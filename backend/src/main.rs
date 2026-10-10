mod mqtt;

use axum::{routing::get, Router};
use std::net::SocketAddr;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    // Khởi chạy MQTT Listener task
    let _mqtt_client = mqtt::client::init_mqtt().await;
    println!("🚀 [MQTT] Listener initialized successfully.");

    // Dựng Axum HTTP Router cơ bản
    let app = Router::new().route("/health", get(|| async { "OK - SmartHome Backend" }));

    let addr = SocketAddr::from(([0, 0, 0, 0], 3000));
    println!("🌐 [Axum] Server running on http://{}", addr);
    
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}