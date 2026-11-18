use tiberius::Query;
use uuid::Uuid;

use crate::models::user::Claims;
use crate::SqlPool;

pub async fn check_permission(
    pool: &SqlPool,
    claims: &Claims,
    required_roles: &[&str],
    target_device_id: Option<Uuid>,
) -> Result<bool, String> {
    let mut conn = pool.get().await.map_err(|e| e.to_string())?;

    // 1. Kiểm tra phiên đăng nhập còn hiệu lực trong SQL Server
    let mut sess_q = Query::new(
        "SELECT TOP 1 1 AS found FROM dbo.user_sessions WHERE id = @P1 AND expires_at > SYSDATETIMEOFFSET()",
    );
    sess_q.bind(claims.session_id);

    let session_exists = sess_q
        .query(&mut conn)
        .await
        .map_err(|e| e.to_string())?
        .into_row()
        .await
        .map_err(|e| e.to_string())?
        .is_some();

    if !session_exists {
        return Err("Session has been revoked or expired".to_string());
    }

    // 2. Chủ nhà (Owner) có toàn quyền trên hệ thống của mình
    if claims.role_name.eq_ignore_ascii_case("Owner") {
        return Ok(true);
    }

    // 3. Kiểm tra vai trò có nằm trong danh sách được phép không
    let has_role = required_roles
        .iter()
        .any(|r| r.eq_ignore_ascii_case(claims.role_name.trim()));
    if !has_role {
        return Err("Forbidden: Insufficient role permission".to_string());
    }

    // 4. Kiểm tra quyền truy cập thiết bị giới hạn thời gian đối với Khách (Guest)
    if claims.role_name.eq_ignore_ascii_case("Guest") {
        if let Some(device_id) = target_device_id {
            let mut guest_q = Query::new(
                r#"
                SELECT TOP 1 1 AS found
                FROM dbo.guest_access
                WHERE guest_id = @P1
                  AND device_id = @P2
                  AND SYSDATETIMEOFFSET() BETWEEN valid_from AND valid_until
                  AND COALESCE(is_revoked, CAST(0 AS BIT)) = 0
                "#,
            );
            guest_q.bind(claims.sub);
            guest_q.bind(device_id);

            let has_guest_access = guest_q
                .query(&mut conn)
                .await
                .map_err(|e| e.to_string())?
                .into_row()
                .await
                .map_err(|e| e.to_string())?
                .is_some();

            if !has_guest_access {
                return Err(
                    "Forbidden: Guest access to this device is invalid or expired".to_string(),
                );
            }
        }
    }

    Ok(true)
}