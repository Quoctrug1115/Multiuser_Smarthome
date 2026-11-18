use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;
use tiberius::Query;
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

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    let sql = r#"
        SELECT id, name, COALESCE(address, N'') AS address, owner_id
        FROM dbo.houses
        WHERE owner_id = @P1
        ORDER BY name ASC
    "#;

    let mut query = Query::new(sql);
    query.bind(tenant_id);

    let response = match query.query(&mut conn).await {
        Ok(stream) => {
            let rows = stream.into_first_result().await.unwrap_or_default();
            let houses: Vec<Value> = rows
                .into_iter()
                .filter_map(|row| {
                    let id = row.get::<Uuid, _>("id")?;
                    let name = row.get::<&str, _>("name").unwrap_or("").to_string();
                    let address = row.get::<&str, _>("address").unwrap_or("").to_string();
                    let owner_id: Option<Uuid> = row.get::<Uuid, _>("owner_id");

                    Some(json!({
                        "id": id.to_string(),
                        "name": name,
                        "address": address,
                        "owner_id": owner_id.map(|u| u.to_string())
                    }))
                })
                .collect();

            (StatusCode::OK, Json(json!(houses))).into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi truy vấn danh sách nhà: {}", e) })),
        )
            .into_response(),
    };
    response
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

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    let address = payload.address.unwrap_or_default().trim().to_string();
    let house_id = Uuid::new_v4();

    let mut insert_q = Query::new(
        "INSERT INTO dbo.houses (id, name, address, owner_id) VALUES (@P1, @P2, @P3, @P4)",
    );
    insert_q.bind(house_id);
    insert_q.bind(&name);
    insert_q.bind(&address);
    insert_q.bind(tenant_id);

    match insert_q.execute(&mut conn).await {
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

    let Ok(house_uuid) = Uuid::parse_str(id.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID ngôi nhà không hợp lệ" })),
        )
            .into_response();
    };

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    let mut cur_q = Query::new(
        "SELECT TOP 1 name, COALESCE(address, N'') AS address FROM dbo.houses WHERE id = @P1 AND owner_id = @P2",
    );
    cur_q.bind(house_uuid);
    cur_q.bind(tenant_id);

    let row = match cur_q.query(&mut conn).await {
        Ok(stream) => match stream.into_row().await {
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
        },
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let old_name = row.get::<&str, _>("name").unwrap_or("").to_string();
    let old_address = row.get::<&str, _>("address").unwrap_or("").to_string();

    let new_name = payload
        .name
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or(old_name);
    let new_address = payload
        .address
        .map(|s| s.trim().to_string())
        .unwrap_or(old_address);

    let mut upd_q = Query::new(
        "UPDATE dbo.houses SET name = @P1, address = @P2 WHERE id = @P3 AND owner_id = @P4",
    );
    upd_q.bind(&new_name);
    upd_q.bind(&new_address);
    upd_q.bind(house_uuid);
    upd_q.bind(tenant_id);

    match upd_q.execute(&mut conn).await {
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

    let Ok(house_uuid) = Uuid::parse_str(id.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID ngôi nhà không hợp lệ" })),
        )
            .into_response();
    };

    let mut conn = match state.db_pool.get().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kết nối SQL Server: {}", e) })),
            )
                .into_response();
        }
    };

    // Xác minh ngôi nhà thuộc đúng Chủ nhà hiện tại trước khi gỡ phòng/thiết bị
    let mut check_q = Query::new(
        "SELECT TOP 1 id FROM dbo.houses WHERE id = @P1 AND owner_id = @P2",
    );
    check_q.bind(house_uuid);
    check_q.bind(tenant_id);

    let owned = match check_q.query(&mut conn).await {
        Ok(stream) => stream.into_row().await.ok().flatten().is_some(),
        Err(_) => false,
    };

    if !owned {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Không tìm thấy ngôi nhà thuộc quyền quản lý của bạn" })),
        )
            .into_response();
    }

    // Gỡ liên kết phòng khỏi thiết bị trước khi xóa phòng & nhà để tránh lỗi khóa ngoại
    let mut unlink_q = Query::new(
        "UPDATE dbo.devices SET room_id = NULL WHERE room_id IN (SELECT id FROM dbo.rooms WHERE house_id = @P1)",
    );
    unlink_q.bind(house_uuid);
    let _ = unlink_q.execute(&mut conn).await;

    let mut del_rooms_q = Query::new("DELETE FROM dbo.rooms WHERE house_id = @P1");
    del_rooms_q.bind(house_uuid);
    let _ = del_rooms_q.execute(&mut conn).await;

    let mut del_house_q = Query::new("DELETE FROM dbo.houses WHERE id = @P1 AND owner_id = @P2");
    del_house_q.bind(house_uuid);
    del_house_q.bind(tenant_id);

    match del_house_q.execute(&mut conn).await {
        Ok(res) if res.rows_affected().iter().sum::<u64>() > 0 => StatusCode::NO_CONTENT.into_response(),
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