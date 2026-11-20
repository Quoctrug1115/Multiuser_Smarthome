import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../widgets/home/device_excel_sheet.dart';
import '../models/smarthome_models.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';
import '../widgets/home/device_card.dart';
import '../widgets/home/device_dialogs.dart';
import '../widgets/home/sensor_overview_section.dart';
import '../widgets/home/space_manager_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ApiService _api = ApiService();
  final WebSocketService _wsService = WebSocketService();
  final TextEditingController _searchController = TextEditingController();

  String _selectedHouseId = 'ALL';
  String _selectedRoomId = 'ALL';
  String _selectedTypeFilter = 'TẤT CẢ';

  bool _isLoading = true;
  bool _isLoadingAi = false;

  JsonList _houses = [];
  JsonList _rooms = [];
  JsonList _devices = [];
  final Set<String> _deletedDeviceIds = {};
  JsonList _aiSuggestions = [];
  final List _activityLogs = [];

  double _temperature = 28.5;
  double _humidity = 65.0;
  int _lux = 450;
  bool _motion = false;

  StreamSubscription? _sensorSub;
  StreamSubscription? _deviceSub;
  StreamSubscription? _aiAlertSub;
  Timer? _deviceSyncTimer;

  @override
  void initState() {
    super.initState();
    _addLog('Hệ thống khởi động & đồng bộ không gian IoT', 'SYSTEM');
    _initRealtimeStreams();
    _loadAllData();
    _deviceSyncTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _syncDeviceStatesSilently();
    });
  }

  void _initRealtimeStreams() {
    if (_api.isAuthenticated && !_wsService.isConnected) {
      _wsService.connect(_api.wsUrl);
    }

    _sensorSub = _wsService.sensorStream.listen((data) {
      if (!mounted) return;
      final newMotion = data['motion'] == true;
      setState(() {
        _temperature = (data['temperature'] ?? _temperature).toDouble();
        _humidity = (data['humidity'] ?? _humidity).toDouble();
        _lux = (data['lux'] ?? _lux).toInt();
        if (newMotion && !_motion) {
          _addLog('Phát hiện chuyển động từ cảm biến PIR', 'SENSOR');
        }
        _motion = newMotion;
      });
    });

    _deviceSub = _wsService.deviceStream.listen((data) {
      if (!mounted) return;
      final incomingId = (data['id'] ?? data['device_id'] ?? '').toString();
      final topic = (data['mqtt_topic'] ?? '').toString();
      final isOn =
          data['is_on'] == true ||
          (data['status'] ?? '').toString().toUpperCase() == 'ON';
      String? triggeredName;

      setState(() {
        for (final d in _devices) {
          final matchById =
              incomingId.isNotEmpty && (d['id'] ?? '').toString() == incomingId;
          final matchByTopic =
              topic.isNotEmpty && (d['mqtt_topic'] ?? '').toString() == topic;
          if (matchById || matchByTopic) {
            d['is_on'] = isOn;
            d['status'] = isOn ? 'ON' : 'OFF';
            triggeredName = (d['name'] ?? topic).toString();
          }
        }
      });

      if (triggeredName != null) {
        _addLog(
          'Realtime: ${isOn ? "Bật" : "Tắt"} $triggeredName (${isOn ? "ON" : "OFF"})',
          'MQTT',
        );
      } else {
        _syncDeviceStatesSilently();
      }
    });

    _aiAlertSub = _wsService.aiAlertStream.listen((alert) {
      if (!mounted) return;
      final title =
          (alert['title'] ?? alert['alert_type'] ?? 'Cảnh báo bất thường AI')
              .toString();
      final msg = (alert['message'] ?? '').toString();
      setState(() => _aiSuggestions.insert(0, alert));
      _addLog('AI Alert: $title', 'AI');
      _showSnack('⚠️ $title${msg.isNotEmpty ? ": $msg" : ""}', isError: true);
    });
  }

  Future<void> _loadAllData() async {
    await Future.wait([_loadSpacesAndDevices(), _loadAiSuggestions()]);
  }

  Future<void> _loadSpacesAndDevices() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        _api.getHouses().catchError((_) => <JsonMap>[]),
        _api.getRooms().catchError((_) => <JsonMap>[]),
        _api.getDevices(),
      ]);
      if (!mounted) return;

      setState(() {
        _houses = results[0];
        _rooms = results[1];
        if (_selectedHouseId != 'ALL' &&
            !_houses.any((h) => h['id'].toString() == _selectedHouseId)) {
          _selectedHouseId = 'ALL';
        }
        if (_selectedRoomId != 'ALL' &&
            !_rooms.any((r) => r['id'].toString() == _selectedRoomId)) {
          _selectedRoomId = 'ALL';
        }
        _devices = results[2]
            .where(
              (d) => !_deletedDeviceIds.contains((d['id'] ?? '').toString()),
            )
            .toList();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnack(e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
  }

  Future<void> _syncDeviceStatesSilently() async {
    try {
      final list = await _api.getDevices();
      if (!mounted) return;
      setState(() {
        _devices = list
            .where(
              (d) => !_deletedDeviceIds.contains((d['id'] ?? '').toString()),
            )
            .toList();
      });
    } catch (_) {}
  }

  Future<void> _loadAiSuggestions() async {
    setState(() => _isLoadingAi = true);
    try {
      final alerts = await _api.getAiAlerts();
      if (!mounted) return;
      setState(() {
        _aiSuggestions = alerts;
        _isLoadingAi = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingAi = false);
    }
  }

  void _addLog(String message, String tag) {
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    if (!mounted) return;
    setState(() {
      _activityLogs.insert(0, {
        'time': timeStr,
        'message': message,
        'tag': tag,
      });
      if (_activityLogs.length > 25) _activityLogs.removeLast();
    });
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: isError ? AppColors.accent : AppColors.secondary,
      ),
    );
  }

  JsonList get _visibleRooms {
    if (_selectedHouseId == 'ALL') return _rooms;
    return _rooms
        .where((r) => (r['house_id'] ?? '').toString() == _selectedHouseId)
        .toList();
  }

  String _resolveRoomName(JsonMap device) {
    final direct = (device['room_name'] ?? '').toString().trim();
    if (direct.isNotEmpty) return direct;
    final roomId = (device['room_id'] ?? '').toString();
    if (roomId.isEmpty) return '';
    for (final r in _rooms) {
      if ((r['id'] ?? '').toString() == roomId) {
        return (r['name'] ?? '').toString();
      }
    }
    return '';
  }

  JsonList get _filteredDevices {
    final query = _searchController.text.trim().toLowerCase();
    final allowedRoomIds = _visibleRooms.map((r) => r['id'].toString()).toSet();

    return _devices.where((device) {
      final type = (device['device_type'] ?? 'switch').toString().toUpperCase();
      final name = (device['name'] ?? '').toString().toLowerCase();
      final topic = (device['mqtt_topic'] ?? '').toString().toLowerCase();
      final roomId = (device['room_id'] ?? '').toString();

      final matchesHouse =
          _selectedHouseId == 'ALL' ||
          (roomId.isNotEmpty && allowedRoomIds.contains(roomId));
      final matchesRoom = _selectedRoomId == 'ALL' || roomId == _selectedRoomId;
      final matchesType =
          _selectedTypeFilter == 'TẤT CẢ' || type == _selectedTypeFilter;
      final matchesQuery =
          query.isEmpty || name.contains(query) || topic.contains(query);

      return matchesHouse && matchesRoom && matchesType && matchesQuery;
    }).toList();
  }

  double get _instantPowerWatt {
    double sum = 0;
    for (final d in _devices) {
      sum += Device.fromJson(d).ratedPowerWatt;
    }
    return sum;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _sensorSub?.cancel();
    _deviceSub?.cancel();
    _aiAlertSub?.cancel();
    _deviceSyncTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;
    final apiService = Provider.of<ApiService>(context);
    final wsService = Provider.of<WebSocketService>(context);

    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);
    final amber = isDark ? Colors.amber : const Color(0xFFD97706);

    final isOwner = apiService.isAdmin;
    final canControl = apiService.currentUserRole.toLowerCase() != 'guest';
    final filteredList = _filteredDevices;
    final activeDeviceCount = _devices
        .where(
          (d) =>
              (d['device_type'] ?? '').toString().toLowerCase() != 'sensor' &&
              HomeDeviceCard.isDeviceOn(d),
        )
        .length;

    final effectiveAiList = _aiSuggestions.isNotEmpty
        ? _aiSuggestions
        : [
            {
              'title': _temperature > 30
                  ? 'Nhiệt độ phòng cao (${_temperature.toStringAsFixed(1)}°C)'
                  : 'Tối ưu năng lượng điều hòa & quạt',
              'message': _temperature > 30
                  ? 'AI đề xuất bật Quạt Phòng Khách để giảm tải tiêu thụ điện.'
                  : 'Môi trường đang ổn định (${_temperature.toStringAsFixed(1)}°C, độ ẩm ${_humidity.toStringAsFixed(0)}%). Duy trì chế độ tiết kiệm điện.',
              'severity': _temperature > 30 ? 'warning' : 'info',
            },
            {
              'title': _lux < 200
                  ? 'Ánh sáng môi trường thấp ($_lux Lux)'
                  : 'Ánh sáng tự nhiên tốt ($_lux Lux)',
              'message': _lux < 200
                  ? 'AI gợi ý bật Đèn Phòng Khách để đảm bảo đủ độ sáng.'
                  : 'Đủ ánh sáng ban ngày, có thể tắt đèn chiếu sáng để tiết kiệm ~15W.',
              'severity': 'info',
            },
          ];

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      floatingActionButton: isOwner
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'fab_scan_wokwi',
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
                    onLog: _addLog,
                    onSnack: _showSnack,
                    onRefresh: _loadSpacesAndDevices,
                  ),
                  icon: const Icon(Icons.radar, size: 19),
                  label: const Text(
                    'QUÉT WOKWI',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
                const SizedBox(width: 8),
                FloatingActionButton.extended(
                  heroTag: 'fab_add_device',
                  backgroundColor: cyan,
                  foregroundColor: isDark
                      ? const Color(0xFF0A0E1A)
                      : Colors.white,
                  onPressed: () => showDeviceFormDialog(
                    context: context,
                    isDark: isDark,
                    api: _api,
                    rooms: _rooms,
                    onLog: _addLog,
                    onSnack: _showSnack,
                    onRefresh: _loadSpacesAndDevices,
                  ),
                  icon: const Icon(Icons.add, size: 19),
                  label: const Text(
                    'THÊM THIẾT BỊ',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
              ],
            )
          : null,
      body: RefreshIndicator(
        color: cyan,
        onRefresh: _loadAllData,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 95),
          children: [
            // 1. CẢM BIẾN MÔI TRƯỜNG & CÔNG SUẤT TẢI
            SensorOverviewSection(
              temperature: _temperature,
              humidity: _humidity,
              lux: _lux,
              motion: _motion,
              isConnected: wsService.isConnected,
              activeDeviceCount: activeDeviceCount,
              instantPowerWatt: _instantPowerWatt,
              isDark: isDark,
            ),
            const SizedBox(height: 16),

            // 2. KHÔNG GIAN NHÀ & PHÒNG
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'KHÔNG GIAN NHÀ & PHÒNG',
                  style: TextStyle(
                    color: AppColors.getTextPrimary(isDark),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.6,
                  ),
                ),
                if (isOwner)
                  InkWell(
                    onTap: () => showSpaceManagerSheet(
                      context: context,
                      isDark: isDark,
                      api: _api,
                      getHouses: () => _houses,
                      getRooms: () => _rooms,
                      onReloadSpaces: _loadSpacesAndDevices,
                      onSnack: _showSnack,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.tune, color: cyan, size: 15),
                        const SizedBox(width: 4),
                        Text(
                          'QUẢN LÝ NHÀ/PHÒNG',
                          style: TextStyle(
                            color: cyan,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_houses.isNotEmpty) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildFilterPill(
                      label: 'Tất cả nhà (${_houses.length})',
                      selected: _selectedHouseId == 'ALL',
                      accentColor: AppColors.secondary,
                      isDark: isDark,
                      onTap: () => setState(() {
                        _selectedHouseId = 'ALL';
                        _selectedRoomId = 'ALL';
                      }),
                    ),
                    ..._houses.map((h) {
                      final hId = h['id'].toString();
                      return _buildFilterPill(
                        label: (h['name'] ?? 'Nhà').toString(),
                        selected: _selectedHouseId == hId,
                        accentColor: AppColors.secondary,
                        isDark: isDark,
                        onTap: () => setState(() {
                          _selectedHouseId = hId;
                          _selectedRoomId = 'ALL';
                        }),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildFilterPill(
                    label: 'Tất cả phòng',
                    selected: _selectedRoomId == 'ALL',
                    accentColor: green,
                    isDark: isDark,
                    onTap: () => setState(() => _selectedRoomId = 'ALL'),
                  ),
                  ..._visibleRooms.map((r) {
                    final rId = r['id'].toString();
                    return _buildFilterPill(
                      label: (r['name'] ?? 'Phòng').toString(),
                      selected: _selectedRoomId == rId,
                      accentColor: green,
                      isDark: isDark,
                      onTap: () => setState(() => _selectedRoomId = rId),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 3. KHỐI AI GỢI Ý & TỐI ƯU HỆ THỐNG
            _buildAiSuggestionsBox(effectiveAiList, isDark, cyan, amber),
            const SizedBox(height: 18),

            // 4. DANH SÁCH THIẾT BỊ KẾT NỐI
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'THIẾT BỊ KẾT NỐI (${filteredList.length})',
                  style: TextStyle(
                    color: AppColors.getTextPrimary(isDark),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.6,
                  ),
                ),
                if (isOwner)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => showDeviceExcelSheet(
                      context: context,
                      isDark: isDark,
                      api: _api,
                      devices: _devices,
                      rooms: _rooms,
                      onLog: _addLog,
                      onSnack: _showSnack,
                      onRefresh: _loadSpacesAndDevices,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: green.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: green.withOpacity(0.5)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.table_view, color: green, size: 14),
                          const SizedBox(width: 5),
                          Text(
                            'NHẬP / XUẤT EXCEL',
                            style: TextStyle(
                              color: green,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _buildSearchAndTypeFilter(isDark, cyan),
            const SizedBox(height: 12),
            if (_isLoading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator(color: cyan)),
              )
            else if (filteredList.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 28,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: AppColors.getSurface(isDark),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDark ? Colors.white12 : Colors.black12,
                  ),
                ),
                child: const Text(
                  'Không có thiết bị nào phù hợp bộ lọc hiện tại.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
              )
            else
              ...filteredList.map((device) {
                final id = (device['id'] ?? '').toString();
                final name = (device['name'] ?? 'Thiết bị').toString();
                final topic = (device['mqtt_topic'] ?? '').toString();

                return HomeDeviceCard(
                  device: device,
                  roomName: _resolveRoomName(device),
                  isDark: isDark,
                  isOwner: isOwner,
                  canControl: canControl,
                  onToggle: (newVal) async {
                    final cmd = newVal ? 'ON' : 'OFF';
                    setState(() {
                      device['is_on'] = newVal;
                      device['status'] = cmd;
                    });
                    try {
                      await _api.controlDevice(id, cmd, mqttTopic: topic);
                      _addLog(
                        '${newVal ? "Bật" : "Tắt"} $name ($cmd)',
                        'DEVICE',
                      );
                    } catch (e) {
                      if (!mounted) return;
                      setState(() {
                        device['is_on'] = !newVal;
                        device['status'] = !newVal ? 'ON' : 'OFF';
                      });
                      _showSnack(
                        e.toString().replaceFirst('Exception: ', ''),
                        isError: true,
                      );
                    }
                  },
                  onEdit: () => showDeviceFormDialog(
                    context: context,
                    isDark: isDark,
                    api: _api,
                    rooms: _rooms,
                    existingDevice: device,
                    onLog: _addLog,
                    onSnack: _showSnack,
                    onRefresh: _loadSpacesAndDevices,
                  ),
                  onDelete: () async {
                    try {
                      await _api.deleteDevice(id);
                      setState(() {
                        _deletedDeviceIds.add(id);
                        _devices.removeWhere(
                          (d) => (d['id'] ?? '').toString() == id,
                        );
                      });
                      _addLog('Xóa thiết bị: $name', 'DEVICE');
                      _showSnack('Đã xóa $name');
                    } catch (e) {
                      _showSnack(
                        e.toString().replaceFirst('Exception: ', ''),
                        isError: true,
                      );
                    }
                  },
                );
              }),
            const SizedBox(height: 16),

            // 5. NHẬT KÝ HOẠT ĐỘNG HỆ THỐNG
            _buildActivityLogsBox(isDark, cyan, green),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterPill({
    required String label,
    required bool selected,
    required Color accentColor,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withOpacity(0.2)
                : AppColors.getSurface(isDark),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? accentColor
                  : (isDark ? Colors.white12 : Colors.black12),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected
                  ? accentColor
                  : AppColors.getTextSecondary(isDark),
              fontSize: 11,
              fontWeight: selected ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAiSuggestionsBox(
    List aiList,
    bool isDark,
    Color cyan,
    Color amber,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cyan.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome, color: cyan, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'AI GỢI Ý & TỐI ƯU HỆ THỐNG',
                    style: TextStyle(
                      color: AppColors.getTextPrimary(isDark),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              InkWell(
                onTap: () async {
                  await _api.triggerAiAnalysis().catchError((_) {});
                  await _loadAiSuggestions();
                  _addLog('Đã chạy phân tích AI gợi ý mới', 'AI');
                },
                child: Text(
                  'PHÂN TÍCH LẠI',
                  style: TextStyle(
                    color: cyan,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_isLoadingAi)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: CircularProgressIndicator(color: cyan, strokeWidth: 2),
              ),
            )
          else
            ...aiList.take(2).map((item) {
              final title =
                  (item['title'] ??
                          item['alert_type'] ??
                          'Gợi ý tiết kiệm điện')
                      .toString();
              final desc = (item['message'] ?? item['description'] ?? '')
                  .toString();
              final severity = (item['severity'] ?? 'info')
                  .toString()
                  .toLowerCase();
              final badgeColor = severity == 'critical' || severity == 'high'
                  ? AppColors.accent
                  : (severity == 'warning' ? amber : cyan);

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.getBackground(isDark),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: badgeColor.withOpacity(0.35)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.tips_and_updates_outlined,
                      color: badgeColor,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: AppColors.getTextPrimary(isDark),
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          if (desc.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              desc,
                              style: const TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildSearchAndTypeFilter(bool isDark, Color cyan) {
    return Column(
      children: [
        TextField(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          style: TextStyle(
            color: AppColors.getTextPrimary(isDark),
            fontSize: 13,
          ),
          decoration: InputDecoration(
            hintText: 'Tìm thiết bị hoặc MQTT topic...',
            hintStyle: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
            ),
            prefixIcon: Icon(Icons.search, color: cyan, size: 20),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(
                      Icons.clear,
                      color: AppColors.textMuted,
                      size: 18,
                    ),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {});
                    },
                  )
                : null,
            filled: true,
            fillColor: AppColors.getSurface(isDark),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: cyan.withOpacity(0.4)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark ? Colors.white12 : Colors.black12,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: cyan, width: 1.4),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: ['TẤT CẢ', 'LIGHT', 'SWITCH', 'FAN', 'AC', 'SENSOR'].map((
              type,
            ) {
              final isSelected = _selectedTypeFilter == type;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() => _selectedTypeFilter = type),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected ? cyan : AppColors.getSurface(isDark),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? cyan
                            : (isDark ? Colors.white12 : Colors.black12),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isSelected) ...[
                          Icon(
                            Icons.check,
                            size: 14,
                            color: isDark
                                ? const Color(0xFF0A0E1A)
                                : Colors.white,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          type,
                          style: TextStyle(
                            color: isSelected
                                ? (isDark
                                      ? const Color(0xFF0A0E1A)
                                      : Colors.white)
                                : AppColors.getTextPrimary(isDark),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildActivityLogsBox(bool isDark, Color cyan, Color green) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.history, color: green, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'NHẬT KÝ HOẠT ĐỘNG HỆ THỐNG',
                    style: TextStyle(
                      color: AppColors.getTextPrimary(isDark),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              InkWell(
                onTap: () => setState(() => _activityLogs.clear()),
                child: const Text(
                  'XÓA LOG',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_activityLogs.isEmpty)
            const Text(
              'Chưa có hoạt động nào được ghi nhận.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 11),
            )
          else
            ..._activityLogs.map(
              (log) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '[${log['time']}] ',
                      style: TextStyle(
                        color: cyan,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        log['message'] ?? '',
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
