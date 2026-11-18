use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct Device {
    pub id: Uuid,
    #[sqlx(default)]
    pub room_id: Option<Uuid>,
    #[sqlx(default)]
    pub room_name: Option<String>,
    pub name: String,
    pub device_type: String,
    pub mqtt_topic: String,
    #[sqlx(default)]
    pub is_on: bool,
    #[sqlx(default)]
    pub status: Option<String>,
    #[sqlx(default)]
    pub power_watt: Option<i32>,
}

#[derive(Debug, Deserialize)]
pub struct DevicePayload {
    pub name: String,
    pub device_type: String,
    pub mqtt_topic: String,
    #[serde(default)]
    pub room_id: Option<String>,
}