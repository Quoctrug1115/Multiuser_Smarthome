use serde::{Deserialize, Serialize};
use uuid::Uuid;

fn default_floor() -> i32 {
    1
}

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct Room {
    pub id: Uuid,
    pub house_id: Uuid,
    #[sqlx(default)]
    pub house_name: Option<String>,
    pub name: String,
    pub floor: i32,
}

#[derive(Debug, Deserialize)]
pub struct CreateRoomDto {
    pub house_id: Uuid,
    pub name: String,
    #[serde(default = "default_floor")]
    pub floor: i32,
}