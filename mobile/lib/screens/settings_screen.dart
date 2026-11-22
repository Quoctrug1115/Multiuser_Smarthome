import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  late final TextEditingController _serverCtrl;
  bool _isSyncingProfile = false;

  @override
  void initState() {
    super.initState();
    final api = ApiService();
    final cleanRoot = api.baseUrl.replaceFirst(RegExp(r'/api/v1$'), '');
    _serverCtrl = TextEditingController(text: cleanRoot);
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    super.dispose();
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

  Future<void> _applyServerConfig() async {
    final input = _serverCtrl.text.trim();
    if (input.isEmpty) {
      _showSnack('Vui lòng nhập địa chỉ máy chủ!', isError: true);
      return;
    }
    final api = ApiService();
    final ws = WebSocketService();
    api.updateBaseUrl(input);
    ws.disconnect(temporary: true);
    if (api.isAuthenticated) {
      ws.connect(api.wsUrl);
    }
    _showSnack('Đã cập nhật máy chủ: ${api.baseUrl}');
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final apiService = Provider.of<ApiService>(context);
    final wsService = Provider.of<WebSocketService>(context);

    final isDark = themeProvider.isDarkMode;
    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);
    final profile = apiService.userProfile;

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        children: [
          // 1. THÔNG TIN TÀI KHOẢN & HỘ GIA ĐÌNH
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.getSurface(isDark),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cyan.withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: cyan.withOpacity(0.18),
                      child: Text(
                        (profile?.name.isNotEmpty == true
                                ? profile!.name[0]
                                : 'U')
                            .toUpperCase(),
                        style: TextStyle(
                          color: cyan,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile?.name ?? 'Người dùng SmartHome',
                            style: TextStyle(
                              color: AppColors.getTextPrimary(isDark),
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            profile?.email ?? 'Chưa đồng bộ email',
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: cyan.withOpacity(0.16),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        apiService.currentUserRole.toUpperCase(),
                        style: TextStyle(
                          color: cyan,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 22),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        'Mã Hộ gia đình (Tenant): ${apiService.householdOwnerId.isEmpty ? "N/A" : apiService.householdOwnerId}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    if (apiService.householdOwnerId.isNotEmpty)
                      IconButton(
                        icon: Icon(Icons.copy, size: 16, color: cyan),
                        tooltip: 'Sao chép ID hộ gia đình',
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: apiService.householdOwnerId),
                          );
                          _showSnack('Đã sao chép Mã hộ gia đình');
                        },
                      ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _isSyncingProfile
                        ? null
                        : () async {
                            setState(() => _isSyncingProfile = true);
                            try {
                              await apiService.fetchCurrentUser();
                              _showSnack('Đã đồng bộ hồ sơ từ /auth/me');
                            } catch (e) {
                              _showSnack(
                                e.toString().replaceFirst('Exception: ', ''),
                                isError: true,
                              );
                            } finally {
                              if (mounted) {
                                setState(() => _isSyncingProfile = false);
                              }
                            }
                          },
                    icon: Icon(Icons.sync, size: 16, color: cyan),
                    label: Text(
                      _isSyncingProfile ? 'ĐANG ĐỒNG BỘ...' : 'ĐỒNG BỘ HỒ SƠ',
                      style: TextStyle(
                        color: cyan,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. GIAO DIỆN HIỂN THỊ
          Material(
            color: AppColors.getSurface(isDark),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: isDark ? Colors.white12 : Colors.black12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: Icon(
                  isDark ? Icons.dark_mode : Icons.light_mode,
                  color: isDark ? Colors.amber : AppColors.secondary,
                ),
                title: Text(
                  'Chế độ Giao diện Tối (Dark)',
                  style: TextStyle(
                    color: AppColors.getTextPrimary(isDark),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: const Text(
                  'Đồng bộ giao diện sáng / tối toàn ứng dụng',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
                value: isDark,
                activeColor: cyan,
                onChanged: (_) => themeProvider.toggleTheme(),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 3. KẾT NỐI MÁY CHỦ RUST BACKEND & WEBSOCKET
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.getSurface(isDark),
              borderRadius: BorderRadius.circular(14),
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
                    Text(
                      'PHIÊN ĐĂNG NHẬP',
                      style: TextStyle(
                        color: AppColors.getTextPrimary(isDark),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    // Row(
                    //   children: [
                    //     Icon(
                    //       Icons.circle,
                    //       size: 8,
                    //       color: wsService.isConnected
                    //           ? green
                    //           : AppColors.accent,
                    //     ),
                    //     const SizedBox(width: 5),
                    //     Text(
                    //       wsService.isConnected ? 'WS CONNECTED' : 'WS OFFLINE',
                    //       style: TextStyle(
                    //         color: wsService.isConnected
                    //             ? green
                    //             : AppColors.accent,
                    //         fontSize: 10,
                    //         fontWeight: FontWeight.bold,
                    //       ),
                    //     ),
                    //   ],
                    // ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _serverCtrl,
                  style: TextStyle(
                    color: AppColors.getTextPrimary(isDark),
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Chưa có phiên đăng nhập',
                    // hintText: 'http://127.0.0.1:3000',
                    prefixIcon: Icon(Icons.dns_outlined, color: cyan, size: 19),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    // ActionChip(
                    //   label: const Text(
                    //     'Android Emulator (127.0.0.1)',
                    //     style: TextStyle(fontSize: 11),
                    //   ),
                    //   onPressed: () {
                    //     _serverCtrl.text = 'http://127.0.0.1:3000';
                    //     _applyServerConfig();
                    //   },
                    // ),
                    // ActionChip(
                    //   label: const Text(
                    //     'Localhost (127.0.0.1)',
                    //     style: TextStyle(fontSize: 11),
                    //   ),
                    //   onPressed: () {
                    //     _serverCtrl.text = 'http://127.0.0.1:3000';
                    //     _applyServerConfig();
                    //   },
                    // ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: cyan,
                      foregroundColor: isDark
                          ? const Color(0xFF0A0E1A)
                          : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: _applyServerConfig,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text(
                      'Xóa phiên đăng nhập',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 4. ĐĂNG XUẤT
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: const BorderSide(color: AppColors.accent, width: 1.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () {
                wsService.disconnect();
                apiService.logout();
                Navigator.pushNamedAndRemoveUntil(
                  context,
                  '/login',
                  (route) => false,
                );
              },
              icon: const Icon(Icons.logout),
              label: const Text(
                'ĐĂNG XUẤT KHỎI HỆ THỐNG',
                style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
