use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use tiberius::Query;
use uuid::Uuid;

use crate::models::user::Claims;
use crate::services::auth_service::{create_jwt, hash_password, verify_password};
use crate::{AppState, SqlPool};

#[derive(Deserialize)]
pub struct RegisterPayload {
    pub name: Option<String>,
    pub full_name: Option<String>,
    pub email: String,
    pub password: String,
}

#[derive(Deserialize)]
pub struct LoginPayload {
    pub email: String,
    pub password: String,
}

#[derive(Deserialize)]
pub struct ForgotPasswordPayload {
    pub email: String,
}

#[derive(Deserialize)]
pub struct ResetPasswordPayload {
    pub email: String,
    pub otp: String,
    pub new_password: String,
}

async fn ensure_auth_schema(pool: &SqlPool) {
    let Ok(mut conn) = pool.get().await else {
        return;
    };

    let migrations = [
        "IF COL_LENGTH(N'dbo.users', N'owner_id') IS NULL ALTER TABLE dbo.users ADD owner_id UNIQUEIDENTIFIER NULL",
        "IF COL_LENGTH(N'dbo.users', N'role') IS NULL ALTER TABLE dbo.users ADD role NVARCHAR(50) NOT NULL DEFAULT N'Owner'",
        "IF COL_LENGTH(N'dbo.users', N'name') IS NULL ALTER TABLE dbo.users ADD name NVARCHAR(150) NULL",
        "IF COL_LENGTH(N'dbo.users', N'full_name') IS NULL ALTER TABLE dbo.users ADD full_name NVARCHAR(150) NULL",
        "IF COL_LENGTH(N'dbo.users', N'is_active') IS NULL ALTER TABLE dbo.users ADD is_active BIT NOT NULL DEFAULT 1",
        "INSERT INTO dbo.roles (id, name) SELECT NEWID(), N'Owner' WHERE NOT EXISTS (SELECT 1 FROM dbo.roles WHERE LOWER(name) = N'owner')",
        "INSERT INTO dbo.roles (id, name) SELECT NEWID(), N'Admin' WHERE NOT EXISTS (SELECT 1 FROM dbo.roles WHERE LOWER(name) = N'admin')",
        "INSERT INTO dbo.roles (id, name) SELECT NEWID(), N'Member' WHERE NOT EXISTS (SELECT 1 FROM dbo.roles WHERE LOWER(name) = N'member')",
        "INSERT INTO dbo.roles (id, name) SELECT NEWID(), N'Guest' WHERE NOT EXISTS (SELECT 1 FROM dbo.roles WHERE LOWER(name) = N'guest')",
        r#"
        IF OBJECT_ID(N'dbo.password_resets', N'U') IS NULL
        CREATE TABLE dbo.password_resets (
            id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
            user_id UNIQUEIDENTIFIER NOT NULL,
            email NVARCHAR(255) NOT NULL,
            otp_hash NVARCHAR(255) NOT NULL,
            attempts INT NOT NULL DEFAULT 0,
            expires_at DATETIMEOFFSET NOT NULL,
            used_at DATETIMEOFFSET NULL,
            created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
            CONSTRAINT FK_password_resets_users FOREIGN KEY (user_id) REFERENCES dbo.users(id) ON DELETE CASCADE
        )
        "#,
    ];

    for sql in migrations {
        let _ = conn.execute(sql, &[]).await;
    }
}

// POST /api/v1/auth/register
pub async fn register(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<RegisterPayload>,
) -> impl IntoResponse {
    ensure_auth_schema(&state.db_pool).await;

    let email = payload.email.trim().to_lowercase();
    if email.is_empty() || payload.password.trim().is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Email và mật khẩu không được để trống" })),
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

    let email_exists = {
        let mut check_q =
            Query::new("SELECT TOP 1 id FROM dbo.users WHERE LOWER(email) = LOWER(@P1)");
        check_q.bind(&email);

        match check_q.query(&mut conn).await {
            Ok(stream) => stream.into_row().await.ok().flatten().is_some(),
            Err(_) => false,
        }
    };

    if email_exists {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Email này đã được đăng ký" })),
        )
            .into_response();
    }

    let role_row = match conn
        .query(
            "SELECT TOP 1 id, name FROM dbo.roles WHERE LOWER(name) = N'owner'",
            &[],
        )
        .await
    {
        Ok(stream) => stream.into_row().await,
        Err(e) => Err(e),
    };

    let (role_id, canonical_role): (Option<Uuid>, String) = match role_row {
        Ok(Some(r)) => (
            r.get::<Uuid, _>("id"),
            r.get::<&str, _>("name").unwrap_or("Owner").to_string(),
        ),
        Ok(None) => (None, "Owner".to_string()),
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let display_name = payload
        .full_name
        .or(payload.name)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| email.split('@').next().unwrap_or("Owner").to_string());

    let hashed_password = match hash_password(payload.password.trim()) {
        Ok(h) => h,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi mã hóa mật khẩu: {}", e) })),
            )
                .into_response();
        }
    };

    let user_id = Uuid::new_v4();

    let insert_user_res = {
        let mut insert_user_q = Query::new(
            r#"
            INSERT INTO dbo.users (id, name, full_name, email, password_hash, role, role_id, owner_id, is_active, created_at)
            VALUES (@P1, @P2, @P3, @P4, @P5, @P6, @P7, NULL, 1, SYSDATETIMEOFFSET())
            "#,
        );
        insert_user_q.bind(user_id);
        insert_user_q.bind(&display_name);
        insert_user_q.bind(&display_name);
        insert_user_q.bind(&email);
        insert_user_q.bind(&hashed_password);
        insert_user_q.bind(&canonical_role);
        insert_user_q.bind(role_id);

        insert_user_q.execute(&mut conn).await
    };

    if let Err(e) = insert_user_res {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Không thể đăng ký tài khoản: {}", e) })),
        )
            .into_response();
    }

    let session_id = Uuid::new_v4();
    let session_id_str = session_id.to_string();

    {
        let mut insert_sess_q = Query::new(
            r#"
            INSERT INTO dbo.user_sessions (id, user_id, token_hash, expires_at, created_at)
            VALUES (@P1, @P2, @P3, DATEADD(DAY, 7, SYSDATETIMEOFFSET()), SYSDATETIMEOFFSET())
            "#,
        );
        insert_sess_q.bind(session_id);
        insert_sess_q.bind(user_id);
        insert_sess_q.bind(&session_id_str);
        let _ = insert_sess_q.execute(&mut conn).await;
    }

    let token = match create_jwt(user_id, session_id, &email, &canonical_role) {
        Ok(t) => t,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi tạo phiên đăng nhập: {}", e) })),
            )
                .into_response();
        }
    };

    (
        StatusCode::CREATED,
        Json(json!({
            "token": token,
            "user": {
                "id": user_id.to_string(),
                "name": display_name,
                "full_name": display_name,
                "email": email,
                "role": canonical_role,
                "owner_id": serde_json::Value::Null
            }
        })),
    )
        .into_response()
}

// POST /api/v1/auth/login
pub async fn login(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<LoginPayload>,
) -> impl IntoResponse {
    ensure_auth_schema(&state.db_pool).await;

    let email = payload.email.trim();
    if email.is_empty() || payload.password.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Vui lòng nhập đầy đủ email và mật khẩu" })),
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

    let sql = r#"
        SELECT TOP 1
            u.id,
            COALESCE(
                NULLIF(TRIM(u.full_name), N''),
                NULLIF(TRIM(u.name), N''),
                LEFT(u.email, CHARINDEX(N'@', u.email + N'@') - 1)
            ) AS display_name,
            u.email,
            u.password_hash,
            u.owner_id,
            COALESCE(NULLIF(TRIM(r.name), N''), NULLIF(TRIM(u.role), N''), N'Member') AS role_name,
            COALESCE(u.is_active, CAST(1 AS BIT)) AS is_active
        FROM dbo.users u
        LEFT JOIN dbo.roles r ON u.role_id = r.id
        WHERE LOWER(u.email) = LOWER(@P1)
    "#;

    let user_row = {
        let mut query = Query::new(sql);
        query.bind(email);

        match query.query(&mut conn).await {
            Ok(stream) => stream.into_row().await,
            Err(e) => Err(e),
        }
    };

    let row = match user_row {
        Ok(Some(r)) => r,
        Ok(None) => {
            return (
                StatusCode::UNAUTHORIZED,
                Json(json!({ "error": "Email hoặc mật khẩu không chính xác" })),
            )
                .into_response();
        }
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi truy vấn đăng nhập: {}", e) })),
            )
                .into_response();
        }
    };

    let is_active = row.get::<bool, _>("is_active").unwrap_or(true);
    if !is_active {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({ "error": "Tài khoản này đã bị vô hiệu hóa" })),
        )
            .into_response();
    }

    let password_hash = row.get::<&str, _>("password_hash").unwrap_or("");
    if !verify_password(&payload.password, password_hash) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "Email hoặc mật khẩu không chính xác" })),
        )
            .into_response();
    }

    let Some(user_id) = row.get::<Uuid, _>("id") else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": "Dữ liệu ID người dùng không hợp lệ" })),
        )
            .into_response();
    };
    let display_name = row.get::<&str, _>("display_name").unwrap_or("").to_string();
    let user_email = row.get::<&str, _>("email").unwrap_or("").to_string();
    let owner_id: Option<Uuid> = row.get::<Uuid, _>("owner_id");
    let role_name = row.get::<&str, _>("role_name").unwrap_or("Member").to_string();

    let session_id = Uuid::new_v4();
    let session_id_str = session_id.to_string();

    {
        let mut insert_sess_q = Query::new(
            r#"
            INSERT INTO dbo.user_sessions (id, user_id, token_hash, expires_at, created_at)
            VALUES (@P1, @P2, @P3, DATEADD(DAY, 7, SYSDATETIMEOFFSET()), SYSDATETIMEOFFSET())
            "#,
        );
        insert_sess_q.bind(session_id);
        insert_sess_q.bind(user_id);
        insert_sess_q.bind(&session_id_str);
        let _ = insert_sess_q.execute(&mut conn).await;
    }

    let token = match create_jwt(user_id, session_id, &user_email, &role_name) {
        Ok(t) => t,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi tạo token: {}", e) })),
            )
                .into_response();
        }
    };

    (
        StatusCode::OK,
        Json(json!({
            "token": token,
            "user": {
                "id": user_id.to_string(),
                "name": display_name,
                "full_name": display_name,
                "email": user_email,
                "role": role_name,
                "owner_id": owner_id.map(|u| u.to_string())
            }
        })),
    )
        .into_response()
}

// GET /api/v1/auth/me
pub async fn me(
    claims: Claims,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
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
        SELECT TOP 1
            u.id,
            COALESCE(
                NULLIF(TRIM(u.full_name), N''),
                NULLIF(TRIM(u.name), N''),
                LEFT(u.email, CHARINDEX(N'@', u.email + N'@') - 1)
            ) AS display_name,
            u.email,
            u.owner_id,
            COALESCE(NULLIF(TRIM(r.name), N''), NULLIF(TRIM(u.role), N''), N'Member') AS role_name
        FROM dbo.users u
        LEFT JOIN dbo.roles r ON u.role_id = r.id
        WHERE u.id = @P1
    "#;

    let row_res = {
        let mut query = Query::new(sql);
        query.bind(claims.sub);

        match query.query(&mut conn).await {
            Ok(stream) => stream.into_row().await,
            Err(e) => Err(e),
        }
    };

    match row_res {
        Ok(Some(row)) => {
            let id = row.get::<Uuid, _>("id").unwrap_or(claims.sub);
            let display_name = row.get::<&str, _>("display_name").unwrap_or("").to_string();
            let email = row.get::<&str, _>("email").unwrap_or("").to_string();
            let owner_id: Option<Uuid> = row.get::<Uuid, _>("owner_id");
            let role_name = row.get::<&str, _>("role_name").unwrap_or("Member").to_string();

            (
                StatusCode::OK,
                Json(json!({
                    "id": id.to_string(),
                    "name": display_name,
                    "full_name": display_name,
                    "email": email,
                    "role": role_name,
                    "owner_id": owner_id.map(|u| u.to_string())
                })),
            )
                .into_response()
        }
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Không tìm thấy người dùng" })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}

// POST /api/v1/auth/forgot-password
pub async fn forgot_password(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ForgotPasswordPayload>,
) -> impl IntoResponse {
    ensure_auth_schema(&state.db_pool).await;

    let email = payload.email.trim().to_lowercase();
    if email.is_empty() || !email.contains('@') {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Vui lòng nhập địa chỉ email hợp lệ" })),
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

    let user_row = {
        let mut q = Query::new(
            "SELECT TOP 1 id, COALESCE(is_active, CAST(1 AS BIT)) AS is_active FROM dbo.users WHERE LOWER(email) = LOWER(@P1)",
        );
        q.bind(&email);
        match q.query(&mut conn).await {
            Ok(stream) => stream.into_row().await,
            Err(e) => Err(e),
        }
    };

    let (user_id, is_active) = match user_row {
        Ok(Some(row)) => (
            row.get::<Uuid, _>("id"),
            row.get::<bool, _>("is_active").unwrap_or(true),
        ),
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({ "error": "Không tìm thấy tài khoản nào gắn với email này" })),
            )
                .into_response();
        }
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi truy vấn người dùng: {}", e) })),
            )
                .into_response();
        }
    };

    let Some(user_id) = user_id else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": "ID người dùng không hợp lệ" })),
        )
            .into_response();
    };

    if !is_active {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({ "error": "Tài khoản này đang bị vô hiệu hóa, không thể đặt lại mật khẩu" })),
        )
            .into_response();
    }

    let otp_num = (Uuid::new_v4().as_u128() % 900_000 + 100_000) as u32;
    let otp_code = format!("{:06}", otp_num);

    let otp_hash = match hash_password(&otp_code) {
        Ok(h) => h,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi tạo mã xác thực: {}", e) })),
            )
                .into_response();
        }
    };

    {
        let mut invalidate_q = Query::new(
            "UPDATE dbo.password_resets SET used_at = SYSDATETIMEOFFSET() WHERE user_id = @P1 AND used_at IS NULL",
        );
        invalidate_q.bind(user_id);
        let _ = invalidate_q.execute(&mut conn).await;
    }

    let reset_id = Uuid::new_v4();
    let insert_res = {
        let mut insert_q = Query::new(
            r#"
            INSERT INTO dbo.password_resets (id, user_id, email, otp_hash, attempts, expires_at, created_at)
            VALUES (@P1, @P2, @P3, @P4, 0, DATEADD(MINUTE, 15, SYSDATETIMEOFFSET()), SYSDATETIMEOFFSET())
            "#,
        );
        insert_q.bind(reset_id);
        insert_q.bind(user_id);
        insert_q.bind(&email);
        insert_q.bind(&otp_hash);
        insert_q.execute(&mut conn).await
    };

    if let Err(e) = insert_res {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Không thể tạo yêu cầu đặt lại mật khẩu: {}", e) })),
        )
            .into_response();
    }

    println!(
        "🔑 [FORGOT PASSWORD] Mã OTP khôi phục cho {} là: {} (hết hạn sau 15 phút)",
        email, otp_code
    );

    let is_prod = std::env::var("APP_ENV")
        .unwrap_or_default()
        .eq_ignore_ascii_case("production");

    let mut body = json!({
        "message": "Mã OTP xác nhận gồm 6 chữ số đã được tạo (hiệu lực 15 phút).",
        "expires_in_minutes": 15
    });

    if !is_prod {
        body["dev_otp"] = json!(otp_code);
    }

    (StatusCode::OK, Json(body)).into_response()
}

// POST /api/v1/auth/reset-password
pub async fn reset_password(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ResetPasswordPayload>,
) -> impl IntoResponse {
    ensure_auth_schema(&state.db_pool).await;

    let email = payload.email.trim().to_lowercase();
    let otp = payload.otp.trim();
    let new_password = payload.new_password.trim();

    if email.is_empty() || otp.is_empty() || new_password.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Vui lòng nhập đầy đủ Email, mã OTP và mật khẩu mới" })),
        )
            .into_response();
    }

    if new_password.len() < 6 {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Mật khẩu mới phải có ít nhất 6 ký tự" })),
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

    let reset_row = {
        let mut q = Query::new(
            r#"
            SELECT TOP 1 id, user_id, otp_hash, attempts
            FROM dbo.password_resets
            WHERE LOWER(email) = LOWER(@P1)
              AND used_at IS NULL
              AND expires_at > SYSDATETIMEOFFSET()
            ORDER BY created_at DESC
            "#,
        );
        q.bind(&email);
        match q.query(&mut conn).await {
            Ok(stream) => stream.into_row().await,
            Err(e) => Err(e),
        }
    };

    let row = match reset_row {
        Ok(Some(r)) => r,
        Ok(None) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "error": "Mã OTP không tồn tại hoặc đã hết hạn. Vui lòng yêu cầu mã mới." })),
            )
                .into_response();
        }
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi kiểm tra mã OTP: {}", e) })),
            )
                .into_response();
        }
    };

    let Some(reset_id) = row.get::<Uuid, _>("id") else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": "Dữ liệu phiên khôi phục không hợp lệ" })),
        )
            .into_response();
    };
    let Some(user_id) = row.get::<Uuid, _>("user_id") else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": "Dữ liệu người dùng không hợp lệ" })),
        )
            .into_response();
    };
    let otp_hash = row.get::<&str, _>("otp_hash").unwrap_or("");
    let attempts = row.get::<i32, _>("attempts").unwrap_or(0);

    if attempts >= 5 {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Json(json!({ "error": "Bạn đã nhập sai OTP quá 5 lần. Vui lòng yêu cầu mã OTP mới." })),
        )
            .into_response();
    }

    if !verify_password(otp, otp_hash) {
        let mut inc_q = Query::new(
            "UPDATE dbo.password_resets SET attempts = attempts + 1 WHERE id = @P1",
        );
        inc_q.bind(reset_id);
        let _ = inc_q.execute(&mut conn).await;

        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Mã OTP không chính xác" })),
        )
            .into_response();
    }

    let hashed_new_password = match hash_password(new_password) {
        Ok(h) => h,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("Lỗi mã hóa mật khẩu mới: {}", e) })),
            )
                .into_response();
        }
    };

    let update_user_res = {
        let mut update_q = Query::new(
            "UPDATE dbo.users SET password_hash = @P1 WHERE id = @P2",
        );
        update_q.bind(&hashed_new_password);
        update_q.bind(user_id);
        update_q.execute(&mut conn).await
    };

    if let Err(e) = update_user_res {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": format!("Không thể cập nhật mật khẩu: {}", e) })),
        )
            .into_response();
    }

    {
        let mut used_q = Query::new(
            "UPDATE dbo.password_resets SET used_at = SYSDATETIMEOFFSET() WHERE id = @P1",
        );
        used_q.bind(reset_id);
        let _ = used_q.execute(&mut conn).await;
    }

    {
        let mut revoke_sess_q = Query::new(
            "DELETE FROM dbo.user_sessions WHERE user_id = @P1",
        );
        revoke_sess_q.bind(user_id);
        let _ = revoke_sess_q.execute(&mut conn).await;
    }

    (
        StatusCode::OK,
        Json(json!({
            "message": "Đặt lại mật khẩu thành công! Bạn có thể đăng nhập bằng mật khẩu mới."
        })),
    )
        .into_response()
}