use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use std::sync::Arc;
use crate::AppState;

// GET /api/v1/guests
pub async fn get_guests(State(_state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(serde_json::json!([
        { "id": "g-1", "guest_name": "Nguyễn Văn A (Khách)", "device_name": "Đèn phòng khách", "expiry_time": "23:59 Hôm nay", "status": "ACTIVE" },
        { "id": "g-2", "guest_name": "Trần Thị B (Khách)", "device_name": "Khóa cửa thông minh", "expiry_time": "18:00 03/11/2026", "status": "ACTIVE" }
    ]))
    .into_response()
}

// POST /api/v1/guests/{id}/revoke
pub async fn revoke_guest(
    Path(_id): Path<String>,
    State(_state): State<Arc<AppState>>,
) -> impl IntoResponse {
    (StatusCode::OK, Json(serde_json::json!({ "status": "success", "message": "Đã thu hồi quyền truy cập" }))).into_response()
}