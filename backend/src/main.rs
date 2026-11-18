use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::State,
    response::IntoResponse,
    routing::{delete, get, post, put},
    Router,
};
use bb8::Pool;
use bb8_tiberius::ConnectionManager;
use rumqttc::{AsyncClient, Event, Incoming, MqttOptions, QoS};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tiberius::{AuthMethod, Config};
use tokio::sync::{broadcast, RwLock};
use tower_http::cors::{Any, CorsLayer};

pub mod controllers;
pub mod models;
pub mod services;
pub mod ws;

pub type SqlPool = Pool<ConnectionManager>;

pub struct AppState {
    pub db_pool: SqlPool,
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
    let _ = dotenvy::dotenv();
    tracing_subscriber::fmt::init();
    println!("Đang khởi động Backend SmartHome Axum Engine (SQL Server)...");

    // 1. Cấu hình & Kết nối Microsoft SQL Server qua Tiberius + bb8
    let db_host = std::env::var("MSSQL_HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let db_port: u16 = std::env::var("MSSQL_PORT")
        .unwrap_or_else(|_| "1433".to_string())
        .parse()
        .unwrap_or(1433);
    let db_user = std::env::var("MSSQL_USER").unwrap_or_else(|_| "sa".to_string());
    let db_pass =
        std::env::var("MSSQL_PASSWORD").unwrap_or_else(|_| "SmartHome@2026".to_string());
    let db_name = std::env::var("MSSQL_DATABASE").unwrap_or_else(|_| "smarthome".to_string());

    let mut config = Config::new();
    config.host(&db_host);
    config.port(db_port);
    config.authentication(AuthMethod::sql_server(&db_user, &db_pass));
    config.database(&db_name);
    config.trust_cert();

    let mgr = ConnectionManager::build(config)?;
    let pool = Pool::builder()
        .max_size(20)
        .connection_timeout(Duration::from_secs(5))
        .build(mgr)
        .await?;

    println!(
        "Kết nối SQL Server thành công: {}@{}:{}/{}",
        db_user, db_host, db_port, db_name
    );

    // Đảm bảo bảng dbo.energy_logs và các cột multi-tenant luôn sẵn sàng
    if let Ok(mut conn) = pool.get().await {
        let init_queries = [
            r#"
            IF OBJECT_ID(N'dbo.energy_logs', N'U') IS NULL
            BEGIN
                CREATE TABLE dbo.energy_logs (
                    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
                    device_id UNIQUEIDENTIFIER NULL,
                    owner_id UNIQUEIDENTIFIER NULL,
                    power_watt FLOAT NOT NULL DEFAULT 0,
                    kwh_consumed FLOAT NOT NULL DEFAULT 0,
                    kwh FLOAT NOT NULL DEFAULT 0,
                    [time] DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
                    recorded_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET()
                );
            END
            "#,
            "IF COL_LENGTH(N'dbo.energy_logs', N'owner_id') IS NULL ALTER TABLE dbo.energy_logs ADD owner_id UNIQUEIDENTIFIER NULL",
            "IF COL_LENGTH(N'dbo.energy_logs', N'power_watt') IS NULL ALTER TABLE dbo.energy_logs ADD power_watt FLOAT NOT NULL DEFAULT 0",
            "IF COL_LENGTH(N'dbo.energy_logs', N'kwh_consumed') IS NULL ALTER TABLE dbo.energy_logs ADD kwh_consumed FLOAT NOT NULL DEFAULT 0",
            "IF COL_LENGTH(N'dbo.energy_logs', N'kwh') IS NULL ALTER TABLE dbo.energy_logs ADD kwh FLOAT NOT NULL DEFAULT 0",
            "IF COL_LENGTH(N'dbo.energy_logs', N'time') IS NULL ALTER TABLE dbo.energy_logs ADD [time] DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET()",
            "IF COL_LENGTH(N'dbo.energy_logs', N'recorded_at') IS NULL ALTER TABLE dbo.energy_logs ADD recorded_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET()",
        ];

        for q in init_queries {
            let _ = conn.execute(q, &[]).await;
        }
    }

    // 2. Khởi tạo Kênh Broadcast WebSocket
    let (tx, _rx) = broadcast::channel::<String>(100);

    // 3. Khởi tạo MQTT Client kết nối tới Broker
    let mqtt_host =
        std::env::var("MQTT_HOST").unwrap_or_else(|_| "broker.emqx.io".to_string());
    let mqtt_port: u16 = std::env::var("MQTT_PORT")
        .unwrap_or_else(|_| "1883".to_string())
        .parse()
        .unwrap_or(1883);

    let client_id = format!("rust_axum_hub_{}", &uuid::Uuid::new_v4().to_string()[..8]);
    let mut mqttoptions = MqttOptions::new(client_id, &mqtt_host, mqtt_port);
    mqttoptions.set_keep_alive(Duration::from_secs(15));

    let (mqtt_client, mut eventloop) = AsyncClient::new(mqttoptions, 20);
    mqtt_client
        .subscribe("smarthome/sensors/#", QoS::AtMostOnce)
        .await?;
    mqtt_client
        .subscribe("smarthome/discovery", QoS::AtMostOnce)
        .await?;
    println!(
        "MQTT Worker ({}:{}): Đã Subscribe 'smarthome/sensors/#' & 'smarthome/discovery'",
        mqtt_host, mqtt_port
    );

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
                                println!("[WOKWI DISCOVERY] Phát hiện thiết bị: {}", topic);
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
                                "[MQTT SENSOR] Topic: {} | Temp: {:.1}°C | Hum: {:.0}% | Lux: {} | Motion: {}",
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

            let Ok(mut conn) = state_meter.db_pool.get().await else {
                continue;
            };

            let active_rows = match conn
                .query(
                    r#"
                    SELECT
                        d.id,
                        COALESCE(d.owner_id, h.owner_id) AS tenant_id,
                        COALESCE(d.device_type, N'switch') AS device_type
                    FROM dbo.devices d
                    LEFT JOIN dbo.rooms r ON d.room_id = r.id
                    LEFT JOIN dbo.houses h ON r.house_id = h.id
                    WHERE ISNULL(d.is_on, 0) = 1
                      AND COALESCE(d.owner_id, h.owner_id) IS NOT NULL
                    "#,
                    &[],
                )
                .await
            {
                Ok(stream) => stream.into_first_result().await.unwrap_or_default(),
                Err(_) => continue,
            };

            for row in active_rows {
                let Some(device_id) = row.get::<uuid::Uuid, _>("id") else {
                    continue;
                };
                let Some(tenant_id) = row.get::<uuid::Uuid, _>("tenant_id") else {
                    continue;
                };
                let dtype = row
                    .get::<&str, _>("device_type")
                    .unwrap_or("switch")
                    .to_string();

                let watt: f64 = match dtype.to_lowercase().as_str() {
                    "ac" | "heater" => 1200.0,
                    "fan" => 45.0,
                    "light" => 15.0,
                    "sensor" => 2.0,
                    _ => 25.0,
                };

                // kWh tiêu thụ trong 15 giây = (Watt / 1000) * (15 / 3600)
                let kwh = (watt / 1000.0) * (interval_secs / 3600.0);
                let log_id = uuid::Uuid::new_v4();

                let mut q = tiberius::Query::new(
                        r#"
                        INSERT INTO dbo.energy_logs (id, device_id, owner_id, power_watt, kwh_consumed, kwh, [time], recorded_at)
                        VALUES (@P1, @P2, @P3, @P4, @P5, @P5, SYSDATETIMEOFFSET(), SYSDATETIMEOFFSET())
                        "#,
                    );
                    q.bind(log_id);
                    q.bind(device_id);
                    q.bind(tenant_id);
                    q.bind(watt);
                    q.bind(kwh);
                    let _ = q.execute(&mut conn).await;
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
    println!("Server đang lắng nghe tại http://{}", addr);

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
    println!("Client WebSocket ngắt kết nối.");
}

async fn evaluate_automations(
    pool: &SqlPool,
    mqtt_client: &AsyncClient,
    tx: &broadcast::Sender<String>,
    temp: f64,
    hum: f64,
    lux: f64,
    motion: f64,
) {
    let Ok(mut conn) = pool.get().await else {
        return;
    };

    let rules = match conn.query("SELECT * FROM dbo.automations", &[]).await {
        Ok(stream) => stream.into_first_result().await.unwrap_or_default(),
        Err(_) => return,
    };

    for rule in rules {
        let is_active = rule
            .try_get::<bool, _>("is_active")
            .ok()
            .flatten()
            .or_else(|| rule.try_get::<bool, _>("enabled").ok().flatten())
            .unwrap_or(true);
        if !is_active {
            continue;
        }

        let name = rule
            .try_get::<&str, _>("name")
            .ok()
            .flatten()
            .unwrap_or("Rule")
            .to_string();
        let cond_type = rule
            .try_get::<&str, _>("condition_type")
            .ok()
            .flatten()
            .or_else(|| rule.try_get::<&str, _>("trigger_type").ok().flatten())
            .unwrap_or("temperature")
            .to_string();
        let operator = rule
            .try_get::<&str, _>("operator")
            .ok()
            .flatten()
            .unwrap_or(">")
            .to_string();
        let threshold: f64 = rule
            .try_get::<f64, _>("threshold")
            .ok()
            .flatten()
            .or_else(|| rule.try_get::<f64, _>("trigger_value").ok().flatten())
            .or_else(|| {
                rule.try_get::<f32, _>("threshold")
                    .ok()
                    .flatten()
                    .map(|v| v as f64)
            })
            .or_else(|| {
                rule.try_get::<f32, _>("trigger_value")
                    .ok()
                    .flatten()
                    .map(|v| v as f64)
            })
            .unwrap_or(30.0);
        let action = rule
            .try_get::<&str, _>("action")
            .ok()
            .flatten()
            .unwrap_or("ON")
            .to_uppercase();
        let device_id = rule
            .try_get::<&str, _>("device_id")
            .ok()
            .flatten()
            .unwrap_or("")
            .to_string();
        let action_text = rule
            .try_get::<&str, _>("action_text")
            .ok()
            .flatten()
            .unwrap_or("")
            .to_string();

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
        let trimmed_dev_id = device_id.trim();

        let target_row = if !trimmed_dev_id.is_empty() {
            match conn
                .query(
                    "SELECT TOP 1 CAST(id AS NVARCHAR(36)) AS id, mqtt_topic, ISNULL(is_on, CAST(0 AS BIT)) AS is_on, ISNULL(status, N'OFF') AS status FROM dbo.devices WHERE LOWER(CAST(id AS NVARCHAR(36))) = LOWER(@P1)",
                    &[&trimmed_dev_id],
                )
                .await
            {
                Ok(s) => s.into_row().await.unwrap_or(None),
                Err(_) => None,
            }
        } else if act_lower.contains("quạt") || act_lower.contains("fan") {
            match conn
                .query(
                    "SELECT TOP 1 CAST(id AS NVARCHAR(36)) AS id, mqtt_topic, ISNULL(is_on, CAST(0 AS BIT)) AS is_on, ISNULL(status, N'OFF') AS status FROM dbo.devices WHERE device_type = N'fan' OR mqtt_topic LIKE N'%quat%'",
                    &[],
                )
                .await
            {
                Ok(s) => s.into_row().await.unwrap_or(None),
                Err(_) => None,
            }
        } else {
            match conn
                .query(
                    "SELECT TOP 1 CAST(id AS NVARCHAR(36)) AS id, mqtt_topic, ISNULL(is_on, CAST(0 AS BIT)) AS is_on, ISNULL(status, N'OFF') AS status FROM dbo.devices WHERE device_type = N'light' OR mqtt_topic LIKE N'%led%'",
                    &[],
                )
                .await
            {
                Ok(s) => s.into_row().await.unwrap_or(None),
                Err(_) => None,
            }
        };

        let (target_topic, already_on) = match target_row {
            Some(r) => {
                let is_on_col = r.get::<bool, _>("is_on").unwrap_or(false);
                let status_str = r.get::<&str, _>("status").unwrap_or("");
                let current_on = is_on_col || status_str.trim().eq_ignore_ascii_case("ON");
                (
                    r.get::<&str, _>("mqtt_topic").unwrap_or("").to_string(),
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

        let mut q = tiberius::Query::new(
                "UPDATE dbo.devices SET is_on = @P1, status = @P2, last_seen = SYSDATETIMEOFFSET() WHERE mqtt_topic = @P3",
            );
            q.bind(want_on);
            q.bind(cmd);
            q.bind(&target_topic);
            let _ = q.execute(&mut conn).await;

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