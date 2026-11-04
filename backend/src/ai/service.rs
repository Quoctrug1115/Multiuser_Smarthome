use std::sync::Arc;
use chrono::{Timelike, Utc};
use serde_json::json;
use sqlx::Row;
use tokio::time::{sleep, Duration};

use crate::ai::anomaly::{detect_sensor_anomaly, is_unusual_time_window};

use crate::ws::handler::AppState;

pub async fn start_ai_worker(state: Arc<AppState>) {
    println!("🤖 [AI Service] Background worker started!");

    tokio::spawn(async move {
        loop {
            // Chạy chu kỳ quét 60 giây một lần
            sleep(Duration::from_secs(60)).await;

            // 1. Chạy phát hiện bất thường cảm biến
            run_anomaly_detection(&state).await;

            // 2. Chạy phân tích thói quen (Định kỳ mỗi giờ)
            let now = Utc::now();
            if now.minute() == 0 {
                run_habit_analysis(&state).await;
            }
        }
    });
}

async fn run_anomaly_detection(state: &Arc<AppState>) {
    // Lấy danh sách các cảm biến nhiệt độ
    let devices = sqlx::query("SELECT id FROM devices WHERE device_type = 'SENSOR'")
        .fetch_all(&state.db_pool)
        .await;

    if let Ok(device_rows) = devices {
        for row in device_rows {
            let device_id: uuid::Uuid = row.get("id");

            // Lấy 20 dữ liệu cảm biến gần nhất từ TimescaleDB
            let history_rows = sqlx::query(
                "SELECT value FROM sensor_data WHERE device_id = $1 ORDER BY time DESC LIMIT 20"
            )
            .bind(device_id)
            .fetch_all(&state.db_pool)
            .await;

            if let Ok(records) = history_rows {
                if records.is_empty() { continue; }

                let current_val: f64 = records[0].get("value");
                let past_vals: Vec<f64> = records.iter().skip(1).map(|r| r.get("value")).collect();

                if let Some((anomaly_type, z_score)) = detect_sensor_anomaly(&past_vals, current_val) {
                    let msg = format!("Thấy biến động bất thường! Giá trị: {}, Z-Score: {:.2}", current_val, z_score);

                    // Lưu vào DB
                    let _ = sqlx::query(
                        "INSERT INTO ai_alerts (device_id, alert_type, severity, message, metadata) VALUES ($1, $2, $3, $4, $5)"
                    )
                    .bind(device_id)
                    .bind(&anomaly_type)
                    .bind("HIGH")
                    .bind(&msg)
                    .bind(json!({ "current_value": current_val, "z_score": z_score }))
                    .execute(&state.db_pool)
                    .await;

                    // Broadcast báo động tức thì qua WebSocket tới ứng dụng
                    let alert_event = json!({
                        "event_type": "AI_ANOMALY_ALERT",
                        "device_id": device_id,
                        "alert_type": anomaly_type,
                        "message": msg
                    }).to_string();

                    let _ = state.tx_ws.send(alert_event);
                }
            }
        }
    }
}

async fn run_habit_analysis(_state: &Arc<AppState>) {
    // Quét lịch sử điều khiển thiết bị trong 14 ngày qua
    let current_hour = Utc::now().hour();
    if is_unusual_time_window(current_hour) {
        // Có thể áp dụng các luật bảo mật khung giờ đêm tại đây
    }
}