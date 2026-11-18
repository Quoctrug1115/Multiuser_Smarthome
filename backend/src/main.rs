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
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, RwLock};
use tower_http::cors::{Any, CorsLayer};

// 1. Khai báo tất cả các Module quản trị
pub mod controllers;
pub mod models;
pub mod services;
pub mod ws;
pub mod handlers;

// 2. Struct AppState lưu trữ trạng thái chia sẻ toàn ứng dụng
pub struct AppState {
    pub db_pool: sqlx::PgPool,
    pub tx: broadcast::Sender<String>,
    pub mqtt_client: AsyncClient,
    pub discovered_devices: RwLock<HashMap<String, serde_json::Value>>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct SensorPayload {
    pub temperature: f32,
    pub humidity: f32,
    pub lux: Option<i32>,
    pub motion: Option<bool>,
    pub sensor_id: Option<String>,
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

    let _ = sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS energy_logs (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            device_id VARCHAR(50) NOT NULL,
            kwh DOUBLE PRECISION NOT NULL,
            recorded_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
        );
        "#,
    )
    .execute(&pool)
    .await;

    // 2. Khởi tạo Kênh Broadcast WebSocket
    let (tx, _rx) = broadcast::channel::<String>(100);

    // 3. Khởi tạo MQTT Client kết nối tới Broker public EMQX
    let mut mqttoptions = MqttOptions::new("rust_axum_backend_hub", "broker.emqx.io", 1883);
    mqttoptions.set_keep_alive(Duration::from_secs(15));

    let (mqtt_client, mut eventloop) = AsyncClient::new(mqttoptions, 10);
    mqtt_client
        .subscribe("smarthome/sensors/dht22", QoS::AtMostOnce)
        .await?;
    mqtt_client
        .subscribe("smarthome/discovery", QoS::AtMostOnce)
        .await?;
    println!("✅ MQTT Worker: Đã Subscribe 'smarthome/sensors/dht22' & 'smarthome/discovery'");

    let state = Arc::new(AppState {
        db_pool: pool,
        tx: tx.clone(),
        mqtt_client,
        discovered_devices: RwLock::new(HashMap::new()),
    });

    let state_mqtt = state.clone();

    // 4. Luồng ngầm định (Background Worker) xử lý tin nhắn MQTT từ ESP32 Wokwi
    tokio::spawn(async move {
        loop {
            match eventloop.poll().await {
                Ok(Event::Incoming(Incoming::Publish(publish))) => {
                    // Nhánh 1: Nhận gói tin báo danh thiết bị từ Wokwi
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

                    // Nhánh 2: Nhận dữ liệu cảm biến DHT22
                    if let Ok(payload) = serde_json::from_slice::<SensorPayload>(&publish.payload) {
                        println!(
                            "📩 [MQTT RECV ESP32] Temp: {}°C, Hum: {}%, Lux: {:?}, Motion: {:?}",
                            payload.temperature, payload.humidity, payload.lux, payload.motion
                        );

                        let pool_clone = state_mqtt.db_pool.clone();
                        let tx_clone = state_mqtt.tx.clone();
                        let mqtt_clone = state_mqtt.mqtt_client.clone();

                        tokio::spawn(async move {
                            let power_watt: f64 = 18.0;
                            let kwh_consumed: f64 = 0.015;

                            let device_uuid =
                                uuid::Uuid::parse_str("00000000-0000-0000-0000-000000000001")
                                    .unwrap_or_else(|_| uuid::Uuid::new_v4());

                            match sqlx::query(
                                r#"
                                INSERT INTO energy_logs (time, device_id, power_watt, kwh_consumed)
                                VALUES (NOW(), $1, $2, $3)
                                "#,
                            )
                            .bind(device_uuid)
                            .bind(power_watt)
                            .bind(kwh_consumed)
                            .execute(&pool_clone)
                            .await
                            {
                                Ok(_) => println!(
                                    "⚡ [DB INSERT] Đã ghi thành công 0.015 kWh vào energy_logs!"
                                ),
                                Err(e) => {
                                    eprintln!("❌ [DB ERROR] Không thể ghi dữ liệu: {:?}", e)
                                }
                            }

                            let lux_val = payload.lux.unwrap_or(450);
                            let motion_bool = payload.motion.unwrap_or(false);

                            // Đánh giá và kích hoạt các kịch bản tự động hóa đang BẬT
                            evaluate_automations(
                                &pool_clone,
                                &mqtt_clone,
                                &tx_clone,
                                payload.temperature as f64,
                                payload.humidity as f64,
                                lux_val as f64,
                                if motion_bool { 1.0 } else { 0.0 },
                            )
                            .await;

                            let ws_msg = serde_json::json!({
                                "type": "SENSOR_UPDATE",
                                "data": {
                                    "temperature": payload.temperature,
                                    "humidity": payload.humidity,
                                    "power_watt": power_watt,
                                    "kwh_consumed": kwh_consumed,
                                    "lux": lux_val,
                                    "motion": motion_bool
                                }
                            });

                            if let Ok(json_str) = serde_json::to_string(&ws_msg) {
                                let _ = tx_clone.send(json_str);
                            }
                        });
                    }
                }
                Ok(_) => {}
                Err(_e) => {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            }
        }
    });

    // 5. Cấu hình Router và API Endpoints (Chuẩn cú pháp Axum 0.8)
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = Router::new()
        .route("/ws", get(ws_handler))
        .route("/api/v1/auth/login", post(controllers::auth_controller::login))
        .route("/api/v1/auth/register", post(controllers::auth_controller::register))
        .route("/api/v1/devices", get(controllers::device_controller::get_devices))
        .route("/api/v1/devices", post(controllers::device_controller::create_device))
        .route("/api/v1/devices/discover",get(controllers::device_controller::discover_devices),)
        .route("/api/v1/devices/{id}", put(controllers::device_controller::update_device))
        .route("/api/v1/devices/{id}", delete(controllers::device_controller::delete_device))
        .route("/api/v1/devices/{id}/control", post(controllers::device_controller::control_device))
        .route("/api/v1/automations",get(controllers::automation_controller::get_automations),)
        .route("/api/v1/automations",post(controllers::automation_controller::create_automation),)
        .route("/api/v1/automations/{id}",axum::routing::put(controllers::automation_controller::toggle_automation).patch(controllers::automation_controller::toggle_automation).delete(controllers::automation_controller::delete_automation),)
        .route("/api/v1/automations/{id}/toggle",axum::routing::post(controllers::automation_controller::toggle_automation).put(controllers::automation_controller::toggle_automation).patch(controllers::automation_controller::toggle_automation),)
        .route("/api/v1/energy/analytics",get(controllers::energy_controller::get_analytics),)
        .route("/api/v1/users", get(controllers::user_controller::get_users))
        .route("/api/v1/users", post(controllers::user_controller::create_user))
        .route("/api/v1/users/{id}", put(controllers::user_controller::update_user))
        .route("/api/v1/users/{id}", delete(controllers::user_controller::delete_user))
        .route("/api/v1/ai/alerts", get(controllers::ai_controller::get_alerts))
        .route("/api/v1/ai/simulate-anomaly",post(controllers::ai_controller::simulate_anomaly),)
        .route("/api/v1/guests", get(controllers::guest_controller::get_guests))
        .route("/api/v1/guests/{id}/revoke",post(controllers::guest_controller::revoke_guest),)
        // Trong Router /api/v1:
        .route("/api/v1/houses", get(controllers::house_controller::get_houses).post(controllers::house_controller::create_house))
        .route("/api/v1/houses/{id}", put(controllers::house_controller::update_house).delete(controllers::house_controller::delete_house))
        .route("/api/v1/rooms", get(controllers::house_controller::get_rooms).post(controllers::house_controller::create_room))
        .route("/api/v1/rooms/{id}", put(controllers::house_controller::update_room).delete(controllers::house_controller::delete_room))
        .layer(cors)
        .with_state(state);

    // 6. Lắng nghe và khởi chạy Web Server trên cổng 3000
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
    use sqlx::Row;

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

        // 1. Gửi lệnh MQTT xuống Wokwi ESP32
        let _ = mqtt_client
            .publish(&target_topic, QoS::AtMostOnce, false, cmd.as_bytes())
            .await;
        let ctrl_topic = format!("{}/control", target_topic.trim_end_matches('/'));
        let _ = mqtt_client
            .publish(&ctrl_topic, QoS::AtMostOnce, false, cmd.as_bytes())
            .await;

        // 2. Cập nhật trạng thái thiết bị vào PostgreSQL
        let _ = sqlx::query("UPDATE devices SET is_on = $1, status = $2 WHERE mqtt_topic = $3")
            .bind(want_on)
            .bind(cmd)
            .bind(&target_topic)
            .execute(pool)
            .await;

        // 3. Thông báo qua WebSocket để giao diện đồng bộ tức thì
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