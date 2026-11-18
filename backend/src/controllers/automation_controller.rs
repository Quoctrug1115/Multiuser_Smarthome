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

use crate::controllers::user_controller::{ensure_owner_or_admin, resolve_tenant_id};
use crate::models::user::Claims;
use crate::AppState;

async fn ensure_automations_schema(pool: &sqlx::PgPool) {
    let _ = sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS automations (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            owner_id UUID REFERENCES users(id) ON DELETE CASCADE,
            name VARCHAR(150) NOT NULL,
            condition_text TEXT DEFAULT '',
            action_text TEXT DEFAULT '',
            condition_type VARCHAR(50) NOT NULL DEFAULT 'temperature',
            operator VARCHAR(20) NOT NULL DEFAULT '>',
            threshold DOUBLE PRECISION NOT NULL DEFAULT 30.0,
            device_id VARCHAR(100) NOT NULL DEFAULT '',
            action VARCHAR(20) NOT NULL DEFAULT 'ON',
            is_active BOOLEAN NOT NULL DEFAULT TRUE,
            created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
        );
        "#,
    )
    .execute(pool)
    .await;

    let migrations = [
        "ALTER TABLE automations ADD COLUMN IF NOT EXISTS owner_id UUID REFERENCES users(id) ON DELETE CASCADE",
        "ALTER TABLE automations ADD COLUMN IF NOT EXISTS condition_text TEXT DEFAULT ''",
        "ALTER TABLE automations ADD COLUMN IF NOT EXISTS action_text TEXT DEFAULT ''",
        "ALTER TABLE automations ADD COLUMN IF NOT EXISTS condition_type VARCHAR(50) DEFAULT 'temperature'",
        "ALTER TABLE automations ADD COLUMN IF NOT EXISTS operator VARCHAR(20) DEFAULT '>'",
        "ALTER TABLE automations ADD COLUMN IF NOT EXISTS threshold DOUBLE PRECISION DEFAULT 30.0",
        "ALTER TABLE automations ADD COLUMN IF NOT EXISTS device_id VARCHAR(100) DEFAULT ''",
        "ALTER TABLE automations ADD COLUMN IF NOT EXISTS action VARCHAR(20) DEFAULT 'ON'",
        "ALTER TABLE automations ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE",
        // Tự động gỡ bỏ NOT NULL trên tất cả các cột cũ còn sót lại (action_payload, trigger_value, v.v.)
        r#"
        DO $$
        DECLARE
            col_name text;
        BEGIN
            FOR col_name IN
                SELECT column_name
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'automations'
                  AND is_nullable = 'NO'
                  AND column_name NOT IN ('id', 'name')
            LOOP
                EXECUTE format('ALTER TABLE automations ALTER COLUMN %I DROP NOT NULL', col_name);
            END LOOP;
        END $$;
        "#,
    ];

    for sql in migrations {
        let _ = sqlx::query(sql).execute(pool).await;
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

    let rows = match sqlx::query("SELECT * FROM automations WHERE owner_id = $1")
        .bind(tenant_id)
        .fetch_all(&state.db_pool)
        .await
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("❌ [GET AUTOMATIONS ERROR]: {:?}", e);
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

        let name = row
            .try_get::<String, _>("name")
            .unwrap_or_else(|_| "Kịch bản tự động".to_string());

        let condition_type = row
            .try_get::<String, _>("condition_type")
            .or_else(|_| row.try_get::<String, _>("trigger_type"))
            .unwrap_or_else(|_| "temperature".to_string());

        let operator = row
            .try_get::<String, _>("operator")
            .or_else(|_| row.try_get::<String, _>("condition"))
            .unwrap_or_else(|_| ">".to_string());

        let threshold = row
            .try_get::<f64, _>("threshold")
            .or_else(|_| row.try_get::<f64, _>("trigger_value"))
            .or_else(|_| row.try_get::<f32, _>("threshold").map(|v| v as f64))
            .or_else(|_| {
                row.try_get::<String, _>("trigger_value")
                    .ok()
                    .and_then(|s| s.parse::<f64>().ok())
                    .ok_or(sqlx::Error::ColumnNotFound("trigger_value".into()))
            })
            .unwrap_or(30.0);

        let action = row
            .try_get::<String, _>("action")
            .or_else(|_| row.try_get::<String, _>("action_payload"))
            .unwrap_or_else(|_| "ON".to_string());

        let condition_text = row
            .try_get::<String, _>("condition_text")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| format!("{} {} {}", condition_type, operator, threshold));

        let action_text = row
            .try_get::<String, _>("action_text")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| format!("Lệnh thực thi: {}", action));

        let is_active = row
            .try_get::<bool, _>("is_active")
            .or_else(|_| row.try_get::<bool, _>("enabled"))
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
        let dev_query = r#"
            SELECT d.id::text AS id, d.name, d.device_type, d.mqtt_topic
            FROM devices d
            LEFT JOIN rooms r ON d.room_id = r.id
            LEFT JOIN houses h ON r.house_id = h.id
            WHERE d.owner_id = $1 OR h.owner_id = $1
        "#;

        if let Ok(dev_rows) = sqlx::query(dev_query)
            .bind(tenant_id)
            .fetch_all(&state.db_pool)
            .await
        {
            for r in dev_rows {
                let d_id: String = r.try_get("id").unwrap_or_default();
                let d_name: String = r.try_get::<String, _>("name").unwrap_or_default().to_lowercase();
                let d_type: String = r.try_get::<String, _>("device_type").unwrap_or_default().to_lowercase();

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

    let insert_res = sqlx::query(
        r#"
        INSERT INTO automations (id, name, condition_text, action_text, condition_type, operator, threshold, device_id, action, owner_id, is_active)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, TRUE)
        "#,
    )
    .bind(id)
    .bind(&name)
    .bind(&condition_text)
    .bind(&action_text)
    .bind(&parsed_type)
    .bind(&parsed_op)
    .bind(parsed_val)
    .bind(&target_device_id)
    .bind(&action_upper)
    .bind(tenant_id)
    .execute(&state.db_pool)
    .await;

    match insert_res {
        Ok(_) => {
            let _ = sqlx::query("UPDATE automations SET trigger_type = $1, trigger_value = $2, action_payload = $3 WHERE id = $4")
                .bind(&parsed_type)
                .bind(parsed_val)
                .bind(&action_upper)
                .bind(id)
                .execute(&state.db_pool)
                .await;

            println!(
                "✅ [AUTOMATION SAVED] {} ({} {} {}) -> Device: {} [{}]",
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
            eprintln!("❌ [CREATE AUTOMATION DB ERROR]: {:?}", e);
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

    match sqlx::query("DELETE FROM automations WHERE id::text = $1 AND owner_id = $2")
        .bind(id.trim())
        .bind(tenant_id)
        .execute(&state.db_pool)
        .await
    {
        Ok(res) if res.rows_affected() > 0 => StatusCode::NO_CONTENT.into_response(),
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

    let payload = serde_json::from_slice::<Value>(&body).ok();
    let explicit_state = payload.as_ref().and_then(|v| {
        v.get("is_active")
            .or_else(|| v.get("enabled"))
            .and_then(|b| b.as_bool())
    });

    let new_active = match explicit_state {
        Some(val) => val,
        None => {
            let current: Option<bool> = sqlx::query_scalar(
                "SELECT COALESCE(is_active, TRUE) FROM automations WHERE id::text = $1 AND owner_id = $2",
            )
            .bind(id.trim())
            .bind(tenant_id)
            .fetch_optional(&state.db_pool)
            .await
            .unwrap_or(None);

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

    let update_res = sqlx::query(
        "UPDATE automations SET is_active = $1 WHERE id::text = $2 AND owner_id = $3",
    )
    .bind(new_active)
    .bind(id.trim())
    .bind(tenant_id)
    .execute(&state.db_pool)
    .await;

    if let Ok(res) = update_res {
        if res.rows_affected() == 0 {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({ "error": "Không tìm thấy kịch bản trong nhà của bạn" })),
            )
                .into_response();
        }
    }

    // Đồng bộ thêm cột `enabled` cũ nếu có trong Database
    let _ = sqlx::query("UPDATE automations SET enabled = $1 WHERE id::text = $2 AND owner_id = $3")
        .bind(new_active)
        .bind(id.trim())
        .bind(tenant_id)
        .execute(&state.db_pool)
        .await;

    println!(
        "🔄 [AUTOMATION TOGGLE] ID: {} -> {}",
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