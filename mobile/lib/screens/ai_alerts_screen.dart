import 'dart:async';

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
  final WebSocketService _ws = WebSocketService();

  List<AiAlert> _alerts = [];
  bool _isLoading = true;
  bool _isSimulating = false;
  StreamSubscription? _alertSub;

  @override
  void initState() {
    super.initState();
    _loadAlerts();
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
  }

  Future<void> _loadAlerts() async {
    setState(() => _isLoading = true);
    try {
      final rawList = await _api.getAiAlerts();
      if (!mounted) return;
      setState(() {
        _alerts = rawList.map((e) => AiAlert.fromJson(e)).toList();
        _isLoading = false;
      });
      widget.onViewed?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnack(e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
  }

  Future<void> _simulateAnomaly() async {
    setState(() => _isSimulating = true);
    try {
      await _api.triggerAiAnalysis(
        temperature: 65.0,
        sensorId: 'dht22_living_room',
      );
      _showSnack('Đã gửi tín hiệu giả lập quá nhiệt 65°C tới AI Engine');
      await _loadAlerts();
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''), isError: true);
    } finally {
      if (mounted) setState(() => _isSimulating = false);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: isError ? AppColors.accent : AppColors.secondary,
      ),
    );
  }

  Color _severityColor(String severity, bool isDark) {
    switch (severity.toLowerCase()) {
      case 'critical':
      case 'high':
        return AppColors.accent;
      case 'warning':
        return isDark ? Colors.amber : const Color(0xFFD97706);
      default:
        return isDark ? AppColors.primary : const Color(0xFF0284C7);
    }
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;
    final apiService = Provider.of<ApiService>(context);
    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      body: RefreshIndicator(
        color: cyan,
        onRefresh: _loadAlerts,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
          children: [
            // Banner giám sát AI Z-Score
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.getSurface(isDark),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.accent.withOpacity(0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.psychology_alt,
                        color: AppColors.accent,
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'GIÁM SÁT BẤT THƯỜNG AI (Z-SCORE)',
                          style: TextStyle(
                            color: AppColors.getTextPrimary(isDark),
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Phát hiện đột biến nhiệt độ, dòng điện và hành vi thiết bị bất thường theo thời gian thực cho hộ gia đình của bạn.',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                  ),
                  if (apiService.isAdmin) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: _isSimulating ? null : _simulateAnomaly,
                        icon: _isSimulating
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.local_fire_department, size: 18),
                        label: const Text(
                          'GIẢ LẬP QUÁ NHIỆT 65°C (TEST AI)',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'LỊCH SỬ CẢNH BÁO (${_alerts.length})',
                  style: TextStyle(
                    color: AppColors.getTextSecondary(isDark),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                InkWell(
                  onTap: _loadAlerts,
                  child: Text(
                    'LÀM MỚI',
                    style: TextStyle(
                      color: cyan,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (_isLoading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator(color: cyan)),
              )
            else if (_alerts.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 36,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: AppColors.getSurface(isDark),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.getBorder(isDark)),
                ),
                child: const Column(
                  children: [
                    Icon(
                      Icons.verified_user_outlined,
                      color: Colors.greenAccent,
                      size: 36,
                    ),
                    SizedBox(height: 10),
                    Text(
                      'Hệ thống an toàn — Chưa ghi nhận cảnh báo bất thường nào.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              )
            else
              ..._alerts.map((alert) {
                final color = _severityColor(alert.severity, isDark);
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.getSurface(isDark),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: color.withOpacity(0.45)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: color,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              alert.title,
                              style: TextStyle(
                                color: AppColors.getTextPrimary(isDark),
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              alert.severity.toUpperCase(),
                              style: TextStyle(
                                color: color,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (alert.message.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          alert.message,
                          style: TextStyle(
                            color: AppColors.getTextSecondary(isDark),
                            fontSize: 12,
                          ),
                        ),
                      ],
                      if (alert.createdAt.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Thời gian: ${alert.createdAt}',
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
