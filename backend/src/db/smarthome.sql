-- ============================================================================
-- KHỞI TẠO DATABASE SMARTHOME TRÊN MICROSOFT SQL SERVER
-- ============================================================================
IF DB_ID(N'smarthome') IS NULL
BEGIN
    CREATE DATABASE [smarthome];
END
GO

USE [smarthome];
GO

-- ============================================================================
-- 1. BẢNG ROLES (PHÂN QUYỀN)
-- ============================================================================
IF OBJECT_ID(N'dbo.roles', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.roles (
        id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
        name NVARCHAR(50) NOT NULL UNIQUE,
        description NVARCHAR(MAX) NULL
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.roles WHERE name = N'Owner')
    INSERT INTO dbo.roles (name, description) VALUES (N'Owner', N'Chủ nhà - Toàn quyền quản trị hệ thống');

IF NOT EXISTS (SELECT 1 FROM dbo.roles WHERE name = N'Admin')
    INSERT INTO dbo.roles (name, description) VALUES (N'Admin', N'Quản trị phụ - Quản lý thiết bị và thành viên');

IF NOT EXISTS (SELECT 1 FROM dbo.roles WHERE name = N'Member')
    INSERT INTO dbo.roles (name, description) VALUES (N'Member', N'Thành viên gia đình - Điều khiển và giám sát');

IF NOT EXISTS (SELECT 1 FROM dbo.roles WHERE name = N'Guest')
    INSERT INTO dbo.roles (name, description) VALUES (N'Guest', N'Khách - Quyền hạn chế theo thời gian');
GO

-- ============================================================================
-- 2. BẢNG USERS (NGƯỜI DÙNG & ĐA HỘ GIA ĐÌNH)
-- ============================================================================
IF OBJECT_ID(N'dbo.users', N'U') IS NULL
BEGIN
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
        -- SQL Server không cho phép ON DELETE CASCADE trên khóa ngoại tự tham chiếu
        CONSTRAINT FK_users_owner FOREIGN KEY (owner_id) REFERENCES dbo.users(id) ON DELETE NO ACTION
    );
END
GO

-- ============================================================================
-- 3. BẢNG USER_SESSIONS (PHIÊN ĐĂNG NHẬP)
-- ============================================================================
IF OBJECT_ID(N'dbo.user_sessions', N'U') IS NULL
BEGIN
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
END
GO

-- ============================================================================
-- 4. BẢNG HOUSES (NGÔI NHÀ)
-- ============================================================================
IF OBJECT_ID(N'dbo.houses', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.houses (
        id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
        name NVARCHAR(100) NOT NULL,
        address NVARCHAR(MAX) NULL,
        owner_id UNIQUEIDENTIFIER NOT NULL,
        created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
        CONSTRAINT FK_houses_users FOREIGN KEY (owner_id) REFERENCES dbo.users(id) ON DELETE CASCADE
    );
END
GO

-- ============================================================================
-- 5. BẢNG ROOMS (PHÒNG)
-- ============================================================================
IF OBJECT_ID(N'dbo.rooms', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.rooms (
        id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
        house_id UNIQUEIDENTIFIER NOT NULL,
        name NVARCHAR(100) NOT NULL,
        floor INT NOT NULL DEFAULT 1,
        CONSTRAINT FK_rooms_houses FOREIGN KEY (house_id) REFERENCES dbo.houses(id) ON DELETE CASCADE
    );
END
GO

-- ============================================================================
-- 6. BẢNG DEVICES (THIẾT BỊ IOT)
-- ============================================================================
IF OBJECT_ID(N'dbo.devices', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.devices (
        id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
        room_id UNIQUEIDENTIFIER NULL,
        owner_id UNIQUEIDENTIFIER NULL,
        name NVARCHAR(100) NOT NULL,
        device_type NVARCHAR(50) NOT NULL, -- relay, light, fan, ac, switch, sensor, dht22, pir
        mqtt_topic NVARCHAR(150) NOT NULL,
        status NVARCHAR(20) NOT NULL DEFAULT N'OFF',
        is_on BIT NOT NULL DEFAULT 0,
        current_state NVARCHAR(MAX) NOT NULL DEFAULT N'{}',
        last_seen DATETIMEOFFSET NULL,
        CONSTRAINT CK_devices_current_state_json CHECK (ISJSON(current_state) = 1),
        CONSTRAINT FK_devices_rooms FOREIGN KEY (room_id) REFERENCES dbo.rooms(id) ON DELETE SET NULL,
        -- Dùng NO ACTION để tránh xung đột vòng lặp cascade (Error 1785) qua đường users -> houses -> rooms -> devices
        CONSTRAINT FK_devices_users FOREIGN KEY (owner_id) REFERENCES dbo.users(id) ON DELETE NO ACTION
    );
END
GO

-- ============================================================================
-- 7. BẢNG GUEST_ACCESS (CẤP QUYỀN TẠM THỜI CHO KHÁCH)
-- ============================================================================
IF OBJECT_ID(N'dbo.guest_access', N'U') IS NULL
BEGIN
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
END
GO

-- ============================================================================
-- 8. BẢNG DEVICE_LOGS (NHẬT KÝ SỰ KIỆN THIẾT BỊ)
-- ============================================================================
IF OBJECT_ID(N'dbo.device_logs', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.device_logs (
        id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
        device_id UNIQUEIDENTIFIER NOT NULL,
        event_type NVARCHAR(50) NOT NULL,
        data NVARCHAR(MAX) NOT NULL DEFAULT N'{}',
        created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
        CONSTRAINT CK_device_logs_data_json CHECK (ISJSON(data) = 1),
        CONSTRAINT FK_device_logs_devices FOREIGN KEY (device_id) REFERENCES dbo.devices(id) ON DELETE CASCADE
    );
END
GO

-- ============================================================================
-- 9. BẢNG SENSOR_DATA (DỮ LIỆU CẢM BIẾN THỜI GIAN THỰC)
-- ============================================================================
IF OBJECT_ID(N'dbo.sensor_data', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.sensor_data (
        [time] DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
        device_id UNIQUEIDENTIFIER NOT NULL,
        sensor_type NVARCHAR(50) NOT NULL,
        [value] FLOAT NOT NULL
    );
    CREATE INDEX IX_sensor_data_device_time ON dbo.sensor_data (device_id, [time] DESC);
END
GO

-- ============================================================================
-- 10. BẢNG AI_ALERTS & AI_SUGGESTIONS (CẢNH BÁO & GỢI Ý AI)
-- ============================================================================
IF OBJECT_ID(N'dbo.ai_alerts', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ai_alerts (
        id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
        device_id UNIQUEIDENTIFIER NULL,
        owner_id UNIQUEIDENTIFIER NULL,
        title NVARCHAR(200) NULL,
        alert_type NVARCHAR(50) NOT NULL, -- 'TEMPERATURE_SPIKE', 'UNUSUAL_MOTION', 'DOOR_LEFT_OPEN'
        severity NVARCHAR(20) NOT NULL DEFAULT N'HIGH',
        message NVARCHAR(MAX) NOT NULL,
        metadata NVARCHAR(MAX) NULL,
        created_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
        CONSTRAINT CK_ai_alerts_metadata_json CHECK (metadata IS NULL OR ISJSON(metadata) = 1),
        CONSTRAINT FK_ai_alerts_devices FOREIGN KEY (device_id) REFERENCES dbo.devices(id) ON DELETE NO ACTION,
        CONSTRAINT FK_ai_alerts_users FOREIGN KEY (owner_id) REFERENCES dbo.users(id) ON DELETE CASCADE
    );
END
GO

IF OBJECT_ID(N'dbo.ai_suggestions', N'U') IS NULL
BEGIN
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
END
GO

-- ============================================================================
-- 11. BẢNG AUTOMATIONS (KỊCH BẢN TỰ ĐỘNG HÓA IF-THEN)
-- ============================================================================
IF OBJECT_ID(N'dbo.automations', N'U') IS NULL
BEGIN
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
END
GO

-- ============================================================================
-- 12. BẢNG ENERGY_LOGS (THỐNG KÊ ĐIỆN NĂNG TIÊU THỤ)
-- ============================================================================
IF OBJECT_ID(N'dbo.energy_logs', N'U') IS NULL
BEGIN
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
END
GO

-- ============================================================================
-- 13. BỔ SUNG CỘT & CHỈ MỤC AN TOÀN (TƯƠNG ĐƯƠNG ADD COLUMN IF NOT EXISTS)
-- ============================================================================
IF COL_LENGTH(N'dbo.users', N'name') IS NULL
    ALTER TABLE dbo.users ADD name NVARCHAR(100) NULL;

IF COL_LENGTH(N'dbo.users', N'role') IS NULL
    ALTER TABLE dbo.users ADD role NVARCHAR(50) NOT NULL DEFAULT N'Member';

IF COL_LENGTH(N'dbo.users', N'owner_id') IS NULL
    ALTER TABLE dbo.users ADD owner_id UNIQUEIDENTIFIER NULL;

IF COL_LENGTH(N'dbo.devices', N'owner_id') IS NULL
    ALTER TABLE dbo.devices ADD owner_id UNIQUEIDENTIFIER NULL;

IF COL_LENGTH(N'dbo.devices', N'is_on') IS NULL
    ALTER TABLE dbo.devices ADD is_on BIT NOT NULL DEFAULT 0;

IF COL_LENGTH(N'dbo.automations', N'owner_id') IS NULL
    ALTER TABLE dbo.automations ADD owner_id UNIQUEIDENTIFIER NULL;

IF COL_LENGTH(N'dbo.ai_alerts', N'owner_id') IS NULL
    ALTER TABLE dbo.ai_alerts ADD owner_id UNIQUEIDENTIFIER NULL;

IF COL_LENGTH(N'dbo.energy_logs', N'owner_id') IS NULL
    ALTER TABLE dbo.energy_logs ADD owner_id UNIQUEIDENTIFIER NULL;
GO

-- Đổi tên cột 'if' -> 'id' nếu bảng guest_access cũ lỡ tạo nhầm tên cột
IF COL_LENGTH(N'dbo.guest_access', N'if') IS NOT NULL AND COL_LENGTH(N'dbo.guest_access', N'id') IS NULL
BEGIN
    EXEC sp_rename N'dbo.guest_access.[if]', N'id', N'COLUMN';
END
GO

-- Tạo Unique Index trên (owner_id, mqtt_topic) cho phép nhiều hộ gia đình dùng chung topic Wokwi
-- (Collation mặc định của SQL Server đã không phân biệt chữ hoa/thường)
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes 
    WHERE name = N'idx_devices_owner_mqtt_topic' AND object_id = OBJECT_ID(N'dbo.devices')
)
BEGIN
    CREATE UNIQUE INDEX idx_devices_owner_mqtt_topic
        ON dbo.devices (owner_id, mqtt_topic)
        WHERE owner_id IS NOT NULL;
END
GO

-- ============================================================================
-- 14. DỮ LIỆU KHỞI TẠO MẪU (SEED DATA)
-- ============================================================================
DECLARE @owner_role_id UNIQUEIDENTIFIER;
SELECT TOP 1 @owner_role_id = id FROM dbo.roles WHERE name = N'Owner';

-- Tạo tài khoản Chủ nhà mẫu
IF NOT EXISTS (SELECT 1 FROM dbo.users WHERE id = '11111111-1111-1111-1111-111111111111')
BEGIN
    INSERT INTO dbo.users (id, email, password_hash, full_name, name, role_id, role, owner_id)
    VALUES (
        '11111111-1111-1111-1111-111111111111',
        N'trung.owner@smarthome.vn',
        N'$2b$12$e86.M4O1aD.Y/mockpasswordhashvaluefortesting',
        N'Lê Quốc Trung',
        N'Lê Quốc Trung',
        @owner_role_id,
        N'Owner',
        NULL
    );
END

-- Tạo Nhà mẫu
IF NOT EXISTS (SELECT 1 FROM dbo.houses WHERE id = 'a1b2c3d4-0000-0000-0000-000000000000')
BEGIN
    INSERT INTO dbo.houses (id, name, address, owner_id)
    VALUES (
        'a1b2c3d4-0000-0000-0000-000000000000',
        N'Nhà thông minh',
        N'TP.HCM',
        '11111111-1111-1111-1111-111111111111'
    );
END

-- Tạo Phòng mẫu
IF NOT EXISTS (SELECT 1 FROM dbo.rooms WHERE id = '22222222-2222-2222-2222-222222222222')
BEGIN
    INSERT INTO dbo.rooms (id, house_id, name, floor)
    VALUES ('22222222-2222-2222-2222-222222222222', 'a1b2c3d4-0000-0000-0000-000000000000', N'Phòng khách', 1);
END

IF NOT EXISTS (SELECT 1 FROM dbo.rooms WHERE id = '33333333-3333-3333-3333-333333333333')
BEGIN
    INSERT INTO dbo.rooms (id, house_id, name, floor)
    VALUES ('33333333-3333-3333-3333-333333333333', 'a1b2c3d4-0000-0000-0000-000000000000', N'Nhà bếp', 1);
END

-- Tạo Thiết bị mẫu
IF NOT EXISTS (SELECT 1 FROM dbo.devices WHERE id = 'd1111111-1111-1111-1111-111111111111')
BEGIN
    INSERT INTO dbo.devices (id, room_id, owner_id, name, device_type, mqtt_topic, status, is_on, current_state)
    VALUES (
        'd1111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
        '11111111-1111-1111-1111-111111111111',
        N'Đèn phòng khách',
        N'light',
        N'smarthome/livingroom/light',
        N'ON',
        1,
        N'{"power": "ON"}'
    );
END

IF NOT EXISTS (SELECT 1 FROM dbo.devices WHERE id = 'd2222222-2222-2222-2222-222222222222')
BEGIN
    INSERT INTO dbo.devices (id, room_id, owner_id, name, device_type, mqtt_topic, status, is_on, current_state)
    VALUES (
        'd2222222-2222-2222-2222-222222222222',
        '33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111',
        N'Cảm biến DHT22',
        N'sensor',
        N'smarthome/kitchen/dht22',
        N'ON',
        1,
        N'{"temperature": 28.5, "humidity": 62}'
    );
END

-- Thiết bị ESP32 Discovery mặc định (owner_id = NULL để quét được ở mọi nhà mới)
IF NOT EXISTS (SELECT 1 FROM dbo.devices WHERE id = '00000000-0000-0000-0000-000000000001')
BEGIN
    INSERT INTO dbo.devices (id, owner_id, name, device_type, mqtt_topic, status, is_on)
    VALUES (
        '00000000-0000-0000-0000-000000000001',
        NULL,
        N'ESP32 Sensor Hub',
        N'sensor',
        N'smarthome/sensors/dht22',
        N'OFF',
        0
    );
END
GO

-- ============================================================================
-- 15. CHUẨN HÓA DỮ LIỆU ĐA HỘ GIA ĐÌNH (TƯƠNG ĐƯƠNG KHỐI DO $$ TRONG POSTGRES)
-- ============================================================================
DECLARE @legacy_owner UNIQUEIDENTIFIER;
DECLARE @owner_role UNIQUEIDENTIFIER;

SELECT TOP 1 @owner_role = id FROM dbo.roles WHERE LOWER(name) = N'owner';
SELECT TOP 1 @legacy_owner = id
FROM dbo.users
WHERE LOWER(role) IN (N'owner', N'admin')
ORDER BY created_at ASC;

IF @legacy_owner IS NOT NULL
BEGIN
    UPDATE dbo.houses SET owner_id = @legacy_owner WHERE owner_id IS NULL;
    UPDATE dbo.devices SET owner_id = @legacy_owner WHERE owner_id IS NULL AND id <> '00000000-0000-0000-0000-000000000001';
    UPDATE dbo.automations SET owner_id = @legacy_owner WHERE owner_id IS NULL;
    UPDATE dbo.ai_alerts SET owner_id = @legacy_owner WHERE owner_id IS NULL;
    UPDATE dbo.energy_logs SET owner_id = @legacy_owner WHERE owner_id IS NULL;
    UPDATE dbo.users SET owner_id = @legacy_owner WHERE owner_id IS NULL AND id <> @legacy_owner AND LOWER(role) <> N'owner';
END

-- Nâng cấp các tài khoản tự đăng ký (owner_id IS NULL) thành Owner độc lập
UPDATE dbo.users
SET role = N'Owner',
    role_id = @owner_role,
    full_name = COALESCE(full_name, name),
    name = COALESCE(name, full_name)
WHERE owner_id IS NULL
  AND LOWER(ISNULL(role, N'member')) <> N'owner';
GO

-- ============================================================================
-- 16. TRUY VẤN KIỂM TRA DỮ LIỆU THEO GIỜ VIỆT NAM (UTC+7)
-- ============================================================================
SELECT TOP 20
    [time] AT TIME ZONE 'SE Asia Standard Time' AS time_vn,
    device_id,
    owner_id,
    power_watt,
    kwh_consumed
FROM dbo.energy_logs
ORDER BY [time] DESC;
GO