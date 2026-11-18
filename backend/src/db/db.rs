use bb8::Pool;
use bb8_tiberius::ConnectionManager;
use std::time::Duration;
use tiberius::{AuthMethod, Config};

pub type SqlPool = Pool<ConnectionManager>;

pub async fn init_db_pool(database_url: &str) -> SqlPool {
    let config = build_mssql_config(database_url)
        .expect("Cấu hình kết nối Microsoft SQL Server không hợp lệ");

    let mgr = ConnectionManager::build(config)
        .expect("Không thể khởi tạo ConnectionManager cho SQL Server");

    Pool::builder()
        .max_size(50)
        .min_idle(Some(5))
        .connection_timeout(Duration::from_secs(5))
        .build(mgr)
        .await
        .expect("Lỗi kết nối CSDL Microsoft SQL Server")
}

fn build_mssql_config(database_url: &str) -> Result<Config, String> {
    let trimmed = database_url.trim();

    // 1. Hỗ trợ chuỗi kết nối chuẩn ADO.NET đọc từ biến môi trường DATABASE_URL
    if trimmed.to_ascii_lowercase().starts_with("server=")
        || trimmed.to_ascii_lowercase().starts_with("data source=")
    {
        return Config::from_ado_string(trimmed)
            .map_err(|e| format!("Chuỗi kết nối ADO.NET không hợp lệ: {}", e));
    }

    // 2. Hỗ trợ chuỗi JDBC đọc từ biến môi trường DATABASE_URL
    if trimmed.to_ascii_lowercase().starts_with("jdbc:sqlserver://") {
        return Config::from_jdbc_string(trimmed)
            .map_err(|e| format!("Chuỗi kết nối JDBC không hợp lệ: {}", e));
    }

    // 3. Đọc thông số từ URL (mssql://...) hoặc bắt buộc lấy từ biến môi trường (.env)
    let mut host = std::env::var("MSSQL_HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let mut port: u16 = std::env::var("MSSQL_PORT")
        .unwrap_or_else(|_| "1433".to_string())
        .parse()
        .unwrap_or(1433);
    let mut user = std::env::var("MSSQL_USER").ok();
    let mut pass = std::env::var("MSSQL_PASSWORD").ok();
    let mut db = std::env::var("MSSQL_DATABASE").unwrap_or_else(|_| "smarthome".to_string());

    if let Some(rest) = trimmed
        .strip_prefix("mssql://")
        .or_else(|| trimmed.strip_prefix("sqlserver://"))
    {
        let (auth_part, host_db_part) = match rest.rsplit_once('@') {
            Some((a, h)) => (Some(a), h),
            None => (None, rest),
        };

        if let Some(auth) = auth_part {
            if let Some((u, p)) = auth.split_once(':') {
                if !u.is_empty() {
                    user = Some(u.to_string());
                }
                if !p.is_empty() {
                    pass = Some(p.to_string());
                }
            }
        }

        let (host_port, db_part) = match host_db_part.split_once('/') {
            Some((hp, d)) => (hp, Some(d.split('?').next().unwrap_or(d))),
            None => (host_db_part, None),
        };

        if let Some(d) = db_part.filter(|s| !s.is_empty()) {
            db = d.to_string();
        }

        if let Some((h, p_str)) = host_port.split_once(':') {
            if !h.is_empty() {
                host = h.to_string();
            }
            if let Ok(parsed_port) = p_str.parse::<u16>() {
                port = parsed_port;
            }
        } else if !host_port.is_empty() {
            host = host_port.to_string();
        }
    }

    let db_user = user
        .filter(|u| !u.trim().is_empty())
        .ok_or_else(|| "Thiếu biến môi trường MSSQL_USER".to_string())?;

    let db_pass = pass
        .filter(|p| !p.trim().is_empty())
        .ok_or_else(|| "Thiếu biến môi trường MSSQL_PASSWORD".to_string())?;

    let mut config = Config::new();
    config.host(&host);
    config.port(port);
    config.authentication(AuthMethod::sql_server(&db_user, &db_pass));
    config.database(&db);
    config.trust_cert();

    Ok(config)
}