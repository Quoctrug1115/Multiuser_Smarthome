import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/api_service.dart';
import 'services/websocket_service.dart';
import 'theme/theme_provider.dart';
import 'screens/login_screen.dart';
import 'screens/main_tab_screen.dart';
import 'screens/user_management_screen.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ApiService()),
        ChangeNotifierProvider(create: (_) => WebSocketService()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const SmartHomeApp(),
    ),
  );
}

class SmartHomeApp extends StatefulWidget {
  const SmartHomeApp({super.key});

  @override
  State<SmartHomeApp> createState() => _SmartHomeAppState();
}

class _SmartHomeAppState extends State<SmartHomeApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final api = ApiService();
    final ws = WebSocketService();
    if (!api.isAuthenticated) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      ws.disconnect(temporary: true);
    } else if (state == AppLifecycleState.resumed) {
      ws.connect(api.wsUrl);
      api.fetchCurrentUser().catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return MaterialApp(
      title: 'SmartHome Sci-Fi Hub',
      debugShowCheckedModeBanner: false,
      themeMode: themeProvider.themeMode,
      theme: ThemeData.light().copyWith(
        scaffoldBackgroundColor: const Color(0xFFF0F4F9),
        primaryColor: const Color(0xFF00F0FF),
      ),
      darkTheme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        primaryColor: const Color(0xFF00F0FF),
      ),
      initialRoute: '/login',
      routes: {
        '/login': (context) => const LoginScreen(),
        '/main': (context) => const MainTabScreen(),
        '/users': (context) => const UserManagementScreen(),
      },
    );
  }
}
