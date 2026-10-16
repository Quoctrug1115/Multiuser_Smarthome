use axum::{extract::State, http::StatusCode, Json};
use sqlx::PgPool;
use crate::models::device::{CreateDeviceDto, Device, GrantGuestAccessDto};
use crate::models::user::Claims;
use crate::services::rbac_service::check_permission;

pub async fn create_device(
    claims: Claims,
    State(pool): State<PgPool>,
    Json(payload): Json<CreateDeviceDto>,
) -> Result<(StatusCode, Json<Device>), (StatusCode, String)> {
    check_permission(&pool, &claims, &["Owner"], None)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e))?;

    let device = sqlx::query_as::<_, Device>(
        r#"
        INSERT INTO devices (room_id, name, device_type, mqtt_topic) 
        VALUES ($1, $2, $3, $4) 
        RETURNING *
        "#,
    )
    .bind(payload.room_id)
    .bind(&payload.name)
    .bind(&payload.device_type)
    .bind(&payload.mqtt_topic)
    .fetch_one(&pool)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok((StatusCode::CREATED, Json(device)))
}

pub async fn grant_guest_access(
    claims: Claims,
    State(pool): State<PgPool>,
    Json(payload): Json<GrantGuestAccessDto>,
) -> Result<(StatusCode, Json<String>), (StatusCode, String)> {
    check_permission(&pool, &claims, &["Owner"], None)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e))?;

    sqlx::query(
        r#"
        INSERT INTO guest_access (guest_id, device_id, valid_from, valid_until) 
        VALUES ($1, $2, $3, $4)
        "#,
    )
    .bind(payload.guest_id)
    .bind(payload.device_id)
    .bind(payload.valid_from)
    .bind(payload.valid_until)
    .execute(&pool)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok((StatusCode::CREATED, Json("Guest access granted successfully".to_string())))
}