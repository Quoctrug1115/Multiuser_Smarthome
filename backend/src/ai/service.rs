use chrono::{Local, Timelike, Utc};
use serde_json::{json, Value};
use std::sync::Arc;
use tiberius::Query;
use tokio::time::{sleep, Duration};
use uuid::Uuid;

use crate::ai::anomaly::{detect_sensor_anomaly, is_unusual_time_window};
use crate::ai::habit::{mine_device_habits, ControlHistoryRecord};
use crate::controllers::ai_controller::ensure_ai_suggestions_schema;
use crate::{AppState, SqlPool};

pub async fn start_ai_worker(state: Arc<AppState>) {
    println!("[AI Service] Background worker started (Anomaly + Smart Suggestions)!");

    tokio::spawn(async move {
        // Quét gợi ý lần đầu sau khi khởi động 15 giây
        sleep(Duration::from_secs(15)).await;
        let _ = run_smart_suggestions(&state, None).await;

        let mut tick_count: u64 = 0;
        loop {
            // Chu kỳ quét 60 giây một lần
            sleep(Duration::from_secs(60)).await;
            tick_count += 1;

            // 1. Chạy phát hiện bất thường cảm biến (giữ nguyên)
            run_anomaly_detection(&state).await;

            // 2. Chạy phân tích gợi ý thông minh mỗi 15 phút (hoặc đầu mỗi giờ)
            let now = Utc::now();
            if tick_count % 15 == 0 || now.minute() == 0 {
                let _ = run_smart_suggestions(&state, None).await;
            }
        }
    });
}

async fn run_anomaly_detection(state: &Arc<AppState>) {
    let Ok(mut conn) = state.db_pool.get().await else {
        return;
    };

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
        let Some(device_id) = row.get::<Uuid, _>("id") else {
            continue;
        };
        let owner_id: Option<Uuid> = row.get::<Uuid, _>("owner_id");

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

/// Kiểm tra xem gợi ý tương tự đã tồn tại (PENDING) hoặc vừa bị từ chối trong 24h chưa
async fn suggestion_already_exists(
    pool: &SqlPool,
    owner_id: Uuid,
    device_id: Uuid,
    suggestion_type: &str,
    signature: &str,
) -> bool {
    let Ok(mut conn) = pool.get().await else {
        return true;
    };

    let mut q = Query::new(
        r#"
        SELECT TOP 1 id
        FROM dbo.ai_suggestions
        WHERE owner_id = @P1
          AND device_id = @P2
          AND suggestion_type = @P3
          AND (
              status = N'PENDING'
              OR (status = N'DISMISSED' AND created_at > DATEADD(HOUR, -24, SYSDATETIMEOFFSET()))
          )
          AND suggested_action LIKE @P4
        "#,
    );
    q.bind(owner_id);
    q.bind(device_id);
    q.bind(suggestion_type);
    q.bind(format!("%{}%", signature));

    let response = match q.query(&mut conn).await {
        Ok(stream) => stream.into_row().await.ok().flatten().is_some(),
        Err(_) => false,
    };
    response
}

/// Lưu gợi ý mới vào SQL Server và phát sự kiện WebSocket `AI_SUGGESTION`
async fn save_and_broadcast_suggestion(
    state: &Arc<AppState>,
    owner_id: Uuid,
    device_id: Uuid,
    device_name: &str,
    room_name: Option<&str>,
    suggestion_type: &str,
    title: &str,
    description: &str,
    suggested_action: Value,
    cron_expression: Option<&str>,
    confidence_score: f64,
) -> bool {
    let Ok(mut conn) = state.db_pool.get().await else {
        return false;
    };

    let sug_id = Uuid::new_v4();
    let action_json_str = suggested_action.to_string();

    let mut insert_q = Query::new(
        r#"
        INSERT INTO dbo.ai_suggestions (
            id, user_id, owner_id, device_id, suggestion_type,
            title, description, suggested_action, cron_expression,
            confidence_score, status, is_applied, created_at
        )
        VALUES (
            @P1, @P2, @P2, @P3, @P4,
            @P5, @P6, @P7, @P8,
            @P9, N'PENDING', 0, SYSDATETIMEOFFSET()
        )
        "#,
    );
    insert_q.bind(sug_id);
    insert_q.bind(owner_id);
    insert_q.bind(device_id);
    insert_q.bind(suggestion_type);
    insert_q.bind(title);
    insert_q.bind(description);
    insert_q.bind(&action_json_str);
    insert_q.bind(cron_expression);
    insert_q.bind(confidence_score);

    if insert_q.execute(&mut conn).await.is_err() {
        return false;
    }

    let now_str = Local::now().format("%H:%M:%S %d/%m").to_string();
    let ws_payload = json!({
        "type": "AI_SUGGESTION",
        "data": {
            "id": sug_id.to_string(),
            "owner_id": owner_id.to_string(),
            "device_id": device_id.to_string(),
            "device_name": device_name,
            "room_name": room_name,
            "suggestion_type": suggestion_type,
            "title": title,
            "description": description,
            "suggested_action": suggested_action,
            "cron_expression": cron_expression,
            "confidence_score": confidence_score,
            "status": "PENDING",
            "created_at": now_str
        }
    });
    let _ = state.tx.send(ws_payload.to_string());
    true
}

/// Phân tích thói quen, ngữ cảnh cảm biến và tiết kiệm điện để sinh gợi ý cho người dùng
pub async fn run_smart_suggestions(
    state: &Arc<AppState>,
    target_tenant: Option<Uuid>,
) -> usize {
    ensure_ai_suggestions_schema(&state.db_pool).await;

    let Ok(mut conn) = state.db_pool.get().await else {
        return 0;
    };

    let mut created_count: usize = 0;

    // ------------------------------------------------------------------------
    // BỘ GỢI Ý 1: KHAI PHÁ THÓI QUEN ĐIỀU KHIỂN THEO KHUNG GIỜ (14 NGÀY GẦN NHẤT)
    // ------------------------------------------------------------------------
    let logs_sql = if target_tenant.is_some() {
        r#"
        SELECT
            COALESCE(l.owner_id, d.owner_id, h.owner_id) AS tenant_id,
            d.id AS device_id,
            d.name AS device_name,
            r.name AS room_name,
            l.data,
            FORMAT(l.created_at AT TIME ZONE 'SE Asia Standard Time', 'yyyy-MM-dd') AS day_key,
            DATEPART(HOUR, l.created_at AT TIME ZONE 'SE Asia Standard Time') AS log_hour,
            DATEPART(MINUTE, l.created_at AT TIME ZONE 'SE Asia Standard Time') AS log_minute
        FROM dbo.device_logs l
        INNER JOIN dbo.devices d ON l.device_id = d.id
        LEFT JOIN dbo.rooms r ON d.room_id = r.id
        LEFT JOIN dbo.houses h ON r.house_id = h.id
        WHERE l.event_type = N'MANUAL_CONTROL'
          AND l.created_at >= DATEADD(DAY, -14, SYSDATETIMEOFFSET())
          AND COALESCE(l.owner_id, d.owner_id, h.owner_id) = @P1
        "#
    } else {
        r#"
        SELECT
            COALESCE(l.owner_id, d.owner_id, h.owner_id) AS tenant_id,
            d.id AS device_id,
            d.name AS device_name,
            r.name AS room_name,
            l.data,
            FORMAT(l.created_at AT TIME ZONE 'SE Asia Standard Time', 'yyyy-MM-dd') AS day_key,
            DATEPART(HOUR, l.created_at AT TIME ZONE 'SE Asia Standard Time') AS log_hour,
            DATEPART(MINUTE, l.created_at AT TIME ZONE 'SE Asia Standard Time') AS log_minute
        FROM dbo.device_logs l
        INNER JOIN dbo.devices d ON l.device_id = d.id
        LEFT JOIN dbo.rooms r ON d.room_id = r.id
        LEFT JOIN dbo.houses h ON r.house_id = h.id
        WHERE l.event_type = N'MANUAL_CONTROL'
          AND l.created_at >= DATEADD(DAY, -14, SYSDATETIMEOFFSET())
          AND COALESCE(l.owner_id, d.owner_id, h.owner_id) IS NOT NULL
        "#
    };

    let log_rows = {
        let mut q = Query::new(logs_sql);
        if let Some(tid) = target_tenant {
            q.bind(tid);
        }
        match q.query(&mut conn).await {
            Ok(stream) => stream.into_first_result().await.unwrap_or_default(),
            Err(_) => Vec::new(),
        }
    };

    let mut history_records = Vec::new();
    let mut room_lookup: std::collections::HashMap<Uuid, String> = std::collections::HashMap::new();

    for row in log_rows {
        let Some(tenant_id) = row.get::<Uuid, _>("tenant_id") else {
            continue;
        };
        let Some(device_id) = row.get::<Uuid, _>("device_id") else {
            continue;
        };
        let device_name = row.get::<&str, _>("device_name").unwrap_or("Thiết bị").to_string();
        if let Some(rn) = row.get::<&str, _>("room_name") {
            room_lookup.insert(device_id, rn.to_string());
        }

        let raw_data = row.get::<&str, _>("data").unwrap_or("{}");
        let parsed: Value = serde_json::from_str(raw_data).unwrap_or_else(|_| json!({}));
        let action = parsed
            .get("action")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_uppercase();

        let day_key = row.get::<&str, _>("day_key").unwrap_or("").to_string();
        let hour = row.get::<i32, _>("log_hour").unwrap_or(0).max(0) as u32;
        let minute = row.get::<i32, _>("log_minute").unwrap_or(0).max(0) as u32;
        let minute_slot = if minute >= 30 { 30 } else { 0 };

        if !day_key.is_empty() && (action == "ON" || action == "OFF") {
            history_records.push(ControlHistoryRecord {
                owner_id: tenant_id,
                device_id,
                device_name,
                action,
                hour,
                minute_slot,
                day_key,
            });
        }
    }

    // Yêu cầu tối thiểu 3 ngày lặp lại, độ tin cậy >= 70%
    let habit_recs = mine_device_habits(&history_records, 3, 0.70);
    for rec in habit_recs {
        let time_str = format!("{:02}:{:02}", rec.hour, rec.minute_slot);
        let signature = format!("\"time\":\"{}\"", time_str);

        if suggestion_already_exists(
            &state.db_pool,
            rec.owner_id,
            rec.device_id,
            "HABIT",
            &signature,
        )
        .await
        {
            continue;
        }

        let action_vi = if rec.action == "ON" { "Bật" } else { "Tắt" };
        let title = format!("Thói quen: {} {} lúc {}", action_vi, rec.device_name, time_str);
        let description = format!(
            "Bạn đã {} {} vào khoảng {} trong {} ngày gần đây. Bạn có muốn tạo kịch bản tự động thực hiện việc này không?",
            action_vi.to_lowercase(),
            rec.device_name,
            time_str,
            rec.repeat_days
        );

        let suggested_action = json!({
            "mode": "AUTOMATION",
            "action": rec.action,
            "time": time_str,
            "device_id": rec.device_id.to_string(),
            "rule_name": format!("Tự động {} {} ({})", action_vi.to_lowercase(), rec.device_name, time_str),
            "condition_text": format!("Thời gian đạt {}", time_str),
            "action_text": format!("{} {}", action_vi, rec.device_name)
        });

        let rn = room_lookup.get(&rec.device_id).map(|s| s.as_str());
        if save_and_broadcast_suggestion(
            state,
            rec.owner_id,
            rec.device_id,
            &rec.device_name,
            rn,
            "HABIT",
            &title,
            &description,
            suggested_action,
            Some(&rec.cron_expression),
            rec.confidence_score,
        )
        .await
        {
            created_count += 1;
        }
    }

    // ------------------------------------------------------------------------
    // BỘ GỢI Ý 2 & 3: NGỮ CẢNH CẢM BIẾN (COMFORT) & TIẾT KIỆM ĐIỆN (ENERGY)
    // ------------------------------------------------------------------------
    let cached_sensor = { state.latest_sensor.read().await.clone() };
    let sensor_data_obj = cached_sensor
        .as_ref()
        .and_then(|v| v.get("data"))
        .cloned()
        .unwrap_or_else(|| json!({}));

    let cur_temp = sensor_data_obj.get("temperature").and_then(|v| v.as_f64());
    let cur_lux = sensor_data_obj.get("lux").and_then(|v| v.as_f64());
    let cur_motion = sensor_data_obj.get("motion").and_then(|v| v.as_bool());

    let devices_sql = if target_tenant.is_some() {
        r#"
        SELECT
            d.id,
            COALESCE(d.owner_id, h.owner_id) AS tenant_id,
            d.name,
            COALESCE(d.device_type, N'switch') AS device_type,
            ISNULL(d.is_on, 0) AS is_on,
            r.name AS room_name,
            DATEDIFF(MINUTE, COALESCE(d.last_seen, SYSDATETIMEOFFSET()), SYSDATETIMEOFFSET()) AS mins_since_change
        FROM dbo.devices d
        LEFT JOIN dbo.rooms r ON d.room_id = r.id
        LEFT JOIN dbo.houses h ON r.house_id = h.id
        WHERE COALESCE(d.owner_id, h.owner_id) = @P1
        "#
    } else {
        r#"
        SELECT
            d.id,
            COALESCE(d.owner_id, h.owner_id) AS tenant_id,
            d.name,
            COALESCE(d.device_type, N'switch') AS device_type,
            ISNULL(d.is_on, 0) AS is_on,
            r.name AS room_name,
            DATEDIFF(MINUTE, COALESCE(d.last_seen, SYSDATETIMEOFFSET()), SYSDATETIMEOFFSET()) AS mins_since_change
        FROM dbo.devices d
        LEFT JOIN dbo.rooms r ON d.room_id = r.id
        LEFT JOIN dbo.houses h ON r.house_id = h.id
        WHERE COALESCE(d.owner_id, h.owner_id) IS NOT NULL
        "#
    };

    let dev_rows = {
        let mut q = Query::new(devices_sql);
        if let Some(tid) = target_tenant {
            q.bind(tid);
        }
        match q.query(&mut conn).await {
            Ok(stream) => stream.into_first_result().await.unwrap_or_default(),
            Err(_) => Vec::new(),
        }
    };

    let current_local_hour = Local::now().hour();

    for row in dev_rows {
        let Some(device_id) = row.get::<Uuid, _>("id") else {
            continue;
        };
        let Some(owner_id) = row.get::<Uuid, _>("tenant_id") else {
            continue;
        };
        let device_name = row.get::<&str, _>("name").unwrap_or("Thiết bị").to_string();
        let dtype = row
            .get::<&str, _>("device_type")
            .unwrap_or("switch")
            .to_lowercase();
        let is_on = row.get::<bool, _>("is_on").unwrap_or(false);
        let room_name = row.get::<&str, _>("room_name").map(|s| s.to_string());
        let mins_since = row.get::<i32, _>("mins_since_change").unwrap_or(0);

        // 2A. Nhiệt độ >= 31°C nhưng Quạt/Điều hòa đang TẮT -> Gợi ý BẬT làm mát
        if !is_on && (dtype.contains("fan") || dtype.contains("ac") || dtype.contains("air")) {
            if let Some(temp) = cur_temp {
                if temp >= 31.0 {
                    let sig = "\"reason\":\"HIGH_TEMP\"";
                    if !suggestion_already_exists(
                        &state.db_pool,
                        owner_id,
                        device_id,
                        "COMFORT",
                        sig,
                    )
                    .await
                    {
                        let title = format!("Nhiệt độ cao ({:.1}°C): Bật {}", temp, device_name);
                        let desc = format!(
                            "Cảm biến ghi nhận nhiệt độ phòng đang ở mức {:.1}°C trong khi {} đang tắt. Bật ngay để làm mát không gian?",
                            temp, device_name
                        );
                        let action_json = json!({
                            "mode": "INSTANT",
                            "action": "ON",
                            "reason": "HIGH_TEMP",
                            "device_id": device_id.to_string(),
                            "rule_name": format!("Tự bật {} khi nóng > 31°C", device_name),
                            "condition_text": "Nhiệt độ > 31",
                            "action_text": format!("Bật {}", device_name)
                        });

                        if save_and_broadcast_suggestion(
                            state,
                            owner_id,
                            device_id,
                            &device_name,
                            room_name.as_deref(),
                            "COMFORT",
                            &title,
                            &desc,
                            action_json,
                            None,
                            0.88,
                        )
                        .await
                        {
                            created_count += 1;
                        }
                    }
                }
            }
        }

        // 2B. Ánh sáng yếu (< 50 Lux) + có người (motion == true) nhưng Đèn đang TẮT
        if !is_on && dtype.contains("light") {
            if let (Some(lux), Some(true)) = (cur_lux, cur_motion) {
                if lux < 50.0 {
                    let sig = "\"reason\":\"DARK_WITH_MOTION\"";
                    if !suggestion_already_exists(
                        &state.db_pool,
                        owner_id,
                        device_id,
                        "COMFORT",
                        sig,
                    )
                    .await
                    {
                        let title = format!("Phát hiện người trong phòng tối: Bật {}", device_name);
                        let desc = format!(
                            "Độ sáng hiện tại chỉ {:.0} Lux và có chuyển động trong phòng. Bật {} ngay?",
                            lux, device_name
                        );
                        let action_json = json!({
                            "mode": "INSTANT",
                            "action": "ON",
                            "reason": "DARK_WITH_MOTION",
                            "device_id": device_id.to_string()
                        });

                        if save_and_broadcast_suggestion(
                            state,
                            owner_id,
                            device_id,
                            &device_name,
                            room_name.as_deref(),
                            "COMFORT",
                            &title,
                            &desc,
                            action_json,
                            None,
                            0.85,
                        )
                        .await
                        {
                            created_count += 1;
                        }
                    }
                }
            }
        }

        // 3. Tiết kiệm điện: Thiết bị tiêu thụ điện đang BẬT > 240 phút (4 giờ) hoặc bật khuya không người
        let is_consumable = dtype != "sensor" && dtype != "dht22";
        let idle_long = mins_since >= 240;
        let late_night_no_motion =
            is_unusual_time_window(current_local_hour) && cur_motion == Some(false) && mins_since >= 45;

        if is_on && is_consumable && (idle_long || late_night_no_motion) {
            let sig = "\"reason\":\"ENERGY_SAVE\"";
            if !suggestion_already_exists(
                &state.db_pool,
                owner_id,
                device_id,
                "ENERGY",
                sig,
            )
            .await
            {
                let hours_on = (mins_since as f64 / 60.0).max(1.0);
                let title = format!("Tiết kiệm điện: Tắt {}", device_name);
                let desc = if late_night_no_motion {
                    format!(
                        "{} vẫn đang bật trong khung giờ đêm khuya và phòng không có chuyển động. Tắt ngay để tiết kiệm điện?",
                        device_name
                    )
                } else {
                    format!(
                        "{} đã bật liên tục khoảng {:.1} giờ. Bạn có muốn tắt thiết bị để tránh lãng phí điện năng?",
                        device_name, hours_on
                    )
                };
                let action_json = json!({
                    "mode": "INSTANT",
                    "action": "OFF",
                    "reason": "ENERGY_SAVE",
                    "device_id": device_id.to_string()
                });

                if save_and_broadcast_suggestion(
                    state,
                    owner_id,
                    device_id,
                    &device_name,
                    room_name.as_deref(),
                    "ENERGY",
                    &title,
                    &desc,
                    action_json,
                    None,
                    0.83,
                )
                .await
                {
                    created_count += 1;
                }
            }
        }
    }

    created_count
}