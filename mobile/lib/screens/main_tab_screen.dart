import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';
import 'ai_alerts_screen.dart';
import 'automation_screen.dart';
import 'energy_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'space_device_management_screen.dart';
import 'user_management_screen.dart';

class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  int _currentIndex = 0;
  int _unreadAlerts = 0;
  StreamSubscription? _alertSub;

  @override
  void initState() {
    super.initState();
    final api = ApiService();
    final ws = WebSocketService();
    if (api.isAuthenticated && !ws.isConnected) {
      ws.connect(api.wsUrl);
    }
    _alertSub = ws.aiAlertStream.listen((_) {
      if (!mounted) return;
      // Tab Cảnh Báo AI nằm ở vị trí index 4
      if (_currentIndex != 4) {
        setState(() => _unreadAlerts++);
      }
    });
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final apiService = Provider.of<ApiService>(context);
    final isDark = themeProvider.isDarkMode;
    final isAdmin = apiService.isAdmin;

    final List<Widget> screens = [
      const HomeScreen(),
      const SpaceDeviceManagementScreen(),
      const EnergyScreen(),
      const AutomationScreen(),
      AiAlertsScreen(
        onViewed: () {
          if (mounted && _unreadAlerts > 0) {
            setState(() => _unreadAlerts = 0);
          }
        },
      ),
      if (isAdmin) const UserManagementScreen(),
      const SettingsScreen(),
    ];

    final List<BottomNavigationBarItem> navItems = [
      const BottomNavigationBarItem(
        icon: Icon(Icons.dashboard_outlined),
        activeIcon: Icon(Icons.dashboard),
        label: 'Tổng Quan',
      ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.home_work_outlined),
        activeIcon: Icon(Icons.home_work),
        label: 'Quản Lý',
      ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.bolt_outlined),
        activeIcon: Icon(Icons.bolt),
        label: 'Điện Năng',
      ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.auto_awesome_outlined),
        activeIcon: Icon(Icons.auto_awesome),
        label: 'Tự Động',
      ),
      BottomNavigationBarItem(
        icon: Badge(
          isLabelVisible: _unreadAlerts > 0,
          label: Text('$_unreadAlerts'),
          backgroundColor: AppColors.accent,
          child: const Icon(Icons.warning_amber_outlined),
        ),
        activeIcon: const Icon(Icons.warning_amber_rounded),
        label: 'Cảnh Báo',
      ),
      if (isAdmin)
        const BottomNavigationBarItem(
          icon: Icon(Icons.people_outline),
          activeIcon: Icon(Icons.people),
          label: 'Thành Viên',
        ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.settings_outlined),
        activeIcon: Icon(Icons.settings),
        label: 'Cài Đặt',
      ),
    ];

    final safeIndex = _currentIndex >= screens.length ? 0 : _currentIndex;

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      appBar: AppBar(
        backgroundColor: AppColors.getSurface(isDark),
        elevation: 1,
        title: Row(
          children: [
            const Icon(Icons.hub, color: AppColors.primary, size: 22),
            const SizedBox(width: 8),
            Text(
              'Smarthome',
              style: TextStyle(
                color: AppColors.getTextPrimary(isDark),
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              isDark ? Icons.light_mode : Icons.dark_mode,
              color: isDark ? Colors.amber : AppColors.secondary,
            ),
            onPressed: () => themeProvider.toggleTheme(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: IndexedStack(index: safeIndex, children: screens),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AppColors.getSurface(isDark),
          border: Border(
            top: BorderSide(color: AppColors.getBorder(isDark), width: 1),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: safeIndex,
          onTap: (index) {
            setState(() {
              _currentIndex = index;
              if (index == 4) _unreadAlerts = 0;
            });
          },
          backgroundColor: AppColors.getSurface(isDark),
          selectedItemColor: AppColors.primary,
          unselectedItemColor: AppColors.getTextSecondary(isDark),
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          iconSize: 20,
          selectedFontSize: 9.5,
          unselectedFontSize: 8.5,
          items: navItems,
        ),
      ),
    );
  }
}
