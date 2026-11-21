import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/smarthome_models.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';
import '../widgets/home/device_card.dart';
import '../widgets/home/device_dialogs.dart';
import '../widgets/home/device_excel_sheet.dart';
import '../widgets/home/sensor_overview_section.dart';
import '../widgets/home/space_manager_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ApiService _api = ApiService();
  late WebSocketService _wsService;
  bool _wsInitialized = false;

  StreamSubscription<dynamic>? _sensorSub;
  StreamSubscription<dynamic>? _deviceSub;
  Timer? _syncTimer;

  bool _isLoading = true;
  JsonList _houses = [];
  JsonList _rooms = [];
  JsonList _devices = [];
  final Set<String> _deletedDeviceIds = {};

  String _selectedHouseId = 'ALL';
  String _selectedRoomId = 'ALL';
  String _selectedType = 'TẤT CẢ';
  final TextEditingController _searchController = TextEditingController();

  double? _temperature;
  double? _humidity;
  double? _lux;
  bool? _motionDetected;

  final List _logs = [];

  @override
  void initState() {
    super.initState();
    _addLog('Hệ thống khởi động & đồng bộ không gian IoT', 'SYSTEM');
    _loadSpacesAndDevices();
    _syncTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      _syncDeviceStatesSilently();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_wsInitialized) {
      _wsInitialized = true;
      try {
        _wsService = Provider.of<WebSocketService>(context, listen: false);
      } catch (_) {
        _wsService = WebSocketService();
      }
      if (_api.isAuthenticated && !_wsService.isConnected) {
        _wsService.connect(_api.wsUrl);
      }
      _initRealtimeStreams();
    }
  }

  void _initRealtimeStreams() {
    _sensorSub = _wsService.sensorStream.listen((raw) {
      if (!mounted || raw == null) return;
      if (raw is Map) {
        final data = raw['data'] is Map ? raw['data'] as Map : raw;
        setState(() {
          if (data['temperature'] != null) {
            _temperature = (data['temperature'] as num).toDouble();
          }
          if (data['humidity'] != null) {
            _humidity = (data['humidity'] as num).toDouble();
          }
          if (data['lux'] != null || data['light'] != null) {
            _lux = ((data['lux'] ?? data['light']) as num).toDouble();
          }
          if (data['motion'] != null || data['motion_detected'] != null) {
            final m = data['motion'] ?? data['motion_detected'];
            _motionDetected = m == true || m == 1 || m.toString() == '1';
          }
        });
      }
    });

    _deviceSub = _wsService.deviceStream.listen((raw) {
      if (!mounted || raw == null) return;

      String incomingId = '';
      String topic = '';
      String incomingOwner = '';
      String source = '';
      bool? parsedIsOn;
      bool? parsedIsOnline;

      if (raw is Map) {
        final data = raw['data'] is Map ? raw['data'] as Map : raw;

        // 1. Lọc đúng hộ gia đình (Multi-tenant) nếu payload có đính kèm owner_id
        incomingOwner = (data['owner_id'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        final myOwner = _api.householdOwnerId.trim().toLowerCase();
        if (incomingOwner.isNotEmpty &&
            myOwner.isNotEmpty &&
            incomingOwner != myOwner) {
          return;
        }

        incomingId = (data['id'] ?? data['device_id'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        topic = (data['mqtt_topic'] ?? '')
            .toString()
            .trim()
            .toLowerCase()
            .replaceAll(RegExp(r'/+$'), '');
        source = (data['source'] ?? '').toString().trim().toLowerCase();

        // 2. Chỉ parse is_on khi gói tin thực sự có trường trạng thái bật/tắt
        if (data.containsKey('is_on') ||
            data.containsKey('status') ||
            data.containsKey('state')) {
          final rawState = data['is_on'] ?? data['status'] ?? data['state'];
          if (rawState is bool) {
            parsedIsOn = rawState;
          } else if (rawState != null) {
            final s = rawState.toString().trim().toLowerCase();
            parsedIsOn = s == 'on' || s == 'true' || s == '1' || s == 'active';
          }
        }

        // 3. Parse trạng thái kết nối phần cứng (Online / Offline từ MQTT LWT)
        if (data.containsKey('is_online') && data['is_online'] != null) {
          final rawOnline = data['is_online'];
          if (rawOnline is bool) {
            parsedIsOnline = rawOnline;
          } else {
            final s = rawOnline.toString().trim().toLowerCase();
            parsedIsOnline = s == 'true' || s == '1' || s == 'online';
          }
        }
      } else {
        try {
          incomingId = (raw.id ?? '').toString().trim().toLowerCase();
          topic = (raw.mqttTopic ?? '')
              .toString()
              .trim()
              .toLowerCase()
              .replaceAll(RegExp(r'/+$'), '');
          parsedIsOn = raw.isOn == true;
        } catch (_) {
          return;
        }
      }

      String? triggeredName;
      bool stateChanged = false;
      bool onlineChanged = false;
      bool finalIsOn = false;
      bool finalIsOnline = true;

      setState(() {
        for (final d in _devices) {
          final localId = (d['id'] ?? '').toString().trim().toLowerCase();
          final localTopic = (d['mqtt_topic'] ?? '')
              .toString()
              .trim()
              .toLowerCase()
              .replaceAll(RegExp(r'/+$'), '');

          final matchById = incomingId.isNotEmpty && localId == incomingId;
          final matchByTopic = topic.isNotEmpty && localTopic == topic;

          if (matchById || matchByTopic) {
            triggeredName = (d['name'] ?? topic).toString();

            final prevOn = HomeDeviceCard.isDeviceOn(d);
            final prevOnline = d['is_online'] != false;

            if (parsedIsOn != null) {
              if (prevOn != parsedIsOn) stateChanged = true;
              d['is_on'] = parsedIsOn;
              d['status'] = parsedIsOn ? 'ON' : 'OFF';
              finalIsOn = parsedIsOn;
            } else {
              finalIsOn = prevOn;
            }

            if (parsedIsOnline != null) {
              if (prevOnline != parsedIsOnline) onlineChanged = true;
              d['is_online'] = parsedIsOnline;
              finalIsOnline = parsedIsOnline;
            } else {
              finalIsOnline = prevOnline;
            }
          }
        }
      });

      // 4. Ghi nhật ký chính xác theo nguồn tác động thực tế
      if (triggeredName != null) {
        if (onlineChanged && !finalIsOnline) {
          _addLog('Mất kết nối phần cứng: $triggeredName (OFFLINE)', 'MQTT');
        } else if (onlineChanged && finalIsOnline && !stateChanged) {
          _addLog(
            'Thiết bị trực tuyến trở lại: $triggeredName (ONLINE)',
            'MQTT',
          );
        } else if (stateChanged) {
          final sourceLabel = source == 'physical_button'
              ? 'Nút bấm cơ'
              : (source == 'sync_reconnect' ? 'Đồng bộ lại' : 'Realtime');
          _addLog(
            '$sourceLabel: ${finalIsOn ? "Bật" : "Tắt"} $triggeredName (${finalIsOn ? "ON" : "OFF"})',
            'MQTT',
          );
        }
      } else {
        _syncDeviceStatesSilently();
      }
    });
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

  Future<void> _loadSpacesAndDevices() async {
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
        _devices = results[2]
            .where(
              (d) => !_deletedDeviceIds.contains((d['id'] ?? '').toString()),
            )
            .toList();
        if (_selectedHouseId != 'ALL' &&
            !_houses.any((h) => h['id'].toString() == _selectedHouseId)) {
          _selectedHouseId = 'ALL';
        }
        if (_selectedRoomId != 'ALL' &&
            !_rooms.any((r) => r['id'].toString() == _selectedRoomId)) {
          _selectedRoomId = 'ALL';
        }
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnack(e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
  }

  void _addLog(String message, String tag) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    if (!mounted) return;
    setState(() {
      _logs.insert(0, {'time': '$hh:$mm:$ss', 'message': message, 'tag': tag});
      if (_logs.length > 30) {
        _logs.removeLast();
      }
    });
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

  double get _activeWatt {
    double total = 0.0;
    for (final d in _devices) {
      if (HomeDeviceCard.isDeviceOn(d)) {
        total += Device.fromJson(d).ratedPowerWatt;
      }
    }
    return total;
  }

  JsonList get _visibleRooms {
    if (_selectedHouseId == 'ALL') return _rooms;
    return _rooms
        .where((r) => (r['house_id'] ?? '').toString() == _selectedHouseId)
        .toList();
  }

  JsonList get _filteredDevices {
    final query = _searchController.text.trim().toLowerCase();
    final allowedRoomIds = _visibleRooms.map((r) => r['id'].toString()).toSet();

    return _devices.where((d) {
      final name = (d['name'] ?? '').toString().toLowerCase();
      final topic = (d['mqtt_topic'] ?? '').toString().toLowerCase();
      final type = (d['device_type'] ?? 'switch').toString().toUpperCase();
      final roomId = (d['room_id'] ?? '').toString();

      final matchQuery =
          query.isEmpty || name.contains(query) || topic.contains(query);
      final matchType = _selectedType == 'TẤT CẢ' || type == _selectedType;

      bool matchSpace = true;
      if (_selectedRoomId != 'ALL') {
        matchSpace = roomId == _selectedRoomId;
      } else if (_selectedHouseId != 'ALL') {
        matchSpace = allowedRoomIds.contains(roomId);
      }

      return matchQuery && matchType && matchSpace;
    }).toList();
  }

  @override
  void dispose() {
    _sensorSub?.cancel();
    _deviceSub?.cancel();
    _syncTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;
    final isOwner = _api.isAdmin;
    final canControl = _api.currentUserRole.toLowerCase() != 'guest';

    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);
    final filteredList = _filteredDevices;

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      floatingActionButton: isOwner
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'fab_home_wokwi',
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
                  icon: const Icon(Icons.radar, size: 18),
                  label: const Text(
                    'QUÉT WOKWI',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
                const SizedBox(width: 8),
                FloatingActionButton.extended(
                  heroTag: 'fab_home_add_device',
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
                  icon: const Icon(Icons.add, size: 18),
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
        onRefresh: _loadSpacesAndDevices,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 95),
          children: [
            // 1. BỘ CHỌN KHÔNG GIAN NHÀ & PHÒNG
            _buildSpaceSelector(isDark, isOwner, cyan, green),
            const SizedBox(height: 14),

            // 2. GIÁM SÁT MÔI TRƯỜNG & CÔNG SUẤT TẢI
            SensorOverviewSection(
              temperature: _temperature,
              humidity: _humidity,
              lux: _lux?.round(),
              motion: _motionDetected,
              totalWatt: _activeWatt,
              isDark: isDark,
            ),
            const SizedBox(height: 16),

            // 3. THẺ GỢI Ý TỐI ƯU AI
            _buildAiSuggestionBanner(isDark, cyan),
            const SizedBox(height: 16),

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
            _buildActivityLogSection(isDark, green),
          ],
        ),
      ),
    );
  }

  Widget _buildSpaceSelector(
    bool isDark,
    bool isOwner,
    Color cyan,
    Color green,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(14),
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
                  Icon(Icons.home_work_outlined, color: cyan, size: 17),
                  const SizedBox(width: 6),
                  Text(
                    'KHÔNG GIAN ĐIỀU KHIỂN',
                    style: TextStyle(
                      color: AppColors.getTextPrimary(isDark),
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              if (isOwner)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => showSpaceManagerSheet(
                    context: context,
                    isDark: isDark,
                    api: _api,
                    getHouses: () => _houses,
                    getRooms: () => _rooms,
                    onSnack: _showSnack,
                    onReloadSpaces: _loadSpacesAndDevices,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: cyan.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '+ NHÀ / PHÒNG',
                      style: TextStyle(
                        color: cyan,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildSpacePill(
                  'Tất cả nhà (${_houses.length})',
                  _selectedHouseId == 'ALL',
                  cyan,
                  isDark,
                  () => setState(() {
                    _selectedHouseId = 'ALL';
                    _selectedRoomId = 'ALL';
                  }),
                ),
                ..._houses.map(
                  (h) => _buildSpacePill(
                    (h['name'] ?? '').toString(),
                    _selectedHouseId == h['id'].toString(),
                    cyan,
                    isDark,
                    () => setState(() {
                      _selectedHouseId = h['id'].toString();
                      _selectedRoomId = 'ALL';
                    }),
                  ),
                ),
              ],
            ),
          ),
          if (_visibleRooms.isNotEmpty) ...[
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildSpacePill(
                    'Tất cả phòng',
                    _selectedRoomId == 'ALL',
                    green,
                    isDark,
                    () => setState(() => _selectedRoomId = 'ALL'),
                  ),
                  ..._visibleRooms.map(
                    (r) => _buildSpacePill(
                      (r['name'] ?? '').toString(),
                      _selectedRoomId == r['id'].toString(),
                      green,
                      isDark,
                      () =>
                          setState(() => _selectedRoomId = r['id'].toString()),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSpacePill(
    String label,
    bool selected,
    Color color,
    bool isDark,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? color.withOpacity(0.2)
                : AppColors.getBackground(isDark),
            borderRadius: BorderRadius.circular(18),
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

  Widget _buildAiSuggestionBanner(bool isDark, Color cyan) {
    final temp = _temperature;
    final hum = _humidity;
    final luxVal = _lux;

    final hint = (temp == null || hum == null || luxVal == null)
        ? 'Đang chờ dữ liệu cảm biến từ ESP32 qua MQTT...'
        : temp > 31
        ? 'Nhiệt độ phòng đạt ${temp.toStringAsFixed(1)}°C. Đề xuất bật quạt hoặc điều hòa làm mát.'
        : luxVal < 250
        ? 'Cường độ ánh sáng thấp (${luxVal.toStringAsFixed(0)} lx). Đề xuất bật đèn chiếu sáng.'
        : 'Môi trường ổn định (${temp.toStringAsFixed(1)}°C • ${hum.toStringAsFixed(0)}%). Hệ thống AI đang giám sát.';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.secondary.withOpacity(0.45)),
      ),
      child: Row(
        children: [
          Icon(Icons.psychology_alt, color: cyan, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              hint,
              style: TextStyle(
                color: AppColors.getTextSecondary(isDark),
                fontSize: 11.5,
              ),
            ),
          ),
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
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: ['TẤT CẢ', 'LIGHT', 'SWITCH', 'FAN', 'AC', 'SENSOR']
                .map(
                  (t) => _buildSpacePill(
                    t,
                    _selectedType == t,
                    cyan,
                    isDark,
                    () => setState(() => _selectedType = t),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildActivityLogSection(bool isDark, Color green) {
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
                  Icon(Icons.history, color: green, size: 17),
                  const SizedBox(width: 6),
                  Text(
                    'NHẬT KÝ HOẠT ĐỘNG HỆ THỐNG',
                    style: TextStyle(
                      color: AppColors.getTextPrimary(isDark),
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              if (_logs.isNotEmpty)
                InkWell(
                  onTap: () => setState(() => _logs.clear()),
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
          if (_logs.isEmpty)
            const Text(
              'Chưa có nhật ký hoạt động mới.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 11),
            )
          else
            ..._logs
                .take(8)
                .map(
                  (log) => Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(fontSize: 11.5),
                        children: [
                          TextSpan(
                            text: '[${log['time']}] ',
                            style: TextStyle(
                              color: green,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          TextSpan(
                            text: log['message'],
                            style: TextStyle(
                              color: AppColors.getTextSecondary(isDark),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}
