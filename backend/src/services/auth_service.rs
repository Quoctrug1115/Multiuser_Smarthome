use axum::{
    extract::FromRequestParts,
    http::{header, request::Parts, StatusCode},
};
use jsonwebtoken::{decode, encode, DecodingKey, EncodingKey, Header, Validation};
use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use uuid::Uuid;
use crate::models::user::Claims;

const JWT_SECRET: &[u8] = b"SMARTHOME_RUST_AXUM_SECRET_KEY";

pub fn hash_password(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| e.to_string())
}

pub fn verify_password(password: &str, hash: &str) -> bool {
    let parsed_hash = match PasswordHash::new(hash) {
        Ok(h) => h,
        Err(_) => return false,
    };
    Argon2::default()
        .verify_password(password.as_bytes(), &parsed_hash).is_ok()
}

pub fn create_jwt (
    user_id: Uuid,
    session_id: Uuid,
    email: &str,
    role_name: &str
) -> Result<String,String> {
    let expiration = chrono::Utc::now()
        .checked_add_signed(chrono::Duration::days(7))
        .expect("Valid timestamp")
        .timestamp() as usize;

    let claims = Claims {
        sub: user_id,
        session_id,
        email: email.to_string(),
        role_name: role_name.to_string(),
        exp: expiration,
    };

    encode(&Header::default(), &claims, &EncodingKey::from_secret(JWT_SECRET))
        .map_err(|e| e.to_string())    
}

impl<S> FromRequestParts<S> for Claims 
where 
    S: Send + Sync,
{
    type Rejection = (StatusCode, &'static str);
    
    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let auth_header =  parts
            .headers
            .get(header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .ok_or((StatusCode::UNAUTHORIZED, "Missing Authorization Header"))?;

        if !auth_header.starts_with("Bearer") {
            return Err((StatusCode::UNAUTHORIZED, "Invalid Bearer Token"));
        }

        let token = &auth_header[7..];
        let token_data = decode::<Claims>(
            token, &DecodingKey::from_secret(JWT_SECRET),
            &Validation::default()
        ).map_err(|_| (StatusCode::UNAUTHORIZED, "Token is invalid or expired"))?;
        Ok(token_data.claims)
    }
}

