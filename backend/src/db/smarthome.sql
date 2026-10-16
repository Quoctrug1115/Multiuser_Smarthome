-- Active: 1791959887858@@127.0.0.1@5432@smarthome_db
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

-- bien bang sensor_data thanh timescaledb hypertable
select create_hypertable('sensor_data','time', if_not_exists => true);

select* from roles;