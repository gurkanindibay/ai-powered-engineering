import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'ui/dashboard/dashboard_controller.dart';
import 'ui/navigation/app_router.dart';
import 'ui/theme/app_theme.dart';
import 'testing/test_id.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  enableE2ESemantics();
  final controller = DashboardController(startAuthenticated: false);
  runApp(SitePulseApp(controller: controller));
}

/// Turkish is the default (and today the only) locale.
const kAppLocale = Locale('tr', 'TR');

class SitePulseApp extends StatefulWidget {
  final DashboardController controller;

  const SitePulseApp({super.key, required this.controller});

  @override
  State<SitePulseApp> createState() => _SitePulseAppState();
}

class _SitePulseAppState extends State<SitePulseApp> with WidgetsBindingObserver {
  late final AppRouterDelegate _routerDelegate = AppRouterDelegate(widget.controller);
  final AppRouteParser _routeParser = const AppRouteParser();

  @override
  void initState() {
    super.initState();
    Intl.defaultLocale = 'tr_TR';
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _routerDelegate.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    widget.controller.updatePlatformBrightness(WidgetsBinding.instance.platformDispatcher.platformBrightness);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        return MaterialApp.router(
          title: 'SitePulse',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: widget.controller.isDarkMode ? ThemeMode.dark : ThemeMode.light,
          locale: kAppLocale,
          supportedLocales: const [kAppLocale],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          routerDelegate: _routerDelegate,
          routeInformationParser: _routeParser,
        );
      },
    );
  }
}
