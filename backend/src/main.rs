mod controllers;
mod models;
mod mqtt;
mod services;

use axum::{
    routing::{post},
    Router,
};
use sqlx::postgres::PgPoolOptions;
use std::net::SocketAddr;
use tower_http::cors::CorsLayer;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    dotenvy::dotenv().ok();

    let db_url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://postgres:postgrespassword@localhost:5432/smarthome_db".to_string());

    let pool = PgPoolOptions::new()
        .max_connections(10)
        .connect(&db_url)
        .await
        .expect("Failed to connect to PostgreSQL/TimescaleDB");

    println!("✅ [Database] PostgreSQL & TimescaleDB Connected.");

    // Khởi chạy MQTT Listener
    let _mqtt_client = mqtt::client::init_mqtt().await;

    // Routing toàn bộ API
    let app = Router::new()
        // Public Auth API
        .route("/api/v1/auth/register", post(controllers::auth_controller::register))
        .route("/api/v1/auth/login", post(controllers::auth_controller::login))
        .route("/api/v1/auth/logout", post(controllers::auth_controller::logout))
        
        // House & Room API
        .route("/api/v1/houses", post(controllers::house_controller::create_house))
        .route("/api/v1/rooms", post(controllers::house_controller::create_room))

        // Device & Guest Access API
        .route("/api/v1/devices", post(controllers::device_controller::create_device))
        .route("/api/v1/devices/guest-access", post(controllers::device_controller::grant_guest_access))

        .layer(CorsLayer::permissive())
        .with_state(pool);

    let addr = SocketAddr::from(([0, 0, 0, 0], 3000));
    println!("🚀 [Backend] Axum Server listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}