import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/smarthome_models.dart';

typedef JsonMap = Map<String, dynamic>;
typedef JsonList = List<JsonMap>;

class ApiService extends ChangeNotifier {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _baseUrl = 'http://127.0.0.1:3000/api/v1';
    }
  }

  String _baseUrl = 'http://localhost:3000/api/v1';
  String? _token;
  JsonMap? _currentUser;

  String get baseUrl => _baseUrl;
  String? get token => _token;
  JsonMap? get currentUser => _currentUser;
  UserProfile? get userProfile =>
      _currentUser != null ? UserProfile.fromJson(_currentUser!) : null;

  bool get isAuthenticated => _token != null && _token!.isNotEmpty;

  /// Tự động suy ra WebSocket URL tương ứng từ REST API Base URL
  String get wsUrl {
    String root = _baseUrl;
    if (root.endsWith('/api/v1')) {
      root = root.substring(0, root.length - 7);
    }
    if (root.startsWith('https://')) {
      root = root.replaceFirst('https://', 'wss://');
    } else if (root.startsWith('http://')) {
      root = root.replaceFirst('http://', 'ws://');
    }
    return '$root/ws';
  }

  /// ID của Chủ hộ (dùng để lọc cảnh báo AI & dữ liệu Multi-tenant)
  String get householdOwnerId {
    final ownerId = _currentUser?['owner_id']?.toString() ?? '';
    if (ownerId.isNotEmpty) return ownerId;
    return _currentUser?['id']?.toString() ?? '';
  }

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
    if (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
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
    if (res.statusCode == 401) {
      logout();
      throw Exception('Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.');
    }

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
          'id': data['id'] ?? jwtClaims['sub'] ?? jwtClaims['id'] ?? '',
          'owner_id': data['owner_id'] ?? jwtClaims['owner_id'] ?? '',
          'email': data['email'] ?? jwtClaims['email'] ?? email,
          'name':
              data['name'] ??
              data['full_name'] ??
              jwtClaims['name'] ??
              email.split('@').first,
          'full_name':
              data['full_name'] ??
              data['name'] ??
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
      // Đồng bộ lại thông tin mới nhất từ /auth/me
      await fetchCurrentUser().catchError((_) {});
    }
  }

  /// Đăng ký tài khoản Chủ nhà (Owner) mới giống luồng Web
  Future<void> register(String fullName, String email, String password) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': fullName,
        'full_name': fullName,
        'email': email,
        'password': password,
      }),
    );
    _parseResponse(res);
  }

  Future<void> fetchCurrentUser() async {
    if (!isAuthenticated) return;
    final res = await http.get(
      Uri.parse('$_baseUrl/auth/me'),
      headers: _headers,
    );
    final data = _parseResponse(res);
    if (data is Map) {
      final userMap = data['user'] is Map
          ? JsonMap.from(data['user'])
          : JsonMap.from(data);
      _currentUser = {...?_currentUser, ...userMap};
      notifyListeners();
    }
  }

  Future<JsonMap> forgotPassword(String email) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/forgot-password'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email.trim()}),
    );
    final data = _parseResponse(res);
    if (data is Map) {
      return JsonMap.from(data);
    }
    return {'message': 'Mã OTP đã được gửi.'};
  }

  Future<String> resetPassword({
    required String email,
    required String otp,
    required String newPassword,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/reset-password'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim(),
        'otp': otp.trim(),
        'new_password': newPassword,
      }),
    );
    final data = _parseResponse(res);
    if (data is Map && data['message'] != null) {
      return data['message'].toString();
    }
    return 'Đặt lại mật khẩu thành công.';
  }

  void logout() {
    _token = null;
    _currentUser = null;
    notifyListeners();
  }

  // ==================== 2. HOUSES & ROOMS (MULTI-TENANT) ====================

  Future<JsonList> getHouses() async {
    final res = await http.get(
      Uri.parse('$_baseUrl/houses'),
      headers: _headers,
    );
    final data = _parseResponse(res);
    if (data is List) return data.map((e) => JsonMap.from(e)).toList();
    if (data is Map && data['houses'] is List) {
      return (data['houses'] as List).map((e) => JsonMap.from(e)).toList();
    }
    return [];
  }

  Future<void> createHouse({
    required String name,
    required String address,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/houses'),
      headers: _headers,
      body: jsonEncode({'name': name, 'address': address}),
    );
    _parseResponse(res);
  }

  Future<void> updateHouse(
    String houseId, {
    required String name,
    required String address,
  }) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/houses/$houseId'),
      headers: _headers,
      body: jsonEncode({'name': name, 'address': address}),
    );
    _parseResponse(res);
  }

  Future<void> deleteHouse(String houseId) async {
    final res = await http.delete(
      Uri.parse('$_baseUrl/houses/$houseId'),
      headers: _headers,
    );
    _parseResponse(res);
  }

  Future<JsonList> getRooms() async {
    final res = await http.get(Uri.parse('$_baseUrl/rooms'), headers: _headers);
    final data = _parseResponse(res);
    if (data is List) return data.map((e) => JsonMap.from(e)).toList();
    if (data is Map && data['rooms'] is List) {
      return (data['rooms'] as List).map((e) => JsonMap.from(e)).toList();
    }
    return [];
  }

  Future<void> createRoom({
    required String houseId,
    required String name,
    int floor = 1,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/rooms'),
      headers: _headers,
      body: jsonEncode({'house_id': houseId, 'name': name, 'floor': floor}),
    );
    _parseResponse(res);
  }

  Future<void> updateRoom(
    String roomId, {
    required String houseId,
    required String name,
    int floor = 1,
  }) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/rooms/$roomId'),
      headers: _headers,
      body: jsonEncode({'house_id': houseId, 'name': name, 'floor': floor}),
    );
    _parseResponse(res);
  }

  Future<void> deleteRoom(String roomId) async {
    final res = await http.delete(
      Uri.parse('$_baseUrl/rooms/$roomId'),
      headers: _headers,
    );
    _parseResponse(res);
  }

  // ==================== 3. DEVICES (CRUD + CONTROL) ====================

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
    String? roomId,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/devices'),
      headers: _headers,
      body: jsonEncode({
        'name': name,
        'device_type': deviceType,
        'mqtt_topic': mqttTopic,
        if (roomId != null && roomId.isNotEmpty) 'room_id': roomId,
      }),
    );
    _parseResponse(res);
  }

  Future<void> updateDevice(
    String deviceId, {
    required String name,
    required String deviceType,
    required String mqttTopic,
    String? roomId,
  }) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/devices/$deviceId'),
      headers: _headers,
      body: jsonEncode({
        'name': name,
        'device_type': deviceType,
        'mqtt_topic': mqttTopic,
        if (roomId != null && roomId.isNotEmpty) 'room_id': roomId,
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
    final isOn = action.toUpperCase() == 'ON';
    final res = await http.post(
      Uri.parse('$_baseUrl/devices/$id/control'),
      headers: _headers,
      body: jsonEncode({
        'action': isOn ? 'ON' : 'OFF',
        'state': isOn ? 'ON' : 'OFF',
        'is_on': isOn,
        if (mqttTopic != null && mqttTopic.isNotEmpty) 'mqtt_topic': mqttTopic,
      }),
    );
    _parseResponse(res);
  }

  Future<void> toggleDeviceApi(String deviceId, bool state) async {
    await controlDevice(deviceId, state ? 'ON' : 'OFF');
  }

  // ==================== 4. ENERGY ====================

  Future<JsonMap> getEnergyStats(String range) async {
    final period = range.toLowerCase();
    final res = await http.get(
      Uri.parse('$_baseUrl/energy/analytics?period=$period&range=$period'),
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

  // ==================== 5. AUTOMATIONS ====================

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
    final uri = Uri.parse('$_baseUrl/automations/$id/toggle');
    final body = jsonEncode({'is_active': isActive});
    var res = await http.post(uri, headers: _headers, body: body);
    if (res.statusCode == 405 || res.statusCode == 404) {
      res = await http.patch(uri, headers: _headers, body: body);
    }
    _parseResponse(res);
  }

  Future<void> deleteAutomation(String id) async {
    final res = await http.delete(
      Uri.parse('$_baseUrl/automations/$id'),
      headers: _headers,
    );
    _parseResponse(res);
  }

  // ==================== 6. USERS & AI ALERTS ====================

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

  String? _resolvedAlertsPath;

  /// Lấy danh sách cảnh báo AI thật từ SQL Server
  Future<JsonList> getAiAlerts() async {
    final paths = <String>[
      if (_resolvedAlertsPath != null) _resolvedAlertsPath!,
      '/ai/alerts',
      '/ai_alerts',
      '/ai-alerts',
      '/anomalies',
      '/alerts',
    ];

    http.Response? lastResponse;
    for (final path in paths) {
      final res = await http.get(
        Uri.parse('$_baseUrl$path'),
        headers: _headers,
      );
      lastResponse = res;
      if (res.statusCode >= 200 && res.statusCode < 300) {
        _resolvedAlertsPath = path;
        final decoded = jsonDecode(res.body);
        if (decoded is List) {
          return decoded
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
        if (decoded is Map) {
          final list = decoded['data'] ?? decoded['alerts'] ?? decoded['items'];
          if (list is List) {
            return list
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          }
        }
        return [];
      }
      if (res.statusCode != 404) {
        break;
      }
    }

    throw Exception(
      'Không thể tải lịch sử cảnh báo (${lastResponse?.statusCode ?? 404})',
    );
  }

  /// Kiểm thử bất thường Z-Score dựa trên thiết bị & chuỗi dữ liệu cảm biến THẬT
  Future<JsonMap> triggerAiAnalysis({
    String? deviceId,
    double? temperature,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/ai/simulate-anomaly'),
      headers: _headers,
      body: jsonEncode({
        if (deviceId != null && deviceId.trim().isNotEmpty)
          'device_id': deviceId.trim(),
        if (temperature != null) 'temperature': temperature,
      }),
    );
    final data = _parseResponse(res);
    return data is Map ? JsonMap.from(data) : {};
  }

  // ==================== 7. AI SUGGESTIONS (GỢI Ý THÔNG MINH) ====================

  /// Lấy danh sách gợi ý AI đang chờ duyệt của hộ gia đình
  Future<JsonList> getAiSuggestions() async {
    final res = await http.get(
      Uri.parse('$_baseUrl/ai/suggestions'),
      headers: _headers,
    );
    final data = _parseResponse(res);
    if (data is List) {
      return data.map((e) => JsonMap.from(e as Map)).toList();
    }
    if (data is Map && data['data'] is List) {
      return (data['data'] as List).map((e) => JsonMap.from(e as Map)).toList();
    }
    return [];
  }

  /// Kích hoạt AI quét lịch sử điều khiển & cảm biến thật để sinh gợi ý mới
  Future<JsonMap> analyzeAiSuggestions() async {
    final res = await http.post(
      Uri.parse('$_baseUrl/ai/suggestions/analyze'),
      headers: _headers,
    );
    final data = _parseResponse(res);
    return data is Map ? JsonMap.from(data) : {};
  }

  /// Chấp nhận & thực thi gợi ý (bật/tắt ngay hoặc tự tạo kịch bản tự động)
  Future<JsonMap> applyAiSuggestion(String id) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/ai/suggestions/$id/apply'),
      headers: _headers,
    );
    final data = _parseResponse(res);
    return data is Map ? JsonMap.from(data) : {};
  }

  /// Bỏ qua gợi ý để AI ghi nhận phản hồi
  Future<void> dismissAiSuggestion(String id) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/ai/suggestions/$id/dismiss'),
      headers: _headers,
    );
    _parseResponse(res);
  }
}
