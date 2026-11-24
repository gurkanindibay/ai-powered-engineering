@Tags(['residents'])
library;

import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/residents/owners_residents_module_page.dart';
import 'test_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Person card cross-navigation', () {
    late DashboardController controller;
    late http.Client previousTransport;
    final calls = <String>[];
    var ownerName = 'Kemal Ev Sahibi';

    http.Response json(Object body, [int status = 200]) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    Map<String, dynamic> card(int id, String name) => {
          'person_id': id,
          'full_name': name,
          'email': 'p$id@example.com',
          'phone': '0532 000 00 0$id',
          'role': 'HOME_OWNER',
          'owned_units': 1,
          'occupied_units': 0,
          'login': 'NONE',
          'version': 1,
        };

    setUp(() async {
      calls.clear();
      ownerName = 'Kemal Ev Sahibi';
      previousTransport = ApiClient.transport;
      ApiClient.transport = MockClient((request) async {
        final path = request.url.path;
        calls.add('${request.method} $path');
        if (path.endsWith('/persons/77') && request.method == 'GET') {
          return json({
            'person': card(77, ownerName),
            'units': [
              {
                'unit_id': 'unit-ws',
                'block': 'B',
                'unit_no': 24,
                'relation': 'OWNER',
                'start_date': '2024-01-01',
                'active': true,
              },
            ],
            'record': <String, dynamic>{},
          });
        }
        if (path.endsWith('/persons/77') && request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          ownerName = body['full_name'] as String;
          return json({'card': card(77, ownerName)..['version'] = 2});
        }
        if (path.endsWith('/duplicate-check')) return json(<Object>[]);
        if (path.endsWith('/persons/77/login') && request.method == 'POST') return json({'status': 'SENT'});
        return json(<Object>[]);
      });
      controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');
      controller.homeOwners.insert(
        0,
        HomeOwnerItem(
          unitId: 'unit-ws',
          siteId: 'site-1',
          block: 'B',
          unitNo: 24,
          floor: 6,
          ownerFullName: ownerName,
          email: 'kemal.owner@example.com',
          phone: '0532 111 22 33',
          occupancyStatus: 'OWNER_OCCUPIED',
          landShare: '1/32',
          monthlyDues: Decimal.parse('1600.00'),
          isResident: true,
          mustChangePassword: false,
          createdAt: DateTime.now(),
          ownerPersonId: 77,
        ),
      );
    });

    tearDown(() => ApiClient.transport = previousTransport);

    Future<void> openWorkspace(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(MaterialApp(home: OwnersResidentsModulePage(controller: controller)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('module_search_input')), 'Kemal');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('module_unit_actions_unit-ws')));
      await tester.pumpAndSettle();
    }

    Future<void> openCard(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('workspace_person_owner_77')));
      await tester.pumpAndSettle();
    }

    void popRoute(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator).first).pop();

    // covers: SC-12-07-01
    testWidgets('unit to person to unit keeps list state and returns focus to the unit row', (tester) async {
      await openWorkspace(tester);
      await openCard(tester);
      expect(find.byKey(const Key('person_edit_btn')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('person_unit_unit-ws')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('person_unit_unit-ws')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace_identity')), findsOneWidget);

      // Unwind: second workspace, person card, first workspace.
      await tester.tap(find.byKey(const Key('workspace_return_btn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('person_edit_btn')), findsOneWidget);
      popRoute(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace_identity')), findsOneWidget);
      await tester.tap(find.byKey(const Key('workspace_return_btn')));
      await tester.pumpAndSettle();

      expect(find.text('Kemal'), findsOneWidget);
      final actionsBtn = find.byKey(const Key('module_unit_actions_unit-ws'));
      expect(tester.widget<OutlinedButton>(actionsBtn).focusNode?.hasFocus, isTrue);
    });

    // covers: SC-12-07-02
    testWidgets('a card edit updates the owner role shown on the unit', (tester) async {
      await openWorkspace(tester);
      await openCard(tester);

      await tester.tap(find.byKey(const Key('person_edit_btn')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('person_form_name')), 'Kemal Yeni Soyad');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
      await tester.pumpAndSettle();

      expect(calls.any((c) => c.startsWith('PATCH') && c.endsWith('/persons/77')), isTrue);
      expect(controller.homeOwners.firstWhere((h) => h.unitId == 'unit-ws').ownerFullName, 'Kemal Yeni Soyad');

      popRoute(tester);
      await tester.pumpAndSettle();
      expect(find.text('Kemal Yeni Soyad'), findsWidgets);
    });

    // covers: SC-12-07-03
    testWidgets('a person without a login can be given one from the card', (tester) async {
      await openWorkspace(tester);
      await openCard(tester);

      await tester.ensureVisible(find.byKey(const Key('person_open_login_btn')));
      await tester.tap(find.byKey(const Key('person_open_login_btn')));
      await tester.pumpAndSettle();

      expect(calls, contains('POST /api/v1/site-admin/persons/77/login'));
    });

    // covers: SC-12-07-03
    testWidgets('person-first role action selects the unit and opens its workspace', (tester) async {
      await openWorkspace(tester);
      await openCard(tester);

      await tester.ensureVisible(find.byKey(const Key('person_role_tenant_btn')));
      await tester.tap(find.byKey(const Key('person_role_tenant_btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('person_role_unit_unit-ws')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('workspace_identity')), findsOneWidget);
    });
  });
}
