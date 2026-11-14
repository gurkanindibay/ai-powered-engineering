@Tags(['residents'])
library;

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/residents/owners_residents_module_page.dart';
import 'test_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Unit workspace', () {
    late DashboardController controller;

    setUp(() async {
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
          ownerFullName: 'Kemal Ev Sahibi',
          email: 'kemal.owner@example.com',
          phone: '0532 111 22 33',
          tenantFullName: 'Ayşe Kiracı',
          occupancyStatus: 'TENANT_OCCUPIED',
          landShare: '1/32',
          monthlyDues: Decimal.parse('1600.00'),
          houseType: '2+1',
          isResident: false,
          mustChangePassword: false,
          createdAt: DateTime.now(),
        ),
      );
    });

    Future<void> openModule(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(home: OwnersResidentsModulePage(controller: controller)));
      await tester.pumpAndSettle();
    }

    // covers: SC-08-11-01
    testWidgets('actions follow the allowed commands of a tenant-occupied unit', (tester) async {
      await openModule(tester);
      final entry = find.byKey(const Key('module_workspace_actions_unit-ws'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();

      for (final id in ['replace_tenant', 'owner_takes_back', 'move_out', 'transfer_ownership', 'history', 'iban', 'delete']) {
        expect(find.byKey(Key('workspace_action_${id}_unit-ws')), findsOneWidget, reason: id);
      }
      expect(find.byKey(const Key('workspace_action_tenant_move_in_unit-ws')), findsNothing);
      expect(find.byKey(const Key('workspace_action_owner_rents_out_unit-ws')), findsNothing);
    });

    // covers: SC-08-11-02
    testWidgets('switches to information with separate ledgers and returns to the list', (tester) async {
      await openModule(tester);
      final entry = find.byKey(const Key('module_workspace_info_unit-ws'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('workspace_information')), findsOneWidget);
      expect(find.text('İşletme Aidat Bakiyesi'), findsOneWidget);
      expect(find.text('Demirbaş Bakiyesi'), findsOneWidget);

      await tester.tap(find.byKey(const Key('workspace_mode_actions_unit-ws')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace_actions')), findsOneWidget);

      await tester.tap(find.byKey(const Key('workspace_return_btn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace_identity')), findsNothing);
    });
  });
}
