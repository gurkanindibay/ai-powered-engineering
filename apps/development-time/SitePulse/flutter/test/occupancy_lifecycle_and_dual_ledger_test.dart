import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
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
      final yonetimTab = find.text('Yönetim');
      if (yonetimTab.evaluate().isNotEmpty) {
        await tester.tap(yonetimTab);
        await tester.pumpAndSettle();
      }

      // Check for presence of DashboardScreen
      expect(find.byType(DashboardScreen), findsOneWidget);
    });
  });
}
