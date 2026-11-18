use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;
use tiberius::Query;
use uuid::Uuid;

use crate::models::user::Claims;
use crate::services::auth_service::hash_password;
use crate::services::rbac_service::check_permission;
use crate::{AppState, SqlPool};

#[derive(Deserialize)]
pub struct CreateUserPayload {
    pub name: Option<String>,
    pub full_name: Option<String>,
    pub email: String,
    pub password: Option<String>,
    pub role: Option<String>,
    pub role_name: Option<String>,
}

#[derive(Deserialize)]
pub struct UpdateUserPayload {
    pub name: Option<String>,
    pub full_name: Option<String>,
    pub role: Option<String>,
    pub role_name: Option<String>,
    pub is_active: Option<bool>,
    pub password: Option<String>,
}

/// Xác định ID Chủ nhà gốc (tenant_id) của người dùng đang đăng nhập:
/// - Nếu user tự đăng ký (owner_id IS NULL) -> trả về chính user_id đó.
/// - Nếu user là tài khoản phụ (Admin/Member/Guest do Owner tạo) -> trả về owner_id của họ.
pub async fn resolve_tenant_id(pool: &SqlPool, user_id: Uuid) -> Result<Uuid, Response> {
    let mut conn = pool.get().await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
        )
            .into_response()
    })?;

    let mut q = Query::new("SELECT TOP 1 owner_id FROM dbo.users WHERE id = @P1");
    q.bind(user_id);

    let row = q
        .query(&mut conn)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi truy vấn người dùng: {}", e) })),
            )
                .into_response()
        })?
        .into_row()
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi đọc dữ liệu người dùng: {}", e) })),
            )
                .into_response()
        })?;

    match row {
        Some(r) => {
            let parent_owner: Option<Uuid> = r.get::<Uuid, _>("owner_id");
            Ok(parent_owner.unwrap_or(user_id))
        }
        None => Err((
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "Tài khoản không tồn tại hoặc đã bị xóa" })),
        )
            .into_response()),
    }
}

pub async fn ensure_owner_or_admin(pool: &SqlPool, claims: &Claims) -> Result<(), Response> {
    let mut db_role: Option<String> = None;

    if let Ok(mut conn) = pool.get().await {
        let mut q = Query::new(
            r#"
            SELECT TOP 1
                COALESCE(NULLIF(TRIM(r.name), N''), NULLIF(TRIM(u.role), N''), N'Member') AS effective_role
            FROM dbo.users u
            LEFT JOIN dbo.roles r ON u.role_id = r.id
            WHERE u.id = @P1
            "#,
        );
        q.bind(claims.sub);

        if let Ok(stream) = q.query(&mut conn).await {
            if let Ok(Some(row)) = stream.into_row().await {
                db_role = row
                    .get::<&str, _>("effective_role")
                    .map(|s| s.to_string());
            }
        }
    }

    let effective_role = db_role
        .unwrap_or_else(|| claims.role_name.clone())
        .trim()
        .to_lowercase();

    if effective_role == "owner" || effective_role == "admin" {
        return Ok(());
    }

    match check_permission(pool, claims, &["Owner", "Admin", "owner", "admin"], None).await {
        Ok(true) => Ok(()),
        _ => Err((
            StatusCode::FORBIDDEN,
            Json(json!({ "error": "Chỉ tài khoản Owner hoặc Admin mới có quyền thực hiện thao tác này" })),
        )
            .into_response()),
    }
}

// GET /api/v1/users
pub async fn get_users(
    claims: Claims,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    let sql = r#"
        SELECT
            u.id,
            u.email,
            COALESCE(
                NULLIF(TRIM(u.full_name), N''),
                NULLIF(NULLIF(TRIM(u.name), N''), N'User'),
                LEFT(u.email, CHARINDEX(N'@', u.email + N'@') - 1),
                N'User'
            ) AS display_name,
            COALESCE(NULLIF(TRIM(r.name), N''), NULLIF(TRIM(u.role), N''), N'Member') AS role_name,
            COALESCE(u.is_active, CAST(1 AS BIT)) AS is_active
        FROM dbo.users u
        LEFT JOIN dbo.roles r ON u.role_id = r.id
        WHERE u.owner_id = @P1 OR u.id = @P1
        ORDER BY CASE WHEN u.id = @P1 THEN 0 ELSE 1 END ASC, u.email ASC
    "#;

    let mut q = Query::new(sql);
    q.bind(tenant_id);

    let response = match q.query(&mut conn).await {
        Ok(stream) => {
            let rows = stream.into_first_result().await.unwrap_or_default();
            let users: Vec<Value> = rows
                .into_iter()
                .filter_map(|row| {
                    let id = row.get::<Uuid, _>("id")?;
                    let email = row.get::<&str, _>("email").unwrap_or("").to_string();
                    let display_name = row
                        .get::<&str, _>("display_name")
                        .unwrap_or("User")
                        .to_string();
                    let role = row
                        .get::<&str, _>("role_name")
                        .unwrap_or("Member")
                        .to_string();
                    let is_active = row.get::<bool, _>("is_active").unwrap_or(true);

                    Some(json!({
                        "id": id.to_string(),
                        "name": display_name,
                        "full_name": display_name,
                        "email": email,
                        "role": role,
                        "role_name": role,
                        "is_active": is_active
                    }))
                })
                .collect();

            (StatusCode::OK, Json(json!(users))).into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi truy vấn người dùng: {}", e) })),
        )
            .into_response(),
    };
    response
}

// POST /api/v1/users
pub async fn create_user(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateUserPayload>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let email = payload.email.trim().to_string();
    if email.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Email không được để trống" })),
        )
            .into_response();
    }

    let display_name = payload
        .full_name
        .or(payload.name)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| email.split('@').next().unwrap_or("User").to_string());

    let requested_role = payload
        .role_name
        .or(payload.role)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Member".to_string());

    if requested_role.eq_ignore_ascii_case("owner") {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Chỉ được tạo tài khoản phụ với vai trò Admin, Member hoặc Guest" })),
        )
            .into_response();
    }

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    // Kiểm tra email đã tồn tại chưa
    let email_exists = {
        let mut dup_q =
            Query::new("SELECT TOP 1 id FROM dbo.users WHERE LOWER(email) = LOWER(@P1)");
        dup_q.bind(&email);

        match dup_q.query(&mut conn).await {
            Ok(stream) => stream.into_row().await.ok().flatten().is_some(),
            Err(_) => false,
        }
    };

    if email_exists {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Email này đã được sử dụng" })),
        )
            .into_response();
    }

    let role_row = {
        let mut role_q =
            Query::new("SELECT TOP 1 id, name FROM dbo.roles WHERE LOWER(name) = LOWER(@P1)");
        role_q.bind(&requested_role);

        match role_q.query(&mut conn).await {
            Ok(stream) => stream.into_row().await,
            Err(e) => Err(e),
        }
    };

    let (role_id, canonical_role): (Uuid, String) = match role_row {
        Ok(Some(r)) => {
            let Some(rid) = r.get::<Uuid, _>("id") else {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "error": "Dữ liệu role_id không hợp lệ" })),
                )
                    .into_response();
            };
            let rname = r
                .get::<&str, _>("name")
                .unwrap_or(&requested_role)
                .to_string();
            (rid, rname)
        }
        Ok(None) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "error": "Tên vai trò không hợp lệ" })),
            )
                .into_response();
        }
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let raw_password = payload
        .password
        .filter(|p| !p.trim().is_empty())
        .unwrap_or_else(|| "123456".to_string());

    let hashed_password = match hash_password(&raw_password) {
        Ok(h) => h,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi mã hóa mật khẩu: {}", e) })),
            )
                .into_response();
        }
    };

    let id = Uuid::new_v4();

    let mut insert_q = Query::new(
        r#"
        INSERT INTO dbo.users (id, name, full_name, email, password_hash, role, role_id, owner_id, is_active, created_at)
        VALUES (@P1, @P2, @P3, @P4, @P5, @P6, @P7, @P8, 1, SYSDATETIMEOFFSET())
        "#,
    );
    insert_q.bind(id);
    insert_q.bind(&display_name);
    insert_q.bind(&display_name);
    insert_q.bind(&email);
    insert_q.bind(&hashed_password);
    insert_q.bind(&canonical_role);
    insert_q.bind(role_id);
    insert_q.bind(tenant_id);

    match insert_q.execute(&mut conn).await {
        Ok(_) => (
            StatusCode::CREATED,
            Json(json!({
                "id": id.to_string(),
                "name": display_name,
                "full_name": display_name,
                "email": email,
                "role": canonical_role,
                "role_name": canonical_role,
                "is_active": true
            })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": format!("Không thể tạo tài khoản: {}", e) })),
        )
            .into_response(),
    }
}

// PUT /api/v1/users/{id}
pub async fn update_user(
    claims: Claims,
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<UpdateUserPayload>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let Ok(uuid_val) = Uuid::parse_str(id.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID người dùng không hợp lệ" })),
        )
            .into_response();
    };

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    // Kiểm tra user mục tiêu có thuộc hộ gia đình hiện tại không
    let exists = {
        let mut check_q = Query::new(
            "SELECT TOP 1 id FROM dbo.users WHERE id = @P1 AND (owner_id = @P2 OR id = @P2)",
        );
        check_q.bind(uuid_val);
        check_q.bind(tenant_id);

        match check_q.query(&mut conn).await {
            Ok(stream) => stream.into_row().await.ok().flatten().is_some(),
            Err(_) => false,
        }
    };

    if !exists {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Không tìm thấy tài khoản trong gia đình của bạn" })),
        )
            .into_response();
    }

    if let Some(new_name) = payload
        .full_name
        .or(payload.name)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
    {
        let mut q = Query::new("UPDATE dbo.users SET name = @P1, full_name = @P1 WHERE id = @P2");
        q.bind(&new_name);
        q.bind(uuid_val);
        if let Err(e) = q.execute(&mut conn).await {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    }

    if let Some(requested_role) = payload
        .role_name
        .or(payload.role)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
    {
        if uuid_val == tenant_id || requested_role.eq_ignore_ascii_case("owner") {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "error": "Không thể thay đổi vai trò Chủ nhà gốc" })),
            )
                .into_response();
        }

        // Giải phóng QueryStream trước khi gọi upd_role_q.execute(&mut conn)
        let role_row = {
            let mut role_q =
                Query::new("SELECT TOP 1 id, name FROM dbo.roles WHERE LOWER(name) = LOWER(@P1)");
            role_q.bind(&requested_role);

            match role_q.query(&mut conn).await {
                Ok(stream) => stream.into_row().await,
                Err(e) => Err(e),
            }
        };

        match role_row {
            Ok(Some(r)) => {
                let Some(role_id) = r.get::<Uuid, _>("id") else {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(json!({ "error": "Dữ liệu role_id không hợp lệ" })),
                    )
                        .into_response();
                };
                let canonical_role = r
                    .get::<&str, _>("name")
                    .unwrap_or(&requested_role)
                    .to_string();

                let mut upd_role_q =
                    Query::new("UPDATE dbo.users SET role = @P1, role_id = @P2 WHERE id = @P3");
                upd_role_q.bind(&canonical_role);
                upd_role_q.bind(role_id);
                upd_role_q.bind(uuid_val);

                if let Err(e) = upd_role_q.execute(&mut conn).await {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(json!({ "error": e.to_string() })),
                    )
                        .into_response();
                }
            }
            Ok(None) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({ "error": "Tên vai trò không hợp lệ" })),
                )
                    .into_response();
            }
            Err(e) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "error": e.to_string() })),
                )
                    .into_response();
            }
        }
    }

    if let Some(is_active) = payload.is_active {
        if uuid_val == tenant_id && !is_active {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "error": "Không thể khóa tài khoản Chủ nhà gốc" })),
            )
                .into_response();
        }

        let mut upd_active_q = Query::new("UPDATE dbo.users SET is_active = @P1 WHERE id = @P2");
        upd_active_q.bind(is_active);
        upd_active_q.bind(uuid_val);

        if let Err(e) = upd_active_q.execute(&mut conn).await {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    }

    if let Some(new_pass) = payload.password.filter(|p| !p.trim().is_empty()) {
        match hash_password(new_pass.trim()) {
            Ok(hashed) => {
                let mut upd_pass_q =
                    Query::new("UPDATE dbo.users SET password_hash = @P1 WHERE id = @P2");
                upd_pass_q.bind(&hashed);
                upd_pass_q.bind(uuid_val);

                if let Err(e) = upd_pass_q.execute(&mut conn).await {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(json!({ "error": e.to_string() })),
                    )
                        .into_response();
                }
            }
            Err(e) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "error": format!("Lỗi mã hóa mật khẩu: {}", e) })),
                )
                    .into_response();
            }
        }
    }

    (
        StatusCode::OK,
        Json(json!({ "message": "Đã cập nhật tài khoản" })),
    )
        .into_response()
}

// DELETE /api/v1/users/{id}
pub async fn delete_user(
    claims: Claims,
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let Ok(uuid_val) = Uuid::parse_str(id.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID người dùng không hợp lệ" })),
        )
            .into_response();
    };

    if uuid_val == tenant_id || uuid_val == claims.sub {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Không thể xóa tài khoản Chủ nhà gốc hoặc tài khoản đang đăng nhập" })),
        )
            .into_response();
    }

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    // Gỡ liên kết khóa ngoại trên các bảng có ON DELETE NO ACTION trước khi xóa tài khoản phụ
    let cleanup_queries = [
        "DELETE FROM dbo.guest_access WHERE guest_user_id = @P1 OR granted_by = @P1",
        "UPDATE dbo.houses SET owner_id = @P2 WHERE owner_id = @P1",
        "UPDATE dbo.devices SET owner_id = @P2 WHERE owner_id = @P1",
        "UPDATE dbo.automations SET owner_id = @P2 WHERE owner_id = @P1",
        "UPDATE dbo.ai_alerts SET owner_id = @P2 WHERE owner_id = @P1",
        "UPDATE dbo.energy_logs SET owner_id = @P2 WHERE owner_id = @P1",
    ];
    for sql in cleanup_queries {
        let mut q = Query::new(sql);
        q.bind(uuid_val);
        q.bind(tenant_id);
        let _ = q.execute(&mut conn).await;
    }

    let mut del_q = Query::new("DELETE FROM dbo.users WHERE id = @P1 AND owner_id = @P2");
    del_q.bind(uuid_val);
    del_q.bind(tenant_id);

    match del_q.execute(&mut conn).await {
        Ok(res) if res.rows_affected().iter().sum::<u64>() > 0 => StatusCode::NO_CONTENT.into_response(),
        Ok(_) => (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Không tìm thấy tài khoản trong gia đình của bạn" })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}