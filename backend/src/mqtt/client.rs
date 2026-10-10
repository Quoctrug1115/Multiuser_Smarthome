use rumqttc::{AsyncClient, MqttOptions, QoS, Event, Packet};
use std::time::Duration;

pub async fn init_mqtt() -> AsyncClient {
    let mut mqttoptions = MqttOptions::new("rust_backend_service", "localhost", 1883);
    mqttoptions.set_keep_alive(Duration::from_secs(5));

    let (client, mut eventloop) = AsyncClient::new(mqttoptions, 10);

    // Subscribe topic nhận dữ liệu cảm biến từ ESP32
    client.subscribe("smarthome/sensors/dht22", QoS::AtMostOnce)
        .await
        .expect("Failed to subscribe topic");

    // Spawn background task để xử lý Message bất đồng bộ
    tokio::spawn(async move {
        loop {
            match eventloop.poll().await {
                Ok(Event::Incoming(Packet::Publish(publish))) => {
                    if let Ok(payload_str) = String::from_utf8(publish.payload.to_vec()) {
                        println!(" -> [Rust Backend] Received MQTT Data on '{}': {}", publish.topic, payload_str);
                        // Tuần 4-5 sẽ bổ sung code parse JSON và lưu PostgreSQL tại đây
                    }
                }
                Ok(_) => {},
                Err(e) => {
                    println!("MQTT Connection Error: {:?}", e);
                    tokio::time::sleep(Duration::from_secs(2)).await;
                }
            }
        }
    });

    client
}