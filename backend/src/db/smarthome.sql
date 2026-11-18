-- ============================================================================
-- 1. BẢNG ROLES (PHÂN QUYỀN)
-- ============================================================================
CREATE TABLE dbo.roles (
    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    name NVARCHAR(50) NOT NULL UNIQUE,
    description NVARCHAR(MAX) NULL
);

INSERT INTO dbo.roles (name, description)
SELECT v.name, v.description
FROM (VALUES
    (N'Owner', N'Chủ nhà - Toàn quyền quản trị hệ thống'),
    (N'Admin', N'Quản trị phụ - Quản lý thiết bị và thành viên'),
    (N'Member', N'Thành viên gia đình - Điều khiển và giám sát'),
    (N'Guest', N'Khách - Quyền hạn chế theo thời gian')
) AS v(name, description)
WHERE NOT EXISTS (SELECT 1 FROM dbo.roles r WHERE r.name = v.name);

-- ============================================================================
-- 2. BẢNG USERS (NGƯỜI DÙNG & ĐA HỘ GIA ĐÌNH)
-- ============================================================================
CREATE TABLE dbo.users (
    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    email NVARCHAR(255) NOT NULL UNIQUE,
    password_hash NVARCHAR(255) NOT NULL,
    full_name NVARCHAR(100) NULL,
    name NVARCHAR(100) NULL,
    role_id UNIQUEIDENTIFIER NULL,
    role NVARCHAR(50) NOT NULL DEFAULT N'Member',
    owner_id UNIQUEIDENTIFIER NULL,
    is_active BIT NOT NULL DEFAULT 1,
    created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT FK_users_roles FOREIGN KEY (role_id) REFERENCES dbo.roles(id),
    CONSTRAINT FK_users_owner FOREIGN KEY (owner_id) REFERENCES dbo.users(id) ON DELETE NO ACTION
);

-- ============================================================================
-- 3. BẢNG USER_SESSIONS (PHIÊN ĐĂNG NHẬP)
-- ============================================================================
CREATE TABLE dbo.user_sessions (
    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    user_id UNIQUEIDENTIFIER NOT NULL,
    token_hash NVARCHAR(255) NOT NULL,
    device_info NVARCHAR(255) NULL,
    ip_address NVARCHAR(45) NULL,
    expires_at DATETIMEOFFSET NOT NULL,
    created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT FK_user_sessions_users FOREIGN KEY (user_id) REFERENCES dbo.users(id) ON DELETE CASCADE
);

-- ============================================================================
-- 4. BẢNG HOUSES (NGÔI NHÀ)
-- ============================================================================
CREATE TABLE dbo.houses (
    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    name NVARCHAR(100) NOT NULL,
    address NVARCHAR(MAX) NULL,
    owner_id UNIQUEIDENTIFIER NOT NULL,
    created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT FK_houses_users FOREIGN KEY (owner_id) REFERENCES dbo.users(id) ON DELETE CASCADE
);

-- ============================================================================
-- 5. BẢNG ROOMS (PHÒNG)
-- ============================================================================
CREATE TABLE dbo.rooms (
    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    house_id UNIQUEIDENTIFIER NOT NULL,
    name NVARCHAR(100) NOT NULL,
    floor INT NOT NULL DEFAULT 1,
    CONSTRAINT FK_rooms_houses FOREIGN KEY (house_id) REFERENCES dbo.houses(id) ON DELETE CASCADE
);

-- ============================================================================
-- 6. BẢNG DEVICES (THIẾT BỊ IOT)
-- ============================================================================
CREATE TABLE dbo.devices (
    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    room_id UNIQUEIDENTIFIER NULL,
    owner_id UNIQUEIDENTIFIER NULL,
    name NVARCHAR(100) NOT NULL,
    device_type NVARCHAR(50) NOT NULL,
    mqtt_topic NVARCHAR(150) NOT NULL,
    status NVARCHAR(20) NOT NULL DEFAULT N'OFF',
    is_on BIT NOT NULL DEFAULT 0,
    current_state NVARCHAR(MAX) NOT NULL DEFAULT N'{}',
    last_seen DATETIMEOFFSET NULL,
    CONSTRAINT CK_devices_current_state_json CHECK (ISJSON(current_state) = 1),
    CONSTRAINT FK_devices_rooms FOREIGN KEY (room_id) REFERENCES dbo.rooms(id) ON DELETE SET NULL,
    CONSTRAINT FK_devices_users FOREIGN KEY (owner_id) REFERENCES dbo.users(id) ON DELETE NO ACTION
);

CREATE UNIQUE INDEX idx_devices_owner_mqtt_topic
    ON dbo.devices (owner_id, mqtt_topic)
    WHERE owner_id IS NOT NULL;

-- ============================================================================
-- 7. BẢNG GUEST_ACCESS (CẤP QUYỀN TẠM THỜI CHO KHÁCH)
-- ============================================================================
CREATE TABLE dbo.guest_access (
    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    guest_id UNIQUEIDENTIFIER NOT NULL,
    device_id UNIQUEIDENTIFIER NOT NULL,
    valid_from DATETIMEOFFSET NOT NULL,
    valid_until DATETIMEOFFSET NOT NULL,
    is_revoked BIT NOT NULL DEFAULT 0,
    created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT FK_guest_access_users FOREIGN KEY (guest_id) REFERENCES dbo.users(id) ON DELETE CASCADE,
    CONSTRAINT FK_guest_access_devices FOREIGN KEY (device_id) REFERENCES dbo.devices(id) ON DELETE NO ACTION
);

-- ============================================================================
-- 8. BẢNG DEVICE_LOGS (NHẬT KÝ SỰ KIỆN THIẾT BỊ)
-- ============================================================================
CREATE TABLE dbo.device_logs (
    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    device_id UNIQUEIDENTIFIER NOT NULL,
    event_type NVARCHAR(50) NOT NULL,
    data NVARCHAR(MAX) NOT NULL DEFAULT N'{}',
    created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT CK_device_logs_data_json CHECK (ISJSON(data) = 1),
    CONSTRAINT FK_device_logs_devices FOREIGN KEY (device_id) REFERENCES dbo.devices(id) ON DELETE CASCADE
);

-- ============================================================================
-- 9. BẢNG SENSOR_DATA (DỮ LIỆU CẢM BIẾN THỜI GIAN THỰC)
-- ============================================================================
CREATE TABLE dbo.sensor_data (
    [time] DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    device_id UNIQUEIDENTIFIER NOT NULL,
    sensor_type NVARCHAR(50) NOT NULL,
    [value] FLOAT NOT NULL
);

CREATE INDEX IX_sensor_data_device_time ON dbo.sensor_data (device_id, [time] DESC);

-- ============================================================================
-- 10. BẢNG AI_ALERTS & AI_SUGGESTIONS (CẢNH BÁO & GỢI Ý AI)
-- ============================================================================
CREATE TABLE dbo.ai_alerts (
    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    device_id UNIQUEIDENTIFIER NULL,
    owner_id UNIQUEIDENTIFIER NULL,
    title NVARCHAR(200) NULL,
    alert_type NVARCHAR(50) NOT NULL,
    severity NVARCHAR(20) NOT NULL DEFAULT N'HIGH',
    message NVARCHAR(MAX) NOT NULL,
    metadata NVARCHAR(MAX) NULL,
    created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT CK_ai_alerts_metadata_json CHECK (metadata IS NULL OR ISJSON(metadata) = 1),
    CONSTRAINT FK_ai_alerts_devices FOREIGN KEY (device_id) REFERENCES dbo.devices(id) ON DELETE NO ACTION,
    CONSTRAINT FK_ai_alerts_users FOREIGN KEY (owner_id) REFERENCES dbo.users(id) ON DELETE CASCADE
);

CREATE TABLE dbo.ai_suggestions (
    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    user_id UNIQUEIDENTIFIER NULL,
    device_id UNIQUEIDENTIFIER NULL,
    suggested_action NVARCHAR(MAX) NOT NULL,
    cron_expression NVARCHAR(50) NULL,
    confidence_score FLOAT NOT NULL,
    is_applied BIT NOT NULL DEFAULT 0,
    created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT CK_ai_suggestions_action_json CHECK (ISJSON(suggested_action) = 1),
    CONSTRAINT FK_ai_suggestions_users FOREIGN KEY (user_id) REFERENCES dbo.users(id) ON DELETE CASCADE,
    CONSTRAINT FK_ai_suggestions_devices FOREIGN KEY (device_id) REFERENCES dbo.devices(id) ON DELETE NO ACTION
);

-- ============================================================================
-- 11. BẢNG AUTOMATIONS (KỊCH BẢN TỰ ĐỘNG HÓA IF-THEN)
-- ============================================================================
CREATE TABLE dbo.automations (
    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    house_id UNIQUEIDENTIFIER NULL,
    owner_id UNIQUEIDENTIFIER NULL,
    name NVARCHAR(100) NOT NULL,
    condition_text NVARCHAR(255) NULL,
    action_text NVARCHAR(255) NULL,
    trigger_device_id UNIQUEIDENTIFIER NULL,
    condition_type NVARCHAR(30) NOT NULL DEFAULT N'temperature',
    operator NVARCHAR(10) NOT NULL DEFAULT N'>',
    threshold FLOAT NOT NULL DEFAULT 30.0,
    trigger_value FLOAT NOT NULL DEFAULT 30.0,
    action NVARCHAR(20) NOT NULL DEFAULT N'ON',
    device_id NVARCHAR(50) NULL,
    action_device_id UNIQUEIDENTIFIER NULL,
    action_payload NVARCHAR(MAX) NOT NULL DEFAULT N'{"power": "ON"}',
    is_active BIT NOT NULL DEFAULT 1,
    created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT CK_automations_payload_json CHECK (ISJSON(action_payload) = 1),
    CONSTRAINT FK_automations_houses FOREIGN KEY (house_id) REFERENCES dbo.houses(id) ON DELETE NO ACTION,
    CONSTRAINT FK_automations_users FOREIGN KEY (owner_id) REFERENCES dbo.users(id) ON DELETE CASCADE,
    CONSTRAINT FK_automations_trigger_dev FOREIGN KEY (trigger_device_id) REFERENCES dbo.devices(id) ON DELETE NO ACTION,
    CONSTRAINT FK_automations_action_dev FOREIGN KEY (action_device_id) REFERENCES dbo.devices(id) ON DELETE NO ACTION
);

-- ============================================================================
-- 12. BẢNG ENERGY_LOGS (THỐNG KÊ ĐIỆN NĂNG TIÊU THỤ)
-- ============================================================================
CREATE TABLE dbo.energy_logs (
    id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    device_id UNIQUEIDENTIFIER NULL,
    owner_id UNIQUEIDENTIFIER NULL,
    power_watt FLOAT NOT NULL DEFAULT 0,
    kwh_consumed FLOAT NOT NULL DEFAULT 0,
    kwh FLOAT NOT NULL DEFAULT 0,
    [time] DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    recorded_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT FK_energy_logs_devices FOREIGN KEY (device_id) REFERENCES dbo.devices(id) ON DELETE NO ACTION,
    CONSTRAINT FK_energy_logs_users FOREIGN KEY (owner_id) REFERENCES dbo.users(id) ON DELETE CASCADE
);

CREATE INDEX IX_energy_logs_owner_time ON dbo.energy_logs (owner_id, [time] DESC);

-- ============================================================================
-- 13. DỮ LIỆU KHỞI TẠO MẪU (SEED DATA)
-- ============================================================================
INSERT INTO dbo.users (id, email, password_hash, full_name, name, role_id, role, owner_id)
SELECT
    '11111111-1111-1111-1111-111111111111',
    N'trung.owner@smarthome.vn',
    N'$2b$12$e86.M4O1aD.Y/mockpasswordhashvaluefortesting',
    N'Lê Quốc Trung',
    N'Lê Quốc Trung',
    r.id,
    N'Owner',
    NULL
FROM dbo.roles r
WHERE r.name = N'Owner'
  AND NOT EXISTS (SELECT 1 FROM dbo.users u WHERE u.id = '11111111-1111-1111-1111-111111111111');

INSERT INTO dbo.houses (id, name, address, owner_id)
SELECT
    'a1b2c3d4-0000-0000-0000-000000000000',
    N'Nhà thông minh',
    N'TP.HCM',
    '11111111-1111-1111-1111-111111111111'
WHERE NOT EXISTS (SELECT 1 FROM dbo.houses WHERE id = 'a1b2c3d4-0000-0000-0000-000000000000');

INSERT INTO dbo.rooms (id, house_id, name, floor)
SELECT v.id, v.house_id, v.name, v.floor
FROM (VALUES
    (CAST('22222222-2222-2222-2222-222222222222' AS UNIQUEIDENTIFIER), CAST('a1b2c3d4-0000-0000-0000-000000000000' AS UNIQUEIDENTIFIER), N'Phòng khách', 1),
    (CAST('33333333-3333-3333-3333-333333333333' AS UNIQUEIDENTIFIER), CAST('a1b2c3d4-0000-0000-0000-000000000000' AS UNIQUEIDENTIFIER), N'Nhà bếp', 1)
) AS v(id, house_id, name, floor)
WHERE NOT EXISTS (SELECT 1 FROM dbo.rooms r WHERE r.id = v.id);

INSERT INTO dbo.devices (id, room_id, owner_id, name, device_type, mqtt_topic, status, is_on, current_state)
SELECT v.id, v.room_id, v.owner_id, v.name, v.device_type, v.mqtt_topic, v.status, v.is_on, v.current_state
FROM (VALUES
    (
        CAST('d1111111-1111-1111-1111-111111111111' AS UNIQUEIDENTIFIER),
        CAST('22222222-2222-2222-2222-222222222222' AS UNIQUEIDENTIFIER),
        CAST('11111111-1111-1111-1111-111111111111' AS UNIQUEIDENTIFIER),
        N'Đèn phòng khách',
        N'light',
        N'smarthome/livingroom/light',
        N'ON',
        CAST(1 AS BIT),
        N'{"power": "ON"}'
    ),
    (
        CAST('d2222222-2222-2222-2222-222222222222' AS UNIQUEIDENTIFIER),
        CAST('33333333-3333-3333-3333-333333333333' AS UNIQUEIDENTIFIER),
        CAST('11111111-1111-1111-1111-111111111111' AS UNIQUEIDENTIFIER),
        N'Cảm biến DHT22',
        N'sensor',
        N'smarthome/kitchen/dht22',
        N'ON',
        CAST(1 AS BIT),
        N'{"temperature": 28.5, "humidity": 62}'
    ),
    (
        CAST('00000000-0000-0000-0000-000000000001' AS UNIQUEIDENTIFIER),
        CAST(NULL AS UNIQUEIDENTIFIER),
        CAST(NULL AS UNIQUEIDENTIFIER),
        N'ESP32 Sensor Hub',
        N'sensor',
        N'smarthome/sensors/dht22',
        N'OFF',
        CAST(0 AS BIT),
        N'{}'
    )
) AS v(id, room_id, owner_id, name, device_type, mqtt_topic, status, is_on, current_state)
WHERE NOT EXISTS (SELECT 1 FROM dbo.devices d WHERE d.id = v.id);

-- ============================================================================
-- 14. CHUẨN HÓA DỮ LIỆU ĐA HỘ GIA ĐÌNH (MULTI-TENANT)
-- ============================================================================
UPDATE dbo.users
SET role = N'Owner',
    role_id = (SELECT TOP 1 id FROM dbo.roles WHERE LOWER(name) = N'owner'),
    full_name = COALESCE(full_name, name),
    name = COALESCE(name, full_name)
WHERE owner_id IS NULL
  AND LOWER(ISNULL(role, N'member')) <> N'owner';

-- ============================================================================
-- 15. TRUY VẤN KIỂM TRA NHANH SAU KHI TẠO
-- ============================================================================
SELECT * FROM dbo.roles;
SELECT id, email, full_name, role, owner_id FROM dbo.users;
SELECT id, name, device_type, mqtt_topic, status, is_on FROM dbo.devices;

SELECT name, LEN(name) AS do_dai_ten, create_date
FROM sys.tables
WHERE name LIKE N'devices%';