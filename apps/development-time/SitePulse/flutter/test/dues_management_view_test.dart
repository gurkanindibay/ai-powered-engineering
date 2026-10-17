import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/ui/components/dues_management_view.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/dashboard/dashboard_screen.dart';
import 'test_fixtures.dart';

void main() {
  group('Dues Management Dedicated Tab & Unmatched Bank Pool Tests', () {
    late DashboardController controller;

    setUp(() {
      controller = DashboardController(startAuthenticated: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
    });

    test('when switching dues month then recalculates and displays monthly paid and overdue counts', () {
      expect(controller.selectedDuesMonth, 'Eylül 2026');
      final sepSummary = controller.currentMonthSummary;
      expect(sepSummary.totalUnitsCount, 12);
      expect(sepSummary.paidUnitsCount, 3);
      expect(sepSummary.overdueUnitsCount, 9);

      // Switch to Ağustos 2026
      controller.setSelectedDuesMonth('Ağustos 2026');
      expect(controller.selectedDuesMonth, 'Ağustos 2026');
      final augSummary = controller.currentMonthSummary;
      expect(augSummary.paidUnitsCount, 10);
      expect(augSummary.overdueUnitsCount, 2);

      // Switch to Temmuz 2026
      controller.setSelectedDuesMonth('Temmuz 2026');
      final julSummary = controller.currentMonthSummary;
      expect(julSummary.paidUnitsCount, 11);
      expect(julSummary.overdueUnitsCount, 1);
    });

    test('reconciliation queue identifies unmatched bank transactions in pool', () {
      expect(controller.unmatchedBankCount, 2);
      final unmatched = controller.unmatchedBankTransactions;
      expect(unmatched.length, 2);
      expect(unmatched.first.status, 'ESLESTIRILEMEDI');
      expect(unmatched.first.confidenceScore, 0);

      // Manually match one of them
      controller.manuallyAssignFlatToTransaction(
        matchId: unmatched.first.matchId,
        block: 'A',
        unitNo: 14,
      );

      // Unmatched count drops by 1
      expect(controller.unmatchedBankCount, 1);
    });

    testWidgets('DashboardScreen renders Aidat Yönetimi bottom tab for Site Manager and switches view', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify bottom navigation bar has Aidat Yönetimi tab
      final duesTabFinder = find.text('Aidat Yönetimi');
      expect(duesTabFinder, findsOneWidget);

      // Tap on Aidat Yönetimi tab
      await tester.tap(duesTabFinder);
      await tester.pumpAndSettle();

      // Verify DuesManagementView is displayed with month selector and metrics
      expect(find.text('Eylül 2026'), findsWidgets);
      expect(find.text('Excel / Ekstre Yükle'), findsOneWidget);
      expect(find.text('Eylül 2026 Tahsilat Performansı'), findsOneWidget);
      expect(find.text('Ödeyen Kişi'), findsOneWidget);
      expect(find.text('Ödemeyen / Geciken'), findsOneWidget);

      // Verify dual section segment control
      expect(find.text('📋 Daire Aidat Durumları'), findsOneWidget);
      expect(find.textContaining('🏦 Eşleşmeyenler'), findsOneWidget);

      // Verify alert banner for unmatched bank transfers is visible
      expect(find.textContaining('Banka hesabında henüz daireyle eşleşmemiş'), findsOneWidget);

      // Tap on Unmatched Bank Pool segment
      await tester.tap(find.textContaining('🏦 Eşleşmeyenler'));
      await tester.pumpAndSettle();

      // Verify unmatched cards and Daire Seç & Eşle button
      expect(find.text('Daire Belirlenemedi'), findsWidgets);
      expect(find.text('Daire Seç & Eşle'), findsWidgets);
    });

    testWidgets('DuesManagementView opens intermediate import summary dialog when importing bank file', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DuesManagementView(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap on Excel / Ekstre Yükle button
      await tester.tap(find.text('Excel / Ekstre Yükle'));
      await tester.pumpAndSettle();

      // Verify import options sheet appears
      expect(find.text('Banka Ekstresi / Excel İçe Aktar'), findsOneWidget);
      expect(find.text('Kuveyt Türk Test Ekstresi Yükle'), findsOneWidget);

      // Tap on Kuveyt Türk test preset
      await tester.tap(find.text('Kuveyt Türk Test Ekstresi Yükle'));
      await tester.pumpAndSettle();

      // Verify intermediate result modal appears with breakdown
      expect(find.text('İçe Aktarma Ara Sonucu'), findsOneWidget);
      expect(find.textContaining('Eşleşen Daireler'), findsOneWidget);
      expect(find.textContaining('Eşleşemeyen'), findsOneWidget);
      expect(find.textContaining('Eşleşenleri Onayla & Kaydet'), findsOneWidget);
    });

    testWidgets('DuesManagementView opens Toplu Aidat Tahakkuku confirmation dialog with duplicate prevention note', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DuesManagementView(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap on Toplu Aidat Tahakkuku button
      final accrueBtn = find.text('Toplu Aidat Tahakkuku');
      expect(accrueBtn, findsOneWidget);
      await tester.tap(accrueBtn);
      await tester.pumpAndSettle();

      // Verify dialog is shown
      expect(find.text('Toplu Aidat Tahakkuku'), findsNWidgets(2)); // Button + Dialog Title
      expect(find.text('Tahakkuk Dönemi:'), findsOneWidget);
      expect(find.text('₺1.400,00'), findsOneWidget);
      expect(find.textContaining('Mükerrer tahakkuklar sistem tarafından engellenir'), findsOneWidget);
      expect(find.text('Tahakkuk Ettir'), findsOneWidget);

      // Confirm accrual
      await tester.tap(find.text('Tahakkuk Ettir'));
      await tester.pumpAndSettle();

      // Verify snackbar feedback is displayed
      expect(find.byType(SnackBar), findsOneWidget);
    });
  });
}
