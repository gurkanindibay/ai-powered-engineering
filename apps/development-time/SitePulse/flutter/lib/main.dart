import 'package:flutter/material.dart';
import 'ui/auth/login_screen.dart';
import 'ui/dashboard/dashboard_controller.dart';
import 'ui/dashboard/dashboard_screen.dart';
import 'ui/theme/app_theme.dart';
import 'testing/test_id.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  enableE2ESemantics();
  final controller = DashboardController(startAuthenticated: false);
  runApp(SitePulseApp(controller: controller));
}

class SitePulseApp extends StatelessWidget {
  final DashboardController controller;

  const SitePulseApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return MaterialApp(
          title: 'SitePulse',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: controller.isDarkMode ? ThemeMode.dark : ThemeMode.light,
          home: controller.isAuthenticated
              ? DashboardScreen(controller: controller)
              : LoginScreen(controller: controller),
        );
      },
    );
  }
}

