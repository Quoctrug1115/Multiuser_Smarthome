import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ApiService _api = ApiService();
  final TextEditingController _searchController = TextEditingController();

  String _selectedTypeFilter = 'TẤT CẢ';
  bool _isLoading = true;
  bool _isLoadingAi = false;

  JsonList _devices = [];
  JsonList _aiSuggestions = [];
  final List _activityLogs = [];

  // Dữ liệu cảm biến Realtime nhận từ Wokwi qua WebSocket
  double _temperature = 28.5;
  double _humidity = 65.0;
  int _lux = 450;
  bool _motion = false;
  bool _wsConnected = false;
  WebSocket? _ws;
  Timer? _wsReconnectTimer;

  @override
  void initState() {
    super.initState();
    _addLog('Hệ thống khởi động & đồng bộ dữ liệu IoT', 'SYSTEM');
    _loadAllData();
    _connectWebSocket();
  }

  Future<void> _loadAllData() async {
    await Future.wait([_loadDevices(), _loadAiSuggestions()]);
  }

  Future<void> _loadDevices() async {
    setState(() => _isLoading = true);
    try {
      final list = await _api.getDevices();
      if (!mounted) return;
      setState(() {
        _devices = list;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnack(e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
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

  void _connectWebSocket() async {
    try {
      final socket = await WebSocket.connect('ws://127.0.0.1:3000/ws');
      if (!mounted) {
        socket.close();
        return;
      }
      _ws = socket;
      setState(() => _wsConnected = true);
      _addLog('Kết nối luồng Telemetry Realtime (Wokwi -> Backend)', 'MQTT');

      socket.listen(
        (raw) {
          if (!mounted) return;
          try {
            final msg = jsonDecode(raw.toString());
            if (msg is Map && msg['type'] == 'SENSOR_UPDATE') {
              final data = msg['data'] ?? {};
              final newMotion = data['motion'] == true;
              setState(() {
                _temperature = (data['temperature'] ?? _temperature).toDouble();
                _humidity = (data['humidity'] ?? _humidity).toDouble();
                _lux = (data['lux'] ?? _lux).toInt();
                if (newMotion && !_motion) {
                  _addLog(
                    'Phát hiện chuyển động từ cảm biến PIR (Wokwi)',
                    'SENSOR',
                  );
                }
                _motion = newMotion;
              });
            }
          } catch (_) {}
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _wsConnected = false);
          _scheduleWsReconnect();
        },
        onError: (_) {
          if (!mounted) return;
          setState(() => _wsConnected = false);
          _scheduleWsReconnect();
        },
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _wsConnected = false);
      _scheduleWsReconnect();
    }
  }

  void _scheduleWsReconnect() {
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_wsConnected) _connectWebSocket();
    });
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
      if (_activityLogs.length > 25) {
        _activityLogs.removeLast();
      }
    });
  }

  // Bảng màu thích ứng độ tương phản cao cho cả nền trắng (Light) và nền tối (Dark)
  Color _accentCyan(bool isDark) =>
      isDark ? AppColors.primary : const Color(0xFF0284C7);
  Color _accentGreen(bool isDark) =>
      isDark ? Colors.greenAccent : const Color(0xFF0D9488);
  Color _accentAmber(bool isDark) =>
      isDark ? Colors.amber : const Color(0xFFD97706);

  JsonList get _filteredDevices {
    final query = _searchController.text.trim().toLowerCase();
    return _devices.where((device) {
      final type = (device['device_type'] ?? 'switch').toString().toUpperCase();
      final name = (device['name'] ?? '').toString().toLowerCase();
      final topic = (device['mqtt_topic'] ?? '').toString().toLowerCase();

      final matchesType =
          _selectedTypeFilter == 'TẤT CẢ' || type == _selectedTypeFilter;
      final matchesQuery =
          query.isEmpty || name.contains(query) || topic.contains(query);
      return matchesType && matchesQuery;
    }).toList();
  }

  bool _isDeviceOn(JsonMap device) {
    final raw = device['is_on'] ?? device['status'] ?? device['state'];
    if (raw is bool) return raw;
    final str = (raw ?? '').toString().trim().toLowerCase();
    return str == 'true' || str == 'on' || str == '1' || str == 'active';
  }

  IconData _getDeviceIcon(String type) {
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

  Color _getDeviceColor(String type, bool isOn, bool isDark) {
    if (type.toLowerCase() == 'sensor') return _accentAmber(isDark);
    if (!isOn) return AppColors.textMuted;
    switch (type.toLowerCase()) {
      case 'light':
        return _accentCyan(isDark);
      case 'fan':
      case 'ac':
        return _accentGreen(isDark);
      default:
        return AppColors.secondary;
    }
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

  // ==================== HỘP THOẠI QUÉT THIẾT BỊ TỪ WOKWI ====================
  void _showWokwiDiscoveryDialog(bool isDark) {
    final cyan = _accentCyan(isDark);
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
                child: FutureBuilder<JsonList>(
                  future: _api.discoverWokwiDevices(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return SizedBox(
                        height: 120,
                        child: Center(
                          child: CircularProgressIndicator(color: cyan),
                        ),
                      );
                    }
                    final discovered = snapshot.data ?? [];
                    if (discovered.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          'Không còn thiết bị Wokwi mới nào chưa thêm.\nHãy đảm bảo mô phỏng Wokwi đang chạy (Play).',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      );
                    }
                    return ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: discovered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final item = discovered[index];
                          final name = (item['name'] ?? 'Thiết bị Wokwi')
                              .toString();
                          final type = (item['device_type'] ?? 'switch')
                              .toString();
                          final topic = (item['mqtt_topic'] ?? '').toString();

                          return Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.getBackground(isDark),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: cyan.withOpacity(0.4)),
                            ),
                            child: Row(
                              children: [
                                Icon(_getDeviceIcon(type), color: cyan),
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
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                  ),
                                  onPressed: () async {
                                    try {
                                      await _api.createDevice(
                                        name: name,
                                        deviceType: type,
                                        mqttTopic: topic,
                                      );
                                      if (!context.mounted) return;
                                      Navigator.pop(ctx);
                                      _addLog(
                                        'Thêm thiết bị Wokwi: $name',
                                        'DEVICE',
                                      );
                                      _showSnack('Đã thêm "$name"');
                                      _loadDevices();
                                    } catch (e) {
                                      _showSnack(
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

  // ==================== HỘP THOẠI THÊM / SỬA THIẾT BỊ THỦ CÔNG ====================
  void _showDeviceFormDialog(bool isDark, {JsonMap? existingDevice}) {
    final isEdit = existingDevice != null;
    final cyan = _accentCyan(isDark);
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
                    decoration: const InputDecoration(
                      labelText: 'Loại thiết bị',
                    ),
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
                      DropdownMenuItem(
                        value: 'ac',
                        child: Text('AC (Điều hòa)'),
                      ),
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
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  final topic = topicCtrl.text.trim();
                  if (name.isEmpty || topic.isEmpty) {
                    _showSnack(
                      'Vui lòng nhập đầy đủ tên và topic!',
                      isError: true,
                    );
                    return;
                  }
                  Navigator.pop(ctx);
                  try {
                    if (isEdit) {
                      await _api.updateDevice(
                        existingDevice['id'].toString(),
                        name: name,
                        deviceType: selectedType,
                        mqttTopic: topic,
                      );
                      _addLog('Cập nhật thiết bị: $name', 'DEVICE');
                      _showSnack('Đã cập nhật thiết bị');
                    } else {
                      await _api.createDevice(
                        name: name,
                        deviceType: selectedType,
                        mqttTopic: topic,
                      );
                      _addLog('Tạo mới thiết bị: $name', 'DEVICE');
                      _showSnack('Đã thêm thiết bị mới');
                    }
                    _loadDevices();
                  } catch (e) {
                    _showSnack(
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

  @override
  void dispose() {
    _searchController.dispose();
    _wsReconnectTimer?.cancel();
    _ws?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;
    final apiService = Provider.of<ApiService>(context);

    final cyan = _accentCyan(isDark);
    final green = _accentGreen(isDark);
    final amber = _accentAmber(isDark);

    final isOwner = apiService.isAdmin;
    final userRole =
        (apiService.currentUser?['role'] ??
                apiService.currentUser?['role_name'] ??
                'Member')
            .toString()
            .toLowerCase();
    final canControl = userRole != 'guest';

    final filteredList = _filteredDevices;

    // Gợi ý mặc định thông minh kết hợp dữ liệu thực tế nếu API AI chưa có bản ghi
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
                  : 'Đủ ánh sáng ban ngày, có thể tắt đèn chiếu sáng để tiết kiệm ~18W.',
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
                  onPressed: () => _showWokwiDiscoveryDialog(isDark),
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
                  onPressed: () => _showDeviceFormDialog(isDark),
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
            // 1. CẢM BIẾN MÔI TRƯỜNG REALTIME (TỪ WOKWI)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'CẢM BIẾN MÔI TRƯỜNG (WOKWI)',
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
                      color: _wsConnected ? green : AppColors.accent,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _wsConnected ? 'LIVE MQTT' : 'OFFLINE',
                      style: TextStyle(
                        color: _wsConnected ? green : AppColors.accent,
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
                    '${_temperature.toStringAsFixed(1)}°C',
                    Icons.thermostat,
                    AppColors.accent,
                    isDark,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildSensorTile(
                    'ĐỘ ẨM',
                    '${_humidity.toStringAsFixed(0)}%',
                    Icons.water_drop_outlined,
                    cyan,
                    isDark,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildSensorTile(
                    'ÁNH SÁNG',
                    '$_lux lx',
                    Icons.wb_sunny_outlined,
                    amber,
                    isDark,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildSensorTile(
                    'CHUYỂN ĐỘNG',
                    _motion ? 'CÓ' : 'KHÔNG',
                    Icons.directions_run,
                    _motion ? AppColors.accent : green,
                    isDark,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 18),

            // 2. KHỐI AI GỢI Ý & PHÂN TÍCH THÔNG MINH (GIỐNG WEB REACT)
            Container(
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
                        child: CircularProgressIndicator(
                          color: cyan,
                          strokeWidth: 2,
                        ),
                      ),
                    )
                  else
                    ...effectiveAiList.take(3).map((item) {
                      final title =
                          (item['title'] ??
                                  item['alert_type'] ??
                                  'Gợi ý tiết kiệm điện')
                              .toString();
                      final desc =
                          (item['message'] ?? item['description'] ?? '')
                              .toString();
                      final severity = (item['severity'] ?? 'info')
                          .toString()
                          .toLowerCase();
                      final badgeColor =
                          severity == 'critical' || severity == 'high'
                          ? AppColors.accent
                          : (severity == 'warning' ? amber : cyan);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.getBackground(isDark),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: badgeColor.withOpacity(0.35),
                          ),
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
                                    const SizedBox(height: 2),
                                    Text(
                                      desc,
                                      style: TextStyle(
                                        color: AppColors.getTextSecondary(
                                          isDark,
                                        ),
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
            ),

            const SizedBox(height: 18),

            // 3. DANH SÁCH THIẾT BỊ ĐIỀU KHIỂN
            Text(
              'THIẾT BỊ KẾT NỐI (${_devices.length})',
              style: TextStyle(
                color: AppColors.getTextPrimary(isDark),
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(height: 8),
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
                filled: true,
                fillColor: AppColors.getSurface(isDark),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: ['TẤT CẢ', 'LIGHT', 'SWITCH', 'FAN', 'AC', 'SENSOR']
                    .map((type) {
                      final isSelected = _selectedTypeFilter == type;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(
                            type,
                            style: TextStyle(
                              color: isSelected
                                  ? (isDark
                                        ? const Color(0xFF0A0E1A)
                                        : Colors.white)
                                  : AppColors.getTextSecondary(isDark),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          selected: isSelected,
                          selectedColor: cyan,
                          backgroundColor: AppColors.getSurface(isDark),
                          onSelected: (_) =>
                              setState(() => _selectedTypeFilter = type),
                        ),
                      );
                    })
                    .toList(),
              ),
            ),
            const SizedBox(height: 10),

            if (_isLoading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator(color: cyan)),
              )
            else if (filteredList.isEmpty)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.getSurface(isDark),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.getBorder(isDark)),
                ),
                child: Text(
                  isOwner
                      ? 'Chưa có thiết bị nào. Bấm "QUÉT WOKWI" ở góc dưới để dò mạch ESP32!'
                      : 'Chưa có thiết bị nào được cấu hình.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              )
            else
              ...filteredList.map((device) {
                final id = device['id'].toString();
                final name = (device['name'] ?? 'Thiết bị').toString();
                final type = (device['device_type'] ?? 'switch').toString();
                final topic = (device['mqtt_topic'] ?? '').toString();
                final isSensor = type.toLowerCase() == 'sensor';
                final isOn = _isDeviceOn(device);
                final accentColor = _getDeviceColor(type, isOn, isDark);

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.getSurface(isDark),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isOn && !isSensor
                          ? accentColor.withOpacity(0.55)
                          : AppColors.getBorder(isDark),
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: accentColor.withOpacity(0.15),
                            child: Icon(
                              _getDeviceIcon(type),
                              color: accentColor,
                              size: 20,
                            ),
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
                                          color: AppColors.getTextPrimary(
                                            isDark,
                                          ),
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: accentColor.withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        type.toUpperCase(),
                                        style: TextStyle(
                                          color: accentColor,
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  topic,
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
                              icon: Icon(
                                Icons.more_vert,
                                color: AppColors.getTextSecondary(isDark),
                              ),
                              color: AppColors.getSurface(isDark),
                              onSelected: (action) async {
                                if (action == 'edit') {
                                  _showDeviceFormDialog(
                                    isDark,
                                    existingDevice: device,
                                  );
                                } else if (action == 'delete') {
                                  try {
                                    await _api.deleteDevice(id);
                                    _addLog('Xóa thiết bị: $name', 'DEVICE');
                                    _showSnack('Đã xóa $name');
                                    _loadDevices();
                                  } catch (e) {
                                    _showSnack(
                                      e.toString().replaceFirst(
                                        'Exception: ',
                                        '',
                                      ),
                                      isError: true,
                                    );
                                  }
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text('Sửa thiết bị'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text(
                                    'Xóa thiết bị',
                                    style: TextStyle(color: AppColors.accent),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      Divider(height: 16, color: AppColors.getBorder(isDark)),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isSensor
                                ? 'TELEMETRY STREAM (5S)'
                                : (canControl
                                      ? 'ĐIỀU KHIỂN MQTT'
                                      : 'CHỈ XEM (GUEST)'),
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 10,
                            ),
                          ),
                          if (isSensor)
                            Text(
                              'ONLINE',
                              style: TextStyle(
                                color: amber,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          else
                            Row(
                              children: [
                                Text(
                                  isOn ? 'ĐANG BẬT' : 'ĐÃ TẮT',
                                  style: TextStyle(
                                    color: isOn ? green : AppColors.textMuted,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                SizedBox(
                                  height: 24,
                                  child: Switch(
                                    value: isOn,
                                    activeColor: cyan,
                                    onChanged: !canControl
                                        ? null
                                        : (val) async {
                                            final cmd = val ? 'ON' : 'OFF';
                                            setState(() {
                                              device['is_on'] = val;
                                              device['status'] = cmd;
                                            });
                                            try {
                                              await _api.controlDevice(
                                                id,
                                                cmd,
                                                mqttTopic: topic,
                                              );
                                              _addLog(
                                                '${val ? "Bật" : "Tắt"} $name ($cmd)',
                                                'MQTT',
                                              );
                                            } catch (e) {
                                              setState(() {
                                                device['is_on'] = !val;
                                                device['status'] = !val
                                                    ? 'ON'
                                                    : 'OFF';
                                              });
                                              _showSnack(
                                                e.toString().replaceFirst(
                                                  'Exception: ',
                                                  '',
                                                ),
                                                isError: true,
                                              );
                                            }
                                          },
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              }),

            const SizedBox(height: 16),

            // 4. NHẬT KÝ HOẠT ĐỘNG HỆ THỐNG (GIỐNG WEB REACT)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.getSurface(isDark),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.getBorder(isDark)),
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
                      'Chưa có sự kiện nào được ghi nhận.',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    )
                  else
                    ..._activityLogs.take(8).map((log) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            Text(
                              '[${log['time']}]',
                              style: TextStyle(
                                color: cyan,
                                fontSize: 11,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                log['message'] ?? '',
                                style: TextStyle(
                                  color: AppColors.getTextSecondary(isDark),
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSensorTile(
    String label,
    String value,
    IconData icon,
    Color color,
    bool isDark,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.getBorder(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: AppColors.getTextPrimary(isDark),
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 8.5,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
