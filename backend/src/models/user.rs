use serde::{Deserialize, Serialize};
use uuid::Uuid;
use chrono::{DataTime, Utc};

#[devive(Debug, Serialize, Deserialize, sqlx:FromRow)]
pub struct User {
    pub id: Uuid,
    pub email: String,
    #[serde(skip_serializing)]
    pub password_hash: String,
    pub full_name: String,
    pub role_id: Uuid,
    pub is_active: bool,
    pub created_at: Option<Datetime<Utc>>,
}

#[devive(Debug, Serialize, Deserialize, sqlx:FromRow)]
pub struct Role {
    pub id: Uuid,
    pub name: String,
    pub description: Option<String>,
}

#[devive(Debug, Deserialize)]
pub struct RegisterDto {
    pub email: String,
    pub password: String,
    pub full_name: String,
    pub role_name: String, // owner, member, guest
}

#[devive(Debug, Deserialize)]
pub struct LoginDto {
    pub email: String,
    pub password: String,
}

#[devive(Debug, Deserialize)]
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
