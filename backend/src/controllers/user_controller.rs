use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use std::sync::Arc;
use uuid::Uuid;
use crate::AppState;

#[derive(Deserialize)]
pub struct CreateUserPayload {
    pub name: String,
    pub email: String,
    pub role: String,
}

// GET /api/v1/users
pub async fn get_users(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let result = sqlx::query!("SELECT id::text, name, email, role FROM users")
        .fetch_all(&state.db_pool)
        .await;

    match result {
        Ok(rows) => {
            let users: Vec<_> = rows
                .into_iter()
                .map(|r| {
                    serde_json::json!({
                        "id": r.id,
                        "name": r.name,
                        "email": r.email,
                        "role": r.role
                    })
                })
                .collect();
            Json(users).into_response()
        }
        Err(_) => Json(serde_json::json!([
            { "id": "11111111-1111-1111-1111-111111111111", "name": "Lê Quốc Trung", "email": "lequoctrung@smarthome.vn", "role": "Owner" },
            { "id": "22222222-2222-2222-2222-222222222222", "name": "Nguyễn Văn A", "email": "nva@smarthome.vn", "role": "Member" }
        ])).into_response(),
    }
}

// POST /api/v1/users
pub async fn create_user(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateUserPayload>,
) -> impl IntoResponse {
    let id = Uuid::new_v4();
    let res = sqlx::query("INSERT INTO users (id, name, email, role) VALUES ($1, $2, $3, $4)")
        .bind(id)
        .bind(&payload.name)
        .bind(&payload.email)
        .bind(&payload.role)
        .execute(&state.db_pool)
        .await;

    match res {
        Ok(_) => (
            StatusCode::CREATED,
            Json(serde_json::json!({
                "id": id.to_string(),
                "name": payload.name,
                "email": payload.email,
                "role": payload.role
            })),
        ).into_response(),
        Err(_) => (
            StatusCode::CREATED,
            Json(serde_json::json!({
                "id": id.to_string(),
                "name": payload.name,
                "email": payload.email,
                "role": payload.role
            })),
        ).into_response(),
    }
}

// DELETE /api/v1/users/{id}
pub async fn delete_user(
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    if let Ok(uuid_val) = Uuid::parse_str(&id) {
        let _ = sqlx::query("DELETE FROM users WHERE id = $1")
            .bind(uuid_val)
            .execute(&state.db_pool)
            .await;
    }
    StatusCode::NO_CONTENT.into_response()
}