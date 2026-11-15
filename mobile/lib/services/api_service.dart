import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

typedef JsonMap = Map<String, dynamic>;
typedef JsonList = List<JsonMap>;

class ApiService extends ChangeNotifier {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _baseUrl = 'http://10.0.2.2:3000/api/v1';
    }
  }

  String _baseUrl = 'http://localhost:3000/api/v1';
  String? _token;
  JsonMap? _currentUser;

  String get baseUrl => _baseUrl;
  String? get token => _token;
  JsonMap? get currentUser => _currentUser;
  bool get isAuthenticated => _token != null && _token!.isNotEmpty;

  String get currentUserRole {
    final raw = _currentUser?['role'] ?? _currentUser?['role_name'] ?? 'Member';
    return raw.toString().trim();
  }

  bool get isAdmin {
    final r = currentUserRole.toLowerCase();
    return r == 'owner' || r == 'admin';
  }

  void updateBaseUrl(String wsOrHttpUrl) {
    String clean = wsOrHttpUrl.trim();
    if (clean.startsWith('ws://')) {
      clean = clean.replaceFirst('ws://', 'http://');
    } else if (clean.startsWith('wss://')) {
      clean = clean.replaceFirst('wss://', 'https://');
    }
    if (clean.endsWith('/ws')) {
      clean = clean.substring(0, clean.length - 3);
    }
    if (!clean.endsWith('/api/v1')) {
      clean = '$clean/api/v1';
    }
    _baseUrl = clean;
    notifyListeners();
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  JsonMap _decodeJwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return {};
      final normalized = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final map = jsonDecode(decoded);
      if (map is Map) return JsonMap.from(map);
    } catch (_) {}
    return {};
  }

  dynamic _parseResponse(http.Response res) {
    final bodyText = utf8.decode(res.bodyBytes);
    dynamic decoded;

    if (bodyText.isNotEmpty) {
      try {
        decoded = jsonDecode(bodyText);
      } catch (_) {
        decoded = null;
      }
    }

    if (res.statusCode >= 200 && res.statusCode <= 299) {
      return decoded;
    }

    String errorMsg = 'Lỗi máy chủ (${res.statusCode})';
    if (decoded is Map && decoded['error'] != null) {
      errorMsg = decoded['error'].toString();
    } else if (decoded is Map && decoded['message'] != null) {
      errorMsg = decoded['message'].toString();
    } else if (bodyText.isNotEmpty) {
      errorMsg = bodyText;
    }
    throw Exception(errorMsg);
  }

  // ==================== 1. AUTH ====================

  Future<void> login(String email, String password) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    final data = _parseResponse(res);
    if (data is Map) {
      _token = data['token']?.toString() ?? data['access_token']?.toString();
      final jwtClaims = _token != null
          ? _decodeJwtPayload(_token!)
          : <String, dynamic>{};

      if (data['user'] is Map) {
        _currentUser = JsonMap.from(data['user']);
      } else {
        _currentUser = {
          'email': data['email'] ?? jwtClaims['email'] ?? email,
          'full_name':
              data['full_name'] ??
              jwtClaims['full_name'] ??
              email.split('@').first,
          'role':
              data['role'] ??
              data['role_name'] ??
              jwtClaims['role'] ??
              jwtClaims['role_name'] ??
              'Member',
        };
      }
      notifyListeners();
    }
  }

  Future<void> register(String fullName, String email, String password) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'full_name': fullName,
        'name': fullName,
        'email': email,
        'password': password,
        'role_name': 'Member',
      }),
    );
    _parseResponse(res);
  }

  void logout() {
    _token = null;
    _currentUser = null;
    notifyListeners();
  }

  // ==================== 2. DEVICES (CRUD + CONTROL) ====================

  Future<JsonList> discoverWokwiDevices() async {
    final res = await http.get(
      Uri.parse('$_baseUrl/devices/discover'),
      headers: _headers,
    );
    final data = _parseResponse(res);
    if (data is List) {
      return data.map((e) => JsonMap.from(e)).toList();
    }
    return [];
  }

  Future<JsonList> getDevices() async {
    final res = await http.get(
      Uri.parse('$_baseUrl/devices'),
      headers: _headers,
    );
    final data = _parseResponse(res);
    if (data is List) {
      return data.map((e) => JsonMap.from(e)).toList();
    }
    if (data is Map && data['devices'] is List) {
      return (data['devices'] as List).map((e) => JsonMap.from(e)).toList();
    }
    return [];
  }

  Future<void> createDevice({
    required String name,
    required String deviceType,
    required String mqttTopic,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/devices'),
      headers: _headers,
      body: jsonEncode({
        'name': name,
        'device_type': deviceType,
        'mqtt_topic': mqttTopic,
      }),
    );
    _parseResponse(res);
  }

  Future<void> updateDevice(
    String deviceId, {
    required String name,
    required String deviceType,
    required String mqttTopic,
  }) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/devices/$deviceId'),
      headers: _headers,
      body: jsonEncode({
        'name': name,
        'device_type': deviceType,
        'mqtt_topic': mqttTopic,
      }),
    );
    _parseResponse(res);
  }

  Future<void> deleteDevice(String deviceId) async {
    final res = await http.delete(
      Uri.parse('$_baseUrl/devices/$deviceId'),
      headers: _headers,
    );
    _parseResponse(res);
  }

  Future<void> controlDevice(
    String id,
    String action, {
    String? mqttTopic,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/devices/$id/control'),
      headers: _headers,
      body: jsonEncode({
        'action': action,
        'state': action,
        'is_on': action.toUpperCase() == 'ON',
        if (mqttTopic != null && mqttTopic.isNotEmpty) 'mqtt_topic': mqttTopic,
      }),
    );
    _parseResponse(res);
  }

  Future<void> toggleDeviceApi(String deviceId, bool state) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/devices/$deviceId/control'),
      headers: _headers,
      body: jsonEncode({'state': state, 'action': state ? 'ON' : 'OFF'}),
    );
    _parseResponse(res);
  }

  // ==================== 3. ENERGY ====================

  Future<JsonMap> getEnergyStats(String range) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/energy/analytics?range=${range.toLowerCase()}'),
      headers: _headers,
    );
    final data = _parseResponse(res);
    if (data is Map) {
      return JsonMap.from(data);
    }
    if (data is List) {
      return {'chart': data};
    }
    return {};
  }

  // ==================== 4. AUTOMATIONS ====================

  Future<JsonList> getAutomations() async {
    final res = await http.get(
      Uri.parse('$_baseUrl/automations'),
      headers: _headers,
    );
    final data = _parseResponse(res);
    if (data is List) {
      return data.map((e) => JsonMap.from(e)).toList();
    }
    if (data is Map && data['automations'] is List) {
      return (data['automations'] as List).map((e) => JsonMap.from(e)).toList();
    }
    return [];
  }

  Future<void> createAutomation(
    String name,
    String conditionText,
    String actionText,
  ) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/automations'),
      headers: _headers,
      body: jsonEncode({
        'name': name,
        'condition_text': conditionText,
        'action_text': actionText,
      }),
    );
    _parseResponse(res);
  }

  Future<void> toggleAutomation(String id, bool isActive) async {
    final res = await http.patch(
      Uri.parse('$_baseUrl/automations/$id/toggle'),
      headers: _headers,
      body: jsonEncode({'is_active': isActive}),
    );
    _parseResponse(res);
  }

  Future<void> deleteAutomation(String id) async {
    final res = await http.delete(
      Uri.parse('$_baseUrl/automations/$id'),
      headers: _headers,
    );
    _parseResponse(res);
  }

  // ==================== 5. USERS & GUESTS (OWNER ONLY) ====================

  Future<JsonList> getUsers() async {
    final res = await http.get(Uri.parse('$_baseUrl/users'), headers: _headers);
    final data = _parseResponse(res);
    if (data is List) {
      return data.map((e) => JsonMap.from(e)).toList();
    }
    if (data is Map && data['users'] is List) {
      return (data['users'] as List).map((e) => JsonMap.from(e)).toList();
    }
    return [];
  }

  Future<void> createUser({
    required String fullName,
    required String email,
    required String password,
    required String role,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/users'),
      headers: _headers,
      body: jsonEncode({
        'name': fullName,
        'full_name': fullName,
        'email': email,
        'password': password,
        'role': role,
        'role_name': role,
      }),
    );
    _parseResponse(res);
  }

  Future<void> createGuest({
    required String fullName,
    required String email,
    required String password,
    required int durationHours,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/guests'),
      headers: _headers,
      body: jsonEncode({
        'name': fullName,
        'full_name': fullName,
        'email': email,
        'password': password,
        'role': 'Guest',
        'role_name': 'Guest',
        'duration_hours': durationHours,
      }),
    );
    _parseResponse(res);
  }

  Future<void> updateUser(
    String id, {
    String? fullName,
    String? role,
    bool? isActive,
    String? password,
  }) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/users/$id'),
      headers: _headers,
      body: jsonEncode({
        if (fullName != null) 'name': fullName,
        if (fullName != null) 'full_name': fullName,
        if (role != null) 'role': role,
        if (role != null) 'role_name': role,
        if (isActive != null) 'is_active': isActive,
        if (password != null && password.isNotEmpty) 'password': password,
      }),
    );
    _parseResponse(res);
  }

  Future<void> deleteUser(String id) async {
    final res = await http.delete(
      Uri.parse('$_baseUrl/users/$id'),
      headers: _headers,
    );
    _parseResponse(res);
  }

  Future<JsonList> getAiAlerts() async {
    final res = await http.get(
      Uri.parse('$_baseUrl/ai/alerts'),
      headers: _headers,
    );
    final data = _parseResponse(res);
    if (data is List) {
      return data.map((e) => JsonMap.from(e)).toList();
    }
    if (data is Map && data['alerts'] is List) {
      return (data['alerts'] as List).map((e) => JsonMap.from(e)).toList();
    }
    return [];
  }

  Future<void> triggerAiAnalysis() async {
    final res = await http.post(
      Uri.parse('$_baseUrl/ai/simulate-anomaly'),
      headers: _headers,
    );
    _parseResponse(res);
  }
}
