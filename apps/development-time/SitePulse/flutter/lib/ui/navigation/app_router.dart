import 'package:flutter/material.dart';

import '../auth/account_link_screen.dart';
import '../auth/login_screen.dart';
import '../dashboard/dashboard_controller.dart';
import '../dashboard/dashboard_screen.dart';
import 'app_routes.dart';

/// Parses browser URLs into [Uri]s and back (no transformation needed).
class AppRouteParser extends RouteInformationParser<Uri> {
  const AppRouteParser();

  @override
  Future<Uri> parseRouteInformation(RouteInformation routeInformation) async => routeInformation.uri;

  @override
  RouteInformation restoreRouteInformation(Uri configuration) => RouteInformation(uri: configuration);
}

/// Owns the current tab and keeps it in sync with the URL.
///
/// * Signed out: always `/login`. A deep link opened while signed out is
///   remembered and applied right after login.
/// * Signed in: the URL names the role path and tab (see [AppRoutes]); a URL
///   that belongs to another role falls back to that user's home tab.
class AppRouterDelegate extends RouterDelegate<Uri> with ChangeNotifier, PopNavigatorRouterDelegateMixin<Uri> {
  final DashboardController controller;

  @override
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  int _tab = 0;
  Uri? _pendingDeepLink;
  /// An activation or email-confirmation link being handled; shown above everything else.
  Uri? _accountLink;

  // Page identity for the Navigator, not an automation target. testid-lint: ignore
  static const _accountLinkPageKey = ValueKey('account-link');
  bool _wasAuthenticated;
  Object? _sessionIdentity;

  AppRouterDelegate(this.controller) : _wasAuthenticated = controller.isAuthenticated {
    controller.addListener(_onControllerChanged);
  }

  int get tab => _tab;

  @override
  void dispose() {
    controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final authenticated = controller.isAuthenticated;
    final identity = authenticated ? (controller.userRole, controller.siteAdminPath) : null;
    if (authenticated && !_wasAuthenticated) {
      _tab = 0;
      final link = _pendingDeepLink;
      _pendingDeepLink = null;
      if (link != null) _tab = AppRoutes.resolve(controller, link) ?? 0;
    } else if (!authenticated && _wasAuthenticated) {
      _tab = 0;
    } else if (identity != _sessionIdentity && _sessionIdentity != null) {
      // Role or manager path changed: tabs differ, so start again on Home.
      _tab = 0;
    }
    _wasAuthenticated = authenticated;
    _sessionIdentity = authenticated ? (controller.userRole, controller.siteAdminPath) : null;
    notifyListeners();
  }

  void selectTab(int index) {
    if (_tab == index) return;
    _tab = index;
    notifyListeners();
  }

  @override
  Uri get currentConfiguration => _accountLink ?? AppRoutes.pathFor(controller, _tab);

  void _closeAccountLink() {
    _accountLink = null;
    notifyListeners();
  }

  @override
  Future<void> setNewRoutePath(Uri configuration) async {
    if (configuration.path == AppRoutes.activate || configuration.path == AppRoutes.confirmEmail) {
      _accountLink = configuration;
      notifyListeners();
      return;
    }
    if (!controller.isAuthenticated) {
      final isLogin = configuration.path == AppRoutes.login || configuration.path == '/' || configuration.path.isEmpty;
      _pendingDeepLink = isLogin ? null : configuration;
      notifyListeners();
      return;
    }
    _tab = AppRoutes.resolve(controller, configuration) ?? 0;
    _sessionIdentity = (controller.userRole, controller.siteAdminPath);
    notifyListeners();
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = controller.isAuthenticated;
    return Navigator(
      key: navigatorKey,
      pages: [
        if (signedIn)
          MaterialPage<void>(
            // Page identity for the Navigator, not an automation target. testid-lint: ignore
            key: const ValueKey('dashboard'),
            child: DashboardScreen(
              controller: controller,
              selectedTab: _tab,
              onTabSelected: selectTab,
            ),
          )
        else
          MaterialPage<void>(
            // Page identity for the Navigator, not an automation target. testid-lint: ignore
            key: const ValueKey('login'),
            child: LoginScreen(controller: controller),
          ),
        if (_accountLink != null)
          MaterialPage<void>(
            key: _accountLinkPageKey,
            child: AccountLinkScreen(
              kind: _accountLink!.path == AppRoutes.activate ? AccountLinkKind.activate : AccountLinkKind.confirmEmail,
              token: _accountLink!.queryParameters['token'] ?? '',
              onDone: _closeAccountLink,
            ),
          ),
      ],
      onDidRemovePage: (page) {
        if (page.key == _accountLinkPageKey) _closeAccountLink();
      },
    );
  }
}
