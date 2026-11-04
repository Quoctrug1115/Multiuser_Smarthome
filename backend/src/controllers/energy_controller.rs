use axum::{extract::State, Json};
use serde::Serialize;
use std::sync::Arc;
use sqlx::Row;
use crate::AppState;

#[derive(Serialize)]
pub struct EnergyAnalyticsResponse {
    pub labels: Vec<String>,
    pub kwh_data: Vec<f64>,
    pub total_kwh: f64,
    pub total_vnd: f64,
}

pub async fn get_analytics(
    State(state): State<Arc<AppState>>,
) -> Json<EnergyAnalyticsResponse> {
    let sql = r#"
        SELECT 
            TO_CHAR(d.day, 'DD/MM') as label,
            COALESCE(SUM(e.kwh_consumed), 0.0)::DOUBLE PRECISION as daily_kwh
        FROM generate_series(
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Ho_Chi_Minh')::date - INTERVAL '6 days',
            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
            INTERVAL '1 day'
        ) AS d(day)
        LEFT JOIN energy_logs e 
            ON DATE(e.time AT TIME ZONE 'Asia/Ho_Chi_Minh') = DATE(d.day)
        GROUP BY d.day
        ORDER BY d.day ASC
    "#;

    let rows = sqlx::query(sql)
        .fetch_all(&state.db_pool)
        .await;

    let mut labels = Vec::new();
    let mut kwh_data = Vec::new();
    let mut total_kwh: f64 = 0.0;

    match rows {
        Ok(records) => {
            for row in records {
                let kwh: f64 = row.try_get("daily_kwh").unwrap_or(0.0);
                let label: String = row.try_get("label").unwrap_or_default();

                labels.push(label);
                let rounded_kwh = (kwh * 1000.0).round() / 1000.0;
                kwh_data.push(rounded_kwh);
                total_kwh += kwh;
            }
        }
        Err(err) => {
            eprintln!("❌ Lỗi truy vấn Database Energy: {:?}", err);
            labels = vec!["T2".into(), "T3".into(), "T4".into(), "T5".into(), "T6".into(), "T7".into(), "CN".into()];
            kwh_data = vec![0.0; 7];
        }
    }

    let rounded_total_kwh = (total_kwh * 1000.0).round() / 1000.0;
    let total_vnd = (rounded_total_kwh * 2500.0).round();

    Json(EnergyAnalyticsResponse {
        labels,
        kwh_data,
        total_kwh: rounded_total_kwh,
        total_vnd,
    })
}