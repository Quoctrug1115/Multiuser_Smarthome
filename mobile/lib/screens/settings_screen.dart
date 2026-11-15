import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _wsUrlController = TextEditingController(
    text: 'ws://localhost:3000/ws',
  );
  bool _overloadAlert = true;

  @override
  void dispose() {
    _wsUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final wsService = Provider.of<WebSocketService>(context);
    final apiService = Provider.of<ApiService>(context);
    final isDark = themeProvider.isDarkMode;

    final user = apiService.currentUser;
    final displayName =
        (user?['full_name'] ?? user?['name'] ?? 'Chưa đăng nhập').toString();
    final displayEmail = (user?['email'] ?? 'guest@local').toString();
    final displayRole = (user?['role'] ?? 'USER').toString().toUpperCase();

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.getSurface(isDark),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.primary.withOpacity(0.5)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: AppColors.getGlowCyan(isDark),
                    child: const Icon(
                      Icons.person,
                      color: AppColors.primary,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName,
                          style: TextStyle(
                            color: AppColors.getTextPrimary(isDark),
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          displayEmail,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.getGlowCyan(isDark),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            displayRole,
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            Text(
              'KẾT NỐI MÁY CHỦ RUST (API & WEBSOCKET)',
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _wsUrlController,
                    style: TextStyle(
                      color: AppColors.getTextPrimary(isDark),
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      labelText: 'WebSocket Endpoint URL',
                      labelStyle: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                      prefixIcon: const Icon(
                        Icons.link,
                        color: AppColors.primary,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'REST API: ${apiService.baseUrl}',
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        wsService.isConnected
                            ? 'Trạng thái: Đã kết nối'
                            : 'Trạng thái: Ngắt kết nối',
                        style: TextStyle(
                          color: wsService.isConnected
                              ? Colors.greenAccent
                              : AppColors.accent,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: const Color(0xFF0A0E1A),
                        ),
                        onPressed: () {
                          final url = _wsUrlController.text.trim();
                          apiService.updateBaseUrl(url);
                          wsService.disconnect();
                          wsService.connect(url);
                        },
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text(
                          'KẾT NỐI LẠI',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            Text(
              'TÙY CHỈNH HỆ THỐNG',
              style: TextStyle(
                color: AppColors.getTextSecondary(isDark),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Material(
              color: AppColors.getSurface(isDark),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: AppColors.getBorder(isDark)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  SwitchListTile(
                    title: Text(
                      'Giao diện Tối (Cyberpunk Dark)',
                      style: TextStyle(
                        color: AppColors.getTextPrimary(isDark),
                        fontSize: 14,
                      ),
                    ),
                    subtitle: const Text(
                      'Tối ưu hiển thị ban đêm & hiệu ứng Neon',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    value: isDark,
                    activeColor: AppColors.primary,
                    onChanged: (_) => themeProvider.toggleTheme(),
                  ),
                  Divider(height: 1, color: AppColors.getBorder(isDark)),
                  SwitchListTile(
                    title: Text(
                      'Cảnh báo quá tải điện năng',
                      style: TextStyle(
                        color: AppColors.getTextPrimary(isDark),
                        fontSize: 14,
                      ),
                    ),
                    subtitle: const Text(
                      'Thông báo khi công suất vượt ngưỡng 2000W',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    value: _overloadAlert,
                    activeColor: AppColors.primary,
                    onChanged: (val) => setState(() => _overloadAlert = val),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  side: const BorderSide(color: AppColors.accent),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {
                  apiService.logout();
                  wsService.disconnect();
                  Navigator.pushReplacementNamed(context, '/login');
                },
                icon: const Icon(Icons.logout),
                label: const Text(
                  'ĐĂNG XUẤT KHỎI HỆ THỐNG',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
