use rumqttc::{AsyncClient, Event, MqttOptions, Packet, QoS};
use serde_json::{json, Value as JsonValue};
use std::sync::Arc;
use std::time::Duration;
use tiberius::Query;
use uuid::Uuid;

use crate::AppState;

pub async fn init_mqtt(state: Arc<AppState>) {
    let mqtt_host = std::env::var("MQTT_HOST").unwrap_or_else(|_| "localhost".to_string());
    let mqtt_port: u16 = std::env::var("MQTT_PORT")
        .unwrap_or_else(|_| "1883".to_string())
        .parse()
        .unwrap_or(1883);

    let mut mqttoptions = MqttOptions::new("rust_backend_service", mqtt_host, mqtt_port);
    mqttoptions.set_keep_alive(Duration::from_secs(10));

    let (client, mut eventloop) = AsyncClient::new(mqttoptions, 10);

    // Subscribe nhận dữ liệu telemetry & state ACK từ toàn bộ thiết bị
    let _ = client
        .subscribe("smarthome/devices/+/telemetry", QoS::AtMostOnce)
        .await;
    let _ = client
        .subscribe("smarthome/devices/+/state", QoS::AtMostOnce)
        .await;

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
                Ok(_) => {}
                Err(e) => {
                    eprintln!("[MQTT] Connection error: {:?}", e);
                    tokio::time::sleep(Duration::from_secs(3)).await;
                }
            }
        }
    });
}

async fn process_mqtt_message(state: &Arc<AppState>, topic: &str, payload: &str) {
    let parts: Vec<&str> = topic.split('/').collect();
    if parts.len() < 4 {
        return;
    }

    let device_id_str = parts[2];
    let message_type = parts[3]; // "telemetry" hoặc "state"

    let device_id = match Uuid::parse_str(device_id_str) {
        Ok(id) => id,
        Err(_) => return,
    };

    if message_type == "telemetry" {
        // 1. Luồng telemetry: Ghi vào SQL Server & Broadcast WebSocket
        if let Ok(parsed) = serde_json::from_str::<JsonValue>(payload) {
            if let Ok(mut conn) = state.db_pool.get().await {
                if let Some(temp) = parsed.get("temp").and_then(|v| v.as_f64()) {
                    let mut q = Query::new(
                        r#"
                        INSERT INTO dbo.sensor_data ([time], device_id, sensor_type, [value])
                        VALUES (SYSDATETIMEOFFSET(), @P1, N'temperature', @P2)
                        "#,
                    );
                    q.bind(device_id);
                    q.bind(temp);
                    let _ = q.execute(&mut conn).await;

                    // Kích hoạt kiểm tra luật tự động hóa theo nhiệt độ
                    evaluate_automation_rules(state, device_id, temp).await;
                }

                if let Some(hum) = parsed.get("humidity").and_then(|v| v.as_f64()) {
                    let mut q = Query::new(
                        r#"
                        INSERT INTO dbo.sensor_data ([time], device_id, sensor_type, [value])
                        VALUES (SYSDATETIMEOFFSET(), @P1, N'humidity', @P2)
                        "#,
                    );
                    q.bind(device_id);
                    q.bind(hum);
                    let _ = q.execute(&mut conn).await;
                }
            }

            // Gửi sự kiện WebSocket
            let event = json!({
                "type": "SENSOR_TELEMETRY_UPDATE",
                "event_type": "SENSOR_TELEMETRY_UPDATE",
                "device_id": device_id,
                "data": parsed
            })
            .to_string();

            let _ = state.tx.send(event);
        }
    } else if message_type == "state" {
        // 2. Luồng state ACK: Cập nhật SQL Server & Broadcast WebSocket
        if let Ok(parsed) = serde_json::from_str::<JsonValue>(payload) {
            let state_json_str = parsed.to_string();

            if let Ok(mut conn) = state.db_pool.get().await {
                let mut q = Query::new(
                    r#"
                    UPDATE dbo.devices
                    SET current_state = @P1, status = N'ONLINE', last_seen = SYSDATETIMEOFFSET()
                    WHERE id = @P2
                    "#,
                );
                q.bind(&state_json_str);
                q.bind(device_id);
                let _ = q.execute(&mut conn).await;
            }

            // Broadcast sự kiện trạng thái mới cho toàn bộ Client
            let event = json!({
                "type": "DEVICE_STATE_UPDATED",
                "event_type": "DEVICE_STATE_UPDATED",
                "device_id": device_id,
                "state": parsed
            })
            .to_string();

            let _ = state.tx.send(event);
        }
    }
}

/// Đánh giá các kịch bản tự động hóa khi có dữ liệu cảm biến mới
pub async fn evaluate_automation_rules(
    state: &Arc<AppState>,
    sensor_device_id: Uuid,
    sensor_value: f64,
) {
    let Ok(mut conn) = state.db_pool.get().await else {
        return;
    };

    let mut q = Query::new(
        r#"
        SELECT action_device_id, action_payload, condition_type, trigger_value
        FROM dbo.automations
        WHERE trigger_device_id = @P1 AND is_active = 1
        "#,
    );
    q.bind(sensor_device_id);

    let rows = match q.query(&mut conn).await {
        Ok(stream) => stream.into_first_result().await.unwrap_or_default(),
        Err(_) => return,
    };

    for row in rows {
        let Some(action_device_id) = row.get::<Uuid, _>("action_device_id") else {
            continue;
        };
        let payload_raw = row.get::<&str, _>("action_payload").unwrap_or("{}");
        let action_payload: JsonValue =
            serde_json::from_str(payload_raw).unwrap_or_else(|_| json!(payload_raw));

        let condition_type = row.get::<&str, _>("condition_type").unwrap_or("");
        let trigger_value = row.get::<f64, _>("trigger_value").unwrap_or(0.0);

        let is_triggered = match condition_type {
            "GREATER_THAN" | ">" => sensor_value > trigger_value,
            "LESS_THAN" | "<" => sensor_value < trigger_value,
            "EQUALS" | "==" => (sensor_value - trigger_value).abs() < f64::EPSILON,
            _ => false,
        };

        if is_triggered {
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