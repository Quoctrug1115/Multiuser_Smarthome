import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/websocket_service.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/user_management_screen.dart';
import 'theme/app_colors.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => WebSocketService())],
      child: const SmartHomeApp(),
    ),
  );
}

class SmartHomeApp extends StatelessWidget {
  const SmartHomeApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartHome Sci-Fi Hub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: AppColors.background,
        fontFamily: 'System',
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const LoginScreen(),
        '/home': (context) => const HomeScreen(),
        '/users': (context) => const UserManagementScreen(),
      },
    );
  }
}
