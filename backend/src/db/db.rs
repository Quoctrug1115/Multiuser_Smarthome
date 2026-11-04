use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;

pub async fn init_db_pool(database_url: &str) -> PgPool {
    PgPoolOptions::new()
        .max_connections(50) // Giới hạn tối đa 50 kết nối đồng thời
        .min_connections(5)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(database_url)
        .await
        .expect("Lỗi kết nối CSDL PostgreSQL/TimescaleDB")
}