// STORY-06-06: a temporary password unlocks nothing but the password change
// screen, for every role.
@Tags(['auth'])
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/auth/force_password_change_screen.dart';
import 'package:sitepulse/ui/auth/login_screen.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/dashboard/dashboard_screen.dart';
import 'package:sitepulse/ui/navigation/app_router.dart';
import 'package:sitepulse/ui/navigation/app_routes.dart';

const _roles = {
  UserRole.saasAdmin: 'SAAS_ADMIN',
  UserRole.siteManager: 'SITE_MANAGER',
  UserRole.homeOwner: 'HOME_OWNER',
  UserRole.homeResident: 'HOME_RESIDENT',
  UserRole.auditor: 'AUDITOR',
};

const _temporary = 'SP-TEMP-0001';
const _permanent = 'Kalici-Sifre-2026';

Map<String, dynamic> _auth(String role, {required bool mustChange}) => {
      'access_token': 'access-${mustChange ? 'temp' : 'final'}',
      'refresh_token': 'refresh-${mustChange ? 'temp' : 'final'}',
      'token_type': 'Bearer',
      'expires_in': 900,
      'user': {
        'id': '7',
        'full_name': 'Temp User',
        'email': 'temp@sitepulse.test',
        'phone': '',
        'role': role,
        'site_id': role == 'SAAS_ADMIN' ? '' : '1',
        'unit_id': role == 'HOME_OWNER' || role == 'HOME_RESIDENT' ? '14' : '',
        'auth_provider': 'LOCAL',
        'must_change_password': mustChange,
        'permissions': const <String>[],
      },
    };

/// Fake backend: login with the temporary password, change it, and answer
/// every business call with 403 PASSWORD_CHANGE_REQUIRED until it is changed.
class _FakeBackend {
  final String role;
  final List<String> calls = [];
  bool changed = false;

  _FakeBackend(this.role);

  http.Client get client => MockClient((request) async {
        calls.add(request.url.path);
        switch (request.url.path) {
          case '/api/v1/auth/login':
            return http.Response(jsonEncode(_auth(role, mustChange: true)), 200);
          case '/api/v1/auth/change-password':
            changed = true;
            return http.Response(jsonEncode(_auth(role, mustChange: false)), 200);
          case '/api/v1/auth/logout':
            return http.Response('', 204);
        }
        if (!changed) {
          return http.Response(
            jsonEncode({
              'error': {'code': 'PASSWORD_CHANGE_REQUIRED', 'message': 'Password change required'},
            }),
            403,
          );
        }
        return http.Response(request.method == 'GET' ? '[]' : '{}', 200);
      });

  /// Business calls made so far (everything except the auth endpoints).
  List<String> get businessCalls => calls.where((p) => !p.startsWith('/api/v1/auth/')).toList();
}

Future<DashboardController> _signIn(_FakeBackend backend) async {
  ApiClient.transport = backend.client;
  final controller = DashboardController();
  await pumpEventQueue();
  backend.calls.clear();
  expect(await controller.loginWithPassword('temp@sitepulse.test', _temporary), isTrue);
  return controller;
}

void main() {
  late http.Client previous;
  setUp(() {
    previous = ApiClient.transport;
    ApiClient.clearSession();
  });
  tearDown(() {
    ApiClient.clearSession();
    ApiClient.transport = previous;
  });

  group('ApiClient.passwordChangeRequired', () {
    test('fires on 403 PASSWORD_CHANGE_REQUIRED only', () async {
      ApiClient.setSession({'access_token': 'a', 'refresh_token': 'r'});
      var fired = 0;
      final sub = ApiClient.passwordChangeRequired.listen((_) => fired++);
      addTearDown(sub.cancel);

      ApiClient.transport = MockClient((_) async => http.Response(
          jsonEncode({'error': {'code': 'PERMISSION_DENIED'}}), 403));
      await ApiClient.get(ApiClient.uri('/api/v1/saas/sites'));
      expect(fired, 0);

      ApiClient.transport = MockClient((_) async => http.Response(
          jsonEncode({'error': {'code': 'PASSWORD_CHANGE_REQUIRED'}}), 403));
      final response = await ApiClient.get(ApiClient.uri('/api/v1/saas/sites'));
      expect(response.statusCode, 403);
      expect(fired, 1);
    });
  });

  for (final entry in _roles.entries) {
    final role = entry.key;
    final apiRole = entry.value;

    group('${role.name} with a temporary password', () {
      test('signs in to the change screen without loading any business data', () async {
        final backend = _FakeBackend(apiRole);
        final controller = await _signIn(backend);
        addTearDown(controller.dispose);
        final router = AppRouterDelegate(controller);
        addTearDown(router.dispose);

        expect(controller.isAuthenticated, isTrue);
        expect(controller.userRole, role);
        expect(controller.requiresPasswordChange, isTrue);
        expect(backend.businessCalls, isEmpty);
        expect(router.currentConfiguration.path, AppRoutes.changePassword);
      });

      test('deep links wait until the password is changed, then open the role home', () async {
        final backend = _FakeBackend(apiRole);
        final controller = await _signIn(backend);
        addTearDown(controller.dispose);
        final router = AppRouterDelegate(controller);
        addTearDown(router.dispose);

        await router.setNewRoutePath(Uri(path: '/admin/sites'));
        expect(router.currentConfiguration.path, AppRoutes.changePassword);

        expect(
          await controller.changePassword(
            email: controller.userSession.email,
            currentPassword: _temporary,
            newPassword: _permanent,
          ),
          isTrue,
        );
        expect(controller.requiresPasswordChange, isFalse);
        if (role == UserRole.saasAdmin) {
          expect(router.currentConfiguration.path, '/admin/sites');
        } else {
          // Another role's link falls back to the user's own home page.
          expect(router.currentConfiguration.path, AppRoutes.pathFor(controller, 0).path);
        }
      });

      testWidgets('router shows only the change screen; logout returns to login', (tester) async {
        final backend = _FakeBackend(apiRole);
        late DashboardController controller;
        await tester.runAsync(() async => controller = await _signIn(backend));
        final router = AppRouterDelegate(controller);
        addTearDown(router.dispose);

        await tester.pumpWidget(MaterialApp.router(
          routerDelegate: router,
          routeInformationParser: const AppRouteParser(),
        ));
        await tester.pump();

        expect(find.byType(ForcePasswordChangeScreen), findsOneWidget);
        expect(find.byType(DashboardScreen), findsNothing);
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.byType(BottomNavigationBar), findsNothing);

        await tester.tap(find.byKey(const Key('btn_force_password_logout')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1)); // page transition
        expect(controller.isAuthenticated, isFalse);
        expect(find.byType(ForcePasswordChangeScreen), findsNothing);
        expect(find.byType(LoginScreen), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });
    });
  }

  test('a 403 PASSWORD_CHANGE_REQUIRED during a session returns to the change screen', () async {
    final backend = _FakeBackend('SITE_MANAGER');
    final controller = await _signIn(backend);
    addTearDown(controller.dispose);
    await controller.changePassword(
      email: controller.userSession.email,
      currentPassword: _temporary,
      newPassword: _permanent,
    );
    expect(controller.requiresPasswordChange, isFalse);

    // An administrator renews the temporary password while the user is signed in.
    backend.changed = false;
    await ApiClient.get(ApiClient.uri('/api/v1/site-admin/home-owners'));
    expect(controller.requiresPasswordChange, isTrue);
  });

  testWidgets('the form validates before calling the server', (tester) async {
    final backend = _FakeBackend('HOME_OWNER');
    late DashboardController controller;
    await tester.runAsync(() async => controller = await _signIn(backend));
    backend.calls.clear();
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ForcePasswordChangeScreen(controller: controller)));

    Future<void> submit(String current, String next, String confirm) async {
      await tester.enterText(find.byKey(const Key('change_password_current')), current);
      await tester.enterText(find.byKey(const Key('change_password_new')), next);
      await tester.enterText(find.byKey(const Key('change_password_confirm')), confirm);
      final button = find.byKey(const Key('btn_submit_change_password'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
    }

    await submit(_temporary, _permanent, 'Farkli-Sifre-2026');
    expect(find.text('Yeni şifreler birbiriyle uyuşmuyor.'), findsOneWidget);
    await submit(_temporary, 'kisa', 'kisa');
    expect(find.text('Yeni şifre en az 10 karakter olmalıdır.'), findsOneWidget);
    await submit(_temporary, _temporary, _temporary);
    expect(find.text('Yeni şifre mevcut şifreden farklı olmalıdır.'), findsOneWidget);
    expect(backend.calls, isEmpty);
    expect(controller.requiresPasswordChange, isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}

