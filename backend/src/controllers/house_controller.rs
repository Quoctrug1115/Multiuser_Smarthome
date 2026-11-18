use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use std::sync::Arc;
use uuid::Uuid;

use crate::models::house::{CreateHouseDto, House};
use crate::models::room::{CreateRoomDto, Room};
use crate::models::user::Claims;
use crate::services::rbac_service::check_permission;
use crate::AppState;

// ==================== HOUSES ====================

pub async fn get_houses(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<House>>, (StatusCode, String)> {
    let houses = sqlx::query_as::<_, House>(
        "SELECT id, name, address, owner_id, created_at FROM houses ORDER BY created_at ASC",
    )
    .fetch_all(&state.db_pool)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(Json(houses))
}

pub async fn create_house(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateHouseDto>,
) -> Result<(StatusCode, Json<House>), (StatusCode, String)> {
    check_permission(&state.db_pool, &claims, &["Owner", "Admin", "owner", "admin"], None)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e))?;

    let house = sqlx::query_as::<_, House>(
        "INSERT INTO houses (name, address, owner_id) VALUES ($1, $2, $3) RETURNING *",
    )
    .bind(payload.name.trim())
    .bind(&payload.address)
    .bind(claims.sub)
    .fetch_one(&state.db_pool)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok((StatusCode::CREATED, Json(house)))
}

pub async fn update_house(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
    Json(payload): Json<CreateHouseDto>,
) -> Result<Json<House>, (StatusCode, String)> {
    check_permission(&state.db_pool, &claims, &["Owner", "Admin", "owner", "admin"], None)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e))?;

    let house = sqlx::query_as::<_, House>(
        "UPDATE houses SET name = $1, address = $2 WHERE id = $3 RETURNING *",
    )
    .bind(payload.name.trim())
    .bind(&payload.address)
    .bind(id)
    .fetch_optional(&state.db_pool)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .ok_or_else(|| (StatusCode::NOT_FOUND, "Không tìm thấy ngôi nhà".to_string()))?;

    Ok(Json(house))
}

pub async fn delete_house(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, (StatusCode, String)> {
    check_permission(&state.db_pool, &claims, &["Owner", "Admin", "owner", "admin"], None)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e))?;

    sqlx::query("DELETE FROM houses WHERE id = $1")
        .bind(id)
        .execute(&state.db_pool)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(StatusCode::NO_CONTENT)
}

// ==================== ROOMS ====================

pub async fn get_rooms(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<Room>>, (StatusCode, String)> {
    let rooms = sqlx::query_as::<_, Room>(
        r#"
        SELECT r.id, r.house_id, h.name AS house_name, r.name, COALESCE(r.floor, 1) AS floor
        FROM rooms r
        LEFT JOIN houses h ON r.house_id = h.id
        ORDER BY r.floor ASC, r.name ASC
        "#,
    )
    .fetch_all(&state.db_pool)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(Json(rooms))
}

pub async fn create_room(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateRoomDto>,
) -> Result<(StatusCode, Json<Room>), (StatusCode, String)> {
    check_permission(&state.db_pool, &claims, &["Owner", "Admin", "owner", "admin"], None)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e))?;

    let room = sqlx::query_as::<_, Room>(
        "INSERT INTO rooms (house_id, name, floor) VALUES ($1, $2, $3) RETURNING *",
    )
    .bind(payload.house_id)
    .bind(payload.name.trim())
    .bind(payload.floor)
    .fetch_one(&state.db_pool)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok((StatusCode::CREATED, Json(room)))
}

pub async fn update_room(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
    Json(payload): Json<CreateRoomDto>,
) -> Result<Json<Room>, (StatusCode, String)> {
    check_permission(&state.db_pool, &claims, &["Owner", "Admin", "owner", "admin"], None)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e))?;

    let room = sqlx::query_as::<_, Room>(
        "UPDATE rooms SET house_id = $1, name = $2, floor = $3 WHERE id = $4 RETURNING *",
    )
    .bind(payload.house_id)
    .bind(payload.name.trim())
    .bind(payload.floor)
    .bind(id)
    .fetch_optional(&state.db_pool)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .ok_or_else(|| (StatusCode::NOT_FOUND, "Không tìm thấy phòng".to_string()))?;

    Ok(Json(room))
}

pub async fn delete_room(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, (StatusCode, String)> {
    check_permission(&state.db_pool, &claims, &["Owner", "Admin", "owner", "admin"], None)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e))?;

    sqlx::query("DELETE FROM rooms WHERE id = $1")
        .bind(id)
        .execute(&state.db_pool)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(StatusCode::NO_CONTENT)
}