import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    HardwareKeyboard.instance.addHandler(_handleEscape);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleEscape);
    WidgetsBinding.instance.removeObserver(this);
    _routerDelegate.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    widget.controller.updatePlatformBrightness(WidgetsBinding.instance.platformDispatcher.platformBrightness);
  }

  /// Escape closes the top full-screen page, as it closed the dialogs those
  /// pages replaced (Papara-style UX). Dialogs, sheets and menus (popup routes)
  /// keep their own Escape handling, and the router's own pages (login,
  /// dashboard) are never popped. A page route's built-in dismiss action is
  /// disabled (not barrier-dismissible), so this is handled at keyboard level.
  bool _handleEscape(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) return false;
    final navigator = _routerDelegate.navigatorKey.currentState;
    if (navigator == null || !navigator.canPop()) return false;
    Route<dynamic>? top;
    navigator.popUntil((route) {
      top = route;
      return true; // inspect only: stops at the top route without popping it
    });
    final route = top;
    if (route == null || route is PopupRoute || route.settings is Page) return false;
    navigator.maybePop();
    return true;
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
