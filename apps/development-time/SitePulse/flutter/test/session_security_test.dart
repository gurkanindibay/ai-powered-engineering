import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/components/security_center_page.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';

void main() {
  late http.Client previous;
  setUp(() {previous = ApiClient.transport; ApiClient.clearSession();});
  tearDown(() {ApiClient.clearSession(); ApiClient.transport = previous;});

  test('roles are exact and unknown roles never gain owner authority', () {
    expect(UserRole.fromApi('SITE_MANAGER'), UserRole.siteManager);
    expect(() => UserRole.fromApi('SUPER_ADMIN'), throwsFormatException);
    expect(() => UserRole.fromApi(null), throwsFormatException);
  });

  test('concurrent expired requests share one refresh', () async {
    ApiClient.setSession({'access_token': 'old', 'refresh_token': 'refresh'});
    var refreshes = 0;
    ApiClient.transport = MockClient((request) async {
      if (request.url.path == '/api/v1/auth/refresh') {
        refreshes++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return http.Response(jsonEncode({'access_token': 'new', 'refresh_token': 'rotated'}), 200);
      }
      return http.Response('{}', request.headers['Authorization'] == 'Bearer new' ? 200 : 401);
    });
    final results = await Future.wait(List.generate(4, (_) => ApiClient.get(ApiClient.uri('/api/v1/audit/events'))));
    expect(refreshes, 1);
    expect(results.every((result) => result.statusCode == 200), isTrue);
  });

  test('protected authentication actions renew expired access', () async {
    ApiClient.setSession({'access_token': 'old', 'refresh_token': 'refresh'});
    var refreshes = 0;
    ApiClient.transport = MockClient((request) async {
      if (request.url.path == '/api/v1/auth/refresh') {
        refreshes++;
        return http.Response(jsonEncode({'access_token': 'new', 'refresh_token': 'rotated'}), 200);
      }
      return http.Response('{}', request.headers['Authorization'] == 'Bearer new' ? 200 : 401);
    });
    final result = await ApiClient.post(ApiClient.uri('/api/v1/auth/step-up'), body: '{}');
    expect(result.statusCode, 200);
    expect(refreshes, 1);
  });

  test('invalid login credentials do not renew an existing session', () async {
    ApiClient.setSession({'access_token': 'current', 'refresh_token': 'refresh'});
    var calls = 0;
    ApiClient.transport = MockClient((_) async {calls++; return http.Response('{}', 401);});
    expect((await ApiClient.post(ApiClient.uri('/api/v1/auth/login'), body: '{}')).statusCode, 401);
    expect(calls, 1);
    expect(ApiClient.accessToken, 'current');
  });

  test('403 never refreshes or signs out', () async {
    ApiClient.setSession({'access_token': 'current', 'refresh_token': 'refresh'});
    var calls = 0;
    ApiClient.transport = MockClient((_) async {calls++; return http.Response('{}', 403);});
    expect((await ApiClient.get(ApiClient.uri('/api/v1/audit/events'))).statusCode, 403);
    expect(calls, 1);
    expect(ApiClient.accessToken, 'current');
  });

  test('a late renewal cannot resurrect a logged out session', () async {
    ApiClient.setSession({'access_token': 'old', 'refresh_token': 'refresh'});
    final started = Completer<void>();
    final finish = Completer<void>();
    ApiClient.transport = MockClient((request) async {
      if (request.url.path.endsWith('/refresh')) {
        started.complete(); await finish.future;
        return http.Response(jsonEncode({'access_token': 'new', 'refresh_token': 'rotated'}), 200);
      }
      return http.Response('{}', 401);
    });
    final pending = ApiClient.get(ApiClient.uri('/api/v1/audit/events'));
    await started.future;
    ApiClient.clearSession();
    finish.complete();
    await pending;
    expect(ApiClient.accessToken, isNull);
  });

  test('a delayed request cannot retry under another signed-in identity', () async {
    ApiClient.setSession({'access_token': 'alice', 'refresh_token': 'alice-refresh'});
    final started = Completer<void>();
    final finish = Completer<void>();
    var calls = 0;
    ApiClient.transport = MockClient((request) async {
      calls++; started.complete(); await finish.future;
      return http.Response('{}', 401);
    });
    final request = ApiClient.get(ApiClient.uri('/api/v1/audit/events'));
    await started.future;
    ApiClient.setSession({'access_token': 'bob', 'refresh_token': 'bob-refresh'});
    finish.complete(); await request;
    expect(calls, 1);
    expect(ApiClient.accessToken, 'bob');
  });

  test('unknown server roles never install credentials or enter demo fallback', () async {
    final controller = DashboardController();
    ApiClient.transport = MockClient((_) async => http.Response(jsonEncode({
      'access_token': 'untrusted', 'refresh_token': 'untrusted-refresh',
      'user': {'role': 'SUPER_ADMIN', 'permissions': <String>[]},
    }), 200));
    expect(await controller.loginWithPassword('unknown@example.com', 'irrelevant-password'), isFalse);
    expect(ApiClient.accessToken, isNull);
    expect(controller.isAuthenticated, isFalse);
    controller.dispose();
  });

  testWidgets('residents see verification but no tenant audit access', (tester) async {
    const session = UserSession(id: '1', fullName: 'Resident', email: 'resident@example.com', phone: '',
      role: UserRole.homeResident, siteName: 'Site', unitName: 'Unit', authProvider: AuthProvider.local,
      permissions: []);
    await tester.pumpWidget(const MaterialApp(home: SecurityCenterPage(session: session)));
    expect(find.byKey(const Key('security_verify')), findsOneWidget);
    expect(find.text('Audit events'), findsNothing);
    expect(find.byKey(const Key('security_export')), findsNothing);
  });
}
