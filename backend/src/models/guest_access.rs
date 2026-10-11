use serde::{Deserialize, Serialize};
use uuid::Uuid;
use chrono::{DateTime, Utc};

#[derive(Debug, Deserialize)]
pub struct GrantGuestAccessDto {
    pub guest_id: Uuid,
    pub device_id: Uuid,
    pub valid_from: DateTime<Utc>,
    pub valid_until: DateTime<Utc>,
}