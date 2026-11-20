import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/smarthome_models.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';

class EnergyScreen extends StatefulWidget {
  const EnergyScreen({super.key});

  @override
  State<EnergyScreen> createState() => _EnergyScreenState();
}

class _EnergyScreenState extends State<EnergyScreen> {
  final ApiService _api = ApiService();
  String _selectedRange = '7d'; // '24h' | '7d' | '30d'
  bool _isLoading = true;

  JsonMap _stats = {};
  List<Device> _devices = [];

  @override
  void initState() {
    super.initState();
    _loadEnergyData();
  }

  Future<void> _loadEnergyData() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        _api
            .getEnergyStats(_selectedRange)
            .catchError((_) => <String, dynamic>{}),
        _api.getDevices().catchError((_) => <JsonMap>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _stats = results[0] as JsonMap;
        _devices = (results[1] as JsonList)
            .map((e) => Device.fromJson(e))
            .toList();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: AppColors.accent,
        ),
      );
    }
  }

  List get _chartPoints {
    final rawSeries =
        _stats['chart'] ??
        _stats['daily'] ??
        _stats['hourly'] ??
        _stats['series'] ??
        _stats['data'];

    if (rawSeries is List && rawSeries.isNotEmpty) {
      return rawSeries.map((item) {
        if (item is Map) {
          final label =
              (item['label'] ??
                      item['date'] ??
                      item['day'] ??
                      item['hour'] ??
                      '')
                  .toString();
          final val =
              (item['kwh'] ??
                      item['energy_kwh'] ??
                      item['value'] ??
                      item['consumption'] ??
                      0)
                  .toDouble();
          return {
            'label': label.length > 5
                ? label.substring(label.length - 5)
                : label,
            'kwh': val,
          };
        }
        return {'label': '', 'kwh': 0.0};
      }).toList();
    }

    // Dữ liệu tham chiếu tỷ lệ theo thiết bị đang bật nếu TimescaleDB chưa tích lũy đủ mẫu
    final baseKwh = math.max(1.2, _activeWatt * 24 / 1000.0);
    if (_selectedRange == '24h') {
      return [
        {'label': '00h', 'kwh': baseKwh * 0.12},
        {'label': '04h', 'kwh': baseKwh * 0.10},
        {'label': '08h', 'kwh': baseKwh * 0.18},
        {'label': '12h', 'kwh': baseKwh * 0.22},
        {'label': '16h', 'kwh': baseKwh * 0.16},
        {'label': '20h', 'kwh': baseKwh * 0.22},
      ];
    }
    return [
      {'label': 'T2', 'kwh': baseKwh * 0.92},
      {'label': 'T3', 'kwh': baseKwh * 1.05},
      {'label': 'T4', 'kwh': baseKwh * 0.88},
      {'label': 'T5', 'kwh': baseKwh * 1.12},
      {'label': 'T6', 'kwh': baseKwh * 0.98},
      {'label': 'T7', 'kwh': baseKwh * 1.15},
      {'label': 'CN', 'kwh': baseKwh * 1.02},
    ];
  }

  double get _activeWatt =>
      _devices.fold<double>(0.0, (sum, d) => sum + d.ratedPowerWatt);

  double get _totalKwh {
    final backendTotal =
        _stats['total_kwh'] ?? _stats['total_energy_kwh'] ?? _stats['sum_kwh'];
    if (backendTotal is num && backendTotal > 0) {
      return backendTotal.toDouble();
    }
    return _chartPoints.fold<double>(
      0.0,
      (sum, p) => sum + (p['kwh'] as double),
    );
  }

  double get _estimatedCostVnd {
    final backendCost = _stats['estimated_cost_vnd'] ?? _stats['total_cost'];
    if (backendCost is num && backendCost > 0) {
      return backendCost.toDouble();
    }
    // Đơn giá điện sinh hoạt trung bình 2.500 VNĐ/kWh đồng bộ với Web
    return _totalKwh * 2500.0;
  }

  String _formatVnd(double amount) {
    final intVal = amount.round().toString();
    final buf = StringBuffer();
    for (int i = 0; i < intVal.length; i++) {
      if (i > 0 && (intVal.length - i) % 3 == 0) buf.write('.');
      buf.write(intVal[i]);
    }
    return '${buf.toString()} đ';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;
    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);
    final amber = isDark ? Colors.amber : const Color(0xFFD97706);

    final points = _chartPoints;
    final maxKwh = points.fold<double>(
      0.1,
      (m, p) => math.max(m, (p['kwh'] as double)),
    );

    final consumerDevices = _devices
        .where((d) => d.deviceType.toLowerCase() != 'sensor')
        .toList();

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      body: RefreshIndicator(
        color: cyan,
        onRefresh: _loadEnergyData,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
          children: [
            // Bộ chọn chu kỳ thống kê
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
                    _buildPeriodChip('24H', '24h', cyan, isDark),
                    const SizedBox(width: 6),
                    _buildPeriodChip('7 NGÀY', '7d', cyan, isDark),
                    const SizedBox(width: 6),
                    _buildPeriodChip('30 NGÀY', '30d', cyan, isDark),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),

            if (_isLoading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator(color: cyan)),
              )
            else ...[
              // 3 Thẻ chỉ số KPI
              Row(
                children: [
                  Expanded(
                    child: _buildKpiCard(
                      'TỔNG TIÊU THỤ',
                      '${_totalKwh.toStringAsFixed(2)} kWh',
                      Icons.electric_bolt,
                      cyan,
                      isDark,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildKpiCard(
                      'CHI PHÍ ƯỚC TÍNH',
                      _formatVnd(_estimatedCostVnd),
                      Icons.payments_outlined,
                      green,
                      isDark,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildKpiCard(
                      'TẢI TỨC THỜI',
                      '${_activeWatt.toStringAsFixed(0)} W',
                      Icons.speed,
                      amber,
                      isDark,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Biểu đồ cột tiêu thụ điện năng
              Container(
                padding: const EdgeInsets.all(16),
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
                          '2.500 đ/kWh',
                          style: TextStyle(
                            color: green,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      height: 150,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: points.map((pt) {
                          final val = pt['kwh'] as double;
                          final ratio = (val / maxKwh).clamp(0.08, 1.0);
                          return Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Text(
                                    val.toStringAsFixed(1),
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 9,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 350),
                                    height: 105 * ratio,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [cyan, cyan.withOpacity(0.35)],
                                      ),
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(6),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    pt['label'].toString(),
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: AppColors.getTextSecondary(isDark),
                                      fontSize: 10,
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

              // Phân bổ công suất theo từng thiết bị
              Text(
                'PHÂN BỔ CÔNG SUẤT THIẾT BỊ (${consumerDevices.length})',
                style: TextStyle(
                  color: AppColors.getTextPrimary(isDark),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 10),
              if (consumerDevices.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppColors.getSurface(isDark),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Chưa có thiết bị tiêu thụ điện nào được kết nối.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                )
              else
                ...consumerDevices.map((dev) {
                  final watt = dev.ratedPowerWatt;
                  final share = _activeWatt > 0 ? (watt / _activeWatt) : 0.0;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.getSurface(isDark),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark ? Colors.white12 : Colors.black12,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                dev.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppColors.getTextPrimary(isDark),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Text(
                              dev.isOn
                                  ? '${watt.toStringAsFixed(0)} W (${(share * 100).toStringAsFixed(0)}%)'
                                  : 'ĐANG TẮT (0 W)',
                              style: TextStyle(
                                color: dev.isOn ? cyan : AppColors.textMuted,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: dev.isOn ? share : 0.0,
                            minHeight: 6,
                            backgroundColor: AppColors.getBackground(isDark),
                            valueColor: AlwaysStoppedAnimation<Color>(cyan),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPeriodChip(String label, String value, Color cyan, bool isDark) {
    final selected = _selectedRange == value;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        if (_selectedRange != value) {
          setState(() => _selectedRange = value);
          _loadEnergyData();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? cyan : AppColors.getSurface(isDark),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? cyan : (isDark ? Colors.white12 : Colors.black12),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? (isDark ? const Color(0xFF0A0E1A) : Colors.white)
                : AppColors.getTextSecondary(isDark),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildKpiCard(
    String label,
    String value,
    IconData icon,
    Color color,
    bool isDark,
  ) {
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
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
