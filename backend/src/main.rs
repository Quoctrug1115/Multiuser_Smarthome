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
    // Khởi tạo Trình ghi log Tracing
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

    // Tự động khởi tạo bảng energy_logs nếu chưa tồn tại
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

                            let ws_msg = serde_json::json!({
                                "type": "SENSOR_UPDATE",
                                "data": {
                                    "temperature": payload.temperature,
                                    "humidity": payload.humidity,
                                    "power_watt": power_watt,
                                    "kwh_consumed": kwh_consumed,
                                    "lux": payload.lux.unwrap_or(450),
                                    "motion": payload.motion.unwrap_or(false)
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
        // WebSocket Realtime Route
        .route("/ws", get(ws_handler))
        // Auth APIs (Đăng nhập & Đăng ký)
        .route("/api/v1/auth/login", post(controllers::auth_controller::login))
        .route("/api/v1/auth/register", post(controllers::auth_controller::register))
        // Devices Control, CRUD & Wokwi Auto-Discovery APIs
        .route("/api/v1/devices", get(controllers::device_controller::get_devices))
        .route("/api/v1/devices", post(controllers::device_controller::create_device))
        .route(
            "/api/v1/devices/discover",
            get(controllers::device_controller::discover_devices),
        )
        .route("/api/v1/devices/{id}", put(controllers::device_controller::update_device))
        .route("/api/v1/devices/{id}", delete(controllers::device_controller::delete_device))
        .route("/api/v1/devices/{id}/control", post(controllers::device_controller::control_device))
        // Automations APIs
        .route(
            "/api/v1/automations",
            get(controllers::automation_controller::get_automations),
        )
        .route(
            "/api/v1/automations",
            post(controllers::automation_controller::create_automation),
        )
        .route(
            "/api/v1/automations/{id}",
            delete(controllers::automation_controller::delete_automation),
        )
        // Analytics & Energy APIs
        .route(
            "/api/v1/energy/analytics",
            get(controllers::energy_controller::get_analytics),
        )
        // User Management APIs
        .route("/api/v1/users", get(controllers::user_controller::get_users))
        .route("/api/v1/users", post(controllers::user_controller::create_user))
        .route("/api/v1/users/{id}", put(controllers::user_controller::update_user))
        .route("/api/v1/users/{id}", delete(controllers::user_controller::delete_user))
        // AI Engine APIs
        .route("/api/v1/ai/alerts", get(controllers::ai_controller::get_alerts))
        .route(
            "/api/v1/ai/simulate-anomaly",
            post(controllers::ai_controller::simulate_anomaly),
        )
        // Guest Access APIs
        .route("/api/v1/guests", get(controllers::guest_controller::get_guests))
        .route(
            "/api/v1/guests/{id}/revoke",
            post(controllers::guest_controller::revoke_guest),
        )
        .layer(cors)
        .with_state(state);

    // 6. Lắng nghe và khởi chạy Web Server trên cổng 3000
    let addr = SocketAddr::from(([0, 0, 0, 0], 3000));
    println!("🌐 Server đang lắng nghe tại http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

// Handler kết nối WebSocket cho Web Dashboard & Mobile App
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
                        // Đồng bộ lệnh điều khiển từ Mobile/Web sang các client khác
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