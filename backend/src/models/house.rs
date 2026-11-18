use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tiberius::Row;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct House {
    pub id: Uuid,
    pub name: String,
    pub address: Option<String>,
    pub owner_id: Uuid,
    pub created_at: Option<DateTime<Utc>>,
}

impl House {
    pub fn from_row(row: &Row) -> Option<Self> {
        let id = row.get::<Uuid, _>("id")?;
        let owner_id = row.get::<Uuid, _>("owner_id")?;
        let name = row.get::<&str, _>("name").unwrap_or("").to_string();
        let address = row.get::<&str, _>("address").map(|s| s.to_string());
        let created_at = row.get::<DateTime<Utc>, _>("created_at");

        Some(Self {
            id,
            name,
            address,
            owner_id,
            created_at,
        })
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateHouseDto {
    pub name: String,
    pub address: Option<String>,
    #[serde(default)]
    pub owner_id: Option<String>,
}