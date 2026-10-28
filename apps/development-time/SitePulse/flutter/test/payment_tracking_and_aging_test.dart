import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/ui/components/bank_statement_reconciliation_page.dart';
import 'package:sitepulse/ui/components/dues_management_view.dart';
import 'package:sitepulse/ui/components/manager_cockpit_view.dart';
import 'package:sitepulse/ui/components/payment_tracking_page.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'test_fixtures.dart';

void main() {
  group('Payment Tracking & Debt Aging Module Tests', () {
    late DashboardController controller;

    setUp(() {
      controller = DashboardController(startAuthenticated: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
    });

    test('when fetching payment stream in test mode then returns mock stream entries and KPIs', () async {
      await controller.fetchPaymentStream();
      expect(controller.paymentStream, isNotNull);
      final stream = controller.paymentStream!;
      expect(stream.entries.isNotEmpty, isTrue);
      expect(stream.totalCount, stream.entries.length);
      expect(stream.totalVolume.toDouble(), greaterThan(0));

      final first = stream.entries.first;
      expect(first.receiptNumber, contains('TAH-'));
      expect(first.payerName.isNotEmpty, isTrue);
      expect(first.amount.toDouble(), greaterThan(0));
    });

    test('when fetching debt aging report then returns brackets with 0-30, 31-60, and 60+ days', () async {
      await controller.fetchDebtAgingReport();
      expect(controller.debtAgingReport, isNotNull);
      final report = controller.debtAgingReport!;
      expect(report.brackets.isNotEmpty, isTrue);
      expect(report.grandTotal.toDouble(), greaterThan(0));
      expect(report.totalPenalty.toDouble(), greaterThanOrEqualTo(0));

      final firstBracket = report.brackets.first;
      expect(firstBracket.unitLabel.isNotEmpty, isTrue);
      expect(firstBracket.residentName.isNotEmpty, isTrue);
      expect(firstBracket.totalOutstanding.toDouble(), greaterThan(0));
    });

    test('when recording manual cash payment then returns receipt and updates stream', () async {
      final res = await controller.recordManualPayment(
        unitId: 'unit-1',
        payerName: 'Gürkan İndibay',
        payerRole: 'TENANT',
        amount: 1250.00,
        paymentChannel: 'CASH',
        description: 'Elden nakit Ekim 2026 aidatı (Ref: ELDEN-MAKBUZ-001)',
      );

      expect(res, isNotNull);
      expect(res!.receiptNumber, contains('TAH-'));
      expect(res.allocatedPrincipal, Decimal.parse('1250.00'));
      expect(res.payerName, 'Gürkan İndibay');
    });

    test('when executing inter-ledger transfer then returns success and receipt number', () async {
      final res = await controller.executeInterLedgerTransfer(
        unitId: 'unit-2',
        amount: 500.00,
        note: 'Fazla ödenen aidat avansı asansör demirbaşına aktarıldı',
      );

      expect(res, isNotNull);
      expect(res!['success'], isTrue);
      expect(res['receipt_number'], contains('TAH-'));
      expect(res['remaining_advance_balance'], '500.00');
    });

    test('when transferring property ownership then records new owner and freezes old liabilities', () async {
      final res = await controller.transferUnitOwnership(
        unitId: 'unit-3',
        newOwnerName: 'Ahmet YeniMalik',
        newOwnerPhone: '05559998877',
        newOwnerEmail: 'ahmet@yenimalik.com',
        notes: 'Noter Satış Sözleşmesi No: 12345',
      );

      expect(res, isNotNull);
      expect(res!['success'], isTrue);
      expect(res['new_owner_name'], 'Ahmet YeniMalik');
    });

    testWidgets('PaymentTrackingPage renders stream items, aging tabs, and search bar', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await controller.fetchPaymentStream();
      await controller.fetchDebtAgingReport();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaymentTrackingPage(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check header title and KPI summary
      expect(find.text('Tahsilat & Ödeme Takibi'), findsOneWidget);
      expect(find.textContaining('Çok Kanallı Kasa & Yaşlandırma'), findsOneWidget);
      expect(find.text('TOPLAM TAHSİLAT HACMİ'), findsOneWidget);
      expect(find.textContaining('İşlem'), findsWidgets);

      // Check Tabs
      expect(find.text('Tahsilat Akışı (Stream)'), findsOneWidget);
      expect(find.text('Borç Yaşlandırma (Aging)'), findsOneWidget);

      // Check Unified Bank Reconciliation action buttons
      expect(find.byKey(const Key('action_open_bank_reconciliation')), findsOneWidget);
      expect(find.byKey(const Key('btn_stream_upload_bank_statement')), findsOneWidget);

      // Switch to Borç Yaşlandırma Tab
      await tester.tap(find.text('Borç Yaşlandırma (Aging)'));
      await tester.pumpAndSettle();

      expect(find.text('Daire Bazlı Borç Yaşlandırma'), findsOneWidget);
      expect(find.text('KMK %5 Gecikme Zammı'), findsOneWidget);
      expect(find.text('Vadesi Gelmemiş'), findsOneWidget);
    });

    testWidgets('PaymentTrackingPage renders unmatched bank transactions banner and opens reconciliation', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      controller.setReconciliationQueueForTesting([
        ReconciliationQueueItem(
          matchId: 'recon-unmatched-1',
          transaction: BankStatementParsedItem(
            transactionId: 'TXN-UNMATCHED-1',
            date: DateTime.now(),
            senderName: 'Bilinmeyen Gönderen',
            amount: Decimal.parse('850.00'),
            currency: 'TRY',
            description: 'Açıklamasız Havale',
          ),
          status: 'ESLESTIRILEMEDI',
          confidenceScore: 20,
          amountMatchesBalance: false,
        ),
      ]);

      await controller.fetchPaymentStream();
      await controller.fetchDebtAgingReport();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaymentTrackingPage(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check warning banner is rendered
      expect(find.byKey(const Key('banner_unmatched_bank_transactions')), findsOneWidget);
      expect(find.textContaining('Banka Ekstresinde Eşleşme Bekleyen 1 İşlem Var'), findsOneWidget);
      expect(find.byKey(const Key('btn_resolve_unmatched_bank')), findsOneWidget);

      // Tap to open Bank Statement Reconciliation Page
      await tester.tap(find.byKey(const Key('btn_resolve_unmatched_bank')));
      await tester.pumpAndSettle();

      expect(find.byType(BankStatementReconciliationPage), findsOneWidget);
    });

    testWidgets('DuesManagementView contains Tahsilat & Kasa Takibi action button', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

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

      expect(find.byKey(const Key('action_payment_tracking')), findsOneWidget);
    });

    testWidgets('ManagerCockpitView contains Tahsilat & Ödeme Takibi quick action card', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ManagerCockpitView(
                controller: controller,
                onAddResidentTap: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('quick_action_payment_tracking')), findsOneWidget);
    });
  });
}
