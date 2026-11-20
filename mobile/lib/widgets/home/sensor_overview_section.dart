import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

class SensorOverviewSection extends StatelessWidget {
  final double temperature;
  final double humidity;
  final int lux;
  final bool motion;
  final bool isConnected;
  final int activeDeviceCount;
  final double instantPowerWatt;
  final bool isDark;

  const SensorOverviewSection({
    super.key,
    required this.temperature,
    required this.humidity,
    required this.lux,
    required this.motion,
    required this.isConnected,
    required this.activeDeviceCount,
    required this.instantPowerWatt,
    required this.isDark,
  });

  Color get _cyan => isDark ? AppColors.primary : const Color(0xFF0284C7);
  Color get _green => isDark ? Colors.greenAccent : const Color(0xFF0D9488);
  Color get _amber => isDark ? Colors.amber : const Color(0xFFD97706);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'CẢM BIẾN & TẢI TỨC THỜI',
              style: TextStyle(
                color: AppColors.getTextPrimary(isDark),
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.6,
              ),
            ),
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 8,
                  color: isConnected ? _green : AppColors.accent,
                ),
                const SizedBox(width: 5),
                Text(
                  isConnected ? 'LIVE WS/MQTT' : 'OFFLINE',
                  style: TextStyle(
                    color: isConnected ? _green : AppColors.accent,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildSensorTile(
                'NHIỆT ĐỘ',
                '${temperature.toStringAsFixed(1)}°C',
                Icons.thermostat,
                AppColors.accent,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildSensorTile(
                'ĐỘ ẨM',
                '${humidity.toStringAsFixed(0)}%',
                Icons.water_drop_outlined,
                _cyan,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildSensorTile(
                'ÁNH SÁNG',
                '$lux lx',
                Icons.wb_sunny_outlined,
                _amber,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildSensorTile(
                'CHUYỂN ĐỘNG',
                motion ? 'CÓ' : 'KHÔNG',
                Icons.directions_run,
                motion ? AppColors.accent : _green,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.getSurface(isDark),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _cyan.withOpacity(0.3)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.bolt, color: _amber, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    'Công suất tải đang bật ($activeDeviceCount thiết bị):',
                    style: TextStyle(
                      color: AppColors.getTextSecondary(isDark),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              Text(
                '${instantPowerWatt.toStringAsFixed(0)} W',
                style: TextStyle(
                  color: _cyan,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSensorTile(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: AppColors.getTextPrimary(isDark),
              fontSize: 14,
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
