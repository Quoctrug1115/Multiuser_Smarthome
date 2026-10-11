use serde::{Deserialize, Serialize};
use uuid::Uuid;
use chrono::{DateTime, Utc};

#[derive(Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct Room {
    pub id: Uuid,
    pub house_id: Uuid,
    pub name: String,
    pub floor: i32,
}

#[derive(Debug, Deserialize)]
pub struct CreateRoomDto {
    pub house_id: Uuid,
    pub name: String,
    pub floor: i32,
}