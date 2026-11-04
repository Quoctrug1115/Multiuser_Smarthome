import 'package:flutter/material.dart';
import 'package:mobile/screens/user_management_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({Key? key}) : super(key: key);

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _currentTabIndex = 0;
  bool isDarkMode = true;
  String currentRole = 'Owner'; // 'Owner' | 'Member' | 'Guest'
  String selectedRoom = 'Tất cả';

  // Thông số cảm biến Real-time
  double sensorTemp = 28.5;
  int sensorHum = 62;
  int sensorLux = 450;
  bool isMotionDetected = true;

  // Danh sách Phòng
  final List<String> rooms = [
    'Tất cả',
    'Phòng khách',
    'Nhà bếp',
    'Phòng ngủ',
    'Cửa chính',
  ];

  // Danh sách Thiết bị
  List<Map<String, dynamic>> devices = [
    {
      'id': 'd1',
      'name': 'Đèn phòng khách',
      'room': 'Phòng khách',
      'status': true,
      'power': 18.0,
    },
    {
      'id': 'd2',
      'name': 'Quạt thông gió',
      'room': 'Nhà bếp',
      'status': false,
      'power': 45.0,
    },
    {
      'id': 'd3',
      'name': 'Khóa cửa Smart',
      'room': 'Cửa chính',
      'status': true,
      'power': 5.0,
    },
    {
      'id': 'd4',
      'name': 'Đèn ngủ PWM',
      'room': 'Phòng ngủ',
      'status': true,
      'power': 12.0,
    },
  ];

  // AI Alerts & Automations
  List<Map<String, String>> aiAlerts = [
    {
      'id': 'a1',
      'type': 'HIGH_SPIKE (Z-Score: 3.85)',
      'message': 'Phát hiện nhiệt độ vọt 65°C bất thường tại Phòng khách!',
      'time': '10:12:05',
    },
  ];

  List<Map<String, dynamic>> automations = [
    {
      'id': 'rule-1',
      'name': 'Bật quạt khi nhiệt độ cao',
      'condition': 'Nhiệt độ > 30°C',
      'action': 'Bật Quạt thông gió',
      'active': true,
    },
  ];

  // Quản lý Khách
  List<Map<String, String>> guests = [
    {
      'id': 'g1',
      'name': 'Nguyễn Văn A (Khách)',
      'device': 'Khóa cửa Smart',
      'expiry': 'Còn 02 giờ 15 phút',
      'status': 'ACTIVE',
    },
  ];

  // Live Terminal Logs
  List<String> logs = [
    '[SYSTEM] Mobile WebSocket Channel Active...',
    '[MQTT] Subscribed to smarthome/devices/+/telemetry',
  ];

  // Giả lập vọt nhiệt độ 65°C
  void triggerAnomaly() {
    setState(() {
      sensorTemp = 65.0;
      aiAlerts.insert(0, {
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'type': 'CRITICAL_SPIKE (Z-Score: 4.12)',
        'message': 'CẢNH BÁO AI: Phát hiện sự cố nhiệt độ vọt 65°C!',
        'time': 'Vừa xong',
      });
      logs.insert(0, '[AI_ENGINE] Z-Score Anomaly Detected! Temp: 65.0°C');
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        backgroundColor: Colors.redAccent,
        content: Text(
          '⚠️ AI Alert: Phát hiện nhiệt độ vọt 65°C! Z-Score > 3.0',
        ),
      ),
    );
  }

  // Thu hồi quyền Khách
  void revokeGuest(String id) {
    setState(() {
      final guest = guests.firstWhere((g) => g['id'] == id);
      guest['status'] = 'REVOKED';
      logs.insert(0, '[RBAC] Owner revoked access for guest $id');
    });
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = isDarkMode
        ? const Color(0xFF09090B)
        : const Color(0xFFF4F4F5);
    final cardColor = isDarkMode ? const Color(0xFF18181B) : Colors.white;
    final textColor = isDarkMode ? Colors.white : const Color(0xFF18181B);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: cardColor,
        elevation: 0,
        title: const Text(
          'SmartHome IoT',
          style: TextStyle(
            color: Colors.cyanAccent,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        actions: [
          if (currentRole == 'Owner')
            IconButton(
              icon: const Icon(Icons.manage_accounts, color: Colors.cyanAccent),
              tooltip: 'Quản lý Tài khoản',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const UserManagementScreen(),
                  ),
                );
              },
            ),
          IconButton(
            icon: Icon(
              isDarkMode ? Icons.wb_sunny : Icons.nightlight_round,
              color: Colors.amber,
            ),
            onPressed: () => setState(() => isDarkMode = !isDarkMode),
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentTabIndex,
        children: [
          _buildControlTab(cardColor, textColor),
          _buildAITab(cardColor, textColor),
          _buildEnergyAndGuestTab(cardColor, textColor),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTabIndex,
        onTap: (index) => setState(() => _currentTabIndex = index),
        backgroundColor: cardColor,
        selectedItemColor: Colors.cyanAccent,
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_customize),
            label: 'Điều khiển',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.auto_awesome),
            label: 'AI & Tự động',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.analytics),
            label: 'Điện & Khách',
          ),
        ],
      ),
    );
  }

  // TAB 1: GIAO DIỆN GIÁM SÁT & ĐIỀU KHIỂN
  Widget _buildControlTab(Color cardColor, Color textColor) {
    final filteredDevices = selectedRoom == 'Tất cả'
        ? devices
        : devices.where((d) => d['room'] == selectedRoom).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Role Selector Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Vai trò người dùng:',
                  style: TextStyle(color: textColor, fontSize: 13),
                ),
                DropdownButton<String>(
                  value: currentRole,
                  dropdownColor: cardColor,
                  style: const TextStyle(
                    color: Colors.cyanAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  underline: const SizedBox(),
                  items: ['Owner', 'Member', 'Guest'].map((role) {
                    return DropdownMenuItem(value: role, child: Text(role));
                  }).toList(),
                  onChanged: (val) => setState(() => currentRole = val!),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Khối Cảm biến Real-time (2x2 Grid)
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.35,
            children: [
              // Temp Sensor
              _buildSensorCard(
                cardColor,
                'Nhiệt độ (DHT22)',
                '$sensorTemp °C',
                Icons.thermostat,
                Colors.orangeAccent,
                buttonAction: triggerAnomaly,
                buttonText: '🔥 Giả lập 65°C',
              ),
              // Humidity
              _buildSensorCard(
                cardColor,
                'Độ ẩm',
                '$sensorHum %',
                Icons.water_drop,
                Colors.blueAccent,
              ),
              // Light
              _buildSensorCard(
                cardColor,
                'Ánh sáng',
                '$sensorLux Lux',
                Icons.light_mode,
                Colors.amber,
              ),
              // Motion
              _buildSensorCard(
                cardColor,
                'Chuyển động',
                isMotionDetected ? 'Có người' : 'Trống',
                Icons.sensors,
                Colors.greenAccent,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Room Filter ChoiceChips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: rooms.map((room) {
                final isSelected = selectedRoom == room;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: ChoiceChip(
                    label: Text(
                      room,
                      style: TextStyle(
                        color: isSelected ? Colors.black : textColor,
                        fontSize: 12,
                      ),
                    ),
                    selected: isSelected,
                    selectedColor: Colors.cyanAccent,
                    backgroundColor: cardColor,
                    onSelected: (val) => setState(() => selectedRoom = room),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),

          // Device Control List
          Text(
            'Danh sách Thiết bị',
            style: TextStyle(
              color: textColor,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),

          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: filteredDevices.length,
            itemBuilder: (context, index) {
              final dev = filteredDevices[index];
              final isGuest = currentRole == 'Guest';

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          dev['name'],
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${dev['room']} • ${dev['power']}W',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isGuest
                            ? Colors.grey.shade800
                            : (dev['status']
                                  ? Colors.cyan.shade700
                                  : Colors.grey.shade800),
                      ),
                      onPressed: isGuest
                          ? null
                          : () {
                              setState(() {
                                dev['status'] = !dev['status'];
                                logs.insert(
                                  0,
                                  '[MQTT] Toggled ${dev['name']} -> ${dev['status']}',
                                );
                              });
                            },
                      child: Text(
                        dev['status'] ? 'ĐANG BẬT' : 'ĐANG TẮT',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 16),

          // Live System Logs Stream
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '🖥️ Live System Log Stream',
                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 60,
                  child: ListView.builder(
                    itemCount: logs.length,
                    itemBuilder: (ctx, idx) => Text(
                      logs[idx],
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // TAB 2: AI & TỰ ĐỘNG HÓA
  Widget _buildAITab(Color cardColor, Color textColor) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '🤖 Cảnh báo AI Anomaly (Z-Score)',
            style: TextStyle(
              color: Colors.redAccent.shade100,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: aiAlerts.length,
            itemBuilder: (ctx, idx) {
              final alert = aiAlerts[idx];
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${alert['type']} - ${alert['time']}',
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      alert['message']!,
                      style: TextStyle(color: textColor, fontSize: 12),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 20),

          Text(
            '⚡ Kịch bản Tự động hóa (IF-THEN)',
            style: TextStyle(
              color: Colors.cyanAccent,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: automations.length,
            itemBuilder: (ctx, idx) {
              final rule = automations[idx];
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          rule['name'],
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          'IF ${rule['condition']} THEN ${rule['action']}',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const Chip(
                      label: Text(
                        'ACTIVE',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.greenAccent,
                        ),
                      ),
                      backgroundColor: Colors.black26,
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // TAB 3: ĐIỆN NĂNG & QUẢN LÝ KHÁCH
  Widget _buildEnergyAndGuestTab(Color cardColor, Color textColor) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '📊 Thống kê Điện năng (TimescaleDB)',
            style: TextStyle(
              color: textColor,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const [
                    Text(
                      'Tổng tiêu thụ (7 ngày):',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    Text(
                      '37.1 kWh',
                      style: TextStyle(
                        color: Colors.cyanAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 20, color: Colors.white10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const [
                    Text(
                      'Chi phí ước tính:',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    Text(
                      '92.750 VNĐ',
                      style: TextStyle(
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          Text(
            '🔑 Quản lý Truy cập Khách',
            style: TextStyle(
              color: textColor,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: guests.length,
            itemBuilder: (ctx, idx) {
              final g = guests[idx];
              final isRevoked = g['status'] == 'REVOKED';

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          g['name']!,
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          '${g['device']} • ${g['expiry']}',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    isRevoked
                        ? const Text(
                            'REVOKED',
                            style: TextStyle(color: Colors.grey, fontSize: 11),
                          )
                        : ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent.shade700,
                            ),
                            onPressed: currentRole == 'Owner'
                                ? () => revokeGuest(g['id']!)
                                : null,
                            child: const Text(
                              'Thu hồi',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // Helper Card cho Cảm biến
  Widget _buildSensorCard(
    Color cardColor,
    String label,
    String value,
    IconData icon,
    Color iconColor, {
    VoidCallback? buttonAction,
    String? buttonText,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
              Icon(icon, color: iconColor, size: 18),
            ],
          ),
          Text(
            value,
            style: TextStyle(
              color: iconColor,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
          if (buttonAction != null)
            SizedBox(
              width: double.infinity,
              height: 26,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent.shade700,
                  padding: EdgeInsets.zero,
                ),
                onPressed: buttonAction,
                child: Text(
                  buttonText!,
                  style: const TextStyle(fontSize: 10, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
