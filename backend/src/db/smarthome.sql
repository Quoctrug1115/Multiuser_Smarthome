-- Active: 1794751769341@@127.0.0.1@5434@smarthome
create extension if not EXISTS "uuid-ossp";
create extension if not EXISTS timescaledb CASCADE;

create table if not exists roles (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(50) UNIQUE not null,
    description TEXT
);

insert into roles (name,description) VALUES
('Owner', 'Chủ nhà - Toàn quyền quản trị hệ thống'),
('Member', 'Thành viên gia đình - Điều khiển và giám sát'),
('Guest', 'Khách - Quyền hạn chế theo thời gian')
on conflict (name) do nothing;

create table if not exists users (
    id uuid primary key default uuid_generate_v4(),
    email varchar(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) not null,
    full_name VARCHAR(100) not null,
    role_id uuid not null REFERENCES roles(id),
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP with time zone DEFAULT current_timestamp
);

create table if not exists user_sessions (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id uuid not null REFERENCES users(id) on delete CASCADE,
    token_hash VARCHAR(255) not NULL,
    device_info VARCHAR(255),
    ip_address VARCHAR(45),
    expires_at TIMESTAMP with time zone not null,
    created_at TIMESTAMP with time zone not null DEFAULT current_timestamp
);

create table if not exists houses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL,
    address TEXT,
    owner_id uuid not null REFERENCES users(id),
    created_at TIMESTAMP with time zone DEFAULT current_timestamp
);

create table if not exists rooms (
    id uuid PRIMARY key DEFAULT uuid_generate_v4(),
    house_id uuid not NULL REFERENCES houses(id) on delete CASCADE,
    name varchar(100) not null,
    floor int DEFAULT 1
);

create table if not exists devices (
    id uuid PRIMARY key DEFAULT uuid_generate_v4(),
    room_id uuid REFERENCES rooms(id) on delete set null,
    name varchar(100) not null,
    device_type varchar(50) not null, -- relay, dht22, pir, magnetic
    mqtt_topic varchar(150) UNIQUE not NULL,
    status VARCHAR(20) DEFAULT 'OFFLINE',
    current_state JSONB DEFAULT '{}'::jsonb,
    last_seen TIMESTAMP with time zone
);

create table if not exists guest_access(
    if UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    guest_id UUID not NULL REFERENCES users(id) on delete CASCADE,
    device_id uuid not null REFERENCES devices(id) on delete CASCADE,
    valid_from TIMESTAMP with time zone not null,
    valid_until TIMESTAMP with time zone not null,
    is_revoked BOOLEAN DEFAULT false
);

create table if not exists device_logs (
    id uuid PRIMARY key DEFAULT uuid_generate_v4(),
    device_id uuid not NULL REFERENCES devices(id) on delete CASCADE,
    event_type VARCHAR(50) not null,
    data JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP with time zone DEFAULT current_timestamp
);

create table if not exists sensor_data (
    time TIMESTAMP with time zone not null,
    device_id uuid not NULL,
    sensor_type VARCHAR(50) not null,
    value DOUBLE precision not NULL
);


-- 1. Bảng lưu vết cảnh báo bất thường
CREATE TABLE IF NOT EXISTS ai_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID REFERENCES devices(id) ON DELETE CASCADE,
    alert_type VARCHAR(50) NOT NULL, -- 'TEMPERATURE_SPIKE', 'UNUSUAL_MOTION', 'DOOR_LEFT_OPEN'
    severity VARCHAR(20) NOT NULL,   -- 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL'
    message TEXT NOT NULL,
    metadata JSONB,                  -- Lưu thông số lúc xảy ra lỗi (VD: {"temp": 65.0, "z_score": 3.8})
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Bảng lưu gợi ý kịch bản thói quen
CREATE TABLE IF NOT EXISTS ai_suggestions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    device_id UUID REFERENCES devices(id) ON DELETE CASCADE,
    suggested_action JSONB NOT NULL, -- VD: {"power": "ON"}
    cron_expression VARCHAR(50),     -- VD: "0 22 * * *" (22:00 mỗi ngày)
    confidence_score FLOAT NOT NULL, -- VD: 0.85 (85%)
    is_applied BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);


-- 1. Bảng lưu trữ kịch bản tự động hóa (Automation Rules)
CREATE TABLE IF NOT EXISTS automations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    house_id UUID REFERENCES houses(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    trigger_device_id UUID REFERENCES devices(id) ON DELETE CASCADE,
    condition_type VARCHAR(20) NOT NULL, -- 'GREATER_THAN', 'LESS_THAN', 'EQUALS'
    trigger_value FLOAT NOT NULL,
    action_device_id UUID REFERENCES devices(id) ON DELETE CASCADE,
    action_payload JSONB NOT NULL,       -- VD: {"power": "ON"}
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Bảng ghi nhận công suất tiêu thụ theo thời gian (TimescaleDB / Hypertable)
CREATE TABLE IF NOT EXISTS energy_logs (
    time TIMESTAMPTZ NOT NULL,
    device_id UUID REFERENCES devices(id) ON DELETE CASCADE,
    power_watt FLOAT NOT NULL, -- Công suất thời điểm (W)
    kwh_consumed FLOAT NOT NULL -- Điện năng tiêu thụ tích lũy (kWh)
);

-- Chuyển đổi energy_logs thành Hypertable nếu dùng TimescaleDB
SELECT create_hypertable('energy_logs', 'time', if_not_exists => TRUE);

-- 3. Bảng quản lý cấp quyền tạm thời cho Khách (Guest Access)
CREATE TABLE IF NOT EXISTS guest_access (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    guest_id UUID REFERENCES users(id) ON DELETE CASCADE,
    device_id UUID REFERENCES devices(id) ON DELETE CASCADE,
    valid_from TIMESTAMPTZ NOT NULL,
    valid_until TIMESTAMPTZ NOT NULL,
    is_revoked BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Bước 0: Bổ sung cột 'name' và 'role' vào bảng users nếu chưa có
ALTER TABLE users ADD COLUMN IF NOT EXISTS name VARCHAR(100);
ALTER TABLE users ADD COLUMN IF NOT EXISTS role VARCHAR(50) DEFAULT 'Member';


-- Bước 1: Khởi tạo danh sách Quyền (Roles)
INSERT INTO roles (name, description) VALUES
  ('Owner', 'Chủ nhà - Toàn quyền quản trị hệ thống'),
  ('Member', 'Thành viên gia đình - Điều khiển và giám sát'),
  ('Guest', 'Khách - Quyền hạn chế theo thời gian')
ON CONFLICT (name) DO NOTHING;

-- Bước 2: Tạo Tài khoản Chủ nhà (Lấy role_id tự động từ bảng roles, khớp với full_name & password_hash)
INSERT INTO users (id, email, password_hash, full_name, role_id)
SELECT 
  '11111111-1111-1111-1111-111111111111', 
  'trung.owner@smarthome.vn', 
  '$2b$12$e86.M4O1aD.Y/mockpasswordhashvaluefortesting', 
  'Lê Quốc Trung', 
  id 
FROM roles WHERE name = 'Owner'
ON CONFLICT (id) DO NOTHING;

-- Bước 3: Tạo Nhà (Liên kết owner_id -> users)
INSERT INTO houses (id, name, address, owner_id)
VALUES (
  'a1b2c3d4-0000-0000-0000-000000000000', 
  'Nhà thông minh', 
  'TP.HCM', 
  '11111111-1111-1111-1111-111111111111'
)
ON CONFLICT (id) DO NOTHING;

-- Bước 4: Tạo Các Phòng (Liên kết house_id -> houses)
INSERT INTO rooms (id, house_id, name, floor)
VALUES 
  ('22222222-2222-2222-2222-222222222222', 'a1b2c3d4-0000-0000-0000-000000000000', 'Phòng khách', 1),
  ('33333333-3333-3333-3333-333333333333', 'a1b2c3d4-0000-0000-0000-000000000000', 'Nhà bếp', 1)
ON CONFLICT (id) DO NOTHING;

-- Bước 5: Tạo Thiết bị mẫu (Liên kết room_id -> rooms)
INSERT INTO devices (id, room_id, name, device_type, mqtt_topic, status, current_state)
VALUES 
  (
    'd1111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222', 
    'Đèn phòng khách', 
    'relay', 
    'smarthome/livingroom/light', 
    'ONLINE', 
    '{"power": "ON"}'::jsonb
  ),
  (
    'd2222222-2222-2222-2222-222222222222',
    '33333333-3333-3333-3333-333333333333', 
    'Cảm biến DHT22', 
    'dht22', 
    'smarthome/kitchen/dht22', 
    'ONLINE', 
    '{"temperature": 28.5, "humidity": 62}'::jsonb
  )
ON CONFLICT (mqtt_topic) DO NOTHING;


-- 1. Thêm thiết bị mặc định vào bảng devices
INSERT INTO devices (id, name, device_type, mqtt_topic) 
VALUES (
    '00000000-0000-0000-0000-000000000001', 
    'ESP32 Sensor Hub', 
    'dht22', 
    'smarthome/sensors/dht22'
)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE guest_access RENAME COLUMN "if" TO id;

SELECT 
    time AT TIME ZONE 'Asia/Ho_Chi_Minh' AS time_vn,
    device_id,
    power_watt,
    kwh_consumed
FROM energy_logs
ORDER BY time DESC
LIMIT 20;


select * from users

SELECT * FROM roles;

UPDATE users
SET role = (SELECT id FROM roles WHERE name = 'Owner')
WHERE email = 'letrung@gmail.com';
ALTER TABLE devices
ADD COLUMN IF NOT EXISTS room_id UUID REFERENCES rooms(id) ON DELETE SET NULL;