import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_service.dart';

class WebSocketService extends ChangeNotifier {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  String? _currentUrl;
  bool _manualDisconnect = false;

  final _sensorController = StreamController.broadcast();
  final _deviceController = StreamController.broadcast();
  final _aiAlertController = StreamController.broadcast();
  final _statusController = StreamController<bool>.broadcast();

  Stream get sensorStream => _sensorController.stream;
  Stream get deviceStream => _deviceController.stream;
  Stream get aiAlertStream => _aiAlertController.stream;
  Stream<bool> get statusStream => _statusController.stream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  void connect([String? wsUrl]) {
    final targetUrl = (wsUrl != null && wsUrl.trim().isNotEmpty)
        ? wsUrl.trim()
        : ApiService().wsUrl;

    if (_isConnected && _currentUrl == targetUrl) return;

    _manualDisconnect = false;
    _currentUrl = targetUrl;
    _reconnectTimer?.cancel();

    try {
      _channel?.sink.close();
      _channel = WebSocketChannel.connect(Uri.parse(targetUrl));
      _isConnected = true;
      _statusController.add(true);
      notifyListeners();

      _channel!.stream.listen(
        (message) => _handleIncomingMessage(message),
        onDone: _handleDisconnect,
        onError: (_) => _handleDisconnect(),
      );
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    _isConnected = false;
    _statusController.add(false);
    notifyListeners();

    if (!_manualDisconnect && _currentUrl != null) {
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(seconds: 4), () {
        if (!_manualDisconnect && !_isConnected) {
          connect(_currentUrl);
        }
      });
    }
  }

  void _handleIncomingMessage(dynamic rawMessage) {
    try {
      final dynamic decoded = jsonDecode(rawMessage.toString());
      if (decoded is! Map) return;

      final String? type = decoded['type']?.toString();
      final dynamic payload = decoded['data'];
      if (payload is! Map) return;

      final mapPayload = Map<String, dynamic>.from(payload);

      if (type == 'SENSOR_UPDATE') {
        _sensorController.add(mapPayload);
      } else if (type == 'DEVICE_UPDATE') {
        _deviceController.add(mapPayload);
      } else if (type == 'AI_ALERT') {
        // Lọc cảnh báo AI theo đúng hộ gia đình (Multi-tenant)
        final alertOwner = (mapPayload['owner_id'] ?? '').toString();
        final myOwner = ApiService().householdOwnerId;
        if (alertOwner.isEmpty || myOwner.isEmpty || alertOwner == myOwner) {
          _aiAlertController.add(mapPayload);
        }
      }
    } catch (e) {
      debugPrint('Lỗi parse JSON WebSocket: $e');
    }
  }

  void toggleDevice(String deviceId, bool newState) {
    if (_channel != null && _isConnected) {
      final payload = jsonEncode({
        'action': 'TOGGLE_DEVICE',
        'device_id': deviceId,
        'is_on': newState,
        'state': newState,
      });
      _channel!.sink.add(payload);
    }
  }

  void disconnect({bool temporary = false}) {
    _manualDisconnect = !temporary;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _isConnected = false;
    _statusController.add(false);
    notifyListeners();
  }
}
