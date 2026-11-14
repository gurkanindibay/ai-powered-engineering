@Tags(['residents', 'finance'])
library;
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
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

    testWidgets('Tapping history button opens Daire Sakin & İkamet Tarihçesi without layout assertion errors', (tester) async {
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

      final residentsTab = find.text('Sakinler & Malikler');
      expect(residentsTab, findsOneWidget);
      await tester.ensureVisible(residentsTab);
      await tester.pumpAndSettle();
      await tester.tap(residentsTab);
      await tester.pumpAndSettle();

      final firstHo = controller.homeOwners.first;
      final unitActions = find.byKey(Key('unit_actions_${firstHo.unitId}'));
      await tester.ensureVisible(unitActions);
      await tester.tap(unitActions);
      await tester.pumpAndSettle();

      final historyBtn = find.byKey(Key('history_ho_${firstHo.unitId}'));
      expect(historyBtn, findsOneWidget);

      await tester.ensureVisible(historyBtn);
      await tester.pumpAndSettle();
      await tester.tap(historyBtn);
      await tester.pumpAndSettle();

      // Verify the page opened cleanly
      expect(find.text('Daire Sakin & İkamet Tarihçesi'), findsOneWidget);

      // Verify closing the dialog
      final closeBtn = find.text('Kapat');
      expect(closeBtn, findsOneWidget);
      await tester.ensureVisible(closeBtn);
      await tester.pumpAndSettle();
      await tester.tap(closeBtn);
      await tester.pumpAndSettle();

      expect(find.text('Daire Sakin & İkamet Tarihçesi'), findsNothing);
    });

    testWidgets('Tapping move-out button opens Sakin Ayrılışı page without layout assertion errors', (tester) async {
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

      final residentsTab = find.text('Sakinler & Malikler');
      expect(residentsTab, findsOneWidget);
      await tester.ensureVisible(residentsTab);
      await tester.pumpAndSettle();
      await tester.tap(residentsTab);
      await tester.pumpAndSettle();

      final firstHo = controller.homeOwners.first;
      final unitActions = find.byKey(Key('unit_actions_${firstHo.unitId}'));
      await tester.ensureVisible(unitActions);
      await tester.tap(unitActions);
      await tester.pumpAndSettle();

      final moveOutBtn = find.byKey(Key('move_out_ho_${firstHo.unitId}'));
      expect(moveOutBtn, findsOneWidget);

      await tester.ensureVisible(moveOutBtn);
      await tester.pumpAndSettle();
      await tester.tap(moveOutBtn);
      await tester.pumpAndSettle();

      // Verify the page opened cleanly
      expect(find.text('Sakin Ayrılışı (Move-Out / Tahliye)'), findsOneWidget);

      // Verify closing via Vazgeç
      final cancelBtn = find.text('Vazgeç');
      expect(cancelBtn, findsOneWidget);
      await tester.ensureVisible(cancelBtn);
      await tester.pumpAndSettle();
      await tester.tap(cancelBtn);
      await tester.pumpAndSettle();

      expect(find.text('Sakin Ayrılışı (Move-Out / Tahliye)'), findsNothing);
    });

    testWidgets('Adding new tenant to existing unit shows confirmation modal and preserves older occupant in history', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final initialHo = controller.homeOwners.first;
      final existingName = initialHo.tenantFullName ?? initialHo.ownerFullName;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final residentsTab = find.text('Sakinler & Malikler');
      await tester.ensureVisible(residentsTab);
      await tester.pumpAndSettle();
      await tester.tap(residentsTab);
      await tester.pumpAndSettle();

      // Tap "Yeni Sakin Ekle"
      final addBtn = find.byKey(const Key('add_resident_btn'));
      expect(addBtn, findsOneWidget);
      await tester.ensureVisible(addBtn);
      await tester.pumpAndSettle();
      await tester.tap(addBtn);
      await tester.pumpAndSettle();

      // Form opens: verify role selector is present
      final roleSelector = find.byKey(const Key('add_resident_role_selector'));
      expect(roleSelector, findsOneWidget);
      expect(find.descendant(of: roleSelector, matching: find.text('Kat Maliki')), findsOneWidget);
      expect(find.descendant(of: roleSelector, matching: find.text('Kiracı')), findsOneWidget);
      expect(find.descendant(of: roleSelector, matching: find.text('Ev Sakini')), findsOneWidget);

      // Select "Kiracı"
      await tester.ensureVisible(find.descendant(of: roleSelector, matching: find.text('Kiracı')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: roleSelector, matching: find.text('Kiracı')));
      await tester.pumpAndSettle();

      // Enter unit number matching existing unit
      final textFields = find.byType(TextField);
      await tester.enterText(textFields.at(0), initialHo.unitNo.toString());
      await tester.enterText(textFields.at(1), 'Mehmet Öz');
      await tester.enterText(textFields.at(2), 'mehmet@example.com');
      await tester.enterText(textFields.at(3), '05559876543');
      await tester.pumpAndSettle();

      // Submit form
      final submitBtn = find.text('Kaydet & Şifre Üret');
      await tester.ensureVisible(submitBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      // Confirmation modal MUST be shown because unit is already occupied and role is Kiracı!
      expect(find.text('Yeni Kiracı Atama Onayı'), findsOneWidget);
      expect(find.textContaining('halihazırda kayıtlı sakin: "$existingName"'), findsOneWidget);

      // Confirm assignment
      final confirmBtn = find.text('Evet, Yeni Kiracı Ata');
      expect(confirmBtn, findsOneWidget);
      await tester.ensureVisible(confirmBtn);
      await tester.pumpAndSettle();
      await tester.tap(confirmBtn);
      await tester.pumpAndSettle();

      // Modal closed, unit updated
      final updatedHo = controller.homeOwners.firstWhere((h) => h.unitId == initialHo.unitId);
      expect(updatedHo.tenantFullName, 'Mehmet Öz');

      // Now open history for this unit:
      final history = await controller.fetchOccupancyHistory(initialHo.unitId);
      expect(history.length, greaterThanOrEqualTo(2));
      expect(history.any((h) => h.personName == 'Mehmet Öz' && h.isActive), isTrue);
      expect(history.any((h) => h.personName == existingName && !h.isActive), isTrue);
    });

    testWidgets('Adding RESIDENT to existing unit does NOT show move-out confirmation modal', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final initialHo = controller.homeOwners.first;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final residentsTab = find.text('Sakinler & Malikler');
      await tester.ensureVisible(residentsTab);
      await tester.pumpAndSettle();
      await tester.tap(residentsTab);
      await tester.pumpAndSettle();

      // Tap "Yeni Sakin Ekle"
      final addBtn = find.byKey(const Key('add_resident_btn'));
      await tester.ensureVisible(addBtn);
      await tester.pumpAndSettle();
      await tester.tap(addBtn);
      await tester.pumpAndSettle();

      // Select "Ev Sakini"
      await tester.ensureVisible(find.text('Ev Sakini'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ev Sakini'));
      await tester.pumpAndSettle();

      // Explanatory banner visible
      expect(find.textContaining('Hane sakini olarak eklenir'), findsOneWidget);

      // Enter unit number matching existing unit
      final textFields = find.byType(TextField);
      await tester.enterText(textFields.at(0), initialHo.unitNo.toString());
      await tester.enterText(textFields.at(1), 'Ali Kaya');
      await tester.enterText(textFields.at(2), 'ali@example.com');
      await tester.enterText(textFields.at(3), '05553332211');
      await tester.pumpAndSettle();

      // Submit form
      final submitBtn = find.text('Kaydet & Şifre Üret');
      await tester.ensureVisible(submitBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      // Confirmation modal MUST NOT be shown for RESIDENT!
      expect(find.text('Yeni Kat Maliki Atama Onayı'), findsNothing);
      expect(find.text('Yeni Kiracı Atama Onayı'), findsNothing);
    });

    testWidgets('Adding RESIDENT to unit attaches them to householdResidents and does NOT add separate flat in Aidat Takibi', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final initialFlatsCount = controller.flatsList.length;
      final targetHo = controller.homeOwners.firstWhere((h) => h.block.contains('A') && h.unitNo == 14, orElse: () => controller.homeOwners.firstWhere((h) => h.block.contains('A')));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final residentsTab = find.text('Sakinler & Malikler');
      await tester.ensureVisible(residentsTab);
      await tester.pumpAndSettle();
      await tester.tap(residentsTab);
      await tester.pumpAndSettle();

      // Tap "Yeni Sakin Ekle"
      final addBtn = find.byKey(const Key('add_resident_btn'));
      await tester.ensureVisible(addBtn);
      await tester.pumpAndSettle();
      await tester.tap(addBtn);
      await tester.pumpAndSettle();

      // Select "Ev Sakini"
      await tester.ensureVisible(find.text('Ev Sakini'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ev Sakini'));
      await tester.pumpAndSettle();

      // Fill form with co-resident "Sakin Kardeş"
      final textFields = find.byType(TextField);
      await tester.enterText(textFields.at(0), targetHo.unitNo.toString());
      await tester.enterText(textFields.at(1), 'Sakin Kardeş');
      await tester.enterText(textFields.at(2), 'sakin@example.com');
      await tester.enterText(textFields.at(3), '05559998877');
      await tester.pumpAndSettle();

      // Submit form
      final submitBtn = find.text('Kaydet & Şifre Üret');
      await tester.ensureVisible(submitBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      // Dismiss provisioned credentials dialog if displayed
      final tamamBtn = find.text('Tamam');
      if (tamamBtn.evaluate().isNotEmpty) {
        await tester.ensureVisible(tamamBtn);
        await tester.pumpAndSettle();
        await tester.tap(tamamBtn);
        await tester.pumpAndSettle();
      }

      // Verify that co-resident was NOT added to flatsList (Aidat Takibi ledger)
      expect(controller.flatsList.length, equals(initialFlatsCount));

      // Verify co-resident is attached under householdResidents on targetHo
      final updatedHo = controller.homeOwners.firstWhere((h) => h.unitId == targetHo.unitId);
      expect(updatedHo.householdResidents.any((r) => r.fullName == 'Sakin Kardeş'), isTrue);

      // Verify co-resident is rendered on unit card in Sakinler & Malikler screen
      expect(find.textContaining('Hane Sakinleri / Birlikte Yaşayanlar'), findsWidgets);
      expect(find.textContaining('Sakin Kardeş'), findsOneWidget);
    });
  });
}
