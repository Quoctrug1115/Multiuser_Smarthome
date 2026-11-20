import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/smarthome_models.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';
import '../widgets/home/device_card.dart';
import '../widgets/home/device_dialogs.dart';
import '../widgets/home/device_excel_sheet.dart';

class SpaceDeviceManagementScreen extends StatefulWidget {
  const SpaceDeviceManagementScreen({super.key});

  @override
  State<SpaceDeviceManagementScreen> createState() =>
      _SpaceDeviceManagementScreenState();
}

class _SpaceDeviceManagementScreenState
    extends State<SpaceDeviceManagementScreen> {
  final ApiService _api = ApiService();
  final TextEditingController _searchCtrl = TextEditingController();

  int _subTabIndex = 0; // 0: Ngôi nhà | 1: Phòng | 2: Thiết bị
  String _filterHouseId = 'ALL';
  String _filterRoomId = 'ALL';
  String _filterDeviceType = 'TẤT CẢ';

  bool _isLoading = true;
  JsonList _houses = [];
  JsonList _rooms = [];
  JsonList _devices = [];

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        _api.getHouses().catchError((_) => <JsonMap>[]),
        _api.getRooms().catchError((_) => <JsonMap>[]),
        _api.getDevices().catchError((_) => <JsonMap>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _houses = results[0];
        _rooms = results[1];
        _devices = results[2];
        if (_filterHouseId != 'ALL' &&
            !_houses.any((h) => h['id'].toString() == _filterHouseId)) {
          _filterHouseId = 'ALL';
        }
        if (_filterRoomId != 'ALL' &&
            _filterRoomId != 'UNASSIGNED' &&
            !_rooms.any((r) => r['id'].toString() == _filterRoomId)) {
          _filterRoomId = 'ALL';
        }
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnack(e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: isError ? AppColors.accent : AppColors.secondary,
      ),
    );
  }

  String _resolveHouseName(String houseId) {
    for (final h in _houses) {
      if (h['id'].toString() == houseId) {
        return (h['name'] ?? '').toString();
      }
    }
    return '';
  }

  String _resolveRoomName(JsonMap device) {
    final direct = (device['room_name'] ?? '').toString().trim();
    if (direct.isNotEmpty) return direct;
    final roomId = (device['room_id'] ?? '').toString();
    for (final r in _rooms) {
      if (r['id'].toString() == roomId) {
        return (r['name'] ?? '').toString();
      }
    }
    return '';
  }

  int _countRoomsInHouse(String houseId) =>
      _rooms.where((r) => (r['house_id'] ?? '').toString() == houseId).length;

  int _countDevicesInHouse(String houseId) {
    final roomIds = _rooms
        .where((r) => (r['house_id'] ?? '').toString() == houseId)
        .map((r) => r['id'].toString())
        .toSet();
    return _devices
        .where((d) => roomIds.contains((d['room_id'] ?? '').toString()))
        .length;
  }

  int _countDevicesInRoom(String roomId) =>
      _devices.where((d) => (d['room_id'] ?? '').toString() == roomId).length;

  // ==================== DIALOG THÊM / SỬA NHÀ ====================
  void _openHouseDialog(bool isDark, {JsonMap? house}) {
    final isEdit = house != null;
    final nameCtrl = TextEditingController(
      text: house?['name']?.toString() ?? '',
    );
    final addrCtrl = TextEditingController(
      text: house?['address']?.toString() ?? '',
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
                  await _api.updateHouse(
                    house['id'].toString(),
                    name: nameCtrl.text.trim(),
                    address: addrCtrl.text.trim(),
                  );
                  _showSnack('Đã cập nhật ngôi nhà');
                } else {
                  await _api.createHouse(
                    name: nameCtrl.text.trim(),
                    address: addrCtrl.text.trim(),
                  );
                  _showSnack('Đã thêm ngôi nhà mới');
                }
                await _loadAll();
              } catch (e) {
                _showSnack(
                  e.toString().replaceFirst('Exception: ', ''),
                  isError: true,
                );
              }
            },
            child: Text(isEdit ? 'LƯU' : 'TẠO MỚI'),
          ),
        ],
      ),
    );
  }

  // ==================== DIALOG THÊM / SỬA PHÒNG ====================
  void _openRoomDialog(bool isDark, {JsonMap? room}) {
    if (_houses.isEmpty) {
      _showSnack('Vui lòng tạo ít nhất 1 Ngôi nhà trước!', isError: true);
      return;
    }
    final isEdit = room != null;
    final nameCtrl = TextEditingController(
      text: room?['name']?.toString() ?? '',
    );
    final floorCtrl = TextEditingController(
      text: (room?['floor'] ?? 1).toString(),
    );
    String selectedHouseId = (room?['house_id'] ?? _houses.first['id'])
        .toString();
    if (!_houses.any((h) => h['id'].toString() == selectedHouseId)) {
      selectedHouseId = _houses.first['id'].toString();
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
                  value: selectedHouseId,
                  dropdownColor: AppColors.getSurface(isDark),
                  style: TextStyle(
                    color: AppColors.getTextPrimary(isDark),
                    fontSize: 13,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Thuộc ngôi nhà',
                  ),
                  items: _houses
                      .map(
                        (h) => DropdownMenuItem(
                          value: h['id'].toString(),
                          child: Text((h['name'] ?? '').toString()),
                        ),
                      )
                      .toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() => selectedHouseId = val);
                    }
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
                  if (nameCtrl.text.trim().isEmpty) return;
                  final floor = int.tryParse(floorCtrl.text.trim()) ?? 1;
                  Navigator.pop(ctx);
                  try {
                    if (isEdit) {
                      await _api.updateRoom(
                        room['id'].toString(),
                        houseId: selectedHouseId,
                        name: nameCtrl.text.trim(),
                        floor: floor,
                      );
                      _showSnack('Đã cập nhật phòng');
                    } else {
                      await _api.createRoom(
                        houseId: selectedHouseId,
                        name: nameCtrl.text.trim(),
                        floor: floor,
                      );
                      _showSnack('Đã thêm phòng mới');
                    }
                    await _loadAll();
                  } catch (e) {
                    _showSnack(
                      e.toString().replaceFirst('Exception: ', ''),
                      isError: true,
                    );
                  }
                },
                child: Text(isEdit ? 'LƯU' : 'TẠO MỚI'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete({
    required bool isDark,
    required String title,
    required String message,
    required Future<void> Function() onConfirm,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.getSurface(isDark),
        title: Text(
          title,
          style: TextStyle(
            color: AppColors.getTextPrimary(isDark),
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          message,
          style: TextStyle(
            color: AppColors.getTextSecondary(isDark),
            fontSize: 13,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('HỦY'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('XÓA'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await onConfirm();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;
    final apiService = Provider.of<ApiService>(context);
    final isAdmin = apiService.isAdmin;

    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);
    final amber = isDark ? Colors.amber : const Color(0xFFD97706);

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      floatingActionButton: isAdmin ? _buildFloatingAction(isDark, cyan) : null,
      body: RefreshIndicator(
        color: cyan,
        onRefresh: _loadAll,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 95),
          children: [
            // 1. THỐNG KÊ HẠ TẦNG NHÀ - PHÒNG - THIẾT BỊ
            Row(
              children: [
                Expanded(
                  child: _buildStatCard(
                    'NGÔI NHÀ',
                    '${_houses.length}',
                    Icons.home_work_outlined,
                    AppColors.secondary,
                    isDark,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatCard(
                    'PHÒNG',
                    '${_rooms.length}',
                    Icons.meeting_room_outlined,
                    green,
                    isDark,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatCard(
                    'THIẾT BỊ',
                    '${_devices.length}',
                    Icons.devices_other,
                    cyan,
                    isDark,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // 2. THANH CHUYỂN PHÂN KHU QUẢN LÝ (NHÀ / PHÒNG / THIẾT BỊ)
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: AppColors.getSurface(isDark),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? Colors.white12 : Colors.black12,
                ),
              ),
              child: Row(
                children: [
                  _buildSubTabBtn('NHÀ (${_houses.length})', 0, cyan, isDark),
                  _buildSubTabBtn('PHÒNG (${_rooms.length})', 1, cyan, isDark),
                  _buildSubTabBtn(
                    'THIẾT BỊ (${_devices.length})',
                    2,
                    cyan,
                    isDark,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            if (_isLoading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator(color: cyan)),
              )
            else if (_subTabIndex == 0)
              _buildHousesSection(isDark, isAdmin, cyan, green)
            else if (_subTabIndex == 1)
              _buildRoomsSection(isDark, isAdmin, cyan, green)
            else
              _buildDevicesSection(isDark, isAdmin, cyan, green, amber),
          ],
        ),
      ),
    );
  }

  Widget? _buildFloatingAction(bool isDark, Color cyan) {
    if (_subTabIndex == 0) {
      return FloatingActionButton.extended(
        heroTag: 'fab_mgmt_house',
        backgroundColor: cyan,
        foregroundColor: isDark ? const Color(0xFF0A0E1A) : Colors.white,
        onPressed: () => _openHouseDialog(isDark),
        icon: const Icon(Icons.add_home),
        label: const Text(
          'THÊM NHÀ',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
        ),
      );
    }
    if (_subTabIndex == 1) {
      return FloatingActionButton.extended(
        heroTag: 'fab_mgmt_room',
        backgroundColor: cyan,
        foregroundColor: isDark ? const Color(0xFF0A0E1A) : Colors.white,
        onPressed: () => _openRoomDialog(isDark),
        icon: const Icon(Icons.meeting_room),
        label: const Text(
          'THÊM PHÒNG',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.extended(
          heroTag: 'fab_mgmt_wokwi',
          backgroundColor: AppColors.getSurface(isDark),
          foregroundColor: cyan,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: cyan, width: 1.3),
          ),
          onPressed: () => showWokwiDiscoveryDialog(
            context: context,
            isDark: isDark,
            api: _api,
            rooms: _rooms,
            existingDevices: _devices,
            onLog: (_, __) {},
            onSnack: _showSnack,
            onRefresh: _loadAll,
          ),
          icon: const Icon(Icons.radar, size: 18),
          label: const Text(
            'QUÉT WOKWI',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
          ),
        ),
        const SizedBox(width: 8),
        FloatingActionButton.extended(
          heroTag: 'fab_mgmt_device',
          backgroundColor: cyan,
          foregroundColor: isDark ? const Color(0xFF0A0E1A) : Colors.white,
          onPressed: () => showDeviceFormDialog(
            context: context,
            isDark: isDark,
            api: _api,
            rooms: _rooms,
            onLog: (_, __) {},
            onSnack: _showSnack,
            onRefresh: _loadAll,
          ),
          icon: const Icon(Icons.add, size: 18),
          label: const Text(
            'THÊM THIẾT BỊ',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _buildSubTabBtn(String label, int index, Color cyan, bool isDark) {
    final active = _subTabIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _subTabIndex = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? cyan : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: active
                  ? (isDark ? const Color(0xFF0A0E1A) : Colors.white)
                  : AppColors.getTextSecondary(isDark),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
    bool isDark,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 19),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: AppColors.getTextPrimary(isDark),
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== PHÂN KHU 1: NGÔI NHÀ ====================
  Widget _buildHousesSection(
    bool isDark,
    bool isAdmin,
    Color cyan,
    Color green,
  ) {
    if (_houses.isEmpty) {
      return _buildEmptyBox(
        isDark,
        'Chưa có ngôi nhà nào được tạo.\nNhấn "THÊM NHÀ" để khởi tạo không gian đầu tiên.',
      );
    }

    return Column(
      children: _houses.map((h) {
        final id = h['id'].toString();
        final name = (h['name'] ?? 'Ngôi nhà').toString();
        final address = (h['address'] ?? 'Chưa cập nhật địa chỉ').toString();
        final roomCount = _countRoomsInHouse(id);
        final deviceCount = _countDevicesInHouse(id);

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.getSurface(isDark),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cyan.withOpacity(0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: cyan.withOpacity(0.15),
                    child: Icon(Icons.home_work, color: cyan, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            color: AppColors.getTextPrimary(isDark),
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          address,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isAdmin) ...[
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 19),
                      onPressed: () => _openHouseDialog(isDark, house: h),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 19,
                        color: AppColors.accent,
                      ),
                      onPressed: () => _confirmDelete(
                        isDark: isDark,
                        title: 'Xóa ngôi nhà?',
                        message:
                            'Bạn có chắc muốn xóa "$name"? Các phòng bên trong có thể bị ảnh hưởng.',
                        onConfirm: () async {
                          try {
                            await _api.deleteHouse(id);
                            _showSnack('Đã xóa ngôi nhà');
                            await _loadAll();
                          } catch (e) {
                            _showSnack(
                              e.toString().replaceFirst('Exception: ', ''),
                              isError: true,
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ],
              ),
              const Divider(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '$roomCount phòng • $deviceCount thiết bị',
                    style: TextStyle(
                      color: green,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  InkWell(
                    onTap: () => setState(() {
                      _filterHouseId = id;
                      _subTabIndex = 1;
                    }),
                    child: Text(
                      'XEM DANH SÁCH PHÒNG →',
                      style: TextStyle(
                        color: cyan,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ==================== PHÂN KHU 2: PHÒNG ====================
  Widget _buildRoomsSection(
    bool isDark,
    bool isAdmin,
    Color cyan,
    Color green,
  ) {
    final visibleRooms = _filterHouseId == 'ALL'
        ? _rooms
        : _rooms
              .where((r) => (r['house_id'] ?? '').toString() == _filterHouseId)
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_houses.isNotEmpty) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildPill(
                  'Tất cả nhà',
                  _filterHouseId == 'ALL',
                  cyan,
                  isDark,
                  () => setState(() => _filterHouseId = 'ALL'),
                ),
                ..._houses.map(
                  (h) => _buildPill(
                    (h['name'] ?? '').toString(),
                    _filterHouseId == h['id'].toString(),
                    cyan,
                    isDark,
                    () => setState(() => _filterHouseId = h['id'].toString()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (visibleRooms.isEmpty)
          _buildEmptyBox(isDark, 'Chưa có phòng nào thuộc lựa chọn hiện tại.')
        else
          ...visibleRooms.map((r) {
            final id = r['id'].toString();
            final name = (r['name'] ?? 'Phòng').toString();
            final floor = r['floor'] ?? 1;
            final houseId = (r['house_id'] ?? '').toString();
            final houseName = (r['house_name'] ?? _resolveHouseName(houseId))
                .toString();
            final devCount = _countDevicesInRoom(id);

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.getSurface(isDark),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: green.withOpacity(0.35)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: green.withOpacity(0.15),
                    child: Icon(Icons.meeting_room, color: green, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$name (Tầng $floor)',
                          style: TextStyle(
                            color: AppColors.getTextPrimary(isDark),
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${houseName.isNotEmpty ? "$houseName • " : ""}$devCount thiết bị',
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.devices, color: cyan, size: 19),
                    tooltip: 'Xem thiết bị trong phòng',
                    onPressed: () => setState(() {
                      _filterRoomId = id;
                      _subTabIndex = 2;
                    }),
                  ),
                  if (isAdmin) ...[
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 19),
                      onPressed: () => _openRoomDialog(isDark, room: r),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 19,
                        color: AppColors.accent,
                      ),
                      onPressed: () => _confirmDelete(
                        isDark: isDark,
                        title: 'Xóa phòng?',
                        message: 'Xác nhận xóa "$name"?',
                        onConfirm: () async {
                          try {
                            await _api.deleteRoom(id);
                            _showSnack('Đã xóa phòng');
                            await _loadAll();
                          } catch (e) {
                            _showSnack(
                              e.toString().replaceFirst('Exception: ', ''),
                              isError: true,
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),
      ],
    );
  }

  // ==================== PHÂN KHU 3: THIẾT BỊ ====================
  Widget _buildDevicesSection(
    bool isDark,
    bool isAdmin,
    Color cyan,
    Color green,
    Color amber,
  ) {
    final query = _searchCtrl.text.trim().toLowerCase();
    final filtered = _devices.where((d) {
      final name = (d['name'] ?? '').toString().toLowerCase();
      final topic = (d['mqtt_topic'] ?? '').toString().toLowerCase();
      final type = (d['device_type'] ?? 'switch').toString().toUpperCase();
      final roomId = (d['room_id'] ?? '').toString();

      final matchQuery =
          query.isEmpty || name.contains(query) || topic.contains(query);
      final matchType =
          _filterDeviceType == 'TẤT CẢ' || type == _filterDeviceType;
      final matchRoom =
          _filterRoomId == 'ALL' ||
          (_filterRoomId == 'UNASSIGNED' && roomId.isEmpty) ||
          roomId == _filterRoomId;

      return matchQuery && matchType && matchRoom;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isAdmin) ...[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: green,
                side: BorderSide(color: green.withOpacity(0.6)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onPressed: () => showDeviceExcelSheet(
                context: context,
                isDark: isDark,
                api: _api,
                devices: _devices,
                rooms: _rooms,
                onLog: (_, __) {},
                onSnack: _showSnack,
                onRefresh: _loadAll,
              ),
              icon: const Icon(Icons.table_view, size: 18),
              label: const Text(
                'NHẬP / XUẤT DANH SÁCH THIẾT BỊ EXCEL (.XLSX)',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        TextField(
          controller: _searchCtrl,
          onChanged: (_) => setState(() {}),
          style: TextStyle(
            color: AppColors.getTextPrimary(isDark),
            fontSize: 13,
          ),
          decoration: InputDecoration(
            hintText: 'Tìm kiếm tên thiết bị hoặc MQTT topic...',
            hintStyle: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
            ),
            prefixIcon: Icon(Icons.search, color: cyan, size: 19),
            filled: true,
            fillColor: AppColors.getSurface(isDark),
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildPill(
                'Tất cả phòng',
                _filterRoomId == 'ALL',
                green,
                isDark,
                () => setState(() => _filterRoomId = 'ALL'),
              ),
              _buildPill(
                'Chưa gán phòng',
                _filterRoomId == 'UNASSIGNED',
                amber,
                isDark,
                () => setState(() => _filterRoomId = 'UNASSIGNED'),
              ),
              ..._rooms.map(
                (r) => _buildPill(
                  (r['name'] ?? '').toString(),
                  _filterRoomId == r['id'].toString(),
                  green,
                  isDark,
                  () => setState(() => _filterRoomId = r['id'].toString()),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: ['TẤT CẢ', 'LIGHT', 'SWITCH', 'FAN', 'AC', 'SENSOR']
                .map(
                  (t) => _buildPill(
                    t,
                    _filterDeviceType == t,
                    cyan,
                    isDark,
                    () => setState(() => _filterDeviceType = t),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 12),
        if (filtered.isEmpty)
          _buildEmptyBox(isDark, 'Không có thiết bị nào khớp bộ lọc hiện tại.')
        else
          ...filtered.map((d) {
            final id = (d['id'] ?? '').toString();
            final name = (d['name'] ?? '').toString();
            final type = (d['device_type'] ?? 'switch').toString();
            final topic = (d['mqtt_topic'] ?? '').toString();
            final roomName = _resolveRoomName(d);
            final model = Device.fromJson(d);

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.getSurface(isDark),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? Colors.white12 : Colors.black12,
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: cyan.withOpacity(0.15),
                    child: Icon(
                      HomeDeviceCard.iconForType(type),
                      color: cyan,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            color: AppColors.getTextPrimary(isDark),
                            fontWeight: FontWeight.bold,
                            fontSize: 13.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${type.toUpperCase()} • ${roomName.isEmpty ? "Chưa gán phòng" : roomName} • ${model.ratedPowerWatt.toStringAsFixed(0)}W',
                          style: TextStyle(
                            color: roomName.isEmpty ? amber : green,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          topic,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isAdmin) ...[
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 19),
                      onPressed: () => showDeviceFormDialog(
                        context: context,
                        isDark: isDark,
                        api: _api,
                        rooms: _rooms,
                        existingDevice: d,
                        onLog: (_, __) {},
                        onSnack: _showSnack,
                        onRefresh: _loadAll,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 19,
                        color: AppColors.accent,
                      ),
                      onPressed: () => _confirmDelete(
                        isDark: isDark,
                        title: 'Xóa thiết bị?',
                        message: 'Xác nhận xóa thiết bị "$name"?',
                        onConfirm: () async {
                          try {
                            await _api.deleteDevice(id);
                            _showSnack('Đã xóa $name');
                            await _loadAll();
                          } catch (e) {
                            _showSnack(
                              e.toString().replaceFirst('Exception: ', ''),
                              isError: true,
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),
      ],
    );
  }

  Widget _buildPill(
    String label,
    bool selected,
    Color color,
    bool isDark,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? color.withOpacity(0.2)
                : AppColors.getSurface(isDark),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? color
                  : (isDark ? Colors.white12 : Colors.black12),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? color : AppColors.getTextSecondary(isDark),
              fontSize: 11,
              fontWeight: selected ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyBox(bool isDark, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
      ),
    );
  }
}
