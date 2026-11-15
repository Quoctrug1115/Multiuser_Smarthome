use axum::{
    extract::{Query, State},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use std::sync::Arc;

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
    pub peak_watt: f64,
    pub max_power_watt: f64,
    pub chart_data: Vec<EnergyPoint>,
    pub logs: Vec<EnergyLogItem>,
    pub records: Vec<EnergyLogItem>,
}

pub async fn get_analytics(
    State(state): State<Arc<AppState>>,
    Query(params): Query<EnergyQueryParams>,
) -> Json<EnergyAnalyticsResponse> {
    let raw_period = params
        .period
        .or(params.range)
        .or(params.timeframe)
        .unwrap_or_else(|| "week".to_string())
        .trim()
        .to_lowercase();

    let (series_sql, interval_filter) = match raw_period.as_str() {
        "day" | "ngay" | "today" | "24h" => (
            r#"
            SELECT 
                TO_CHAR(h.hr, 'HH24:00') AS label,
                COALESCE(SUM(e.kwh_consumed), 0.0)::DOUBLE PRECISION AS period_kwh,
                COALESCE(MAX(e.power_watt), 0.0)::DOUBLE PRECISION AS peak_watt
            FROM generate_series(
                DATE_TRUNC('day', CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Ho_Chi_Minh'),
                DATE_TRUNC('day', CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Ho_Chi_Minh') + INTERVAL '23 hours',
                INTERVAL '1 hour'
            ) AS h(hr)
            LEFT JOIN energy_logs e 
                ON DATE_TRUNC('hour', e.time AT TIME ZONE 'Asia/Ho_Chi_Minh') = h.hr
            GROUP BY h.hr
            ORDER BY h.hr ASC
            "#,
            "INTERVAL '1 day'",
        ),
        "month" | "thang" | "30d" => (
            r#"
            SELECT 
                TO_CHAR(d.day, 'DD/MM') AS label,
                COALESCE(SUM(e.kwh_consumed), 0.0)::DOUBLE PRECISION AS period_kwh,
                COALESCE(MAX(e.power_watt), 0.0)::DOUBLE PRECISION AS peak_watt
            FROM generate_series(
                (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Ho_Chi_Minh')::date - INTERVAL '29 days',
                (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
                INTERVAL '1 day'
            ) AS d(day)
            LEFT JOIN energy_logs e 
                ON DATE(e.time AT TIME ZONE 'Asia/Ho_Chi_Minh') = DATE(d.day)
            GROUP BY d.day
            ORDER BY d.day ASC
            "#,
            "INTERVAL '30 days'",
        ),
        _ => (
            r#"
            SELECT 
                TO_CHAR(d.day, 'DD/MM') AS label,
                COALESCE(SUM(e.kwh_consumed), 0.0)::DOUBLE PRECISION AS period_kwh,
                COALESCE(MAX(e.power_watt), 0.0)::DOUBLE PRECISION AS peak_watt
            FROM generate_series(
                (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Ho_Chi_Minh')::date - INTERVAL '6 days',
                (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
                INTERVAL '1 day'
            ) AS d(day)
            LEFT JOIN energy_logs e 
                ON DATE(e.time AT TIME ZONE 'Asia/Ho_Chi_Minh') = DATE(d.day)
            GROUP BY d.day
            ORDER BY d.day ASC
            "#,
            "INTERVAL '7 days'",
        ),
    };

    let mut labels = Vec::new();
    let mut kwh_data = Vec::new();
    let mut chart_data = Vec::new();
    let mut total_kwh: f64 = 0.0;
    let mut peak_watt: f64 = 0.0;

    match sqlx::query(series_sql).fetch_all(&state.db_pool).await {
        Ok(records) => {
            for row in records {
                let kwh: f64 = row.try_get("period_kwh").unwrap_or(0.0);
                let watt: f64 = row.try_get("peak_watt").unwrap_or(0.0);
                let label: String = row.try_get("label").unwrap_or_default();

                let rounded_kwh = (kwh * 1000.0).round() / 1000.0;
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
            eprintln!("❌ Lỗi truy vấn Database Energy: {:?}", err);
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

    // Lấy danh sách bản ghi chi tiết từ energy_logs để hiển thị biểu đồ/bảng trên Mobile
    let logs_sql = format!(
        r#"
        SELECT 
            TO_CHAR(time AT TIME ZONE 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM') AS formatted_time,
            device_id::text AS device_id,
            COALESCE(power_watt, 0.0)::DOUBLE PRECISION AS power_watt,
            COALESCE(kwh_consumed, 0.0)::DOUBLE PRECISION AS kwh_consumed
        FROM energy_logs
        WHERE time >= NOW() - {}
        ORDER BY time DESC
        LIMIT 50
        "#,
        interval_filter
    );

    let mut logs = Vec::new();
    if let Ok(log_rows) = sqlx::query(&logs_sql).fetch_all(&state.db_pool).await {
        for r in log_rows {
            let formatted_time: String = r.try_get("formatted_time").unwrap_or_default();
            let device_id: String = r.try_get("device_id").unwrap_or_default();
            let watt: f64 = r.try_get("power_watt").unwrap_or(0.0);
            let kwh: f64 = r.try_get("kwh_consumed").unwrap_or(0.0);
            let rounded_kwh = (kwh * 1000.0).round() / 1000.0;

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

    let rounded_total_kwh = (total_kwh * 1000.0).round() / 1000.0;
    let total_vnd = (rounded_total_kwh * 2500.0).round();

    Json(EnergyAnalyticsResponse {
        labels,
        kwh_data,
        total_kwh: rounded_total_kwh,
        total_vnd,
        peak_watt,
        max_power_watt: peak_watt,
        chart_data,
        records: logs.clone(),
        logs,
    })
}