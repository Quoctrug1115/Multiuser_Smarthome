import 'package:flutter/material.dart';

class AppColors {
  // Nền ứng dụng (Dark Cyberpunk / Sci-Fi Space)
  static const Color background = Color(0xFF0A0E1A);
  static const Color surface = Color(0xFF121829);
  static const Color surfaceLight = Color(0xFF1E2640);

  // Viền & Hiệu ứng Glow
  static const Color border = Color(0xFF1F293D);
  static const Color primary = Color(0xFF00F0FF); // Neon Cyan (Màu chính)
  static const Color secondary = Color(
    0xFF8B5CF6,
  ); // Neon Purple (Chỉ số phụ/Giá tiền)
  static const Color accent = Color(0xFFF43F5E); // Neon Pink/Red (Cảnh báo)

  // Trạng thái thiết bị
  static const Color success = Color(0xFF10B981);
  static const Color danger = Color(0xFFEF4444);

  // Chữ & Mắt đọc
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);

  // Hiệu ứng phát sáng
  static Color glowCyan = const Color(0xFF00F0FF).withOpacity(0.15);
  static Color glowPurple = const Color(0xFF8B5CF6).withOpacity(0.15);
}
