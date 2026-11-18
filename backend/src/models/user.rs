use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tiberius::Row;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: Uuid,
    pub email: String,
    #[serde(skip_serializing)]
    pub password_hash: String,
    pub full_name: String,
    pub role_id: Uuid,
    pub is_active: bool,
    pub created_at: Option<DateTime<Utc>>,
}

impl User {
    pub fn from_row(row: &Row) -> Option<Self> {
        let id = row.get::<Uuid, _>("id")?;
        let email = row.get::<&str, _>("email").unwrap_or("").to_string();
        let password_hash = row
            .get::<&str, _>("password_hash")
            .unwrap_or("")
            .to_string();
        let full_name = row.get::<&str, _>("full_name").unwrap_or("").to_string();
        let role_id = row.get::<Uuid, _>("role_id")?;
        let is_active = row.get::<bool, _>("is_active").unwrap_or(true);
        let created_at = row.get::<DateTime<Utc>, _>("created_at");

        Some(Self {
            id,
            email,
            password_hash,
            full_name,
            role_id,
            is_active,
            created_at,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Role {
    pub id: Uuid,
    pub name: String,
    pub description: Option<String>,
}

impl Role {
    pub fn from_row(row: &Row) -> Option<Self> {
        let id = row.get::<Uuid, _>("id")?;
        let name = row.get::<&str, _>("name").unwrap_or("").to_string();
        let description = row.get::<&str, _>("description").map(|s| s.to_string());

        Some(Self {
            id,
            name,
            description,
        })
    }
}

#[derive(Debug, Deserialize)]
pub struct RegisterDto {
    pub email: String,
    pub password: String,
    pub full_name: String,
    pub role_name: String, // owner, member, guest
}

#[derive(Debug, Deserialize)]
pub struct LoginDto {
    pub email: String,
    pub password: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct AuthResponseDto {
    pub token: String,
    pub user_id: Uuid,
    pub email: String,
    pub role_name: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Claims {
    pub sub: Uuid, // user_id
    pub session_id: Uuid,
    pub email: String,
    pub role_name: String,
    pub exp: usize,
}