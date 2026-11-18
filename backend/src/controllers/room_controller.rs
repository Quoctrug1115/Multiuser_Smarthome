use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::Row;
use std::sync::Arc;
use uuid::Uuid;

use crate::controllers::user_controller::{ensure_owner_or_admin, resolve_tenant_id};
use crate::models::user::Claims;
use crate::AppState;

#[derive(Deserialize)]
pub struct CreateRoomPayload {
    pub house_id: String,
    pub name: String,
    pub floor: Option<i32>,
}

#[derive(Deserialize)]
pub struct UpdateRoomPayload {
    pub house_id: Option<String>,
    pub name: Option<String>,
    pub floor: Option<i32>,
}

// GET /api/v1/rooms
pub async fn get_rooms(
    claims: Claims,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let query = r#"
        SELECT
            r.id,
            r.house_id,
            h.name AS house_name,
            r.name,
            COALESCE(r.floor, 1) AS floor
        FROM rooms r
        INNER JOIN houses h ON r.house_id = h.id
        WHERE h.owner_id = $1
        ORDER BY h.name ASC, r.floor ASC, r.name ASC
    "#;

    match sqlx::query(query)
        .bind(tenant_id)
        .fetch_all(&state.db_pool)
        .await
    {
        Ok(rows) => {
            let rooms: Vec<Value> = rows
                .into_iter()
                .map(|row| {
                    let id: Uuid = row.get("id");
                    let house_id: Uuid = row.get("house_id");
                    let house_name: String = row.try_get("house_name").unwrap_or_default();
                    let name: String = row.get("name");
                    let floor: i32 = row.try_get("floor").unwrap_or(1);

                    json!({
                        "id": id.to_string(),
                        "house_id": house_id.to_string(),
                        "house_name": house_name,
                        "name": name,
                        "floor": floor
                    })
                })
                .collect();

            (StatusCode::OK, Json(json!(rooms))).into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi truy vấn danh sách phòng: {}", e) })),
        )
            .into_response(),
    }
}

// POST /api/v1/rooms
pub async fn create_room(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateRoomPayload>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let Ok(house_uuid) = Uuid::parse_str(payload.house_id.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID ngôi nhà không hợp lệ" })),
        )
            .into_response();
    };

    let name = payload.name.trim().to_string();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Tên phòng không được để trống" })),
        )
            .into_response();
    }

    // Xác minh ngôi nhà trực thuộc đúng hộ gia đình của user
    let house_row = sqlx::query("SELECT name FROM houses WHERE id = $1 AND owner_id = $2")
        .bind(house_uuid)
        .bind(tenant_id)
        .fetch_optional(&state.db_pool)
        .await;

    let house_name: String = match house_row {
        Ok(Some(r)) => r.get("name"),
        Ok(None) => {
            return (
                StatusCode::FORBIDDEN,
                Json(json!({ "error": "Ngôi nhà không tồn tại hoặc không thuộc quyền quản lý của bạn" })),
            )
                .into_response();
        }
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let floor = payload.floor.unwrap_or(1);
    let room_id = Uuid::new_v4();

    match sqlx::query("INSERT INTO rooms (id, house_id, name, floor) VALUES ($1, $2, $3, $4)")
        .bind(room_id)
        .bind(house_uuid)
        .bind(&name)
        .bind(floor)
        .execute(&state.db_pool)
        .await
    {
        Ok(_) => (
            StatusCode::CREATED,
            Json(json!({
                "id": room_id.to_string(),
                "house_id": house_uuid.to_string(),
                "house_name": house_name,
                "name": name,
                "floor": floor
            })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Không thể tạo phòng: {}", e) })),
        )
            .into_response(),
    }
}

// PUT /api/v1/rooms/{id}
pub async fn update_room(
    claims: Claims,
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<UpdateRoomPayload>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let Ok(room_uuid) = Uuid::parse_str(&id) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID phòng không hợp lệ" })),
        )
            .into_response();
    };

    let current = sqlx::query(
        "SELECT r.house_id, r.name, COALESCE(r.floor, 1) AS floor
         FROM rooms r
         INNER JOIN houses h ON r.house_id = h.id
         WHERE r.id = $1 AND h.owner_id = $2",
    )
    .bind(room_uuid)
    .bind(tenant_id)
    .fetch_optional(&state.db_pool)
    .await;

    let row = match current {
        Ok(Some(r)) => r,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({ "error": "Không tìm thấy phòng thuộc quyền quản lý của bạn" })),
            )
                .into_response();
        }
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let old_house_id: Uuid = row.get("house_id");
    let old_name: String = row.get("name");
    let old_floor: i32 = row.try_get("floor").unwrap_or(1);

    let target_house_id = if let Some(hid_str) = payload.house_id.filter(|s| !s.trim().is_empty()) {
        let Ok(parsed_hid) = Uuid::parse_str(hid_str.trim()) else {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "error": "ID ngôi nhà đích không hợp lệ" })),
            )
                .into_response();
        };

        let valid_target = sqlx::query("SELECT id FROM houses WHERE id = $1 AND owner_id = $2")
            .bind(parsed_hid)
            .bind(tenant_id)
            .fetch_optional(&state.db_pool)
            .await
            .unwrap_or(None);

        if valid_target.is_none() {
            return (
                StatusCode::FORBIDDEN,
                Json(json!({ "error": "Ngôi nhà đích không thuộc quyền quản lý của bạn" })),
            )
                .into_response();
        }
        parsed_hid
    } else {
        old_house_id
    };

    let new_name = payload
        .name
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or(old_name);
    let new_floor = payload.floor.unwrap_or(old_floor);

    match sqlx::query("UPDATE rooms SET house_id = $1, name = $2, floor = $3 WHERE id = $4")
        .bind(target_house_id)
        .bind(&new_name)
        .bind(new_floor)
        .bind(room_uuid)
        .execute(&state.db_pool)
        .await
    {
        Ok(_) => (
            StatusCode::OK,
            Json(json!({
                "id": room_uuid.to_string(),
                "house_id": target_house_id.to_string(),
                "name": new_name,
                "floor": new_floor
            })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi cập nhật phòng: {}", e) })),
        )
            .into_response(),
    }
}

// DELETE /api/v1/rooms/{id}
pub async fn delete_room(
    claims: Claims,
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let Ok(room_uuid) = Uuid::parse_str(&id) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID phòng không hợp lệ" })),
        )
            .into_response();
    };

    // Kiểm tra quyền sở hữu phòng thông qua ngôi nhà cha
    let owned = sqlx::query(
        "SELECT r.id FROM rooms r
         INNER JOIN houses h ON r.house_id = h.id
         WHERE r.id = $1 AND h.owner_id = $2",
    )
    .bind(room_uuid)
    .bind(tenant_id)
    .fetch_optional(&state.db_pool)
    .await
    .unwrap_or(None);

    if owned.is_none() {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Không tìm thấy phòng thuộc quyền quản lý của bạn" })),
        )
            .into_response();
    }

    // Chuyển các thiết bị trong phòng về "Chưa phân phòng" trước khi xóa phòng
    let _ = sqlx::query("UPDATE devices SET room_id = NULL WHERE room_id = $1")
        .bind(room_uuid)
        .execute(&state.db_pool)
        .await;

    match sqlx::query("DELETE FROM rooms WHERE id = $1")
        .bind(room_uuid)
        .execute(&state.db_pool)
        .await
    {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi xóa phòng: {}", e) })),
        )
            .into_response(),
    }
}