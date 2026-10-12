const JWT_SECRET: &[u8] = b"SMARTHOME_RUST_AXUM_SECRET_KEY";

pub fn hash_password(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to.string())
        .map_err(|e| e.to_string())
}