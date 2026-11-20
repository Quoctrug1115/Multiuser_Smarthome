double _toDouble(dynamic value, [double fallback = 0.0]) {
  if (value == null) return fallback;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? fallback;
}

int _toInt(dynamic value, [int fallback = 0]) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value.toString()) ?? fallback;
}

bool _toBool(dynamic value, [bool fallback = false]) {
  if (value == null) return fallback;
  if (value is bool) return value;
  final s = value.toString().trim().toLowerCase();
  if (s == 'true' || s == '1' || s == 'on' || s == 'active') return true;
  if (s == 'false' || s == '0' || s == 'off' || s == 'inactive') return false;
  return fallback;
}

class UserProfile {
  final String id;
  final String fullName;
  final String email;
  final String role;
  final String? ownerId;
  final bool isActive;
  final String? expiresAt;
  final String? createdAt;

  UserProfile({
    required this.id,
    required this.fullName,
    required this.email,
    required this.role,
    this.ownerId,
    this.isActive = true,
    this.expiresAt,
    this.createdAt,
  });

  bool get isOwner => role.trim().toLowerCase() == 'owner';
  bool get isAdmin => isOwner || role.trim().toLowerCase() == 'admin';
  bool get isGuest => role.trim().toLowerCase() == 'guest';
  String get name => fullName;
  String get roleName => role;
  String? get tenantId => ownerId;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: (json['id'] ?? '').toString(),
      fullName: (json['full_name'] ?? json['name'] ?? 'Người dùng').toString(),
      email: (json['email'] ?? '').toString(),
      role: (json['role'] ?? json['role_name'] ?? 'Member').toString(),
      ownerId: (json['owner_id'] ?? json['tenant_id'])?.toString(),
      isActive: _toBool(json['is_active'], true),
      expiresAt: (json['expires_at'] ?? json['guest_expires_at'])?.toString(),
      createdAt: json['created_at']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'full_name': fullName,
    'email': email,
    'role': role,
    'owner_id': ownerId,
    'is_active': isActive,
    'expires_at': expiresAt,
    'created_at': createdAt,
  };
}

class House {
  final String id;
  final String name;
  final String address;
  final String? ownerId;

  House({
    required this.id,
    required this.name,
    this.address = '',
    this.ownerId,
  });

  factory House.fromJson(Map<String, dynamic> json) {
    return House(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      address: (json['address'] ?? '').toString(),
      ownerId: json['owner_id']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'owner_id': ownerId,
  };
}

class Room {
  final String id;
  final String houseId;
  final String? houseName;
  final String name;
  final int floor;

  Room({
    required this.id,
    required this.houseId,
    this.houseName,
    required this.name,
    this.floor = 1,
  });

  factory Room.fromJson(Map<String, dynamic> json) {
    return Room(
      id: (json['id'] ?? '').toString(),
      houseId: (json['house_id'] ?? '').toString(),
      houseName: json['house_name']?.toString(),
      name: (json['name'] ?? '').toString(),
      floor: _toInt(json['floor'], 1),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'house_id': houseId,
    'house_name': houseName,
    'name': name,
    'floor': floor,
  };
}

class Device {
  final String id;
  final String name;
  final String deviceType;
  final String mqttTopic;
  final String? roomId;
  final String? roomName;
  final bool isOn;
  final double ratedPowerWatt;

  Device({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.mqttTopic,
    this.roomId,
    this.roomName,
    required this.isOn,
    required this.ratedPowerWatt,
  });

  static double defaultWattForType(String deviceType, String name) {
    final t = deviceType.trim().toLowerCase();
    final n = name.trim().toLowerCase();
    if (t == 'sensor' || n.contains('cảm biến') || n.contains('dht')) {
      return 0.0;
    }
    if (t == 'ac' ||
        n.contains('điều hòa') ||
        n.contains('máy lạnh') ||
        n.contains('air')) {
      return 1200.0;
    }
    if (t == 'fan' || n.contains('quạt')) {
      return 45.0;
    }
    if (t == 'light' || n.contains('đèn') || n.contains('led')) {
      return 15.0;
    }
    if (t == 'tv' || n.contains('tivi')) {
      return 120.0;
    }
    if (t == 'pump' || n.contains('bơm')) {
      return 350.0;
    }
    return 60.0; // Công tắc / ổ cắm mặc định
  }

  factory Device.fromJson(Map<String, dynamic> json) {
    final type = (json['device_type'] ?? 'switch').toString();
    final devName = (json['name'] ?? '').toString();

    final rawWatt =
        json['rated_power_watt'] ??
        json['power_watt'] ??
        json['wattage'] ??
        json['watt'] ??
        json['power'] ??
        0;
    final parsedWatt = _toDouble(rawWatt, 0.0);
    final effectiveWatt = parsedWatt > 0
        ? parsedWatt
        : defaultWattForType(type, devName);

    final status = (json['status'] ?? '').toString().trim().toUpperCase();
    final active = json['is_on'] is bool
        ? json['is_on'] as bool
        : (status == 'ON' || status == '1' || status == 'TRUE');

    return Device(
      id: (json['id'] ?? '').toString(),
      name: devName,
      deviceType: type,
      mqttTopic: (json['mqtt_topic'] ?? '').toString(),
      roomId: json['room_id']?.toString(),
      roomName: json['room_name']?.toString(),
      isOn: active,
      ratedPowerWatt: effectiveWatt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'device_type': deviceType,
    'mqtt_topic': mqttTopic,
    'room_id': roomId,
    'room_name': roomName,
    'is_on': isOn,
    'status': isOn ? 'ON' : 'OFF',
    'rated_power_watt': ratedPowerWatt,
  };
}

class AiAlert {
  final String id;
  final String title;
  final String message;
  final String severity;
  final String? deviceName;
  final String? roomName;
  final String? sensorType;
  final double? sensorValue;
  final double? zScore;
  final String createdAt;
  final bool isResolved;

  AiAlert({
    required this.id,
    required this.title,
    required this.message,
    this.severity = 'warning',
    this.deviceName,
    this.roomName,
    this.sensorType,
    this.sensorValue,
    this.zScore,
    this.createdAt = '',
    this.isResolved = false,
  });

  factory AiAlert.fromJson(dynamic raw) {
    final Map<String, dynamic> map = raw is Map<String, dynamic>
        ? raw
        : (raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{});
    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : map;

    return AiAlert(
      id: (data['id'] ?? data['alert_id'] ?? '').toString(),
      title: (data['title'] ?? data['alert_type'] ?? 'Cảnh báo bất thường AI')
          .toString(),
      message: (data['message'] ?? data['description'] ?? '').toString(),
      severity: (data['severity'] ?? data['level'] ?? 'warning').toString(),
      deviceName: data['device_name']?.toString(),
      roomName: data['room_name']?.toString(),
      sensorType: (data['sensor_type'] ?? data['metric'])?.toString(),
      sensorValue: data['sensor_value'] != null || data['value'] != null
          ? _toDouble(data['sensor_value'] ?? data['value'])
          : null,
      zScore: data['z_score'] != null ? _toDouble(data['z_score']) : null,
      createdAt: (data['created_at'] ?? data['timestamp'] ?? '').toString(),
      isResolved: _toBool(data['is_resolved'] ?? data['is_read'], false),
    );
  }
}

class AutomationRule {
  final String id;
  final String name;
  final String sensorType;
  final String conditionOperator;
  final double threshold;
  final String targetDeviceId;
  final String? targetDeviceName;
  final String action;
  final bool isActive;

  AutomationRule({
    required this.id,
    required this.name,
    required this.sensorType,
    required this.conditionOperator,
    required this.threshold,
    required this.targetDeviceId,
    this.targetDeviceName,
    required this.action,
    this.isActive = true,
  });

  factory AutomationRule.fromJson(Map<String, dynamic> json) {
    return AutomationRule(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      sensorType: (json['sensor_type'] ?? 'temperature').toString(),
      conditionOperator: (json['condition_operator'] ?? json['operator'] ?? '>')
          .toString(),
      threshold: _toDouble(json['threshold'], 0.0),
      targetDeviceId: (json['target_device_id'] ?? json['device_id'] ?? '')
          .toString(),
      targetDeviceName: (json['target_device_name'] ?? json['device_name'])
          ?.toString(),
      action: (json['action'] ?? 'ON').toString(),
      isActive: _toBool(json['is_active'] ?? json['enabled'], true),
    );
  }
}
