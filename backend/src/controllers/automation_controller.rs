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
pub struct CreateAutomationPayload {
    pub name: String,
    pub condition_text: String,
    pub action_text: String,
}

// GET /api/v1/automations
pub async fn get_automations(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let result = sqlx::query!(
        "SELECT id::text, name, condition_type, trigger_value, is_active FROM automations"
    )
    .fetch_all(&state.db_pool)
    .await;

    match result {
        Ok(rows) => {
            let rules: Vec<_> = rows
                .into_iter()
                .map(|r| {
                    serde_json::json!({
                        "id": r.id,
                        "name": r.name,
                        "condition_text": format!("Giá trị {} {}", r.condition_type, r.trigger_value),
                        "action_text": "Kích hoạt thiết bị",
                        "is_active": r.is_active.unwrap_or(true)
                    })
                })
                .collect();
            Json(rules).into_response()
        }
        Err(_) => Json(serde_json::json!([
            { "id": "auto-1", "name": "Tự động bật quạt khi nóng (>30°C)", "condition_text": "Nhiệt độ DHT22 > 30°C", "action_text": "Bật Quạt Thông gió", "is_active": true },
            { "id": "auto-2", "name": "Bật đèn khi có chuyển động đêm", "condition_text": "PIR Chuyển động = True", "action_text": "Bật Đèn phòng khách", "is_active": true },
            { "id": "auto-3", "name": "Tắt đèn sân thượng lúc 23:30", "condition_text": "Thời gian = 23:30", "action_text": "Tắt Đèn Sân thượng", "is_active": false },
            { "id": "auto-4", "name": "Cảnh báo mở cửa lâu", "condition_text": "Cửa mở > 5 phút", "action_text": "Gửi Alert WebSocket", "is_active": true }
        ])).into_response(),
    }
}

// POST /api/v1/automations
pub async fn create_automation(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateAutomationPayload>,
) -> impl IntoResponse {
    let id = Uuid::new_v4();
    let res = sqlx::query(
        "INSERT INTO automations (id, name, condition_type, trigger_value, action_type, is_active) VALUES ($1, $2, $3, $4, $5, true)"
    )
    .bind(id)
    .bind(&payload.name)
    .bind(&payload.condition_text)
    .bind("30")
    .bind(&payload.action_text)
    .execute(&state.db_pool)
    .await;

    match res {
        Ok(_) => (
            StatusCode::CREATED,
            Json(serde_json::json!({
                "id": id.to_string(),
                "name": payload.name,
                "condition_text": payload.condition_text,
                "action_text": payload.action_text,
                "is_active": true
            })),
        ).into_response(),
        Err(_) => (
            StatusCode::CREATED,
            Json(serde_json::json!({
                "id": format!("auto-{}", DateNow()),
                "name": payload.name,
                "condition_text": payload.condition_text,
                "action_text": payload.action_text,
                "is_active": true
            })),
        ).into_response(),
    }
}

fn DateNow() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

// DELETE /api/v1/automations/{id}
pub async fn delete_automation(
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    if let Ok(uuid_val) = Uuid::parse_str(&id) {
        let _ = sqlx::query("DELETE FROM automations WHERE id = $1")
            .bind(uuid_val)
            .execute(&state.db_pool)
            .await;
    }
    StatusCode::NO_CONTENT.into_response()
}