use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;
use tiberius::Query;
use uuid::Uuid;
use axum::extract::Path;
use rumqttc::QoS;
use crate::controllers::user_controller::{ensure_owner_or_admin, resolve_tenant_id};
use crate::models::user::Claims;
use crate::{AppState, SqlPool};

#[derive(Deserialize, Default)]
pub struct AnomalyPayload {
    pub device_id: Option<String>,
    pub temperature: Option<f64>,
    pub sensor_id: Option<String>,
}

async fn ensure_ai_alerts_schema(pool: &SqlPool) {
    let Ok(mut conn) = pool.get().await else {
        return;
    };

    let init_queries = [
        r#"
        IF OBJECT_ID(N'dbo.ai_alerts', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.ai_alerts (
                id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
                device_id UNIQUEIDENTIFIER NULL,
                owner_id UNIQUEIDENTIFIER NULL,
                title NVARCHAR(200) NULL DEFAULT N'Cảnh báo AI',
                alert_type NVARCHAR(50) NOT NULL DEFAULT N'ANOMALY',
                severity NVARCHAR(20) NOT NULL DEFAULT N'HIGH',
                message NVARCHAR(MAX) NOT NULL,
                metadata NVARCHAR(MAX) NULL,
                created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
                CONSTRAINT FK_ai_alerts_users FOREIGN KEY (owner_id) REFERENCES dbo.users(id) ON DELETE CASCADE
            );
        END
        "#,
        "IF COL_LENGTH(N'dbo.ai_alerts', N'owner_id') IS NULL ALTER TABLE dbo.ai_alerts ADD owner_id UNIQUEIDENTIFIER NULL",
        "IF COL_LENGTH(N'dbo.ai_alerts', N'title') IS NULL ALTER TABLE dbo.ai_alerts ADD title NVARCHAR(200) NULL DEFAULT N'Cảnh báo AI'",
    ];

    for q in init_queries {
        let _ = conn.execute(q, &[]).await;
    }
}

// GET /api/v1/ai/alerts
pub async fn get_alerts(
    claims: Claims,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ensure_ai_alerts_schema(&state.db_pool).await;

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
        SELECT TOP 30
            CAST(id AS NVARCHAR(36)) AS id,
            COALESCE(alert_type, N'ANOMALY') AS alert_type,
            COALESCE(title, N'Cảnh báo AI') AS title,
            COALESCE(message, N'') AS message,
            COALESCE(severity, N'high') AS severity,
            FORMAT(created_at AT TIME ZONE 'SE Asia Standard Time', 'HH:mm:ss dd/MM') AS created_at
        FROM dbo.ai_alerts
        WHERE owner_id = @P1
        ORDER BY created_at DESC
    "#;

    let mut query = Query::new(sql);
    query.bind(tenant_id);

    let response = match query.query(&mut conn).await {
        Ok(stream) => {
            let rows = stream.into_first_result().await.unwrap_or_default();
            let alerts: Vec<Value> = rows
                .into_iter()
                .map(|row| {
                    let id: String = row
                        .try_get::<&str, _>("id")
                        .ok()
                        .flatten()
                        .unwrap_or_default()
                        .to_string();
                    let alert_type = row
                        .get::<&str, _>("alert_type")
                        .unwrap_or("ANOMALY")
                        .to_string();
                    let title = row
                        .get::<&str, _>("title")
                        .unwrap_or("Cảnh báo AI")
                        .to_string();
                    let message = row.get::<&str, _>("message").unwrap_or("").to_string();
                    let severity = row
                        .get::<&str, _>("severity")
                        .unwrap_or("high")
                        .to_string();
                    let created_at = row.get::<&str, _>("created_at").unwrap_or("").to_string();

                    json!({
                        "id": id,
                        "alert_type": alert_type,
                        "title": title,
                        "message": message,
                        "severity": severity,
                        "created_at": created_at
                    })
                })
                .collect();

            (StatusCode::OK, Json(json!(alerts))).into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi truy vấn cảnh báo AI: {}", e) })),
        )
            .into_response(),
    };
    response
}

// POST /api/v1/ai/simulate-anomaly (Sử dụng thiết bị & chuỗi dữ liệu cảm biến thật)
pub async fn simulate_anomaly(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    payload: Option<Json<AnomalyPayload>>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    ensure_ai_alerts_schema(&state.db_pool).await;

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

    let body = payload.map(|Json(p)| p).unwrap_or_default();
    let requested_dev_id = body
        .device_id
        .as_deref()
        .and_then(|s| Uuid::parse_str(s.trim()).ok());

    // 1. Tìm thiết bị cảm biến THẬT thuộc hộ gia đình của người dùng
    let sensor_info: Option<(Uuid, String, String, Option<String>)> = {
        let mut dev_q = if let Some(dev_uuid) = requested_dev_id {
            let mut q = Query::new(
                r#"
                SELECT TOP 1
                    d.id,
                    d.name,
                    COALESCE(d.mqtt_topic, N'') AS mqtt_topic,
                    r.name AS room_name
                FROM dbo.devices d
                LEFT JOIN dbo.rooms r ON d.room_id = r.id
                LEFT JOIN dbo.houses h ON r.house_id = h.id
                WHERE d.id = @P1
                  AND (d.owner_id = @P2 OR h.owner_id = @P2)
                "#,
            );
            q.bind(dev_uuid);
            q.bind(tenant_id);
            q
        } else {
            let mut q = Query::new(
                r#"
                SELECT TOP 1
                    d.id,
                    d.name,
                    COALESCE(d.mqtt_topic, N'') AS mqtt_topic,
                    r.name AS room_name
                FROM dbo.devices d
                LEFT JOIN dbo.rooms r ON d.room_id = r.id
                LEFT JOIN dbo.houses h ON r.house_id = h.id
                WHERE (d.owner_id = @P1 OR h.owner_id = @P1)
                  AND (
                      LOWER(COALESCE(d.device_type, N'')) IN (N'sensor', N'dht22')
                      OR LOWER(COALESCE(d.mqtt_topic, N'')) LIKE N'%sensor%'
                      OR LOWER(COALESCE(d.mqtt_topic, N'')) LIKE N'%dht%'
                      OR LOWER(COALESCE(d.mqtt_topic, N'')) LIKE N'%telemetry%'
                  )
                ORDER BY d.last_seen DESC, d.created_at ASC
                "#,
            );
            q.bind(tenant_id);
            q
        };

        match dev_q.query(&mut conn).await {
            Ok(stream) => stream
                .into_row()
                .await
                .ok()
                .flatten()
                .and_then(|row| {
                    let id = row.get::<Uuid, _>("id")?;
                    let name = row.get::<&str, _>("name").unwrap_or("Cảm biến").to_string();
                    let topic = row.get::<&str, _>("mqtt_topic").unwrap_or("").to_string();
                    let room = row.get::<&str, _>("room_name").map(|s| s.to_string());
                    Some((id, name, topic, room))
                }),
            Err(_) => None,
        }
    };

    let Some((real_device_id, real_device_name, real_mqtt_topic, real_room_name)) = sensor_info else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": "Ngôi nhà của bạn chưa có thiết bị cảm biến thật nào để mô phỏng. Hãy thêm cảm biến ở tab Phòng & Thiết bị trước."
            })),
        )
            .into_response();
    };

    // 2. Lấy lịch sử 20 mẫu đo THẬT từ dbo.sensor_data của chính cảm biến này
    let history_vals: Vec<f64> = {
        let mut hist_q = Query::new(
            "SELECT TOP 20 [value] FROM dbo.sensor_data WHERE device_id = @P1 ORDER BY [time] DESC",
        );
        hist_q.bind(real_device_id);
        match hist_q.query(&mut conn).await {
            Ok(stream) => stream
                .into_first_result()
                .await
                .unwrap_or_default()
                .into_iter()
                .filter_map(|r| r.get::<f64, _>("value"))
                .collect(),
            Err(_) => Vec::new(),
        }
    };

    // Lấy thêm nhiệt độ live từ cache MQTT (nếu thiết bị đang gửi dữ liệu)
    let live_cached_temp: Option<f64> = {
        let cached = state.latest_sensor.read().await;
        cached
            .as_ref()
            .and_then(|v| v.get("data"))
            .and_then(|d| d.get("temperature"))
            .and_then(|t| t.as_f64())
    };

    // 3. Tính toán Mean, StdDev và Z-Score trên tập dữ liệu thật
    let (baseline_mean, std_dev, sample_count) = if history_vals.len() >= 2 {
        let n = history_vals.len() as f64;
        let mean = history_vals.iter().sum::<f64>() / n;
        let variance = history_vals
            .iter()
            .map(|v| (v - mean).powi(2))
            .sum::<f64>()
            / n;
        let sd = variance.sqrt().max(0.8);
        (mean, sd, history_vals.len())
    } else if let Some(single_val) = history_vals.first().copied().or(live_cached_temp) {
        (single_val, 1.2, 1)
    } else if let Some(req_t) = body.temperature {
        (req_t, 1.2, 1)
    } else {
        (28.5, 1.2, 0)
    };

    // Nếu người dùng truyền giá trị test thì dùng, ngược lại tạo điểm đột biến dựa trên nền nhiệt độ thật
    let simulated_temp = body
        .temperature
        .unwrap_or_else(|| (baseline_mean + (3.6 * std_dev).max(12.0)).min(85.0));

    let z_score = ((simulated_temp - baseline_mean).abs() / std_dev).max(3.1);

    let alert_id = Uuid::new_v4();
    let alert_type = format!("HIGH_SPIKE (Z-Score: {:.2})", z_score);
    let title = format!("Cảnh báo quá nhiệt tại {}", real_device_name);
    let room_suffix = real_room_name
        .as_deref()
        .map(|r| format!(" (Phòng: {})", r))
        .unwrap_or_default();
    let topic_label = if real_mqtt_topic.is_empty() {
        real_device_name.clone()
    } else {
        format!("{} [{}]", real_device_name, real_mqtt_topic)
    };

    let message = format!(
        "Độ ẩm {:.1}°C tại {}{} (Nhiệt độ thực tế: {:.1}°C, Z-Score: {:.2}).",
        simulated_temp, room_suffix, topic_label, baseline_mean, z_score
    );

    let metadata_str = json!({
        "device_id": real_device_id.to_string(),
        "device_name": real_device_name,
        "room_name": real_room_name,
        "mqtt_topic": real_mqtt_topic,
        "current_value": simulated_temp,
        "baseline_mean": baseline_mean,
        "std_dev": std_dev,
        "z_score": z_score,
        "sample_count": sample_count
    })
    .to_string();

    let now_str = chrono::Local::now().format("%H:%M:%S %d/%m").to_string();

    let mut insert_q = Query::new(
        r#"
        INSERT INTO dbo.ai_alerts (id, device_id, owner_id, alert_type, title, message, severity, metadata, created_at)
        VALUES (@P1, @P2, @P3, @P4, @P5, @P6, N'high', @P7, SYSDATETIMEOFFSET())
        "#,
    );
    insert_q.bind(alert_id);
    insert_q.bind(real_device_id);
    insert_q.bind(tenant_id);
    insert_q.bind(&alert_type);
    insert_q.bind(&title);
    insert_q.bind(&message);
    insert_q.bind(&metadata_str);

    if let Err(e) = insert_q.execute(&mut conn).await {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi lưu cảnh báo AI: {}", e) })),
        )
            .into_response();
    }

    let alert_msg = json!({
        "id": alert_id.to_string(),
        "owner_id": tenant_id.to_string(),
        "device_id": real_device_id.to_string(),
        "device_name": real_device_name,
        "room_name": real_room_name,
        "alert_type": alert_type,
        "title": title,
        "message": message,
        "severity": "high",
        "created_at": now_str
    });

    let ws_broadcast = json!({
        "type": "AI_ALERT",
        "data": alert_msg
    });
    let _ = state.tx.send(ws_broadcast.to_string());

    (StatusCode::CREATED, Json(alert_msg)).into_response()
}

// --- DÁN THÊM VÀO CUỐI FILE ai_controller.rs ---

pub async fn ensure_ai_suggestions_schema(pool: &SqlPool) {
    let Ok(mut conn) = pool.get().await else {
        return;
    };

    let migrations = [
        r#"
        IF OBJECT_ID(N'dbo.ai_suggestions', N'U') IS NULL
        CREATE TABLE dbo.ai_suggestions (
            id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
            user_id UNIQUEIDENTIFIER NULL,
            owner_id UNIQUEIDENTIFIER NULL,
            device_id UNIQUEIDENTIFIER NULL,
            suggestion_type NVARCHAR(50) NOT NULL DEFAULT N'HABIT',
            title NVARCHAR(200) NOT NULL DEFAULT N'Gợi ý tự động hóa thông minh',
            description NVARCHAR(MAX) NOT NULL DEFAULT N'',
            suggested_action NVARCHAR(MAX) NOT NULL DEFAULT N'{}',
            cron_expression NVARCHAR(50) NULL,
            confidence_score FLOAT NOT NULL DEFAULT 0.8,
            status NVARCHAR(20) NOT NULL DEFAULT N'PENDING',
            is_applied BIT NOT NULL DEFAULT 0,
            created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET()
        )
        "#,
        "IF COL_LENGTH(N'dbo.ai_suggestions', N'owner_id') IS NULL ALTER TABLE dbo.ai_suggestions ADD owner_id UNIQUEIDENTIFIER NULL",
        "IF COL_LENGTH(N'dbo.ai_suggestions', N'suggestion_type') IS NULL ALTER TABLE dbo.ai_suggestions ADD suggestion_type NVARCHAR(50) NOT NULL DEFAULT N'HABIT'",
        "IF COL_LENGTH(N'dbo.ai_suggestions', N'title') IS NULL ALTER TABLE dbo.ai_suggestions ADD title NVARCHAR(200) NOT NULL DEFAULT N'Gợi ý thông minh'",
        "IF COL_LENGTH(N'dbo.ai_suggestions', N'description') IS NULL ALTER TABLE dbo.ai_suggestions ADD description NVARCHAR(MAX) NOT NULL DEFAULT N''",
        "IF COL_LENGTH(N'dbo.ai_suggestions', N'status') IS NULL ALTER TABLE dbo.ai_suggestions ADD status NVARCHAR(20) NOT NULL DEFAULT N'PENDING'",
    ];

    for sql in migrations {
        let _ = conn.execute(sql, &[]).await;
    }
}

// GET /api/v1/ai/suggestions
pub async fn get_suggestions(
    claims: Claims,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ensure_ai_suggestions_schema(&state.db_pool).await;

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
        SELECT TOP 20
            CAST(s.id AS NVARCHAR(36)) AS id,
            CAST(s.device_id AS NVARCHAR(36)) AS device_id,
            COALESCE(d.name, N'Thiết bị IoT') AS device_name,
            r.name AS room_name,
            COALESCE(s.suggestion_type, N'HABIT') AS suggestion_type,
            COALESCE(s.title, N'Gợi ý thông minh') AS title,
            COALESCE(s.description, N'') AS description,
            COALESCE(s.suggested_action, N'{}') AS suggested_action,
            s.cron_expression,
            COALESCE(s.confidence_score, 0.8) AS confidence_score,
            COALESCE(s.status, N'PENDING') AS status,
            FORMAT(s.created_at AT TIME ZONE 'SE Asia Standard Time', 'HH:mm dd/MM') AS created_at
        FROM dbo.ai_suggestions s
        LEFT JOIN dbo.devices d ON s.device_id = d.id
        LEFT JOIN dbo.rooms r ON d.room_id = r.id
        WHERE COALESCE(s.owner_id, s.user_id) = @P1
          AND COALESCE(s.status, N'PENDING') = N'PENDING'
          AND ISNULL(s.is_applied, 0) = 0
        ORDER BY s.confidence_score DESC, s.created_at DESC
    "#;

    let mut query = Query::new(sql);
    query.bind(tenant_id);

    let response = match query.query(&mut conn).await {
        Ok(stream) => {
            let rows = stream.into_first_result().await.unwrap_or_default();
            let list: Vec<Value> = rows
                .into_iter()
                .map(|row| {
                    let raw_action = row.get::<&str, _>("suggested_action").unwrap_or("{}");
                    let action_val: Value =
                        serde_json::from_str(raw_action).unwrap_or_else(|_| json!({}));

                    json!({
                        "id": row.get::<&str, _>("id").unwrap_or(""),
                        "device_id": row.get::<&str, _>("device_id").unwrap_or(""),
                        "device_name": row.get::<&str, _>("device_name").unwrap_or("Thiết bị IoT"),
                        "room_name": row.get::<&str, _>("room_name"),
                        "suggestion_type": row.get::<&str, _>("suggestion_type").unwrap_or("HABIT"),
                        "title": row.get::<&str, _>("title").unwrap_or("Gợi ý thông minh"),
                        "description": row.get::<&str, _>("description").unwrap_or(""),
                        "suggested_action": action_val,
                        "cron_expression": row.get::<&str, _>("cron_expression"),
                        "confidence_score": row.get::<f64, _>("confidence_score").unwrap_or(0.8),
                        "status": row.get::<&str, _>("status").unwrap_or("PENDING"),
                        "created_at": row.get::<&str, _>("created_at").unwrap_or("")
                    })
                })
                .collect();

            (StatusCode::OK, Json(json!(list))).into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi truy vấn gợi ý AI: {}", e) })),
        )
            .into_response(),
    };
    response
}

// POST /api/v1/ai/suggestions/{id}/apply
pub async fn apply_suggestion(
    claims: Claims,
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ensure_ai_suggestions_schema(&state.db_pool).await;

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let Ok(sug_uuid) = Uuid::parse_str(id.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID gợi ý không hợp lệ" })),
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

    // 1. Lấy thông tin gợi ý thuộc hộ gia đình hiện tại
    let sug_row = {
        let mut q = Query::new(
            r#"
            SELECT TOP 1
                s.id,
                s.device_id,
                COALESCE(s.suggestion_type, N'HABIT') AS suggestion_type,
                COALESCE(s.title, N'Gợi ý AI') AS title,
                COALESCE(s.suggested_action, N'{}') AS suggested_action,
                d.mqtt_topic,
                COALESCE(d.name, N'Thiết bị') AS device_name
            FROM dbo.ai_suggestions s
            LEFT JOIN dbo.devices d ON s.device_id = d.id
            WHERE s.id = @P1 AND COALESCE(s.owner_id, s.user_id) = @P2
            "#,
        );
        q.bind(sug_uuid);
        q.bind(tenant_id);

        match q.query(&mut conn).await {
            Ok(stream) => stream.into_row().await,
            Err(e) => Err(e),
        }
    };

    let row = match sug_row {
        Ok(Some(r)) => r,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({ "error": "Không tìm thấy gợi ý trong hộ gia đình của bạn" })),
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

    let device_id: Option<Uuid> = row.get::<Uuid, _>("device_id");
    let title = row.get::<&str, _>("title").unwrap_or("Gợi ý AI").to_string();
    let mqtt_topic = row.get::<&str, _>("mqtt_topic").unwrap_or("").to_string();
    let device_name = row.get::<&str, _>("device_name").unwrap_or("Thiết bị").to_string();
    let raw_action = row.get::<&str, _>("suggested_action").unwrap_or("{}");
    let action_json: Value = serde_json::from_str(raw_action).unwrap_or_else(|_| json!({}));

    let mode = action_json
        .get("mode")
        .and_then(|v| v.as_str())
        .unwrap_or("INSTANT")
        .to_uppercase();
    let cmd = action_json
        .get("action")
        .and_then(|v| v.as_str())
        .unwrap_or("ON")
        .to_uppercase();
    let next_is_on = cmd == "ON";

    let mut result_message = format!("Đã áp dụng gợi ý: {}", title);

    // 2A. Nếu là gợi ý dạng AUTOMATION (tạo kịch bản tự động hóa)
    if mode == "AUTOMATION" {
        let auto_id = Uuid::new_v4();
        let rule_name = action_json
            .get("rule_name")
            .and_then(|v| v.as_str())
            .unwrap_or(&title)
            .to_string();
        let condition_text = action_json
            .get("condition_text")
            .and_then(|v| v.as_str())
            .unwrap_or("Theo thói quen AI")
            .to_string();
        let action_text = action_json
            .get("action_text")
            .and_then(|v| v.as_str())
            .unwrap_or(&format!("{} {}", cmd, device_name))
            .to_string();
        let dev_id_str = device_id.map(|u| u.to_string()).unwrap_or_default();
        let action_payload_str = json!({ "power": cmd }).to_string();

        let mut ins_auto = Query::new(
            r#"
            INSERT INTO dbo.automations (
                id, name, condition_text, action_text, condition_type,
                operator, threshold, trigger_value, device_id, action,
                action_payload, owner_id, is_active, created_at
            )
            VALUES (
                @P1, @P2, @P3, @P4, N'schedule',
                N'==', 1.0, 1.0, @P5, @P6,
                @P7, @P8, 1, SYSDATETIMEOFFSET()
            )
            "#,
        );
        ins_auto.bind(auto_id);
        ins_auto.bind(&rule_name);
        ins_auto.bind(&condition_text);
        ins_auto.bind(&action_text);
        ins_auto.bind(&dev_id_str);
        ins_auto.bind(&cmd);
        ins_auto.bind(&action_payload_str);
        ins_auto.bind(tenant_id);

        if ins_auto.execute(&mut conn).await.is_ok() {
            result_message = format!("Đã tạo kịch bản tự động: {}", rule_name);
        }
    }

    // 2B. Nếu có thiết bị đích và ở chế độ thực thi tức thời (hoặc cần đồng bộ trạng thái ngay)
    if mode == "INSTANT" {
        if let Some(dev_uuid) = device_id {
            let mut upd_dev = Query::new(
                "UPDATE dbo.devices SET is_on = @P1, status = @P2, last_seen = SYSDATETIMEOFFSET() WHERE id = @P3",
            );
            upd_dev.bind(next_is_on);
            upd_dev.bind(&cmd);
            upd_dev.bind(dev_uuid);
            let _ = upd_dev.execute(&mut conn).await;

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

            let ws_dev = json!({
                "type": "DEVICE_UPDATE",
                "data": {
                    "id": dev_uuid.to_string(),
                    "mqtt_topic": mqtt_topic,
                    "is_on": next_is_on,
                    "status": cmd
                }
            });
            let _ = state.tx.send(ws_dev.to_string());

            result_message = format!(
                "Đã {} {} theo gợi ý AI.",
                if next_is_on { "BẬT" } else { "TẮT" },
                device_name
            );
        }
    }

    // 3. Đánh dấu gợi ý đã áp dụng
    {
        let mut mark_q = Query::new(
            "UPDATE dbo.ai_suggestions SET is_applied = 1, status = N'APPLIED' WHERE id = @P1",
        );
        mark_q.bind(sug_uuid);
        let _ = mark_q.execute(&mut conn).await;
    }

    (
        StatusCode::OK,
        Json(json!({
            "id": sug_uuid.to_string(),
            "status": "APPLIED",
            "message": result_message
        })),
    )
        .into_response()
}

// POST /api/v1/ai/suggestions/{id}/dismiss
pub async fn dismiss_suggestion(
    claims: Claims,
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ensure_ai_suggestions_schema(&state.db_pool).await;

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let Ok(sug_uuid) = Uuid::parse_str(id.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID gợi ý không hợp lệ" })),
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

    let mut upd_q = Query::new(
        "UPDATE dbo.ai_suggestions SET status = N'DISMISSED' WHERE id = @P1 AND COALESCE(owner_id, user_id) = @P2",
    );
    upd_q.bind(sug_uuid);
    upd_q.bind(tenant_id);

    match upd_q.execute(&mut conn).await {
        Ok(res) if res.rows_affected().iter().sum::<u64>() > 0 => (
            StatusCode::OK,
            Json(json!({
                "id": sug_uuid.to_string(),
                "status": "DISMISSED",
                "message": "Đã bỏ qua gợi ý"
            })),
        )
            .into_response(),
        Ok(_) => (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Không tìm thấy gợi ý" })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}

// POST /api/v1/ai/suggestions/analyze
pub async fn analyze_suggestions(
    claims: Claims,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let newly_created = crate::ai::service::run_smart_suggestions(&state, Some(tenant_id)).await;

    (
        StatusCode::OK,
        Json(json!({
            "created_count": newly_created,
            "message": if newly_created > 0 {
                format!("AI vừa phát hiện {} gợi ý tối ưu mới cho ngôi nhà của bạn!", newly_created)
            } else {
                "Đã hoàn tất quét dữ liệu hành vi & cảm biến. Chưa có gợi ý mới phát sinh.".to_string()
            }
        })),
    )
        .into_response()
}