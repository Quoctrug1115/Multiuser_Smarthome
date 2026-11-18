use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde_json::{json, Value};
use std::sync::Arc;
use tiberius::Query;
use uuid::Uuid;

use crate::controllers::user_controller::{ensure_owner_or_admin, resolve_tenant_id};
use crate::models::user::Claims;
use crate::{AppState, SqlPool};

async fn ensure_automations_schema(pool: &SqlPool) {
    let Ok(mut conn) = pool.get().await else {
        return;
    };

    let migrations = [
        r#"
        IF OBJECT_ID(N'dbo.automations', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.automations (
                id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
                house_id UNIQUEIDENTIFIER NULL,
                owner_id UNIQUEIDENTIFIER NULL,
                name NVARCHAR(100) NOT NULL,
                condition_text NVARCHAR(255) NULL DEFAULT N'',
                action_text NVARCHAR(255) NULL DEFAULT N'',
                trigger_device_id UNIQUEIDENTIFIER NULL,
                condition_type NVARCHAR(30) NOT NULL DEFAULT N'temperature',
                operator NVARCHAR(10) NOT NULL DEFAULT N'>',
                threshold FLOAT NOT NULL DEFAULT 30.0,
                trigger_value FLOAT NOT NULL DEFAULT 30.0,
                action NVARCHAR(20) NOT NULL DEFAULT N'ON',
                device_id NVARCHAR(50) NULL DEFAULT N'',
                action_device_id UNIQUEIDENTIFIER NULL,
                action_payload NVARCHAR(MAX) NOT NULL DEFAULT N'{"power": "ON"}',
                is_active BIT NOT NULL DEFAULT 1,
                created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET()
            );
        END
        "#,
        "IF COL_LENGTH(N'dbo.automations', N'owner_id') IS NULL ALTER TABLE dbo.automations ADD owner_id UNIQUEIDENTIFIER NULL",
        "IF COL_LENGTH(N'dbo.automations', N'condition_text') IS NULL ALTER TABLE dbo.automations ADD condition_text NVARCHAR(255) NULL DEFAULT N''",
        "IF COL_LENGTH(N'dbo.automations', N'action_text') IS NULL ALTER TABLE dbo.automations ADD action_text NVARCHAR(255) NULL DEFAULT N''",
        "IF COL_LENGTH(N'dbo.automations', N'condition_type') IS NULL ALTER TABLE dbo.automations ADD condition_type NVARCHAR(30) NOT NULL DEFAULT N'temperature'",
        "IF COL_LENGTH(N'dbo.automations', N'operator') IS NULL ALTER TABLE dbo.automations ADD operator NVARCHAR(10) NOT NULL DEFAULT N'>'",
        "IF COL_LENGTH(N'dbo.automations', N'threshold') IS NULL ALTER TABLE dbo.automations ADD threshold FLOAT NOT NULL DEFAULT 30.0",
        "IF COL_LENGTH(N'dbo.automations', N'device_id') IS NULL ALTER TABLE dbo.automations ADD device_id NVARCHAR(50) NULL DEFAULT N''",
        "IF COL_LENGTH(N'dbo.automations', N'action') IS NULL ALTER TABLE dbo.automations ADD action NVARCHAR(20) NOT NULL DEFAULT N'ON'",
        "IF COL_LENGTH(N'dbo.automations', N'is_active') IS NULL ALTER TABLE dbo.automations ADD is_active BIT NOT NULL DEFAULT 1",
    ];

    for sql in migrations {
        let _ = conn.execute(sql, &[]).await;
    }
}

fn parse_condition_text(text: &str) -> (String, String, f64) {
    let lower = text.to_lowercase();
    let cond_type = if lower.contains("ẩm") || lower.contains("hum") {
        "humidity"
    } else if lower.contains("sáng") || lower.contains("lux") || lower.contains("light") {
        "lux"
    } else if lower.contains("động") || lower.contains("motion") || lower.contains("pir") {
        "motion"
    } else {
        "temperature"
    };

    let operator = if lower.contains(">=") {
        ">="
    } else if lower.contains("<=") {
        "<="
    } else if lower.contains('<') {
        "<"
    } else if lower.contains("==") || lower.contains('=') || cond_type == "motion" {
        "=="
    } else {
        ">"
    };

    let num_str: String = lower
        .chars()
        .filter(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    let threshold = num_str
        .parse::<f64>()
        .unwrap_or(if cond_type == "motion" { 1.0 } else { 30.0 });

    (cond_type.to_string(), operator.to_string(), threshold)
}

// GET /api/v1/automations
pub async fn get_automations(
    claims: Claims,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ensure_automations_schema(&state.db_pool).await;

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[GET AUTOMATIONS CONN ERROR]: {:?}", e);
            return (StatusCode::OK, Json(Vec::<Value>::new())).into_response();
        }
    };

    let mut query = Query::new("SELECT * FROM dbo.automations WHERE owner_id = @P1 ORDER BY created_at DESC");
    query.bind(tenant_id);

    let rows = match query.query(&mut conn).await {
        Ok(stream) => stream.into_first_result().await.unwrap_or_default(),
        Err(e) => {
            eprintln!("[GET AUTOMATIONS ERROR]: {:?}", e);
            return (StatusCode::OK, Json(Vec::<Value>::new())).into_response();
        }
    };

    let mut list = Vec::new();
    for row in rows {
        let id = row
            .try_get::<Uuid, _>("id")
            .ok()
            .flatten()
            .map(|u| u.to_string())
            .or_else(|| row.try_get::<&str, _>("id").ok().flatten().map(|s| s.to_string()))
            .unwrap_or_default();

        let name = row
            .try_get::<&str, _>("name")
            .ok()
            .flatten()
            .unwrap_or("Kịch bản tự động")
            .to_string();

        let condition_type = row
            .try_get::<&str, _>("condition_type")
            .ok()
            .flatten()
            .or_else(|| row.try_get::<&str, _>("trigger_type").ok().flatten())
            .unwrap_or("temperature")
            .to_string();

        let operator = row
            .try_get::<&str, _>("operator")
            .ok()
            .flatten()
            .or_else(|| row.try_get::<&str, _>("condition").ok().flatten())
            .unwrap_or(">")
            .to_string();

        let threshold = row
            .try_get::<f64, _>("threshold")
            .ok()
            .flatten()
            .or_else(|| row.try_get::<f64, _>("trigger_value").ok().flatten())
            .or_else(|| {
                row.try_get::<f32, _>("threshold")
                    .ok()
                    .flatten()
                    .map(|v| v as f64)
            })
            .unwrap_or(30.0);

        let action = row
            .try_get::<&str, _>("action")
            .ok()
            .flatten()
            .unwrap_or("ON")
            .to_string();

        let condition_text = row
            .try_get::<&str, _>("condition_text")
            .ok()
            .flatten()
            .map(|s| s.to_string())
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| format!("{} {} {}", condition_type, operator, threshold));

        let action_text = row
            .try_get::<&str, _>("action_text")
            .ok()
            .flatten()
            .map(|s| s.to_string())
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| format!("Lệnh thực thi: {}", action));

        let is_active = row
            .try_get::<bool, _>("is_active")
            .ok()
            .flatten()
            .or_else(|| row.try_get::<bool, _>("enabled").ok().flatten())
            .unwrap_or(true);

        list.push(json!({
            "id": id,
            "name": name,
            "condition_text": condition_text,
            "action_text": action_text,
            "condition_type": condition_type,
            "operator": operator,
            "threshold": threshold,
            "action": action,
            "is_active": is_active
        }));
    }

    (StatusCode::OK, Json(list)).into_response()
}

// POST /api/v1/automations
pub async fn create_automation(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<Value>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    ensure_automations_schema(&state.db_pool).await;

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

    let id = Uuid::new_v4();
    let name = payload
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("Kịch bản tự động")
        .trim()
        .to_string();

    let condition_text = payload
        .get("condition_text")
        .or_else(|| payload.get("condition"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();

    let action_text = payload
        .get("action_text")
        .or_else(|| payload.get("action"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();

    let (parsed_type, parsed_op, parsed_val) = parse_condition_text(&condition_text);
    let action_upper = if action_text.to_lowercase().contains("tắt")
        || action_text.to_uppercase().contains("OFF")
    {
        "OFF".to_string()
    } else {
        "ON".to_string()
    };

    // Chỉ tìm device_id trong phạm vi thiết bị thuộc đúng hộ gia đình (tenant_id)
    let mut target_device_id = payload
        .get("device_id")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();

    if target_device_id.is_empty() {
        let act_lower = action_text.to_lowercase();
        let dev_sql = r#"
            SELECT CAST(d.id AS NVARCHAR(36)) AS id, d.name, d.device_type, d.mqtt_topic
            FROM dbo.devices d
            LEFT JOIN dbo.rooms r ON d.room_id = r.id
            LEFT JOIN dbo.houses h ON r.house_id = h.id
            WHERE d.owner_id = @P1 OR h.owner_id = @P1
        "#;

        let mut dev_q = Query::new(dev_sql);
        dev_q.bind(tenant_id);

        if let Ok(stream) = dev_q.query(&mut conn).await {
            let dev_rows = stream.into_first_result().await.unwrap_or_default();
            for r in dev_rows {
                let d_id = r.get::<&str, _>("id").unwrap_or("").to_string();
                let d_name = r.get::<&str, _>("name").unwrap_or("").to_lowercase();
                let d_type = r.get::<&str, _>("device_type").unwrap_or("").to_lowercase();

                if (!d_name.is_empty() && act_lower.contains(&d_name))
                    || ((act_lower.contains("quạt") || act_lower.contains("fan")) && d_type == "fan")
                    || ((act_lower.contains("đèn") || act_lower.contains("light")) && d_type == "light")
                {
                    target_device_id = d_id;
                    break;
                }
            }
        }
    }

    let action_payload_json = json!({ "power": action_upper }).to_string();

    let mut insert_q = Query::new(
        r#"
        INSERT INTO dbo.automations (
            id, name, condition_text, action_text, condition_type,
            operator, threshold, trigger_value, device_id, action,
            action_payload, owner_id, is_active, created_at
        )
        VALUES (@P1, @P2, @P3, @P4, @P5, @P6, @P7, @P7, @P8, @P9, @P10, @P11, 1, SYSDATETIMEOFFSET())
        "#,
    );
    insert_q.bind(id);
    insert_q.bind(&name);
    insert_q.bind(&condition_text);
    insert_q.bind(&action_text);
    insert_q.bind(&parsed_type);
    insert_q.bind(&parsed_op);
    insert_q.bind(parsed_val);
    insert_q.bind(&target_device_id);
    insert_q.bind(&action_upper);
    insert_q.bind(&action_payload_json);
    insert_q.bind(tenant_id);

    match insert_q.execute(&mut conn).await {
        Ok(_) => {
            println!(
                "[AUTOMATION SAVED] {} ({} {} {}) -> Device: {} [{}]",
                name, parsed_type, parsed_op, parsed_val, target_device_id, action_upper
            );

            (
                StatusCode::CREATED,
                Json(json!({
                    "id": id.to_string(),
                    "name": name,
                    "condition_text": condition_text,
                    "action_text": action_text,
                    "condition_type": parsed_type,
                    "operator": parsed_op,
                    "threshold": parsed_val,
                    "device_id": target_device_id,
                    "action": action_upper,
                    "is_active": true
                })),
            )
                .into_response()
        }
        Err(e) => {
            eprintln!("[CREATE AUTOMATION DB ERROR]: {:?}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response()
        }
    }
}

// DELETE /api/v1/automations/{id}
pub async fn delete_automation(
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

    let trimmed_id = id.trim();
    let mut del_q = Query::new(
        "DELETE FROM dbo.automations WHERE LOWER(CAST(id AS NVARCHAR(36))) = LOWER(@P1) AND owner_id = @P2",
    );
    del_q.bind(trimmed_id);
    del_q.bind(tenant_id);

    match del_q.execute(&mut conn).await {
        Ok(res) if res.rows_affected().iter().sum::<u64>() > 0 => StatusCode::NO_CONTENT.into_response(),
        Ok(_) => (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Không tìm thấy kịch bản thuộc quyền quản lý của bạn" })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}

// POST/PUT/PATCH /api/v1/automations/{id}/toggle hoặc PUT/PATCH /api/v1/automations/{id}
pub async fn toggle_automation(
    claims: Claims,
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
    body: axum::body::Bytes,
) -> impl IntoResponse {
    ensure_automations_schema(&state.db_pool).await;

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

    let trimmed_id = id.trim();
    let payload = serde_json::from_slice::<Value>(&body).ok();
    let explicit_state = payload.as_ref().and_then(|v| {
        v.get("is_active")
            .or_else(|| v.get("enabled"))
            .and_then(|b| b.as_bool())
    });

    let new_active = match explicit_state {
        Some(val) => val,
        None => {
            let mut cur_q = Query::new(
                "SELECT TOP 1 COALESCE(is_active, CAST(1 AS BIT)) AS is_active FROM dbo.automations WHERE LOWER(CAST(id AS NVARCHAR(36))) = LOWER(@P1) AND owner_id = @P2",
            );
            cur_q.bind(trimmed_id);
            cur_q.bind(tenant_id);

            let current: Option<bool> = match cur_q.query(&mut conn).await {
                Ok(stream) => stream
                    .into_row()
                    .await
                    .ok()
                    .flatten()
                    .and_then(|r| r.get::<bool, _>("is_active")),
                Err(_) => None,
            };

            match current {
                Some(cur) => !cur,
                None => {
                    return (
                        StatusCode::NOT_FOUND,
                        Json(json!({ "error": "Không tìm thấy kịch bản trong nhà của bạn" })),
                    )
                        .into_response();
                }
            }
        }
    };

    let mut upd_q = Query::new(
        "UPDATE dbo.automations SET is_active = @P1 WHERE LOWER(CAST(id AS NVARCHAR(36))) = LOWER(@P2) AND owner_id = @P3",
    );
    upd_q.bind(new_active);
    upd_q.bind(trimmed_id);
    upd_q.bind(tenant_id);

    if let Ok(res) = upd_q.execute(&mut conn).await {
        if res.rows_affected().iter().sum::<u64>() == 0 {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({ "error": "Không tìm thấy kịch bản trong nhà của bạn" })),
            )
                .into_response();
        }
    }

    // Đồng bộ thêm cột `enabled` cũ nếu có trong Database
    let mut sync_q = Query::new(
        "IF COL_LENGTH(N'dbo.automations', N'enabled') IS NOT NULL UPDATE dbo.automations SET enabled = @P1 WHERE LOWER(CAST(id AS NVARCHAR(36))) = LOWER(@P2) AND owner_id = @P3",
    );
    sync_q.bind(new_active);
    sync_q.bind(trimmed_id);
    sync_q.bind(tenant_id);
    let _ = sync_q.execute(&mut conn).await;

    println!(
        "[AUTOMATION TOGGLE] ID: {} -> {}",
        id,
        if new_active { "BẬT" } else { "TẮT" }
    );

    (
        StatusCode::OK,
        Json(json!({
            "id": id,
            "is_active": new_active,
            "enabled": new_active
        })),
    )
        .into_response()
}