import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoginMode = true;
  bool _isLoading = false;
  bool _obscurePassword = true;

  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  Future<void> _submitForm() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _showMessage('Vui lòng nhập đầy đủ Email và Mật khẩu!', isError: true);
      return;
    }

    if (!_isLoginMode) {
      if (_nameController.text.trim().isEmpty) {
        _showMessage('Vui lòng nhập Họ và Tên!', isError: true);
        return;
      }
      if (password != _confirmPasswordController.text.trim()) {
        _showMessage('Mật khẩu xác nhận không khớp!', isError: true);
        return;
      }
    }

    setState(() => _isLoading = true);
    final api = ApiService();

    try {
      if (_isLoginMode) {
        await api.login(email, password);
        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/main');
      } else {
        await api.register(_nameController.text.trim(), email, password);
        if (!mounted) return;
        _showMessage('Đăng ký thành công! Vui lòng đăng nhập.');
        setState(() {
          _isLoginMode = true;
          _passwordController.clear();
          _confirmPasswordController.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        _showMessage(
          e.toString().replaceFirst('Exception: ', ''),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showMessage(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppColors.accent : AppColors.secondary,
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.isDarkMode;

    return Scaffold(
      backgroundColor: AppColors.getBackground(isDark),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              isDark ? Icons.light_mode : Icons.dark_mode,
              color: isDark ? Colors.amber : AppColors.secondary,
            ),
            onPressed: () => themeProvider.toggleTheme(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.getSurface(isDark),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.getBorder(isDark)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.getGlowCyan(isDark),
                      border: Border.all(color: AppColors.primary, width: 2),
                    ),
                    child: const Icon(
                      Icons.hub,
                      size: 42,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'NEXUS SMART HOME',
                    style: TextStyle(
                      color: isDark
                          ? AppColors.primary
                          : AppColors.getTextPrimary(isDark),
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _isLoginMode
                        ? 'Xác thực qua máy chủ Rust Backend'
                        : 'Đăng ký tài khoản mới vào Database',
                    style: TextStyle(
                      color: AppColors.getTextSecondary(isDark),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AppColors.getBackground(isDark),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.getBorder(isDark)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _buildModeTab(
                            'ĐĂNG NHẬP',
                            _isLoginMode,
                            isDark,
                            () => setState(() => _isLoginMode = true),
                          ),
                        ),
                        Expanded(
                          child: _buildModeTab(
                            'ĐĂNG KÝ',
                            !_isLoginMode,
                            isDark,
                            () => setState(() => _isLoginMode = false),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (!_isLoginMode) ...[
                    _buildTextField(
                      controller: _nameController,
                      label: 'HỌ VÀ TÊN',
                      icon: Icons.badge_outlined,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 14),
                  ],
                  _buildTextField(
                    controller: _emailController,
                    label: 'EMAIL ĐĂNG NHẬP',
                    icon: Icons.email_outlined,
                    isDark: isDark,
                  ),
                  const SizedBox(height: 14),
                  _buildTextField(
                    controller: _passwordController,
                    label: 'MẬT KHẨU',
                    icon: Icons.lock_outline,
                    isDark: isDark,
                    obscureText: _obscurePassword,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                        color: AppColors.textMuted,
                        size: 18,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  if (!_isLoginMode) ...[
                    const SizedBox(height: 14),
                    _buildTextField(
                      controller: _confirmPasswordController,
                      label: 'XÁC NHẬN MẬT KHẨU',
                      icon: Icons.lock_reset,
                      isDark: isDark,
                      obscureText: _obscurePassword,
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _submitForm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: const Color(0xFF0A0E1A),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Color(0xFF0A0E1A),
                              ),
                            )
                          : Text(
                              _isLoginMode
                                  ? 'TRUY CẬP HỆ THỐNG'
                                  : 'TẠO TÀI KHOẢN',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeTab(
    String title,
    bool active,
    bool isDark,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          title,
          style: TextStyle(
            color: active
                ? const Color(0xFF0A0E1A)
                : AppColors.getTextSecondary(isDark),
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required bool isDark,
    bool obscureText = false,
    Widget? suffixIcon,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      style: TextStyle(color: AppColors.getTextPrimary(isDark), fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: AppColors.getTextSecondary(isDark),
          fontSize: 11,
        ),
        prefixIcon: Icon(icon, color: AppColors.primary, size: 20),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: AppColors.getBackground(isDark),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.getBorder(isDark)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
    );
  }
}
