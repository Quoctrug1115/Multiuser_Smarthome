import 'dart:io';

import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/smarthome_models.dart';
import '../../services/api_service.dart';
import '../../theme/app_colors.dart';
import 'device_card.dart';

void showDeviceExcelSheet({
  required BuildContext context,
  required bool isDark,
  required ApiService api,
  required JsonList devices,
  required JsonList rooms,
  required void Function(String msg, String tag) onLog,
  required void Function(String msg, {bool isError}) onSnack,
  required Future<void> Function() onRefresh,
}) {
  final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
  final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);

  bool isBusy = false;
  String? pickedFileName;
  JsonList validRows = [];
  List<String> skippedWarnings = [];

  String resolveRoomName(JsonMap device) {
    final direct = (device['room_name'] ?? '').toString().trim();
    if (direct.isNotEmpty) return direct;
    final roomId = (device['room_id'] ?? '').toString();
    for (final r in rooms) {
      if ((r['id'] ?? '').toString() == roomId) {
        return (r['name'] ?? '').toString();
      }
    }
    return '';
  }

  String? matchRoomIdByName(String roomName) {
    final target = roomName.trim().toLowerCase();
    if (target.isEmpty) return null;
    for (final r in rooms) {
      final rName = (r['name'] ?? '').toString().trim().toLowerCase();
      if (rName == target) return r['id'].toString();
    }
    return null;
  }

  String normalizeDeviceType(String raw) {
    final t = raw.trim().toLowerCase();
    const valid = ['light', 'switch', 'fan', 'ac', 'sensor'];
    if (valid.contains(t)) return t;
    if (t.contains('đèn') || t.contains('den')) return 'light';
    if (t.contains('quạt') || t.contains('quat')) return 'fan';
    if (t.contains('điều hòa') || t.contains('dieu hoa')) return 'ac';
    if (t.contains('cảm biến') || t.contains('cam bien')) return 'sensor';
    return 'switch';
  }

  String readCell(Data? cell) {
    final v = cell?.value;
    if (v == null) return '';
    return switch (v) {
      TextCellValue() => v.value.toString().trim(),
      IntCellValue() => v.value.toString(),
      DoubleCellValue() => v.value.toString(),
      BoolCellValue() => v.value.toString(),
      _ => v.toString().trim(),
    };
  }

  Future<void> exportExcel({required bool isTemplate}) async {
    final excel = Excel.createExcel();
    const sheetName = 'ThietBi_SmartHome';
    final sheet = excel[sheetName];
    excel.setDefaultSheet(sheetName);
    if (excel.sheets.containsKey('Sheet1')) {
      excel.delete('Sheet1');
    }

    sheet.appendRow([
      TextCellValue('Tên thiết bị'),
      TextCellValue('Loại thiết bị (light/switch/fan/ac/sensor)'),
      TextCellValue('MQTT Topic'),
      TextCellValue('Tên phòng'),
      TextCellValue('Trạng thái'),
      TextCellValue('Công suất định mức (W)'),
    ]);

    if (isTemplate) {
      final sampleRoom = rooms.isNotEmpty
          ? (rooms.first['name'] ?? 'Phòng Khách').toString()
          : 'Phòng Khách';
      sheet.appendRow([
        TextCellValue('Đèn Trần Phòng Khách'),
        TextCellValue('light'),
        TextCellValue('smarthome/devices/den_tran_pk'),
        TextCellValue(sampleRoom),
        TextCellValue('OFF'),
        IntCellValue(18),
      ]);
      sheet.appendRow([
        TextCellValue('Quạt Đứng Phòng Ngủ'),
        TextCellValue('fan'),
        TextCellValue('smarthome/devices/quat_phong_ngu'),
        TextCellValue(sampleRoom),
        TextCellValue('OFF'),
        IntCellValue(55),
      ]);
    } else {
      for (final d in devices) {
        final model = Device.fromJson(d);
        final isOn = HomeDeviceCard.isDeviceOn(d);
        final topic = (d['mqtt_topic'] ?? '').toString();
        sheet.appendRow([
          TextCellValue(model.name),
          TextCellValue(model.deviceType),
          TextCellValue(topic),
          TextCellValue(resolveRoomName(d)),
          TextCellValue(isOn ? 'ON' : 'OFF'),
          DoubleCellValue(model.ratedPowerWatt),
        ]);
      }
    }

    final bytes = excel.save();
    if (bytes == null) {
      throw Exception('Không thể tạo dữ liệu file Excel');
    }

    final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
    final fileName = isTemplate
        ? 'Mau_Nhap_Thiet_Bi_SmartHome.xlsx'
        : 'Danh_Sach_Thiet_Bi_${DateTime.now().millisecondsSinceEpoch}.xlsx';
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);

    try {
      await Share.shareXFiles(
        [XFile(file.path)],
        text: isTemplate
            ? 'File Excel mẫu nhập thiết bị SmartHome'
            : 'Danh sách thiết bị SmartHome (${devices.length} thiết bị)',
      );
    } catch (_) {
      // Dự phòng hiển thị đường dẫn lưu file trên Linux Desktop
    }
    onSnack('Đã xuất file Excel: ${file.path}');
  }

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.getSurface(isDark),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> pickAndParseExcel() async {
            final result = await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: ['xlsx'],
              withData: true,
            );
            if (result == null || result.files.isEmpty) return;

            final file = result.files.first;
            final bytes =
                file.bytes ??
                (file.path != null
                    ? await File(file.path!).readAsBytes()
                    : null);
            if (bytes == null) {
              onSnack('Không thể đọc nội dung file Excel!', isError: true);
              return;
            }

            final excel = Excel.decodeBytes(bytes);
            if (excel.tables.isEmpty) {
              onSnack('File Excel không có trang tính nào!', isError: true);
              return;
            }

            final firstSheet = excel.tables.values.first;
            final existingTopics = devices
                .map(
                  (d) =>
                      (d['mqtt_topic'] ?? '').toString().trim().toLowerCase(),
                )
                .where((t) => t.isNotEmpty)
                .toSet();
            final Set<String> seenInFile = {};

            final JsonList parsedValid = [];
            final List<String> warnings = [];

            for (int i = 1; i < firstSheet.rows.length; i++) {
              final row = firstSheet.rows[i];
              if (row.isEmpty) continue;

              final name = readCell(row.isNotEmpty ? row[0] : null);
              final rawType = readCell(row.length > 1 ? row[1] : null);
              final topic = readCell(row.length > 2 ? row[2] : null);
              final roomName = readCell(row.length > 3 ? row[3] : null);

              if (name.isEmpty && topic.isEmpty) continue;
              if (name.isEmpty || topic.isEmpty) {
                warnings.add(
                  'Dòng ${i + 1}: Thiếu tên thiết bị hoặc MQTT Topic.',
                );
                continue;
              }

              final lowerTopic = topic.toLowerCase();
              if (existingTopics.contains(lowerTopic)) {
                warnings.add(
                  'Dòng ${i + 1} ($name): Topic "$topic" đã tồn tại.',
                );
                continue;
              }
              if (seenInFile.contains(lowerTopic)) {
                warnings.add('Dòng ${i + 1} ($name): Trùng topic trong file.');
                continue;
              }

              seenInFile.add(lowerTopic);
              parsedValid.add({
                'name': name,
                'device_type': normalizeDeviceType(rawType),
                'mqtt_topic': topic,
                'room_name': roomName,
                'room_id': matchRoomIdByName(roomName) ?? '',
              });
            }

            setSheetState(() {
              pickedFileName = file.name;
              validRows = parsedValid;
              skippedWarnings = warnings;
            });
          }

          Future<void> executeBatchImport() async {
            if (validRows.isEmpty) return;
            setSheetState(() => isBusy = true);
            int successCount = 0;

            for (final item in validRows) {
              try {
                final roomId = (item['room_id'] ?? '').toString();
                await api.createDevice(
                  name: (item['name'] ?? '').toString(),
                  deviceType: (item['device_type'] ?? 'switch').toString(),
                  mqttTopic: (item['mqtt_topic'] ?? '').toString(),
                  roomId: roomId.isEmpty ? null : roomId,
                );
                successCount++;
              } catch (_) {}
            }

            if (!context.mounted) return;
            Navigator.pop(ctx);
            onLog(
              'Nhập Excel: Thêm thành công $successCount/${validRows.length} thiết bị',
              'EXCEL',
            );
            onSnack('Đã nhập thành công $successCount thiết bị từ Excel');
            await onRefresh();
          }

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.72,
            maxChildSize: 0.92,
            minChildSize: 0.45,
            builder: (_, scrollCtrl) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: ListView(
                  controller: scrollCtrl,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.table_view, color: green, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              'NHẬP / XUẤT EXCEL THIẾT BỊ',
                              style: TextStyle(
                                color: AppColors.getTextPrimary(isDark),
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const Divider(),
                    const SizedBox(height: 6),

                    // 1. XUẤT EXCEL & TẢI FILE MẪU
                    Text(
                      '1. XUẤT DỮ LIỆU & FILE MẪU (.XLSX)',
                      style: TextStyle(
                        color: cyan,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: green,
                              foregroundColor: isDark
                                  ? const Color(0xFF0A0E1A)
                                  : Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 11),
                            ),
                            onPressed: isBusy
                                ? null
                                : () async {
                                    try {
                                      await exportExcel(isTemplate: false);
                                      onLog(
                                        'Xuất danh sách ${devices.length} thiết bị ra Excel',
                                        'EXCEL',
                                      );
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
                            icon: const Icon(
                              Icons.file_download_outlined,
                              size: 18,
                            ),
                            label: Text(
                              'XUẤT EXCEL (${devices.length})',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: cyan,
                              side: BorderSide(color: cyan),
                              padding: const EdgeInsets.symmetric(vertical: 11),
                            ),
                            onPressed: isBusy
                                ? null
                                : () async {
                                    try {
                                      await exportExcel(isTemplate: true);
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
                            icon: const Icon(
                              Icons.description_outlined,
                              size: 18,
                            ),
                            label: const Text(
                              'TẢI FILE MẪU',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // 2. NHẬP THIẾT BỊ TỪ EXCEL
                    Text(
                      '2. NHẬP THIẾT BỊ TỪ FILE EXCEL (.XLSX)',
                      style: TextStyle(
                        color: cyan,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Cấu trúc cột: [A] Tên thiết bị | [B] Loại (light, switch, fan, ac, sensor) | [C] MQTT Topic | [D] Tên phòng',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.getTextPrimary(isDark),
                        side: BorderSide(
                          color: isDark ? Colors.white24 : Colors.black26,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: isBusy ? null : pickAndParseExcel,
                      icon: Icon(Icons.upload_file, color: cyan),
                      label: Text(
                        pickedFileName ?? 'CHỌN FILE EXCEL (.XLSX) TỪ MÁY',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),

                    if (skippedWarnings.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AppColors.accent.withOpacity(0.4),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Bỏ qua ${skippedWarnings.length} dòng không hợp lệ / trùng topic:',
                              style: const TextStyle(
                                color: AppColors.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            ...skippedWarnings
                                .take(5)
                                .map(
                                  (w) => Text(
                                    '• $w',
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ],

                    if (validRows.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Sẵn sàng nhập ${validRows.length} thiết bị hợp lệ:',
                        style: TextStyle(
                          color: green,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...validRows.map((item) {
                        final itemName = (item['name'] ?? '').toString();
                        final itemType = (item['device_type'] ?? 'switch')
                            .toString();
                        final itemTopic = (item['mqtt_topic'] ?? '').toString();

                        return Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.getBackground(isDark),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: green.withOpacity(0.35)),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                HomeDeviceCard.iconForType(itemType),
                                color: green,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      itemName,
                                      style: TextStyle(
                                        color: AppColors.getTextPrimary(isDark),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Text(
                                      '${itemType.toUpperCase()} • $itemTopic',
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppColors.textMuted,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: cyan,
                            foregroundColor: isDark
                                ? const Color(0xFF0A0E1A)
                                : Colors.white,
                          ),
                          onPressed: isBusy ? null : executeBatchImport,
                          icon: isBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.cloud_upload_outlined),
                          label: Text(
                            isBusy
                                ? 'ĐANG NHẬP DỮ LIỆU...'
                                : 'XÁC NHẬN NHẬP (${validRows.length} THIẾT BỊ)',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          );
        },
      );
    },
  );
}
