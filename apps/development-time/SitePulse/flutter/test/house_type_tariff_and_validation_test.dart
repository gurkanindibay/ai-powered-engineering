@Tags(['finance', 'residents'])
library;
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/dashboard/dashboard_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('House Type & Tariff Configuration Tests', () {
    test('HouseTypeTariff serialization and deserialization roundtrip', () {
      final tariff = HouseTypeTariff(
        id: 'ht-1',
        siteId: 'site-1',
        typeName: '3+1',
        duesAmount: Decimal.parse('1800.00'),
        description: '3 Oda 1 Salon Standart Daire',
      );

      final json = tariff.toJson();
      expect(json['id'], equals('ht-1'));
      expect(json['type_name'], equals('3+1'));
      expect(json['dues_amount'], equals('1800'));

      final fromJson = HouseTypeTariff.fromJson(json);
      expect(fromJson.id, equals(tariff.id));
      expect(fromJson.siteId, equals(tariff.siteId));
      expect(fromJson.typeName, equals('3+1'));
      expect(fromJson.duesAmount, equals(Decimal.parse('1800.00')));
      expect(fromJson.description, equals('3 Oda 1 Salon Standart Daire'));
    });

    test('DashboardController initializes with default site tariffs', () {
      final controller = DashboardController(isTestMode: true);
      controller.switchSessionRole(UserRole.siteManager);

      expect(controller.houseTypes, isNotEmpty);
      expect(controller.houseTypes.any((h) => h.typeName == '1+1'), isTrue);
      expect(controller.houseTypes.any((h) => h.typeName == '2+1'), isTrue);
      expect(controller.houseTypes.any((h) => h.typeName == '3+1'), isTrue);
    });

    test('DashboardController can add, update, and delete house types in test mode', () async {
      final controller = DashboardController(isTestMode: true);
      controller.switchSessionRole(UserRole.siteManager);

      final initialCount = controller.houseTypes.length;

      // Add Villa tariff
      final added = await controller.saveHouseType(
        typeName: 'Villa',
        duesAmount: Decimal.parse('3500.00'),
        description: 'Müstakil Bahçeli Villa',
      );
      expect(added, isTrue);
      expect(controller.houseTypes.length, equals(initialCount + 1));
      final villa = controller.houseTypes.firstWhere((h) => h.typeName == 'Villa');
      expect(villa.duesAmount, equals(Decimal.parse('3500.00')));

      // Update Villa tariff
      await controller.saveHouseType(
        typeName: 'Villa',
        duesAmount: Decimal.parse('4000.00'),
        description: 'Müstakil Villa (Güncellendi)',
      );
      final updatedVilla = controller.houseTypes.firstWhere((h) => h.typeName == 'Villa');
      expect(updatedVilla.duesAmount, equals(Decimal.parse('4000.00')));
      expect(updatedVilla.description, equals('Müstakil Villa (Güncellendi)'));

      // Delete Villa tariff
      final deleted = await controller.deleteHouseType(updatedVilla.id);
      expect(deleted, isTrue);
      expect(controller.houseTypes.any((h) => h.typeName == 'Villa'), isFalse);
    });
  });

  group('Add Resident Dialog Validation & House Type Selection UI Tests', () {
    late DashboardController controller;

    setUp(() {
      controller = DashboardController(isTestMode: true);
      controller.switchSessionRole(UserRole.siteManager);
      controller.setHouseTypesForTesting([
        HouseTypeTariff(id: '1', siteId: 'site-1', typeName: '1+1', duesAmount: Decimal.parse('1000.00')),
        HouseTypeTariff(id: '2', siteId: 'site-1', typeName: '2+1', duesAmount: Decimal.parse('1400.00')),
        HouseTypeTariff(id: '3', siteId: 'site-1', typeName: '3+1', duesAmount: Decimal.parse('1800.00')),
        HouseTypeTariff(id: '4', siteId: 'site-1', typeName: 'Dublex', duesAmount: Decimal.parse('2500.00')),
      ]);
    });

    testWidgets('Manuel Sakin Ekle dialog validates required fields, email and phone', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1024, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap 'Manuel Sakin Ekle' button
      final addResidentBtn = find.text('Manuel Sakin Ekle').first;
      expect(addResidentBtn, findsOneWidget);
      await tester.ensureVisible(addResidentBtn);
      await tester.pumpAndSettle();
      await tester.tap(addResidentBtn);
      await tester.pumpAndSettle();

      // Full screen page should be open
      expect(find.text('Yeni Daire / Sakin Ekle'), findsOneWidget);
      expect(find.text('Konut Tipi (Daire Tipi)'), findsOneWidget);

      // Verify that dues amount text field is NOT present, but House Type dropdown and info banner ARE present
      expect(find.text('Aylık Aidat Tutarı (TL)'), findsNothing);
      expect(find.text('₺1.000,00 / ay'), findsWidgets);

      // Attempt to save empty form
      final saveBtn = find.text('Kaydet & Şifre Üret');
      await tester.ensureVisible(saveBtn);
      await tester.pumpAndSettle();
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      // Expect general error regarding required name/unit
      expect(find.text('Lütfen Sakin Ad Soyad ve Daire No alanlarını doldurunuz.'), findsOneWidget);

      // Fill in Name and Unit
      await tester.enterText(find.widgetWithText(TextField, 'Ad Soyad'), 'Ahmet Yılmaz');
      await tester.enterText(find.widgetWithText(TextField, 'Daire No'), '15');
      await tester.pumpAndSettle();

      // Enter invalid email
      await tester.enterText(find.widgetWithText(TextField, 'E-posta (Doğrulama zorunlu)'), 'invalid-email');
      await tester.ensureVisible(saveBtn);
      await tester.pumpAndSettle();
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      expect(find.text('Geçerli bir e-posta adresi girin (ör. ad@ornek.com).'), findsOneWidget);

      // Enter valid email and invalid phone
      await tester.enterText(find.widgetWithText(TextField, 'E-posta (Doğrulama zorunlu)'), 'ahmet@example.com');
      await tester.enterText(find.widgetWithText(TextField, 'Telefon (Doğrulama zorunlu)'), '1234');
      await tester.ensureVisible(saveBtn);
      await tester.pumpAndSettle();
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      expect(find.text('Geçerli bir cep telefonu girin (ör. 0532 123 45 67).'), findsOneWidget);

      // Enter valid phone (Turkish mobile format)
      await tester.enterText(find.widgetWithText(TextField, 'Telefon (Doğrulama zorunlu)'), '0532 555 11 22');
      await tester.ensureVisible(saveBtn);
      await tester.pumpAndSettle();
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      // Should submit successfully and close the dialog
      expect(find.text('Yeni Daire / Sakin Ekle'), findsNothing);
    });

    testWidgets('Opening Konut Tipleri & Tarifeler dialog displays tariffs and allows management', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1024, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap 'Konut Tipleri & Tarifeler' button
      final tariffsBtn = find.text('Konut Tipleri & Tarifeler').first;
      expect(tariffsBtn, findsOneWidget);
      await tester.ensureVisible(tariffsBtn);
      await tester.pumpAndSettle();
      await tester.tap(tariffsBtn);
      await tester.pumpAndSettle();

      // Dialog should be displayed
      expect(find.text('Konut Tipleri & Aidat Tarifeleri'), findsOneWidget);
      expect(find.text('1+1'), findsOneWidget);
      expect(find.text('2+1'), findsOneWidget);
      expect(find.text('3+1'), findsOneWidget);
      expect(find.text('Dublex'), findsOneWidget);
      expect(find.text('₺1.800,00'), findsOneWidget);
    });

    testWidgets('house type management validates, creates, and deletes a tariff through the UI', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1024, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DashboardScreen(controller: controller))));
      await tester.pumpAndSettle();
      final tariffsButton = find.text('Konut Tipleri & Tarifeler').first;
      await tester.ensureVisible(tariffsButton);
      await tester.pumpAndSettle();
      await tester.tap(tariffsButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yeni Konut Tipi Ekle').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Lütfen Konut Tipi adını giriniz (örn: 2+1, 3+1).'), findsOneWidget);

      await tester.enterText(find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.labelText == 'Konut Tipi Adı (örn: 1+1, 2+1, 3+1, Dubleks)'), 'Penthouse');
      await tester.enterText(find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.labelText == 'Aylık Aidat Tutarı (₺)'), '3250.50');
      await tester.enterText(find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.labelText == 'Açıklama (Opsiyonel)'), 'Üst kat daire');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();

      expect(controller.houseTypes.any((item) => item.typeName == 'Penthouse'), isTrue);
      expect(find.text('Penthouse'), findsOneWidget);
      expect(find.text('Üst kat daire'), findsOneWidget);

      await tester.tap(find.byTooltip('Tarifeyi sil').last);
      await tester.pumpAndSettle();
      expect(find.text('Penthouse tarifesini silmek istediğinize emin misiniz?'), findsOneWidget);
      await tester.tap(find.text('Sil').last);
      await tester.pumpAndSettle();
      expect(controller.houseTypes.any((item) => item.typeName == 'Penthouse'), isFalse);
      expect(find.text('Penthouse'), findsNothing);
    });

    testWidgets('Manuel Sakin Ekle dialog presents blocks in dropdown and allows block selection', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1024, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      controller.setBlocksForTesting(['A Blok', 'B Blok', 'C Blok']);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final addResidentBtn = find.text('Manuel Sakin Ekle').first;
      await tester.ensureVisible(addResidentBtn);
      await tester.pumpAndSettle();
      await tester.tap(addResidentBtn);
      await tester.pumpAndSettle();

      // Verify that block dropdown is present instead of free-text field
      final blockDropdown = find.byKey(const Key('add_resident_block_dropdown'));
      expect(blockDropdown, findsOneWidget);

      // Verify default selection or options
      expect(find.text('A Blok'), findsWidgets);

      // Tap dropdown to open options
      await tester.ensureVisible(blockDropdown);
      await tester.pumpAndSettle();
      await tester.tap(blockDropdown);
      await tester.pumpAndSettle();

      expect(find.text('B Blok'), findsWidgets);
      expect(find.text('C Blok'), findsWidgets);

      // Select B Blok
      await tester.ensureVisible(find.text('B Blok').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('B Blok').last);
      await tester.pumpAndSettle();

      // Fill in remaining fields
      await tester.enterText(find.widgetWithText(TextField, 'Ad Soyad'), 'Zeynep Kaya');
      await tester.enterText(find.widgetWithText(TextField, 'Daire No'), '12');
      await tester.enterText(find.widgetWithText(TextField, 'E-posta (Doğrulama zorunlu)'), 'zeynep@kaya.com');
      await tester.enterText(find.widgetWithText(TextField, 'Telefon (Doğrulama zorunlu)'), '0544 111 22 33');

      final saveBtn = find.text('Kaydet & Şifre Üret');
      await tester.ensureVisible(saveBtn);
      await tester.pumpAndSettle();
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      // Dialog should close successfully
      expect(find.text('Yeni Daire / Sakin Ekle'), findsNothing);
    });

    testWidgets('SaaS Add Site Dialog allows defining blocks list for new site', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1024, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      controller.switchSessionRole(UserRole.saasAdmin);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find "Yeni Site Kaydet" button
      final addSiteBtn = find.text('Yeni Site Kaydet');
      expect(addSiteBtn, findsOneWidget);
      await tester.ensureVisible(addSiteBtn);
      await tester.pumpAndSettle();
      await tester.tap(addSiteBtn);
      await tester.pumpAndSettle();

      expect(find.text('Yeni Site / Kompleks Kaydet'), findsOneWidget);

      // Verify blocks field is present with default value
      final blocksField = find.byKey(const Key('add_site_blocks_field'));
      expect(blocksField, findsOneWidget);
      expect(find.text('A Blok, B Blok'), findsOneWidget);

      // Change blocks to 3 custom blocks
      await tester.enterText(blocksField, '1. Blok, 2. Blok, 3. Blok');
      await tester.enterText(find.widgetWithText(TextField, 'Site / Proje Adı'), 'Çamlıca Konakları');
      await tester.enterText(find.widgetWithText(TextField, 'Yönetici Ad Soyad'), 'Serkan Çetin');
      await tester.enterText(find.widgetWithText(TextField, 'Yönetici E-posta'), 'serkan@camlica.com');

      final submitBtn = find.text('Siteyi Kaydet & Yetkilendir');
      await tester.ensureVisible(submitBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      // Modal closed and new site registered with blocks
      expect(find.text('Yeni Site / Kompleks Kaydet'), findsNothing);
      expect(controller.saasSites.any((s) => s.name == 'Çamlıca Konakları'), isTrue);
      final registered = controller.saasSites.firstWhere((s) => s.name == 'Çamlıca Konakları');
      expect(registered.blocks, equals(['1. Blok', '2. Blok', '3. Blok']));

      // Dismiss credentials dialog if open
      if (find.text('Tamam').evaluate().isNotEmpty) {
        await tester.ensureVisible(find.text('Tamam'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tamam'));
        await tester.pumpAndSettle();
      }
    });
  });
}
