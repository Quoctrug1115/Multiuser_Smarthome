use std::sync::Arc;
use chrono::{Timelike, Utc};
use serde_json::json;
use tiberius::Query;
use tokio::time::{sleep, Duration};

use crate::ai::anomaly::{detect_sensor_anomaly, is_unusual_time_window};
use crate::AppState;

pub async fn start_ai_worker(state: Arc<AppState>) {
    println!("[AI Service] Background worker started!");

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
    let Ok(mut conn) = state.db_pool.get().await else {
        return;
    };

    // Lấy danh sách các cảm biến (kèm owner_id để phân tách cảnh báo theo từng hộ gia đình)
    let device_rows = match conn
        .query(
            "SELECT id, owner_id FROM dbo.devices WHERE LOWER(device_type) IN (N'sensor', N'dht22')",
            &[],
        )
        .await
    {
        Ok(stream) => stream.into_first_result().await.unwrap_or_default(),
        Err(_) => return,
    };

    for row in device_rows {
        let Some(device_id) = row.get::<uuid::Uuid, _>("id") else {
            continue;
        };
        let owner_id: Option<uuid::Uuid> = row.get::<uuid::Uuid, _>("owner_id");

        // Lấy 20 dữ liệu cảm biến gần nhất từ SQL Server (dùng TOP 20 thay cho LIMIT 20)
        let mut history_q = Query::new(
            "SELECT TOP 20 [value] FROM dbo.sensor_data WHERE device_id = @P1 ORDER BY [time] DESC",
        );
        history_q.bind(device_id);

        let records = match history_q.query(&mut conn).await {
            Ok(stream) => stream.into_first_result().await.unwrap_or_default(),
            Err(_) => continue,
        };

        if records.is_empty() {
            continue;
        }

        let Some(current_val) = records[0].get::<f64, _>("value") else {
            continue;
        };
        let past_vals: Vec<f64> = records
            .iter()
            .skip(1)
            .filter_map(|r| r.get::<f64, _>("value"))
            .collect();

        if let Some((anomaly_type, z_score)) = detect_sensor_anomaly(&past_vals, current_val) {
            let msg = format!(
                "Thấy biến động bất thường! Giá trị: {}, Z-Score: {:.2}",
                current_val, z_score
            );
            let metadata_str = json!({
                "current_value": current_val,
                "z_score": z_score
            })
            .to_string();

            // Lưu cảnh báo vào SQL Server
            let mut insert_q = Query::new(
                r#"
                INSERT INTO dbo.ai_alerts (id, device_id, owner_id, alert_type, severity, message, metadata, created_at)
                VALUES (NEWID(), @P1, @P2, @P3, @P4, @P5, @P6, SYSDATETIMEOFFSET())
                "#,
            );
            insert_q.bind(device_id);
            insert_q.bind(owner_id);
            insert_q.bind(&anomaly_type);
            insert_q.bind("HIGH");
            insert_q.bind(&msg);
            insert_q.bind(&metadata_str);

            let _ = insert_q.execute(&mut conn).await;

            // Broadcast báo động tức thì qua WebSocket tới ứng dụng
            let alert_event = json!({
                "type": "AI_ANOMALY_ALERT",
                "event_type": "AI_ANOMALY_ALERT",
                "device_id": device_id,
                "alert_type": anomaly_type,
                "message": msg
            })
            .to_string();

            let _ = state.tx.send(alert_event);
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