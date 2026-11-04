class Device {
  final String id;
  final String name;
  final String deviceType;
  final String mqttTopic;
  final String status;
  final Map<String, dynamic> currentState;

  Device({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.mqttTopic,
    required this.status,
    required this.currentState,
  });

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      deviceType: json['device_type'] ?? '',
      mqttTopic: json['mqtt_topic'] ?? '',
      status: json['status'] ?? 'OFFLINE',
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
      'status': status,
      'current_state': currentState,
    };
  }

  Device copyWith({
    String? id,
    String? name,
    String? deviceType,
    String? mqttTopic,
    String? status,
    Map<String, dynamic>? currentState,
  }) {
    return Device(
      id: id ?? this.id,
      name: name ?? this.name,
      deviceType: deviceType ?? this.deviceType,
      mqttTopic: mqttTopic ?? this.mqttTopic,
      status: status ?? this.status,
      currentState: currentState ?? this.currentState,
    );
  }
}
