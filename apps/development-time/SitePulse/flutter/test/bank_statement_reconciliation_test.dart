import 'dart:typed_data';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/ui/components/bank_statement_reconciliation_page.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';

void main() {
  group('Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02)', () {
    late DashboardController controller;

    setUp(() {
      controller = DashboardController(startAuthenticated: true);
      controller.switchSessionRole(UserRole.siteManager);
    });

    test('when parsing turkish bank excel line then identifies unit A Blok D:14 with 100 percent confidence and exact amount', () {
      const line = 'HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33';

      controller.parseBankStatement(line);

      expect(controller.reconciliationQueue.length, 1);
      final match = controller.reconciliationQueue.first;

      expect(match.matchedUnitDesc, 'A Blok D:14');
      expect(match.matchedBlock, 'A');
      expect(match.matchedUnitNumber, 14);
      expect(match.matchedResidentName, 'Ahmet Yılmaz');
      expect(match.confidenceScore, 100);
      expect(match.transaction.amount, Decimal.parse('1423.33'));
      expect(match.amountMatchesBalance, true);
      expect(match.status, 'ONAY_BEKLIYOR');
    });

    test('when parsing swift mt940 statement with MT940 bank configured then extracts transaction and matches flat', () {
      controller.configureBankAccount(
        bankCode: 'VAKIFBANK',
        iban: 'TR120001500000000000001001',
        accountHolder: 'Begonya Sitesi Yönetimi',
      );

      const mt940 = ':20:STARTMR\n'
          ':25:TR120006200000000000001001\n'
          ':28C:00001/001\n'
          ':60F:C260901TRY50000,00\n'
          ':61:2609150915CR1423,33NTRFNONREF//TXN77889\n'
          ':86:HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT\n'
          ':62F:C260930TRY51423,33\n'
          '-';

      final success = controller.parseBankStatement(mt940);
      expect(success, true);

      expect(controller.reconciliationQueue.length, 1);
      final match = controller.reconciliationQueue.first;

      expect(match.matchedUnitDesc, 'A Blok D:14');
      expect(match.confidenceScore, 100);
      expect(match.transaction.amount, Decimal.parse('1423.33'));
      expect(match.status, 'ONAY_BEKLIYOR');
    });

    test('when file format does not match active bank format then parseBankStatementFile strictly rejects it', () {
      // Default bank is Kuveyt Turk (EXCEL)
      expect(controller.siteBankAccount?.bankCode, 'KUVEYT_TURK');
      expect(controller.siteBankAccount?.statementFormat, 'EXCEL');

      // 1. Upload CSV to EXCEL bank -> Rejected
      final csvBytes = Uint8List.fromList('01.07.2026;TXN1;Ahmet Yilmaz;1423.33;TL'.codeUnits);
      final successCsv = controller.parseBankStatementFile(
        fileName: 'ekstre.csv',
        bytes: csvBytes,
      );
      expect(successCsv, false);
      expect(controller.bankStatementError, contains('Format Reddedildi'));
      expect(controller.bankStatementError, contains('Kuveyt Türk Katılım Bankası'));
      expect(controller.reconciliationQueue, isEmpty);

      // 2. Upload MT940 (.sta) to EXCEL bank -> Rejected
      final staBytes = Uint8List.fromList(':20:START\n:61:260915CR1423,33\n:86:AHMET YILMAZ'.codeUnits);
      final successSta = controller.parseBankStatementFile(
        fileName: 'ekstre.sta',
        bytes: staBytes,
      );
      expect(successSta, false);
      expect(controller.bankStatementError, contains('Format Reddedildi'));
      expect(controller.reconciliationQueue, isEmpty);

      // 3. Upload MT940 text disguised with .xlsx extension -> Rejected
      final fakeXlsxBytes = Uint8List.fromList(':20:FAKE_MT940\n:61:260915CR1423,33\n:86:AHMET YILMAZ'.codeUnits);
      final successFake = controller.parseBankStatementFile(
        fileName: 'fake_ekstre.xlsx',
        bytes: fakeXlsxBytes,
      );
      expect(successFake, false);
      expect(controller.bankStatementError, contains('Format Reddedildi'));
      expect(controller.reconciliationQueue, isEmpty);

      // 4. Change bank to Vakifbank (MT940) and test rejection of Excel/CSV
      controller.configureBankAccount(
        bankCode: 'VAKIFBANK',
        iban: 'TR120001500000000000001001',
        accountHolder: 'Begonya Sitesi Yönetimi',
      );
      expect(controller.siteBankAccount?.statementFormat, 'MT940');

      final successExcelOnMt940 = controller.parseBankStatementFile(
        fileName: 'hesap-ekstresi.xlsx',
        bytes: Uint8List(50),
      );
      expect(successExcelOnMt940, false);
      expect(controller.bankStatementError, contains('Vakıfbank'));
      expect(controller.bankStatementError, contains('SWIFT MT940'));
      expect(controller.reconciliationQueue, isEmpty);
    });

    test('when confirming reconciliation then marks flat as paid and updates collection summary', () {
      const line = 'HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33';
      controller.parseBankStatement(line);

      final matchId = controller.reconciliationQueue.first.matchId;
      final initialPaidCount = controller.collectionSummary.paidUnitsCount;

      controller.confirmReconciliation([matchId]);

      // Check match is approved
      final updatedMatch = controller.reconciliationQueue.firstWhere((m) => m.matchId == matchId);
      expect(updatedMatch.status, 'ONAYLANDI');
      expect(updatedMatch.isApproved, true);

      // Check flat A Blok D:14 is marked as paid
      final flat14 = controller.flatsList.firstWhere((f) => f.unitNo == 14 && f.block == 'A');
      expect(flat14.isPaid, true);
      expect(flat14.paidDateStr, 'Banka Ekstresi');

      // Check collection summary incremented
      expect(controller.collectionSummary.paidUnitsCount, initialPaidCount + 1);
    });

    testWidgets('BankStatementReconciliationPage renders presets, parses statement, and allows batch confirmation', (tester) async {
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => MaterialApp(
            home: Scaffold(
              body: BankStatementReconciliationPage(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify title and subtitle
      expect(find.text('Banka Ekstresi & Eşleştirme'), findsOneWidget);
      expect(find.text('Zero-Approval (Sıfır Onaylı) Akıllı Eşleştirici', findRichText: true).evaluate().isNotEmpty ||
          find.textContaining('Sıfır Onaylı').evaluate().isNotEmpty, isTrue);

      // Verify preset chips
      expect(find.text('Garanti BBVA'), findsOneWidget);
      expect(find.text('İş Bankası CSV'), findsOneWidget);
      expect(find.text('SWIFT MT940'), findsOneWidget);

      // Verify parsed match item
      expect(find.text('A Blok D:14'), findsOneWidget);
      expect(find.text('%100 Güven'), findsOneWidget);
      expect(find.text('ONAY_BEKLIYOR'), findsOneWidget);

      // Tap on confirmation button in bottom bar
      final confirmButton = find.textContaining('Seçilenleri Onayla');
      expect(confirmButton, findsOneWidget);
      await tester.tap(confirmButton);
      await tester.pumpAndSettle();

      // Verify status transitions to ONAYLANDI
      expect(find.text('ONAYLANDI'), findsOneWidget);
    });

    test('when transaction is unmatched, allows manually assigning flat and confirms payment', () {
      // Line with no block or unit info
      const line = '01.07.2026;TXN99;Bilinmeyen Aciklama;1.320,00;TL';
      controller.parseBankStatement(line);

      expect(controller.reconciliationQueue.length, 1);
      final item = controller.reconciliationQueue.first;
      expect(item.confidenceScore, 0);
      expect(item.status, 'ESLESTIRILEMEDI');
      expect(item.matchedUnitDesc, 'Belirlenemedi');

      // Manually assign to B Blok D:3
      controller.manuallyAssignFlatToTransaction(
        matchId: item.matchId,
        block: 'B',
        unitNo: 3,
      );

      final updated = controller.reconciliationQueue.firstWhere((q) => q.matchId == item.matchId);
      expect(updated.confidenceScore, 100);
      expect(updated.status, 'ONAY_BEKLIYOR');
      expect(updated.matchedBlock, 'B');
      expect(updated.matchedUnitNumber, 3);
      expect(updated.matchedUnitDesc, 'B Blok D:3');

      // Confirm reconciliation
      controller.confirmReconciliation([updated.matchId]);
      final confirmed = controller.reconciliationQueue.firstWhere((q) => q.matchId == item.matchId);
      expect(confirmed.status, 'ONAYLANDI');
      expect(confirmed.isApproved, true);

      final flatB3 = controller.flatsList.firstWhere((f) => f.block == 'B' && f.unitNo == 3);
      expect(flatB3.isPaid, true);
    });

    testWidgets('BankStatementReconciliationPage displays intermediate breakdown report and filter tabs', (tester) async {
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => MaterialApp(
            home: Scaffold(
              body: BankStatementReconciliationPage(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Intermediate step report
      expect(find.text('Eşleştirme Analiz Raporu (Ara Adım)'), findsOneWidget);
      expect(find.text('Eşleşen Daireler'), findsOneWidget);
      expect(find.text('Eşleşemeyen'), findsOneWidget);
      expect(find.text('Gider / Masraf'), findsOneWidget);

      // Filter tabs
      expect(find.textContaining('🟢 Eşleşenler'), findsOneWidget);
      expect(find.textContaining('🟠 Eşleşmeyenler'), findsOneWidget);
    });
  });
}
