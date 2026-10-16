use sqlx::PgPool;
use uuid::Uuid;
use crate::models::user::Claims;

pub async fn check_permission(
    pool: &PgPool,
    claims: &Claims,
    required_roles: &[&str],
    target_device_id: Option<Uuid>,
) -> Result<bool, String> {
    let session_exists = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM user_sessions WHERE id = $1 AND expires_at > NOW())",
    )
    .bind(claims.session_id)
    .fetch_one(pool)
    .await
    .map_err(|e| e.to_string())?;

    if !session_exists {
        return Err("Session has been revoked or expired".to_string());
    }

    if claims.role_name == "Owner" {
        return Ok(true);
    }

    if !required_roles.contains(&claims.role_name.as_str()) {
        return Err("Forbidden: Insufficient role permission".to_string());
    }

    if claims.role_name == "Guest" {
        if let Some(device_id) = target_device_id {
            let has_guest_access = sqlx::query_scalar::<_, bool>(
                r#"
                SELECT EXISTS(
                    SELECT 1 FROM guest_access 
                    WHERE guest_id = $1 
                      AND device_id = $2 
                      AND NOW() BETWEEN valid_from AND valid_until 
                      AND is_revoked = FALSE
                )
                "#,
            )
            .bind(claims.sub)
            .bind(device_id)
            .fetch_one(pool)
            .await
            .map_err(|e| e.to_string())?;

            if !has_guest_access {
                return Err("Forbidden: Guest access to this device is invalid or expired".to_string());
            }
        }
    }

    Ok(true)
}