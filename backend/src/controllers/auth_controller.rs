use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use serde_json::json;
use sqlx::{PgPool, Row};
use std::sync::Arc;
use uuid::Uuid;

use crate::models::user::Claims;
use crate::services::auth_service::{create_jwt, hash_password, verify_password};
use crate::AppState;

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

async fn ensure_auth_schema(pool: &PgPool) {
    let migrations = [
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS owner_id UUID REFERENCES users(id) ON DELETE CASCADE",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS role VARCHAR(50) DEFAULT 'Owner'",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS name VARCHAR(150)",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS full_name VARCHAR(150)",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE",
        "INSERT INTO roles (id, name) SELECT gen_random_uuid(), 'Owner' WHERE NOT EXISTS (SELECT 1 FROM roles WHERE LOWER(name) = 'owner')",
        "INSERT INTO roles (id, name) SELECT gen_random_uuid(), 'Admin' WHERE NOT EXISTS (SELECT 1 FROM roles WHERE LOWER(name) = 'admin')",
        "INSERT INTO roles (id, name) SELECT gen_random_uuid(), 'Member' WHERE NOT EXISTS (SELECT 1 FROM roles WHERE LOWER(name) = 'member')",
        "INSERT INTO roles (id, name) SELECT gen_random_uuid(), 'Guest' WHERE NOT EXISTS (SELECT 1 FROM roles WHERE LOWER(name) = 'guest')",
    ];

    for sql in migrations {
        let _ = sqlx::query(sql).execute(pool).await;
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

    // 1. Kiểm tra email đã tồn tại chưa
    let existing = sqlx::query("SELECT id FROM users WHERE LOWER(email) = LOWER($1)")
        .bind(&email)
        .fetch_optional(&state.db_pool)
        .await;

    if let Ok(Some(_)) = existing {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Email này đã được đăng ký" })),
        )
            .into_response();
    }

    // 2. Lấy vai trò "Owner" (Chủ nhà độc lập theo mô hình Multi-tenant)
    let role_row = sqlx::query("SELECT id, name FROM roles WHERE LOWER(name) = 'owner' LIMIT 1")
        .fetch_optional(&state.db_pool)
        .await;

    let (role_id, canonical_role): (Option<Uuid>, String) = match role_row {
        Ok(Some(r)) => (Some(r.get("id")), r.get("name")),
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
    let insert_res = sqlx::query(
        "INSERT INTO users (id, name, full_name, email, password_hash, role, role_id, owner_id, is_active)
         VALUES ($1, $2, $3, $4, $5, $6, $7, NULL, true)",
    )
    .bind(user_id)
    .bind(&display_name)
    .bind(&display_name)
    .bind(&email)
    .bind(&hashed_password)
    .bind(&canonical_role)
    .bind(role_id)
    .execute(&state.db_pool)
    .await;

    if let Err(e) = insert_res {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Không thể đăng ký tài khoản: {}", e) })),
        )
            .into_response();
    }

    // 4. Tạo session_id và JWT khớp với auth_service::create_jwt
    let session_id = Uuid::new_v4();
    let _ = sqlx::query(
        "INSERT INTO user_sessions (id, user_id, expires_at) VALUES ($1, $2, NOW() + INTERVAL '7 days')",
    )
    .bind(session_id)
    .bind(user_id)
    .execute(&state.db_pool)
    .await;

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

    let query = r#"
        SELECT
            u.id,
            COALESCE(NULLIF(TRIM(u.full_name), ''), NULLIF(TRIM(u.name), ''), split_part(u.email, '@', 1)) AS display_name,
            u.email,
            u.password_hash,
            u.owner_id,
            COALESCE(NULLIF(TRIM(r.name), ''), NULLIF(TRIM(u.role), ''), 'Member') AS role_name,
            COALESCE(u.is_active, true) AS is_active
        FROM users u
        LEFT JOIN roles r ON u.role_id = r.id
        WHERE LOWER(u.email) = LOWER($1)
        LIMIT 1
    "#;

    let row = match sqlx::query(query)
        .bind(email)
        .fetch_optional(&state.db_pool)
        .await
    {
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

    let is_active: bool = row.try_get("is_active").unwrap_or(true);
    if !is_active {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({ "error": "Tài khoản này đã bị vô hiệu hóa" })),
        )
            .into_response();
    }

    let password_hash: String = row.try_get("password_hash").unwrap_or_default();
    if !verify_password(&payload.password, &password_hash) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "Email hoặc mật khẩu không chính xác" })),
        )
            .into_response();
    }

    let user_id: Uuid = row.get("id");
    let display_name: String = row.get("display_name");
    let user_email: String = row.get("email");
    let owner_id: Option<Uuid> = row.try_get("owner_id").unwrap_or(None);
    let role_name: String = row.get("role_name");

    let session_id = Uuid::new_v4();
    let _ = sqlx::query(
        "INSERT INTO user_sessions (id, user_id, expires_at) VALUES ($1, $2, NOW() + INTERVAL '7 days')",
    )
    .bind(session_id)
    .bind(user_id)
    .execute(&state.db_pool)
    .await;

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
    let query = r#"
        SELECT
            u.id,
            COALESCE(NULLIF(TRIM(u.full_name), ''), NULLIF(TRIM(u.name), ''), split_part(u.email, '@', 1)) AS display_name,
            u.email,
            u.owner_id,
            COALESCE(NULLIF(TRIM(r.name), ''), NULLIF(TRIM(u.role), ''), 'Member') AS role_name
        FROM users u
        LEFT JOIN roles r ON u.role_id = r.id
        WHERE u.id = $1
    "#;

    match sqlx::query(query)
        .bind(claims.sub)
        .fetch_optional(&state.db_pool)
        .await
    {
        Ok(Some(row)) => {
            let id: Uuid = row.get("id");
            let display_name: String = row.get("display_name");
            let email: String = row.get("email");
            let owner_id: Option<Uuid> = row.try_get("owner_id").unwrap_or(None);
            let role_name: String = row.get("role_name");

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