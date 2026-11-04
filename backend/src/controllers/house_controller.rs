use axum::{extract::State, http::StatusCode, Json};
use std::sync::Arc;
use crate::models::house::{CreateHouseDto, House};
use crate::models::room::{CreateRoomDto, Room};
use crate::models::user::Claims;
use crate::services::rbac_service::check_permission;
use crate::ws::handler::AppState;

pub async fn create_house(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateHouseDto>,
) -> Result<(StatusCode, Json<House>), (StatusCode, String)> {
    check_permission(&state.db_pool, &claims, &["Owner"], None)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e))?;

    let house = sqlx::query_as::<_, House>(
        "INSERT INTO houses (name, address, owner_id) VALUES ($1, $2, $3) RETURNING *",
    )
    .bind(&payload.name)
    .bind(&payload.address)
    .bind(claims.sub)
    .fetch_one(&state.db_pool)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok((StatusCode::CREATED, Json(house)))
}

pub async fn create_room(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateRoomDto>,
) -> Result<(StatusCode, Json<Room>), (StatusCode, String)> {
    check_permission(&state.db_pool, &claims, &["Owner"], None)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e))?;

    let room = sqlx::query_as::<_, Room>(
        "INSERT INTO rooms (house_id, name, floor) VALUES ($1, $2, $3) RETURNING *",
    )
    .bind(payload.house_id)
    .bind(&payload.name)
    .bind(payload.floor)
    .fetch_one(&state.db_pool)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok((StatusCode::CREATED, Json(room)))
}