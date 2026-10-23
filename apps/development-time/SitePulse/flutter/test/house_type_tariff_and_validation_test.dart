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
      await tester.tap(addResidentBtn);
      await tester.pumpAndSettle();

      // Full screen page should be open
      expect(find.text('Yeni Daire / Sakin Ekle'), findsOneWidget);
      expect(find.text('Konut Tipi (Daire Tipi)'), findsOneWidget);

      // Verify that dues amount text field is NOT present, but House Type dropdown and info banner ARE present
      expect(find.text('Aylık Aidat Tutarı (TL)'), findsNothing);
      expect(find.text('₺1000 / ay'), findsWidgets);

      // Attempt to save empty form
      final saveBtn = find.text('Kaydet & Şifre Üret');
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
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      expect(find.text('Geçerli bir e-posta adresi giriniz (örn: sakin@site.com)'), findsOneWidget);

      // Enter valid email and invalid phone
      await tester.enterText(find.widgetWithText(TextField, 'E-posta (Doğrulama zorunlu)'), 'ahmet@example.com');
      await tester.enterText(find.widgetWithText(TextField, 'Telefon (Doğrulama zorunlu)'), '1234');
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      expect(find.text('Geçerli bir telefon numarası giriniz (örn: 0555 123 45 67)'), findsOneWidget);

      // Enter valid phone (Turkish mobile format)
      await tester.enterText(find.widgetWithText(TextField, 'Telefon (Doğrulama zorunlu)'), '0532 555 11 22');
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
      await tester.tap(tariffsBtn);
      await tester.pumpAndSettle();

      // Dialog should be displayed
      expect(find.text('Konut Tipleri & Aidat Tarifeleri'), findsOneWidget);
      expect(find.text('1+1'), findsOneWidget);
      expect(find.text('2+1'), findsOneWidget);
      expect(find.text('3+1'), findsOneWidget);
      expect(find.text('Dublex'), findsOneWidget);
      expect(find.text('₺1800'), findsOneWidget);
    });
  });
}
