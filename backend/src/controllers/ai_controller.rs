use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::Row;
use std::sync::Arc;
use uuid::Uuid;

use crate::controllers::user_controller::{ensure_owner_or_admin, resolve_tenant_id};
use crate::models::user::Claims;
use crate::AppState;

#[derive(Deserialize, Default)]
pub struct AnomalyPayload {
    pub temperature: Option<f32>,
    pub sensor_id: Option<String>,
}

async fn ensure_ai_alerts_schema(pool: &sqlx::PgPool) {
    let _ = sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS ai_alerts (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            owner_id UUID REFERENCES users(id) ON DELETE CASCADE,
            alert_type VARCHAR(100) NOT NULL DEFAULT 'ANOMALY',
            title VARCHAR(150) NOT NULL DEFAULT 'Cảnh báo AI',
            message TEXT NOT NULL,
            severity VARCHAR(30) NOT NULL DEFAULT 'high',
            created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
        );
        "#,
    )
    .execute(pool)
    .await;

    let _ = sqlx::query(
        "ALTER TABLE ai_alerts ADD COLUMN IF NOT EXISTS owner_id UUID REFERENCES users(id) ON DELETE CASCADE",
    )
    .execute(pool)
    .await;

    let _ = sqlx::query(
        "ALTER TABLE ai_alerts ADD COLUMN IF NOT EXISTS title VARCHAR(150) DEFAULT 'Cảnh báo AI'",
    )
    .execute(pool)
    .await;
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

    let query = r#"
        SELECT
            id::text AS id,
            COALESCE(alert_type, 'ANOMALY') AS alert_type,
            COALESCE(title, 'Cảnh báo AI') AS title,
            COALESCE(message, '') AS message,
            COALESCE(severity, 'high') AS severity,
            to_char(created_at AT TIME ZONE 'Asia/Ho_Chi_Minh', 'HH24:MI:SS DD/MM') AS created_at
        FROM ai_alerts
        WHERE owner_id = $1
        ORDER BY created_at DESC
        LIMIT 30
    "#;

    match sqlx::query(query)
        .bind(tenant_id)
        .fetch_all(&state.db_pool)
        .await
    {
        Ok(rows) => {
            let alerts: Vec<Value> = rows
                .into_iter()
                .map(|row| {
                    let id: String = row.try_get("id").unwrap_or_default();
                    let alert_type: String = row.try_get("alert_type").unwrap_or_default();
                    let title: String = row.try_get("title").unwrap_or_else(|_| "Cảnh báo AI".to_string());
                    let message: String = row.try_get("message").unwrap_or_default();
                    let severity: String = row.try_get("severity").unwrap_or_else(|_| "high".to_string());
                    let created_at: String = row.try_get("created_at").unwrap_or_default();

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
    }
}

// POST /api/v1/ai/simulate-anomaly
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

    let body = payload.map(|Json(p)| p).unwrap_or_default();
    let temperature = body.temperature.unwrap_or(65.0);
    let sensor_id = body
        .sensor_id
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "ESP32-DHT22-01".to_string());

    let alert_id = Uuid::new_v4();
    let alert_type = "HIGH_SPIKE (Z-Score: 4.12)";
    let title = "Cảnh báo quá nhiệt bất thường";
    let message = format!(
        "Cảnh báo vọt nhiệt độ {:.1}°C tại cảm biến {}!",
        temperature, sensor_id
    );
    let now_str = chrono::Local::now().format("%H:%M:%S %d/%m").to_string();

    let _ = sqlx::query(
        "INSERT INTO ai_alerts (id, owner_id, alert_type, title, message, severity)
         VALUES ($1, $2, $3, $4, $5, 'high')",
    )
    .bind(alert_id)
    .bind(tenant_id)
    .bind(alert_type)
    .bind(title)
    .bind(&message)
    .execute(&state.db_pool)
    .await;

    let alert_msg = json!({
        "id": alert_id.to_string(),
        "owner_id": tenant_id.to_string(),
        "alert_type": alert_type,
        "title": title,
        "message": message,
        "severity": "high",
        "created_at": now_str
    });

    // Bắn tin nhắn phát sóng WebSocket tới Frontend Client ngay lập tức
    let ws_broadcast = json!({
        "type": "AI_ALERT",
        "data": alert_msg
    });
    let _ = state.tx.send(ws_broadcast.to_string());

    (StatusCode::CREATED, Json(alert_msg)).into_response()
}