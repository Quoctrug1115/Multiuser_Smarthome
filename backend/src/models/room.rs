use serde::{Deserialize, Serialize};
use tiberius::Row;
use uuid::Uuid;

fn default_floor() -> i32 {
    1
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Room {
    pub id: Uuid,
    pub house_id: Uuid,
    #[serde(default)]
    pub house_name: Option<String>,
    pub name: String,
    pub floor: i32,
}

impl Room {
    pub fn from_row(row: &Row) -> Option<Self> {
        let id = row.get::<Uuid, _>("id")?;
        let house_id = row.get::<Uuid, _>("house_id")?;
        let house_name = row.get::<&str, _>("house_name").map(|s| s.to_string());
        let name = row.get::<&str, _>("name").unwrap_or("").to_string();
        let floor = row.get::<i32, _>("floor").unwrap_or_else(default_floor);

        Some(Self {
            id,
            house_id,
            house_name,
            name,
            floor,
        })
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateRoomDto {
    pub house_id: Uuid,
    pub name: String,
    #[serde(default = "default_floor")]
    pub floor: i32,
}