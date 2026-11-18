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
        SELECT
            r.id,
            r.house_id,
            h.name AS house_name,
            r.name,
            COALESCE(r.floor, 1) AS floor
        FROM dbo.rooms r
        INNER JOIN dbo.houses h ON r.house_id = h.id
        WHERE h.owner_id = @P1
        ORDER BY h.name ASC, r.floor ASC, r.name ASC
    "#;

    let mut query = Query::new(sql);
    query.bind(tenant_id);

    let response = match query.query(&mut conn).await {
        Ok(stream) => {
            let rows = stream.into_first_result().await.unwrap_or_default();
            let rooms: Vec<Value> = rows
                .into_iter()
                .filter_map(|row| {
                    let id = row.get::<Uuid, _>("id")?;
                    let house_id = row.get::<Uuid, _>("house_id")?;
                    let house_name = row.get::<&str, _>("house_name").unwrap_or("").to_string();
                    let name = row.get::<&str, _>("name").unwrap_or("").to_string();
                    let floor = row.get::<i32, _>("floor").unwrap_or(1);

                    Some(json!({
                        "id": id.to_string(),
                        "house_id": house_id.to_string(),
                        "house_name": house_name,
                        "name": name,
                        "floor": floor
                    }))
                })
                .collect();

            (StatusCode::OK, Json(json!(rooms))).into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi truy vấn danh sách phòng: {}", e) })),
        )
            .into_response(),
    };
    response
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

    // Xác minh ngôi nhà trực thuộc đúng hộ gia đình của user
    let mut house_q = Query::new(
        "SELECT TOP 1 name FROM dbo.houses WHERE id = @P1 AND owner_id = @P2",
    );
    house_q.bind(house_uuid);
    house_q.bind(tenant_id);

    let house_name: String = match house_q.query(&mut conn).await {
        Ok(stream) => match stream.into_row().await {
            Ok(Some(r)) => r.get::<&str, _>("name").unwrap_or("").to_string(),
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
        },
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

    let mut insert_q = Query::new(
        "INSERT INTO dbo.rooms (id, house_id, name, floor) VALUES (@P1, @P2, @P3, @P4)",
    );
    insert_q.bind(room_id);
    insert_q.bind(house_uuid);
    insert_q.bind(&name);
    insert_q.bind(floor);

    match insert_q.execute(&mut conn).await {
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

    let Ok(room_uuid) = Uuid::parse_str(id.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID phòng không hợp lệ" })),
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
        r#"
        SELECT TOP 1 r.house_id, r.name, COALESCE(r.floor, 1) AS floor
        FROM dbo.rooms r
        INNER JOIN dbo.houses h ON r.house_id = h.id
        WHERE r.id = @P1 AND h.owner_id = @P2
        "#,
    );
    cur_q.bind(room_uuid);
    cur_q.bind(tenant_id);

    let row = match cur_q.query(&mut conn).await {
        Ok(stream) => match stream.into_row().await {
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
        },
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let Some(old_house_id) = row.get::<Uuid, _>("house_id") else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": "Dữ liệu house_id của phòng không hợp lệ" })),
        )
            .into_response();
    };
    let old_name = row.get::<&str, _>("name").unwrap_or("").to_string();
    let old_floor = row.get::<i32, _>("floor").unwrap_or(1);

    let target_house_id = if let Some(hid_str) = payload.house_id.filter(|s| !s.trim().is_empty()) {
        let Ok(parsed_hid) = Uuid::parse_str(hid_str.trim()) else {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "error": "ID ngôi nhà đích không hợp lệ" })),
            )
                .into_response();
        };

        let mut valid_q = Query::new(
            "SELECT TOP 1 id FROM dbo.houses WHERE id = @P1 AND owner_id = @P2",
        );
        valid_q.bind(parsed_hid);
        valid_q.bind(tenant_id);

        let is_valid = match valid_q.query(&mut conn).await {
            Ok(stream) => stream.into_row().await.ok().flatten().is_some(),
            Err(_) => false,
        };

        if !is_valid {
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

    let mut upd_q = Query::new(
        "UPDATE dbo.rooms SET house_id = @P1, name = @P2, floor = @P3 WHERE id = @P4",
    );
    upd_q.bind(target_house_id);
    upd_q.bind(&new_name);
    upd_q.bind(new_floor);
    upd_q.bind(room_uuid);

    match upd_q.execute(&mut conn).await {
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

    let Ok(room_uuid) = Uuid::parse_str(id.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ID phòng không hợp lệ" })),
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

    // Kiểm tra quyền sở hữu phòng thông qua ngôi nhà cha
    let mut check_q = Query::new(
        r#"
        SELECT TOP 1 r.id
        FROM dbo.rooms r
        INNER JOIN dbo.houses h ON r.house_id = h.id
        WHERE r.id = @P1 AND h.owner_id = @P2
        "#,
    );
    check_q.bind(room_uuid);
    check_q.bind(tenant_id);

    let owned = match check_q.query(&mut conn).await {
        Ok(stream) => stream.into_row().await.ok().flatten().is_some(),
        Err(_) => false,
    };

    if !owned {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Không tìm thấy phòng thuộc quyền quản lý của bạn" })),
        )
            .into_response();
    }

    // Chuyển các thiết bị trong phòng về "Chưa phân phòng" trước khi xóa phòng
    let mut unlink_q = Query::new("UPDATE dbo.devices SET room_id = NULL WHERE room_id = @P1");
    unlink_q.bind(room_uuid);
    let _ = unlink_q.execute(&mut conn).await;

    let mut del_q = Query::new("DELETE FROM dbo.rooms WHERE id = @P1");
    del_q.bind(room_uuid);

    match del_q.execute(&mut conn).await {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Lỗi xóa phòng: {}", e) })),
        )
            .into_response(),
    }
}