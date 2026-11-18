use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::Row;
use std::sync::Arc;
use uuid::Uuid;

use crate::models::user::Claims;
use crate::services::auth_service::hash_password;
use crate::services::rbac_service::check_permission;
use crate::AppState;

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

async fn ensure_owner_or_admin(pool: &sqlx::PgPool, claims: &Claims) -> Result<(), Response> {
    match check_permission(pool, claims, &["Owner", "Admin", "owner", "admin"], None).await {
        Ok(true) => Ok(()),
        Ok(false) => Err((
            StatusCode::FORBIDDEN,
            Json(json!({ "error": "Chỉ tài khoản Owner hoặc Admin mới có quyền quản lý tài khoản" })),
        )
            .into_response()),
        Err(e) => Err((
            StatusCode::FORBIDDEN,
            Json(json!({ "error": format!("Không có quyền quản lý tài khoản: {}", e) })),
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

    let query = r#"
        SELECT
            to_jsonb(u) - 'password_hash' - 'password' AS user_data,
            r.name AS joined_role
        FROM users u
        LEFT JOIN roles r ON u.role_id = r.id
        ORDER BY u.email ASC
    "#;

    match sqlx::query(query).fetch_all(&state.db_pool).await {
        Ok(rows) => {
            let users: Vec<Value> = rows
                .into_iter()
                .map(|row| {
                    let user_data: Value = row.try_get("user_data").unwrap_or_else(|_| json!({}));
                    let joined_role: Option<String> = row.try_get("joined_role").ok();

                    let id = user_data
                        .get("id")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default()
                        .to_string();
                    let email = user_data
                        .get("email")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default()
                        .to_string();

                    let full_name = user_data
                        .get("full_name")
                        .and_then(|v| v.as_str())
                        .map(str::trim)
                        .filter(|s| !s.is_empty());
                    let raw_name = user_data
                        .get("name")
                        .and_then(|v| v.as_str())
                        .map(str::trim)
                        .filter(|s| !s.is_empty() && *s != "User");

                    let display_name = full_name
                        .or(raw_name)
                        .map(ToString::to_string)
                        .unwrap_or_else(|| {
                            email
                                .split('@')
                                .next()
                                .filter(|s| !s.is_empty())
                                .unwrap_or("User")
                                .to_string()
                        });

                    let role = joined_role
                        .filter(|s| !s.trim().is_empty())
                        .or_else(|| {
                            user_data
                                .get("role")
                                .and_then(|v| v.as_str())
                                .map(str::trim)
                                .filter(|s| !s.is_empty())
                                .map(ToString::to_string)
                        })
                        .unwrap_or_else(|| "Member".to_string());

                    let is_active = user_data
                        .get("is_active")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(true);

                    json!({
                        "id": id,
                        "name": display_name,
                        "full_name": display_name,
                        "email": email,
                        "role": role,
                        "role_name": role,
                        "is_active": is_active
                    })
                })
                .collect();

            (StatusCode::OK, Json(json!(users))).into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi truy vấn người dùng: {}", e) })),
        )
            .into_response(),
    }
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

    let display_name = payload
        .full_name
        .or(payload.name)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| payload.email.split('@').next().unwrap_or("User").to_string());

    let requested_role = payload
        .role_name
        .or(payload.role)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Member".to_string());

    let role_row = sqlx::query("SELECT id, name FROM roles WHERE LOWER(name) = LOWER($1)")
        .bind(&requested_role)
        .fetch_optional(&state.db_pool)
        .await;

    let (role_id, canonical_role): (Uuid, String) = match role_row {
        Ok(Some(r)) => (r.get("id"), r.get("name")),
        Ok(None) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "error": "Invalid role name" })),
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
    let email = payload.email.trim().to_string();

    let insert_res = sqlx::query(
        "INSERT INTO users (id, name, full_name, email, password_hash, role, role_id, is_active) VALUES ($1, $2, $3, $4, $5, $6, $7, true)",
    )
    .bind(id)
    .bind(&display_name)
    .bind(&display_name)
    .bind(&email)
    .bind(&hashed_password)
    .bind(&canonical_role)
    .bind(role_id)
    .execute(&state.db_pool)
    .await;

    match insert_res {
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

    let Ok(uuid_val) = Uuid::parse_str(&id) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID người dùng không hợp lệ" })),
        )
            .into_response();
    };

    if let Some(new_name) = payload
        .full_name
        .or(payload.name)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
    {
        if let Err(e) = sqlx::query("UPDATE users SET name = $1, full_name = $1 WHERE id = $2")
            .bind(&new_name)
            .bind(uuid_val)
            .execute(&state.db_pool)
            .await
        {
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
        let role_row = sqlx::query("SELECT id, name FROM roles WHERE LOWER(name) = LOWER($1)")
            .bind(&requested_role)
            .fetch_optional(&state.db_pool)
            .await;

        match role_row {
            Ok(Some(r)) => {
                let role_id: Uuid = r.get("id");
                let canonical_role: String = r.get("name");
                if let Err(e) =
                    sqlx::query("UPDATE users SET role = $1, role_id = $2 WHERE id = $3")
                        .bind(&canonical_role)
                        .bind(role_id)
                        .bind(uuid_val)
                        .execute(&state.db_pool)
                        .await
                {
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
                    Json(json!({ "error": "Invalid role name" })),
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
        if let Err(e) = sqlx::query("UPDATE users SET is_active = $1 WHERE id = $2")
            .bind(is_active)
            .bind(uuid_val)
            .execute(&state.db_pool)
            .await
        {
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
                if let Err(e) = sqlx::query("UPDATE users SET password_hash = $1 WHERE id = $2")
                    .bind(&hashed)
                    .bind(uuid_val)
                    .execute(&state.db_pool)
                    .await
                {
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

    let Ok(uuid_val) = Uuid::parse_str(&id) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID người dùng không hợp lệ" })),
        )
            .into_response();
    };

    if claims.sub == uuid_val {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Không thể tự xóa tài khoản đang đăng nhập" })),
        )
            .into_response();
    }

    match sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(uuid_val)
        .execute(&state.db_pool)
        .await
    {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}