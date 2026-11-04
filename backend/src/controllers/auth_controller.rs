use axum::{extract::State, http::StatusCode, Json};
use std::sync::Arc;
use crate::models::user::{AuthResponseDto, LoginDto, RegisterDto, User, Role, Claims};
use crate::services::auth_service::{create_jwt, hash_password, verify_password};
use crate::AppState;

pub async fn register(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<RegisterDto>,
) -> Result<(StatusCode, Json<String>), (StatusCode, String)> {
    let password_hash = hash_password(&payload.password)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    let role = sqlx::query_as::<_, Role>("SELECT * FROM roles WHERE name = $1")
        .bind(&payload.role_name)
        .fetch_optional(&state.db_pool)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .ok_or((StatusCode::BAD_REQUEST, "Invalid role name".to_string()))?;

    sqlx::query(
        "INSERT INTO users (email, password_hash, full_name, role_id) VALUES ($1, $2, $3, $4)",
    )
    .bind(&payload.email)
    .bind(&password_hash)
    .bind(&payload.full_name)
    .bind(role.id)
    .execute(&state.db_pool)
    .await
    .map_err(|e| (StatusCode::BAD_REQUEST, format!("User creation error: {}", e)))?;

    Ok((StatusCode::CREATED, Json("User registered successfully".to_string())))
}

pub async fn login(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<LoginDto>,
) -> Result<Json<AuthResponseDto>, (StatusCode, String)> {
    let user = sqlx::query_as::<_, User>("SELECT * FROM users WHERE email = $1")
        .bind(&payload.email)
        .fetch_optional(&state.db_pool)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .ok_or((StatusCode::UNAUTHORIZED, "Invalid credentials".to_string()))?;

    if !verify_password(&payload.password, &user.password_hash) {
        return Err((StatusCode::UNAUTHORIZED, "Invalid credentials".to_string()));
    }

    let role = sqlx::query_as::<_, Role>("SELECT * FROM roles WHERE id = $1")
        .bind(user.role_id)
        .fetch_one(&state.db_pool)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let session_id = uuid::Uuid::new_v4();
    let expires_at = chrono::Utc::now() + chrono::Duration::days(7);

    sqlx::query(
        "INSERT INTO user_sessions (id, user_id, token_hash, device_info, expires_at) VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(session_id)
    .bind(user.id)
    .bind("SESSION_TOKEN")
    .bind("Web/Mobile Client")
    .bind(expires_at)
    .execute(&state.db_pool)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let token = create_jwt(user.id, session_id, &user.email, &role.name)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    Ok(Json(AuthResponseDto {
        token,
        user_id: user.id,
        email: user.email,
        role_name: role.name,
    }))
}

pub async fn logout(
    claims: Claims,
    State(state): State<Arc<AppState>>,
) -> Result<StatusCode, (StatusCode, String)> {
    sqlx::query("DELETE FROM user_sessions WHERE id = $1")
        .bind(claims.session_id)
        .execute(&state.db_pool)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(StatusCode::OK)
}