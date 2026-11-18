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

use crate::controllers::user_controller::{ensure_owner_or_admin, resolve_tenant_id};
use crate::models::user::Claims;
use crate::{AppState, SqlPool};

#[derive(Deserialize, Default)]
pub struct AnomalyPayload {
    pub temperature: Option<f32>,
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
                    let id = row
                        .get::<Uuid, _>("id")
                        .map(|u| u.to_string())
                        .unwrap_or_default();
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

    let mut insert_q = Query::new(
        r#"
        INSERT INTO dbo.ai_alerts (id, owner_id, alert_type, title, message, severity, created_at)
        VALUES (@P1, @P2, @P3, @P4, @P5, N'high', SYSDATETIMEOFFSET())
        "#,
    );
    insert_q.bind(alert_id);
    insert_q.bind(tenant_id);
    insert_q.bind(alert_type);
    insert_q.bind(title);
    insert_q.bind(&message);

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