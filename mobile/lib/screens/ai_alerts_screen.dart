import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/smarthome_models.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';

class AiAlertsScreen extends StatefulWidget {
  final VoidCallback? onViewed;

  const AiAlertsScreen({super.key, this.onViewed});

  @override
  State<AiAlertsScreen> createState() => _AiAlertsScreenState();
}

class _AiAlertsScreenState extends State<AiAlertsScreen> {
  final ApiService _api = ApiService();
  late WebSocketService _ws;
  bool _wsBound = false;

  List<AiAlert> _alerts = [];
  JsonList _realDevices = [];
  JsonList _realRooms = [];

  bool _isLoading = true;
  String? _errorMessage;
  String _selectedSeverity = 'ALL'; // ALL | HIGH | WARNING

  // Chỉ số thực tế nhận từ cảm biến & thiết bị thật qua WebSocket/API
  double? _liveTemp;
  double? _liveHumidity;
  double? _liveLux;
  final List<double> _tempHistory = [];
  DateTime? _lastRealtimeAlertAt;

  StreamSubscription<dynamic>? _alertSub;
  StreamSubscription<dynamic>? _sensorSub;
  StreamSubscription<dynamic>? _deviceSub;

  @override
  void initState() {
    super.initState();
    _loadRealData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_wsBound) {
      _wsBound = true;
      try {
        _ws = Provider.of<WebSocketService>(context, listen: false);
      } catch (_) {
        _ws = WebSocketService();
      }
      if (_api.isAuthenticated && !_ws.isConnected) {
        _ws.connect(_api.wsUrl);
      }
      _bindRealtimeStreams();
    }
  }

  void _bindRealtimeStreams() {
    // 1. Lắng nghe cảnh báo AI thật phát từ Backend Rust qua WebSocket
    _alertSub = _ws.aiAlertStream.listen((raw) {
      if (!mounted) return;
      final incoming = AiAlert.fromJson(raw);
      setState(() {
        if (incoming.id.isEmpty ||
            !_alerts.any((existing) => existing.id == incoming.id)) {
          _alerts.insert(0, incoming);
        }
      });
      widget.onViewed?.call();
    });

    // 2. Lắng nghe dữ liệu cảm biến thật (MQTT -> WebSocket) và phân tích Z-Score thực tế
    _sensorSub = _ws.sensorStream.listen((raw) {
      if (!mounted || raw is! Map) return;
      final data = raw['data'] is Map ? raw['data'] as Map : raw;

      final temp = (data['temperature'] as num?)?.toDouble();
      final hum = (data['humidity'] as num?)?.toDouble();
      final lux = ((data['lux'] ?? data['light']) as num?)?.toDouble();

      setState(() {
        if (temp != null) _liveTemp = temp;
        if (hum != null) _liveHumidity = hum;
        if (lux != null) _liveLux = lux;
      });

      if (temp != null) {
        _evaluateRealSensorAnomaly(temp);
      }
    });

    // 3. Cập nhật trạng thái bật/tắt thiết bị thật để tính công suất tải thực tế
    _deviceSub = _ws.deviceStream.listen((raw) {
      if (!mounted || raw == null) return;
      String incomingId = '';
      String topic = '';
      bool isOn = false;

      if (raw is Map) {
        final data = raw['data'] is Map ? raw['data'] as Map : raw;
        incomingId = (data['id'] ?? data['device_id'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        topic = (data['mqtt_topic'] ?? '').toString().trim().toLowerCase();
        final rawState = data['is_on'] ?? data['status'] ?? data['state'];
        isOn = rawState is bool
            ? rawState
            : [
                'on',
                'true',
                '1',
                'active',
              ].contains((rawState ?? '').toString().trim().toLowerCase());
      } else {
        try {
          incomingId = (raw.id ?? '').toString().trim().toLowerCase();
          topic = (raw.mqttTopic ?? '').toString().trim().toLowerCase();
          isOn = raw.isOn == true;
        } catch (_) {
          return;
        }
      }

      setState(() {
        for (final d in _realDevices) {
          final localId = (d['id'] ?? '').toString().trim().toLowerCase();
          final localTopic = (d['mqtt_topic'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          if ((incomingId.isNotEmpty && localId == incomingId) ||
              (topic.isNotEmpty && localTopic == topic)) {
            d['is_on'] = isOn;
            d['status'] = isOn ? 'ON' : 'OFF';
          }
        }
      });
    });
  }

  /// Tính Z-Score trên chuỗi dữ liệu nhiệt độ thực tế từ cảm biến
  void _evaluateRealSensorAnomaly(double currentTemp) {
    double? zScore;
    if (_tempHistory.length >= 5) {
      final mean = _tempHistory.reduce((a, b) => a + b) / _tempHistory.length;
      final variance =
          _tempHistory
              .map((x) => math.pow(x - mean, 2))
              .reduce((a, b) => a + b) /
          _tempHistory.length;
      final stdDev = math.sqrt(variance);
      if (stdDev > 0.1) {
        zScore = (currentTemp - mean) / stdDev;
      }
    }

    _tempHistory.add(currentTemp);
    if (_tempHistory.length > 30) {
      _tempHistory.removeAt(0);
    }

    final isOverheat = currentTemp >= 45.0;
    final isStatisticalSpike = zScore != null && zScore.abs() >= 2.8;

    if (isOverheat || isStatisticalSpike) {
      final now = DateTime.now();
      if (_lastRealtimeAlertAt != null &&
          now.difference(_lastRealtimeAlertAt!).inSeconds < 15) {
        return;
      }
      _lastRealtimeAlertAt = now;

      final sensor = _pickRealSensor();
      final sensorName = sensor != null
          ? (sensor['name'] ?? sensor['mqtt_topic'] ?? 'Cảm biến môi trường')
                .toString()
          : 'Cảm biến môi trường';
      final roomName = sensor != null
          ? (sensor['room_name'] ??
                    _resolveRoomNameById(sensor['room_id']?.toString()))
                .toString()
          : '';

      final realtimeAlert = AiAlert(
        id: 'rt_${now.millisecondsSinceEpoch}',
        title: isOverheat
            ? 'Cảnh báo quá nhiệt thực tế'
            : 'Phát hiện biến động nhiệt độ bất thường',
        message:
            'Ghi nhận nhiệt độ thực tế ${currentTemp.toStringAsFixed(1)}°C tại $sensorName.',
        severity: isOverheat ? 'HIGH' : 'WARNING',
        deviceName: sensorName,
        roomName: roomName.isNotEmpty ? roomName : null,
        sensorType: 'temperature',
        sensorValue: currentTemp,
        zScore: zScore,
        createdAt: now.toIso8601String(),
      );

      setState(() {
        _alerts.insert(0, realtimeAlert);
      });
      widget.onViewed?.call();

      // Đồng bộ thêm các bản ghi mới từ Backend SQL Server
      _loadRealData(silent: true);
    }
  }

  Future<void> _loadRealData({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final results = await Future.wait([
        _api.getAiAlerts(),
        _api.getDevices().catchError((_) => <JsonMap>[]),
        _api.getRooms().catchError((_) => <JsonMap>[]),
      ]);

      if (!mounted) return;
      final serverAlerts = results[0].map((e) => AiAlert.fromJson(e)).toList();

      // Giữ lại các cảnh báo realtime vừa ghi nhận nếu server chưa kịp đồng bộ
      final localRealtime = _alerts
          .where((a) => a.id.startsWith('rt_'))
          .where(
            (rt) => !serverAlerts.any(
              (srv) =>
                  srv.message == rt.message && srv.createdAt == rt.createdAt,
            ),
          )
          .toList();

      setState(() {
        _alerts = [...localRealtime, ...serverAlerts];
        _realDevices = results[1];
        _realRooms = results[2];
        _isLoading = false;
        _errorMessage = null;
      });
      widget.onViewed?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  String _resolveRoomNameById(String? roomId) {
    if (roomId == null || roomId.isEmpty) return '';
    for (final r in _realRooms) {
      if ((r['id'] ?? '').toString() == roomId) {
        return (r['name'] ?? '').toString();
      }
    }
    return '';
  }

  JsonMap? _pickRealSensor() {
    if (_realDevices.isEmpty) return null;
    for (final d in _realDevices) {
      final type = (d['device_type'] ?? '').toString().toLowerCase();
      final topic = (d['mqtt_topic'] ?? '').toString().toLowerCase();
      if (type == 'sensor' ||
          topic.contains('dht') ||
          topic.contains('sensor') ||
          topic.contains('temp')) {
        return d;
      }
    }
    return _realDevices.first;
  }

  double get _activePowerWatt {
    double total = 0.0;
    for (final raw in _realDevices) {
      final dev = Device.fromJson(raw);
      if (dev.isOn) {
        total += dev.ratedPowerWatt;
      }
    }
    return total;
  }

  List<AiAlert> get _filteredAlerts {
    if (_selectedSeverity == 'ALL') return _alerts;
    return _alerts.where((a) {
      final sev = a.severity.trim().toUpperCase();
      if (_selectedSeverity == 'HIGH') {
        return sev == 'HIGH' || sev == 'CRITICAL';
      }
      return sev == 'WARNING' || sev == 'MEDIUM';
    }).toList();
  }

  String _formatTimestamp(String raw) {
    if (raw.trim().isEmpty) return 'Vừa xong';
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) {
      final local = parsed.toLocal();
      final hh = local.hour.toString().padLeft(2, '0');
      final mm = local.minute.toString().padLeft(2, '0');
      final ss = local.second.toString().padLeft(2, '0');
      final dd = local.day.toString().padLeft(2, '0');
      final mo = local.month.toString().padLeft(2, '0');
      return '$hh:$mm:$ss $dd/$mo';
    }
    return raw;
  }

  Color _severityColor(String severity, Color cyan) {
    switch (severity.trim().toLowerCase()) {
      case 'critical':
      case 'high':
        return AppColors.accent;
      case 'medium':
      case 'warning':
        return Colors.amber;
      default:
        return cyan;
    }
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    _sensorSub?.cancel();
    _deviceSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;
    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);
    final amber = isDark ? Colors.amber : const Color(0xFFD97706);

    final sensor = _pickRealSensor();
    final filtered = _filteredAlerts;
    final wsConnected = _ws.isConnected;

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      body: RefreshIndicator(
        color: cyan,
        onRefresh: () => _loadRealData(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 90),
          children: [
            // 1. KHỐI GIÁM SÁT BẤT THƯỜNG AI TỪ DỮ LIỆU THỰC TẾ
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.getSurface(isDark),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cyan.withOpacity(0.45)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.psychology, color: cyan, size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'GIÁM SÁT BẤT THƯỜNG AI (Z-SCORE)',
                          style: TextStyle(
                            color: AppColors.getTextPrimary(isDark),
                            fontSize: 13.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: (wsConnected ? green : amber).withOpacity(
                            0.16,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: (wsConnected ? green : amber).withOpacity(
                              0.5,
                            ),
                          ),
                        ),
                        child: Text(
                          wsConnected ? 'LIVE MQTT' : 'ĐỒNG BỘ API',
                          style: TextStyle(
                            color: wsConnected ? green : amber,
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Phân tích trực tiếp luồng dữ liệu cảm biến môi trường và công suất tải thực tế của hộ gia đình.',
                    style: TextStyle(
                      color: AppColors.getTextSecondary(isDark),
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  if (sensor != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Nguồn cảm biến: ${sensor['name'] ?? sensor['mqtt_topic']}',
                      style: TextStyle(
                        color: green,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  // Hàng chỉ số cảm biến thực tế đang đo
                  Row(
                    children: [
                      Expanded(
                        child: _buildLiveMetricBox(
                          isDark: isDark,
                          label: 'NHIỆT ĐỘ',
                          value: _liveTemp != null
                              ? '${_liveTemp!.toStringAsFixed(1)}°C'
                              : '-- °C',
                          color: (_liveTemp ?? 0) >= 45
                              ? AppColors.accent
                              : amber,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildLiveMetricBox(
                          isDark: isDark,
                          label: 'ĐỘ ẨM',
                          value: _liveHumidity != null
                              ? '${_liveHumidity!.toStringAsFixed(0)}%'
                              : '-- %',
                          color: cyan,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildLiveMetricBox(
                          isDark: isDark,
                          label: 'CÔNG SUẤT TẢI',
                          value: () {
                            final totalCap = _realDevices
                                .map((e) => Device.fromJson(e))
                                .where(
                                  (d) => d.deviceType.toLowerCase() != 'sensor',
                                )
                                .fold<double>(
                                  0.0,
                                  (sum, d) => sum + d.ratedPowerWatt,
                                );
                            final pct = totalCap > 0
                                ? ((_activePowerWatt / totalCap) * 100).round()
                                : 0;
                            return '${_activePowerWatt.toStringAsFixed(0)} W ($pct%)';
                          }(),
                          color: green,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 2. BỘ LỌC MỨC ĐỘ CẢNH BÁO
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildFilterPill(
                    'Tất cả (${_alerts.length})',
                    _selectedSeverity == 'ALL',
                    cyan,
                    isDark,
                    () => setState(() => _selectedSeverity = 'ALL'),
                  ),
                  _buildFilterPill(
                    'Mức cao (HIGH)',
                    _selectedSeverity == 'HIGH',
                    AppColors.accent,
                    isDark,
                    () => setState(() => _selectedSeverity = 'HIGH'),
                  ),
                  _buildFilterPill(
                    'Cảnh báo (WARNING)',
                    _selectedSeverity == 'WARNING',
                    amber,
                    isDark,
                    () => setState(() => _selectedSeverity = 'WARNING'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // 3. THANH TIÊU ĐỀ LỊCH SỬ CẢNH BÁO THẬT
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'LỊCH SỬ CẢNH BÁO THỰC TẾ (${filtered.length})',
                  style: TextStyle(
                    color: AppColors.getTextPrimary(isDark),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                InkWell(
                  onTap: () => _loadRealData(),
                  child: Text(
                    'LÀM MỚI',
                    style: TextStyle(
                      color: cyan,
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 4. DANH SÁCH CẢNH BÁO TỪ SQL SERVER & REALTIME
            if (_isLoading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator(color: cyan)),
              )
            else if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.getSurface(isDark),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.accent.withOpacity(0.5)),
                ),
                child: Column(
                  children: [
                    Text(
                      _errorMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () => _loadRealData(),
                      child: const Text('THỬ TẢI LẠI'),
                    ),
                  ],
                ),
              )
            else if (filtered.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 34,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: AppColors.getSurface(isDark),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDark ? Colors.white12 : Colors.black12,
                  ),
                ),
                child: Column(
                  children: [
                    Icon(Icons.verified_user_outlined, color: green, size: 32),
                    const SizedBox(height: 10),
                    Text(
                      'Hệ thống an toàn — Chưa ghi nhận cảnh báo bất thường thực tế nào.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.getTextSecondary(isDark),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              )
            else
              ...filtered.map((alert) {
                final badgeColor = _severityColor(alert.severity, cyan);
                final severityLabel = alert.severity.trim().isEmpty
                    ? 'HIGH'
                    : alert.severity.toUpperCase();

                final metaParts = <String>[];
                if (alert.deviceName != null &&
                    alert.deviceName!.trim().isNotEmpty) {
                  metaParts.add('Thiết bị: ${alert.deviceName}');
                }
                if (alert.roomName != null &&
                    alert.roomName!.trim().isNotEmpty) {
                  metaParts.add('Phòng: ${alert.roomName}');
                }
                if (alert.sensorValue != null) {
                  metaParts.add(
                    'Giá trị đo: ${alert.sensorValue!.toStringAsFixed(1)}',
                  );
                }
                if (alert.zScore != null) {
                  metaParts.add('Z-Score: ${alert.zScore!.toStringAsFixed(2)}');
                }

                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.getSurface(isDark),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: badgeColor.withOpacity(0.45)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: badgeColor,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              alert.title,
                              style: TextStyle(
                                color: AppColors.getTextPrimary(isDark),
                                fontSize: 13.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: badgeColor.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              severityLabel,
                              style: TextStyle(
                                color: badgeColor,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (alert.message.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          alert.message,
                          style: TextStyle(
                            color: AppColors.getTextSecondary(isDark),
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                      if (metaParts.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          metaParts.join(' • '),
                          style: TextStyle(
                            color: cyan,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        'Thời gian: ${_formatTimestamp(alert.createdAt)}',
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveMetricBox({
    required bool isDark,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.getBackground(isDark),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterPill(
    String label,
    bool selected,
    Color color,
    bool isDark,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? color.withOpacity(0.2)
                : AppColors.getSurface(isDark),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? color
                  : (isDark ? Colors.white12 : Colors.black12),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? color : AppColors.getTextSecondary(isDark),
              fontSize: 11,
              fontWeight: selected ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
