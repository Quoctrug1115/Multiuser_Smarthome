import 'package:flutter/material.dart';

class AppColors {
  // Dark Cyberpunk Palette
  static const Color darkBackground = Color(0xFF0A0E1A);
  static const Color darkSurface = Color(0xFF121829);
  static const Color darkSurfaceLight = Color(0xFF1E2640);
  static const Color darkBorder = Color(0xFF1F293D);
  static const Color darkTextPrimary = Color(0xFFFFFFFF);
  static const Color darkTextSecondary = Color(0xFF94A3B8);

  // Light Sci-Fi Palette
  static const Color lightBackground = Color(0xFFF0F4F9);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceLight = Color(0xFFE2E8F0);
  static const Color lightBorder = Color(0xFFCBD5E1);
  static const Color lightTextPrimary = Color(0xFF0F172A);
  static const Color lightTextSecondary = Color(0xFF475569);

  // Giữ tương thích ngược cho các màn hình cũ
  static const Color background = darkBackground;
  static const Color surface = darkSurface;
  static const Color surfaceLight = darkSurfaceLight;
  static const Color border = darkBorder;
  static const Color textPrimary = darkTextPrimary;
  static const Color textSecondary = darkTextSecondary;
  static Color glowCyan = primary.withOpacity(0.15);

  // Neon Accent Colors
  static const Color primary = Color(0xFF00F0FF); // Neon Cyan
  static const Color secondary = Color(0xFF8B5CF6); // Neon Purple
  static const Color accent = Color(0xFFF43F5E); // Neon Pink
  static const Color textMuted = Color(0xFF64748B);

  // Hàm lấy màu động theo chế độ Light / Dark
  static Color getBackground(bool isDark) =>
      isDark ? darkBackground : lightBackground;
  static Color getSurface(bool isDark) => isDark ? darkSurface : lightSurface;
  static Color getSurfaceLight(bool isDark) =>
      isDark ? darkSurfaceLight : lightSurfaceLight;
  static Color getBorder(bool isDark) => isDark ? darkBorder : lightBorder;
  static Color getTextPrimary(bool isDark) =>
      isDark ? darkTextPrimary : lightTextPrimary;
  static Color getTextSecondary(bool isDark) =>
      isDark ? darkTextSecondary : lightTextSecondary;
  static Color getGlowCyan(bool isDark) =>
      primary.withOpacity(isDark ? 0.15 : 0.25);
}
