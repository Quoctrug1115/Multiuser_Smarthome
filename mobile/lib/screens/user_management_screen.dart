import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';

class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  final ApiService _api = ApiService();
  final _searchController = TextEditingController();
  String _selectedRoleFilter = 'TẤT CẢ';
  bool _isLoading = true;
  JsonList _users = [];

  @override
  void initState() {
    super.initState();
    if (_api.isAdmin) {
      _loadUsers();
    }
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

  String _normalizeRole(dynamic rawRole) {
    final r = (rawRole ?? '').toString().trim().toLowerCase();
    if (r == 'owner' || r == 'admin' || r.startsWith('e8a4742f')) {
      return 'Owner';
    }
    if (r == 'guest' || r.startsWith('c645ad8a')) {
      return 'Guest';
    }
    return 'Member';
  }

  JsonList get _filteredUsers {
    final query = _searchController.text.trim().toLowerCase();
    return _users.where((user) {
      final role = _normalizeRole(
        user['role'] ?? user['role_name'] ?? user['role_id'],
      ).toUpperCase();
      final name = (user['full_name'] ?? user['name'] ?? user['username'] ?? '')
          .toString()
          .toLowerCase();
      final email = (user['email'] ?? '').toString().toLowerCase();
      final matchesRole =
          _selectedRoleFilter == 'TẤT CẢ' || role == _selectedRoleFilter;
      final matchesQuery =
          query.isEmpty || name.contains(query) || email.contains(query);
      return matchesRole && matchesQuery;
    }).toList();
  }

  Color _getRoleColor(String role) {
    switch (role.toLowerCase()) {
      case 'owner':
      case 'admin':
        return AppColors.primary;
      case 'guest':
        return Colors.amber;
      default:
        return Colors.tealAccent;
    }
  }

  void _showSnack(String message, {bool isError = false}) {
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

  void _showUserFormDialog(bool isDark, {JsonMap? existingUser}) {
    final isEdit = existingUser != null;
    final nameCtrl = TextEditingController(
      text:
          existingUser?['full_name']?.toString() ??
          existingUser?['name']?.toString() ??
          existingUser?['username']?.toString() ??
          '',
    );
    final emailCtrl = TextEditingController(
      text: existingUser?['email']?.toString() ?? '',
    );
    final passwordCtrl = TextEditingController();
    String selectedRole = _normalizeRole(
      existingUser?['role'] ??
          existingUser?['role_name'] ??
          existingUser?['role_id'],
    );
    int guestHours = 24;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: AppColors.getSurface(isDark),
            title: Text(
              isEdit ? 'CẬP NHẬT TÀI KHOẢN' : 'THÊM TÀI KHOẢN VÀO DATABASE',
              style: TextStyle(
                color: isDark
                    ? AppColors.primary
                    : AppColors.getTextPrimary(isDark),
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    style: TextStyle(
                      color: AppColors.getTextPrimary(isDark),
                      fontSize: 13,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Họ và tên',
                      prefixIcon: Icon(
                        Icons.person_outline,
                        color: AppColors.primary,
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: emailCtrl,
                    enabled: !isEdit,
                    style: TextStyle(
                      color: AppColors.getTextPrimary(isDark),
                      fontSize: 13,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Email đăng nhập',
                      prefixIcon: Icon(
                        Icons.email_outlined,
                        color: AppColors.primary,
                        size: 18,
                      ),
                    ),
                  ),
                  if (!isEdit) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: passwordCtrl,
                      obscureText: true,
                      style: TextStyle(
                        color: AppColors.getTextPrimary(isDark),
                        fontSize: 13,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Mật khẩu',
                        prefixIcon: Icon(
                          Icons.lock_outline,
                          color: AppColors.primary,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    value: selectedRole,
                    dropdownColor: AppColors.getSurface(isDark),
                    style: TextStyle(
                      color: AppColors.getTextPrimary(isDark),
                      fontSize: 13,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Vai trò phân quyền',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'Owner',
                        child: Text('Owner (Chủ nhà - Toàn quyền)'),
                      ),
                      DropdownMenuItem(
                        value: 'Member',
                        child: Text('Member (Thành viên gia đình)'),
                      ),
                      DropdownMenuItem(
                        value: 'Guest',
                        child: Text('Guest (Khách hạn chế)'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) setDialogState(() => selectedRole = val);
                    },
                  ),
                  if (!isEdit && selectedRole == 'Guest') ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      value: guestHours,
                      dropdownColor: AppColors.getSurface(isDark),
                      style: TextStyle(
                        color: AppColors.getTextPrimary(isDark),
                        fontSize: 13,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Thời hạn truy cập khách',
                      ),
                      items: const [
                        DropdownMenuItem(value: 2, child: Text('2 giờ')),
                        DropdownMenuItem(value: 24, child: Text('24 giờ')),
                        DropdownMenuItem(value: 168, child: Text('7 ngày')),
                        DropdownMenuItem(value: 720, child: Text('30 ngày')),
                      ],
                      onChanged: (val) {
                        if (val != null) setDialogState(() => guestHours = val);
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
                  backgroundColor: AppColors.primary,
                  foregroundColor: const Color(0xFF0A0E1A),
                ),
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  final email = emailCtrl.text.trim();
                  final pass = passwordCtrl.text.trim();
                  if (name.isEmpty ||
                      email.isEmpty ||
                      (!isEdit && pass.isEmpty)) {
                    _showSnack(
                      'Vui lòng điền đầy đủ thông tin!',
                      isError: true,
                    );
                    return;
                  }
                  Navigator.pop(ctx);
                  try {
                    if (isEdit) {
                      await _api.updateUser(
                        existingUser['id'].toString(),
                        fullName: name,
                        role: selectedRole,
                      );
                      _showSnack('Đã cập nhật tài khoản');
                    } else if (selectedRole == 'Guest') {
                      await _api.createGuest(
                        fullName: name,
                        email: email,
                        password: pass,
                        durationHours: guestHours,
                      );
                      _showSnack('Đã cấp tài khoản Khách');
                    } else {
                      await _api.createUser(
                        fullName: name,
                        email: email,
                        password: pass,
                        role: selectedRole,
                      );
                      _showSnack('Đã tạo tài khoản thành viên');
                    }
                    _loadUsers();
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

  void _showResetPasswordDialog(JsonMap user, bool isDark) {
    final newPassCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.getSurface(isDark),
        title: Text(
          'ĐẶT LẠI MẬT KHẨU',
          style: TextStyle(
            color: AppColors.getTextPrimary(isDark),
            fontSize: 15,
          ),
        ),
        content: TextField(
          controller: newPassCtrl,
          obscureText: true,
          style: TextStyle(color: AppColors.getTextPrimary(isDark)),
          decoration: const InputDecoration(
            labelText: 'Mật khẩu mới (tối thiểu 6 ký tự)',
          ),
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
              if (newPassCtrl.text.trim().length < 6) {
                _showSnack('Mật khẩu phải từ 6 ký tự trở lên!', isError: true);
                return;
              }
              Navigator.pop(ctx);
              try {
                await _api.updateUser(
                  user['id'].toString(),
                  password: newPassCtrl.text.trim(),
                );
                _showSnack('Đã cập nhật mật khẩu mới');
              } catch (e) {
                _showSnack(
                  e.toString().replaceFirst('Exception: ', ''),
                  isError: true,
                );
              }
            },
            child: const Text(
              'XÁC NHẬN',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;
    final apiService = Provider.of<ApiService>(context);

    if (!apiService.isAdmin) {
      return Scaffold(
        backgroundColor: AppColors.getBackground(isDark),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_person, color: AppColors.accent, size: 48),
              SizedBox(height: 12),
              Text(
                'KHÔNG CÓ QUYỀN TRUY CẬP',
                style: TextStyle(
                  color: AppColors.accent,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'Chỉ tài khoản Chủ nhà (Owner) mới được phép quản lý người dùng.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final activeCount = _users.where((u) => u['is_active'] != false).length;
    final guestCount = _users
        .where(
          (u) =>
              _normalizeRole(u['role'] ?? u['role_name'] ?? u['role_id']) ==
              'Guest',
        )
        .length;
    final filteredList = _filteredUsers;
    final currentEmail = (apiService.currentUser?['email'] ?? '')
        .toString()
        .toLowerCase();

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab_user_management',
        backgroundColor: AppColors.primary,
        foregroundColor: const Color(0xFF0A0E1A),
        onPressed: () => _showUserFormDialog(isDark),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text(
          'THÊM TÀI KHOẢN',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: _buildStatCard(
                    'TỔNG TÀI KHOẢN',
                    '${_users.length}',
                    AppColors.primary,
                    isDark,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatCard(
                    'HOẠT ĐỘNG',
                    '$activeCount',
                    Colors.greenAccent,
                    isDark,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatCard(
                    'KHÁCH',
                    '$guestCount',
                    Colors.amber,
                    isDark,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              style: TextStyle(
                color: AppColors.getTextPrimary(isDark),
                fontSize: 13,
              ),
              decoration: InputDecoration(
                hintText: 'Tìm kiếm theo tên hoặc email...',
                hintStyle: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
                prefixIcon: const Icon(
                  Icons.search,
                  color: AppColors.primary,
                  size: 20,
                ),
                filled: true,
                fillColor: AppColors.getSurface(isDark),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: ['TẤT CẢ', 'OWNER', 'MEMBER', 'GUEST'].map((role) {
                final isSelected = _selectedRoleFilter == role;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(
                      role,
                      style: TextStyle(
                        color: isSelected
                            ? const Color(0xFF0A0E1A)
                            : AppColors.getTextSecondary(isDark),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    selected: isSelected,
                    selectedColor: AppColors.primary,
                    backgroundColor: AppColors.getSurface(isDark),
                    onSelected: (_) =>
                        setState(() => _selectedRoleFilter = role),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: RefreshIndicator(
              color: AppColors.primary,
              onRefresh: _loadUsers,
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
                  : filteredList.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 100),
                        Center(
                          child: Text(
                            'Không có tài khoản nào phù hợp',
                            style: TextStyle(color: AppColors.textMuted),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
                      itemCount: filteredList.length,
                      itemBuilder: (context, index) {
                        final user = filteredList[index];
                        final id = user['id'].toString();
                        final name =
                            (user['full_name'] ??
                                    user['name'] ??
                                    user['username'] ??
                                    'User')
                                .toString();
                        final email = (user['email'] ?? '').toString();
                        final isSelf = email.toLowerCase() == currentEmail;
                        final roleValue = isSelf && apiService.isAdmin
                            ? 'Owner'
                            : _normalizeRole(
                                user['role'] ??
                                    user['role_name'] ??
                                    user['role_id'],
                              );
                        final roleDisplay = roleValue.toUpperCase();
                        final isActive = user['is_active'] != false;
                        final roleColor = _getRoleColor(roleValue);

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.getSurface(isDark),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: AppColors.getBorder(isDark),
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: roleColor.withOpacity(
                                      0.18,
                                    ),
                                    child: Text(
                                      name.isNotEmpty
                                          ? name[0].toUpperCase()
                                          : '?',
                                      style: TextStyle(
                                        color: roleColor,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                name,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color:
                                                      AppColors.getTextPrimary(
                                                        isDark,
                                                      ),
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: roleColor.withOpacity(
                                                  0.15,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                roleDisplay,
                                                style: TextStyle(
                                                  color: roleColor,
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        Text(
                                          email,
                                          style: const TextStyle(
                                            color: AppColors.textMuted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuButton<String>(
                                    icon: Icon(
                                      Icons.more_vert,
                                      color: AppColors.getTextSecondary(isDark),
                                    ),
                                    color: AppColors.getSurface(isDark),
                                    onSelected: (action) async {
                                      if (action == 'edit') {
                                        _showUserFormDialog(
                                          isDark,
                                          existingUser: user,
                                        );
                                      } else if (action == 'reset_pass') {
                                        _showResetPasswordDialog(user, isDark);
                                      } else if (action == 'delete') {
                                        if (isSelf) {
                                          _showSnack(
                                            'Không thể tự xóa tài khoản đang đăng nhập!',
                                            isError: true,
                                          );
                                          return;
                                        }
                                        try {
                                          await _api.deleteUser(id);
                                          _showSnack('Đã xóa tài khoản $name');
                                          _loadUsers();
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
                                    itemBuilder: (context) => [
                                      const PopupMenuItem(
                                        value: 'edit',
                                        child: Text('Sửa & Phân quyền'),
                                      ),
                                      const PopupMenuItem(
                                        value: 'reset_pass',
                                        child: Text('Đặt lại mật khẩu'),
                                      ),
                                      if (!isSelf)
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text(
                                            'Xóa tài khoản',
                                            style: TextStyle(
                                              color: AppColors.accent,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                              Divider(
                                height: 16,
                                color: AppColors.getBorder(isDark),
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'ID: $id',
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 10,
                                    ),
                                  ),
                                  Row(
                                    children: [
                                      Text(
                                        isActive ? 'HOẠT ĐỘNG' : 'ĐÃ KHÓA',
                                        style: TextStyle(
                                          color: isActive
                                              ? Colors.greenAccent
                                              : AppColors.accent,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      SizedBox(
                                        height: 24,
                                        child: Switch(
                                          value: isActive,
                                          activeColor: AppColors.primary,
                                          onChanged: isSelf
                                              ? null
                                              : (val) async {
                                                  setState(
                                                    () =>
                                                        user['is_active'] = val,
                                                  );
                                                  try {
                                                    await _api.updateUser(
                                                      id,
                                                      isActive: val,
                                                    );
                                                  } catch (e) {
                                                    setState(
                                                      () => user['is_active'] =
                                                          !val,
                                                    );
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
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String label, String value, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.getSurface(isDark),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.getBorder(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
