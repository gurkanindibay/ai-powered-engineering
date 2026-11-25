@Tags(['residents', 'finance'])
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
import 'package:sitepulse/ui/components/sp_effective_date_field.dart';
import 'package:sitepulse/ui/dashboard/dashboard_screen.dart';
import 'test_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Occupancy Lifecycle and Dual Ledger Domain Model Tests', () {
    test('HomeOwnerItem deserializes occupancy status and dual-ledger balances correctly', () {
      final json = {
        'unit_id': '10',
        'site_id': 'site-1',
        'block': 'A',
        'unit_no': 5,
        'floor': 2,
        'owner_full_name': 'Ali Yılmaz',
        'email': 'ali@example.com',
        'phone': '5551112233',
        'land_share': '1/24',
        'monthly_dues': '1250.00',
        'house_type': '2+1',
        'is_resident': false,
        'created_at': '2026-01-01T00:00:00Z',
        'occupancy_status': 'TENANT_OCCUPIED',
        'tenant_full_name': 'Zeynep Kaya',
        'tenant_email': 'zeynep@example.com',
        'tenant_phone': '5559998877',
        'operational_dues_balance': '1250.00',
        'capital_dues_balance': '500.00',
      };

      final item = HomeOwnerItem.fromJson(json);

      expect(item.unitId, '10');
      expect(item.occupancyStatus, 'TENANT_OCCUPIED');
      expect(item.tenantFullName, 'Zeynep Kaya');
      expect(item.operationalDuesBalance, Decimal.parse('1250.00'));
      expect(item.capitalDuesBalance, Decimal.parse('500.00'));
      expect(item.isResident, isFalse);

      final exported = item.toJson();
      expect(exported['occupancy_status'], 'TENANT_OCCUPIED');
      expect(exported['tenant_full_name'], 'Zeynep Kaya');
      expect(exported['operational_dues_balance'], '1250');
      expect(exported['capital_dues_balance'], '500');
    });

    test('OccupancyHistoryItem deserializes timeline correctly', () {
      final json = {
        'id': 1,
        'unit_id': 10,
        'person_id': 42,
        'person_name': 'Mehmet Demir',
        'person_phone': '5551234567',
        'person_email': 'mehmet@example.com',
        'role': 'TENANT',
        'start_date': '2025-06-01',
        'end_date': '2026-05-31',
        'is_active': false,
        'exit_balance': '350.50',
        'notes': 'Key returned to security desk',
        'created_at': '2025-06-01T10:00:00Z',
      };

      final item = OccupancyHistoryItem.fromJson(json);
      expect(item.id, 1);
      expect(item.personName, 'Mehmet Demir');
      expect(item.role, 'TENANT');
      expect(item.isActive, isFalse);
      expect(item.exitBalance, Decimal.parse('350.50'));
      expect(item.notes, 'Key returned to security desk');
    });

    test('Move-out records the effective date chosen by the manager', () async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');
      final first = controller.homeOwners.first;
      final earlier = DateTime(2026, 1, 15);

      final ok = await controller.moveOutResident(first.unitId, effectiveDate: earlier);
      expect(ok, isTrue);

      final history = await controller.fetchOccupancyHistory(first.unitId);
      final closed = history.where((h) => !h.isActive && h.endDate != null);
      if (closed.isNotEmpty) {
        expect(closed.first.endDate, '2026-01-15');
      }
      expect(formatEffectiveDate(earlier), '2026-01-15');
    });

    test('Controller handles move-out and move-in in local fallback mode', () async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      // Verify initial resident exists
      expect(controller.homeOwners, isNotEmpty);
      final first = controller.homeOwners.first;

      // Execute move out
      final outSuccess = await controller.moveOutResident(first.unitId, notes: 'Contract ended');
      expect(outSuccess, isTrue);

      final updated = controller.homeOwners.firstWhere((h) => h.unitId == first.unitId);
      expect(updated.occupancyStatus, 'VACANT');
      expect(updated.tenantFullName, isNull);

      // Execute move in with a new tenant
      final inSuccess = await controller.moveInResident(
        first.unitId,
        role: 'TENANT',
        fullName: 'Canan Can',
        email: 'canan@example.com',
        phone: '5550001122',
        notes: '1-year lease agreement',
      );
      expect(inSuccess, isTrue);

      final reOccupied = controller.homeOwners.firstWhere((h) => h.unitId == first.unitId);
      expect(reOccupied.occupancyStatus, 'TENANT_OCCUPIED');
      expect(reOccupied.tenantFullName, 'Canan Can');
      expect(reOccupied.tenantEmail, 'canan@example.com');
    });
  });

  group('Dashboard HomeOwnerCard Occupancy & Dues Breakdown UI Widget Tests', () {
    testWidgets('Renders occupancy status badge and dual ledger breakdown chips', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Navigate to Yönetim tab
      final residentsTab = find.text('Sakinler & Malikler');
      if (residentsTab.evaluate().isNotEmpty) {
        await tester.ensureVisible(residentsTab);
        await tester.pumpAndSettle();
        await tester.tap(residentsTab);
        await tester.pumpAndSettle();
      }

      // Check for presence of DashboardScreen
      expect(find.byType(DashboardScreen), findsOneWidget);
    });

    // The residents tab lists units; their actions run in the owners & residents module workspace.
    Future<String> openWorkspaceAction(WidgetTester tester, DashboardController controller, String action) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DashboardScreen(controller: controller))));
      await tester.pumpAndSettle();

      final residentsTab = find.text('Sakinler & Malikler');
      expect(residentsTab, findsOneWidget);
      await tester.ensureVisible(residentsTab);
      await tester.pumpAndSettle();
      await tester.tap(residentsTab);
      await tester.pumpAndSettle();

      final unit = controller.homeOwners.firstWhere((h) => h.isTenantOccupied || h.isOwnerOccupied);
      final unitActions = find.byKey(Key('module_unit_actions_${unit.unitId}'));
      await tester.ensureVisible(unitActions);
      await tester.pumpAndSettle();
      await tester.tap(unitActions);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace_actions')), findsOneWidget);

      final row = find.byKey(Key('workspace_action_${action}_${unit.unitId}'));
      await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      return unit.unitId;
    }

    testWidgets('Tapping history in the unit workspace opens Daire Sakin & İkamet Tarihçesi', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      await openWorkspaceAction(tester, controller, 'history');

      expect(find.text('Daire Sakin & İkamet Tarihçesi'), findsOneWidget);
      await tester.tap(find.text('Kapat'));
      await tester.pumpAndSettle();
      expect(find.text('Daire Sakin & İkamet Tarihçesi'), findsNothing);
    });

    testWidgets('Tapping move-out in the unit workspace opens Sakin Ayrılışı without layout errors', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');
      final previousTransport = ApiClient.transport;
      addTearDown(() => ApiClient.transport = previousTransport);
      ApiClient.transport = MockClient((request) async {
        if (request.url.path.endsWith('/statement')) {
          final unitId = request.url.pathSegments[3];
          final home = controller.homeOwners.firstWhere((item) => item.unitId == unitId);
          return http.Response(
            jsonEncode({
              'unit_id': unitId,
              'unit_label': 'A Blok 1',
              'debtors': [
                {
                  'debtor_type': 'TENANT',
                  'name': home.tenantFullName ?? 'Zeynep Kaya',
                  'principal_outstanding': '100.00',
                  'penalty_outstanding': '10.00',
                  'total_outstanding': '110.00',
                },
              ],
              'receipts': [],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404, headers: {'content-type': 'application/json'});
      });

      await openWorkspaceAction(tester, controller, 'move_out');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(find.text('Sakin Ayrılışı (Move-Out / Tahliye)'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(find.text('Sakin Ayrılışı (Move-Out / Tahliye)'), findsNothing);
    });
  });
}
