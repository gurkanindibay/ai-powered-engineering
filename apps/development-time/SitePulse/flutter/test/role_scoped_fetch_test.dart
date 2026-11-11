// Each role only requests what the server lets it read (STORY-06-01). Found by the
// GUI user journeys: owners, residents and auditors were sent the site manager's
// directory and overview, and residents the owner's household list, all 403.
@Tags(['auth'])
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';

const _managerOnly = ['/api/v1/site-admin/home-owners', '/api/v1/site-admin/overview'];
const _householdList = '/api/v1/home-residents/members/14';

Map<String, dynamic> _auth(String role) => {
      'access_token': 'access',
      'refresh_token': 'refresh',
      'token_type': 'Bearer',
      'expires_in': 900,
      'user': {
        'id': '7',
        'full_name': 'Role User',
        'email': 'role@sitepulse.test',
        'phone': '',
        'role': role,
        'site_id': '1',
        'unit_id': role == 'HOME_OWNER' || role == 'HOME_RESIDENT' ? '14' : '',
        'auth_provider': 'LOCAL',
        'must_change_password': false,
        'permissions': const <String>[],
      },
    };

Future<(DashboardController, List<String>)> _signIn(String role) async {
  final calls = <String>[];
  ApiClient.transport = MockClient((request) async {
    calls.add(request.url.path);
    if (request.url.path == '/api/v1/auth/login') return http.Response(jsonEncode(_auth(role)), 200);
    return http.Response(request.url.path.endsWith('/dashboard') || request.url.path.endsWith('/overview') ? '{}' : '[]', 200);
  });
  final controller = DashboardController();
  await pumpEventQueue();
  expect(await controller.loginWithPassword('role@sitepulse.test', 'Permanent-Pass-1'), isTrue);
  // What the dashboard screen and the home page ask for on open.
  await controller.fetchHomeOwners();
  await controller.fetchSiteManagerOverview(siteId: '1');
  await controller.fetchResidentDashboard('14');
  await pumpEventQueue();
  return (controller, calls);
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

  for (final role in ['HOME_OWNER', 'HOME_RESIDENT', 'AUDITOR']) {
    test('$role never requests the site manager directory or overview', () async {
      final (controller, calls) = await _signIn(role);
      addTearDown(controller.dispose);
      for (final path in _managerOnly) {
        expect(calls, isNot(contains(path)), reason: path);
      }
    });
  }

  test('a resident does not request the household list; the owner does', () async {
    final (resident, residentCalls) = await _signIn('HOME_RESIDENT');
    addTearDown(resident.dispose);
    expect(resident.canManageHousehold, isFalse);
    expect(residentCalls, isNot(contains(_householdList)));

    ApiClient.clearSession();
    final (owner, ownerCalls) = await _signIn('HOME_OWNER');
    addTearDown(owner.dispose);
    expect(owner.canManageHousehold, isTrue);
    expect(ownerCalls, contains(_householdList));
  });

  test('the site manager still loads its directory and overview', () async {
    final (controller, calls) = await _signIn('SITE_MANAGER');
    addTearDown(controller.dispose);
    expect(controller.canReadSiteDirectory, isTrue);
    for (final path in _managerOnly) {
      expect(calls, contains(path), reason: path);
    }
  });
}
