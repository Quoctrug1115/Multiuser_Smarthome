use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::IntoResponse,
};
use std::sync::Arc;

use crate::AppState;

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(mut socket: WebSocket, state: Arc<AppState>) {
    println!("[WebSocket] Client connected!");
    let mut rx = state.tx.subscribe();

    loop {
        tokio::select! {
            // Nhận dữ liệu broadcast từ MQTT/AI Engine gửi xuống Client
            Ok(msg) = rx.recv() => {
                if socket.send(Message::Text(msg.into())).await.is_err() {
                    break;
                }
            }
            // Nhận tin nhắn do Client gửi lên Backend
            Some(Ok(msg)) = socket.recv() => {
                match msg {
                    Message::Text(text) => println!("Nhận từ client: {}", text),
                    Message::Close(_) => break,
                    _ => {}
                }
            }
            else => break,
        }
    }

    println!("[WebSocket] Client disconnected!");
}