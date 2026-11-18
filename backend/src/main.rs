use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::State,
    response::IntoResponse,
    routing::{delete, get, post, put},
    Router,
};
use rumqttc::{AsyncClient, Event, Incoming, MqttOptions, QoS};
use serde::{Deserialize, Serialize};
use sqlx::postgres::PgPoolOptions;
use sqlx::Row;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, RwLock};
use tower_http::cors::{Any, CorsLayer};

pub mod controllers;
pub mod models;
pub mod services;
pub mod ws;

pub struct AppState {
    pub db_pool: sqlx::PgPool,
    pub tx: broadcast::Sender<String>,
    pub mqtt_client: AsyncClient,
    pub discovered_devices: RwLock<HashMap<String, serde_json::Value>>,
    pub latest_sensor: RwLock<Option<serde_json::Value>>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct WsMessage {
    pub r#type: String,
    pub data: serde_json::Value,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();
    println!("🚀 Đang khởi động Backend SmartHome Axum Engine...");

    // 1. Kết nối Database PostgreSQL / TimescaleDB
    let db_url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://postgres:123456@localhost:5434/smarthome".to_string());

    let pool = PgPoolOptions::new()
        .max_connections(20)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&db_url)
        .await?;
    println!("✅ Kết nối Database thành công: {}", db_url);

    // Đảm bảo cấu trúc bảng energy_logs hỗ trợ đầy đủ multi-tenant (owner_id) và các cột thời gian
    let _ = sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS energy_logs (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            device_id UUID,
            owner_id UUID,
            power_watt DOUBLE PRECISION DEFAULT 0,
            kwh_consumed DOUBLE PRECISION DEFAULT 0,
            kwh DOUBLE PRECISION DEFAULT 0,
            time TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
            recorded_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
        );
        "#,
    )
    .execute(&pool)
    .await;

    for alter_sql in [
        "ALTER TABLE energy_logs ADD COLUMN IF NOT EXISTS owner_id UUID",
        "ALTER TABLE energy_logs ADD COLUMN IF NOT EXISTS power_watt DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE energy_logs ADD COLUMN IF NOT EXISTS kwh_consumed DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE energy_logs ADD COLUMN IF NOT EXISTS kwh DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE energy_logs ADD COLUMN IF NOT EXISTS time TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP",
        "ALTER TABLE energy_logs ADD COLUMN IF NOT EXISTS recorded_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP",
    ] {
        let _ = sqlx::query(alter_sql).execute(&pool).await;
    }

    // 2. Khởi tạo Kênh Broadcast WebSocket
    let (tx, _rx) = broadcast::channel::<String>(100);

    // 3. Khởi tạo MQTT Client kết nối tới Broker EMQX
    let client_id = format!("rust_axum_hub_{}", &uuid::Uuid::new_v4().to_string()[..8]);
    let mut mqttoptions = MqttOptions::new(client_id, "broker.emqx.io", 1883);
    mqttoptions.set_keep_alive(Duration::from_secs(15));

    let (mqtt_client, mut eventloop) = AsyncClient::new(mqttoptions, 20);
    mqtt_client
        .subscribe("smarthome/sensors/#", QoS::AtMostOnce)
        .await?;
    mqtt_client
        .subscribe("smarthome/discovery", QoS::AtMostOnce)
        .await?;
    println!("✅ MQTT Worker: Đã Subscribe 'smarthome/sensors/#' & 'smarthome/discovery'");

    let state = Arc::new(AppState {
        db_pool: pool,
        tx: tx.clone(),
        mqtt_client,
        discovered_devices: RwLock::new(HashMap::new()),
        latest_sensor: RwLock::new(None),
    });

    // 4A. Luồng MQTT Worker nhận dữ liệu cảm biến & discovery từ ESP32 Wokwi
    let state_mqtt = state.clone();
    tokio::spawn(async move {
        loop {
            match eventloop.poll().await {
                Ok(Event::Incoming(Incoming::Publish(publish))) => {
                    // Nhánh 1: Thiết bị tự báo danh qua MQTT Discovery
                    if publish.topic == "smarthome/discovery" {
                        if let Ok(device_json) =
                            serde_json::from_slice::<serde_json::Value>(&publish.payload)
                        {
                            if let Some(topic) =
                                device_json.get("mqtt_topic").and_then(|v| v.as_str())
                            {
                                let mut discovered = state_mqtt.discovered_devices.write().await;
                                discovered.insert(topic.to_string(), device_json.clone());
                                println!("📡 [WOKWI DISCOVERY] Phát hiện thiết bị: {}", topic);
                            }
                        }
                        continue;
                    }

                    // Nhánh 2: Dữ liệu cảm biến môi trường (DHT22 / LDR / PIR)
                    if publish.topic.starts_with("smarthome/sensors") {
                        if let Ok(raw_json) =
                            serde_json::from_slice::<serde_json::Value>(&publish.payload)
                        {
                            let temperature = raw_json
                                .get("temperature")
                                .or_else(|| raw_json.get("temp"))
                                .and_then(|v| v.as_f64())
                                .unwrap_or(0.0);
                            let humidity = raw_json
                                .get("humidity")
                                .or_else(|| raw_json.get("hum"))
                                .and_then(|v| v.as_f64())
                                .unwrap_or(0.0);
                            let lux = raw_json
                                .get("lux")
                                .or_else(|| raw_json.get("light"))
                                .and_then(|v| v.as_f64())
                                .unwrap_or(450.0) as i32;
                            let motion = raw_json
                                .get("motion")
                                .or_else(|| raw_json.get("pir"))
                                .map(|v| {
                                    v.as_bool()
                                        .unwrap_or_else(|| v.as_i64().unwrap_or(0) > 0)
                                })
                                .unwrap_or(false);

                            println!(
                                "📩 [MQTT SENSOR] Topic: {} | Temp: {:.1}°C | Hum: {:.0}% | Lux: {} | Motion: {}",
                                publish.topic, temperature, humidity, lux, motion
                            );

                            let ws_msg = serde_json::json!({
                                "type": "SENSOR_UPDATE",
                                "data": {
                                    "topic": publish.topic,
                                    "temperature": temperature,
                                    "humidity": humidity,
                                    "lux": lux,
                                    "motion": motion
                                }
                            });

                            // Lưu cache chỉ số gần nhất để client mới/F5 nhận được ngay lập tức
                            {
                                let mut latest = state_mqtt.latest_sensor.write().await;
                                *latest = Some(ws_msg.clone());
                            }

                            if let Ok(json_str) = serde_json::to_string(&ws_msg) {
                                let _ = state_mqtt.tx.send(json_str);
                            }

                            let pool_clone = state_mqtt.db_pool.clone();
                            let mqtt_clone = state_mqtt.mqtt_client.clone();
                            let tx_clone = state_mqtt.tx.clone();

                            tokio::spawn(async move {
                                evaluate_automations(
                                    &pool_clone,
                                    &mqtt_clone,
                                    &tx_clone,
                                    temperature,
                                    humidity,
                                    lux as f64,
                                    if motion { 1.0 } else { 0.0 },
                                )
                                .await;
                            });
                        }
                    }
                }
                Ok(_) => {}
                Err(_) => {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            }
        }
    });

    // 4B. Luồng đo đếm điện năng tiêu thụ mỗi 15 giây cho các thiết bị đang BẬT theo từng Chủ nhà
    let state_meter = state.clone();
    tokio::spawn(async move {
        let interval_secs: f64 = 15.0;
        loop {
            tokio::time::sleep(Duration::from_secs(interval_secs as u64)).await;

            let active_rows = match sqlx::query(
                r#"
                SELECT
                    d.id,
                    COALESCE(d.owner_id, h.owner_id) AS tenant_id,
                    COALESCE(d.device_type, 'switch') AS device_type
                FROM devices d
                LEFT JOIN rooms r ON d.room_id = r.id
                LEFT JOIN houses h ON r.house_id = h.id
                WHERE COALESCE(d.is_on, false) = true
                  AND COALESCE(d.owner_id, h.owner_id) IS NOT NULL
                "#,
            )
            .fetch_all(&state_meter.db_pool)
            .await
            {
                Ok(rows) => rows,
                Err(_) => continue,
            };

            for row in active_rows {
                let Ok(device_id) = row.try_get::<uuid::Uuid, _>("id") else {
                    continue;
                };
                let Ok(tenant_id) = row.try_get::<uuid::Uuid, _>("tenant_id") else {
                    continue;
                };
                let dtype: String = row.try_get("device_type").unwrap_or_default();

                let watt: f64 = match dtype.to_lowercase().as_str() {
                    "ac" | "heater" => 1200.0,
                    "fan" => 45.0,
                    "light" => 15.0,
                    "sensor" => 2.0,
                    _ => 25.0,
                };

                // kWh tiêu thụ trong 15 giây = (Watt / 1000) * (15 / 3600)
                let kwh = (watt / 1000.0) * (interval_secs / 3600.0);

                let _ = sqlx::query(
                    r#"
                    INSERT INTO energy_logs (id, device_id, owner_id, power_watt, kwh_consumed, kwh, time, recorded_at)
                    VALUES ($1, $2, $3, $4, $5, $5, NOW(), NOW())
                    "#,
                )
                .bind(uuid::Uuid::new_v4())
                .bind(device_id)
                .bind(tenant_id)
                .bind(watt)
                .bind(kwh)
                .execute(&state_meter.db_pool)
                .await;
            }
        }
    });

    // 5. Cấu hình Router và API Endpoints (Axum 0.8)
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = Router::new()
        .route("/ws", get(ws_handler))
        .route("/api/v1/auth/login", post(controllers::auth_controller::login))
        .route("/api/v1/auth/register", post(controllers::auth_controller::register))
        .route("/api/v1/auth/me", get(controllers::auth_controller::me))
        .route("/api/v1/devices", get(controllers::device_controller::get_devices))
        .route("/api/v1/devices", post(controllers::device_controller::create_device))
        .route("/api/v1/devices/discover", get(controllers::device_controller::discover_devices))
        .route("/api/v1/devices/{id}", put(controllers::device_controller::update_device))
        .route("/api/v1/devices/{id}", delete(controllers::device_controller::delete_device))
        .route("/api/v1/devices/{id}/control", post(controllers::device_controller::control_device))
        .route("/api/v1/automations", get(controllers::automation_controller::get_automations))
        .route("/api/v1/automations", post(controllers::automation_controller::create_automation))
        .route(
            "/api/v1/automations/{id}",
            axum::routing::put(controllers::automation_controller::toggle_automation)
                .patch(controllers::automation_controller::toggle_automation)
                .delete(controllers::automation_controller::delete_automation),
        )
        .route(
            "/api/v1/automations/{id}/toggle",
            axum::routing::post(controllers::automation_controller::toggle_automation)
                .put(controllers::automation_controller::toggle_automation)
                .patch(controllers::automation_controller::toggle_automation),
        )
        .route("/api/v1/energy/analytics", get(controllers::energy_controller::get_analytics))
        .route("/api/v1/users", get(controllers::user_controller::get_users))
        .route("/api/v1/users", post(controllers::user_controller::create_user))
        .route("/api/v1/users/{id}", put(controllers::user_controller::update_user))
        .route("/api/v1/users/{id}", delete(controllers::user_controller::delete_user))
        .route("/api/v1/ai/alerts", get(controllers::ai_controller::get_alerts))
        .route("/api/v1/ai/simulate-anomaly", post(controllers::ai_controller::simulate_anomaly))
        .route("/api/v1/guests", get(controllers::guest_controller::get_guests))
        .route("/api/v1/guests/{id}/revoke", post(controllers::guest_controller::revoke_guest))
        .route(
            "/api/v1/houses",
            get(controllers::house_controller::get_houses)
                .post(controllers::house_controller::create_house),
        )
        .route(
            "/api/v1/houses/{id}",
            put(controllers::house_controller::update_house)
                .delete(controllers::house_controller::delete_house),
        )
        .route(
            "/api/v1/rooms",
            get(controllers::room_controller::get_rooms)
                .post(controllers::room_controller::create_room),
        )
        .route(
            "/api/v1/rooms/{id}",
            put(controllers::room_controller::update_room)
                .delete(controllers::room_controller::delete_room),
        )
        .layer(cors)
        .with_state(state);

    // 6. Lắng nghe trên cổng 3000
    let addr = SocketAddr::from(([0, 0, 0, 0], 3000));
    println!("🌐 Server đang lắng nghe tại http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ws.on_upgrade(|socket| handle_socket(socket, state))
}

async fn handle_socket(mut socket: WebSocket, state: Arc<AppState>) {
    let mut rx = state.tx.subscribe();
    println!("⚡ Client WebSocket đã kết nối!");

    // Gửi ngay chỉ số cảm biến gần nhất (nếu có) khi trình duyệt vừa kết nối/F5
    let cached_sensor = { state.latest_sensor.read().await.clone() };
    if let Some(sensor_val) = cached_sensor {
        if let Ok(msg_str) = serde_json::to_string(&sensor_val) {
            let _ = socket.send(Message::Text(msg_str.into())).await;
        }
    }

    loop {
        tokio::select! {
            Ok(msg) = rx.recv() => {
                if socket.send(Message::Text(msg.into())).await.is_err() {
                    break;
                }
            }
            Some(msg) = socket.recv() => {
                match msg {
                    Ok(Message::Text(text)) => {
                        let _ = state.tx.send(text.to_string());
                    }
                    Ok(Message::Close(_)) | Err(_) => break,
                    _ => {}
                }
            }
        }
    }
    println!("🔌 Client WebSocket ngắt kết nối.");
}

async fn evaluate_automations(
    pool: &sqlx::PgPool,
    mqtt_client: &AsyncClient,
    tx: &broadcast::Sender<String>,
    temp: f64,
    hum: f64,
    lux: f64,
    motion: f64,
) {
    let rules = match sqlx::query("SELECT * FROM automations")
        .fetch_all(pool)
        .await
    {
        Ok(r) => r,
        Err(_) => return,
    };

    for rule in rules {
        let is_active = rule
            .try_get::<bool, _>("is_active")
            .or_else(|_| rule.try_get::<bool, _>("enabled"))
            .unwrap_or(true);
        if !is_active {
            continue;
        }

        let name: String = rule.try_get("name").unwrap_or_else(|_| "Rule".into());
        let cond_type: String = rule
            .try_get("condition_type")
            .or_else(|_| rule.try_get("trigger_type"))
            .unwrap_or_else(|_| "temperature".into());
        let operator: String = rule
            .try_get("operator")
            .unwrap_or_else(|_| ">".into());
        let threshold: f64 = rule
            .try_get::<f64, _>("threshold")
            .or_else(|_| rule.try_get::<f64, _>("trigger_value"))
            .or_else(|_| rule.try_get::<f32, _>("threshold").map(|v| v as f64))
            .or_else(|_| rule.try_get::<f32, _>("trigger_value").map(|v| v as f64))
            .unwrap_or(30.0);
        let action: String = rule
            .try_get::<String, _>("action")
            .unwrap_or_else(|_| "ON".into())
            .to_uppercase();
        let device_id: String = rule.try_get("device_id").unwrap_or_default();
        let action_text: String = rule.try_get("action_text").unwrap_or_default();

        let current_val = match cond_type.to_lowercase().as_str() {
            "humidity" => hum,
            "lux" | "light" => lux,
            "motion" | "pir" => motion,
            _ => temp,
        };

        let matched = match operator.trim() {
            ">" => current_val > threshold,
            ">=" => current_val >= threshold,
            "<" => current_val < threshold,
            "<=" => current_val <= threshold,
            "==" | "=" => (current_val - threshold).abs() < 0.01,
            _ => false,
        };

        if !matched {
            continue;
        }

        let act_lower = action_text.to_lowercase();
        let target_row = if !device_id.trim().is_empty() {
            sqlx::query("SELECT id::text AS id, mqtt_topic, COALESCE(is_on, FALSE) AS is_on, COALESCE(status, 'OFF') AS status FROM devices WHERE id::text = $1")
                .bind(device_id.trim())
                .fetch_optional(pool)
                .await
                .unwrap_or(None)
        } else if act_lower.contains("quạt") || act_lower.contains("fan") {
            sqlx::query("SELECT id::text AS id, mqtt_topic, COALESCE(is_on, FALSE) AS is_on, COALESCE(status, 'OFF') AS status FROM devices WHERE device_type = 'fan' OR mqtt_topic LIKE '%quat%' LIMIT 1")
                .fetch_optional(pool)
                .await
                .unwrap_or(None)
        } else {
            sqlx::query("SELECT id::text AS id, mqtt_topic, COALESCE(is_on, FALSE) AS is_on, COALESCE(status, 'OFF') AS status FROM devices WHERE device_type = 'light' OR mqtt_topic LIKE '%led%' LIMIT 1")
                .fetch_optional(pool)
                .await
                .unwrap_or(None)
        };

        let (target_topic, already_on) = match target_row {
            Some(r) => {
                let is_on_col = r.try_get::<bool, _>("is_on").unwrap_or(false);
                let status_str = r.try_get::<String, _>("status").unwrap_or_default();
                let current_on = is_on_col || status_str.trim().eq_ignore_ascii_case("ON");
                (
                    r.try_get::<String, _>("mqtt_topic").unwrap_or_default(),
                    current_on,
                )
            }
            None => {
                if act_lower.contains("quạt") || act_lower.contains("fan") {
                    ("smarthome/devices/quat_phong_khach".to_string(), false)
                } else {
                    ("smarthome/devices/led_phong_khach".to_string(), false)
                }
            }
        };

        let want_on = action == "ON";
        if target_topic.is_empty() || already_on == want_on {
            continue;
        }

        let cmd = if want_on { "ON" } else { "OFF" };

        let _ = mqtt_client
            .publish(&target_topic, QoS::AtMostOnce, false, cmd.as_bytes())
            .await;
        let ctrl_topic = format!("{}/control", target_topic.trim_end_matches('/'));
        let _ = mqtt_client
            .publish(&ctrl_topic, QoS::AtMostOnce, false, cmd.as_bytes())
            .await;

        let _ = sqlx::query("UPDATE devices SET is_on = $1, status = $2 WHERE mqtt_topic = $3")
            .bind(want_on)
            .bind(cmd)
            .bind(&target_topic)
            .execute(pool)
            .await;

        let ws_dev = serde_json::json!({
            "type": "DEVICE_UPDATE",
            "data": {
                "mqtt_topic": target_topic,
                "is_on": want_on,
                "status": cmd
            }
        });
        if let Ok(msg_str) = serde_json::to_string(&ws_dev) {
            let _ = tx.send(msg_str);
        }

        println!(
            "⚡ [AUTOMATION TRIGGERED] '{}' ({} {} {}) -> {} = {}",
            name, current_val, operator, threshold, target_topic, cmd
        );
    }
}