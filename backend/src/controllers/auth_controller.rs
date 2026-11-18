use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use tiberius::Query;
use uuid::Uuid;

use crate::models::user::Claims;
use crate::services::auth_service::{create_jwt, hash_password, verify_password};
use crate::{AppState, SqlPool};

#[derive(Deserialize)]
pub struct RegisterPayload {
    pub name: Option<String>,
    pub full_name: Option<String>,
    pub email: String,
    pub password: String,
}

#[derive(Deserialize)]
pub struct LoginPayload {
    pub email: String,
    pub password: String,
}

async fn ensure_auth_schema(pool: &SqlPool) {
    let Ok(mut conn) = pool.get().await else {
        return;
    };

    let migrations = [
        "IF COL_LENGTH(N'dbo.users', N'owner_id') IS NULL ALTER TABLE dbo.users ADD owner_id UNIQUEIDENTIFIER NULL",
        "IF COL_LENGTH(N'dbo.users', N'role') IS NULL ALTER TABLE dbo.users ADD role NVARCHAR(50) NOT NULL DEFAULT N'Owner'",
        "IF COL_LENGTH(N'dbo.users', N'name') IS NULL ALTER TABLE dbo.users ADD name NVARCHAR(150) NULL",
        "IF COL_LENGTH(N'dbo.users', N'full_name') IS NULL ALTER TABLE dbo.users ADD full_name NVARCHAR(150) NULL",
        "IF COL_LENGTH(N'dbo.users', N'is_active') IS NULL ALTER TABLE dbo.users ADD is_active BIT NOT NULL DEFAULT 1",
        "INSERT INTO dbo.roles (id, name) SELECT NEWID(), N'Owner' WHERE NOT EXISTS (SELECT 1 FROM dbo.roles WHERE LOWER(name) = N'owner')",
        "INSERT INTO dbo.roles (id, name) SELECT NEWID(), N'Admin' WHERE NOT EXISTS (SELECT 1 FROM dbo.roles WHERE LOWER(name) = N'admin')",
        "INSERT INTO dbo.roles (id, name) SELECT NEWID(), N'Member' WHERE NOT EXISTS (SELECT 1 FROM dbo.roles WHERE LOWER(name) = N'member')",
        "INSERT INTO dbo.roles (id, name) SELECT NEWID(), N'Guest' WHERE NOT EXISTS (SELECT 1 FROM dbo.roles WHERE LOWER(name) = N'guest')",
    ];

    for sql in migrations {
        let _ = conn.execute(sql, &[]).await;
    }
}

// POST /api/v1/auth/register
pub async fn register(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<RegisterPayload>,
) -> impl IntoResponse {
    ensure_auth_schema(&state.db_pool).await;

    let email = payload.email.trim().to_lowercase();
    if email.is_empty() || payload.password.trim().is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Email và mật khẩu không được để trống" })),
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

    // 1. Kiểm tra email đã tồn tại chưa (giải phóng QueryStream ngay trong block)
    let email_exists = {
        let mut check_q =
            Query::new("SELECT TOP 1 id FROM dbo.users WHERE LOWER(email) = LOWER(@P1)");
        check_q.bind(&email);

        match check_q.query(&mut conn).await {
            Ok(stream) => stream.into_row().await.ok().flatten().is_some(),
            Err(_) => false,
        }
    };

    if email_exists {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Email này đã được đăng ký" })),
        )
            .into_response();
    }

    // 2. Lấy vai trò "Owner" (tiêu thụ QueryStream ngay thành Row để trả lại &mut conn)
    let role_row = match conn
        .query(
            "SELECT TOP 1 id, name FROM dbo.roles WHERE LOWER(name) = N'owner'",
            &[],
        )
        .await
    {
        Ok(stream) => stream.into_row().await,
        Err(e) => Err(e),
    };

    let (role_id, canonical_role): (Option<Uuid>, String) = match role_row {
        Ok(Some(r)) => (
            r.get::<Uuid, _>("id"),
            r.get::<&str, _>("name").unwrap_or("Owner").to_string(),
        ),
        Ok(None) => (None, "Owner".to_string()),
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let display_name = payload
        .full_name
        .or(payload.name)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| email.split('@').next().unwrap_or("Owner").to_string());

    let hashed_password = match hash_password(payload.password.trim()) {
        Ok(h) => h,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi mã hóa mật khẩu: {}", e) })),
            )
                .into_response();
        }
    };

    let user_id = Uuid::new_v4();

    // 3. Tạo tài khoản Owner mới với owner_id = NULL (Chủ nhà gốc)
    let insert_user_res = {
        let mut insert_user_q = Query::new(
            r#"
            INSERT INTO dbo.users (id, name, full_name, email, password_hash, role, role_id, owner_id, is_active, created_at)
            VALUES (@P1, @P2, @P3, @P4, @P5, @P6, @P7, NULL, 1, SYSDATETIMEOFFSET())
            "#,
        );
        insert_user_q.bind(user_id);
        insert_user_q.bind(&display_name);
        insert_user_q.bind(&display_name);
        insert_user_q.bind(&email);
        insert_user_q.bind(&hashed_password);
        insert_user_q.bind(&canonical_role);
        insert_user_q.bind(role_id);

        insert_user_q.execute(&mut conn).await
    };

    if let Err(e) = insert_user_res {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Không thể đăng ký tài khoản: {}", e) })),
        )
            .into_response();
    }

    // 4. Tạo session_id và JWT khớp với auth_service::create_jwt
    let session_id = Uuid::new_v4();
    let session_id_str = session_id.to_string();

    {
        let mut insert_sess_q = Query::new(
            r#"
            INSERT INTO dbo.user_sessions (id, user_id, token_hash, expires_at, created_at)
            VALUES (@P1, @P2, @P3, DATEADD(DAY, 7, SYSDATETIMEOFFSET()), SYSDATETIMEOFFSET())
            "#,
        );
        insert_sess_q.bind(session_id);
        insert_sess_q.bind(user_id);
        insert_sess_q.bind(&session_id_str);
        let _ = insert_sess_q.execute(&mut conn).await;
    }

    let token = match create_jwt(user_id, session_id, &email, &canonical_role) {
        Ok(t) => t,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi tạo phiên đăng nhập: {}", e) })),
            )
                .into_response();
        }
    };

    (
        StatusCode::CREATED,
        Json(json!({
            "token": token,
            "user": {
                "id": user_id.to_string(),
                "name": display_name,
                "full_name": display_name,
                "email": email,
                "role": canonical_role,
                "owner_id": serde_json::Value::Null
            }
        })),
    )
        .into_response()
}

// POST /api/v1/auth/login
pub async fn login(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<LoginPayload>,
) -> impl IntoResponse {
    ensure_auth_schema(&state.db_pool).await;

    let email = payload.email.trim();
    if email.is_empty() || payload.password.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Vui lòng nhập đầy đủ email và mật khẩu" })),
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

    let sql = r#"
        SELECT TOP 1
            u.id,
            COALESCE(
                NULLIF(TRIM(u.full_name), N''),
                NULLIF(TRIM(u.name), N''),
                LEFT(u.email, CHARINDEX(N'@', u.email + N'@') - 1)
            ) AS display_name,
            u.email,
            u.password_hash,
            u.owner_id,
            COALESCE(NULLIF(TRIM(r.name), N''), NULLIF(TRIM(u.role), N''), N'Member') AS role_name,
            COALESCE(u.is_active, CAST(1 AS BIT)) AS is_active
        FROM dbo.users u
        LEFT JOIN dbo.roles r ON u.role_id = r.id
        WHERE LOWER(u.email) = LOWER(@P1)
    "#;

    let user_row = {
        let mut query = Query::new(sql);
        query.bind(email);

        match query.query(&mut conn).await {
            Ok(stream) => stream.into_row().await,
            Err(e) => Err(e),
        }
    };

    let row = match user_row {
        Ok(Some(r)) => r,
        Ok(None) => {
            return (
                StatusCode::UNAUTHORIZED,
                Json(json!({ "error": "Email hoặc mật khẩu không chính xác" })),
            )
                .into_response();
        }
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi truy vấn đăng nhập: {}", e) })),
            )
                .into_response();
        }
    };

    let is_active = row.get::<bool, _>("is_active").unwrap_or(true);
    if !is_active {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({ "error": "Tài khoản này đã bị vô hiệu hóa" })),
        )
            .into_response();
    }

    let password_hash = row.get::<&str, _>("password_hash").unwrap_or("");
    if !verify_password(&payload.password, password_hash) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "Email hoặc mật khẩu không chính xác" })),
        )
            .into_response();
    }

    let Some(user_id) = row.get::<Uuid, _>("id") else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": "Dữ liệu ID người dùng không hợp lệ" })),
        )
            .into_response();
    };
    let display_name = row.get::<&str, _>("display_name").unwrap_or("").to_string();
    let user_email = row.get::<&str, _>("email").unwrap_or("").to_string();
    let owner_id: Option<Uuid> = row.get::<Uuid, _>("owner_id");
    let role_name = row.get::<&str, _>("role_name").unwrap_or("Member").to_string();

    let session_id = Uuid::new_v4();
    let session_id_str = session_id.to_string();

    {
        let mut insert_sess_q = Query::new(
            r#"
            INSERT INTO dbo.user_sessions (id, user_id, token_hash, expires_at, created_at)
            VALUES (@P1, @P2, @P3, DATEADD(DAY, 7, SYSDATETIMEOFFSET()), SYSDATETIMEOFFSET())
            "#,
        );
        insert_sess_q.bind(session_id);
        insert_sess_q.bind(user_id);
        insert_sess_q.bind(&session_id_str);
        let _ = insert_sess_q.execute(&mut conn).await;
    }

    let token = match create_jwt(user_id, session_id, &user_email, &role_name) {
        Ok(t) => t,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi tạo token: {}", e) })),
            )
                .into_response();
        }
    };

    (
        StatusCode::OK,
        Json(json!({
            "token": token,
            "user": {
                "id": user_id.to_string(),
                "name": display_name,
                "full_name": display_name,
                "email": user_email,
                "role": role_name,
                "owner_id": owner_id.map(|u| u.to_string())
            }
        })),
    )
        .into_response()
}

// GET /api/v1/auth/me
pub async fn me(
    claims: Claims,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
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
        SELECT TOP 1
            u.id,
            COALESCE(
                NULLIF(TRIM(u.full_name), N''),
                NULLIF(TRIM(u.name), N''),
                LEFT(u.email, CHARINDEX(N'@', u.email + N'@') - 1)
            ) AS display_name,
            u.email,
            u.owner_id,
            COALESCE(NULLIF(TRIM(r.name), N''), NULLIF(TRIM(u.role), N''), N'Member') AS role_name
        FROM dbo.users u
        LEFT JOIN dbo.roles r ON u.role_id = r.id
        WHERE u.id = @P1
    "#;

    let row_res = {
        let mut query = Query::new(sql);
        query.bind(claims.sub);

        match query.query(&mut conn).await {
            Ok(stream) => stream.into_row().await,
            Err(e) => Err(e),
        }
    };

    match row_res {
        Ok(Some(row)) => {
            let id = row.get::<Uuid, _>("id").unwrap_or(claims.sub);
            let display_name = row.get::<&str, _>("display_name").unwrap_or("").to_string();
            let email = row.get::<&str, _>("email").unwrap_or("").to_string();
            let owner_id: Option<Uuid> = row.get::<Uuid, _>("owner_id");
            let role_name = row.get::<&str, _>("role_name").unwrap_or("Member").to_string();

            (
                StatusCode::OK,
                Json(json!({
                    "id": id.to_string(),
                    "name": display_name,
                    "full_name": display_name,
                    "email": email,
                    "role": role_name,
                    "owner_id": owner_id.map(|u| u.to_string())
                })),
            )
                .into_response()
        }
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Không tìm thấy người dùng" })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}