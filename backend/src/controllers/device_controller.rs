use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use rumqttc::QoS;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::Arc;
use tiberius::Query;
use uuid::Uuid;

use crate::controllers::user_controller::{ensure_owner_or_admin, resolve_tenant_id};
use crate::models::user::Claims;
use crate::{AppState, SqlPool};

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

/// Đảm bảo chỉ mục duy nhất (owner_id, mqtt_topic) trên SQL Server
async fn ensure_device_tenant_index(pool: &SqlPool) {
    let Ok(mut conn) = pool.get().await else {
        return;
    };

    let sql = r#"
        IF NOT EXISTS (
            SELECT 1 FROM sys.indexes
            WHERE name = N'idx_devices_owner_mqtt_topic'
              AND object_id = OBJECT_ID(N'dbo.devices')
        )
        BEGIN
            CREATE UNIQUE INDEX idx_devices_owner_mqtt_topic
                ON dbo.devices (owner_id, mqtt_topic)
                WHERE owner_id IS NOT NULL;
        END
    "#;

    let _ = conn.execute(sql, &[]).await;
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

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    let sql = r#"
        SELECT
            COALESCE(d.is_online, CAST(1 AS BIT)) AS is_online,
            d.id,
            d.name,
            COALESCE(d.device_type, N'switch') AS device_type,
            COALESCE(d.mqtt_topic, N'') AS mqtt_topic,
            d.room_id,
            r.name AS room_name,
            COALESCE(d.is_on, CAST(0 AS BIT)) AS is_on
        FROM dbo.devices d
        LEFT JOIN dbo.rooms r ON d.room_id = r.id
        LEFT JOIN dbo.houses h ON r.house_id = h.id
        WHERE d.owner_id = @P1 OR h.owner_id = @P1
        ORDER BY d.name ASC
    "#;

    let mut query = Query::new(sql);
    query.bind(tenant_id);

    let response = match query.query(&mut conn).await {
        Ok(stream) => {
            let rows = stream.into_first_result().await.unwrap_or_default();
            let list: Vec<Value> = rows
                .into_iter()
                .filter_map(|row| {
                    let id = row.get::<Uuid, _>("id")?;
                    let name = row.get::<&str, _>("name").unwrap_or("").to_string();
                    let device_type = row
                        .get::<&str, _>("device_type")
                        .unwrap_or("switch")
                        .to_string();
                    let mqtt_topic = row.get::<&str, _>("mqtt_topic").unwrap_or("").to_string();
                    let room_id: Option<Uuid> = row.get::<Uuid, _>("room_id");
                    let room_name = row.get::<&str, _>("room_name").map(|s| s.to_string());
                    let is_on = row.get::<bool, _>("is_on").unwrap_or(false);

                    Some(json!({
                        "id": id.to_string(),
                        "name": name,
                        "device_type": device_type,
                        "mqtt_topic": mqtt_topic,
                        "room_id": room_id.map(|u| u.to_string()),
                        "room_name": room_name,
                        "is_on": is_on,
                        "status": if is_on { "ON" } else { "OFF" },
                        "is_online": row.get::<bool, _>("is_online").unwrap_or(true),
                    }))
                })
                .collect();

            (StatusCode::OK, Json(json!(list))).into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi truy vấn thiết bị: {}", e) })),
        )
            .into_response(),
    };
    response
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

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    // Kiểm tra trùng MQTT Topic trong phạm vi ngôi nhà của Chủ nhà hiện tại
    let mut dup_q = Query::new(
        "SELECT TOP 1 id FROM dbo.devices WHERE owner_id = @P1 AND LOWER(mqtt_topic) = LOWER(@P2)",
    );
    dup_q.bind(tenant_id);
    dup_q.bind(&mqtt_topic);

    if let Ok(stream) = dup_q.query(&mut conn).await {
        if let Ok(Some(_)) = stream.into_row().await {
            return (
                StatusCode::CONFLICT,
                Json(json!({ "error": "MQTT Topic này đã tồn tại trong ngôi nhà của bạn" })),
            )
                .into_response();
        }
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

            let mut room_q = Query::new(
                "SELECT TOP 1 r.id FROM dbo.rooms r INNER JOIN dbo.houses h ON r.house_id = h.id WHERE r.id = @P1 AND h.owner_id = @P2",
            );
            room_q.bind(parsed);
            room_q.bind(tenant_id);

            let is_valid = match room_q.query(&mut conn).await {
                Ok(stream) => stream.into_row().await.ok().flatten().is_some(),
                Err(_) => false,
            };

            if !is_valid {
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

    let mut insert_q = Query::new(
        r#"
        INSERT INTO dbo.devices (id, name, device_type, mqtt_topic, room_id, owner_id, status, is_on)
        VALUES (@P1, @P2, @P3, @P4, @P5, @P6, N'OFF', 0)
        "#,
    );
    insert_q.bind(device_id);
    insert_q.bind(&name);
    insert_q.bind(&device_type);
    insert_q.bind(&mqtt_topic);
    insert_q.bind(room_uuid);
    insert_q.bind(tenant_id);

    match insert_q.execute(&mut conn).await {
        Ok(_) => (
            StatusCode::CREATED,
            Json(json!({
                "id": device_id.to_string(),
                "name": name,
                "device_type": device_type,
                "mqtt_topic": mqtt_topic,
                "room_id": room_uuid.map(|u| u.to_string()),
                "is_on": false,
                "status": "OFF"
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

    let Ok(dev_uuid) = Uuid::parse_str(id.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID thiết bị không hợp lệ" })),
        )
            .into_response();
    };

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    let mut cur_q = Query::new(
        r#"
        SELECT TOP 1 d.name, d.device_type, d.mqtt_topic, d.room_id
        FROM dbo.devices d
        LEFT JOIN dbo.rooms r ON d.room_id = r.id
        LEFT JOIN dbo.houses h ON r.house_id = h.id
        WHERE d.id = @P1 AND (d.owner_id = @P2 OR h.owner_id = @P2)
        "#,
    );
    cur_q.bind(dev_uuid);
    cur_q.bind(tenant_id);

    let row = match cur_q.query(&mut conn).await {
        Ok(stream) => match stream.into_row().await {
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
        },
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let old_name = row.get::<&str, _>("name").unwrap_or("").to_string();
    let old_type = row
        .get::<&str, _>("device_type")
        .unwrap_or("switch")
        .to_string();
    let old_topic = row.get::<&str, _>("mqtt_topic").unwrap_or("").to_string();

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
        None => row.get::<Uuid, _>("room_id"),
    };

    let mut upd_q = Query::new(
        r#"
        UPDATE dbo.devices
        SET name = @P1, device_type = @P2, mqtt_topic = @P3, room_id = @P4, owner_id = @P5
        WHERE id = @P6
        "#,
    );
    upd_q.bind(&new_name);
    upd_q.bind(&new_type);
    upd_q.bind(&new_topic);
    upd_q.bind(new_room_id);
    upd_q.bind(tenant_id);
    upd_q.bind(dev_uuid);

    match upd_q.execute(&mut conn).await {
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

// POST /api/v1/devices/{id}/control
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

    let Ok(dev_uuid) = Uuid::parse_str(id.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID thiết bị không hợp lệ" })),
        )
            .into_response();
    };

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    let next_state = payload.is_on.unwrap_or_else(|| {
        payload
            .action
            .as_deref()
            .map(|a| a.eq_ignore_ascii_case("ON"))
            .unwrap_or(false)
    });

    let mut target_q = Query::new(
        r#"
        SELECT TOP 1 d.id, d.mqtt_topic
        FROM dbo.devices d
        LEFT JOIN dbo.rooms r ON d.room_id = r.id
        LEFT JOIN dbo.houses h ON r.house_id = h.id
        WHERE d.id = @P1 AND (d.owner_id = @P2 OR h.owner_id = @P2)
        "#,
    );
    target_q.bind(dev_uuid);
    target_q.bind(tenant_id);

    let mqtt_topic: String = match target_q.query(&mut conn).await {
        Ok(stream) => match stream.into_row().await {
            Ok(Some(row)) => row.get::<&str, _>("mqtt_topic").unwrap_or("").to_string(),
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
        },
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let cmd = if next_state { "ON" } else { "OFF" };

    let mut upd_q = Query::new(
        "UPDATE dbo.devices SET is_on = @P1, status = @P2, last_seen = SYSDATETIMEOFFSET() WHERE id = @P3",
    );
    upd_q.bind(next_state);
    upd_q.bind(cmd);
    upd_q.bind(dev_uuid);

    if let Err(e) = upd_q.execute(&mut conn).await {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response();
    }

    // Gửi lệnh điều khiển qua MQTT Broker xuống ESP32/Wokwi
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

    let Ok(dev_uuid) = Uuid::parse_str(id.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID thiết bị không hợp lệ" })),
        )
            .into_response();
    };

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    // Kiểm tra thiết bị có thuộc nhà của người dùng trước khi dọn liên kết khóa ngoại
    let mut check_q = Query::new(
        r#"
        SELECT TOP 1 d.id
        FROM dbo.devices d
        LEFT JOIN dbo.rooms r ON d.room_id = r.id
        LEFT JOIN dbo.houses h ON r.house_id = h.id
        WHERE d.id = @P1 AND (d.owner_id = @P2 OR h.owner_id = @P2)
        "#,
    );
    check_q.bind(dev_uuid);
    check_q.bind(tenant_id);

    let exists = match check_q.query(&mut conn).await {
        Ok(stream) => stream.into_row().await.ok().flatten().is_some(),
        Err(_) => false,
    };

    if !exists {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Không tìm thấy thiết bị trong nhà của bạn" })),
        )
            .into_response();
    }

    // Gỡ liên kết ở các bảng có ON DELETE NO ACTION trong SQL Server
    let cleanup_queries = [
        "DELETE FROM dbo.guest_access WHERE device_id = @P1",
        "UPDATE dbo.energy_logs SET device_id = NULL WHERE device_id = @P1",
        "UPDATE dbo.ai_alerts SET device_id = NULL WHERE device_id = @P1",
        "UPDATE dbo.ai_suggestions SET device_id = NULL WHERE device_id = @P1",
        "UPDATE dbo.automations SET trigger_device_id = NULL WHERE trigger_device_id = @P1",
        "UPDATE dbo.automations SET action_device_id = NULL WHERE action_device_id = @P1",
    ];
    for sql in cleanup_queries {
        let mut q = Query::new(sql);
        q.bind(dev_uuid);
        let _ = q.execute(&mut conn).await;
    }

    let mut del_q = Query::new("DELETE FROM dbo.devices WHERE id = @P1");
    del_q.bind(dev_uuid);

    match del_q.execute(&mut conn).await {
        Ok(res) if res.rows_affected().iter().sum::<u64>() > 0 => StatusCode::NO_CONTENT.into_response(),
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

    // 2. Lấy thêm các thiết bị mẫu/chưa gán chủ sở hữu trong bảng dbo.devices (owner_id IS NULL)
    if let Ok(mut conn) = state.db_pool.get().await {
        let sql = r#"
            SELECT
                id,
                name,
                COALESCE(device_type, N'switch') AS device_type,
                COALESCE(mqtt_topic, N'') AS mqtt_topic,
                COALESCE(is_on, CAST(0 AS BIT)) AS is_on
            FROM dbo.devices
            WHERE owner_id IS NULL
            ORDER BY name ASC
        "#;

        if let Ok(stream) = conn.query(sql, &[]).await {
            let rows = stream.into_first_result().await.unwrap_or_default();
            for row in rows {
                let mqtt_topic = row.get::<&str, _>("mqtt_topic").unwrap_or("");
                let clean_topic = mqtt_topic.trim().to_string();
                if clean_topic.is_empty() || !seen_topics.insert(clean_topic.to_lowercase()) {
                    continue;
                }

                let Some(id) = row.get::<Uuid, _>("id") else {
                    continue;
                };
                let name = row.get::<&str, _>("name").unwrap_or("").to_string();
                let device_type = row
                    .get::<&str, _>("device_type")
                    .unwrap_or("switch")
                    .to_string();
                let is_on = row.get::<bool, _>("is_on").unwrap_or(false);

                discovered.push(json!({
                    "id": id.to_string(),
                    "name": name,
                    "device_type": device_type,
                    "mqtt_topic": clean_topic,
                    "is_on": is_on
                }));
            }
        }
    }

    (StatusCode::OK, Json(json!(discovered))).into_response()
}