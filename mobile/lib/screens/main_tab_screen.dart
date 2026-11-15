import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';
import 'home_screen.dart';
import 'energy_screen.dart';
import 'automation_screen.dart';
import 'user_management_screen.dart';
import 'settings_screen.dart';

class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final apiService = Provider.of<ApiService>(context);
    final isDark = themeProvider.isDarkMode;
    final isAdmin = apiService.isAdmin;

    final List<Widget> screens = [
      const HomeScreen(),
      const EnergyScreen(),
      const AutomationScreen(),
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
        icon: Icon(Icons.bolt_outlined),
        activeIcon: Icon(Icons.bolt),
        label: 'Điện Năng',
      ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.auto_awesome_outlined),
        activeIcon: Icon(Icons.auto_awesome),
        label: 'Tự Động',
      ),
      if (isAdmin)
        const BottomNavigationBarItem(
          icon: Icon(Icons.people_outline),
          activeIcon: Icon(Icons.people),
          label: 'Người Dùng',
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
              'SCI-FI HUB CONTROL',
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
          onTap: (index) => setState(() => _currentIndex = index),
          backgroundColor: AppColors.getSurface(isDark),
          selectedItemColor: AppColors.primary,
          unselectedItemColor: AppColors.getTextSecondary(isDark),
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          selectedFontSize: 11,
          unselectedFontSize: 10,
          items: navItems,
        ),
      ),
    );
  }
}
