import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../theme/app_colors.dart';
import 'device_card.dart';

void showWokwiDiscoveryDialog({
  required BuildContext context,
  required bool isDark,
  required ApiService api,
  required JsonList rooms,
  required JsonList existingDevices,
  required void Function(String msg, String tag) onLog,
  required void Function(String msg, {bool isError}) onSnack,
  required Future<void> Function() onRefresh,
}) {
  final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
  String? chosenRoomId = rooms.isNotEmpty ? rooms.first['id'].toString() : null;

  final existingTopics = existingDevices
      .map((d) => (d['mqtt_topic'] ?? '').toString().trim().toLowerCase())
      .where((t) => t.isNotEmpty)
      .toSet();
  final addedInSession = <String>{};

  showDialog(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: AppColors.getSurface(isDark),
            title: Row(
              children: [
                Icon(Icons.radar, color: cyan, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'QUÉT THIẾT BỊ WOKWI (MQTT)',
                    style: TextStyle(
                      color: AppColors.getTextPrimary(isDark),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (rooms.isNotEmpty) ...[
                    DropdownButtonFormField<String>(
                      value: chosenRoomId,
                      dropdownColor: AppColors.getSurface(isDark),
                      style: TextStyle(
                        color: AppColors.getTextPrimary(isDark),
                        fontSize: 12,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Gán vào phòng mặc định',
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem<String>(
                          value: '',
                          child: Text('Không gán phòng'),
                        ),
                        ...rooms.map(
                          (r) => DropdownMenuItem<String>(
                            value: r['id'].toString(),
                            child: Text((r['name'] ?? '').toString()),
                          ),
                        ),
                      ],
                      onChanged: (val) =>
                          setDialogState(() => chosenRoomId = val),
                    ),
                    const SizedBox(height: 10),
                  ],
                  FutureBuilder<JsonList>(
                    future: api.discoverWokwiDevices(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return SizedBox(
                          height: 120,
                          child: Center(
                            child: CircularProgressIndicator(color: cyan),
                          ),
                        );
                      }
                      final rawDiscovered = snapshot.data ?? [];
                      final discovered = rawDiscovered.where((item) {
                        final topic = (item['mqtt_topic'] ?? '')
                            .toString()
                            .trim()
                            .toLowerCase();
                        return topic.isNotEmpty &&
                            !existingTopics.contains(topic) &&
                            !addedInSession.contains(topic);
                      }).toList();

                      if (discovered.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'Tất cả thiết bị Wokwi khả dụng đều đã được thêm vào nhà.\nNếu có thiết bị mới, hãy đảm bảo Wokwi đang chạy (Play) rồi bấm Quét lại.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        );
                      }
                      return ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 280),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: discovered.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final item = discovered[index];
                            final name = (item['name'] ?? 'Thiết bị Wokwi')
                                .toString();
                            final type = (item['device_type'] ?? 'switch')
                                .toString();
                            final topic = (item['mqtt_topic'] ?? '')
                                .toString()
                                .trim();

                            return Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppColors.getBackground(isDark),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: cyan.withOpacity(0.4),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    HomeDeviceCard.iconForType(type),
                                    color: cyan,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          name,
                                          style: TextStyle(
                                            color: AppColors.getTextPrimary(
                                              isDark,
                                            ),
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                        Text(
                                          '${type.toUpperCase()} • $topic',
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: AppColors.textMuted,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: cyan,
                                      foregroundColor: isDark
                                          ? const Color(0xFF0A0E1A)
                                          : Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                    ),
                                    onPressed: () async {
                                      try {
                                        await api.createDevice(
                                          name: name,
                                          deviceType: type,
                                          mqttTopic: topic,
                                          roomId:
                                              (chosenRoomId != null &&
                                                  chosenRoomId!.isNotEmpty)
                                              ? chosenRoomId
                                              : null,
                                        );
                                        addedInSession.add(topic.toLowerCase());
                                        if (context.mounted) {
                                          setDialogState(() {});
                                        }
                                        onLog(
                                          'Thêm thiết bị Wokwi: $name',
                                          'DEVICE',
                                        );
                                        onSnack('Đã thêm "$name"');
                                        await onRefresh();
                                      } catch (e) {
                                        onSnack(
                                          e.toString().replaceFirst(
                                            'Exception: ',
                                            '',
                                          ),
                                          isError: true,
                                        );
                                      }
                                    },
                                    child: const Text(
                                      'THÊM',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => setDialogState(() {}),
                child: const Text('QUÉT LẠI'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ĐÓNG'),
              ),
            ],
          );
        },
      );
    },
  );
}

void showDeviceFormDialog({
  required BuildContext context,
  required bool isDark,
  required ApiService api,
  required JsonList rooms,
  JsonMap? existingDevice,
  required void Function(String msg, String tag) onLog,
  required void Function(String msg, {bool isError}) onSnack,
  required Future<void> Function() onRefresh,
}) {
  final isEdit = existingDevice != null;
  final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
  final nameCtrl = TextEditingController(
    text: existingDevice?['name']?.toString() ?? '',
  );
  final topicCtrl = TextEditingController(
    text:
        existingDevice?['mqtt_topic']?.toString() ??
        'smarthome/devices/led_phong_khach',
  );

  const validTypes = ['light', 'switch', 'fan', 'ac', 'sensor'];
  final rawType = (existingDevice?['device_type'] ?? 'light')
      .toString()
      .toLowerCase();
  String selectedType = validTypes.contains(rawType) ? rawType : 'switch';

  String selectedRoom = (existingDevice?['room_id'] ?? '').toString();
  if (selectedRoom.isNotEmpty &&
      !rooms.any((r) => r['id'].toString() == selectedRoom)) {
    selectedRoom = '';
  }

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDialogState) {
        return AlertDialog(
          backgroundColor: AppColors.getSurface(isDark),
          title: Text(
            isEdit ? 'CẬP NHẬT THIẾT BỊ' : 'THÊM THIẾT BỊ MỚI',
            style: TextStyle(
              color: AppColors.getTextPrimary(isDark),
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  style: TextStyle(
                    color: AppColors.getTextPrimary(isDark),
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Tên thiết bị',
                    prefixIcon: Icon(
                      Icons.devices_other,
                      color: cyan,
                      size: 18,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: selectedType,
                  dropdownColor: AppColors.getSurface(isDark),
                  style: TextStyle(
                    color: AppColors.getTextPrimary(isDark),
                    fontSize: 13,
                  ),
                  decoration: const InputDecoration(labelText: 'Loại thiết bị'),
                  items: const [
                    DropdownMenuItem(
                      value: 'light',
                      child: Text('LIGHT (Đèn)'),
                    ),
                    DropdownMenuItem(
                      value: 'switch',
                      child: Text('SWITCH (Công tắc)'),
                    ),
                    DropdownMenuItem(value: 'fan', child: Text('FAN (Quạt)')),
                    DropdownMenuItem(value: 'ac', child: Text('AC (Điều hòa)')),
                    DropdownMenuItem(
                      value: 'sensor',
                      child: Text('SENSOR (Cảm biến)'),
                    ),
                  ],
                  onChanged: (val) {
                    if (val != null) setDialogState(() => selectedType = val);
                  },
                ),
                const SizedBox(height: 12),
                if (rooms.isNotEmpty) ...[
                  DropdownButtonFormField<String>(
                    value: selectedRoom,
                    dropdownColor: AppColors.getSurface(isDark),
                    style: TextStyle(
                      color: AppColors.getTextPrimary(isDark),
                      fontSize: 13,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Vị trí phòng',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Chưa gán phòng'),
                      ),
                      ...rooms.map(
                        (r) => DropdownMenuItem(
                          value: r['id'].toString(),
                          child: Text((r['name'] ?? '').toString()),
                        ),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => selectedRoom = val);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: topicCtrl,
                  style: TextStyle(
                    color: AppColors.getTextPrimary(isDark),
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    labelText: 'MQTT Topic',
                    prefixIcon: Icon(
                      Icons.router_outlined,
                      color: cyan,
                      size: 18,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('HỦY'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: cyan,
                foregroundColor: isDark
                    ? const Color(0xFF0A0E1A)
                    : Colors.white,
              ),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final topic = topicCtrl.text.trim();
                if (name.isEmpty || topic.isEmpty) {
                  onSnack('Vui lòng nhập đầy đủ tên và topic!', isError: true);
                  return;
                }
                Navigator.pop(ctx);
                try {
                  if (isEdit) {
                    await api.updateDevice(
                      existingDevice['id'].toString(),
                      name: name,
                      deviceType: selectedType,
                      mqttTopic: topic,
                      roomId: selectedRoom.isEmpty ? null : selectedRoom,
                    );
                    onLog('Cập nhật thiết bị: $name', 'DEVICE');
                    onSnack('Đã cập nhật thiết bị');
                  } else {
                    await api.createDevice(
                      name: name,
                      deviceType: selectedType,
                      mqttTopic: topic,
                      roomId: selectedRoom.isEmpty ? null : selectedRoom,
                    );
                    onLog('Tạo mới thiết bị: $name', 'DEVICE');
                    onSnack('Đã thêm thiết bị mới');
                  }
                  await onRefresh();
                } catch (e) {
                  onSnack(
                    e.toString().replaceFirst('Exception: ', ''),
                    isError: true,
                  );
                }
              },
              child: Text(
                isEdit ? 'LƯU' : 'TẠO MỚI',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    ),
  );
}
