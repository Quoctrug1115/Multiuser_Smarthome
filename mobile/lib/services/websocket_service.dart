import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocketService extends ChangeNotifier {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _channel;

  // Khai báo chính xác >
  final _sensorController = StreamController<Map<String, dynamic>>.broadcast();
  final _deviceController = StreamController<Map<String, dynamic>>.broadcast();
  final _statusController = StreamController<bool>.broadcast();

  Stream<Map<String, dynamic>> get sensorStream => _sensorController.stream;
  Stream<Map<String, dynamic>> get deviceStream => _deviceController.stream;
  Stream<bool> get statusStream => _statusController.stream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  void connect(String wsUrl) {
    if (_isConnected) return;

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _isConnected = true;
      _statusController.add(true);
      notifyListeners();

      _channel!.stream.listen(
        (message) => _handleIncomingMessage(message),
        onDone: () {
          _isConnected = false;
          _statusController.add(false);
          notifyListeners();
        },
        onError: (error) {
          _isConnected = false;
          _statusController.add(false);
          notifyListeners();
        },
      );
    } catch (e) {
      _isConnected = false;
      _statusController.add(false);
      notifyListeners();
    }
  }

  void _handleIncomingMessage(dynamic rawMessage) {
    try {
      final Map<String, dynamic> data = jsonDecode(rawMessage);
      final String? type = data['type'];
      final dynamic payload = data['data'];

      if (type == 'SENSOR_UPDATE' && payload != null) {
        _sensorController.add(Map<String, dynamic>.from(payload));
      } else if (type == 'DEVICE_UPDATE' && payload != null) {
        _deviceController.add(Map<String, dynamic>.from(payload));
      }
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Lỗi parse JSON: $e');
    }
  }

  void toggleDevice(String deviceId, bool newState) {
    if (_channel != null && _isConnected) {
      final payload = jsonEncode({
        'action': 'TOGGLE_DEVICE',
        'device_id': deviceId,
        'state': newState,
      });
      _channel!.sink.add(payload);
    }
  }

  void disconnect() {
    _channel?.sink.close();
    _isConnected = false;
    _statusController.add(false);
    notifyListeners();
  }
}
