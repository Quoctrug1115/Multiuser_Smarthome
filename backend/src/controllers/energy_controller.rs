use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tiberius::Query as TSqlQuery;

use crate::controllers::user_controller::resolve_tenant_id;
use crate::models::user::Claims;
use crate::AppState;

#[derive(Deserialize, Default)]
pub struct EnergyQueryParams {
    pub period: Option<String>,
    pub range: Option<String>,
    pub timeframe: Option<String>,
}

#[derive(Serialize, Clone)]
pub struct EnergyPoint {
    pub label: String,
    pub kwh: f64,
    pub power_watt: f64,
}

#[derive(Serialize, Clone)]
pub struct EnergyLogItem {
    pub time: String,
    pub label: String,
    pub device_id: String,
    pub power_watt: f64,
    pub kwh_consumed: f64,
    pub kwh: f64,
}

#[derive(Serialize)]
pub struct EnergyAnalyticsResponse {
    pub labels: Vec<String>,
    pub kwh_data: Vec<f64>,
    pub total_kwh: f64,
    pub total_vnd: f64,
    pub estimated_cost: f64,
    pub peak_watt: f64,
    pub max_power_watt: f64,
    pub chart_data: Vec<EnergyPoint>,
    pub daily: Vec<EnergyPoint>,
    pub logs: Vec<EnergyLogItem>,
    pub records: Vec<EnergyLogItem>,
}

// GET /api/v1/energy/analytics?period=day|week|month
pub async fn get_analytics(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Query(params): Query<EnergyQueryParams>,
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
                Json(serde_json::json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    // Đảm bảo bảng dbo.energy_logs có đầy đủ các cột cần thiết cho multi-tenant
    for alter_sql in [
        "IF COL_LENGTH(N'dbo.energy_logs', N'owner_id') IS NULL ALTER TABLE dbo.energy_logs ADD owner_id UNIQUEIDENTIFIER NULL",
        "IF COL_LENGTH(N'dbo.energy_logs', N'power_watt') IS NULL ALTER TABLE dbo.energy_logs ADD power_watt FLOAT NOT NULL DEFAULT 0",
        "IF COL_LENGTH(N'dbo.energy_logs', N'kwh_consumed') IS NULL ALTER TABLE dbo.energy_logs ADD kwh_consumed FLOAT NOT NULL DEFAULT 0",
        "IF COL_LENGTH(N'dbo.energy_logs', N'kwh') IS NULL ALTER TABLE dbo.energy_logs ADD kwh FLOAT NOT NULL DEFAULT 0",
        "IF COL_LENGTH(N'dbo.energy_logs', N'time') IS NULL ALTER TABLE dbo.energy_logs ADD [time] DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET()",
        "IF COL_LENGTH(N'dbo.energy_logs', N'recorded_at') IS NULL ALTER TABLE dbo.energy_logs ADD recorded_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET()",
    ] {
        let _ = conn.execute(alter_sql, &[]).await;
    }

    let raw_period = params
        .period
        .or(params.range)
        .or(params.timeframe)
        .unwrap_or_else(|| "week".to_string())
        .trim()
        .to_lowercase();

    let is_day = matches!(raw_period.as_str(), "day" | "ngay" | "today" | "24h");
    let lookback_days: i32 = match raw_period.as_str() {
        "day" | "ngay" | "today" | "24h" => 1,
        "month" | "thang" | "30d" => 30,
        _ => 7,
    };

    let series_query = if is_day {
        let sql = r#"
            WITH nums AS (
                SELECT 0 AS n
                UNION ALL
                SELECT n + 1 FROM nums WHERE n < 23
            ),
            hours AS (
                SELECT DATEADD(
                    HOUR,
                    n,
                    CAST(CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'SE Asia Standard Time' AS DATE) AS DATETIME2)
                ) AS hr
                FROM nums
            ),
            tenant_logs AS (
                SELECT
                    CAST(COALESCE(e.[time], e.recorded_at) AT TIME ZONE 'SE Asia Standard Time' AS DATETIME2) AS local_time,
                    COALESCE(e.power_watt, 0.0) AS power_watt,
                    COALESCE(e.kwh_consumed, e.kwh, 0.0) AS kwh_val
                FROM dbo.energy_logs e
                LEFT JOIN dbo.devices d ON e.device_id = d.id
                LEFT JOIN dbo.rooms r ON d.room_id = r.id
                LEFT JOIN dbo.houses h ON r.house_id = h.id
                WHERE e.owner_id = @P1 OR d.owner_id = @P1 OR h.owner_id = @P1
            )
            SELECT
                FORMAT(hr.hr, 'HH:00') AS label,
                CAST(COALESCE(SUM(e.kwh_val), 0.0) AS FLOAT) AS period_kwh,
                CAST(COALESCE(MAX(e.power_watt), 0.0) AS FLOAT) AS peak_watt
            FROM hours hr
            LEFT JOIN tenant_logs e
                ON e.local_time >= hr.hr AND e.local_time < DATEADD(HOUR, 1, hr.hr)
            GROUP BY hr.hr
            ORDER BY hr.hr ASC
        "#;
        let mut q = TSqlQuery::new(sql);
        q.bind(tenant_id);
        q
    } else {
        let span_offset: i32 = lookback_days - 1;
        let sql = r#"
            WITH nums AS (
                SELECT 0 AS n
                UNION ALL
                SELECT n + 1 FROM nums WHERE n < @P2
            ),
            days AS (
                SELECT DATEADD(
                    DAY,
                    n - @P2,
                    CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'SE Asia Standard Time' AS DATE)
                ) AS day_date
                FROM nums
            ),
            tenant_logs AS (
                SELECT
                    CAST(COALESCE(e.[time], e.recorded_at) AT TIME ZONE 'SE Asia Standard Time' AS DATE) AS local_date,
                    COALESCE(e.power_watt, 0.0) AS power_watt,
                    COALESCE(e.kwh_consumed, e.kwh, 0.0) AS kwh_val
                FROM dbo.energy_logs e
                LEFT JOIN dbo.devices d ON e.device_id = d.id
                LEFT JOIN dbo.rooms r ON d.room_id = r.id
                LEFT JOIN dbo.houses h ON r.house_id = h.id
                WHERE e.owner_id = @P1 OR d.owner_id = @P1 OR h.owner_id = @P1
            )
            SELECT
                FORMAT(d.day_date, 'dd/MM') AS label,
                CAST(COALESCE(SUM(e.kwh_val), 0.0) AS FLOAT) AS period_kwh,
                CAST(COALESCE(MAX(e.power_watt), 0.0) AS FLOAT) AS peak_watt
            FROM days d
            LEFT JOIN tenant_logs e
                ON e.local_date = d.day_date
            GROUP BY d.day_date
            ORDER BY d.day_date ASC
        "#;
        let mut q = TSqlQuery::new(sql);
        q.bind(tenant_id);
        q.bind(span_offset);
        q
    };

    let mut labels = Vec::new();
    let mut kwh_data = Vec::new();
    let mut chart_data = Vec::new();
    let mut total_kwh: f64 = 0.0;
    let mut peak_watt: f64 = 0.0;

    match series_query.query(&mut conn).await {
        Ok(stream) => {
            let records = stream.into_first_result().await.unwrap_or_default();
            for row in records {
                let kwh: f64 = row.get::<f64, _>("period_kwh").unwrap_or(0.0);
                let watt: f64 = row.get::<f64, _>("peak_watt").unwrap_or(0.0);
                let label: String = row.get::<&str, _>("label").unwrap_or("").to_string();

                let rounded_kwh = (kwh * 10000.0).round() / 10000.0;
                let rounded_watt = (watt * 10.0).round() / 10.0;

                labels.push(label.clone());
                kwh_data.push(rounded_kwh);
                chart_data.push(EnergyPoint {
                    label,
                    kwh: rounded_kwh,
                    power_watt: rounded_watt,
                });

                total_kwh += kwh;
                if rounded_watt > peak_watt {
                    peak_watt = rounded_watt;
                }
            }
        }
        Err(err) => {
            eprintln!("Lỗi truy vấn Database Energy: {:?}", err);
            labels = vec![
                "T2".into(),
                "T3".into(),
                "T4".into(),
                "T5".into(),
                "T6".into(),
                "T7".into(),
                "CN".into(),
            ];
            kwh_data = vec![0.0; 7];
        }
    }

    // Lấy 10 bản ghi chi tiết gần nhất thuộc đúng hộ gia đình (tenant_id)
    let logs_sql = r#"
        SELECT
            formatted_time,
            device_id,
            power_watt,
            kwh_consumed
        FROM (
            SELECT TOP 10
                COALESCE(e.[time], e.recorded_at) AS log_time,
                FORMAT(COALESCE(e.[time], e.recorded_at) AT TIME ZONE 'SE Asia Standard Time', 'HH:mm') AS formatted_time,
                COALESCE(CAST(e.device_id AS NVARCHAR(36)), N'') AS device_id,
                CAST(COALESCE(e.power_watt, 0.0) AS FLOAT) AS power_watt,
                CAST(COALESCE(e.kwh_consumed, e.kwh, 0.0) AS FLOAT) AS kwh_consumed
            FROM dbo.energy_logs e
            LEFT JOIN dbo.devices d ON e.device_id = d.id
            LEFT JOIN dbo.rooms r ON d.room_id = r.id
            LEFT JOIN dbo.houses h ON r.house_id = h.id
            WHERE (e.owner_id = @P1 OR d.owner_id = @P1 OR h.owner_id = @P1)
              AND COALESCE(e.[time], e.recorded_at) >= DATEADD(DAY, -@P2, SYSDATETIMEOFFSET())
            ORDER BY COALESCE(e.[time], e.recorded_at) DESC
        ) sub
        ORDER BY log_time ASC
    "#;

    let mut logs_q = TSqlQuery::new(logs_sql);
    logs_q.bind(tenant_id);
    logs_q.bind(lookback_days);

    let mut logs = Vec::new();
    if let Ok(stream) = logs_q.query(&mut conn).await {
        let log_rows = stream.into_first_result().await.unwrap_or_default();
        for r in log_rows {
            let formatted_time = r
                .get::<&str, _>("formatted_time")
                .unwrap_or("")
                .to_string();
            let device_id = r.get::<&str, _>("device_id").unwrap_or("").to_string();
            let watt = r.get::<f64, _>("power_watt").unwrap_or(0.0);
            let kwh = r.get::<f64, _>("kwh_consumed").unwrap_or(0.0);
            let rounded_kwh = (kwh * 10000.0).round() / 10000.0;

            logs.push(EnergyLogItem {
                time: formatted_time.clone(),
                label: formatted_time,
                device_id,
                power_watt: (watt * 10.0).round() / 10.0,
                kwh_consumed: rounded_kwh,
                kwh: rounded_kwh,
            });
        }
    }

    let rounded_total_kwh = (total_kwh * 10000.0).round() / 10000.0;
    let total_vnd = (rounded_total_kwh * 2500.0).round();

    (
        StatusCode::OK,
        Json(EnergyAnalyticsResponse {
            labels,
            kwh_data,
            total_kwh: rounded_total_kwh,
            total_vnd,
            estimated_cost: total_vnd,
            peak_watt,
            max_power_watt: peak_watt,
            daily: chart_data.clone(),
            chart_data,
            records: logs.clone(),
            logs,
        }),
    )
        .into_response()
}