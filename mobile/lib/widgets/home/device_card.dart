import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../theme/app_colors.dart';

class HomeDeviceCard extends StatelessWidget {
  final JsonMap device;
  final String roomName;
  final bool isDark;
  final bool isOwner;
  final bool canControl;
  final Future<void> Function(bool newVal) onToggle;
  final VoidCallback onEdit;
  final Future<void> Function() onDelete;

  const HomeDeviceCard({
    super.key,
    required this.device,
    required this.roomName,
    required this.isDark,
    required this.isOwner,
    required this.canControl,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  static bool isDeviceOn(JsonMap device) {
    final raw = device['is_on'] ?? device['status'] ?? device['state'];
    if (raw is bool) return raw;
    final str = (raw ?? '').toString().trim().toLowerCase();
    return str == 'true' || str == 'on' || str == '1' || str == 'active';
  }

  static IconData iconForType(String type) {
    switch (type.toLowerCase()) {
      case 'light':
        return Icons.lightbulb_outline;
      case 'fan':
        return Icons.air;
      case 'ac':
        return Icons.ac_unit;
      case 'sensor':
        return Icons.sensors;
      default:
        return Icons.power_settings_new;
    }
  }

  Color _deviceColor(String type, bool isOn) {
    final amber = isDark ? Colors.amber : const Color(0xFFD97706);
    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);

    if (type.toLowerCase() == 'sensor') return amber;
    if (!isOn) return AppColors.textMuted;
    switch (type.toLowerCase()) {
      case 'light':
        return cyan;
      case 'fan':
      case 'ac':
        return green;
      default:
        return AppColors.secondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = (device['name'] ?? 'Thiết bị').toString();
    final type = (device['device_type'] ?? 'switch').toString();
    final topic = (device['mqtt_topic'] ?? '').toString();
    final isSensor = type.toLowerCase() == 'sensor';
    final isOn = isDeviceOn(device);
    final deviceColor = _deviceColor(type, isOn);
    final amber = isDark ? Colors.amber : const Color(0xFFD97706);
    final isOnline = device['is_online'] != false;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSensor
              ? amber.withOpacity(0.35)
              : (isOn
                    ? deviceColor.withOpacity(0.5)
                    : (isDark ? Colors.white12 : Colors.black12)),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: deviceColor.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(iconForType(type), color: deviceColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.getTextPrimary(isDark),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: deviceColor.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            type.toUpperCase(),
                            style: TextStyle(
                              color: deviceColor,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      roomName.isNotEmpty ? '$roomName • $topic' : topic,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (isOwner)
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert,
                    color: AppColors.textMuted,
                    size: 20,
                  ),
                  color: AppColors.getSurface(isDark),
                  onSelected: (action) async {
                    if (action == 'edit') {
                      onEdit();
                    } else if (action == 'delete') {
                      await onDelete();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(
                            Icons.edit_outlined,
                            size: 18,
                            color: AppColors.getTextPrimary(isDark),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Chỉnh sửa',
                            style: TextStyle(
                              color: AppColors.getTextPrimary(isDark),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: AppColors.accent,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Xóa thiết bị',
                            style: TextStyle(
                              color: AppColors.accent,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
          Divider(height: 20, color: isDark ? Colors.white10 : Colors.black12),
          if (isSensor)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'TELEMETRY STREAM (5S)',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  'ONLINE',
                  style: TextStyle(
                    color: amber,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'ĐIỀU KHIỂN MQTT',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                Row(
                  children: [
                    Text(
                      isOn ? 'ĐANG BẬT' : 'ĐÃ TẮT',
                      style: TextStyle(
                        color: isOn ? deviceColor : AppColors.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Switch(
                      value: isOn,
                      activeColor: deviceColor,
                      // Trong Switch của HomeDeviceCard:
                      onChanged: (canControl && isOnline)
                          ? (val) => onToggle(val)
                          : null,
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }
}
