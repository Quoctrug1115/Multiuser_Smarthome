import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';
import '../widgets/users/user_excel_sheet.dart';

class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  final ApiService _api = ApiService();
  JsonList _users = [];
  bool _isLoading = true;
  String _selectedRoleFilter = 'TẤT CẢ';

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    try {
      final list = await _api.getUsers();
      if (!mounted) return;
      setState(() {
        _users = list;
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

  String _normalizeRole(dynamic raw) {
    final r = (raw ?? 'Member').toString().trim().toLowerCase();
    switch (r) {
      case 'owner':
        return 'Owner';
      case 'admin':
        return 'Admin';
      case 'guest':
        return 'Guest';
      default:
        return 'Member';
    }
  }

  Color _roleColor(String role, bool isDark) {
    switch (role.toLowerCase()) {
      case 'owner':
        return isDark ? Colors.amber : const Color(0xFFD97706);
      case 'admin':
        return isDark ? AppColors.primary : const Color(0xFF0284C7);
      case 'guest':
        return AppColors.secondary;
      default:
        return isDark ? Colors.greenAccent : const Color(0xFF0D9488);
    }
  }

  JsonList get _filteredUsers {
    if (_selectedRoleFilter == 'TẤT CẢ') return _users;
    return _users.where((u) {
      final role = _normalizeRole(u['role'] ?? u['role_name']);
      return role.toLowerCase() == _selectedRoleFilter.toLowerCase();
    }).toList();
  }

  void _showCreateAccountDialog(bool isDark) {
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    String selectedRole = 'Member';
    int durationHours = 24;

    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final isCurrentOwner = _api.currentUserRole.toLowerCase() == 'owner';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final isGuest = selectedRole == 'Guest';
          return AlertDialog(
            backgroundColor: AppColors.getSurface(isDark),
            title: Text(
              isGuest ? 'CẤP QUYỀN KHÁCH TẠM THỜI' : 'THÊM THÀNH VIÊN MỚI',
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
                  DropdownButtonFormField<String>(
                    value: selectedRole,
                    dropdownColor: AppColors.getSurface(isDark),
                    style: TextStyle(
                      color: AppColors.getTextPrimary(isDark),
                      fontSize: 13,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Vai trò (RBAC)',
                    ),
                    items: [
                      if (isCurrentOwner)
                        const DropdownMenuItem(
                          value: 'Owner',
                          child: Text('Owner (Chủ hộ toàn quyền)'),
                        ),
                      const DropdownMenuItem(
                        value: 'Admin',
                        child: Text('Admin (Quản trị viên)'),
                      ),
                      const DropdownMenuItem(
                        value: 'Member',
                        child: Text('Member (Thành viên gia đình)'),
                      ),
                      const DropdownMenuItem(
                        value: 'Guest',
                        child: Text('Guest (Khách truy cập có thời hạn)'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => selectedRole = val);
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameCtrl,
                    style: TextStyle(color: AppColors.getTextPrimary(isDark)),
                    decoration: const InputDecoration(labelText: 'Họ và tên'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    style: TextStyle(color: AppColors.getTextPrimary(isDark)),
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    style: TextStyle(color: AppColors.getTextPrimary(isDark)),
                    decoration: const InputDecoration(labelText: 'Mật khẩu'),
                  ),
                  if (isGuest) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      value: durationHours,
                      dropdownColor: AppColors.getSurface(isDark),
                      style: TextStyle(
                        color: AppColors.getTextPrimary(isDark),
                        fontSize: 13,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Thời hạn hiệu lực (Guest)',
                      ),
                      items: const [
                        DropdownMenuItem(value: 2, child: Text('2 giờ')),
                        DropdownMenuItem(value: 6, child: Text('6 giờ')),
                        DropdownMenuItem(value: 12, child: Text('12 giờ')),
                        DropdownMenuItem(
                          value: 24,
                          child: Text('24 giờ (1 ngày)'),
                        ),
                        DropdownMenuItem(
                          value: 72,
                          child: Text('72 giờ (3 ngày)'),
                        ),
                        DropdownMenuItem(
                          value: 168,
                          child: Text('168 giờ (7 ngày)'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() => durationHours = val);
                        }
                      },
                    ),
                  ],
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
                  final name = nameCtrl.text.trim();
                  final email = emailCtrl.text.trim();
                  final pass = passCtrl.text.trim();
                  if (name.isEmpty || email.isEmpty || pass.isEmpty) {
                    _showSnack(
                      'Vui lòng nhập đầy đủ họ tên, email và mật khẩu!',
                      isError: true,
                    );
                    return;
                  }
                  Navigator.pop(ctx);
                  try {
                    if (isGuest) {
                      await _api.createGuest(
                        fullName: name,
                        email: email,
                        password: pass,
                        durationHours: durationHours,
                      );
                      _showSnack('Đã cấp tài khoản Khách ($durationHours giờ)');
                    } else {
                      await _api.createUser(
                        fullName: name,
                        email: email,
                        password: pass,
                        role: selectedRole,
                      );
                      _showSnack('Đã thêm thành viên $selectedRole');
                    }
                    await _loadUsers();
                  } catch (e) {
                    _showSnack(
                      e.toString().replaceFirst('Exception: ', ''),
                      isError: true,
                    );
                  }
                },
                child: const Text(
                  'TẠO TÀI KHOẢN',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showEditUserDialog(JsonMap user, bool isDark) {
    final id = (user['id'] ?? '').toString();
    final nameCtrl = TextEditingController(
      text: (user['full_name'] ?? user['name'] ?? '').toString(),
    );
    final passCtrl = TextEditingController();
    String selectedRole = _normalizeRole(user['role'] ?? user['role_name']);
    bool isActive = user['is_active'] != false;

    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final isCurrentOwner = _api.currentUserRole.toLowerCase() == 'owner';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: AppColors.getSurface(isDark),
            title: Text(
              'CHỈNH SỬA PHÂN QUYỀN',
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
                    style: TextStyle(color: AppColors.getTextPrimary(isDark)),
                    decoration: const InputDecoration(labelText: 'Họ và tên'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: selectedRole,
                    dropdownColor: AppColors.getSurface(isDark),
                    style: TextStyle(
                      color: AppColors.getTextPrimary(isDark),
                      fontSize: 13,
                    ),
                    decoration: const InputDecoration(labelText: 'Vai trò'),
                    items: [
                      if (isCurrentOwner || selectedRole == 'Owner')
                        const DropdownMenuItem(
                          value: 'Owner',
                          child: Text('Owner'),
                        ),
                      const DropdownMenuItem(
                        value: 'Admin',
                        child: Text('Admin'),
                      ),
                      const DropdownMenuItem(
                        value: 'Member',
                        child: Text('Member'),
                      ),
                      const DropdownMenuItem(
                        value: 'Guest',
                        child: Text('Guest'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => selectedRole = val);
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    style: TextStyle(color: AppColors.getTextPrimary(isDark)),
                    decoration: const InputDecoration(
                      labelText: 'Mật khẩu mới (để trống nếu giữ nguyên)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Trạng thái kích hoạt',
                      style: TextStyle(
                        color: AppColors.getTextPrimary(isDark),
                        fontSize: 13,
                      ),
                    ),
                    value: isActive,
                    activeColor: cyan,
                    onChanged: (val) => setDialogState(() => isActive = val),
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
                  Navigator.pop(ctx);
                  try {
                    await _api.updateUser(
                      id,
                      fullName: nameCtrl.text.trim(),
                      role: selectedRole,
                      isActive: isActive,
                      password: passCtrl.text.trim().isEmpty
                          ? null
                          : passCtrl.text.trim(),
                    );
                    _showSnack('Đã cập nhật thông tin thành viên');
                    await _loadUsers();
                  } catch (e) {
                    _showSnack(
                      e.toString().replaceFirst('Exception: ', ''),
                      isError: true,
                    );
                  }
                },
                child: const Text(
                  'LƯU',
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
    final cyan = isDark ? AppColors.primary : const Color(0xFF0284C7);
    final green = isDark ? Colors.greenAccent : const Color(0xFF0D9488);
    final amber = isDark ? Colors.amber : const Color(0xFFD97706);

    final currentUserId = (_api.currentUser?['id'] ?? '').toString();
    final isCurrentOwner = _api.currentUserRole.toLowerCase() == 'owner';
    final list = _filteredUsers;

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab_add_user',
        backgroundColor: cyan,
        foregroundColor: isDark ? const Color(0xFF0A0E1A) : Colors.white,
        onPressed: () => _showCreateAccountDialog(isDark),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text(
          'THÊM TÀI KHOẢN',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
        ),
      ),
      body: RefreshIndicator(
        color: cyan,
        onRefresh: _loadUsers,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 95),
          children: [
            // Thanh công cụ Owner: Nhập / Xuất Excel tài khoản
            if (isCurrentOwner) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.getSurface(isDark),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: amber.withOpacity(0.45)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.admin_panel_settings,
                          color: amber,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'QUYỀN CHỦ NHÀ (${_users.length} TÀI KHOẢN)',
                          style: TextStyle(
                            color: AppColors.getTextPrimary(isDark),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => showUserExcelSheet(
                        context: context,
                        isDark: isDark,
                        api: _api,
                        existingUsers: _users,
                        onSnack: _showSnack,
                        onRefresh: _loadUsers,
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: green.withOpacity(0.16),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: green.withOpacity(0.5)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.table_view, size: 14, color: green),
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
              ),
              const SizedBox(height: 12),
            ],

            // Bộ lọc theo 4 vai trò RBAC
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: ['TẤT CẢ', 'Owner', 'Admin', 'Member', 'Guest'].map((
                  role,
                ) {
                  final selected = _selectedRoleFilter == role;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => setState(() => _selectedRoleFilter = role),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? cyan.withOpacity(0.2)
                              : AppColors.getSurface(isDark),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: selected
                                ? cyan
                                : (isDark ? Colors.white12 : Colors.black12),
                          ),
                        ),
                        child: Text(
                          role,
                          style: TextStyle(
                            color: selected
                                ? cyan
                                : AppColors.getTextSecondary(isDark),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 14),

            if (_isLoading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator(color: cyan)),
              )
            else if (list.isEmpty)
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppColors.getSurface(isDark),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.getBorder(isDark)),
                ),
                child: const Text(
                  'Không có tài khoản nào thuộc nhóm vai trò này.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
              )
            else
              ...list.map((u) {
                final id = (u['id'] ?? '').toString();
                final name = (u['full_name'] ?? u['name'] ?? 'Thành viên')
                    .toString();
                final email = (u['email'] ?? '').toString();
                final role = _normalizeRole(u['role'] ?? u['role_name']);
                final isActive = u['is_active'] != false;
                final expiresAt =
                    (u['expires_at'] ?? u['guest_expires_at'] ?? '').toString();
                final rColor = _roleColor(role, isDark);
                final isSelf = id.isNotEmpty && id == currentUserId;

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.getSurface(isDark),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isActive
                          ? rColor.withOpacity(0.35)
                          : AppColors.accent.withOpacity(0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: rColor.withOpacity(0.18),
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : 'U',
                          style: TextStyle(
                            color: rColor,
                            fontWeight: FontWeight.bold,
                          ),
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
                                    isSelf ? '$name (Bạn)' : name,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: AppColors.getTextPrimary(isDark),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: rColor.withOpacity(0.16),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    role.toUpperCase(),
                                    style: TextStyle(
                                      color: rColor,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              email,
                              style: const TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 11,
                              ),
                            ),
                            if (!isActive)
                              const Text(
                                'ĐÃ VÔ HIỆU HÓA',
                                style: TextStyle(
                                  color: AppColors.accent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            else if (role == 'Guest' && expiresAt.isNotEmpty)
                              Text(
                                'Hết hạn: $expiresAt',
                                style: TextStyle(color: rColor, fontSize: 10),
                              ),
                          ],
                        ),
                      ),
                      if (!isSelf) ...[
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 19),
                          color: AppColors.getTextSecondary(isDark),
                          onPressed: () => _showEditUserDialog(u, isDark),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            size: 19,
                            color: AppColors.accent,
                          ),
                          onPressed: () async {
                            try {
                              await _api.deleteUser(id);
                              _showSnack('Đã xóa tài khoản $name');
                              await _loadUsers();
                            } catch (e) {
                              _showSnack(
                                e.toString().replaceFirst('Exception: ', ''),
                                isError: true,
                              );
                            }
                          },
                        ),
                      ],
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
