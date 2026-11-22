@Tags(['residents'])
library;
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

  group('Home Owner Directory & Edit Screen Tests', () {
    test('HomeOwnerItem model serializes and deserializes correctly', () {
      final now = DateTime.now();
      final item = HomeOwnerItem(
        unitId: 'unit-b65',
        siteId: 'site-1',
        block: 'B',
        unitNo: 65,
        floor: 17,
        ownerFullName: 'Test Murat',
        email: 'murat.test@example.com',
        phone: '0555 999 88 77',
        landShare: '1/24',
        monthlyDues: Decimal.parse('1000.00'),
        houseType: '1+1',
        isResident: true,
        mustChangePassword: false,
        createdAt: now,
      );

      final json = item.toJson();
      expect(json['unit_id'], equals('unit-b65'));
      expect(json['owner_full_name'], equals('Test Murat'));
      expect(json['block'], equals('B'));
      expect(json['unit_no'], equals(65));
      expect(json['monthly_dues'], equals('1000'));

      final parsed = HomeOwnerItem.fromJson(json);
      expect(parsed.unitId, equals('unit-b65'));
      expect(parsed.ownerFullName, equals('Test Murat'));
      expect(parsed.monthlyDues, equals(Decimal.parse('1000.00')));
    });

    test('DashboardController fetchHomeOwners deduplicates duplicate units properly', () async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);

      await controller.fetchHomeOwners(siteId: 'site-1');
      expect(controller.homeOwners, isNotEmpty);

      // Verify no duplicates by (block, unitNo)
      final seen = <String>{};
      for (final ho in controller.homeOwners) {
        final key = '${ho.block}-${ho.unitNo}';
        expect(seen.contains(key), isFalse, reason: 'Duplicate key found: $key');
        seen.add(key);
      }
    });

    test('DashboardController updateHomeOwner updates resident in-place and updates flats list', () async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final target = controller.homeOwners.first;
      final success = await controller.updateHomeOwner(
        unitId: target.unitId,
        fullName: 'Murat Güncellendi',
        email: 'murat.guncel@example.com',
        phone: '0532 999 00 11',
        houseType: '2+1',
        monthlyDues: Decimal.parse('1400.00'),
        isResident: true,
      );

      expect(success, isTrue);
      final updated = controller.homeOwners.firstWhere((h) => h.unitId == target.unitId);
      expect(updated.ownerFullName, equals('Murat Güncellendi'));
      expect(updated.phone, equals('0532 999 00 11'));
      expect(updated.houseType, equals('2+1'));
      expect(updated.monthlyDues, equals(Decimal.parse('1400.00')));

      final matchingFlat = controller.flatsList.firstWhere((f) => f.id == target.unitId);
      expect(matchingFlat.residentName, equals('Murat Güncellendi'));
      expect(matchingFlat.houseType, equals('2+1'));
      expect(matchingFlat.amountDue, equals(Decimal.parse('1400.00')));
    });

    test('DashboardController deleteHomeOwner removes homeowner and matching flats locally', () async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final initialCount = controller.homeOwners.length;
      final target = controller.homeOwners.first;

      final success = await controller.deleteHomeOwner(unitId: target.unitId);
      expect(success, isTrue);

      expect(controller.homeOwners.length, equals(initialCount - 1));
      expect(controller.homeOwners.any((h) => h.unitId == target.unitId), isFalse);
      expect(controller.flatsList.any((f) => f.id == target.unitId || f.unitNo == target.unitNo), isFalse);
    });

    test('DashboardController updateHomeOwner updates tenant and homeowner independently', () async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      // Inject a tenant-occupied unit
      final tenantUnit = HomeOwnerItem(
        unitId: 'unit-tenant-test',
        siteId: 'site-1',
        block: 'A',
        unitNo: 14,
        floor: 4,
        ownerFullName: 'Yeni Ev Sahibi 2',
        email: 'owner@example.com',
        phone: '0531 456 4545',
        tenantFullName: 'Canan Can',
        tenantEmail: 'canan@example.com',
        tenantPhone: '0533 111 22 33',
        occupancyStatus: 'TENANT_OCCUPIED',
        landShare: '1/24',
        monthlyDues: Decimal.parse('1500.00'),
        houseType: '3+1',
        isResident: false,
        mustChangePassword: false,
        createdAt: DateTime.now(),
        householdResidents: const [
          UnitResidentMember(
            id: 'mem-1',
            fullName: 'Sakin Kardeş',
            relationship: 'Kardeşi',
            phone: '0533 999 88 77',
          ),
        ],
      );
      controller.homeOwners.add(tenantUnit);

      final success = await controller.updateHomeOwner(
        unitId: 'unit-tenant-test',
        fullName: 'Yeni Ev Sahibi 2',
        email: 'owner@example.com',
        phone: '0531 456 4545',
        tenantFullName: 'Canan Can Güncellendi',
        tenantEmail: 'canan.guncel@example.com',
        tenantPhone: '0533 222 33 44',
      );

      expect(success, isTrue);
      final updated = controller.homeOwners.firstWhere((h) => h.unitId == 'unit-tenant-test');
      expect(updated.tenantFullName, equals('Canan Can Güncellendi'));
      expect(updated.tenantEmail, equals('canan.guncel@example.com'));
      expect(updated.tenantPhone, equals('0533 222 33 44'));
      expect(updated.ownerFullName, equals('Yeni Ev Sahibi 2'));
    });

    test('DashboardController updateHomeOwner with removeTenant clears tenant', () async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final tenantUnit = HomeOwnerItem(
        unitId: 'unit-tenant-clear-test',
        siteId: 'site-1',
        block: 'A',
        unitNo: 15,
        floor: 4,
        ownerFullName: 'Yeni Ev Sahibi 2',
        email: 'owner@example.com',
        phone: '0531 456 4545',
        tenantFullName: 'Canan Can',
        occupancyStatus: 'TENANT_OCCUPIED',
        landShare: '1/24',
        monthlyDues: Decimal.parse('1500.00'),
        houseType: '3+1',
        isResident: false,
        mustChangePassword: false,
        createdAt: DateTime.now(),
      );
      controller.homeOwners.add(tenantUnit);

      final success = await controller.updateHomeOwner(
        unitId: 'unit-tenant-clear-test',
        removeTenant: true,
      );

      expect(success, isTrue);
      final updated = controller.homeOwners.firstWhere((h) => h.unitId == 'unit-tenant-clear-test');
      expect(updated.tenantFullName, isNull);
      expect(updated.occupancyStatus, equals('VACANT'));
    });

    test('DashboardController deleteHouseholdMember removes member from unit', () async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final unitWithMember = HomeOwnerItem(
        unitId: 'unit-member-test',
        siteId: 'site-1',
        block: 'B',
        unitNo: 8,
        floor: 2,
        ownerFullName: 'Mehmet Yılmaz',
        email: 'mehmet@example.com',
        phone: '0532 111 22 33',
        occupancyStatus: 'OWNER_OCCUPIED',
        landShare: '1/24',
        monthlyDues: Decimal.parse('1200.00'),
        isResident: true,
        mustChangePassword: false,
        createdAt: DateTime.now(),
        householdResidents: const [
          UnitResidentMember(
            id: 'mem-101',
            fullName: 'Sakin Kardeş',
            relationship: 'Kardeşi',
          ),
        ],
      );
      controller.homeOwners.add(unitWithMember);

      final success = await controller.deleteHouseholdMember(
        unitId: 'unit-member-test',
        residentId: 'mem-101',
      );

      expect(success, isTrue);
      final updated = controller.homeOwners.firstWhere((h) => h.unitId == 'unit-member-test');
      expect(updated.householdResidents.any((m) => m.id == 'mem-101'), isFalse);
    });

    // REQ-042: the residents tab only lists units; every action runs in the owners & residents
    // module workspace, whose pages reference person cards instead of person text inputs.
    Future<HomeOwnerItem> openResidentsTab(WidgetTester tester, DashboardController controller) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(controller: controller)));
      await tester.pumpAndSettle();
      final residentsTab = find.text('Sakinler & Malikler');
      await tester.ensureVisible(residentsTab);
      await tester.pumpAndSettle();
      await tester.tap(residentsTab);
      await tester.pumpAndSettle();
      return controller.homeOwners.first;
    }

    Future<void> tapWorkspaceAction(WidgetTester tester, String action, String unitId) async {
      final row = find.byKey(Key('workspace_action_${action}_$unitId'));
      await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    // covers: SC-12-06-04
    testWidgets('Residents tab lists units and opens their actions in the module workspace', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final unit = await openResidentsTab(tester, controller);
      expect(find.text('Kat Malikleri & Sakinler Yönetimi'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget); // the search field only
      final actions = find.byKey(Key('module_unit_actions_${unit.unitId}'));
      expect(actions, findsOneWidget);

      await tester.ensureVisible(actions);
      await tester.pumpAndSettle();
      await tester.tap(actions);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace_actions')), findsOneWidget);

      await tapWorkspaceAction(tester, 'edit_owner', unit.unitId);
      expect(find.text('Sakin Bilgilerini Düzenle'), findsOneWidget);
      for (final label in ['Ad Soyad', 'Telefon', 'E-posta']) {
        expect(find.widgetWithText(TextField, label), findsNothing, reason: label);
      }
    });

    testWidgets('Residents tab details open the unit information in the module workspace', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final unit = await openResidentsTab(tester, controller);
      final details = find.byKey(Key('module_unit_details_${unit.unitId}'));
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace_information')), findsOneWidget);
    });

    testWidgets('Site Manager deletes a unit from the module workspace opened on the residents tab', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final unit = await openResidentsTab(tester, controller);
      final actions = find.byKey(Key('module_unit_actions_${unit.unitId}'));
      await tester.ensureVisible(actions);
      await tester.pumpAndSettle();
      await tester.tap(actions);
      await tester.pumpAndSettle();

      await tapWorkspaceAction(tester, 'delete', unit.unitId);
      await tester.tap(find.text('Evet, Sil'));
      await tester.pumpAndSettle();
      expect(controller.homeOwners.any((h) => h.unitId == unit.unitId), isFalse);
    });

    testWidgets('Resident search clear button resets field text and filter query', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      await openResidentsTab(tester, controller);

      final searchField = find.byKey(const Key('resident_search_field'));
      expect(searchField, findsOneWidget);

      await tester.enterText(searchField, 'Z-999-ABSENT');
      await tester.pumpAndSettle();

      final clearBtn = find.byKey(const Key('resident_search_clear_btn'));
      expect(clearBtn, findsOneWidget);

      await tester.tap(clearBtn);
      await tester.pumpAndSettle();

      final TextField field = tester.widget(searchField);
      expect(field.controller?.text, isEmpty);
      expect(find.byKey(const Key('resident_search_clear_btn')), findsNothing);
    });
  });
}
