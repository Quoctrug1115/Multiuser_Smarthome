import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/smarthome_models.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';

class EnergyScreen extends StatefulWidget {
  const EnergyScreen({super.key});

  @override
  State<EnergyScreen> createState() => _EnergyScreenState();
}

class _EnergyScreenState extends State<EnergyScreen> {
  final ApiService _api = ApiService();
  late WebSocketService _ws;
  bool _wsBound = false;

  StreamSubscription<dynamic>? _deviceSub;
  StreamSubscription<dynamic>? _sensorSub;
  Timer? _syncTimer;

  String _selectedRange = '24H'; // 24H | 7D | 30D
  bool _isLoading = true;
  String? _errorMessage;

  double _totalKwh = 0.0;
  double _estimatedCost = 0.0;
  final double _unitPriceVnd = 2500.0;
  double? _telemetryLiveWatt;

  List _chartBars = [];
  JsonList _devices = [];

  @override
  void initState() {
    super.initState();
    _loadEnergyData();
    // Tự động đồng bộ số liệu điện năng & trạng thái thiết bị mỗi 10 giây
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _loadEnergyData(silent: true);
    });
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
      _bindRealtime();
    }
  }

  void _bindRealtime() {
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
        for (final d in _devices) {
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

    _sensorSub = _ws.sensorStream.listen((raw) {
      if (!mounted || raw is! Map) return;
      final data = raw['data'] is Map ? raw['data'] as Map : raw;
      final p = data['power'] ?? data['watt'] ?? data['active_power'];
      if (p is num && p > 0) {
        setState(() {
          _telemetryLiveWatt = p.toDouble();
        });
      }
    });
  }

  double _toDouble(dynamic val, [double fallback = 0.0]) {
    if (val == null) return fallback;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? fallback;
  }

  Future<void> _loadEnergyData({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final results = await Future.wait([
        _api.getDevices().catchError((_) => <JsonMap>[]),
        _api.getEnergyStats(_selectedRange),
      ]);

      if (!mounted) return;

      final devicesList = results[0] as JsonList;
      final rawEnergy = results[1] as JsonMap;
      final map = rawEnergy['data'] is Map
          ? JsonMap.from(rawEnergy['data'] as Map)
          : rawEnergy;

      // Đọc chuỗi điểm biểu đồ từ Backend (/api/v1/energy/analytics)
      final rawSeries = map['daily'] ?? map['chart_data'] ?? map['chart'];
      final parsedBars = [];

      if (rawSeries is List && rawSeries.isNotEmpty) {
        for (final item in rawSeries) {
          if (item is Map) {
            parsedBars.add({
              'label': (item['label'] ?? item['date'] ?? '').toString(),
              'kwh': _toDouble(item['kwh'] ?? item['value']),
              'power_watt': _toDouble(item['power_watt']),
            });
          }
        }
      } else if (map['labels'] is List && map['kwh_data'] is List) {
        final labels = map['labels'] as List;
        final values = map['kwh_data'] as List;
        final len = labels.length < values.length
            ? labels.length
            : values.length;
        for (int i = 0; i < len; i++) {
          parsedBars.add({
            'label': labels[i].toString(),
            'kwh': _toDouble(values[i]),
          });
        }
      }

      final bars = parsedBars.isNotEmpty
          ? parsedBars
          : _buildDefaultBars(_selectedRange);

      double totalKwh = _toDouble(
        map['total_kwh'] ?? map['total_consumption'] ?? map['kwh'],
      );
      if (totalKwh <= 0 && bars.isNotEmpty) {
        totalKwh = bars.fold<double>(
          0.0,
          (sum, b) => sum + _toDouble(b['kwh']),
        );
      }

      double cost = _toDouble(
        map['estimated_cost'] ?? map['total_vnd'] ?? map['total_cost'],
      );
      if (cost <= 0 && totalKwh > 0) {
        cost = (totalKwh * _unitPriceVnd).roundToDouble();
      }

      setState(() {
        _devices = devicesList;
        _totalKwh = totalKwh;
        _estimatedCost = cost;
        _chartBars = bars;
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_chartBars.isEmpty) {
          _chartBars = _buildDefaultBars(_selectedRange);
        }
        _isLoading = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  List _buildDefaultBars(String range) {
    final now = DateTime.now();
    if (range == '24H') {
      return List.generate(24, (h) {
        final label = '${h.toString().padLeft(2, '0')}:00';
        return {'label': label, 'kwh': 0.0};
      });
    }
    final days = range == '30D' ? 30 : 7;
    return List.generate(days, (idx) {
      final d = now.subtract(Duration(days: (days - 1) - idx));
      final label =
          '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
      return {'label': label, 'kwh': 0.0};
    });
  }

  List<Device> get _loadDevices {
    return _devices
        .map((e) => Device.fromJson(e))
        .where((d) => d.ratedPowerWatt > 0)
        .toList();
  }

  double get _instantPowerWatt {
    double sum = 0.0;
    for (final d in _loadDevices) {
      if (d.isOn) {
        sum += d.ratedPowerWatt;
      }
    }
    if (sum > 0) return sum;
    return _telemetryLiveWatt ?? 0.0;
  }

  String _formatKwh(double val) {
    if (val > 0 && val < 0.01) return val.toStringAsFixed(4);
    if (val > 0 && val < 1.0) return val.toStringAsFixed(3);
    return val.toStringAsFixed(2);
  }

  String _formatBarKwh(double val) {
    if (val <= 0) return '0.0';
    if (val < 0.1) return val.toStringAsFixed(3);
    if (val < 1.0) return val.toStringAsFixed(2);
    return val.toStringAsFixed(1);
  }

  String _formatVnd(double amount) {
    final intVal = amount.round().toString();
    final reg = RegExp(r'\B(?=(\d{3})+(?!\d))');
    return '${intVal.replaceAllMapped(reg, (m) => '.')} đ';
  }

  @override
  void dispose() {
    _deviceSub?.cancel();
    _sensorSub?.cancel();
    _syncTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;
    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);
    final amber = isDark ? Colors.amber : const Color(0xFFD97706);

    final loadDevices = _loadDevices;
    final instantWatt = _instantPowerWatt;
    final totalCapacityWatt = loadDevices.fold<double>(
      0.0,
      (prev, d) => prev + d.ratedPowerWatt,
    );

    double peakKwh = 0.0;
    for (final b in _chartBars) {
      final v = _toDouble(b['kwh']);
      if (v > peakKwh) peakKwh = v;
    }
    final double maxBarScale = peakKwh > 0 ? peakKwh * 1.15 : 0.1;

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      body: RefreshIndicator(
        color: cyan,
        onRefresh: () => _loadEnergyData(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 90),
          children: [
            // HEADER & CHỌN CHU KỲ
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'PHÂN TÍCH ĐIỆN NĂNG',
                  style: TextStyle(
                    color: AppColors.getTextPrimary(isDark),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.6,
                  ),
                ),
                Row(
                  children: [
                    _buildRangeBtn('24H', '24H', cyan, isDark),
                    const SizedBox(width: 6),
                    _buildRangeBtn('7 NGÀY', '7D', cyan, isDark),
                    const SizedBox(width: 6),
                    _buildRangeBtn('30 NGÀY', '30D', cyan, isDark),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),

            if (_errorMessage != null) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.accent.withOpacity(0.45)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: AppColors.accent,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(
                          color: AppColors.accent,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: () => _loadEnergyData(),
                      child: Text(
                        'THỬ LẠI',
                        style: TextStyle(
                          color: cyan,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // 3 THẺ TỔNG QUAN ĐIỆN NĂNG & TẢI TỨC THỜI
            Row(
              children: [
                Expanded(
                  child: _buildMetricCard(
                    isDark: isDark,
                    icon: Icons.bolt,
                    color: cyan,
                    value: '${_formatKwh(_totalKwh)} kWh',
                    label: 'TỔNG TIÊU THỤ',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetricCard(
                    isDark: isDark,
                    icon: Icons.payments_outlined,
                    color: green,
                    value: _formatVnd(_estimatedCost),
                    label: 'CHI PHÍ ƯỚC TÍNH',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetricCard(
                    isDark: isDark,
                    icon: Icons.speed,
                    color: amber,
                    value: '${instantWatt.toStringAsFixed(0)} W',
                    label: 'TẢI TỨC THỜI',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // BIỂU ĐỒ TIÊU THỤ (kWh)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.getSurface(isDark),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cyan.withOpacity(0.35)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _selectedRange == '24H'
                            ? 'BIỂU ĐỒ THEO GIỜ (kWh)'
                            : 'BIỂU ĐỒ TIÊU THỤ (kWh)',
                        style: TextStyle(
                          color: AppColors.getTextPrimary(isDark),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${_formatVnd(_unitPriceVnd)}/kWh',
                        style: TextStyle(
                          color: green,
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  if (_chartBars.length > 7) ...[
                    const SizedBox(height: 4),
                    const Text(
                      'Vuốt ngang biểu đồ để xem đầy đủ các mốc thời gian',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 140,
                    child: _chartBars.length <= 7
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: _chartBars.map((bar) {
                              return Expanded(
                                child: _buildBarColumn(
                                  bar: bar,
                                  peakKwh: peakKwh,
                                  maxBarScale: maxBarScale,
                                  cyan: cyan,
                                  amber: amber,
                                  isDark: isDark,
                                ),
                              );
                            }).toList(),
                          )
                        : SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: _chartBars.map((bar) {
                                return SizedBox(
                                  width: 42,
                                  child: _buildBarColumn(
                                    bar: bar,
                                    peakKwh: peakKwh,
                                    maxBarScale: maxBarScale,
                                    cyan: cyan,
                                    amber: amber,
                                    isDark: isDark,
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // PHÂN BỔ CÔNG SUẤT THIẾT BỊ (W và %)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'PHÂN BỔ CÔNG SUẤT THIẾT BỊ (${loadDevices.length})',
                  style: TextStyle(
                    color: AppColors.getTextPrimary(isDark),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                if (totalCapacityWatt > 0)
                  Text(
                    'Tổng định mức: ${totalCapacityWatt.toStringAsFixed(0)} W',
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 10.5,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            if (_isLoading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator(color: cyan)),
              )
            else if (loadDevices.isEmpty)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.getSurface(isDark),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text(
                  'Chưa có thiết bị tiêu thụ điện nào được cấu hình.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
              )
            else
              ...loadDevices.map((dev) {
                final activeW = dev.isOn ? dev.ratedPowerWatt : 0.0;
                final pct = (dev.isOn && instantWatt > 0)
                    ? ((activeW / instantWatt) * 100).round()
                    : 0;
                final progress = (pct / 100).clamp(0.0, 1.0);

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.getSurface(isDark),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: dev.isOn
                          ? cyan.withOpacity(0.45)
                          : (isDark ? Colors.white12 : Colors.black12),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              dev.name,
                              style: TextStyle(
                                color: AppColors.getTextPrimary(isDark),
                                fontSize: 13.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Text(
                            '${activeW.toStringAsFixed(0)} W ($pct%)',
                            style: TextStyle(
                              color: dev.isOn ? cyan : AppColors.textMuted,
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 6,
                          backgroundColor: isDark
                              ? Colors.white10
                              : Colors.black12,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            dev.isOn ? cyan : AppColors.textMuted,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            dev.isOn ? 'Đang hoạt động' : 'Đang tắt',
                            style: TextStyle(
                              color: dev.isOn ? green : AppColors.textMuted,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'Công suất định mức: ${dev.ratedPowerWatt.toStringAsFixed(0)} W',
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
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

  Widget _buildBarColumn({
    required Map<String, dynamic> bar,
    required double peakKwh,
    required double maxBarScale,
    required Color cyan,
    required Color amber,
    required bool isDark,
  }) {
    final kwh = _toDouble(bar['kwh']);
    final label = (bar['label'] ?? '').toString();
    final isPeak = peakKwh > 0 && kwh >= peakKwh;
    final barColor = isPeak ? amber : cyan;
    final ratio = maxBarScale > 0 ? (kwh / maxBarScale).clamp(0.0, 1.0) : 0.0;
    final barHeight = kwh > 0 ? (14.0 + ratio * 82.0) : 6.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            _formatBarKwh(kwh),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: kwh > 0 ? barColor : AppColors.textMuted,
              fontSize: 9,
              fontWeight: kwh > 0 ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            height: barHeight,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [barColor, barColor.withOpacity(0.35)],
              ),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.getTextSecondary(isDark),
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRangeBtn(String label, String value, Color cyan, bool isDark) {
    final active = _selectedRange == value;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        if (_selectedRange == value) return;
        setState(() => _selectedRange = value);
        _loadEnergyData();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? cyan : AppColors.getSurface(isDark),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? cyan : (isDark ? Colors.white12 : Colors.black12),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active
                ? (isDark ? const Color(0xFF0A0E1A) : Colors.white)
                : AppColors.getTextSecondary(isDark),
            fontSize: 10.5,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildMetricCard({
    required bool isDark,
    required IconData icon,
    required Color color,
    required String value,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 8),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.getTextPrimary(isDark),
              fontSize: 13.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
