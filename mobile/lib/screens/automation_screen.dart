import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/smarthome_models.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';

class AutomationScreen extends StatefulWidget {
  const AutomationScreen({super.key});

  @override
  State<AutomationScreen> createState() => _AutomationScreenState();
}

class _AutomationScreenState extends State<AutomationScreen> {
  final ApiService _api = ApiService();
  JsonList _rules = [];
  List<Device> _devices = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        _api.getAutomations(),
        _api.getDevices().catchError((_) => <JsonMap>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _rules = results[0];
        _devices = results[1]
            .map((e) => Device.fromJson(e))
            .where((d) => d.deviceType.toLowerCase() != 'sensor')
            .toList();
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

  void _showAddRuleDialog(bool isDark) {
    final nameCtrl = TextEditingController();
    final condCtrl = TextEditingController(text: 'Nhiệt độ > 30');
    final actionCtrl = TextEditingController(
      text: _devices.isNotEmpty
          ? 'Bật ${_devices.first.name} (ON)'
          : 'Bật Quạt Phòng Khách (ON)',
    );

    String sensorMetric = 'Nhiệt độ';
    String operatorSymbol = '>';
    final thresholdCtrl = TextEditingController(text: '30');
    String targetDeviceName = _devices.isNotEmpty
        ? _devices.first.name
        : 'Quạt Phòng Khách';
    String targetAction = 'ON';

    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);

    void syncTextsFromBuilder() {
      condCtrl.text =
          '$sensorMetric $operatorSymbol ${thresholdCtrl.text.trim()}';
      actionCtrl.text =
          '${targetAction == "ON" ? "Bật" : "Tắt"} $targetDeviceName ($targetAction)';
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: AppColors.getSurface(isDark),
            title: Text(
              'TẠO KỊCH BẢN TỰ ĐỘNG',
              style: TextStyle(
                color: AppColors.getTextPrimary(isDark),
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Mẫu kích hoạt nhanh Wokwi:',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ActionChip(
                        label: const Text(
                          'Nóng > 30°C → Bật Quạt',
                          style: TextStyle(fontSize: 11),
                        ),
                        onPressed: () {
                          setDialogState(() {
                            nameCtrl.text = 'Tự động làm mát phòng khách';
                            condCtrl.text = 'Nhiệt độ > 30';
                            actionCtrl.text = 'Bật Quạt Phòng Khách (ON)';
                          });
                        },
                      ),
                      ActionChip(
                        label: const Text(
                          'Tối < 300 lx → Bật Đèn',
                          style: TextStyle(fontSize: 11),
                        ),
                        onPressed: () {
                          setDialogState(() {
                            nameCtrl.text = 'Bật đèn khi trời tối';
                            condCtrl.text = 'Ánh sáng < 300';
                            actionCtrl.text = 'Bật Đèn Phòng Khách (ON)';
                          });
                        },
                      ),
                      ActionChip(
                        label: const Text(
                          'Có chuyển động → Bật Đèn',
                          style: TextStyle(fontSize: 11),
                        ),
                        onPressed: () {
                          setDialogState(() {
                            nameCtrl.text = 'Cảnh báo chuyển động PIR';
                            condCtrl.text = 'Chuyển động == 1';
                            actionCtrl.text = 'Bật Đèn Phòng Khách (ON)';
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameCtrl,
                    style: TextStyle(color: AppColors.getTextPrimary(isDark)),
                    decoration: const InputDecoration(
                      labelText: 'Tên kịch bản',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: DropdownButtonFormField<String>(
                          value: sensorMetric,
                          dropdownColor: AppColors.getSurface(isDark),
                          style: TextStyle(
                            color: AppColors.getTextPrimary(isDark),
                            fontSize: 12,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Cảm biến',
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'Nhiệt độ',
                              child: Text('Nhiệt độ'),
                            ),
                            DropdownMenuItem(
                              value: 'Độ ẩm',
                              child: Text('Độ ẩm'),
                            ),
                            DropdownMenuItem(
                              value: 'Ánh sáng',
                              child: Text('Ánh sáng'),
                            ),
                            DropdownMenuItem(
                              value: 'Chuyển động',
                              child: Text('Chuyển động'),
                            ),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setDialogState(() {
                                sensorMetric = val;
                                syncTextsFromBuilder();
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String>(
                          value: operatorSymbol,
                          dropdownColor: AppColors.getSurface(isDark),
                          style: TextStyle(
                            color: AppColors.getTextPrimary(isDark),
                            fontSize: 12,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'So sánh',
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(value: '>', child: Text('>')),
                            DropdownMenuItem(value: '<', child: Text('<')),
                            DropdownMenuItem(value: '==', child: Text('==')),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setDialogState(() {
                                operatorSymbol = val;
                                syncTextsFromBuilder();
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: thresholdCtrl,
                          keyboardType: TextInputType.number,
                          style: TextStyle(
                            color: AppColors.getTextPrimary(isDark),
                            fontSize: 12,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Ngưỡng',
                            isDense: true,
                          ),
                          onChanged: (_) => syncTextsFromBuilder(),
                        ),
                      ),
                    ],
                  ),
                  if (_devices.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: DropdownButtonFormField<String>(
                            value: targetDeviceName,
                            dropdownColor: AppColors.getSurface(isDark),
                            style: TextStyle(
                              color: AppColors.getTextPrimary(isDark),
                              fontSize: 12,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Thiết bị thực thi',
                              isDense: true,
                            ),
                            items: _devices
                                .map(
                                  (d) => DropdownMenuItem(
                                    value: d.name,
                                    child: Text(
                                      d.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() {
                                  targetDeviceName = val;
                                  syncTextsFromBuilder();
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          flex: 2,
                          child: DropdownButtonFormField<String>(
                            value: targetAction,
                            dropdownColor: AppColors.getSurface(isDark),
                            style: TextStyle(
                              color: AppColors.getTextPrimary(isDark),
                              fontSize: 12,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Lệnh',
                              isDense: true,
                            ),
                            items: const [
                              DropdownMenuItem(value: 'ON', child: Text('BẬT')),
                              DropdownMenuItem(
                                value: 'OFF',
                                child: Text('TẮT'),
                              ),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() {
                                  targetAction = val;
                                  syncTextsFromBuilder();
                                });
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextField(
                    controller: condCtrl,
                    style: TextStyle(color: AppColors.getTextPrimary(isDark)),
                    decoration: const InputDecoration(
                      labelText: 'Điều kiện kích hoạt (IF)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: actionCtrl,
                    style: TextStyle(color: AppColors.getTextPrimary(isDark)),
                    decoration: const InputDecoration(
                      labelText: 'Hành động thực thi (THEN)',
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
                  foregroundColor: isDark
                      ? const Color(0xFF0A0E1A)
                      : Colors.white,
                ),
                onPressed: () async {
                  if (nameCtrl.text.trim().isEmpty ||
                      condCtrl.text.trim().isEmpty) {
                    return;
                  }
                  Navigator.pop(ctx);
                  try {
                    await _api.createAutomation(
                      nameCtrl.text.trim(),
                      condCtrl.text.trim(),
                      actionCtrl.text.trim(),
                    );
                    _showSnack('Đã lưu kịch bản vào Database');
                    await _loadData();
                  } catch (e) {
                    _showSnack(
                      e.toString().replaceFirst('Exception: ', ''),
                      isError: true,
                    );
                  }
                },
                child: const Text(
                  'LƯU KỊCH BẢN',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;
    final apiService = Provider.of<ApiService>(context);
    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final canEdit = apiService.currentUserRole.toLowerCase() != 'guest';

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              heroTag: 'fab_automation',
              backgroundColor: cyan,
              foregroundColor: isDark ? const Color(0xFF0A0E1A) : Colors.white,
              onPressed: () => _showAddRuleDialog(isDark),
              icon: const Icon(Icons.add),
              label: const Text(
                'THÊM LUẬT',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            )
          : null,
      body: RefreshIndicator(
        color: cyan,
        onRefresh: _loadData,
        child: _isLoading
            ? Center(child: CircularProgressIndicator(color: cyan))
            : _rules.isEmpty
            ? ListView(
                children: const [
                  SizedBox(height: 120),
                  Center(
                    child: Text(
                      'Chưa có kịch bản tự động nào trong Database',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                ],
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                itemCount: _rules.length,
                itemBuilder: (context, index) {
                  final rule = _rules[index];
                  final id = (rule['id'] ?? '').toString();
                  final active = rule['is_active'] != false;
                  final condText =
                      (rule['condition_text'] ??
                              '${rule['condition_type'] ?? ''} ${rule['operator'] ?? ''} ${rule['threshold'] ?? ''}')
                          .toString();
                  final actionText =
                      (rule['action_text'] ??
                              'Hành động: ${rule['action'] ?? 'ON'}')
                          .toString();

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.getSurface(isDark),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: active ? cyan : AppColors.getBorder(isDark),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          color: active ? cyan : AppColors.textMuted,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                rule['name']?.toString() ?? 'Kịch bản',
                                style: TextStyle(
                                  color: AppColors.getTextPrimary(isDark),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'IF $condText',
                                style: const TextStyle(
                                  color: AppColors.secondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (actionText.isNotEmpty)
                                Text(
                                  'THEN $actionText',
                                  style: const TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Switch(
                          value: active,
                          activeColor: cyan,
                          onChanged: canEdit
                              ? (val) async {
                                  setState(() => rule['is_active'] = val);
                                  try {
                                    await _api.toggleAutomation(id, val);
                                  } catch (e) {
                                    setState(() => rule['is_active'] = !val);
                                    _showSnack(
                                      e.toString().replaceFirst(
                                        'Exception: ',
                                        '',
                                      ),
                                      isError: true,
                                    );
                                  }
                                }
                              : null,
                        ),
                        if (canEdit)
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: AppColors.accent,
                              size: 20,
                            ),
                            onPressed: () async {
                              try {
                                await _api.deleteAutomation(id);
                                _loadData();
                              } catch (e) {
                                _showSnack(
                                  e.toString().replaceFirst('Exception: ', ''),
                                  isError: true,
                                );
                              }
                            },
                          ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
