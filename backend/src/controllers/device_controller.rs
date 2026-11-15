use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use rumqttc::QoS;
use serde::Deserialize;
use serde_json::Value as JsonValue;
use std::sync::Arc;
use uuid::Uuid;
use crate::AppState;

#[derive(Debug, Deserialize)]
pub struct ControlDeviceDto {
    pub command: Option<JsonValue>,
    pub power: Option<String>,
}

// GET /api/v1/devices
pub async fn get_devices(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let result = sqlx::query(
        "SELECT id::text, name, room_name, status, power_watt FROM devices"
    )
    .fetch_all(&state.db_pool)
    .await;

    match result {
        Ok(rows) => {
            use sqlx::Row;
            let list: Vec<_> = rows
                .into_iter()
                .map(|r| {
                    let id: String = r.get("id");
                    let name: String = r.get("name");
                    let room_name: String = r.get("room_name");
                    let status: bool = r.get("status");
                    let power_watt: i32 = r.get("power_watt");

                    serde_json::json!({
                        "id": id,
                        "name": name,
                        "room_name": room_name,
                        "status": status,
                        "power_watt": power_watt,
                        "topic": format!("smarthome/devices/{}/command", id)
                    })
                })
                .collect();
            Json(list).into_response()
        }
        Err(_) => {
            // Fallback dữ liệu mẫu nếu chưa tạo bảng DB
            Json(serde_json::json!([
                { "id": "d1", "name": "Đèn phòng khách", "room_name": "Phòng khách", "status": true, "power_watt": 18, "topic": "smarthome/devices/d1/command" },
                { "id": "d2", "name": "Quạt Thông gió", "room_name": "Nhà bếp", "status": false, "power_watt": 45, "topic": "smarthome/devices/d2/command" },
                { "id": "d3", "name": "Khóa cửa thông minh", "room_name": "Phòng khách", "status": true, "power_watt": 5, "topic": "smarthome/devices/d3/command" },
                { "id": "d4", "name": "Đèn ngủ PWM", "room_name": "Phòng ngủ", "status": true, "power_watt": 12, "topic": "smarthome/devices/d4/command" },
                { "id": "d5", "name": "Điều hòa Phòng khách", "room_name": "Phòng khách", "status": true, "power_watt": 350, "topic": "smarthome/devices/d5/command" },
                { "id": "d6", "name": "Đèn Sân thượng", "room_name": "Sân thượng", "status": false, "power_watt": 20, "topic": "smarthome/devices/d6/command" }
            ])).into_response()
        }
    }
}

#[derive(serde::Deserialize)]
pub struct DevicePayload {
    pub name: String,
    pub device_type: String,
    pub mqtt_topic: String,
}

// POST /api/v1/devices
pub async fn create_device(
    axum::extract::State(state): axum::extract::State<std::sync::Arc<crate::AppState>>,
    axum::Json(payload): axum::Json<DevicePayload>,
) -> impl axum::response::IntoResponse {
    let res = sqlx::query(
        "INSERT INTO devices (name, device_type, mqtt_topic, status) VALUES ($1, $2, $3, 'OFF')",
    )
    .bind(&payload.name)
    .bind(&payload.device_type)
    .bind(&payload.mqtt_topic)
    .execute(&state.db_pool)
    .await;

    match res {
        Ok(_) => (
            axum::http::StatusCode::CREATED,
            axum::Json(serde_json::json!({ "message": "Đã thêm thiết bị" })),
        ),
        Err(e) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            axum::Json(serde_json::json!({ "error": e.to_string() })),
        ),
    }
}

// GET /api/v1/devices/discover
pub async fn discover_devices(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let existing_topics: Vec<String> =
        sqlx::query_scalar::<_, String>("SELECT mqtt_topic FROM devices")
            .fetch_all(&state.db_pool)
            .await
            .unwrap_or_default();

    let discovered = state.discovered_devices.read().await;
    let available: Vec<serde_json::Value> = discovered
        .iter()
        .filter(|(topic, _)| !existing_topics.contains(topic))
        .map(|(_, info)| info.clone())
        .collect();

    (StatusCode::OK, Json(available)).into_response()
}
// POST /api/v1/devices/{id}/control
pub async fn control_device(
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    let action_str = payload
        .get("action")
        .or_else(|| payload.get("state"))
        .and_then(|v| v.as_str())
        .unwrap_or("OFF")
        .to_uppercase();
    let is_on = action_str == "ON"
        || payload
            .get("is_on")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
    let command = if is_on { "ON" } else { "OFF" };

    // 1. Ưu tiên tìm mqtt_topic trong PostgreSQL
    let db_topic: Option<String> =
        sqlx::query_scalar("SELECT mqtt_topic FROM devices WHERE id::text = $1")
            .bind(id.trim())
            .fetch_optional(&state.db_pool)
            .await
            .unwrap_or(None);

    // 2. Nếu là thiết bị mẫu (d1..d4) chưa có trong DB, lấy topic từ payload hoặc mặc định Wokwi
    let mqtt_topic = db_topic
        .or_else(|| {
            payload
                .get("mqtt_topic")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        })
        .unwrap_or_else(|| {
            if id.trim() == "d2" || id.trim() == "d4" {
                "smarthome/devices/quat_phong_khach".to_string()
            } else {
                "smarthome/devices/led_phong_khach".to_string()
            }
        });

    // 3. Cập nhật trạng thái trong Database (nếu bản ghi tồn tại)
    let _ = sqlx::query("UPDATE devices SET is_on = $1 WHERE id::text = $2")
        .bind(is_on)
        .bind(id.trim())
        .execute(&state.db_pool)
        .await;
    let _ = sqlx::query("UPDATE devices SET status = $1 WHERE id::text = $2")
        .bind(command)
        .bind(id.trim())
        .execute(&state.db_pool)
        .await;

    // 4. Bắn lệnh MQTT xuống Wokwi ESP32
    let _ = state
        .mqtt_client
        .publish(&mqtt_topic, rumqttc::QoS::AtMostOnce, false, command.as_bytes())
        .await;
    let control_topic = format!("{}/control", mqtt_topic.trim_end_matches('/'));
    let _ = state
        .mqtt_client
        .publish(&control_topic, rumqttc::QoS::AtMostOnce, false, command.as_bytes())
        .await;

    println!(
        "🚀 [MQTT SEND -> WOKWI] ID: {} | Topic: {} | Lệnh: {}",
        id, mqtt_topic, command
    );

    (
        StatusCode::OK,
        Json(serde_json::json!({
            "id": id,
            "is_on": is_on,
            "status": command,
            "mqtt_topic": mqtt_topic
        })),
    )
        .into_response()
}
// PUT /api/v1/devices/{id}
pub async fn update_device(
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    if let Some(name) = payload.get("name").and_then(|v| v.as_str()) {
        let _ = sqlx::query("UPDATE devices SET name = $1 WHERE id::text = $2")
            .bind(name.trim())
            .bind(id.trim())
            .execute(&state.db_pool)
            .await;
    }
    if let Some(dtype) = payload.get("device_type").and_then(|v| v.as_str()) {
        let _ = sqlx::query("UPDATE devices SET device_type = $1 WHERE id::text = $2")
            .bind(dtype.trim())
            .bind(id.trim())
            .execute(&state.db_pool)
            .await;
    }
    if let Some(topic) = payload.get("mqtt_topic").and_then(|v| v.as_str()) {
        let _ = sqlx::query("UPDATE devices SET mqtt_topic = $1 WHERE id::text = $2")
            .bind(topic.trim())
            .bind(id.trim())
            .execute(&state.db_pool)
            .await;
    }

    (
        StatusCode::OK,
        Json(serde_json::json!({ "message": "Đã cập nhật thiết bị", "id": id })),
    )
        .into_response()
}

// DELETE /api/v1/devices/{id}
pub async fn delete_device(
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    match sqlx::query("DELETE FROM devices WHERE id::text = $1")
        .bind(id.trim())
        .execute(&state.db_pool)
        .await
    {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}