use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct House {
    pub id: Uuid,
    pub name: String,
    pub address: Option<String>,
    pub owner_id: Uuid,
    pub created_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize)]
pub struct CreateHouseDto {
    pub name: String,
    pub address: Option<String>,
    #[serde(default)]
    pub owner_id: Option<String>,
}