import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

class SensorOverviewSection extends StatelessWidget {
  final double? temperature;
  final double? humidity;
  final int? lux;
  final bool? motion;
  final double totalWatt;
  final bool isDark;

  const SensorOverviewSection({
    super.key,
    required this.temperature,
    required this.humidity,
    required this.lux,
    required this.motion,
    this.totalWatt = 0.0,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);
    final amber = isDark ? Colors.amber : const Color(0xFFD97706);

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildSensorTile(
                icon: Icons.thermostat,
                label: 'NHIỆT ĐỘ',
                value: temperature != null
                    ? '${temperature!.toStringAsFixed(1)}°C'
                    : '--°C',
                color: (temperature ?? 0) > 35 ? AppColors.accent : amber,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildSensorTile(
                icon: Icons.water_drop_outlined,
                label: 'ĐỘ ẨM',
                value: humidity != null
                    ? '${humidity!.toStringAsFixed(0)}%'
                    : '--%',
                color: cyan,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildSensorTile(
                icon: Icons.wb_sunny_outlined,
                label: 'ÁNH SÁNG',
                value: lux != null ? '$lux lx' : '-- lx',
                color: green,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildSensorTile(
                icon: motion == true ? Icons.sensors : Icons.sensors_off,
                label: 'CHUYỂN ĐỘNG',
                value: motion == null
                    ? 'CHƯA KẾT NỐI'
                    : (motion! ? 'CÓ NGƯỜI' : 'AN TOÀN'),
                color: motion == true ? AppColors.accent : AppColors.secondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.getSurface(isDark),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cyan.withOpacity(0.35)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.bolt, color: amber, size: 19),
                  const SizedBox(width: 8),
                  Text(
                    'TỔNG CÔNG SUẤT ĐANG TẢI',
                    style: TextStyle(
                      color: AppColors.getTextSecondary(isDark),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Text(
                '${totalWatt.toStringAsFixed(0)} W',
                style: TextStyle(
                  color: cyan,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSensorTile({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 17,
            backgroundColor: color.withOpacity(0.15),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.getTextPrimary(isDark),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
