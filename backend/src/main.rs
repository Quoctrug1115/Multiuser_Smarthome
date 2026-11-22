use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
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
use uuid::Uuid;

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

/// Trích xuất chip_id từ topic dạng `smarthome/{chip_id}/...` (bỏ qua các prefix hệ thống).
fn extract_chip_id(topic: &str) -> Option<String> {
    let parts: Vec<&str> = topic.split('/').collect();
    if parts.len() >= 3 && parts[0].eq_ignore_ascii_case("smarthome") {
        let chip = parts[1].trim();
        if !chip.is_empty()
            && !chip.eq_ignore_ascii_case("devices")
            && !chip.eq_ignore_ascii_case("sensors")
            && !chip.eq_ignore_ascii_case("discovery")
        {
            return Some(chip.to_string());
        }
    }
    None
}

/// Tìm tất cả owner_id (tenant) có đăng ký thiết bị thuộc chip_id này.
async fn resolve_chip_owners(pool: &SqlPool, chip_id: &str) -> Vec<String> {
    let Ok(mut conn) = pool.get().await else {
        return Vec::new();
    };
    let prefix = format!("smarthome/{}/", chip_id.trim());
    let mut q = tiberius::Query::new(
        r#"
        SELECT DISTINCT COALESCE(d.owner_id, h.owner_id) AS owner_id
        FROM dbo.devices d
        LEFT JOIN dbo.rooms r ON d.room_id = r.id
        LEFT JOIN dbo.houses h ON r.house_id = h.id
        WHERE LEFT(LOWER(LTRIM(d.mqtt_topic)), LEN(@P1)) = LOWER(@P1)
          AND COALESCE(d.owner_id, h.owner_id) IS NOT NULL
        "#,
    );
    q.bind(prefix);
    let Ok(stream) = q.query(&mut conn).await else {
        return Vec::new();
    };
    let Ok(rows) = stream.into_first_result().await else {
        return Vec::new();
    };
    rows.into_iter()
        .filter_map(|r| r.get::<Uuid, _>("owner_id").map(|u| u.to_string()))
        .collect()
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
        std::env::var("MSSQL_PASSWORD").unwrap_or_else(|_| "Quoctrung2005@".to_string());
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

    // Đảm bảo bảng dbo.energy_logs và các cột multi-tenant / trạng thái thiết bị luôn sẵn sàng
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
            "IF COL_LENGTH(N'dbo.devices', N'is_online') IS NULL ALTER TABLE dbo.devices ADD is_online BIT NOT NULL DEFAULT 1",
            "IF COL_LENGTH(N'dbo.devices', N'current_state') IS NULL ALTER TABLE dbo.devices ADD current_state NVARCHAR(MAX) NULL",
            "IF COL_LENGTH(N'dbo.devices', N'last_seen') IS NULL ALTER TABLE dbo.devices ADD last_seen DATETIMEOFFSET NULL",
            "IF OBJECT_ID(N'dbo.automations', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.automations', N'enabled') IS NULL ALTER TABLE dbo.automations ADD enabled BIT NOT NULL DEFAULT 1",
            "IF OBJECT_ID(N'dbo.automations', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.automations', N'is_active') IS NOT NULL UPDATE dbo.automations SET enabled = ISNULL(is_active, 1)",
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

    let client_id = format!("rust_axum_hub_{}", &Uuid::new_v4().to_string()[..8]);
    let mut mqttoptions = MqttOptions::new(client_id, &mqtt_host, mqtt_port);
    mqttoptions.set_keep_alive(Duration::from_secs(15));
    if let (Ok(user), Ok(pass)) = (std::env::var("MQTT_USER"), std::env::var("MQTT_PASS")) {
        if !user.is_empty() {
            mqttoptions.set_credentials(user, pass);
        }
    }

    // [FIX #2] KHÔNG subscribe trước vòng lặp: rumqttc (clean_session = true) sẽ mất toàn bộ
    // subscription sau mỗi lần reconnect. Việc subscribe thực hiện mỗi khi nhận ConnAck bên dưới.
    let (mqtt_client, mut eventloop) = AsyncClient::new(mqttoptions, 50);
    println!("MQTT Worker sẽ kết nối tới {}:{}", mqtt_host, mqtt_port);

    let state = Arc::new(AppState {
        db_pool: pool,
        tx: tx.clone(),
        mqtt_client,
        discovered_devices: RwLock::new(HashMap::new()),
        latest_sensor: RwLock::new(None),
    });

    // 4A. Luồng MQTT Worker: state ACK, availability (LWT), discovery, telemetry
    let state_mqtt = state.clone();
    tokio::spawn(async move {
        loop {
            match eventloop.poll().await {
                // [FIX #2] Mỗi lần (re)connect thành công đều subscribe lại toàn bộ topic
                Ok(Event::Incoming(Incoming::ConnAck(_))) => {
                    println!("✅ [MQTT] Đã kết nối Broker -> subscribe lại các topic...");
                    let subs: [(&str, QoS); 6] = [
                        ("smarthome/+/state", QoS::AtLeastOnce), // smarthome/{chip_id}/state
                        ("smarthome/+/+/state", QoS::AtLeastOnce), // smarthome/{chip_id}/{channel}/state & legacy
                        ("smarthome/+/availability", QoS::AtLeastOnce), // LWT ONLINE/OFFLINE
                        ("smarthome/+/telemetry", QoS::AtMostOnce),
                        ("smarthome/sensors/#", QoS::AtMostOnce),
                        ("smarthome/discovery", QoS::AtMostOnce),
                    ];
                    for (topic, qos) in subs {
                        if let Err(e) = state_mqtt.mqtt_client.try_subscribe(topic, qos) {
                            eprintln!("❌ [MQTT] subscribe '{}' lỗi: {:?}", topic, e);
                        }
                    }
                    // [FIX #7] Yêu cầu mọi ESP32 đang online báo danh lại (discovery không retain)
                    let _ = state_mqtt.mqtt_client.try_publish(
                        "smarthome/discovery/request",
                        QoS::AtMostOnce,
                        false,
                        "1",
                    );
                }

                Ok(Event::Incoming(Incoming::Publish(publish))) => {
                    // Nhánh A: Đồng bộ ngược trạng thái thực tế từ ESP32 (.../state)
                    if publish.topic.ends_with("/state") {
                        let base_topic = publish
                            .topic
                            .trim_end_matches("/state")
                            .trim_end_matches('/')
                            .to_string();
                        let payload_str = String::from_utf8_lossy(&publish.payload).to_string();

                        let (is_on, source) =
                            if let Ok(json_val) = serde_json::from_str::<serde_json::Value>(&payload_str) {
                                let on = json_val
                                    .get("is_on")
                                    .and_then(|v| v.as_bool())
                                    .unwrap_or_else(|| {
                                        json_val
                                            .get("status")
                                            .and_then(|v| v.as_str())
                                            .map(|s| s.eq_ignore_ascii_case("ON"))
                                            .unwrap_or(false)
                                    });
                                let src = json_val
                                    .get("source")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("device")
                                    .to_string();
                                (on, src)
                            } else {
                                let upper = payload_str.trim().to_uppercase();
                                (
                                    upper == "ON" || upper == "1" || upper == "TRUE",
                                    "device".to_string(),
                                )
                            };

                        let status_str = if is_on { "ON" } else { "OFF" };

                        // Cột current_state có CHECK ISJSON(...) = 1 -> luôn lưu chuỗi JSON hợp lệ
                        let state_json = if serde_json::from_str::<serde_json::Value>(&payload_str).is_ok() {
                            payload_str.clone()
                        } else {
                            serde_json::json!({ "is_on": is_on, "status": status_str }).to_string()
                        };

                        let mut conn = match state_mqtt.db_pool.get().await {
                            Ok(c) => c,
                            Err(e) => {
                                eprintln!("❌ [STATE SYNC] Không lấy được kết nối SQL: {}", e);
                                continue;
                            }
                        };

                        let mut q = tiberius::Query::new(
                            r#"
                            UPDATE d
                            SET d.is_on = @P1,
                                d.status = @P2,
                                d.is_online = 1,
                                d.current_state = @P3,
                                d.last_seen = SYSDATETIMEOFFSET()
                            OUTPUT INSERTED.id,
                                INSERTED.mqtt_topic,
                                COALESCE(INSERTED.owner_id, h.owner_id) AS owner_id
                            FROM dbo.devices d
                            LEFT JOIN dbo.rooms r ON d.room_id = r.id
                            LEFT JOIN dbo.houses h ON r.house_id = h.id
                            WHERE LOWER(
                                CASE
                                    WHEN RIGHT(RTRIM(LTRIM(d.mqtt_topic)), 1) = '/'
                                    THEN LEFT(RTRIM(LTRIM(d.mqtt_topic)), LEN(RTRIM(LTRIM(d.mqtt_topic))) - 1)
                                    ELSE RTRIM(LTRIM(d.mqtt_topic))
                                END
                            ) = LOWER(@P4)
                            "#,
                        );
                        q.bind(is_on);
                        q.bind(status_str);
                        q.bind(state_json);
                        q.bind(base_topic.clone());

                        // [FIX #1/#3] Log rõ khi SQL lỗi hoặc không khớp thiết bị nào
                        let mut matched = 0usize;
                        match q.query(&mut conn).await {
                            Ok(stream) => match stream.into_first_result().await {
                                Ok(rows) => {
                                    for row in rows {
                                        let Some(dev_id) = row.get::<Uuid, _>("id") else {
                                            continue;
                                        };
                                        matched += 1;
                                        let db_topic = row
                                            .get::<&str, _>("mqtt_topic")
                                            .filter(|t| !t.trim().is_empty())
                                            .unwrap_or(&base_topic)
                                            .to_string();
                                        let owner_id = row.get::<Uuid, _>("owner_id").map(|u| u.to_string());
                                        println!(
                                            "🔄 [STATE SYNC] {} -> {} (source: {})",
                                            db_topic, status_str, source
                                        );
                                        let ws_msg = serde_json::json!({
                                            "type": "DEVICE_UPDATE",
                                            "data": {
                                                "id": dev_id.to_string(),
                                                "owner_id": owner_id,
                                                "mqtt_topic": db_topic,
                                                "is_on": is_on,
                                                "status": status_str,
                                                "is_online": true,
                                                "source": source
                                            }
                                        });
                                        let _ = state_mqtt.tx.send(ws_msg.to_string());
                                    }
                                }
                                Err(e) => eprintln!("❌ [STATE SYNC] Đọc kết quả SQL lỗi: {}", e),
                            },
                            Err(e) => eprintln!("❌ [STATE SYNC] UPDATE lỗi: {}", e),
                        }
                        if matched == 0 {
                            eprintln!(
                                "⚠️  [STATE SYNC] Nhận state từ '{}' nhưng KHÔNG có thiết bị nào trong dbo.devices có mqtt_topic = '{}'. \
                                 -> Sửa mqtt_topic của thiết bị cho khớp (hoặc thêm thiết bị bằng Discovery).",
                                publish.topic, base_topic
                            );
                        }
                        continue;
                    }

                    // Nhánh B: Giám sát trạng thái Online / Offline (MQTT LWT)
                    if publish.topic.ends_with("/availability") {
                        let chip_prefix =
                            format!("{}/", publish.topic.trim_end_matches("/availability"));
                        let avail_str = String::from_utf8_lossy(&publish.payload)
                            .trim()
                            .to_uppercase();
                        let is_online = avail_str == "ONLINE";

                        let mut conn = match state_mqtt.db_pool.get().await {
                            Ok(c) => c,
                            Err(e) => {
                                eprintln!("❌ [AVAILABILITY] Không lấy được kết nối SQL: {}", e);
                                continue;
                            }
                        };

                        let mut q = tiberius::Query::new(
                            r#"
                            UPDATE d
                            SET d.is_online = @P1,
                                d.last_seen = CASE WHEN @P1 = 1 THEN SYSDATETIMEOFFSET() ELSE d.last_seen END
                            OUTPUT INSERTED.id,
                                INSERTED.mqtt_topic,
                                ISNULL(INSERTED.is_on, CAST(0 AS BIT)) AS is_on,
                                COALESCE(INSERTED.owner_id, h.owner_id) AS owner_id
                            FROM dbo.devices d
                            LEFT JOIN dbo.rooms r ON d.room_id = r.id
                            LEFT JOIN dbo.houses h ON r.house_id = h.id
                            WHERE LEFT(LOWER(LTRIM(d.mqtt_topic)), LEN(@P2)) = LOWER(@P2)
                            "#,
                        );
                        q.bind(is_online);
                        q.bind(chip_prefix);

                        match q.query(&mut conn).await {
                            Ok(stream) => match stream.into_first_result().await {
                                Ok(rows) => {
                                    println!(
                                        "📡 [AVAILABILITY] {} -> {} ({} thiết bị)",
                                        publish.topic,
                                        if is_online { "ONLINE" } else { "OFFLINE" },
                                        rows.len()
                                    );
                                    for row in rows {
                                        let Some(dev_id) = row.get::<Uuid, _>("id") else {
                                            continue;
                                        };
                                        let topic = row
                                            .get::<&str, _>("mqtt_topic")
                                            .unwrap_or("")
                                            .to_string();
                                        let is_on = row.get::<bool, _>("is_on").unwrap_or(false);
                                        let owner_id =
                                            row.get::<Uuid, _>("owner_id").map(|u| u.to_string());
                                        let ws_msg = serde_json::json!({
                                            "type": "DEVICE_UPDATE",
                                            "data": {
                                                "id": dev_id.to_string(),
                                                "owner_id": owner_id,
                                                "mqtt_topic": topic,
                                                "is_on": is_on,
                                                "status": if is_on { "ON" } else { "OFF" },
                                                "is_online": is_online,
                                                "source": "availability"
                                            }
                                        });
                                        let _ = state_mqtt.tx.send(ws_msg.to_string());
                                    }
                                }
                                Err(e) => eprintln!("❌ [AVAILABILITY] Đọc kết quả SQL lỗi: {}", e),
                            },
                            Err(e) => eprintln!("❌ [AVAILABILITY] UPDATE lỗi: {}", e),
                        }
                        continue;
                    }

                    // Nhánh 1: Thiết bị tự báo danh qua MQTT Discovery
                    if publish.topic == "smarthome/discovery" {
                        if let Ok(device_json) =
                            serde_json::from_slice::<serde_json::Value>(&publish.payload)
                        {
                            if let Some(topic) =
                                device_json.get("mqtt_topic").and_then(|v| v.as_str())
                            {
                                let mut discovered = state_mqtt.discovered_devices.write().await;
                                if discovered.len() > 500 {
                                    discovered.clear(); // chặn phình RAM
                                }
                                discovered.insert(topic.to_string(), device_json.clone());
                                println!("[DISCOVERY] Phát hiện thiết bị: {}", topic);
                            }
                        }
                        continue;
                    }

                    // Nhánh 2: Dữ liệu cảm biến môi trường (DHT22 / LDR / PIR)
                    if publish.topic.starts_with("smarthome/sensors")
                        || publish.topic.ends_with("/telemetry")
                    {
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
                                    v.as_bool().unwrap_or_else(|| v.as_i64().unwrap_or(0) > 0)
                                })
                                .unwrap_or(false);

                       let sensor_owners = if let Some(chip_id) = extract_chip_id(&publish.topic) {
                                resolve_chip_owners(&state_mqtt.db_pool, &chip_id).await
                            } else {
                                Vec::new()
                            };
                       let sensor_owner_uuids: Vec<Uuid> = sensor_owners
                            .iter()
                            .filter_map(|s| Uuid::parse_str(s).ok())
                            .collect();

                            let ws_msg = serde_json::json!({
                                "type": "SENSOR_UPDATE",
                                "data": {
                                    "topic": publish.topic,
                                    "owner_id": sensor_owners.first().cloned(),
                                    "owner_ids": sensor_owners,
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

                            let _ = state_mqtt.tx.send(ws_msg.to_string());

                            let pool_clone = state_mqtt.db_pool.clone();
                            let mqtt_clone = state_mqtt.mqtt_client.clone();
                            let owners_clone = sensor_owner_uuids.clone();
                            tokio::spawn(async move {
                                evaluate_automations(
                                    &pool_clone,
                                    &mqtt_clone,
                                    &owners_clone,
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
                Err(e) => {
                    // [FIX #2] Log rõ lý do rớt kết nối trước khi thử lại
                    eprintln!("❌ [MQTT] Mất kết nối Broker: {:?} -> thử lại sau 2s", e);
                    tokio::time::sleep(Duration::from_secs(2)).await;
                }
            }
        }
    });

    // 4B. Luồng đo đếm điện năng tiêu thụ mỗi 15 giây cho các thiết bị đang BẬT & ONLINE theo từng Chủ nhà
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
                      AND ISNULL(d.is_online, 1) = 1
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

    // 6. Lắng nghe trên cổng cấu hình (mặc định 3000)
    let port: u16 = std::env::var("PORT")
        .unwrap_or_else(|_| "3000".to_string())
        .parse()
        .unwrap_or(3000);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    println!("Server đang lắng nghe tại http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

// ============================================================================
// WEBSOCKET
// ============================================================================

/// Giải mã JWT truyền qua query `?token=...` (cùng secret với auth_service).
fn decode_ws_token(token: &str) -> Option<crate::models::user::Claims> {
    let secret = std::env::var("JWT_SECRET")
        .unwrap_or_else(|_| "SMARTHOME_RUST_AXUM_SECRET_KEY".to_string());
    jsonwebtoken::decode::<crate::models::user::Claims>(
        token,
        &jsonwebtoken::DecodingKey::from_secret(secret.as_bytes()),
        &jsonwebtoken::Validation::default(),
    )
    .ok()
    .map(|data| data.claims)
}

/// Tenant = owner_id của user (Owner thì tenant chính là id của mình).
async fn resolve_ws_tenant(pool: &SqlPool, user_id: Uuid) -> Option<Uuid> {
    let mut conn = pool.get().await.ok()?;
    let mut q = tiberius::Query::new("SELECT TOP 1 owner_id FROM dbo.users WHERE id = @P1");
    q.bind(user_id);
    let row = q.query(&mut conn).await.ok()?.into_row().await.ok()??;
    Some(row.get::<Uuid, _>("owner_id").unwrap_or(user_id))
}

/// Sự kiện có owner_id khác tenant của socket thì không được gửi cho socket đó.
fn event_visible_to(msg: &str, tenant: Option<Uuid>) -> bool {
    let Some(tenant) = tenant else {
        return true;
    };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(msg) else {
        return true;
    };
    let tenant_str = tenant.to_string();
    if let Some(owners) = v
        .get("data")
        .and_then(|d| d.get("owner_ids"))
        .and_then(|arr| arr.as_array())
    {
        if !owners.is_empty() {
            return owners
                .iter()
                .filter_map(|o| o.as_str())
                .any(|o| o.eq_ignore_ascii_case(&tenant_str));
        }
    }
    match v
        .get("data")
        .and_then(|d| d.get("owner_id"))
        .and_then(|o| o.as_str())
    {
        Some(owner) if !owner.is_empty() => owner.eq_ignore_ascii_case(&tenant_str),
        _ => true,
    }
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Response {
    let require_auth = matches!(
        std::env::var("WS_REQUIRE_AUTH").unwrap_or_default().to_lowercase().as_str(),
        "1" | "true" | "yes"
    );

    let mut tenant: Option<Uuid> = None;
    if let Some(token) = params.get("token").map(|t| t.trim()).filter(|t| !t.is_empty()) {
        match decode_ws_token(token) {
            Some(claims) => tenant = resolve_ws_tenant(&state.db_pool, claims.sub).await,
            None => return (StatusCode::UNAUTHORIZED, "Token không hợp lệ hoặc đã hết hạn").into_response(),
        }
    }
    if require_auth && tenant.is_none() {
        return (StatusCode::UNAUTHORIZED, "Thiếu token: kết nối /ws?token=<JWT>").into_response();
    }

    ws.on_upgrade(move |socket| handle_socket(socket, state, tenant))
}

async fn handle_socket(mut socket: WebSocket, state: Arc<AppState>, tenant: Option<Uuid>) {
    let mut rx = state.tx.subscribe();

    let cached_sensor = { state.latest_sensor.read().await.clone() };
    if let Some(sensor_val) = cached_sensor {
        if let Ok(msg_str) = serde_json::to_string(&sensor_val) {
            if event_visible_to(&msg_str, tenant) {
                let _ = socket.send(Message::Text(msg_str.into())).await;
            }
        }
    }

    loop {
        tokio::select! {
            // Server -> Client: chỉ gửi sự kiện thuộc đúng hộ gia đình
            res = rx.recv() => {
                match res {
                    Ok(msg) => {
                        if !event_visible_to(&msg, tenant) {
                            continue;
                        }
                        if socket.send(Message::Text(msg.into())).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => break,
                }
            }
            // Client -> Server
            incoming = socket.recv() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        // [FIX #8] Không echo mọi text của client cho tất cả client khác.
                        let Ok(cmd_json) = serde_json::from_str::<serde_json::Value>(&text) else { continue };
                        if cmd_json.get("action").and_then(|v| v.as_str()) != Some("TOGGLE_DEVICE") {
                            continue;
                        }
                        // Lệnh điều khiển bắt buộc phải có danh tính (token query hoặc token trong payload)
                        let effective_tenant = match tenant {
                            Some(t) => Some(t),
                            None => match cmd_json
                                .get("token")
                                .and_then(|v| v.as_str())
                                .map(|t| t.trim())
                                .filter(|t| !t.is_empty())
                                .and_then(decode_ws_token)
                            {
                                Some(claims) => resolve_ws_tenant(&state.db_pool, claims.sub).await,
                                None => None,
                            },
                        };
                        let Some(tenant_id) = effective_tenant else { continue };
                        let Some(dev_id_str) = cmd_json.get("device_id").and_then(|v| v.as_str()) else { continue };
                        let Ok(dev_uuid) = Uuid::parse_str(dev_id_str.trim()) else { continue };
                        let next_on = cmd_json.get("is_on").and_then(|v| v.as_bool()).unwrap_or(false);
                        let cmd_str = if next_on { "ON" } else { "OFF" };

                        let Ok(mut conn) = state.db_pool.get().await else { continue };
                        let mut q = tiberius::Query::new(
                            r#"
                            SELECT TOP 1 d.mqtt_topic
                            FROM dbo.devices d
                            LEFT JOIN dbo.rooms r ON d.room_id = r.id
                            LEFT JOIN dbo.houses h ON r.house_id = h.id
                            WHERE d.id = @P1 AND (d.owner_id = @P2 OR h.owner_id = @P2)
                            "#,
                        );
                        q.bind(dev_uuid);
                        q.bind(tenant_id);

                        let topic = match q.query(&mut conn).await {
                            Ok(stream) => match stream.into_row().await {
                                Ok(Some(row)) => row.get::<&str, _>("mqtt_topic").unwrap_or("").to_string(),
                                _ => {
                                    eprintln!("⛔ [WS TOGGLE] Thiết bị {} không thuộc tenant {}", dev_uuid, tenant_id);
                                    continue;
                                }
                            },
                            Err(e) => {
                                eprintln!("❌ [WS TOGGLE] SQL lỗi: {}", e);
                                continue;
                            }
                        };

                        // [FIX #3/#6] Chỉ gửi lệnh tới /control. KHÔNG ghi DB / broadcast lạc quan:
                        // trạng thái chỉ đổi khi ESP32 phản hồi /state (state ACK) -> UI luôn đúng phần cứng.
                        if !topic.trim().is_empty() {
                            let ctrl_topic = format!("{}/control", topic.trim_end_matches('/'));
                            let _ = state
                                .mqtt_client
                                .publish(&ctrl_topic, QoS::AtLeastOnce, false, cmd_str.as_bytes())
                                .await;
                            println!("📤 [WS TOGGLE] {} -> {}", ctrl_topic, cmd_str);
                        }
                    }
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                    _ => {}
                }
            }
        }
    }
}

// ============================================================================
// AUTOMATION ENGINE
// ============================================================================
fn get_rule_f64(row: &tiberius::Row, col: &str) -> Option<f64> {
    row.try_get::<f64, _>(col)
        .ok()
        .flatten()
        .or_else(|| row.try_get::<f32, _>(col).ok().flatten().map(|v| v as f64))
        .or_else(|| row.try_get::<i32, _>(col).ok().flatten().map(|v| v as f64))
        .or_else(|| row.try_get::<i64, _>(col).ok().flatten().map(|v| v as f64))
        .or_else(|| {
            row.try_get::<tiberius::numeric::Numeric, _>(col)
                .ok()
                .flatten()
                .map(f64::from)
        })
}

async fn evaluate_automations(
    pool: &SqlPool,
    mqtt_client: &AsyncClient,
    sensor_owners: &[Uuid],
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
        Err(e) => {
            eprintln!("❌ [AUTOMATION] Lỗi truy vấn dbo.automations: {}", e);
            return;
        }
    };

    for rule in rules {
        // Ưu tiên cột enabled vì nút gạt trên Web/Mobile cập nhật trực tiếp cột này
        let is_active = rule
            .try_get::<bool, _>("enabled")
            .ok()
            .flatten()
            .or_else(|| rule.try_get::<bool, _>("is_active").ok().flatten())
            .unwrap_or(true);
        if !is_active {
            continue;
        }

        // Kiểm tra kịch bản có thuộc một trong các hộ đang sở hữu chip cảm biến này không
        let rule_owner: Option<Uuid> = rule.try_get::<Uuid, _>("owner_id").ok().flatten();
        if let Some(r_owner) = rule_owner {
            if !sensor_owners.is_empty() && !sensor_owners.contains(&r_owner) {
                continue;
            }
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
        let threshold = get_rule_f64(&rule, "threshold")
            .or_else(|| get_rule_f64(&rule, "trigger_value"))
            .unwrap_or(30.0);
        let action = rule
            .try_get::<&str, _>("action")
            .ok()
            .flatten()
            .unwrap_or("ON")
            .trim()
            .to_uppercase();

        // Đọc device_id hỗ trợ cả kiểu UNIQUEIDENTIFIER lẫn NVARCHAR
        let device_id = rule
            .try_get::<Uuid, _>("device_id")
            .ok()
            .flatten()
            .map(|u| u.to_string())
            .or_else(|| {
                rule.try_get::<&str, _>("device_id")
                    .ok()
                    .flatten()
                    .map(|s| s.to_string())
            })
            .unwrap_or_default();

        let action_text = rule
            .try_get::<&str, _>("action_text")
            .ok()
            .flatten()
            .unwrap_or("")
            .to_string();

        let current_val = match cond_type.trim().to_lowercase().as_str() {
            "humidity" | "hum" => hum,
            "lux" | "light" => lux,
            "motion" | "pir" => motion,
            _ => temp,
        };

        let matched = match operator.trim().to_uppercase().as_str() {
            ">" | "GT" => current_val > threshold,
            ">=" | "GTE" => current_val >= threshold,
            "<" | "LT" => current_val < threshold,
            "<=" | "LTE" => current_val <= threshold,
            "==" | "=" | "EQ" => (current_val - threshold).abs() < 0.01,
            _ => false,
        };

        if !matched {
            continue;
        }

        let act_lower = action_text.to_lowercase();
        let trimmed_dev_id = device_id.trim();

        let target_row = if !trimmed_dev_id.is_empty() {
            let mut q = match rule_owner {
                Some(owner) => {
                    let mut q = tiberius::Query::new(
                        r#"
                        SELECT TOP 1 d.mqtt_topic,
                            ISNULL(d.is_on, CAST(0 AS BIT)) AS is_on,
                            ISNULL(d.status, N'OFF') AS status
                        FROM dbo.devices d
                        LEFT JOIN dbo.rooms r ON d.room_id = r.id
                        LEFT JOIN dbo.houses h ON r.house_id = h.id
                        WHERE LOWER(CAST(d.id AS NVARCHAR(36))) = LOWER(@P1)
                          AND COALESCE(d.owner_id, h.owner_id) = @P2
                        "#,
                    );
                    q.bind(trimmed_dev_id);
                    q.bind(owner);
                    q
                }
                None => {
                    let mut q = tiberius::Query::new(
                        r#"
                        SELECT TOP 1 d.mqtt_topic,
                            ISNULL(d.is_on, CAST(0 AS BIT)) AS is_on,
                            ISNULL(d.status, N'OFF') AS status
                        FROM dbo.devices d
                        WHERE LOWER(CAST(d.id AS NVARCHAR(36))) = LOWER(@P1)
                        "#,
                    );
                    q.bind(trimmed_dev_id);
                    q
                }
            };
            match q.query(&mut conn).await {
                Ok(s) => s.into_row().await.unwrap_or(None),
                Err(_) => None,
            }
        } else if act_lower.contains("quạt") || act_lower.contains("fan") {
            let mut q = match rule_owner {
                Some(owner) => {
                    let mut q = tiberius::Query::new(
                        r#"
                        SELECT TOP 1 d.mqtt_topic,
                            ISNULL(d.is_on, CAST(0 AS BIT)) AS is_on,
                            ISNULL(d.status, N'OFF') AS status
                        FROM dbo.devices d
                        LEFT JOIN dbo.rooms r ON d.room_id = r.id
                        LEFT JOIN dbo.houses h ON r.house_id = h.id
                        WHERE (d.device_type = N'fan' OR d.mqtt_topic LIKE N'%quat%' OR d.mqtt_topic LIKE N'%/fan')
                          AND COALESCE(d.owner_id, h.owner_id) = @P1
                        "#,
                    );
                    q.bind(owner);
                    q
                }
                None => tiberius::Query::new(
                    r#"
                    SELECT TOP 1 d.mqtt_topic,
                        ISNULL(d.is_on, CAST(0 AS BIT)) AS is_on,
                        ISNULL(d.status, N'OFF') AS status
                    FROM dbo.devices d
                    WHERE d.device_type = N'fan' OR d.mqtt_topic LIKE N'%quat%' OR d.mqtt_topic LIKE N'%/fan'
                    "#,
                ),
            };
            match q.query(&mut conn).await {
                Ok(s) => s.into_row().await.unwrap_or(None),
                Err(_) => None,
            }
        } else {
            let mut q = match rule_owner {
                Some(owner) => {
                    let mut q = tiberius::Query::new(
                        r#"
                        SELECT TOP 1 d.mqtt_topic,
                            ISNULL(d.is_on, CAST(0 AS BIT)) AS is_on,
                            ISNULL(d.status, N'OFF') AS status
                        FROM dbo.devices d
                        LEFT JOIN dbo.rooms r ON d.room_id = r.id
                        LEFT JOIN dbo.houses h ON r.house_id = h.id
                        WHERE (d.device_type = N'light' OR d.mqtt_topic LIKE N'%led%' OR d.mqtt_topic LIKE N'%/light')
                          AND COALESCE(d.owner_id, h.owner_id) = @P1
                        "#,
                    );
                    q.bind(owner);
                    q
                }
                None => tiberius::Query::new(
                    r#"
                    SELECT TOP 1 d.mqtt_topic,
                        ISNULL(d.is_on, CAST(0 AS BIT)) AS is_on,
                        ISNULL(d.status, N'OFF') AS status
                    FROM dbo.devices d
                    WHERE d.device_type = N'light' OR d.mqtt_topic LIKE N'%led%' OR d.mqtt_topic LIKE N'%/light'
                    "#,
                ),
            };
            match q.query(&mut conn).await {
                Ok(s) => s.into_row().await.unwrap_or(None),
                Err(_) => None,
            }
        };

        let Some(r) = target_row else {
            eprintln!(
                "⚠️  [AUTOMATION] Luật '{}' thỏa điều kiện ({} {} {}) nhưng không tìm thấy thiết bị đích (device_id='{}')",
                name, current_val, operator, threshold, trimmed_dev_id
            );
            continue;
        };

        let is_on_col = r.get::<bool, _>("is_on").unwrap_or(false);
        let status_str = r.get::<&str, _>("status").unwrap_or("");
        let already_on = is_on_col || status_str.trim().eq_ignore_ascii_case("ON");
        let target_topic = r.get::<&str, _>("mqtt_topic").unwrap_or("").to_string();

        let want_on = action == "ON" || action == "1" || action == "TRUE" || action.contains("BẬT");
        if target_topic.is_empty() || already_on == want_on {
            continue;
        }

        let cmd = if want_on { "ON" } else { "OFF" };
        let ctrl_topic = format!("{}/control", target_topic.trim_end_matches('/'));
        let _ = mqtt_client
            .publish(&ctrl_topic, QoS::AtLeastOnce, false, cmd.as_bytes())
            .await;

        println!(
            "⚡ [AUTOMATION TRIGGERED] '{}' ({} {} {}) -> {} = {} (chờ state ACK)",
            name, current_val, operator, threshold, ctrl_topic, cmd
        );
    }
}

