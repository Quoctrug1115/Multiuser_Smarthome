class Device {
  final String id;
  final String name;
  final String deviceType; // 'light' | 'fan' | 'ac' | 'switch' | 'sensor'
  final String mqttTopic;
  final String? roomId;
  final String? roomName;
  final bool isOn;
  final String status;
  final Map<String, dynamic> currentState;

  Device({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.mqttTopic,
    this.roomId,
    this.roomName,
    required this.isOn,
    required this.status,
    this.currentState = const {},
  });

  /// Công suất định mức tham chiếu (W) đồng bộ với Web
  double get ratedPowerWatt {
    if (!isOn || deviceType.toLowerCase() == 'sensor') return 0.0;
    switch (deviceType.toLowerCase()) {
      case 'ac':
      case 'heater':
        return 1200.0;
      case 'fan':
        return 45.0;
      case 'light':
        return 15.0;
      default:
        return 25.0;
    }
  }

  factory Device.fromJson(Map<String, dynamic> json) {
    final rawOn = json['is_on'] ?? json['status'] ?? json['state'];
    bool parsedIsOn = false;
    if (rawOn is bool) {
      parsedIsOn = rawOn;
    } else if (rawOn != null) {
      final s = rawOn.toString().trim().toLowerCase();
      parsedIsOn = s == 'true' || s == 'on' || s == '1' || s == 'active';
    }

    return Device(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      deviceType: (json['device_type'] ?? 'switch').toString(),
      mqttTopic: (json['mqtt_topic'] ?? '').toString(),
      roomId: json['room_id']?.toString(),
      roomName: json['room_name']?.toString(),
      isOn: parsedIsOn,
      status: parsedIsOn ? 'ON' : 'OFF',
      currentState: json['current_state'] is Map
          ? Map<String, dynamic>.from(json['current_state'])
          : {},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'device_type': deviceType,
      'mqtt_topic': mqttTopic,
      if (roomId != null) 'room_id': roomId,
      if (roomName != null) 'room_name': roomName,
      'is_on': isOn,
      'status': isOn ? 'ON' : 'OFF',
      'current_state': currentState,
    };
  }

  Device copyWith({
    String? id,
    String? name,
    String? deviceType,
    String? mqttTopic,
    String? roomId,
    String? roomName,
    bool? isOn,
    String? status,
    Map<String, dynamic>? currentState,
  }) {
    final nextOn = isOn ?? this.isOn;
    return Device(
      id: id ?? this.id,
      name: name ?? this.name,
      deviceType: deviceType ?? this.deviceType,
      mqttTopic: mqttTopic ?? this.mqttTopic,
      roomId: roomId ?? this.roomId,
      roomName: roomName ?? this.roomName,
      isOn: nextOn,
      status: status ?? (nextOn ? 'ON' : 'OFF'),
      currentState: currentState ?? this.currentState,
    );
  }
}
