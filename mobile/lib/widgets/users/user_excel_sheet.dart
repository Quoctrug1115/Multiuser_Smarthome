import 'dart:io';

import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/api_service.dart';
import '../../theme/app_colors.dart';

void showUserExcelSheet({
  required BuildContext context,
  required bool isDark,
  required ApiService api,
  required JsonList existingUsers,
  required void Function(String msg, {bool isError}) onSnack,
  required Future<void> Function() onRefresh,
}) {
  final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
  final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);
  final amber = isDark ? Colors.amber : const Color(0xFFD97706);

  bool isBusy = false;
  String? pickedFileName;
  JsonList validRows = [];
  List<String> skippedWarnings = [];

  String normalizeRole(String raw) {
    final r = raw.trim().toLowerCase();
    if (r == 'admin' || r == 'quản trị' || r == 'quan tri') return 'Admin';
    if (r == 'guest' || r == 'khách' || r == 'khach') return 'Guest';
    return 'Member';
  }

  String readCell(Data? cell) {
    final v = cell?.value;
    if (v == null) return '';
    return switch (v) {
      TextCellValue() => v.value.toString().trim(),
      IntCellValue() => v.value.toString(),
      DoubleCellValue() => v.value.round().toString(),
      BoolCellValue() => v.value.toString(),
      _ => v.toString().trim(),
    };
  }

  Future<void> exportUsersExcel({required bool isTemplate}) async {
    final excel = Excel.createExcel();
    const sheetName = 'TaiKhoan_SmartHome';
    final sheet = excel[sheetName];
    excel.setDefaultSheet(sheetName);
    if (excel.sheets.containsKey('Sheet1')) {
      excel.delete('Sheet1');
    }

    if (isTemplate) {
      sheet.appendRow([
        TextCellValue('Họ và tên'),
        TextCellValue('Email'),
        TextCellValue('Mật khẩu'),
        TextCellValue('Vai trò (Admin/Member/Guest)'),
        TextCellValue('Thời hạn Guest (giờ)'),
      ]);
      sheet.appendRow([
        TextCellValue('Nguyễn Văn Thành'),
        TextCellValue('thanh.member@smarthome.vn'),
        TextCellValue('123456'),
        TextCellValue('Member'),
        TextCellValue(''),
      ]);
      sheet.appendRow([
        TextCellValue('Trần Minh Quản Trị'),
        TextCellValue('minh.admin@smarthome.vn'),
        TextCellValue('123456'),
        TextCellValue('Admin'),
        TextCellValue(''),
      ]);
      sheet.appendRow([
        TextCellValue('Khách Thăm Nhà'),
        TextCellValue('khach24h@smarthome.vn'),
        TextCellValue('123456'),
        TextCellValue('Guest'),
        IntCellValue(24),
      ]);
    } else {
      sheet.appendRow([
        TextCellValue('Họ và tên'),
        TextCellValue('Email'),
        TextCellValue('Vai trò'),
        TextCellValue('Trạng thái'),
        TextCellValue('Hết hạn (Guest)'),
      ]);

      for (final u in existingUsers) {
        final name = (u['full_name'] ?? u['name'] ?? '').toString();
        final email = (u['email'] ?? '').toString();
        final role = (u['role'] ?? u['role_name'] ?? 'Member').toString();
        final isActive = u['is_active'] != false;
        final expiresAt = (u['expires_at'] ?? u['guest_expires_at'] ?? '')
            .toString();

        sheet.appendRow([
          TextCellValue(name),
          TextCellValue(email),
          TextCellValue(role),
          TextCellValue(isActive ? 'Đang hoạt động' : 'Vô hiệu hóa'),
          TextCellValue(expiresAt),
        ]);
      }
    }

    final bytes = excel.save();
    if (bytes == null) {
      throw Exception('Không thể khởi tạo dữ liệu file Excel');
    }

    final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
    final fileName = isTemplate
        ? 'Mau_Nhap_Tai_Khoan_SmartHome.xlsx'
        : 'Danh_Sach_Tai_Khoan_${DateTime.now().millisecondsSinceEpoch}.xlsx';
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);

    try {
      await Share.shareXFiles(
        [XFile(file.path)],
        text: isTemplate
            ? 'File Excel mẫu nhập tài khoản SmartHome'
            : 'Danh sách tài khoản hộ gia đình (${existingUsers.length} tài khoản)',
      );
    } catch (_) {
      // Dự phòng trên môi trường Linux Desktop
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

            final excel = Excel.decodeBytes(bytes);
            if (excel.tables.isEmpty) {
              onSnack('File Excel không có trang tính nào!', isError: true);
              return;
            }

            final firstSheet = excel.tables.values.first;
            final existingEmails = existingUsers
                .map((u) => (u['email'] ?? '').toString().trim().toLowerCase())
                .where((e) => e.isNotEmpty)
                .toSet();
            final Set<String> seenInFile = {};

            final JsonList parsedValid = [];
            final List<String> warnings = [];

            for (int i = 1; i < firstSheet.rows.length; i++) {
              final row = firstSheet.rows[i];
              if (row.isEmpty) continue;

              final fullName = readCell(row.isNotEmpty ? row[0] : null);
              final email = readCell(row.length > 1 ? row[1] : null);
              final password = readCell(row.length > 2 ? row[2] : null);
              final rawRole = readCell(row.length > 3 ? row[3] : null);
              final rawHours = readCell(row.length > 4 ? row[4] : null);

              if (fullName.isEmpty && email.isEmpty && password.isEmpty) {
                continue;
              }
              if (fullName.isEmpty || email.isEmpty || password.isEmpty) {
                warnings.add(
                  'Dòng ${i + 1}: Thiếu Họ tên, Email hoặc Mật khẩu.',
                );
                continue;
              }
              if (!email.contains('@')) {
                warnings.add(
                  'Dòng ${i + 1} ($fullName): Email "$email" không hợp lệ.',
                );
                continue;
              }

              final lowerEmail = email.toLowerCase();
              if (existingEmails.contains(lowerEmail)) {
                warnings.add(
                  'Dòng ${i + 1} ($fullName): Email "$email" đã tồn tại.',
                );
                continue;
              }
              if (seenInFile.contains(lowerEmail)) {
                warnings.add(
                  'Dòng ${i + 1} ($fullName): Trùng email "$email" trong file.',
                );
                continue;
              }

              final role = normalizeRole(rawRole);
              final durationHours = int.tryParse(rawHours) ?? 24;

              seenInFile.add(lowerEmail);
              parsedValid.add({
                'full_name': fullName,
                'email': email,
                'password': password,
                'role': role,
                'duration_hours': durationHours > 0 ? durationHours : 24,
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
                final role = (item['role'] ?? 'Member').toString();
                if (role == 'Guest') {
                  await api.createGuest(
                    fullName: (item['full_name'] ?? '').toString(),
                    email: (item['email'] ?? '').toString(),
                    password: (item['password'] ?? '').toString(),
                    durationHours: (item['duration_hours'] as int?) ?? 24,
                  );
                } else {
                  await api.createUser(
                    fullName: (item['full_name'] ?? '').toString(),
                    email: (item['email'] ?? '').toString(),
                    password: (item['password'] ?? '').toString(),
                    role: role,
                  );
                }
                successCount++;
              } catch (_) {}
            }

            if (!context.mounted) return;
            Navigator.pop(ctx);
            onSnack(
              'Đã tạo thành công $successCount/${validRows.length} tài khoản từ Excel',
            );
            await onRefresh();
          }

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.74,
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
                            Icon(Icons.table_view, color: amber, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              'NHẬP / XUẤT EXCEL TÀI KHOẢN (OWNER)',
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

                    // 1. XUẤT DANH SÁCH & FILE MẪU
                    Text(
                      '1. XUẤT DANH SÁCH THÀNH VIÊN & FILE MẪU (.XLSX)',
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
                                      await exportUsersExcel(isTemplate: false);
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
                              'XUẤT EXCEL (${existingUsers.length})',
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
                                      await exportUsersExcel(isTemplate: true);
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

                    // 2. NHẬP TÀI KHOẢN TỪ EXCEL
                    Text(
                      '2. NHẬP HÀNG LOẠT TÀI KHOẢN TỪ EXCEL (.XLSX)',
                      style: TextStyle(
                        color: cyan,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Cấu trúc cột: [A] Họ và tên | [B] Email | [C] Mật khẩu | [D] Vai trò (Admin, Member, Guest) | [E] Thời hạn Guest (giờ)',
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
                              'Bỏ qua ${skippedWarnings.length} dòng không hợp lệ / trùng email:',
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
                        'Sẵn sàng tạo ${validRows.length} tài khoản hợp lệ:',
                        style: TextStyle(
                          color: green,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...validRows.map((item) {
                        final name = (item['full_name'] ?? '').toString();
                        final email = (item['email'] ?? '').toString();
                        final role = (item['role'] ?? 'Member').toString();
                        final hours = item['duration_hours'];

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
                              Icon(Icons.person_add, color: green, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '$name (${role.toUpperCase()})',
                                      style: TextStyle(
                                        color: AppColors.getTextPrimary(isDark),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Text(
                                      role == 'Guest'
                                          ? '$email • Hiệu lực $hours giờ'
                                          : email,
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
                                ? 'ĐANG TẠO TÀI KHOẢN...'
                                : 'XÁC NHẬN NHẬP (${validRows.length} TÀI KHOẢN)',
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
