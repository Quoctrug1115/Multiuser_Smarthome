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

// POST /api/v1/devices/{id}/control
pub async fn control_device(
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ControlDeviceDto>,
) -> impl IntoResponse {
    let topic = format!("smarthome/devices/{}/command", id);
    
    // Lấy lệnh "ON" / "OFF" từ payload
    let cmd_str = if let Some(p) = payload.power {
        p
    } else if let Some(c) = payload.command {
        if let Some(s) = c.as_str() { s.to_string() } else { c.to_string() }
    } else {
        "TOGGLE".to_string()
    };

    // Bắn tin nhắn xuống MQTT Broker (bảo đảm ESP32 Wokwi nhận ngay)
    let _ = state
        .mqtt_client
        .publish(topic, QoS::AtLeastOnce, false, cmd_str.as_bytes())
        .await;

    // Cập nhật trạng thái vào PostgreSQL nếu có UUID hợp lệ
    if let Ok(dev_uuid) = Uuid::parse_str(&id) {
        let is_on = cmd_str == "ON";
        let pool = state.db_pool.clone();
        tokio::spawn(async move {
            let _ = sqlx::query("UPDATE devices SET status = $1 WHERE id = $2")
                .bind(is_on)
                .bind(dev_uuid)
                .execute(&pool)
                .await;
        });
    }

    (StatusCode::ACCEPTED, Json(serde_json::json!({
        "status": "success",
        "message": format!("Đã gửi lệnh {} tới thiết bị {}", cmd_str, id)
    }))).into_response()
}