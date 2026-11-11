@Tags(['finance'])
library;
import 'dart:convert';
import 'dart:typed_data';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/components/bank_statement_reconciliation_page.dart';
import 'package:sitepulse/ui/components/manual_unit_assignment_page.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'test_fixtures.dart';

void main() {
  group('Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02)', () {
    late DashboardController controller;

    setUp(() {
      controller = DashboardController(startAuthenticated: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
    });

    tearDownAll(() async {
      try {
        final url = Uri.parse('http://localhost:8080/api/v1/system/reset-demo-data');
        await http.post(url).timeout(const Duration(seconds: 2));
      } catch (_) {}
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

      // Enter statement line into text field and trigger parse
      await tester.enterText(
        find.byType(TextField),
        'HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33',
      );
      await tester.ensureVisible(find.text('Ekstre Ayrıştır & Daireleri Eşleştir'));
      await tester.tap(find.text('Ekstre Ayrıştır & Daireleri Eşleştir'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('A Blok D:14'));
      // Verify parsed match item
      expect(find.text('A Blok D:14'), findsOneWidget);
      expect(find.text('%100 Güven'), findsOneWidget);
      expect(find.text('ONAY_BEKLIYOR'), findsOneWidget);

      // Tap on confirmation button in bottom bar
      final confirmButton = find.textContaining('Seçilenleri Onayla');
      expect(confirmButton, findsOneWidget);
      await tester.ensureVisible(confirmButton);
      await tester.pumpAndSettle();
      await tester.tap(confirmButton);
      await tester.pumpAndSettle();

      // Verify confirmation dialog and optional message request are presented
      expect(find.text('Eşleştirme ve Tahsilat Onayı'), findsOneWidget);
      expect(find.text('Ev Sahiplerine / Sakinlere Bilgilendirme Mesajı Gönder (Opsiyonel)'), findsOneWidget);

      // Confirm in dialog
      final dialogConfirmBtn = find.text('Onayla ve Kaydet');
      expect(dialogConfirmBtn, findsOneWidget);
      await tester.ensureVisible(dialogConfirmBtn);
      await tester.pumpAndSettle();
      await tester.tap(dialogConfirmBtn);
      await tester.pumpAndSettle();

      // Verify status transitions to ONAYLANDI and host message is recorded
      expect(find.text('ONAYLANDI'), findsOneWidget);
      expect(controller.sentHostMessages.length, 1);
      expect(controller.sentHostMessages.first.residentName, 'Ahmet Yılmaz');
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
      expect(find.textContaining('Eşleşenler'), findsOneWidget);
      expect(find.textContaining('Eşleşmeyenler'), findsOneWidget);
    });

    test('when transaction belongs to already paid flat then marks status as ZATEN_YUKLENDI and prevents double collection', () {
      // Selim Ak (A Blok D:1) is already paid in initial seeded data
      final flatA1 = controller.flatsList.firstWhere((f) => f.block == 'A' && f.unitNo == 1);
      expect(flatA1.isPaid, true);

      const line = 'HAVALE - SELIM AK A BLOK D:1 AIDAT ODEMESI - ₺1.250,00';
      controller.parseBankStatement(line);

      expect(controller.reconciliationQueue.length, 1);
      final item = controller.reconciliationQueue.first;

      expect(item.matchedUnitDesc, 'A Blok D:1');
      expect(item.status, 'ZATEN_YUKLENDI');
      expect(item.isAlreadyUploaded, true);
      expect(item.confidenceScore, 100);
      expect(item.amountMatchesBalance, true);
      expect(item.notes, contains('Daha önce zaten yüklenmiş'));

      // Ensure select all does not include already uploaded items for approval
      final pendingCount = controller.reconciliationQueue.where((q) => q.isPendingApproval).length;
      expect(pendingCount, 0);
    });

    test('when flat is confirmed in one statement, subsequent statement with same unit is flagged as ZATEN_YUKLENDI', () {
      // First statement: A Blok D:14 (Ahmet Yilmaz) is pending
      const line1 = 'HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33';
      controller.parseBankStatement(line1);

      expect(controller.reconciliationQueue.length, 1);
      final firstMatch = controller.reconciliationQueue.first;
      expect(firstMatch.status, 'ONAY_BEKLIYOR');

      // Manager confirms the payment
      controller.confirmReconciliation([firstMatch.matchId]);
      expect(controller.reconciliationQueue.first.isApproved, true);

      // Second statement: Manager uploads statement again or new statement with same payment
      const line2 = 'HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33';
      controller.parseBankStatement(line2);

      expect(controller.reconciliationQueue.length, 1);
      final secondMatch = controller.reconciliationQueue.first;
      expect(secondMatch.status, 'ZATEN_YUKLENDI');
      expect(secondMatch.isAlreadyUploaded, true);
      expect(secondMatch.notes, contains('Daha önce zaten yüklenmiş'));
    });

    test('when confirming reconciliation with optional message then records host notification message', () {
      const line = 'HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33';
      controller.parseBankStatement(line);

      final matchId = controller.reconciliationQueue.first.matchId;
      expect(controller.sentHostMessages, isEmpty);

      const customMsg = 'Sayın Ahmet Yılmaz, Eylül ayı aidatınız tahsil edilmiştir.';
      controller.confirmReconciliation([matchId], optionalHostMessage: customMsg);

      expect(controller.sentHostMessages.length, 1);
      final sent = controller.sentHostMessages.first;
      expect(sent.residentName, 'Ahmet Yılmaz');
      expect(sent.block, 'A');
      expect(sent.unitNo, 14);
      expect(sent.amount, Decimal.parse('1423.33'));
      expect(sent.messageText, customMsg);
      expect(controller.reconciliationSuccessMessage, contains('bilgilendirme mesajı iletildi'));
    });

    testWidgets('when matching host in ManualUnitAssignmentPage, requires confirmation and optional message request', (tester) async {
      const line = '01.07.2026;TXN99;Bilinmeyen Aciklama;1.320,00;TL';
      controller.parseBankStatement(line);
      final item = controller.reconciliationQueue.first;

      ManualAssignmentResult? assignmentResult;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  assignmentResult = await Navigator.push<ManualAssignmentResult>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ManualUnitAssignmentPage(
                        item: item,
                        flats: controller.flatsList,
                      ),
                    ),
                  );
                },
                child: const Text('Open Assignment'),
              ),
            ),
          ),
        ),
      );

      // Open page
      await tester.ensureVisible(find.text('Open Assignment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Assignment'));
      await tester.pumpAndSettle();

      expect(find.text('Manuel Daire Eşleştirme'), findsOneWidget);

      // Tap on a flat to match (e.g. B Blok D:3)
      final flatCard = find.text('B Blok D:3');
      expect(flatCard, findsOneWidget);
      await tester.ensureVisible(flatCard);
      await tester.pumpAndSettle();
      await tester.tap(flatCard);
      await tester.pumpAndSettle();

      // Verify confirmation dialog and optional message request appear
      expect(find.text('Ev Sahibi & Ödeme Eşleştirme Onayı'), findsOneWidget);
      expect(find.text('Ev Sahibine Bilgilendirme Mesajı Gönder (Opsiyonel)'), findsOneWidget);

      // Confirm match
      final confirmBtn = find.text('Eşleştirmeyi Onayla');
      expect(confirmBtn, findsOneWidget);
      await tester.ensureVisible(confirmBtn);
      await tester.pumpAndSettle();
      await tester.tap(confirmBtn);
      await tester.pumpAndSettle();

      // Verify result was returned with optional message enabled
      expect(assignmentResult, isNotNull);
      expect(assignmentResult!.flat.flatDesc, 'B Blok D:3');
      expect(assignmentResult!.sendOptionalMessage, true);
      expect(assignmentResult!.optionalMessageText, contains('aidat ödemeniz'));
    });

    test('fetchBankAccount loads site bank account from API and sets siteBankAccount', () async {
      final previous = ApiClient.transport;
      addTearDown(() => ApiClient.transport = previous);

      ApiClient.transport = MockClient((request) async {
        if (request.url.path == '/api/v1/site-admin/bank-account/site-1') {
          return http.Response(
            json.encode({
              'id': '1',
              'site_id': 'site-1',
              'bank_code': 'KUVEYT_TURK',
              'bank_name': 'Kuveyt Türk Katılım Bankası',
              'iban': 'TR620020500009863791600001',
              'account_holder': 'Begonya Sitesi Yönetimi',
              'statement_format': 'EXCEL',
              'is_active': true,
              'configured_by': 'usr-1',
              'updated_at': '2026-11-01T10:00:00Z',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      final testController = DashboardController(startAuthenticated: true, isTestMode: false);
      expect(testController.siteBankAccount, isNull);

      await testController.fetchBankAccount('site-1');
      expect(testController.siteBankAccount, isNotNull);
      expect(testController.siteBankAccount!.bankCode, 'KUVEYT_TURK');
      expect(testController.siteBankAccount!.statementFormat, 'EXCEL');

      // Now verifying that format rejection works with the loaded account:
      final staBytes = Uint8List.fromList(':20:START\n:61:260915CR1423,33\n:86:AHMET YILMAZ'.codeUnits);
      final success = testController.parseBankStatementFile(
        fileName: 'ekstre.sta',
        bytes: staBytes,
      );
      expect(success, false);
      expect(testController.bankStatementError, contains('Format Reddedildi'));
      expect(testController.bankStatementError, contains('Kuveyt Türk Katılım Bankası'));
    });
  });
}
