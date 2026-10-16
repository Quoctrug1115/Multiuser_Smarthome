use serde::{Deserialize, Serialize};
use uuid::Uuid;
use chrono::{DateTime, Utc};
use serde_json::Value as JsonValue;

#[derive(Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct Device {
    pub id: Uuid,
    pub room_id: Option<Uuid>,
    pub name: String,
    pub device_type: String,
    pub mqtt_topic: String,
    pub status: String,
    pub current_state: Option<JsonValue>,
    pub last_seen: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize)]
pub struct CreateDeviceDto {
    pub room_id: Option<Uuid>,
    pub name: String,
    pub device_type: String,
    pub mqtt_topic: String,
}

#[derive(Debug, Deserialize)]
pub struct GrantGuestAccessDto {
    pub guest_id: Uuid,
    pub device_id: Uuid,
    pub valid_from: DateTime<Utc>,
    pub valid_until: DateTime<Utc>,
}