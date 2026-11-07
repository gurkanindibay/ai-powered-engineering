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

    testWidgets('Site Manager can navigate to Yönetim tab and view Home Owners Directory', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      await tester.pumpWidget(MaterialApp(
        home: DashboardScreen(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Tap on Tab 2 ("Sakinler & Malikler")
      final residentsTab = find.text('Sakinler & Malikler');
      expect(residentsTab, findsOneWidget);
      await tester.ensureVisible(residentsTab);
      await tester.pumpAndSettle();
      await tester.tap(residentsTab);
      await tester.pumpAndSettle();

      // Verify directory header and search bar
      expect(find.text('Kat Malikleri & Sakinler Yönetimi'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      // Verify "Düzenle" button is present on resident cards
      final editButtons = find.text('Düzenle');
      expect(editButtons, findsWidgets);

      // Tap the first "Düzenle" button to open edit modal
      await tester.ensureVisible(editButtons.first);
      await tester.pumpAndSettle();
      await tester.tap(editButtons.first);
      await tester.pumpAndSettle();

      // Verify Edit Dialog / Page opened
      expect(find.text('Sakin Bilgilerini Düzenle'), findsOneWidget);
      expect(find.text('Kaydet'), findsOneWidget);

      // Verify dues amount is NOT an editable TextField and is locked to house type
      final allTextFields = tester.widgetList<TextField>(find.byType(TextField));
      for (final tf in allTextFields) {
        expect(tf.decoration?.hintText != '1000.00', isTrue, reason: 'Dues amount should not be an editable TextField');
      }
      expect(find.text('Konut tipine bağlı'), findsOneWidget);
      expect(find.text('Aylık Aidat Tutarı'), findsOneWidget);

      // Verify "Sil" button is present in the edit bottom bar
      expect(find.byKey(const Key('edit_ho_delete_button')), findsOneWidget);
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

    testWidgets('Site Manager can delete home owner via delete button and confirmation modal', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final target = controller.homeOwners.first;

      await tester.pumpWidget(MaterialApp(
        home: DashboardScreen(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Go to Sakinler & Malikler tab
      final residentsTab = find.text('Sakinler & Malikler');
      await tester.ensureVisible(residentsTab);
      await tester.pumpAndSettle();
      await tester.tap(residentsTab);
      await tester.pumpAndSettle();

      // Find the delete icon button for this homeowner
      final deleteBtn = find.byKey(Key('delete_ho_${target.unitId}'));
      expect(deleteBtn, findsOneWidget);

      // Tap delete button
      await tester.ensureVisible(deleteBtn);
      await tester.pumpAndSettle();
      await tester.tap(deleteBtn);
      await tester.pumpAndSettle();

      // Verify confirmation screen is shown
      expect(find.text('Kat Malikini Sil'), findsOneWidget);
      expect(find.text('Evet, Sil'), findsOneWidget);
      expect(find.text('Vazgeç'), findsOneWidget);

      // Confirm deletion
      await tester.ensureVisible(find.text('Evet, Sil'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Evet, Sil'));
      await tester.pumpAndSettle();

      // Verify success snackbar and removal from directory
      expect(find.text('Kat maliki başarıyla silindi.'), findsOneWidget);
      expect(controller.homeOwners.any((h) => h.unitId == target.unitId), isFalse);
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

    testWidgets('Site Manager editing a tenant-occupied unit sees both Tenant and Homeowner fields with correct values', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final tenantUnit = HomeOwnerItem(
        unitId: 'unit-ui-tenant-14',
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
      );
      controller.homeOwners.insert(0, tenantUnit);

      await tester.pumpWidget(MaterialApp(
        home: DashboardScreen(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Go to Sakinler & Malikler tab
      await tester.ensureVisible(find.text('Sakinler & Malikler'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sakinler & Malikler'));
      await tester.pumpAndSettle();

      // Verify card displays tenant Canan Can and owner Yeni Ev Sahibi 2
      expect(find.text('Canan Can'), findsOneWidget);
      expect(find.textContaining('Yeni Ev Sahibi 2'), findsOneWidget);

      // Tap Düzenle on this card
      final editBtn = find.text('Düzenle').first;
      await tester.ensureVisible(editBtn);
      await tester.pumpAndSettle();
      await tester.tap(editBtn);
      await tester.pumpAndSettle();

      // Verify edit page displays both sections
      expect(find.text('Kiracı (Fiilen İkamet Eden Sakin)'), findsOneWidget);
      expect(find.text('Kat Maliki (Ev Sahibi) Bilgileri'), findsOneWidget);

      // Verify fields have initial values
      final tenantNameField = tester.widget<TextField>(find.byKey(const Key('tenant_name_field')));
      expect(tenantNameField.controller?.text, equals('Canan Can'));

      final ownerNameField = tester.widget<TextField>(find.byKey(const Key('owner_name_field')));
      expect(ownerNameField.controller?.text, equals('Yeni Ev Sahibi 2'));

      // Verify quick move-out option in tenant section
      expect(find.text('Kiracıyı Daireden Çıkar (Move-Out)'), findsOneWidget);
    });

    testWidgets('Site Manager clicking delete on tenant unit sees options to remove tenant or delete entire unit', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final tenantUnit = HomeOwnerItem(
        unitId: 'unit-ui-tenant-delete-test',
        siteId: 'site-1',
        block: 'A',
        unitNo: 14,
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
      controller.homeOwners.insert(0, tenantUnit);

      await tester.pumpWidget(MaterialApp(
        home: DashboardScreen(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Go to Sakinler & Malikler tab
      await tester.ensureVisible(find.text('Sakinler & Malikler'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sakinler & Malikler'));
      await tester.pumpAndSettle();

      // Tap delete on this unit
      final deleteBtn = find.byKey(const Key('delete_ho_unit-ui-tenant-delete-test'));
      await tester.ensureVisible(deleteBtn);
      await tester.pumpAndSettle();
      await tester.tap(deleteBtn);
      await tester.pumpAndSettle();

      // Verify option choices are displayed
      expect(find.text('Sakin / Daire Silme Seçenekleri'), findsOneWidget);
      expect(find.text('Sadece Kiracıyı Çıkar / Sil'), findsOneWidget);
      expect(find.text('Tüm Daireyi ve Kat Malikini Sil'), findsOneWidget);
      expect(find.byKey(const Key('remove_tenant_only_button')), findsOneWidget);
      expect(find.byKey(const Key('delete_entire_home_owner_button')), findsOneWidget);
    });

    testWidgets('Rented unit has separate card tabs for Sakinler and Kat Maliki, and allows direct resident editing', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final tenantUnit = HomeOwnerItem(
        unitId: 'unit-dual-tab-test',
        siteId: 'site-1',
        block: 'A',
        unitNo: 14,
        floor: 4,
        ownerFullName: 'Yeni Ev Sahibi 2',
        email: 'owner@example.com',
        phone: '+90 531 456 4545',
        tenantFullName: 'Canan Can',
        tenantEmail: 'canan@example.com',
        tenantPhone: '+90 533 111 22 33',
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
            phone: '+90 533 999 88 77',
          ),
        ],
      );
      controller.homeOwners.insert(0, tenantUnit);

      await tester.pumpWidget(MaterialApp(
        home: DashboardScreen(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Go to Sakinler & Malikler tab
      await tester.ensureVisible(find.text('Sakinler & Malikler'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sakinler & Malikler'));
      await tester.pumpAndSettle();

      // Verify card has dual tabs
      final residentsTab = find.byKey(const Key('tab_residents_unit-dual-tab-test'));
      final ownerTab = find.byKey(const Key('tab_owner_unit-dual-tab-test'));
      expect(residentsTab, findsOneWidget);
      expect(ownerTab, findsOneWidget);

      // By default, Sakinler tab is active
      expect(find.text('Fiilen İkamet Eden Kiracı (Birincil Muhatap)'), findsOneWidget);
      expect(find.byKey(const Key('edit_residents_unit-dual-tab-test')), findsOneWidget);
      expect(find.byKey(const Key('add_resident_to_unit-dual-tab-test')), findsOneWidget);

      // Switch to Kat Maliki tab
      await tester.ensureVisible(ownerTab);
      await tester.pumpAndSettle();
      await tester.tap(ownerTab);
      await tester.pumpAndSettle();

      // Verify Kat Maliki view
      expect(find.text('Kat Maliki (Daire Mülk Sahibi)'), findsOneWidget);
      expect(find.byKey(const Key('edit_owner_unit-dual-tab-test')), findsOneWidget);

      // Switch back to Sakinler tab
      await tester.ensureVisible(residentsTab);
      await tester.pumpAndSettle();
      await tester.tap(residentsTab);
      await tester.pumpAndSettle();
      expect(find.text('Fiilen İkamet Eden Kiracı (Birincil Muhatap)'), findsOneWidget);

      // Tap Sakinleri Düzenle button to open resident editing modal
      final editResidentsBtn = find.byKey(const Key('edit_residents_unit-dual-tab-test'));
      await tester.ensureVisible(editResidentsBtn);
      await tester.pumpAndSettle();
      await tester.tap(editResidentsBtn);
      await tester.pumpAndSettle();

      // Verify modal opened with Sakinler tab active
      expect(find.text('Sakin Bilgilerini Düzenle'), findsOneWidget);
      expect(find.byKey(const Key('dialog_tab_residents')), findsOneWidget);
      expect(find.byKey(const Key('dialog_tab_owner')), findsOneWidget);
      expect(find.byKey(const Key('dialog_tab_all')), findsOneWidget);

      // Modify tenant phone with Turkish +90 format and save
      final tenantPhoneField = find.byKey(const Key('tenant_phone_field'));
      expect(tenantPhoneField, findsOneWidget);
      await tester.enterText(tenantPhoneField, '+90 533 888 77 66');

      final tenantNameField = find.byKey(const Key('tenant_name_field'));
      await tester.enterText(tenantNameField, 'Canan Can Düzenlendi');

      // Tap Kaydet
      await tester.ensureVisible(find.text('Kaydet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();

      // Verify success snackbar and updated details in controller
      expect(find.text('Sakin bilgileri başarıyla güncellendi.'), findsOneWidget);
      final updatedUnit = controller.homeOwners.firstWhere((h) => h.unitId == 'unit-dual-tab-test');
      expect(updatedUnit.tenantFullName, equals('Canan Can Düzenlendi'));
      expect(updatedUnit.tenantPhone, equals('+90 533 888 77 66'));
    });

    testWidgets('Site Manager viewing owner-occupied unit can add new resident via card actions, household header, and edit dialog', (tester) async {
      final controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      final ownerOccupiedUnit = HomeOwnerItem(
        unitId: 'unit-owner-res-test',
        siteId: 'site-1',
        block: 'A',
        unitNo: 1,
        floor: 1,
        ownerFullName: 'Murat Ay',
        email: 'murat@ay.com',
        phone: '0531 345 45 45',
        occupancyStatus: 'OWNER_OCCUPIED',
        landShare: '1/24',
        monthlyDues: Decimal.parse('1000.00'),
        houseType: '1+1',
        isResident: true,
        mustChangePassword: false,
        createdAt: DateTime.now(),
        householdResidents: const [
          UnitResidentMember(
            id: 'mem-ayse',
            fullName: 'Ayşe Ay',
            relationship: 'Eşi',
            phone: '0531 111 22 33',
          ),
        ],
      );
      controller.homeOwners.insert(0, ownerOccupiedUnit);

      await tester.pumpWidget(MaterialApp(
        home: DashboardScreen(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Go to Sakinler & Malikler tab
      await tester.ensureVisible(find.text('Sakinler & Malikler'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sakinler & Malikler'));
      await tester.pumpAndSettle();

      // Verify homeowner Murat Ay and existing household member Ayşe Ay are rendered
      expect(find.textContaining('Murat Ay'), findsWidgets);
      expect(find.textContaining('Ayşe Ay'), findsOneWidget);

      // Verify resident add action buttons are visible on the owner-occupied unit card
      final cardAddMemberBtn = find.byKey(const Key('add_resident_to_unit-owner-res-test'));
      expect(cardAddMemberBtn, findsOneWidget);

      final quickAddResidentBtn = find.byKey(const Key('quick_add_resident_unit-owner-res-test'));
      expect(quickAddResidentBtn, findsOneWidget);

      final sectionAAddResidentBtn = find.byKey(const Key('add_resident_member_to_unit-owner-res-test'));
      expect(sectionAAddResidentBtn, findsOneWidget);

      // Tap + Sakin Ekle in Section C to add a new resident
      await tester.ensureVisible(cardAddMemberBtn);
      await tester.pumpAndSettle();
      await tester.tap(cardAddMemberBtn);
      await tester.pumpAndSettle();

      // Verify modal opened
      expect(find.text('Yeni Hane Sakini Ekle'), findsOneWidget);

      // Enter name for second resident
      final nameField = find.byType(TextField).first;
      await tester.enterText(nameField, 'Oğuz Ay');
      await tester.pumpAndSettle();

      // Save new household resident
      final saveMemberBtn = find.byKey(const Key('household_save_button'));
      expect(saveMemberBtn, findsOneWidget);
      await tester.ensureVisible(saveMemberBtn);
      await tester.pumpAndSettle();
      await tester.tap(saveMemberBtn);
      await tester.pumpAndSettle();

      // Verify second resident is now present under householdResidents in controller
      final updatedHo = controller.homeOwners.firstWhere((h) => h.unitId == 'unit-owner-res-test');
      expect(updatedHo.householdResidents.length, equals(2));
      expect(updatedHo.householdResidents.any((r) => r.fullName == 'Oğuz Ay'), isTrue);

      // Now tap Düzenle on the owner-occupied card
      final editBtn = find.text('Düzenle').first;
      await tester.ensureVisible(editBtn);
      await tester.pumpAndSettle();
      await tester.tap(editBtn);
      await tester.pumpAndSettle();

      // Verify Edit dialog has Hane Sakinleri section with Yeni Sakin Ekle button and Move-In option
      expect(find.text('Sakin Bilgilerini Düzenle'), findsOneWidget);
      expect(find.byKey(const Key('dialog_add_household_member')), findsOneWidget);
      expect(find.byKey(const Key('dialog_move_in_btn')), findsOneWidget);
      expect(find.textContaining('Oğuz Ay'), findsOneWidget);
    });
  });
}

