import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../theme/app_colors.dart';

void showSpaceManagerSheet({
  required BuildContext context,
  required bool isDark,
  required ApiService api,
  required JsonList Function() getHouses,
  required JsonList Function() getRooms,
  required Future<void> Function() onReloadSpaces,
  required void Function(String msg, {bool isError}) onSnack,
}) {
  final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
  final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);

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
          final houses = getHouses();
          final rooms = getRooms();

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            maxChildSize: 0.92,
            minChildSize: 0.5,
            builder: (_, scrollCtrl) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: ListView(
                  controller: scrollCtrl,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'QUẢN LÝ KHÔNG GIAN NHÀ & PHÒNG',
                          style: TextStyle(
                            color: AppColors.getTextPrimary(isDark),
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const Divider(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'DANH SÁCH NGÔI NHÀ (${houses.length})',
                          style: TextStyle(
                            color: cyan,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => _showHouseFormDialog(
                            context: context,
                            isDark: isDark,
                            api: api,
                            onSnack: onSnack,
                            onSaved: () async {
                              await onReloadSpaces();
                              setSheetState(() {});
                            },
                          ),
                          icon: Icon(Icons.add_home, size: 16, color: cyan),
                          label: Text(
                            'THÊM NHÀ',
                            style: TextStyle(color: cyan, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    if (houses.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Chưa có ngôi nhà nào. Hãy thêm ngôi nhà đầu tiên.',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      )
                    else
                      ...houses.map((h) {
                        final hId = h['id'].toString();
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.home_work_outlined, color: cyan),
                          title: Text(
                            (h['name'] ?? '').toString(),
                            style: TextStyle(
                              color: AppColors.getTextPrimary(isDark),
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: Text(
                            (h['address'] ?? 'Chưa cập nhật địa chỉ')
                                .toString(),
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 11,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                onPressed: () => _showHouseFormDialog(
                                  context: context,
                                  isDark: isDark,
                                  api: api,
                                  existingHouse: h,
                                  onSnack: onSnack,
                                  onSaved: () async {
                                    await onReloadSpaces();
                                    setSheetState(() {});
                                  },
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                  color: AppColors.accent,
                                ),
                                onPressed: () async {
                                  try {
                                    await api.deleteHouse(hId);
                                    await onReloadSpaces();
                                    setSheetState(() {});
                                    onSnack('Đã xóa ngôi nhà');
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
                              ),
                            ],
                          ),
                        );
                      }),
                    const SizedBox(height: 12),
                    const Divider(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'DANH SÁCH PHÒNG (${rooms.length})',
                          style: TextStyle(
                            color: cyan,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: houses.isEmpty
                              ? () => onSnack(
                                  'Vui lòng tạo ít nhất 1 Ngôi nhà trước!',
                                  isError: true,
                                )
                              : () => _showRoomFormDialog(
                                  context: context,
                                  isDark: isDark,
                                  api: api,
                                  houses: houses,
                                  onSnack: onSnack,
                                  onSaved: () async {
                                    await onReloadSpaces();
                                    setSheetState(() {});
                                  },
                                ),
                          icon: Icon(
                            Icons.meeting_room_outlined,
                            size: 16,
                            color: cyan,
                          ),
                          label: Text(
                            'THÊM PHÒNG',
                            style: TextStyle(color: cyan, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    if (rooms.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Chưa có phòng nào được tạo.',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      )
                    else
                      ...rooms.map((r) {
                        final rId = r['id'].toString();
                        final floor = r['floor'] ?? 1;
                        final houseName = (r['house_name'] ?? '').toString();
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.meeting_room, color: green),
                          title: Text(
                            '${r['name']} (Tầng $floor)',
                            style: TextStyle(
                              color: AppColors.getTextPrimary(isDark),
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: houseName.isNotEmpty
                              ? Text(
                                  houseName,
                                  style: const TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 11,
                                  ),
                                )
                              : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                onPressed: () => _showRoomFormDialog(
                                  context: context,
                                  isDark: isDark,
                                  api: api,
                                  houses: houses,
                                  existingRoom: r,
                                  onSnack: onSnack,
                                  onSaved: () async {
                                    await onReloadSpaces();
                                    setSheetState(() {});
                                  },
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                  color: AppColors.accent,
                                ),
                                onPressed: () async {
                                  try {
                                    await api.deleteRoom(rId);
                                    await onReloadSpaces();
                                    setSheetState(() {});
                                    onSnack('Đã xóa phòng');
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
                              ),
                            ],
                          ),
                        );
                      }),
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

void _showHouseFormDialog({
  required BuildContext context,
  required bool isDark,
  required ApiService api,
  JsonMap? existingHouse,
  required void Function(String msg, {bool isError}) onSnack,
  required Future<void> Function() onSaved,
}) {
  final isEdit = existingHouse != null;
  final nameCtrl = TextEditingController(
    text: existingHouse?['name']?.toString() ?? '',
  );
  final addrCtrl = TextEditingController(
    text: existingHouse?['address']?.toString() ?? '',
  );
  final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.getSurface(isDark),
      title: Text(
        isEdit ? 'CẬP NHẬT NGÔI NHÀ' : 'THÊM NGÔI NHÀ MỚI',
        style: TextStyle(
          color: AppColors.getTextPrimary(isDark),
          fontSize: 15,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameCtrl,
            style: TextStyle(color: AppColors.getTextPrimary(isDark)),
            decoration: const InputDecoration(labelText: 'Tên ngôi nhà'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: addrCtrl,
            style: TextStyle(color: AppColors.getTextPrimary(isDark)),
            decoration: const InputDecoration(labelText: 'Địa chỉ'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('HỦY'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: cyan,
            foregroundColor: isDark ? const Color(0xFF0A0E1A) : Colors.white,
          ),
          onPressed: () async {
            if (nameCtrl.text.trim().isEmpty) return;
            Navigator.pop(ctx);
            try {
              if (isEdit) {
                await api.updateHouse(
                  existingHouse['id'].toString(),
                  name: nameCtrl.text.trim(),
                  address: addrCtrl.text.trim(),
                );
              } else {
                await api.createHouse(
                  name: nameCtrl.text.trim(),
                  address: addrCtrl.text.trim(),
                );
              }
              await onSaved();
              onSnack(isEdit ? 'Đã cập nhật nhà' : 'Đã tạo nhà mới');
            } catch (e) {
              onSnack(
                e.toString().replaceFirst('Exception: ', ''),
                isError: true,
              );
            }
          },
          child: Text(isEdit ? 'LƯU' : 'TẠO'),
        ),
      ],
    ),
  );
}

void _showRoomFormDialog({
  required BuildContext context,
  required bool isDark,
  required ApiService api,
  required JsonList houses,
  JsonMap? existingRoom,
  required void Function(String msg, {bool isError}) onSnack,
  required Future<void> Function() onSaved,
}) {
  final isEdit = existingRoom != null;
  final nameCtrl = TextEditingController(
    text: existingRoom?['name']?.toString() ?? '',
  );
  final floorCtrl = TextEditingController(
    text: (existingRoom?['floor'] ?? 1).toString(),
  );
  String selectedHouse =
      (existingRoom?['house_id'] ??
              (houses.isNotEmpty ? houses.first['id'] : ''))
          .toString();
  if (!houses.any((h) => h['id'].toString() == selectedHouse) &&
      houses.isNotEmpty) {
    selectedHouse = houses.first['id'].toString();
  }
  final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDialogState) {
        return AlertDialog(
          backgroundColor: AppColors.getSurface(isDark),
          title: Text(
            isEdit ? 'CẬP NHẬT PHÒNG' : 'THÊM PHÒNG MỚI',
            style: TextStyle(
              color: AppColors.getTextPrimary(isDark),
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: selectedHouse.isEmpty ? null : selectedHouse,
                dropdownColor: AppColors.getSurface(isDark),
                style: TextStyle(
                  color: AppColors.getTextPrimary(isDark),
                  fontSize: 13,
                ),
                decoration: const InputDecoration(labelText: 'Thuộc ngôi nhà'),
                items: houses
                    .map(
                      (h) => DropdownMenuItem(
                        value: h['id'].toString(),
                        child: Text((h['name'] ?? '').toString()),
                      ),
                    )
                    .toList(),
                onChanged: (val) {
                  if (val != null) setDialogState(() => selectedHouse = val);
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nameCtrl,
                style: TextStyle(color: AppColors.getTextPrimary(isDark)),
                decoration: const InputDecoration(labelText: 'Tên phòng'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: floorCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(color: AppColors.getTextPrimary(isDark)),
                decoration: const InputDecoration(labelText: 'Tầng'),
              ),
            ],
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
                if (nameCtrl.text.trim().isEmpty || selectedHouse.isEmpty) {
                  return;
                }
                final floor = int.tryParse(floorCtrl.text.trim()) ?? 1;
                Navigator.pop(ctx);
                try {
                  if (isEdit) {
                    await api.updateRoom(
                      existingRoom['id'].toString(),
                      houseId: selectedHouse,
                      name: nameCtrl.text.trim(),
                      floor: floor,
                    );
                  } else {
                    await api.createRoom(
                      houseId: selectedHouse,
                      name: nameCtrl.text.trim(),
                      floor: floor,
                    );
                  }
                  await onSaved();
                  onSnack(isEdit ? 'Đã cập nhật phòng' : 'Đã tạo phòng mới');
                } catch (e) {
                  onSnack(
                    e.toString().replaceFirst('Exception: ', ''),
                    isError: true,
                  );
                }
              },
              child: Text(isEdit ? 'LƯU' : 'TẠO'),
            ),
          ],
        );
      },
    ),
  );
}
