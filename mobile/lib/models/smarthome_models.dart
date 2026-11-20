export 'device.dart';

class UserProfile {
  final String id;
  final String name;
  final String email;
  final String role; // 'Owner' | 'Admin' | 'Member' | 'Guest'
  final String ownerId;
  final bool isActive;

  UserProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.ownerId,
    this.isActive = true,
  });

  bool get isAdminOrOwner {
    final r = role.toLowerCase();
    return r == 'owner' || r == 'admin';
  }

  bool get canControlDevices => role.toLowerCase() != 'guest';

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? '').toString();
    final rawRole = (json['role'] ?? json['role_name'] ?? 'Member')
        .toString()
        .trim();
    return UserProfile(
      id: id,
      name: (json['full_name'] ?? json['name'] ?? json['username'] ?? 'User')
          .toString(),
      email: (json['email'] ?? '').toString(),
      role: rawRole.isEmpty ? 'Member' : rawRole,
      ownerId: (json['owner_id'] ?? id).toString(),
      isActive: json['is_active'] != false,
    );
  }
}

class House {
  final String id;
  final String name;
  final String address;
  final String ownerId;

  House({
    required this.id,
    required this.name,
    required this.address,
    required this.ownerId,
  });

  factory House.fromJson(Map<String, dynamic> json) {
    return House(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      address: (json['address'] ?? '').toString(),
      ownerId: (json['owner_id'] ?? '').toString(),
    );
  }
}

class Room {
  final String id;
  final String houseId;
  final String houseName;
  final String name;
  final int floor;

  Room({
    required this.id,
    required this.houseId,
    required this.houseName,
    required this.name,
    required this.floor,
  });

  factory Room.fromJson(Map<String, dynamic> json) {
    return Room(
      id: (json['id'] ?? '').toString(),
      houseId: (json['house_id'] ?? '').toString(),
      houseName: (json['house_name'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      floor: (json['floor'] is num)
          ? (json['floor'] as num).toInt()
          : int.tryParse((json['floor'] ?? '1').toString()) ?? 1,
    );
  }
}

class SensorData {
  final double temperature;
  final double humidity;
  final int lux;
  final bool motion;

  SensorData({
    this.temperature = 28.5,
    this.humidity = 65.0,
    this.lux = 450,
    this.motion = false,
  });

  factory SensorData.fromJson(Map<String, dynamic> json, [SensorData? prev]) {
    return SensorData(
      temperature: (json['temperature'] ?? prev?.temperature ?? 28.5)
          .toDouble(),
      humidity: (json['humidity'] ?? prev?.humidity ?? 65.0).toDouble(),
      lux: (json['lux'] ?? prev?.lux ?? 450).toInt(),
      motion: json['motion'] is bool ? json['motion'] : (prev?.motion ?? false),
    );
  }
}

class AutomationRule {
  final String id;
  final String name;
  final String conditionText;
  final String actionText;
  final bool isActive;

  AutomationRule({
    required this.id,
    required this.name,
    required this.conditionText,
    required this.actionText,
    required this.isActive,
  });

  factory AutomationRule.fromJson(Map<String, dynamic> json) {
    final fallbackCond =
        '${json['condition_type'] ?? ''} ${json['operator'] ?? ''} ${json['threshold'] ?? ''}'
            .trim();
    return AutomationRule(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? 'Kịch bản').toString(),
      conditionText: (json['condition_text'] ?? fallbackCond).toString(),
      actionText:
          (json['action_text'] ?? 'Hành động: ${json['action'] ?? 'ON'}')
              .toString(),
      isActive: json['is_active'] != false,
    );
  }
}

class AiAlert {
  final String id;
  final String ownerId;
  final String alertType;
  final String title;
  final String message;
  final String severity;
  final String createdAt;

  AiAlert({
    required this.id,
    required this.ownerId,
    required this.alertType,
    required this.title,
    required this.message,
    required this.severity,
    required this.createdAt,
  });

  factory AiAlert.fromJson(Map<String, dynamic> json) {
    final type = (json['alert_type'] ?? 'ANOMALY').toString();
    return AiAlert(
      id: (json['id'] ?? '').toString(),
      ownerId: (json['owner_id'] ?? '').toString(),
      alertType: type,
      title: (json['title'] ?? type).toString(),
      message: (json['message'] ?? json['description'] ?? '').toString(),
      severity: (json['severity'] ?? 'warning').toString().toLowerCase(),
      createdAt: (json['created_at'] ?? '').toString(),
    );
  }
}
