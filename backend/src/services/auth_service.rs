const JWT_SECRET: &[u8] = b"SMARTHOME_RUST_AXUM_SECRET_KEY";

pub fn hash_password(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to.string())
        .map_err(|e| e.to_string())
}

pub fn verify_password(password: &str, hash: &str) ->bool {
    let parsed_hash = match PasswordHash::new(hash) {
        Ok(h)=> h,
        Err(_)=> return false,
    };
    Argon2::default().verify_password(password.as_bytes(), &parsed_hash).is_ok()
}