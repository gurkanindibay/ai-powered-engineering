import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/ui/auth/dev_quick_login.dart';
import 'package:sitepulse/ui/auth/login_screen.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/dashboard/dashboard_screen.dart';
import 'package:sitepulse/ui/navigation/app_router.dart';
import 'package:sitepulse/ui/navigation/app_routes.dart';

void main() {
  setUp(() {
    DevQuickLoginGate.debugEnabledOverride = null;
    DevQuickLoginGate.debugProductionOverride = null;
  });

  tearDown(() {
    DevQuickLoginGate.debugEnabledOverride = null;
    DevQuickLoginGate.debugProductionOverride = null;
  });

  group('DevQuickLoginGate production enforcement', () {
    test('no override can enable the handoff in a production build', () async {
      DevQuickLoginGate.debugProductionOverride = true;
      DevQuickLoginGate.debugEnabledOverride = true;

      expect(DevQuickLoginGate.isProduction, isTrue);
      expect(DevQuickLoginGate.isEnabled, isFalse);
      expect(DevQuickLoginGate.allowed, isFalse);

      final controller = DashboardController(startAuthenticated: false);
      final result = await DevQuickLoginGate.tryHandleQuickLogin(
        uri: Uri.parse('/#/quick-login?email=yonetici@begonya.com&password=Password123'),
        controller: controller,
      );

      expect(result, isNull);
      expect(controller.isAuthenticated, isFalse);
    });

    test('strictly disabled when production flag is simulated', () async {
      DevQuickLoginGate.debugEnabledOverride = false;
      expect(DevQuickLoginGate.allowed, isFalse);

      final controller = DashboardController(startAuthenticated: false);
      final uri = Uri.parse('/?quick_login=true&email=yonetici@begonya.com&password=Password123');

      final result = await DevQuickLoginGate.tryHandleQuickLogin(
        uri: uri,
        controller: controller,
      );

      expect(result, isNull);
      expect(controller.isAuthenticated, isFalse);
    });

    testWidgets('router ignores quick login when production gate is disabled', (tester) async {
      DevQuickLoginGate.debugEnabledOverride = false;
      final controller = DashboardController(startAuthenticated: false);
      final delegate = AppRouterDelegate(controller);

      await tester.pumpWidget(
        MaterialApp(
          home: Router(
            routerDelegate: delegate,
            routeInformationParser: const AppRouteParser(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(DashboardScreen), findsNothing);

      // Attempt navigation with quick-login params
      final uri = Uri.parse('/quick-login?email=yonetici@begonya.com&password=Password123');
      await delegate.setNewRoutePath(uri);
      await tester.pumpAndSettle();

      // Must remain strictly on LoginScreen
      expect(controller.isAuthenticated, isFalse);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(DashboardScreen), findsNothing);
    });
  });

  group('DevQuickLoginGate dev-mode behavior', () {
    test('authenticates persona and targets manager cockpit in test mode', () async {
      DevQuickLoginGate.debugEnabledOverride = true;
      expect(DevQuickLoginGate.allowed, isTrue);

      final controller = DashboardController(isTestMode: true, startAuthenticated: false);
      final uri = Uri.parse(
        '/?quick_login=true&email=yonetici@begonya.com&password=Password123&target=/manager/home',
      );

      final result = await DevQuickLoginGate.tryHandleQuickLogin(
        uri: uri,
        controller: controller,
      );

      expect(result, isNotNull);
      expect(controller.isAuthenticated, isTrue);
      expect(controller.userRole, UserRole.siteManager);
      expect(controller.siteAdminPath, SiteAdminActivePath.managerCockpit);
    });

    test('supports hash-fragment query parameters', () async {
      DevQuickLoginGate.debugEnabledOverride = true;

      final controller = DashboardController(isTestMode: true, startAuthenticated: false);
      final uri = Uri.parse(
        'http://localhost:9090/#/?quick_login=true&email=ahmet.yilmaz@begonya.com&password=Password123&target=/resident/home',
      );

      final result = await DevQuickLoginGate.tryHandleQuickLogin(
        uri: uri,
        controller: controller,
      );

      expect(result, isNotNull);
      expect(controller.isAuthenticated, isTrue);
      expect(controller.userRole, UserRole.homeOwner);
    });

    testWidgets('router transitions to DashboardScreen when dev quick-login succeeds', (tester) async {
      DevQuickLoginGate.debugEnabledOverride = true;
      final controller = DashboardController(isTestMode: true, startAuthenticated: false);
      final delegate = AppRouterDelegate(controller);

      await tester.pumpWidget(
        MaterialApp(
          home: Router(
            routerDelegate: delegate,
            routeInformationParser: const AppRouteParser(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);

      final uri = Uri.parse(
        '/?quick_login=true&email=yonetici@begonya.com&password=Password123&target=/manager/home',
      );
      await delegate.setNewRoutePath(uri);
      await tester.pumpAndSettle();

      expect(controller.isAuthenticated, isTrue);
      expect(find.byType(DashboardScreen), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
    });

    test('a malformed role parameter never breaks the handoff', () async {
      DevQuickLoginGate.debugEnabledOverride = true;
      final controller = DashboardController(isTestMode: true, startAuthenticated: false);
      final uri = Uri.parse(
        '/#/quick-login?email=yonetici@begonya.com&password=Password123&role=NOT_A_ROLE',
      );

      final result = await DevQuickLoginGate.tryHandleQuickLogin(
        uri: uri,
        controller: controller,
      );

      expect(result, isNotNull);
      expect(controller.isAuthenticated, isTrue);
      // The role falls back to the email-derived one instead of throwing.
      expect(controller.userRole, UserRole.siteManager);
    });

    test('a resident persona is not given a manager landing path', () async {
      DevQuickLoginGate.debugEnabledOverride = true;
      final controller = DashboardController(isTestMode: true, startAuthenticated: false);
      final uri = Uri.parse(
        '/#/quick-login?email=ahmet.yilmaz@begonya.com&password=Password123&role=HOME_OWNER&target=/resident/home',
      );

      final result = await DevQuickLoginGate.tryHandleQuickLogin(
        uri: uri,
        controller: controller,
      );

      expect(result, isNotNull);
      expect(controller.userRole, UserRole.homeOwner);
      expect(AppRoutes.pathFor(controller, result!).path, startsWith('/resident/'));
    });

    test('a path-style quick-login URL lands the manager on the manager route', () async {
      DevQuickLoginGate.debugEnabledOverride = true;
      final controller = DashboardController(isTestMode: true, startAuthenticated: false);

      final handled = await DevQuickLoginGate.tryHandleQuickLogin(
        uri: Uri.parse('/quick-login?email=yonetici@begonya.com&password=Password123&role=SITE_MANAGER'),
        controller: controller,
      );

      expect(AppRoutes.pathFor(controller, handled!).path, '/manager/home');
      expect(controller.userRole, UserRole.siteManager);
    });
  });
}
