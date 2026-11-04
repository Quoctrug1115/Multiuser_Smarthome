use axum::{extract::State, response::IntoResponse, Json};
use serde::Deserialize;
use std::sync::Arc;
use crate::AppState;

#[derive(Deserialize)]
pub struct AnomalyPayload {
    pub temperature: f32,
    pub sensor_id: String,
}

// GET /api/v1/ai/alerts
pub async fn get_alerts(State(_state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(serde_json::json!([
        { "id": "alt-1", "alert_type": "HIGH_SPIKE (Z-Score: 3.85)", "message": "Nhiệt độ vọt lên 65°C bất thường!", "created_at": "10:12:05" },
        { "id": "alt-2", "alert_type": "UNUSUAL_MOTION (Z-Score: 2.1)", "message": "Phát hiện chuyển động lúc 03:15 sáng", "created_at": "03:15:22" }
    ]))
    .into_response()
}

// POST /api/v1/ai/simulate-anomaly
pub async fn simulate_anomaly(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<AnomalyPayload>,
) -> impl IntoResponse {
    let now_str = chrono::Local::now().format("%H:%M:%S").to_string();
    let alert_msg = serde_json::json!({
        "id": format!("alt-{}", DateNow()),
        "alert_type": "HIGH_SPIKE (Z-Score: 4.12)",
        "message": format!("Cảnh báo vọt nhiệt độ {}°C tại cảm biến {}!", payload.temperature, payload.sensor_id),
        "created_at": now_str
    });

    // Bắn tin nhắn phát sóng WebSocket tới Frontend Client ngay lập tức
    let ws_broadcast = serde_json::json!({
        "type": "AI_ALERT",
        "data": alert_msg
    });
    let _ = state.tx.send(ws_broadcast.to_string());

    Json(alert_msg).into_response()
}

fn DateNow() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}