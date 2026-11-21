import 'dart:io';

import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/excel_helper.dart';

void showSpaceExcelSheet({
  required BuildContext context,
  required bool isDark,
  required ApiService api,
  required JsonList existingHouses,
  required JsonList existingRooms,
  required void Function(String msg, {bool isError}) onSnack,
  required Future<void> Function() onRefresh,
}) {
  final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
  final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);

  bool isBusy = false;
  String? pickedFileName;
  JsonList validHouses = [];
  JsonList validRooms = [];
  List<String> skippedWarnings = [];

  String resolveHouseNameById(String houseId) {
    for (final h in existingHouses) {
      if ((h['id'] ?? '').toString() == houseId) {
        return (h['name'] ?? '').toString().trim();
      }
    }
    return '';
  }

  Future<void> exportSpacesExcel({required bool isTemplate}) async {
    final excel = Excel.createExcel();
    const houseSheetName = 'NgoiNha';
    const roomSheetName = 'Phong';

    final houseSheet = excel[houseSheetName];
    final roomSheet = excel[roomSheetName];
    excel.setDefaultSheet(houseSheetName);
    if (excel.sheets.containsKey('Sheet1')) {
      excel.delete('Sheet1');
    }

    houseSheet.appendRow([
      TextCellValue('Tên ngôi nhà'),
      TextCellValue('Địa chỉ'),
    ]);

    roomSheet.appendRow([
      TextCellValue('Tên phòng'),
      TextCellValue('Thuộc ngôi nhà'),
      TextCellValue('Tầng'),
    ]);

    if (isTemplate) {
      houseSheet.appendRow([
        TextCellValue('Biệt Thự Thảo Điền'),
        TextCellValue('12 Xuân Thủy, TP. Thủ Đức, TP.HCM'),
      ]);
      houseSheet.appendRow([
        TextCellValue('Nhà Phố Quận 7'),
        TextCellValue('45 Nguyễn Văn Linh, Quận 7, TP.HCM'),
      ]);

      roomSheet.appendRow([
        TextCellValue('Phòng Khách'),
        TextCellValue('Biệt Thự Thảo Điền'),
        IntCellValue(1),
      ]);
      roomSheet.appendRow([
        TextCellValue('Phòng Ngủ Master'),
        TextCellValue('Biệt Thự Thảo Điền'),
        IntCellValue(2),
      ]);
      roomSheet.appendRow([
        TextCellValue('Phòng Làm Việc'),
        TextCellValue('Nhà Phố Quận 7'),
        IntCellValue(1),
      ]);
    } else {
      for (final h in existingHouses) {
        houseSheet.appendRow([
          TextCellValue((h['name'] ?? '').toString()),
          TextCellValue((h['address'] ?? '').toString()),
        ]);
      }

      for (final r in existingRooms) {
        final hId = (r['house_id'] ?? '').toString();
        final hName = (r['house_name'] ?? resolveHouseNameById(hId)).toString();
        final floor = int.tryParse((r['floor'] ?? 1).toString()) ?? 1;

        roomSheet.appendRow([
          TextCellValue((r['name'] ?? '').toString()),
          TextCellValue(hName),
          IntCellValue(floor),
        ]);
      }
    }

    final savedPath = await ExcelHelper.saveAndShareExcel(
      excel: excel,
      fileName: isTemplate
          ? 'Mau_Nhap_Nha_Va_Phong_SmartHome.xlsx'
          : 'Danh_Sach_Nha_Va_Phong_${DateTime.now().millisecondsSinceEpoch}.xlsx',
      shareText: isTemplate
          ? 'File Excel mẫu nhập Nhà & Phòng SmartHome'
          : 'Danh sách Nhà (${existingHouses.length}) & Phòng (${existingRooms.length})',
    );
    onSnack('Đã xuất file Excel: $savedPath');
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
            try {
              final result = await FilePicker.pickFiles(
                type: FileType.custom,
                allowedExtensions: ['xlsx'],
              );
              if (result.isEmpty) return;

              final file = result.first;
              final bytes = file.path != null
                  ? await File(file.path!).readAsBytes()
                  : null;
              if (bytes == null) {
                onSnack('Không thể đọc nội dung file Excel!', isError: true);
                return;
              }

              final excel = ExcelHelper.decodeBytesSafe(bytes);
              if (excel.tables.isEmpty) {
                onSnack('File Excel không có trang tính nào!', isError: true);
                return;
              }

              Sheet? houseSheet;
              Sheet? roomSheet;

              for (final entry in excel.tables.entries) {
                final key = entry.key.trim().toLowerCase();
                if (key.contains('nha') ||
                    key.contains('nhà') ||
                    key.contains('house')) {
                  houseSheet ??= entry.value;
                } else if (key.contains('phong') ||
                    key.contains('phòng') ||
                    key.contains('room')) {
                  roomSheet ??= entry.value;
                }
              }

              final allSheets = excel.tables.values.toList();
              if (houseSheet == null && roomSheet == null) {
                if (allSheets.isNotEmpty) houseSheet = allSheets[0];
                if (allSheets.length > 1) roomSheet = allSheets[1];
              }

              final existingHouseNames = existingHouses
                  .map((h) => (h['name'] ?? '').toString().trim().toLowerCase())
                  .where((n) => n.isNotEmpty)
                  .toSet();
              final Set<String> newHouseNamesInFile = {};

              final JsonList parsedHouses = [];
              final JsonList parsedRooms = [];
              final List<String> warnings = [];

              if (houseSheet != null) {
                for (int i = 1; i < houseSheet.rows.length; i++) {
                  final row = houseSheet.rows[i];
                  if (row.isEmpty) continue;

                  final name = ExcelHelper.readCell(
                    row.isNotEmpty ? row[0] : null,
                  );
                  final address = ExcelHelper.readCell(
                    row.length > 1 ? row[1] : null,
                  );

                  if (name.isEmpty && address.isEmpty) continue;
                  if (name.isEmpty) {
                    warnings.add(
                      'Sheet Nhà - Dòng ${i + 1}: Thiếu tên ngôi nhà.',
                    );
                    continue;
                  }

                  final lowerName = name.toLowerCase();
                  if (existingHouseNames.contains(lowerName)) {
                    warnings.add(
                      'Sheet Nhà - Dòng ${i + 1}: Nhà "$name" đã tồn tại.',
                    );
                    continue;
                  }
                  if (newHouseNamesInFile.contains(lowerName)) {
                    warnings.add(
                      'Sheet Nhà - Dòng ${i + 1}: Trùng tên nhà "$name" trong file.',
                    );
                    continue;
                  }

                  newHouseNamesInFile.add(lowerName);
                  parsedHouses.add({'name': name, 'address': address});
                }
              }

              final existingRoomKeys = <String>{};
              for (final r in existingRooms) {
                final rName = (r['name'] ?? '').toString().trim().toLowerCase();
                final hId = (r['house_id'] ?? '').toString();
                final hName = (r['house_name'] ?? resolveHouseNameById(hId))
                    .toString()
                    .trim()
                    .toLowerCase();
                if (rName.isNotEmpty && hName.isNotEmpty) {
                  existingRoomKeys.add('$hName|$rName');
                }
              }
              final Set<String> seenRoomsInFile = {};

              if (roomSheet != null) {
                for (int i = 1; i < roomSheet.rows.length; i++) {
                  final row = roomSheet.rows[i];
                  if (row.isEmpty) continue;

                  final roomName = ExcelHelper.readCell(
                    row.isNotEmpty ? row[0] : null,
                  );
                  final houseName = ExcelHelper.readCell(
                    row.length > 1 ? row[1] : null,
                  );
                  final rawFloor = ExcelHelper.readCell(
                    row.length > 2 ? row[2] : null,
                    roundDouble: true,
                  );

                  if (roomName.isEmpty && houseName.isEmpty) continue;
                  if (roomName.isEmpty || houseName.isEmpty) {
                    warnings.add(
                      'Sheet Phòng - Dòng ${i + 1}: Thiếu tên phòng hoặc tên ngôi nhà.',
                    );
                    continue;
                  }

                  final lowerHouse = houseName.toLowerCase();
                  final lowerRoom = roomName.toLowerCase();
                  final roomKey = '$lowerHouse|$lowerRoom';

                  if (!existingHouseNames.contains(lowerHouse) &&
                      !newHouseNamesInFile.contains(lowerHouse)) {
                    warnings.add(
                      'Sheet Phòng - Dòng ${i + 1} ($roomName): Không tìm thấy nhà "$houseName".',
                    );
                    continue;
                  }
                  if (existingRoomKeys.contains(roomKey)) {
                    warnings.add(
                      'Sheet Phòng - Dòng ${i + 1}: Phòng "$roomName" đã có trong "$houseName".',
                    );
                    continue;
                  }
                  if (seenRoomsInFile.contains(roomKey)) {
                    warnings.add(
                      'Sheet Phòng - Dòng ${i + 1}: Trùng phòng "$roomName" trong file.',
                    );
                    continue;
                  }

                  final floor = int.tryParse(rawFloor) ?? 1;
                  seenRoomsInFile.add(roomKey);
                  parsedRooms.add({
                    'name': roomName,
                    'house_name': houseName,
                    'floor': floor > 0 ? floor : 1,
                  });
                }
              }

              setSheetState(() {
                pickedFileName = file.name;
                validHouses = parsedHouses;
                validRooms = parsedRooms;
                skippedWarnings = warnings;
              });
            } catch (e) {
              onSnack(
                'Lỗi đọc file Excel: ${e.toString().replaceFirst("Exception: ", "")}',
                isError: true,
              );
            }
          }

          Future<void> executeBatchImport() async {
            if (validHouses.isEmpty && validRooms.isEmpty) return;
            setSheetState(() => isBusy = true);

            int createdHouses = 0;
            for (final h in validHouses) {
              try {
                await api.createHouse(
                  name: (h['name'] ?? '').toString(),
                  address: (h['address'] ?? '').toString(),
                );
                createdHouses++;
              } catch (_) {}
            }

            JsonList latestHouses = existingHouses;
            if (validRooms.isNotEmpty) {
              try {
                latestHouses = await api.getHouses();
              } catch (_) {}
            }

            final Map<String, String> houseNameToId = {};
            for (final h in latestHouses) {
              final hName = (h['name'] ?? '').toString().trim().toLowerCase();
              final hId = (h['id'] ?? '').toString();
              if (hName.isNotEmpty && hId.isNotEmpty) {
                houseNameToId[hName] = hId;
              }
            }

            int createdRooms = 0;
            for (final r in validRooms) {
              final hNameLower = (r['house_name'] ?? '')
                  .toString()
                  .trim()
                  .toLowerCase();
              final targetHouseId = houseNameToId[hNameLower];
              if (targetHouseId == null || targetHouseId.isEmpty) continue;

              try {
                await api.createRoom(
                  houseId: targetHouseId,
                  name: (r['name'] ?? '').toString(),
                  floor: (r['floor'] as int?) ?? 1,
                );
                createdRooms++;
              } catch (_) {}
            }

            if (!context.mounted) return;
            Navigator.pop(ctx);
            onSnack(
              'Đã nhập thành công $createdHouses nhà và $createdRooms phòng từ Excel',
            );
            await onRefresh();
          }

          final totalValid = validHouses.length + validRooms.length;

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.76,
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
                              'NHẬP / XUẤT EXCEL NHÀ & PHÒNG',
                              style: TextStyle(
                                color: AppColors.getTextPrimary(isDark),
                                fontSize: 13.5,
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
                    Text(
                      '1. XUẤT DANH SÁCH NHÀ & PHÒNG (.XLSX)',
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
                                      await exportSpacesExcel(
                                        isTemplate: false,
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
                              'XUẤT (${existingHouses.length}N / ${existingRooms.length}P)',
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
                                      await exportSpacesExcel(isTemplate: true);
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
                    Text(
                      '2. NHẬP HÀNG LOẠT NHÀ & PHÒNG TỪ EXCEL (.XLSX)',
                      style: TextStyle(
                        color: cyan,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '• Sheet "NgoiNha": [A] Tên ngôi nhà | [B] Địa chỉ\n• Sheet "Phong": [A] Tên phòng | [B] Thuộc ngôi nhà | [C] Tầng',
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
                              'Bỏ qua ${skippedWarnings.length} dòng không hợp lệ / trùng lặp:',
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
                    if (totalValid > 0) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Sẵn sàng nhập ${validHouses.length} ngôi nhà và ${validRooms.length} phòng:',
                        style: TextStyle(
                          color: green,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...validHouses.map((h) {
                        final name = (h['name'] ?? '').toString();
                        final addr = (h['address'] ?? '').toString();
                        return Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.getBackground(isDark),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: cyan.withOpacity(0.35)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.home_work, color: cyan, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'NHÀ: $name',
                                      style: TextStyle(
                                        color: AppColors.getTextPrimary(isDark),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    if (addr.isNotEmpty)
                                      Text(
                                        addr,
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
                      ...validRooms.map((r) {
                        final name = (r['name'] ?? '').toString();
                        final hName = (r['house_name'] ?? '').toString();
                        final floor = r['floor'] ?? 1;
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
                              Icon(Icons.meeting_room, color: green, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'PHÒNG: $name (Tầng $floor)',
                                      style: TextStyle(
                                        color: AppColors.getTextPrimary(isDark),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Text(
                                      'Thuộc nhà: $hName',
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
                                : 'XÁC NHẬN NHẬP (${validHouses.length} NHÀ, ${validRooms.length} PHÒNG)',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 11.5,
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
