import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/websocket_service.dart';
import '../theme/app_colors.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final WebSocketService _wsService = WebSocketService();

  StreamSubscription? _sensorSub;
  StreamSubscription? _statusSub;

  // Dữ liệu Cảm biến Real-time
  double temp = 26.5;
  double hum = 62.0;
  double powerWatt = 18.5;
  double todayKwh = 0.35;
  bool isConnected = false;

  // Trạng thái các thiết bị trong nhà
  final Map<String, bool> _deviceStates = {
    '00000000-0000-0000-0000-000000000001': false, // Đèn Phòng Khách
    'DEV_002': true, // Điều Hòa Sci-Fi
    'DEV_003': false, // Quạt Thông Gió
    'DEV_004': true, // Ổ Cắm Thông Minh
  };

  // Nhật ký hệ thống (Cyberpunk Terminal Log)
  final List<String> _systemLogs = [];

  @override
  void initState() {
    super.initState();
    _initWebSocketConnection();
  }

  /// Tự động lấy URL WebSocket chuẩn theo nền tảng
  void _initWebSocketConnection() {
    String wsUrl = 'ws://localhost:3000/ws'; // Mặc định cho Web Chrome
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      wsUrl = 'ws://10.0.2.2:3000/ws'; // Android Emulator
    }

    _wsService.connect(wsUrl);

    _statusSub = _wsService.statusStream.listen((status) {
      if (mounted) {
        setState(() => isConnected = status);
        _addLog(
          status
              ? 'SYSTEM: Connected to WebSocket Server'
              : 'SYSTEM: Connection Lost',
        );
      }
    });

    _sensorSub = _wsService.sensorStream.listen((data) {
      if (mounted) {
        setState(() {
          if (data['temperature'] != null)
            temp = (data['temperature'] as num).toDouble();
          if (data['humidity'] != null)
            hum = (data['humidity'] as num).toDouble();
          if (data['power_watt'] != null)
            powerWatt = (data['power_watt'] as num).toDouble();
        });
        _addLog('TELEMETRY: Temp ${temp}°C | Hum ${hum}%');
      }
    });
  }

  void _addLog(String message) {
    final now = DateTime.now();
    final timeStr =
        "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    setState(() {
      _systemLogs.insert(0, "[$timeStr] $message");
      if (_systemLogs.length > 20) _systemLogs.removeLast();
    });
  }

  @override
  void dispose() {
    _sensorSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text(
          'SCI-FI HUB CONTROL',
          style: TextStyle(
            color: AppColors.primary,
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: _buildStatusBadge(),
          ),
        ],
      ),
      drawer: _buildCyberDrawer(context),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Chỉ số cảm biến môi trường
              _buildSectionTitle('CHỈ SỐ MÔI TRƯỜNG REAL-TIME'),
              const SizedBox(height: 10),
              _buildEnvironmentMetrics(),

              const SizedBox(height: 20),

              // 2. Thống kê điện năng tiêu thụ
              _buildSectionTitle('ĐIỆN NĂNG TIÊU THỤ & CHI PHÍ'),
              const SizedBox(height: 10),
              _buildEnergyAnalyticsCard(),

              const SizedBox(height: 20),

              // 3. Trung tâm điều khiển thiết bị
              _buildSectionTitle('TRUNG TÂM ĐIỀU KHIỂN THIẾT BỊ'),
              const SizedBox(height: 10),
              _buildDeviceGrid(),

              const SizedBox(height: 20),

              // 4. Terminal nhật ký hệ thống
              _buildSectionTitle('NHẬT KÝ HỆ THỐNG (CYBERPUNK TERMINAL)'),
              const SizedBox(height: 10),
              _buildTerminalLogCard(),
            ],
          ),
        ),
      ),
    );
  }

  // Header Status Badge
  Widget _buildStatusBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isConnected ? AppColors.glowCyan : Colors.red.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isConnected ? AppColors.primary : Colors.red),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: isConnected ? AppColors.primary : Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            isConnected ? 'ONLINE' : 'OFFLINE',
            style: TextStyle(
              color: isConnected ? AppColors.primary : Colors.red,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // Drawer Menu Sci-Fi
  Widget _buildCyberDrawer(BuildContext context) {
    return Drawer(
      backgroundColor: AppColors.surface,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              border: const Border(
                bottom: BorderSide(color: AppColors.primary, width: 2),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.hub, color: AppColors.primary, size: 40),
                SizedBox(height: 10),
                Text(
                  'NEXUS IOT CONTROL',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(
                  'v2.4 Sci-Fi Edition',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dashboard, color: AppColors.primary),
            title: const Text(
              'Bảng Điều Khiển',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            onTap: () => Navigator.pop(context),
          ),
          ListTile(
            leading: const Icon(Icons.people, color: AppColors.secondary),
            title: const Text(
              'Quản Lý Người Dùng',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/users');
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings, color: AppColors.textSecondary),
            title: const Text(
              'Cấu Hình Hệ Thống',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            onTap: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
      ),
    );
  }

  // 1. Chỉ số Môi trường (Temp, Humidity, Power)
  Widget _buildEnvironmentMetrics() {
    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            'NHIỆT ĐỘ',
            temp.toStringAsFixed(1),
            '°C',
            Icons.thermostat,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildMetricCard(
            'ĐỘ ẨM',
            hum.toStringAsFixed(1),
            '%',
            Icons.water_drop,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildMetricCard(
            'CÔNG SUẤT',
            powerWatt.toStringAsFixed(1),
            'W',
            Icons.flash_on,
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard(
    String label,
    String value,
    String unit,
    IconData icon,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Icon(icon, color: AppColors.primary, size: 14),
            ],
          ),
          const SizedBox(height: 6),
          RichText(
            text: TextSpan(
              text: value,
              style: const TextStyle(
                color: AppColors.primary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              children: [
                TextSpan(
                  text: ' $unit',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 2. Điện năng & Chi phí
  Widget _buildEnergyAnalyticsCard() {
    final costEstimate = (todayKwh * 2500).round(); // Tạm tính 2.500đ / kWh
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Tổng Điện Năng Hôm Nay',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$todayKwh kWh',
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'Chi Phí Ước Tính',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$costEstimate VNĐ',
                    style: const TextStyle(
                      color: AppColors.secondary,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Biểu đồ điện năng giả lập đơn giản Sci-Fi
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(12, (index) {
              final heights = [
                15.0,
                25.0,
                10.0,
                40.0,
                30.0,
                50.0,
                20.0,
                35.0,
                60.0,
                45.0,
                25.0,
                30.0,
              ];
              return Container(
                width: 16,
                height: heights[index],
                decoration: BoxDecoration(
                  color: index == 8
                      ? AppColors.primary
                      : AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: index == 8 ? AppColors.primary : AppColors.border,
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  // 3. Grid nhiều thiết bị
  Widget _buildDeviceGrid() {
    final devices = [
      {
        'id': '00000000-0000-0000-0000-000000000001',
        'name': 'Đèn Phòng Khách',
        'icon': Icons.lightbulb,
        'sub': '18W • DHT22',
      },
      {
        'id': 'DEV_002',
        'name': 'Điều Hòa Sci-Fi',
        'icon': Icons.ac_unit,
        'sub': '850W • Smart Hub',
      },
      {
        'id': 'DEV_003',
        'name': 'Quạt Thông Gió',
        'icon': Icons.wind_power,
        'sub': '45W • Sensor Linked',
      },
      {
        'id': 'DEV_004',
        'name': 'Ổ Cắm Thông Minh',
        'icon': Icons.power,
        'sub': 'Max 2500W',
      },
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.4,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final dev = devices[index];
        final id = dev['id'] as String;
        final isOn = _deviceStates[id] ?? false;

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isOn ? AppColors.primary : AppColors.border,
            ),
            boxShadow: isOn
                ? [
                    BoxShadow(
                      color: AppColors.primary.withOpacity(0.15),
                      blurRadius: 8,
                    ),
                  ]
                : [],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    dev['icon'] as IconData,
                    color: isOn ? AppColors.primary : AppColors.textMuted,
                  ),
                  Switch(
                    value: isOn,
                    activeColor: AppColors.primary,
                    activeTrackColor: AppColors.glowCyan,
                    inactiveThumbColor: AppColors.textMuted,
                    inactiveTrackColor: AppColors.surfaceLight,
                    onChanged: (val) {
                      setState(() => _deviceStates[id] = val);
                      _wsService.toggleDevice(id, val);
                      _addLog(
                        "CONTROL: ${dev['name']} turned ${val ? 'ON' : 'OFF'}",
                      );
                    },
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    dev['name'] as String,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    dev['sub'] as String,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // 4. Cyberpunk Log Terminal
  Widget _buildTerminalLogCard() {
    return Container(
      width: double.infinity,
      height: 130,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.primary.withOpacity(0.5)),
      ),
      child: ListView.builder(
        itemCount: _systemLogs.length,
        itemBuilder: (context, index) {
          return Text(
            _systemLogs[index],
            style: const TextStyle(
              color: AppColors.primary,
              fontFamily: 'monospace',
              fontSize: 10,
            ),
          );
        },
      ),
    );
  }
}
