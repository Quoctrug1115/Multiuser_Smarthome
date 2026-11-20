import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
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

  String _selectedRange = '7D'; // 24H | 7D | 30D
  bool _isLoading = true;

  double _totalKwh = 0.0;
  double _estimatedCost = 0.0;
  double _unitPriceVnd = 2500.0;
  double? _telemetryLiveWatt;

  List _chartBars = [];
  JsonList _devices = [];

  @override
  void initState() {
    super.initState();
    _loadEnergyData();
    _syncTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      _syncDevicesSilently();
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

  Future<void> _syncDevicesSilently() async {
    try {
      final list = await _api.getDevices();
      if (!mounted) return;
      setState(() {
        _devices = list;
      });
    } catch (_) {}
  }

  Future<void> _loadEnergyData() async {
    setState(() => _isLoading = true);
    try {
      final devicesFuture = _api.getDevices().catchError((_) => <JsonMap>[]);
      final energyFuture = _fetchEnergyFromBackend(_selectedRange);

      final results = await Future.wait([devicesFuture, energyFuture]);
      if (!mounted) return;

      final devicesList = results[0] as JsonList;
      final energyMap = results[1] as Map<String, dynamic>;

      setState(() {
        _devices = devicesList;
        _totalKwh = (energyMap['total_kwh'] as num?)?.toDouble() ?? 0.0;
        _unitPriceVnd = (energyMap['unit_price'] as num?)?.toDouble() ?? 2500.0;
        _estimatedCost =
            (energyMap['estimated_cost'] as num?)?.toDouble() ??
            (_totalKwh * _unitPriceVnd);
        _chartBars = List.from(
          energyMap['bars'] as List? ?? _buildDefaultBars(),
        );
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _chartBars = _buildDefaultBars();
        _isLoading = false;
      });
    }
  }

  Future _fetchEnergyFromBackend(String range) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (_api.token != null && _api.token!.isNotEmpty)
        'Authorization': 'Bearer ${_api.token}',
    };

    const paths = ['/energy', '/energy/stats', '/energy/summary'];
    for (final path in paths) {
      try {
        final uri = Uri.parse('${_api.baseUrl}$path?period=$range');
        final res = await http.get(uri, headers: headers);
        if (res.statusCode >= 200 && res.statusCode < 300) {
          final decoded = jsonDecode(res.body);
          final map = decoded is Map<String, dynamic>
              ? (decoded['data'] is Map
                    ? Map<String, dynamic>.from(decoded['data'] as Map)
                    : decoded)
              : <String, dynamic>{};

          final totalKwh =
              ((map['total_kwh'] ??
                          map['total_consumption'] ??
                          map['kwh'] ??
                          0.0)
                      as num)
                  .toDouble();
          final unitPrice =
              ((map['unit_price'] ?? map['tariff'] ?? 2500.0) as num)
                  .toDouble();
          final cost =
              ((map['estimated_cost'] ??
                          map['total_cost'] ??
                          (totalKwh * unitPrice))
                      as num)
                  .toDouble();

          final rawSeries = map['daily'] ?? map['chart'] ?? map['series'];
          final bars = [];
          if (rawSeries is List && rawSeries.isNotEmpty) {
            for (final item in rawSeries) {
              if (item is Map) {
                bars.add({
                  'label': (item['label'] ?? item['date'] ?? '').toString(),
                  'kwh': ((item['kwh'] ?? item['value'] ?? 0.0) as num)
                      .toDouble(),
                });
              }
            }
          }

          return {
            'total_kwh': totalKwh,
            'unit_price': unitPrice,
            'estimated_cost': cost,
            'bars': bars.isNotEmpty ? bars : _buildDefaultBars(),
          };
        }
      } catch (_) {}
    }

    return {
      'total_kwh': 0.0,
      'unit_price': 2500.0,
      'estimated_cost': 0.0,
      'bars': _buildDefaultBars(),
    };
  }

  List _buildDefaultBars() {
    final now = DateTime.now();
    return List.generate(7, (idx) {
      final d = now.subtract(Duration(days: 6 - idx));
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

    double maxBarKwh = 0.2;
    for (final b in _chartBars) {
      final v = (b['kwh'] as num?)?.toDouble() ?? 0.0;
      if (v > maxBarKwh) maxBarKwh = v;
    }

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      body: RefreshIndicator(
        color: cyan,
        onRefresh: _loadEnergyData,
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

            // 3 THẺ TỔNG QUAN ĐIỆN NĂNG & TẢI TỨC THỜI
            Row(
              children: [
                Expanded(
                  child: _buildMetricCard(
                    isDark: isDark,
                    icon: Icons.bolt,
                    color: cyan,
                    value: '${_totalKwh.toStringAsFixed(2)} kWh',
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
                        'BIỂU ĐỒ TIÊU THỤ (kWh)',
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
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 130,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: _chartBars.map((bar) {
                        final kwh = (bar['kwh'] as num?)?.toDouble() ?? 0.0;
                        final label = (bar['label'] ?? '').toString();
                        final ratio = maxBarKwh > 0
                            ? (kwh / maxBarKwh).clamp(0.0, 1.0)
                            : 0.0;
                        final barHeight = kwh > 0 ? (14 + ratio * 76) : 6.0;

                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Text(
                                  kwh.toStringAsFixed(1),
                                  style: const TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 9.5,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  height: barHeight,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [cyan, cyan.withOpacity(0.35)],
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  label,
                                  style: TextStyle(
                                    color: AppColors.getTextSecondary(isDark),
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
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
                // Tính % trên tổng tải tức thời đang bật (nếu đang bật)
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
              fontSize: 14,
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
