import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class UserManagementScreen extends StatelessWidget {
  const UserManagementScreen({super.key});

  // Khai báo chính xác List>
  final List<Map<String, dynamic>> users = const [
    {
      'name': 'Admin User',
      'email': 'admin@smarthome.io',
      'role': 'ADMIN',
      'status': 'ACTIVE',
    },
    {
      'name': 'Operator 01',
      'email': 'operator@smarthome.io',
      'role': 'OPERATOR',
      'status': 'ACTIVE',
    },
    {
      'name': 'Guest User',
      'email': 'guest@smarthome.io',
      'role': 'VIEWER',
      'status': 'INACTIVE',
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text(
          'QUẢN LÝ NGƯỜI DÙNG',
          style: TextStyle(color: AppColors.primary, fontSize: 16),
        ),
        iconTheme: const IconThemeData(color: AppColors.primary),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: users.length,
        itemBuilder: (context, index) {
          final user = users[index];
          final isActive = user['status'] == 'ACTIVE';

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: AppColors.glowCyan,
                  child: Text(
                    user['name']![0],
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user['name']!,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        user['email']!,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isActive
                        ? AppColors.glowCyan
                        : Colors.red.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    user['role']!,
                    style: TextStyle(
                      color: isActive ? AppColors.primary : Colors.red,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
