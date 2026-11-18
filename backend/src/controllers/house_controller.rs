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
pub struct CreateHousePayload {
    pub name: String,
    pub address: Option<String>,
    #[allow(dead_code)]
    pub owner_id: Option<String>,
}

#[derive(Deserialize)]
pub struct UpdateHousePayload {
    pub name: Option<String>,
    pub address: Option<String>,
}

// GET /api/v1/houses
pub async fn get_houses(
    claims: Claims,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let query = r#"
        SELECT id, name, COALESCE(address, '') AS address, owner_id
        FROM houses
        WHERE owner_id = $1
        ORDER BY name ASC
    "#;

    match sqlx::query(query)
        .bind(tenant_id)
        .fetch_all(&state.db_pool)
        .await
    {
        Ok(rows) => {
            let houses: Vec<Value> = rows
                .into_iter()
                .map(|row| {
                    let id: Uuid = row.get("id");
                    let name: String = row.get("name");
                    let address: String = row.try_get("address").unwrap_or_default();
                    let owner_id: Option<Uuid> = row.try_get("owner_id").unwrap_or(None);

                    json!({
                        "id": id.to_string(),
                        "name": name,
                        "address": address,
                        "owner_id": owner_id.map(|u| u.to_string())
                    })
                })
                .collect();

            (StatusCode::OK, Json(json!(houses))).into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi truy vấn danh sách nhà: {}", e) })),
        )
            .into_response(),
    }
}

// POST /api/v1/houses
pub async fn create_house(
    claims: Claims,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateHousePayload>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let name = payload.name.trim().to_string();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Tên ngôi nhà không được để trống" })),
        )
            .into_response();
    }

    let address = payload.address.unwrap_or_default().trim().to_string();
    let house_id = Uuid::new_v4();

    let res = sqlx::query(
        "INSERT INTO houses (id, name, address, owner_id) VALUES ($1, $2, $3, $4)",
    )
    .bind(house_id)
    .bind(&name)
    .bind(&address)
    .bind(tenant_id)
    .execute(&state.db_pool)
    .await;

    match res {
        Ok(_) => (
            StatusCode::CREATED,
            Json(json!({
                "id": house_id.to_string(),
                "name": name,
                "address": address,
                "owner_id": tenant_id.to_string()
            })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Không thể tạo ngôi nhà: {}", e) })),
        )
            .into_response(),
    }
}

// PUT /api/v1/houses/{id}
pub async fn update_house(
    claims: Claims,
    Path(id): Path<String>,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<UpdateHousePayload>,
) -> impl IntoResponse {
    if let Err(resp) = ensure_owner_or_admin(&state.db_pool, &claims).await {
        return resp;
    }

    let tenant_id = match resolve_tenant_id(&state.db_pool, claims.sub).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let Ok(house_uuid) = Uuid::parse_str(&id) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID ngôi nhà không hợp lệ" })),
        )
            .into_response();
    };

    let current = sqlx::query("SELECT name, COALESCE(address, '') AS address FROM houses WHERE id = $1 AND owner_id = $2")
        .bind(house_uuid)
        .bind(tenant_id)
        .fetch_optional(&state.db_pool)
        .await;

    let row = match current {
        Ok(Some(r)) => r,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({ "error": "Không tìm thấy ngôi nhà thuộc quyền quản lý của bạn" })),
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

    let old_name: String = row.get("name");
    let old_address: String = row.try_get("address").unwrap_or_default();

    let new_name = payload
        .name
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or(old_name);
    let new_address = payload
        .address
        .map(|s| s.trim().to_string())
        .unwrap_or(old_address);

    match sqlx::query("UPDATE houses SET name = $1, address = $2 WHERE id = $3 AND owner_id = $4")
        .bind(&new_name)
        .bind(&new_address)
        .bind(house_uuid)
        .bind(tenant_id)
        .execute(&state.db_pool)
        .await
    {
        Ok(_) => (
            StatusCode::OK,
            Json(json!({
                "id": house_uuid.to_string(),
                "name": new_name,
                "address": new_address,
                "owner_id": tenant_id.to_string()
            })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi cập nhật ngôi nhà: {}", e) })),
        )
            .into_response(),
    }
}

// DELETE /api/v1/houses/{id}
pub async fn delete_house(
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

    let Ok(house_uuid) = Uuid::parse_str(&id) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID ngôi nhà không hợp lệ" })),
        )
            .into_response();
    };

    // Gỡ liên kết phòng khỏi thiết bị trước khi xóa phòng & nhà để tránh lỗi khóa ngoại
    let _ = sqlx::query(
        "UPDATE devices SET room_id = NULL
         WHERE room_id IN (SELECT id FROM rooms WHERE house_id = $1)",
    )
    .bind(house_uuid)
    .execute(&state.db_pool)
    .await;

    let _ = sqlx::query("DELETE FROM rooms WHERE house_id = $1")
        .bind(house_uuid)
        .execute(&state.db_pool)
        .await;

    match sqlx::query("DELETE FROM houses WHERE id = $1 AND owner_id = $2")
        .bind(house_uuid)
        .bind(tenant_id)
        .execute(&state.db_pool)
        .await
    {
        Ok(res) if res.rows_affected() > 0 => StatusCode::NO_CONTENT.into_response(),
        Ok(_) => (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Không tìm thấy ngôi nhà thuộc quyền quản lý của bạn" })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi xóa ngôi nhà: {}", e) })),
        )
            .into_response(),
    }
}