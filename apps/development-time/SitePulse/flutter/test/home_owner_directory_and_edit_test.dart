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

      // Tap on Tab 2 ("Yönetim")
      final yonetimTab = find.text('Yönetim');
      expect(yonetimTab, findsOneWidget);
      await tester.tap(yonetimTab);
      await tester.pumpAndSettle();

      // Verify directory header and search bar
      expect(find.text('Kat Malikleri & Sakinler Yönetimi'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      // Verify "Düzenle" button is present on resident cards
      final editButtons = find.text('Düzenle');
      expect(editButtons, findsWidgets);

      // Tap the first "Düzenle" button to open edit modal
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
    });
  });
}
