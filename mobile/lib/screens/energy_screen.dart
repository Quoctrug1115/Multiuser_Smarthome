import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
  String _selectedRange = 'DAY';
  int _selectedBarIndex = 0;
  bool _isLoading = true;
  String? _errorMsg;

  double _totalKwh = 0.0;
  double _totalCost = 0.0;
  double _peakWatt = 0.0;
  List _chartPoints = [];
  List _deviceBreakdown = [];

  @override
  void initState() {
    super.initState();
    _loadEnergyData();
  }

  Future<void> _loadEnergyData() async {
    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    try {
      final data = await _api.getEnergyStats(_selectedRange);
      if (!mounted) return;

      final rawChart =
          (data['chart'] ?? data['history'] ?? data['logs'] ?? []) as List;
      final rawDevices = (data['by_device'] ?? data['devices'] ?? []) as List;

      setState(() {
        _totalKwh = ((data['total_kwh'] ?? 0) as num).toDouble();
        _totalCost = ((data['total_cost'] ?? (_totalKwh * 2500)) as num)
            .toDouble();
        _peakWatt = ((data['peak_watt'] ?? 0) as num).toDouble();
        _chartPoints = rawChart
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _deviceBreakdown = rawDevices
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _selectedBarIndex = 0;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _loadEnergyData,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'ĐIỆN NĂNG TỪ TIMESCALEDB',
                    style: TextStyle(
                      color: AppColors.getTextSecondary(isDark),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Row(
                    children:
                        [
                          {'key': 'DAY', 'label': 'NGÀY'},
                          {'key': 'WEEK', 'label': 'TUẦN'},
                          {'key': 'MONTH', 'label': 'THÁNG'},
                        ].map((item) {
                          final active = _selectedRange == item['key'];
                          return GestureDetector(
                            onTap: () {
                              setState(() => _selectedRange = item['key']!);
                              _loadEnergyData();
                            },
                            child: Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: active
                                    ? AppColors.primary
                                    : AppColors.getSurface(isDark),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: active
                                      ? AppColors.primary
                                      : AppColors.getBorder(isDark),
                                ),
                              ),
                              child: Text(
                                item['label']!,
                                style: TextStyle(
                                  color: active
                                      ? const Color(0xFF0A0E1A)
                                      : AppColors.getTextSecondary(isDark),
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              if (_isLoading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: CircularProgressIndicator(color: AppColors.primary),
                  ),
                )
              else if (_errorMsg != null)
                Center(
                  child: Column(
                    children: [
                      Text(
                        'Không tải được dữ liệu: $_errorMsg',
                        style: const TextStyle(color: AppColors.accent),
                      ),
                      TextButton(
                        onPressed: _loadEnergyData,
                        child: const Text('THỬ LẠI'),
                      ),
                    ],
                  ),
                )
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: _buildKpiCard(
                        'TỔNG TIÊU THỤ',
                        '${_totalKwh.toStringAsFixed(2)} kWh',
                        AppColors.primary,
                        isDark,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildKpiCard(
                        'CHI PHÍ',
                        '${_totalCost.round()} đ',
                        AppColors.secondary,
                        isDark,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildKpiCard(
                        'ĐỈNH CÔNG SUẤT',
                        '${_peakWatt.toStringAsFixed(0)} W',
                        AppColors.accent,
                        isDark,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.getSurface(isDark),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.getBorder(isDark)),
                  ),
                  child: _chartPoints.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Chưa có bản ghi energy_logs trong khoảng thời gian này',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        )
                      : _buildChart(isDark),
                ),
                const SizedBox(height: 18),

                if (_deviceBreakdown.isNotEmpty) ...[
                  Text(
                    'TIÊU THỤ THEO TỪNG THIẾT BỊ',
                    style: TextStyle(
                      color: AppColors.getTextSecondary(isDark),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.getSurface(isDark),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.getBorder(isDark)),
                    ),
                    child: Column(
                      children: _deviceBreakdown.map((dev) {
                        final kwh =
                            ((dev['kwh'] ?? dev['kwh_consumed'] ?? 0) as num)
                                .toDouble();
                        final ratio = _totalKwh > 0
                            ? (kwh / _totalKwh).clamp(0.0, 1.0)
                            : 0.0;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    dev['name']?.toString() ?? 'Thiết bị',
                                    style: TextStyle(
                                      color: AppColors.getTextPrimary(isDark),
                                      fontSize: 13,
                                    ),
                                  ),
                                  Text(
                                    '${kwh.toStringAsFixed(2)} kWh',
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              LinearProgressIndicator(
                                value: ratio,
                                minHeight: 6,
                                backgroundColor: AppColors.getSurfaceLight(
                                  isDark,
                                ),
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  AppColors.primary,
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChart(bool isDark) {
    final values = _chartPoints
        .map((e) => ((e['kwh'] ?? e['value'] ?? 0) as num).toDouble())
        .toList();
    final labels = _chartPoints
        .map((e) => (e['label'] ?? e['bucket'] ?? '').toString())
        .toList();
    final maxVal = values.reduce((a, b) => a > b ? a : b);
    final safeIdx = _selectedBarIndex < values.length ? _selectedBarIndex : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'MỐC: ${labels[safeIdx]}',
              style: TextStyle(
                color: AppColors.getTextSecondary(isDark),
                fontSize: 11,
              ),
            ),
            Text(
              '${values[safeIdx].toStringAsFixed(2)} kWh',
              style: const TextStyle(
                color: AppColors.primary,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 145,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(values.length, (i) {
              final selected = i == safeIdx;
              final h = maxVal > 0 ? (values[i] / maxVal) * 110 : 12.0;
              return GestureDetector(
                onTap: () => setState(() => _selectedBarIndex = i),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      width: 22,
                      height: h < 10 ? 10 : h,
                      decoration: BoxDecoration(
                        color: selected
                            ? AppColors.primary
                            : AppColors.getSurfaceLight(isDark),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      labels[i],
                      style: TextStyle(
                        color: selected
                            ? AppColors.primary
                            : AppColors.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildKpiCard(
    String title,
    String value,
    Color accentColor,
    bool isDark,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.getBorder(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: accentColor,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
