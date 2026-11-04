use rumqttc::{AsyncClient, MqttOptions, Event, Packet, QoS};
use std::sync::Arc;
use std::time::Duration;
use serde_json::json;
use serde_json::Value as JsonValue;
use uuid::Uuid;
use chrono::Utc;
use crate::ws::handler::AppState;

pub async fn init_mqtt(state: Arc<AppState>) {
    let mut mqttoptions = MqttOptions::new("rust_backend_service", "localhost", 1883);
    mqttoptions.set_keep_alive(Duration::from_secs(10));

    let (client, mut eventloop) = AsyncClient::new(mqttoptions, 10);

    // Subscribe nhận dữ liệu telemetry & state ACK từ toàn bộ thiết bị
    client.subscribe("smarthome/devices/+/telemetry", QoS::AtMostOnce).await.unwrap();
    client.subscribe("smarthome/devices/+/state", QoS::AtMostOnce).await.unwrap();

    let state_clone = state.clone();

    // Spawn Background Async Worker
    tokio::spawn(async move {
        loop {
            match eventloop.poll().await {
                Ok(Event::Incoming(Packet::Publish(publish))) => {
                    let topic = publish.topic.clone();
                    if let Ok(payload_str) = String::from_utf8(publish.payload.to_vec()) {
                        process_mqtt_message(&state_clone, &topic, &payload_str).await;
                    }
                }
                Ok(_) => {},
                Err(e) => {
                    eprintln!("⚠️ [MQTT] Connection error: {:?}", e);
                    tokio::time::sleep(Duration::from_secs(3)).await;
                }
            }
        }
    });

    // Lưu trữ MQTT Client vào AppState để dùng cho API điều khiển
    // (Lưu ý: MqttClient được truyền sẵn qua state)
}

async fn process_mqtt_message(state: &Arc<AppState>, topic: &str, payload: &str) {
    let parts: Vec<&str> = topic.split('/').collect();
    if parts.len() < 4 { return; }

    let device_id_str = parts[2];
    let message_type = parts[3]; // "telemetry" hoặc "state"

    let device_id = match uuid::Uuid::parse_str(device_id_str) {
        Ok(id) => id,
        Err(_) => return,
    };

    if message_type == "telemetry" {
        // 1. Luồng telemetry: Ghi vào TimescaleDB & Broadcast WebSocket (Sơ đồ 3.4)
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(payload) {
            let time = Utc::now();
            
            if let Some(temp) = parsed.get("temp").and_then(|v| v.as_f64()) {
                let _ = sqlx::query("INSERT INTO sensor_data (time, device_id, sensor_type, value) VALUES ($1, $2, $3, $4)")
                    .bind(time).bind(device_id).bind("temperature").bind(temp)
                    .execute(&state.db_pool).await;
            }

            if let Some(hum) = parsed.get("humidity").and_then(|v| v.as_f64()) {
                let _ = sqlx::query("INSERT INTO sensor_data (time, device_id, sensor_type, value) VALUES ($1, $2, $3, $4)")
                    .bind(time).bind(device_id).bind("humidity").bind(hum)
                    .execute(&state.db_pool).await;
            }

            // Gửi sự kiện WebSocket
            let event = json!({
                "event_type": "SENSOR_TELEMETRY_UPDATE",
                "device_id": device_id,
                "data": parsed
            }).to_string();

            let _ = state.tx_ws.send(event);
        }
    } else if message_type == "state" {
        // 2. Luồng state ACK: Cập nhật PostgreSQL & Broadcast WebSocket (Sơ đồ 3.3)
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(payload) {
            let _ = sqlx::query("UPDATE devices SET current_state = $1, status = 'ONLINE', last_seen = NOW() WHERE id = $2")
                .bind(&parsed)
                .bind(device_id)
                .execute(&state.db_pool)
                .await;

            // Broadcast sự kiện trạng thái mới cho toàn bộ Client
            let event = json!({
                "event_type": "DEVICE_STATE_UPDATED",
                "device_id": device_id,
                "state": parsed
            }).to_string();

            let _ = state.tx_ws.send(event);
        }
    }
}

/// Đánh giá các kịch bản tự động hóa khi có dữ liệu cảm biến mới
pub async fn evaluate_automation_rules(
    state: &Arc<AppState>,
    sensor_device_id: Uuid,
    sensor_value: f64,
) {
    let rules = sqlx::query(
        r#"
        SELECT action_device_id, action_payload, condition_type, trigger_value 
        FROM automations 
        WHERE trigger_device_id = $1 AND is_active = TRUE
        "#,
    )
    .bind(sensor_device_id)
    .fetch_all(&state.db_pool)
    .await;

    if let Ok(rows) = rules {
        for row in rows {
            use sqlx::Row;
            let action_device_id: Uuid = row.get("action_device_id");
            let action_payload: JsonValue = row.get("action_payload");
            let condition_type: String = row.get("condition_type");
            let trigger_value: f64 = row.get("trigger_value");

            let is_triggered = match condition_type.as_str() {
                "GREATER_THAN" => sensor_value > trigger_value,
                "LESS_THAN" => sensor_value < trigger_value,
                "EQUALS" => (sensor_value - trigger_value).abs() < f64::EPSILON,
                _ => false,
            };

            if is_triggered {
                // Tự động kích hoạt thiết bị bằng lệnh MQTT
                let topic = format!("smarthome/devices/{}/command", action_device_id);
                let payload_bytes = action_payload.to_string().into_bytes();

                let _ = state
                    .mqtt_client
                    .publish(topic, QoS::AtLeastOnce, false, payload_bytes)
                    .await;

                println!(
                    "⚡ [Automation Engine] Triggered action for device {} with payload {}",
                    action_device_id, action_payload
                );
            }
        }
    }
}