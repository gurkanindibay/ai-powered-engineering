import 'package:flutter/material.dart';

import '../auth/account_link_screen.dart';
import '../auth/dev_quick_login.dart';
import '../auth/force_password_change_screen.dart';
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
/// * Signed in with a temporary password (any role): only
///   `/change-password` is shown, with no dashboard behind it. A URL opened
///   meanwhile is remembered and applied once the password is changed.
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
  bool _wasPasswordChangeRequired;
  Object? _sessionIdentity;

  AppRouterDelegate(this.controller)
      : _wasAuthenticated = controller.isAuthenticated,
        _wasPasswordChangeRequired = controller.requiresPasswordChange {
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
    final mustChange = controller.requiresPasswordChange;
    final identity = authenticated ? (controller.userRole, controller.siteAdminPath) : null;
    final unlocked = authenticated && !mustChange && (!_wasAuthenticated || _wasPasswordChangeRequired);
    if (unlocked) {
      // Signed in, or just replaced a temporary password: open the remembered link.
      _tab = 0;
      final link = _pendingDeepLink;
      _pendingDeepLink = null;
      if (link != null) _tab = AppRoutes.resolve(controller, link) ?? 0;
    } else if (authenticated && mustChange) {
      _tab = 0;
    } else if (!authenticated && _wasAuthenticated) {
      _tab = 0;
      _pendingDeepLink = null;
    } else if (identity != _sessionIdentity && _sessionIdentity != null) {
      // Role or manager path changed: tabs differ, so start again on Home.
      _tab = 0;
    }
    _wasAuthenticated = authenticated;
    _wasPasswordChangeRequired = mustChange;
    _sessionIdentity = authenticated ? (controller.userRole, controller.siteAdminPath) : null;
    notifyListeners();
  }

  void selectTab(int index) {
    if (_tab == index) return;
    _tab = index;
    notifyListeners();
  }

  @override
  Uri get currentConfiguration =>
      _accountLink ??
      (controller.requiresPasswordChange ? Uri(path: AppRoutes.changePassword) : AppRoutes.pathFor(controller, _tab));

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
      final quickLoginTab = await DevQuickLoginGate.tryHandleQuickLogin(
        uri: configuration,
        controller: controller,
      );
      if (quickLoginTab != null) {
        _tab = quickLoginTab;
        // The handoff fully replaces any earlier deep link, and the rebuild reports
        // the clean tab URL, so credential parameters leave the address bar.
        _pendingDeepLink = null;
        _sessionIdentity = (controller.userRole, controller.siteAdminPath);
        notifyListeners();
        return;
      }

      final isLogin = configuration.path == AppRoutes.login || configuration.path == AppRoutes.quickLogin || configuration.path == AppRoutes.changePassword || configuration.path == '/' || configuration.path.isEmpty;
      _pendingDeepLink = isLogin ? null : configuration;
      notifyListeners();
      return;
    }
    if (controller.requiresPasswordChange) {
      // Nothing opens before the password is changed; keep the link for afterwards.
      if (configuration.path != AppRoutes.changePassword) _pendingDeepLink = configuration;
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
        if (signedIn && controller.requiresPasswordChange)
          MaterialPage<void>(
            // Page identity for the Navigator, not an automation target. testid-lint: ignore
            key: const ValueKey('force-password-change'),
            child: ForcePasswordChangeScreen(controller: controller),
          )
        else if (signedIn)
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
