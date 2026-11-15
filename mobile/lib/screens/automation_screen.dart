import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
  List _rules = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAutomations();
  }

  Future<void> _loadAutomations() async {
    setState(() => _isLoading = true);
    try {
      final list = await _api.getAutomations();
      if (!mounted) return;
      setState(() {
        _rules = list;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnack(e.toString().replaceFirst('Exception: ', ''), isError: true);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppColors.accent : AppColors.secondary,
      ),
    );
  }

  void _showAddRuleDialog(bool isDark) {
    final nameCtrl = TextEditingController();
    final condCtrl = TextEditingController();
    final actionCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.getSurface(isDark),
        title: Text(
          'TẠO KỊCH BẢN TỰ ĐỘNG',
          style: TextStyle(
            color: AppColors.getTextPrimary(isDark),
            fontSize: 15,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              style: TextStyle(color: AppColors.getTextPrimary(isDark)),
              decoration: const InputDecoration(labelText: 'Tên kịch bản'),
            ),
            TextField(
              controller: condCtrl,
              style: TextStyle(color: AppColors.getTextPrimary(isDark)),
              decoration: const InputDecoration(
                labelText: 'Điều kiện kích hoạt',
              ),
            ),
            TextField(
              controller: actionCtrl,
              style: TextStyle(color: AppColors.getTextPrimary(isDark)),
              decoration: const InputDecoration(
                labelText: 'Hành động thực thi',
              ),
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
              backgroundColor: AppColors.primary,
              foregroundColor: const Color(0xFF0A0E1A),
            ),
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty || condCtrl.text.trim().isEmpty)
                return;
              Navigator.pop(ctx);
              try {
                await _api.createAutomation(
                  nameCtrl.text.trim(),
                  condCtrl.text.trim(),
                  actionCtrl.text.trim(),
                );
                _showSnack('Đã lưu kịch bản vào Database');
                _loadAutomations();
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab_automation',
        backgroundColor: AppColors.primary,
        foregroundColor: const Color(0xFF0A0E1A),
        onPressed: () => _showAddRuleDialog(isDark),
        icon: const Icon(Icons.add),
        label: const Text(
          'THÊM LUẬT',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _loadAutomations,
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              )
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
                padding: const EdgeInsets.all(16),
                itemCount: _rules.length,
                itemBuilder: (context, index) {
                  final rule = _rules[index];
                  final id = rule['id'].toString();
                  final active = rule['is_active'] == true;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.getSurface(isDark),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: active
                            ? AppColors.primary
                            : AppColors.getBorder(isDark),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          color: active
                              ? AppColors.primary
                              : AppColors.textMuted,
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
                                rule['condition_text']?.toString() ?? '',
                                style: const TextStyle(
                                  color: AppColors.secondary,
                                  fontSize: 12,
                                ),
                              ),
                              if (rule['action_text'] != null)
                                Text(
                                  rule['action_text'].toString(),
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
                          activeColor: AppColors.primary,
                          onChanged: (val) async {
                            setState(() => rule['is_active'] = val);
                            try {
                              await _api.toggleAutomation(id, val);
                            } catch (e) {
                              setState(() => rule['is_active'] = !val);
                              _showSnack(
                                e.toString().replaceFirst('Exception: ', ''),
                                isError: true,
                              );
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: AppColors.accent,
                            size: 20,
                          ),
                          onPressed: () async {
                            try {
                              await _api.deleteAutomation(id);
                              _loadAutomations();
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
