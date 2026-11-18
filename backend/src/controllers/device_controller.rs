use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use rumqttc::QoS;
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::Row;
use std::collections::HashSet;
use std::sync::Arc;
use uuid::Uuid;

use crate::controllers::user_controller::{ensure_owner_or_admin, resolve_tenant_id};
use crate::models::user::Claims;
use crate::AppState;

#[derive(Deserialize)]
pub struct CreateDevicePayload {
    pub name: String,
    pub device_type: Option<String>,
    pub mqtt_topic: String,
    pub room_id: Option<String>,
}

#[derive(Deserialize)]
pub struct UpdateDevicePayload {
    pub name: Option<String>,
    pub device_type: Option<String>,
    pub mqtt_topic: Option<String>,
    pub room_id: Option<String>,
}

#[derive(Deserialize)]
pub struct ControlDevicePayload {
    pub action: Option<String>,
    pub is_on: Option<bool>,
}

/// Chuyển ràng buộc unique mqtt_topic từ toàn hệ thống sang theo từng Chủ nhà (owner_id)
async fn ensure_device_tenant_index(pool: &sqlx::PgPool) {
    let _ = sqlx::query("ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_mqtt_topic_key")
        .execute(pool)
        .await;
    let _ = sqlx::query("DROP INDEX IF EXISTS devices_mqtt_topic_key")
        .execute(pool)
        .await;
    let _ = sqlx::query(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_owner_mqtt_topic ON devices (owner_id, LOWER(mqtt_topic))",
    )
    .execute(pool)
    .await;
}

// GET /api/v1/devices
pub async fn get_devices(
    claims: Claims,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let query = r#"
        SELECT
            d.id,
            d.name,
            d.device_type,
            d.mqtt_topic,
            d.room_id,
            r.name AS room_name,
            COALESCE(d.is_on, false) AS is_on
        FROM devices d
        LEFT JOIN rooms r ON d.room_id = r.id
        LEFT JOIN houses h ON r.house_id = h.id
        WHERE d.owner_id = $1 OR h.owner_id = $1
        ORDER BY d.name ASC
    "#;

    match sqlx::query(query)
        .bind(tenant_id)
        .fetch_all(&state.db_pool)
        .await
    {
        Ok(rows) => {
            let list: Vec<Value> = rows
                .into_iter()
                .map(|row| {
                    let id: Uuid = row.get("id");
                    let name: String = row.get("name");
                    let device_type: String = row
                        .try_get("device_type")
                        .unwrap_or_else(|_| "switch".to_string());
                    let mqtt_topic: String = row.try_get("mqtt_topic").unwrap_or_default();
                    let room_id: Option<Uuid> = row.try_get("room_id").unwrap_or(None);
                    let room_name: Option<String> = row.try_get("room_name").unwrap_or(None);
                    let is_on: bool = row.try_get("is_on").unwrap_or(false);

                    json!({
                        "id": id.to_string(),
                        "name": name,
                        "device_type": device_type,
                        "mqtt_topic": mqtt_topic,
                        "room_id": room_id.map(|u| u.to_string()),
                        "room_name": room_name,
                        "is_on": is_on,
                        "status": if is_on { "ON" } else { "OFF" }
                    })
                })
                .collect();

            (StatusCode::OK, Json(json!(list))).into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi truy vấn thiết bị: {}", e) })),
        )
            .into_response(),
    }
}

// POST /api/v1/devices
pub async fn create_device(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateDevicePayload>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    ensure_device_tenant_index(&state.db_pool).await;

    let name = payload.name.trim().to_string();
    let mqtt_topic = payload.mqtt_topic.trim().to_string();
    if name.is_empty() || mqtt_topic.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Tên thiết bị và MQTT Topic không được để trống" })),
        )
            .into_response();
    }

    // Kiểm tra trùng MQTT Topic trong phạm vi ngôi nhà của Chủ nhà hiện tại
    let dup_check = sqlx::query(
        "SELECT id FROM devices WHERE owner_id = $1 AND LOWER(mqtt_topic) = LOWER($2) LIMIT 1",
    )
    .bind(tenant_id)
    .bind(&mqtt_topic)
    .fetch_optional(&state.db_pool)
    .await
    .unwrap_or(None);

    if dup_check.is_some() {
        return (
            StatusCode::CONFLICT,
            Json(json!({ "error": "MQTT Topic này đã tồn tại trong ngôi nhà của bạn" })),
        )
            .into_response();
    }

    let device_type = payload
        .device_type
        .unwrap_or_else(|| "switch".to_string())
        .trim()
        .to_string();

    let room_uuid: Option<Uuid> = match payload.room_id.filter(|s| !s.trim().is_empty()) {
        Some(rid) => {
            let Ok(parsed) = Uuid::parse_str(rid.trim()) else {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({ "error": "ID phòng không hợp lệ" })),
                )
                    .into_response();
            };

            let valid_room = sqlx::query(
                "SELECT r.id FROM rooms r INNER JOIN houses h ON r.house_id = h.id WHERE r.id = $1 AND h.owner_id = $2",
            )
            .bind(parsed)
            .bind(tenant_id)
            .fetch_optional(&state.db_pool)
            .await
            .unwrap_or(None);

            if valid_room.is_none() {
                return (
                    StatusCode::FORBIDDEN,
                    Json(json!({ "error": "Phòng không thuộc quyền quản lý của bạn" })),
                )
                    .into_response();
            }
            Some(parsed)
        }
        None => None,
    };

    let device_id = Uuid::new_v4();

    match sqlx::query(
        "INSERT INTO devices (id, name, device_type, mqtt_topic, room_id, owner_id, is_on)
         VALUES ($1, $2, $3, $4, $5, $6, false)",
    )
    .bind(device_id)
    .bind(&name)
    .bind(&device_type)
    .bind(&mqtt_topic)
    .bind(room_uuid)
    .bind(tenant_id)
    .execute(&state.db_pool)
    .await
    {
        Ok(_) => (
            StatusCode::CREATED,
            Json(json!({
                "id": device_id.to_string(),
                "name": name,
                "device_type": device_type,
                "mqtt_topic": mqtt_topic,
                "room_id": room_uuid.map(|u| u.to_string()),
                "is_on": false
            })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Không thể tạo thiết bị: {}", e) })),
        )
            .into_response(),
    }
}

// PUT /api/v1/devices/{id}
pub async fn update_device(
    claims: Claims,
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<UpdateDevicePayload>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    ensure_device_tenant_index(&state.db_pool).await;

    let Ok(dev_uuid) = Uuid::parse_str(&id) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID thiết bị không hợp lệ" })),
        )
            .into_response();
    };

    let current = sqlx::query(
        "SELECT d.name, d.device_type, d.mqtt_topic, d.room_id
         FROM devices d
         LEFT JOIN rooms r ON d.room_id = r.id
         LEFT JOIN houses h ON r.house_id = h.id
         WHERE d.id = $1 AND (d.owner_id = $2 OR h.owner_id = $2)",
    )
    .bind(dev_uuid)
    .bind(tenant_id)
    .fetch_optional(&state.db_pool)
    .await;

    let row = match current {
        Ok(Some(r)) => r,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({ "error": "Không tìm thấy thiết bị thuộc quyền quản lý của bạn" })),
            )
                .into_response();
        }
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let old_name: String = row.get("name");
    let old_type: String = row.get("device_type");
    let old_topic: String = row.get("mqtt_topic");

    let new_name = payload
        .name
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or(old_name);
    let new_type = payload
        .device_type
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or(old_type);
    let new_topic = payload
        .mqtt_topic
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or(old_topic);

    let new_room_id: Option<Uuid> = match payload.room_id {
        Some(ref s) if s.trim().is_empty() => None,
        Some(ref s) => Uuid::parse_str(s.trim()).ok(),
        None => row.try_get("room_id").unwrap_or(None),
    };

    match sqlx::query(
        "UPDATE devices SET name = $1, device_type = $2, mqtt_topic = $3, room_id = $4, owner_id = $5 WHERE id = $6",
    )
    .bind(&new_name)
    .bind(&new_type)
    .bind(&new_topic)
    .bind(new_room_id)
    .bind(tenant_id)
    .bind(dev_uuid)
    .execute(&state.db_pool)
    .await
    {
        Ok(_) => (
            StatusCode::OK,
            Json(json!({ "message": "Đã cập nhật thiết bị" })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}

// POST /api/v1/devices/{id}/control (Cả Owner, Admin, Member đều bật/tắt được thiết bị trong nhà mình)
pub async fn control_device(
    claims: Claims,
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ControlDevicePayload>,
) -> impl IntoResponse {
    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let Ok(dev_uuid) = Uuid::parse_str(&id) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID thiết bị không hợp lệ" })),
        )
            .into_response();
    };

    let next_state = payload.is_on.unwrap_or_else(|| {
        payload
            .action
            .as_deref()
            .map(|a| a.eq_ignore_ascii_case("ON"))
            .unwrap_or(false)
    });

    let target_row = sqlx::query(
        "SELECT d.id, d.mqtt_topic
         FROM devices d
         LEFT JOIN rooms r ON d.room_id = r.id
         LEFT JOIN houses h ON r.house_id = h.id
         WHERE d.id = $1 AND (d.owner_id = $2 OR h.owner_id = $2)",
    )
    .bind(dev_uuid)
    .bind(tenant_id)
    .fetch_optional(&state.db_pool)
    .await;

    let mqtt_topic: String = match target_row {
        Ok(Some(row)) => row.try_get("mqtt_topic").unwrap_or_default(),
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({ "error": "Không tìm thấy thiết bị trong nhà của bạn" })),
            )
                .into_response();
        }
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    if let Err(e) = sqlx::query("UPDATE devices SET is_on = $1 WHERE id = $2")
        .bind(next_state)
        .bind(dev_uuid)
        .execute(&state.db_pool)
        .await
    {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response();
    }

    // Gửi lệnh điều khiển qua MQTT Broker xuống ESP32/Wokwi
    let cmd = if next_state { "ON" } else { "OFF" };
    if !mqtt_topic.trim().is_empty() {
        let _ = state
            .mqtt_client
            .publish(&mqtt_topic, QoS::AtMostOnce, false, cmd.as_bytes())
            .await;
        let ctrl_topic = format!("{}/control", mqtt_topic.trim_end_matches('/'));
        let _ = state
            .mqtt_client
            .publish(&ctrl_topic, QoS::AtMostOnce, false, cmd.as_bytes())
            .await;
    }

    // Phát sự kiện WebSocket cập nhật trạng thái thiết bị tức thì
    let ws_msg = json!({
        "type": "DEVICE_UPDATE",
        "data": {
            "id": dev_uuid.to_string(),
            "mqtt_topic": mqtt_topic,
            "is_on": next_state,
            "status": cmd
        }
    });
    if let Ok(text) = serde_json::to_string(&ws_msg) {
        let _ = state.tx.send(text);
    }

    (
        StatusCode::OK,
        Json(json!({
            "id": dev_uuid.to_string(),
            "is_on": next_state,
            "status": cmd
        })),
    )
        .into_response()
}

// DELETE /api/v1/devices/{id}
pub async fn delete_device(
    claims: Claims,
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let Ok(dev_uuid) = Uuid::parse_str(&id) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID thiết bị không hợp lệ" })),
        )
            .into_response();
    };

    match sqlx::query(
        "DELETE FROM devices d
         USING (
             SELECT d2.id FROM devices d2
             LEFT JOIN rooms r ON d2.room_id = r.id
             LEFT JOIN houses h ON r.house_id = h.id
             WHERE d2.id = $1 AND (d2.owner_id = $2 OR h.owner_id = $2)
         ) sub
         WHERE d.id = sub.id",
    )
    .bind(dev_uuid)
    .bind(tenant_id)
    .execute(&state.db_pool)
    .await
    {
        Ok(res) if res.rows_affected() > 0 => StatusCode::NO_CONTENT.into_response(),
        Ok(_) => (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Không tìm thấy thiết bị trong nhà của bạn" })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}

// GET /api/v1/devices/discover
pub async fn discover_devices(
    _claims: Claims,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let mut seen_topics = HashSet::new();
    let mut discovered: Vec<Value> = Vec::new();

    // 1. Lấy các thiết bị mới vừa phát tín hiệu qua topic MQTT `smarthome/discovery`
    {
        let map = state.discovered_devices.read().await;
        for (topic, item) in map.iter() {
            let clean_topic = topic.trim().to_string();
            if clean_topic.is_empty() || !seen_topics.insert(clean_topic.to_lowercase()) {
                continue;
            }
            let name = item
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or(&clean_topic);
            let device_type = item
                .get("device_type")
                .and_then(|v| v.as_str())
                .unwrap_or("switch");

            discovered.push(json!({
                "id": Uuid::new_v4().to_string(),
                "name": name,
                "device_type": device_type,
                "mqtt_topic": clean_topic,
                "is_on": false
            }));
        }
    }

    // 2. Lấy thêm các thiết bị mẫu/chưa gán chủ sở hữu trong bảng devices (owner_id IS NULL)
    let query = r#"
        SELECT
            id,
            name,
            COALESCE(device_type, 'switch') AS device_type,
            COALESCE(mqtt_topic, '') AS mqtt_topic,
            COALESCE(is_on, false) AS is_on
        FROM devices
        WHERE owner_id IS NULL
        ORDER BY name ASC
    "#;

    if let Ok(rows) = sqlx::query(query).fetch_all(&state.db_pool).await {
        for row in rows {
            let mqtt_topic: String = row.try_get("mqtt_topic").unwrap_or_default();
            let clean_topic = mqtt_topic.trim().to_string();
            if clean_topic.is_empty() || !seen_topics.insert(clean_topic.to_lowercase()) {
                continue;
            }

            let id: Uuid = row.get("id");
            let name: String = row.get("name");
            let device_type: String = row
                .try_get("device_type")
                .unwrap_or_else(|_| "switch".to_string());
            let is_on: bool = row.try_get("is_on").unwrap_or(false);

            discovered.push(json!({
                "id": id.to_string(),
                "name": name,
                "device_type": device_type,
                "mqtt_topic": clean_topic,
                "is_on": is_on
            }));
        }
    }

    (StatusCode::OK, Json(json!(discovered))).into_response()
}