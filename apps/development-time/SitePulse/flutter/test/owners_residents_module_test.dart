@Tags(['residents'])
library;
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/dashboard/dashboard_screen.dart';
import 'package:sitepulse/ui/residents/owners_residents_module_page.dart';
import 'test_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Owners & Residents Module Dedicated Tests', () {
    late DashboardController controller;

    setUp(() async {
      controller = DashboardController(isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
      await controller.fetchHomeOwners(siteId: 'site-1');

      // Inject a rented unit with co-residents
      final rentedUnit = HomeOwnerItem(
        unitId: 'unit-rented-kpi',
        siteId: 'site-1',
        block: 'B',
        unitNo: 24,
        floor: 6,
        ownerFullName: 'Kemal Ev Sahibi',
        email: 'kemal.owner@example.com',
        phone: '0532 111 22 33',
        tenantFullName: 'Ayşe Kiracı',
        tenantEmail: 'ayse.tenant@example.com',
        tenantPhone: '0533 444 55 66',
        occupancyStatus: 'TENANT_OCCUPIED',
        landShare: '1/32',
        monthlyDues: Decimal.parse('1600.00'),
        houseType: '2+1',
        isResident: false,
        mustChangePassword: false,
        createdAt: DateTime.now(),
        householdResidents: const [
          UnitResidentMember(
            id: 'mem-kpi-1',
            fullName: 'Mehmet Kiracıoğlu',
            relationship: 'Eşi',
            phone: '0535 777 88 99',
          ),
        ],
      );
      controller.homeOwners.insert(0, rentedUnit);
    });

    testWidgets('OwnersResidentsModulePage renders KPIs, filter chips, and unit cards', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: OwnersResidentsModulePage(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Verify Header & Module Title
      expect(find.text('Kat Malikleri & Sakinler Modülü'), findsOneWidget);
      expect(find.text('${controller.userSession.siteName} • Yönetim ve Operasyon Portalı'), findsOneWidget);

      // Verify KPI Metric Cards
      expect(find.text('Toplam Daire'), findsOneWidget);
      expect(find.text('Kiracılı'), findsWidgets);
      expect(find.text('Malik Mukim'), findsOneWidget);
      expect(find.text('Boş Daire'), findsOneWidget);
      expect(find.text('Hane Sakini'), findsOneWidget);

      // Verify Filter Chips
      expect(find.textContaining('Tümü'), findsWidgets);
      expect(find.text('Tüm Bloklar'), findsOneWidget);
      expect(find.textContaining('Kiracılı'), findsWidgets);
      expect(find.textContaining('Malik Mukim'), findsWidgets);
      expect(find.textContaining('Boş Daire'), findsWidgets);

      // Verify injected unit is present on Sakinler tab
      expect(find.text('Ayşe Kiracı'), findsWidgets);
    });

    testWidgets('Site Manager can navigate to Sakinler & Malikler tab via Cockpit button', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: DashboardScreen(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Find 'Sakin & Malik Listesi' action button in cockpit
      final residentsButton = find.byKey(const Key('btn_cockpit_manage_residents'));
      await tester.ensureVisible(residentsButton);
      await tester.pumpAndSettle();
      expect(residentsButton, findsOneWidget);

      // Tap button to navigate to Sakinler & Malikler tab
      await tester.ensureVisible(residentsButton);
      await tester.pumpAndSettle();
      await tester.tap(residentsButton);
      await tester.pumpAndSettle();

      // Verify navigated to Sakinler & Malikler tab and module button is present
      expect(find.byKey(const Key('open_owners_residents_module')), findsOneWidget);
    });

    testWidgets('Site Manager can open OwnersResidentsModulePage from Yönetim tab header button', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: DashboardScreen(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Tap Sakinler & Malikler tab
      await tester.ensureVisible(find.text('Sakinler & Malikler'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sakinler & Malikler'));
      await tester.pumpAndSettle();

      // Find module button in header
      final moduleBtn = find.byKey(const Key('open_owners_residents_module'));
      expect(moduleBtn, findsOneWidget);

      // Tap module button
      await tester.ensureVisible(moduleBtn);
      await tester.pumpAndSettle();
      await tester.tap(moduleBtn);
      await tester.pumpAndSettle();

      // Verify module is opened
      expect(find.byType(OwnersResidentsModulePage), findsOneWidget);
      expect(find.text('Kat Malikleri & Sakinler Modülü'), findsOneWidget);
    });

    testWidgets('OwnersResidentsModulePage supports designating primary responsible resident', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: OwnersResidentsModulePage(controller: controller),
      ));
      await tester.pumpAndSettle();

      final responsibleBtn = find.byKey(const Key('module_set_responsible_unit-rented-kpi'));
      await tester.ensureVisible(responsibleBtn);
      await tester.pumpAndSettle();
      expect(responsibleBtn, findsOneWidget);

      // Tap button to open primary responsible selection modal
      await tester.ensureVisible(responsibleBtn);
      await tester.pumpAndSettle();
      await tester.tap(responsibleBtn);
      await tester.pumpAndSettle();

      // Verify modal content
      expect(find.text('Aktif Sorumlu Sakini Belirle'), findsOneWidget);
      expect(find.text('Kemal Ev Sahibi'), findsWidgets);

      // Choose Kat Maliki as active responsible
      await tester.ensureVisible(find.text('Kemal Ev Sahibi').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kemal Ev Sahibi').first);
      await tester.pumpAndSettle();

      // Verify controller was updated
      final updated = controller.homeOwners.firstWhere((h) => h.unitId == 'unit-rented-kpi');
      expect(updated.primaryResponsibleRole, equals('OWNER'));
      expect(updated.primaryResponsibleName, equals('Kemal Ev Sahibi'));
    });

    testWidgets('OwnersResidentsModulePage tab switching toggles Sakinler and Kat Maliki views', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: OwnersResidentsModulePage(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Verify tabs on rented unit
      final residentsTabFinder = find.byKey(const Key('module_tab_residents_unit-rented-kpi'));
      final ownerTab = find.byKey(const Key('module_tab_owner_unit-rented-kpi'));
      await tester.ensureVisible(residentsTabFinder);
      await tester.pumpAndSettle();

      expect(residentsTabFinder, findsOneWidget);
      expect(ownerTab, findsOneWidget);

      // Switch to Kat Maliki tab
      await tester.ensureVisible(ownerTab);
      await tester.pumpAndSettle();
      await tester.tap(ownerTab);
      await tester.pumpAndSettle();

      expect(find.text('Kat Maliki (Mülk Sahibi)'), findsWidgets);
      expect(find.byKey(const Key('module_edit_owner_unit-rented-kpi')), findsOneWidget);

      // Switch back to Sakinler tab
      await tester.ensureVisible(residentsTabFinder);
      await tester.pumpAndSettle();
      await tester.tap(residentsTabFinder);
      await tester.pumpAndSettle();

      expect(find.text('Birincil Kiracı'), findsWidgets);
      expect(find.byKey(const Key('module_edit_residents_unit-rented-kpi')), findsOneWidget);
    });

    testWidgets('OwnersResidentsModulePage allows adding co-resident and shows occupancy history', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: OwnersResidentsModulePage(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Find + Hane Sakini button
      final addMemberBtn = find.byKey(const Key('module_add_resident_to_unit-rented-kpi'));
      await tester.ensureVisible(addMemberBtn);
      await tester.pumpAndSettle();
      expect(addMemberBtn, findsOneWidget);

      // Tap + Hane Sakini
      await tester.ensureVisible(addMemberBtn);
      await tester.pumpAndSettle();
      await tester.tap(addMemberBtn);
      await tester.pumpAndSettle();

      expect(find.text('Hane Sakini Ekle'), findsOneWidget);
      // Close modal
      await tester.ensureVisible(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();

      // Find History button
      final historyBtn = find.byKey(const Key('module_history_ho_unit-rented-kpi'));
      await tester.ensureVisible(historyBtn);
      await tester.pumpAndSettle();
      expect(historyBtn, findsOneWidget);

      // Tap history
      await tester.ensureVisible(historyBtn);
      await tester.pumpAndSettle();
      await tester.tap(historyBtn);
      await tester.pumpAndSettle();

      expect(find.text('Daire Sakin & İkamet Tarihçesi'), findsOneWidget);
    });

    testWidgets('OwnersResidentsModulePage allows defining Kat Maliki (Owner) vs Kiracı (Renter) when adding new resident', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: OwnersResidentsModulePage(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Tap Top Bar "Yeni Sakin Ekle" button
      final addResidentBtn = find.byKey(const Key('module_add_new_resident_btn'));
      expect(addResidentBtn, findsOneWidget);
      await tester.ensureVisible(addResidentBtn);
      await tester.pumpAndSettle();
      await tester.tap(addResidentBtn);
      await tester.pumpAndSettle();

      // Verify Fullscreen Page Title and Occupancy Status Selector
      expect(find.text('Yeni Daire / Sakin Tanımla'), findsOneWidget);
      final occupancySelector = find.byKey(const Key('module_occupancy_status_selector'));
      expect(occupancySelector, findsOneWidget);
      expect(find.descendant(of: occupancySelector, matching: find.text('Malik Oturuyor')), findsOneWidget);
      expect(find.descendant(of: occupancySelector, matching: find.text('Daire Kirada')), findsOneWidget);
      expect(find.descendant(of: occupancySelector, matching: find.text('Boş Daire')), findsOneWidget);

      // Verify default is OWNER_OCCUPIED: no tenant fields are rendered
      expect(find.byKey(const Key('module_new_tenant_name')), findsNothing);

      // Fill Kat Maliki and Unit details: Blok B Daire 99
      await tester.enterText(find.byKey(const Key('module_new_resident_unit')), '99');
      await tester.enterText(find.byKey(const Key('module_new_resident_name')), 'Selim Evsahibi');
      await tester.enterText(find.byKey(const Key('module_new_resident_phone')), '0532 888 77 66');
      await tester.enterText(find.byKey(const Key('module_new_resident_email')), 'selim@example.com');
      await tester.pumpAndSettle();

      // Now switch occupancy status to 'Daire Kirada' (Tenant Occupied)
      final tenantSegment = find.descendant(of: occupancySelector, matching: find.text('Daire Kirada'));
      await tester.ensureVisible(tenantSegment);
      await tester.tap(tenantSegment);
      await tester.pumpAndSettle();

      // Verify Kiracı fields appear
      final tenantNameField = find.byKey(const Key('module_new_tenant_name'));
      expect(tenantNameField, findsOneWidget);
      await tester.ensureVisible(tenantNameField);
      await tester.enterText(tenantNameField, 'Canan Kiracı');
      await tester.enterText(find.byKey(const Key('module_new_tenant_phone')), '0533 999 88 77');
      await tester.enterText(find.byKey(const Key('module_new_tenant_email')), 'canan@example.com');
      await tester.pumpAndSettle();

      // Save new resident
      final saveBtn = find.byKey(const Key('module_save_new_resident_btn'));
      await tester.ensureVisible(saveBtn);
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      // Verify unit was registered as TENANT_OCCUPIED with both names
      final registered = controller.homeOwners.firstWhere((h) => h.unitNo == 99);
      expect(registered.tenantFullName, equals('Canan Kiracı'));
      expect(registered.ownerFullName, equals('Selim Evsahibi'));
      expect(registered.occupancyStatus, equals('TENANT_OCCUPIED'));
      expect(registered.isTenantOccupied, isTrue);
    });

    testWidgets('OwnersResidentsModulePage allows defining or switching occupancy mode in Edit dialog', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: OwnersResidentsModulePage(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Open Edit for rented unit
      final editBtn = find.byKey(const Key('module_edit_residents_unit-rented-kpi'));
      await tester.ensureVisible(editBtn);
      await tester.pumpAndSettle();
      await tester.tap(editBtn);
      await tester.pumpAndSettle();

      // Verify Edit dialog contains occupancy mode selector
      expect(find.text('Sakin Bilgilerini Düzenle'), findsOneWidget);
      final roleSelector = find.byKey(const Key('module_edit_occupancy_role_selector'));
      expect(roleSelector, findsOneWidget);
      expect(find.descendant(of: roleSelector, matching: find.text('Kiracı Oturuyor')), findsOneWidget);
      expect(find.descendant(of: roleSelector, matching: find.text('Malik Oturuyor')), findsOneWidget);
      expect(find.descendant(of: roleSelector, matching: find.text('Boş Daire')), findsOneWidget);

      // Switch to Malik Oturuyor (Owner Occupied)
      await tester.ensureVisible(find.descendant(of: roleSelector, matching: find.text('Malik Oturuyor')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: roleSelector, matching: find.text('Malik Oturuyor')));
      await tester.pumpAndSettle();

      // Kiracı fields should now be hidden
      expect(find.text('Kiracı Bilgileri (Fiilen İkamet Eden)'), findsNothing);

      // Save
      await tester.ensureVisible(find.byKey(const Key('module_save_edit_resident_btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('module_save_edit_resident_btn')));
      await tester.pumpAndSettle();

      // Verify in controller that tenant was removed and status switched to OWNER_OCCUPIED
      final updated = controller.homeOwners.firstWhere((h) => h.unitId == 'unit-rented-kpi');
      expect(updated.tenantFullName, isNull);
      expect(updated.occupancyStatus, equals('OWNER_OCCUPIED'));
      expect(updated.isOwnerOccupied, isTrue);
    });

    testWidgets('OwnersResidentsModulePage move-in dialog allows choosing between Kiracı and Kat Maliki', (tester) async {
      // Inject a vacant unit
      final vacantUnit = HomeOwnerItem(
        unitId: 'unit-vacant-test',
        siteId: 'site-1',
        block: 'A',
        unitNo: 50,
        floor: 12,
        ownerFullName: 'Hasan Malik',
        email: 'hasan@example.com',
        phone: '0544 111 22 33',
        occupancyStatus: 'VACANT',
        landShare: '1/24',
        monthlyDues: Decimal.parse('1400.00'),
        houseType: '2+1',
        isResident: false,
        mustChangePassword: false,
        createdAt: DateTime.now(),
      );
      controller.homeOwners.insert(0, vacantUnit);

      await tester.pumpWidget(MaterialApp(
        home: OwnersResidentsModulePage(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Find move-in button on vacant unit card
      final moveInBtn = find.byKey(const Key('module_move_in_unit-vacant-test'));
      await tester.ensureVisible(moveInBtn);
      await tester.pumpAndSettle();
      await tester.tap(moveInBtn);
      await tester.pumpAndSettle();

      // Verify Move-In dialog opens with role selector
      expect(find.text('Yeni Sakin / Giriş (Move-In)'), findsOneWidget);
      final roleSelector = find.byKey(const Key('module_move_in_role_selector'));
      expect(roleSelector, findsOneWidget);
      expect(find.descendant(of: roleSelector, matching: find.text('Kiracı Girişi')), findsOneWidget);
      expect(find.descendant(of: roleSelector, matching: find.text('Kat Maliki Girişi')), findsOneWidget);

      // Select Kat Maliki Girişi
      await tester.ensureVisible(find.descendant(of: roleSelector, matching: find.text('Kat Maliki Girişi')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: roleSelector, matching: find.text('Kat Maliki Girişi')));
      await tester.pumpAndSettle();

      expect(find.text('Kat Maliki Ad Soyad *'), findsOneWidget);
    });

    testWidgets('OwnersResidentsModulePage enforces resident owner exclusivity and saves dynamic co-residents on add form', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: OwnersResidentsModulePage(controller: controller),
      ));
      await tester.pumpAndSettle();

      // Tap Top Bar "Yeni Sakin Ekle" button
      final addResidentBtn = find.byKey(const Key('module_add_new_resident_btn'));
      await tester.ensureVisible(addResidentBtn);
      await tester.pumpAndSettle();
      await tester.tap(addResidentBtn);
      await tester.pumpAndSettle();

      // Verify Fullscreen Page Title and Default Malik Oturuyor state
      expect(find.text('Yeni Daire / Sakin Tanımla'), findsOneWidget);

      // Verify Malik Oturuyor banner is shown and no Kiracı fields are rendered
      expect(find.textContaining('Malik Oturuyor: Kat maliki bu dairede bizzat ikamet etmektedir'), findsOneWidget);
      expect(find.text('2. Kat Maliki (Mülk Sahibi) Bilgileri'), findsOneWidget);
      expect(find.byKey(const Key('module_new_tenant_name')), findsNothing);

      // Verify Hane Sakinleri section is present
      expect(find.textContaining('4. Hane Sakinleri (Birlikte İkamet Eden Bireyler)'), findsOneWidget);
      final addCoResidentBtn = find.byKey(const Key('module_add_co_resident_btn'));
      expect(addCoResidentBtn, findsOneWidget);

      // Fill Kat Maliki fields: Blok A Daire 105
      await tester.enterText(find.byKey(const Key('module_new_resident_unit')), '105');
      await tester.enterText(find.byKey(const Key('module_new_resident_name')), 'Burak Demir');
      await tester.enterText(find.byKey(const Key('module_new_resident_phone')), '0533 123 45 67');
      await tester.enterText(find.byKey(const Key('module_new_resident_email')), 'burak@example.com');
      await tester.pumpAndSettle();

      // Tap "+ Hane Sakini Ekle" to add a co-resident
      await tester.ensureVisible(addCoResidentBtn);
      await tester.tap(addCoResidentBtn);
      await tester.pumpAndSettle();

      // Verify co-resident row appeared
      expect(find.text('Hane Sakini #1'), findsOneWidget);
      expect(find.text('Ad Soyad *'), findsOneWidget);

      // Enter co-resident details (Spouse)
      final coResidentNameField = find.widgetWithText(TextField, 'Ad Soyad *');
      await tester.ensureVisible(coResidentNameField);
      await tester.enterText(coResidentNameField, 'Selin Demir');
      await tester.pumpAndSettle();

      // Save new resident and household co-resident
      final saveBtn = find.byKey(const Key('module_save_new_resident_btn'));
      await tester.ensureVisible(saveBtn);
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      // Verify unit was registered as OWNER_OCCUPIED with Burak Demir
      final registered = controller.homeOwners.firstWhere((h) => h.unitNo == 105);
      expect(registered.ownerFullName, equals('Burak Demir'));
      expect(registered.occupancyStatus, equals('OWNER_OCCUPIED'));
      expect(registered.isResident, isTrue);

      // Verify co-resident Selin Demir was added to unit's householdResidents
      expect(registered.householdResidents.any((m) => m.fullName == 'Selin Demir' && m.relationship == 'SPOUSE'), isTrue);
    });
  });
}

