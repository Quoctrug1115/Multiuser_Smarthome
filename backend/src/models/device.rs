use serde::{Deserialize, Serialize};
use tiberius::Row;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: Uuid,
    #[serde(default)]
    pub room_id: Option<Uuid>,
    #[serde(default)]
    pub room_name: Option<String>,
    pub name: String,
    pub device_type: String,
    pub mqtt_topic: String,
    #[serde(default)]
    pub is_on: bool,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub power_watt: Option<i32>,
}

impl Device {
    pub fn from_row(row: &Row) -> Option<Self> {
        let id = row.get::<Uuid, _>("id")?;
        let is_on = row.get::<bool, _>("is_on").unwrap_or(false);
        let status = row
            .get::<&str, _>("status")
            .map(|s| s.to_string())
            .or_else(|| Some(if is_on { "ON".to_string() } else { "OFF".to_string() }));

        Some(Self {
            id,
            room_id: row.get::<Uuid, _>("room_id"),
            room_name: row.get::<&str, _>("room_name").map(|s| s.to_string()),
            name: row.get::<&str, _>("name").unwrap_or("").to_string(),
            device_type: row
                .get::<&str, _>("device_type")
                .unwrap_or("switch")
                .to_string(),
            mqtt_topic: row.get::<&str, _>("mqtt_topic").unwrap_or("").to_string(),
            is_on,
            status,
            power_watt: row.get::<i32, _>("power_watt"),
        })
    }
}

#[derive(Debug, Deserialize)]
pub struct DevicePayload {
    pub name: String,
    pub device_type: String,
    pub mqtt_topic: String,
    #[serde(default)]
    pub room_id: Option<String>,
}