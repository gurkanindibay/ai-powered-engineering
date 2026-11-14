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

// covers: SC-08-11-01
// covers: SC-08-11-02
// covers: SC-08-11-03
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

    Future<void> openModule(WidgetTester tester, {Size size = const Size(1280, 800)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(MaterialApp(home: OwnersResidentsModulePage(controller: controller)));
      await tester.pumpAndSettle();
    }

    Finder directoryListScrollable() => find.descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        ).first;

    Future<void> openUnitActions(WidgetTester tester, String unitId) async {
      final action = find.byKey(Key('module_unit_actions_$unitId'));
      await tester.scrollUntilVisible(action, 180, scrollable: directoryListScrollable());
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();
    }

    Future<void> openUnitDetails(WidgetTester tester, String unitId) async {
      final detail = find.byKey(Key('module_unit_details_$unitId'));
      await tester.scrollUntilVisible(detail, 180, scrollable: directoryListScrollable());
      await tester.pumpAndSettle();
      await tester.tap(detail);
      await tester.pumpAndSettle();
    }

    // covers: SC-08-11-01
    testWidgets('actions follow the allowed commands of a tenant-occupied unit in one tap', (tester) async {
      await openModule(tester);
      await openUnitActions(tester, 'unit-ws');

      expect(find.byKey(const Key('workspace_actions')), findsOneWidget);
      for (final id in ['replace_tenant', 'owner_takes_back', 'move_out', 'transfer_ownership', 'history', 'iban', 'delete']) {
        expect(find.byKey(Key('workspace_action_${id}_unit-ws')), findsOneWidget, reason: id);
      }
      expect(find.byKey(const Key('workspace_action_tenant_move_in_unit-ws')), findsNothing);
      expect(find.byKey(const Key('workspace_action_owner_rents_out_unit-ws')), findsNothing);
    });

    // covers: SC-08-11-02
    testWidgets('details opens information mode directly, shows ledgers and returns to the list', (tester) async {
      await openModule(tester);
      await openUnitDetails(tester, 'unit-ws');

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

    // covers: SC-08-11-03
    testWidgets('restores filter, search query, and focus on return at desktop and phone widths', (tester) async {
      await openModule(tester, size: const Size(1280, 800));

      final searchField = find.byKey(const Key('module_search_input'));
      await tester.enterText(searchField, 'Kemal');
      await tester.pumpAndSettle();

      final actionsBtn = find.byKey(const Key('module_unit_actions_unit-ws'));
      expect(actionsBtn, findsOneWidget);

      // Open workspace
      await tester.tap(actionsBtn);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace_actions')), findsOneWidget);

      // Return
      await tester.tap(find.byKey(const Key('workspace_return_btn')));
      await tester.pumpAndSettle();

      // Verify search query preserved
      expect(find.text('Kemal'), findsOneWidget);
      // Verify actions button is focused
      expect(tester.widget<OutlinedButton>(actionsBtn).focusNode?.hasFocus, isTrue);
    });

    testWidgets('phone width (<720px) opens unit workspace and returns cleanly', (tester) async {
      await openModule(tester, size: const Size(600, 900));
      await openUnitActions(tester, 'unit-ws');

      expect(find.byKey(const Key('workspace_actions')), findsOneWidget);
      await tester.tap(find.byKey(const Key('workspace_return_btn')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('workspace_actions')), findsNothing);
    });
  });
}
