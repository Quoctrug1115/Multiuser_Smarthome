use serde::{Deserialize, Serialize};
use uuid::Uuid;
use chrono::{DateTime, Utc};

#[derive(Debug, Serialize, Deserialize, sqlx::FromRow)]
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
}
