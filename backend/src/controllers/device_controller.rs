use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde_json::{json, Value};
use sqlx::Row;
use std::sync::Arc;
use uuid::Uuid;

use crate::AppState;

async fn ensure_devices_schema(pool: &sqlx::PgPool) {
    let _ = sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS devices (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            name VARCHAR(150) NOT NULL,
            device_type VARCHAR(50) NOT NULL DEFAULT 'switch',
            mqtt_topic VARCHAR(255) NOT NULL DEFAULT '',
            is_on BOOLEAN NOT NULL DEFAULT FALSE,
            status VARCHAR(20) NOT NULL DEFAULT 'OFF',
            power_watt DOUBLE PRECISION DEFAULT 15.0,
            room_id UUID REFERENCES rooms(id) ON DELETE SET NULL,
            created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
        );
        "#,
    )
    .execute(pool)
    .await;

    let migrations = [
        // Gỡ khóa ngoại ở energy_logs để không lỗi khi xóa thiết bị
        "ALTER TABLE energy_logs DROP CONSTRAINT IF EXISTS energy_logs_device_id_fkey",
        // Bổ sung đầy đủ các cột cần thiết cho bảng devices
        "ALTER TABLE devices ADD COLUMN IF NOT EXISTS device_type VARCHAR(50) DEFAULT 'switch'",
        "ALTER TABLE devices ADD COLUMN IF NOT EXISTS mqtt_topic VARCHAR(255) DEFAULT ''",
        "ALTER TABLE devices ADD COLUMN IF NOT EXISTS is_on BOOLEAN DEFAULT FALSE",
        "ALTER TABLE devices ADD COLUMN IF NOT EXISTS status VARCHAR(20) DEFAULT 'OFF'",
        "ALTER TABLE devices ADD COLUMN IF NOT EXISTS power_watt DOUBLE PRECISION DEFAULT 15.0",
        "ALTER TABLE devices ADD COLUMN IF NOT EXISTS room_id UUID REFERENCES rooms(id) ON DELETE SET NULL",
        // Gỡ ràng buộc NOT NULL ở các cột cũ (nếu có) để tránh lỗi khi thêm thiết bị mới
        "ALTER TABLE devices ALTER COLUMN type DROP NOT NULL",
        "ALTER TABLE devices ALTER COLUMN room DROP NOT NULL",
        "ALTER TABLE devices ALTER COLUMN user_id DROP NOT NULL",
        "UPDATE devices SET is_on = FALSE WHERE is_on IS NULL",
        "UPDATE devices SET status = 'OFF' WHERE status IS NULL",
    ];

    for sql in migrations {
        let _ = sqlx::query(sql).execute(pool).await;
    }
}

fn parse_optional_room_uuid(payload: &Value) -> Option<Uuid> {
    payload
        .get("room_id")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .and_then(|s| Uuid::parse_str(s).ok())
}

// GET /api/v1/devices
pub async fn get_devices(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    ensure_devices_schema(&state.db_pool).await;

    let rows = match sqlx::query(
        r#"
        SELECT d.*, r.name AS room_name
        FROM devices d
        LEFT JOIN rooms r ON d.room_id::text = r.id::text
        "#,
    )
    .fetch_all(&state.db_pool)
    .await
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("❌ [GET DEVICES ERROR]: {:?}", e);
            return (StatusCode::OK, Json(Vec::<Value>::new())).into_response();
        }
    };

    let mut list = Vec::new();
    for row in rows {
        let id = row
            .try_get::<String, _>("id")
            .or_else(|_| row.try_get::<Uuid, _>("id").map(|u| u.to_string()))
            .or_else(|_| row.try_get::<i32, _>("id").map(|i| i.to_string()))
            .unwrap_or_default();

        let name: String = row.try_get("name").unwrap_or_else(|_| "Thiết bị".into());
        let device_type: String = row
            .try_get("device_type")
            .or_else(|_| row.try_get("type"))
            .unwrap_or_else(|_| "switch".into());
        let mqtt_topic: String = row.try_get("mqtt_topic").unwrap_or_default();

        let room_id: Option<String> = row
            .try_get::<Option<Uuid>, _>("room_id")
            .ok()
            .flatten()
            .map(|u| u.to_string())
            .or_else(|| {
                row.try_get::<Option<String>, _>("room_id")
                    .ok()
                    .flatten()
                    .filter(|s| !s.trim().is_empty())
            });

        let room_name: Option<String> = row
            .try_get::<Option<String>, _>("room_name")
            .ok()
            .flatten()
            .filter(|s| !s.trim().is_empty());

        let status_str: String = row.try_get("status").unwrap_or_default();
        let is_on_col: bool = row.try_get::<bool, _>("is_on").unwrap_or(false);
        let is_on = is_on_col
            || matches!(
                status_str.trim().to_uppercase().as_str(),
                "ON" | "TRUE" | "1"
            );

        list.push(json!({
            "id": id,
            "name": name,
            "room_id": room_id,
            "room_name": room_name,
            "device_type": device_type,
            "mqtt_topic": mqtt_topic,
            "is_on": is_on,
            "status": if is_on { "ON" } else { "OFF" }
        }));
    }

    list.sort_by(|a, b| {
        a["name"]
            .as_str()
            .unwrap_or("")
            .cmp(b["name"].as_str().unwrap_or(""))
    });

    (StatusCode::OK, Json(list)).into_response()
}

// POST /api/v1/devices
pub async fn create_device(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<Value>,
) -> impl IntoResponse {
    ensure_devices_schema(&state.db_pool).await;

    let name = payload
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("Thiết bị mới")
        .trim()
        .to_string();
    let device_type = payload
        .get("device_type")
        .and_then(|v| v.as_str())
        .unwrap_or("switch")
        .trim()
        .to_lowercase();
    let mqtt_topic = payload
        .get("mqtt_topic")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    let room_uuid = parse_optional_room_uuid(&payload);
    let is_on = payload
        .get("is_on")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let status = if is_on { "ON" } else { "OFF" };

    let new_uuid = Uuid::new_v4();
    let insert_res = sqlx::query(
        r#"
        INSERT INTO devices (id, name, device_type, mqtt_topic, is_on, status, room_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        "#,
    )
    .bind(new_uuid)
    .bind(&name)
    .bind(&device_type)
    .bind(&mqtt_topic)
    .bind(is_on)
    .bind(status)
    .bind(room_uuid)
    .execute(&state.db_pool)
    .await;

    let final_id = match insert_res {
        Ok(_) => new_uuid.to_string(),
        Err(_) => {
            // Dự phòng nếu cột id trong DB là kiểu SERIAL (số nguyên tự tăng)
            match sqlx::query_scalar::<_, String>(
                r#"
                INSERT INTO devices (name, device_type, mqtt_topic, is_on, status, room_id)
                VALUES ($1, $2, $3, $4, $5, $6)
                RETURNING id::text
                "#,
            )
            .bind(&name)
            .bind(&device_type)
            .bind(&mqtt_topic)
            .bind(is_on)
            .bind(status)
            .bind(room_uuid)
            .fetch_one(&state.db_pool)
            .await
            {
                Ok(id) => id,
                Err(e) => {
                    eprintln!("❌ [CREATE DEVICE ERROR]: {:?}", e);
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(json!({ "error": e.to_string() })),
                    )
                        .into_response();
                }
            }
        }
    };

    println!("✅ [DEVICE CREATED] {} ({})", name, mqtt_topic);

    (
        StatusCode::CREATED,
        Json(json!({
            "id": final_id,
            "name": name,
            "room_id": room_uuid.map(|u| u.to_string()),
            "device_type": device_type,
            "mqtt_topic": mqtt_topic,
            "is_on": is_on,
            "status": status
        })),
    )
        .into_response()
}

// PUT /api/v1/devices/{id}
pub async fn update_device(
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<Value>,
) -> impl IntoResponse {
    ensure_devices_schema(&state.db_pool).await;

    let name = payload
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("Thiết bị")
        .trim()
        .to_string();
    let device_type = payload
        .get("device_type")
        .and_then(|v| v.as_str())
        .unwrap_or("switch")
        .trim()
        .to_lowercase();
    let mqtt_topic = payload
        .get("mqtt_topic")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();

    let has_room_field = payload.get("room_id").is_some();
    let room_uuid = parse_optional_room_uuid(&payload);

    let result = if has_room_field {
        sqlx::query(
            "UPDATE devices SET name = $1, device_type = $2, mqtt_topic = $3, room_id = $4 WHERE id::text = $5",
        )
        .bind(&name)
        .bind(&device_type)
        .bind(&mqtt_topic)
        .bind(room_uuid)
        .bind(id.trim())
        .execute(&state.db_pool)
        .await
    } else {
        sqlx::query(
            "UPDATE devices SET name = $1, device_type = $2, mqtt_topic = $3 WHERE id::text = $4",
        )
        .bind(&name)
        .bind(&device_type)
        .bind(&mqtt_topic)
        .bind(id.trim())
        .execute(&state.db_pool)
        .await
    };

    match result {
        Ok(_) => (
            StatusCode::OK,
            Json(json!({
                "id": id,
                "name": name,
                "room_id": room_uuid.map(|u| u.to_string()),
                "device_type": device_type,
                "mqtt_topic": mqtt_topic
            })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}

// POST /api/v1/devices/{id}/control
pub async fn control_device(
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<Value>,
) -> impl IntoResponse {
    ensure_devices_schema(&state.db_pool).await;

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

    let db_topic: Option<String> =
        sqlx::query_scalar("SELECT mqtt_topic FROM devices WHERE id::text = $1")
            .bind(id.trim())
            .fetch_optional(&state.db_pool)
            .await
            .unwrap_or(None);

    let mqtt_topic = db_topic
        .or_else(|| {
            payload
                .get("mqtt_topic")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        })
        .unwrap_or_else(|| "smarthome/devices/led_phong_khach".to_string());

    let _ = sqlx::query("UPDATE devices SET is_on = $1, status = $2 WHERE id::text = $3")
        .bind(is_on)
        .bind(command)
        .bind(id.trim())
        .execute(&state.db_pool)
        .await;

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
        Json(json!({
            "id": id,
            "is_on": is_on,
            "status": command,
            "mqtt_topic": mqtt_topic
        })),
    )
        .into_response()
}

// DELETE /api/v1/devices/{id}
pub async fn delete_device(
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ensure_devices_schema(&state.db_pool).await;

    let topic_opt: Option<String> =
        sqlx::query_scalar("SELECT mqtt_topic FROM devices WHERE id::text = $1")
            .bind(id.trim())
            .fetch_optional(&state.db_pool)
            .await
            .unwrap_or(None);

    if let Some(topic) = topic_opt {
        let clean_topic = topic.trim();
        if !clean_topic.is_empty() {
            let _ = state
                .mqtt_client
                .publish(clean_topic, rumqttc::QoS::AtMostOnce, false, b"OFF")
                .await;
            let control_topic = format!("{}/control", clean_topic.trim_end_matches('/'));
            let _ = state
                .mqtt_client
                .publish(&control_topic, rumqttc::QoS::AtMostOnce, false, b"OFF")
                .await;
            println!(
                "🛑 [MQTT OFF ON DELETE] ID: {} | Topic: {} -> OFF",
                id, clean_topic
            );
        }
    }

    let _ = sqlx::query("DELETE FROM energy_logs WHERE device_id::text = $1")
        .bind(id.trim())
        .execute(&state.db_pool)
        .await;

    match sqlx::query("DELETE FROM devices WHERE id::text = $1")
        .bind(id.trim())
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

// GET /api/v1/devices/discover
pub async fn discover_wokwi_devices(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    ensure_devices_schema(&state.db_pool).await;

    let _ = state
        .mqtt_client
        .publish(
            "smarthome/discovery/request",
            rumqttc::QoS::AtMostOnce,
            false,
            b"DISCOVER",
        )
        .await;

    tokio::time::sleep(std::time::Duration::from_millis(300)).await;

    // 1. Lấy danh sách mqtt_topic đã lưu trong PostgreSQL để loại bỏ thiết bị trùng
    let existing_topics: Vec<String> =
        sqlx::query_scalar("SELECT COALESCE(mqtt_topic, '') FROM devices")
            .fetch_all(&state.db_pool)
            .await
            .unwrap_or_default();

    // 2. Gom các thiết bị từ RAM + 3 thiết bị chuẩn của mạch Wokwi ESP32
    let mut candidates: Vec<Value> = vec![
        json!({
            "name": "Đèn Phòng Khách (Wokwi)",
            "device_type": "light",
            "mqtt_topic": "smarthome/devices/led_phong_khach",
            "chip": "ESP32 GPIO 2 (LED Vàng)"
        }),
        json!({
            "name": "Quạt Phòng Khách (Wokwi)",
            "device_type": "fan",
            "mqtt_topic": "smarthome/devices/quat_phong_khach",
            "chip": "ESP32 GPIO 4 (LED Xanh)"
        }),
        json!({
            "name": "Cảm Biến Môi Trường (Wokwi)",
            "device_type": "sensor",
            "mqtt_topic": "smarthome/sensors/dht22",
            "chip": "ESP32 DHT22 + LDR + PIR"
        }),
    ];

    let map = state.discovered_devices.read().await;
    for (k, d) in map.iter() {
        let topic = d
            .get("mqtt_topic")
            .and_then(|v| v.as_str())
            .unwrap_or(k.as_str());
        if !candidates
            .iter()
            .any(|c| c["mqtt_topic"].as_str() == Some(topic))
        {
            candidates.push(d.clone());
        }
    }

    // 3. Chỉ trả về những thiết bị chưa được thêm vào Database
    let available: Vec<Value> = candidates
        .into_iter()
        .filter(|d| {
            let topic = d["mqtt_topic"].as_str().unwrap_or("");
            !existing_topics.iter().any(|t| t.trim() == topic)
        })
        .collect();

    (StatusCode::OK, Json(available)).into_response()
}

pub async fn discover_devices(state: State<Arc<AppState>>) -> impl IntoResponse {
    discover_wokwi_devices(state).await
}