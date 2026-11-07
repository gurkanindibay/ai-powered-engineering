import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'test_fixtures.dart';

void main() {
  group('DashboardController Unit & Integration Tests', () {
    late DashboardController controller;

    setUp(() {
      controller = DashboardController();
      controller.loadTestFixtures();
    });

    tearDownAll(() async {
      try {
        final url = Uri.parse('http://localhost:8080/api/v1/system/reset-demo-data');
        await http.post(url).timeout(const Duration(seconds: 2));
      } catch (_) {}
    });

    test('when initialized, then default role is homeOwner with Begonya Sitesi unit scope', () {
      final session = controller.userSession;
      expect(session.role, UserRole.homeOwner);
      expect(session.unitName, 'A Blok D:14');
      expect(session.siteName, 'Begonya Sitesi');
      expect(session.permissions.any((p) => p.code == 'UNIT_PAY' && p.isGranted), isTrue);
      expect(session.permissions.any((p) => p.code == 'LEDGER_MANAGE_ALL' && p.isGranted), isFalse);
    });

    test('when login as site manager, then sets siteManager role and complex scope permissions', () {
      controller.loginWithPassword('mehmet.demir@begonya.com', 'password123');

      final session = controller.userSession;
      expect(session.role, UserRole.siteManager);
      expect(session.unitName, 'Tüm Kompleks');
      expect(session.permissions.any((p) => p.code == 'LEDGER_MANAGE_ALL' && p.isGranted), isTrue);
      expect(session.permissions.any((p) => p.code == 'RESIDENT_INVITE_SITE' && p.isGranted), isTrue);
      expect(session.permissions.any((p) => p.code == 'RESIDENT_APPROVE' && p.isGranted), isTrue);
    });

    test('when login as saas admin, then sets saasAdmin role and tenant management permissions', () {
      controller.loginWithPassword('admin@sitepulse.io', 'adminpass');

      final session = controller.userSession;
      expect(session.role, UserRole.saasAdmin);
      expect(session.permissions.any((p) => p.code == 'TENANT_MANAGE' && p.isGranted), isTrue);
      expect(session.permissions.any((p) => p.code == 'SITE_MANAGE' && p.isGranted), isTrue);
    });

    test('when login with Google, then authenticates as homeOwner with Google provider', () {
      controller.loginWithGoogle();

      final session = controller.userSession;
      expect(session.role, UserRole.homeOwner);
      expect(session.authProvider, AuthProvider.google);
      expect(session.fullName, 'Google Kullanıcısı');
    });

    test('when register new site, then provisions credentials and adds site to tenant list', () {
      final initialCount = controller.saasSites.length;
      controller.registerNewSite(
        name: 'Nilüfer Vadisi',
        city: 'Bursa',
        address: 'Nilüfer, Çamlık Cad. No:12',
        adminName: 'Serdar Akın',
        adminEmail: 'serdar@nilufervadisi.com',
        adminPhone: '0532 999 88 77',
        planType: 'PREMIUM',
      );

      expect(controller.saasSites.length, initialCount + 1);
      final creds = controller.provisionedCredentials;
      expect(creds, isNotNull);
      expect(creds?.siteName, 'Nilüfer Vadisi');
      expect(creds?.adminEmail, 'serdar@nilufervadisi.com');
      expect(creds!.temporaryPassword.startsWith('SP-'), isTrue);
    });

    test('when updating site information, then persists updated values and notifies listeners', () async {
      final initialSite = controller.saasSites.first;
      final targetId = initialSite.id;

      final result = await controller.updateSite(
        siteId: targetId,
        name: 'Göztepe Park Rezidans',
        city: 'İzmir',
        address: 'Göztepe Mah. Sahil Cad. No:100',
        status: 'ACTIVE',
        planType: 'PRO',
        adminName: 'Ahmet Güncellenmiş',
        adminEmail: 'ahmet.guncel@goztepe.com',
        adminPhone: '0555 444 33 22',
        blocks: ['A Blok', 'B Blok', 'C Blok'],
      );

      expect(result, isTrue);
      final updatedSite = controller.saasSites.firstWhere((s) => s.id == targetId);
      expect(updatedSite.name, 'Göztepe Park Rezidans');
      expect(updatedSite.city, 'İzmir');
      expect(updatedSite.address, 'Göztepe Mah. Sahil Cad. No:100');
      expect(updatedSite.planType, 'PRO');
      expect(updatedSite.adminName, 'Ahmet Güncellenmiş');
      expect(updatedSite.adminEmail, 'ahmet.guncel@goztepe.com');
      expect(updatedSite.adminPhone, '0555 444 33 22');
      expect(updatedSite.blocks, ['A Blok', 'B Blok', 'C Blok']);
    });

    test('when register home owner by manager, then adds flat and issues resident password', () {
      final initialFlatsCount = controller.flatsList.length;
      controller.registerHomeOwner(
        block: 'B Blok',
        unitNo: 12,
        ownerName: 'Caner Yurt',
        email: 'caner@example.com',
        phone: '0543 222 33 44',
        duesAmount: Decimal.parse('1400.00'),
        isResident: true,
      );

      expect(controller.flatsList.length, initialFlatsCount + 1);
      expect(controller.currentMonthFlats.any((f) => f.residentName == 'Caner Yurt'), isTrue);
      final creds = controller.provisionedHomeOwner;
      expect(creds, isNotNull);
      expect(creds?.ownerName, 'Caner Yurt');
      expect(creds!.temporaryPassword.startsWith('SP-SAKIN-'), isTrue);
    });

    test('when approve registration request, then removes from pending queue and generates credentials', () {
      final pending = controller.pendingRegistrations;
      expect(pending.isNotEmpty, isTrue);
      final targetReq = pending.first;

      controller.approveRegistration(targetReq.id);

      expect(controller.pendingRegistrations.any((r) => r.id == targetReq.id), isFalse);
      final success = controller.approvalSuccessInfo;
      expect(success, isNotNull);
      expect(success?.fullName, targetReq.fullName);
      expect(success!.temporaryPassword.startsWith('SP-SAKIN-'), isTrue);
    });

    test('when generate unit invite link, then produces unit-scoped URL', () {
      controller.generateUnitInviteLink();

      final invite = controller.unitInviteInfo;
      expect(invite, isNotNull);
      expect(invite!.inviteUrl.contains('begonya-sitesi/units/d-14'), isTrue);
      expect(invite.token.startsWith('SP-HANE-'), isTrue);
    });

    test('when switch session role, then role and session update immediately', () {
      controller.switchSessionRole(UserRole.siteManager);
      expect(controller.userRole, UserRole.siteManager);
      expect(controller.userSession.role, UserRole.siteManager);

      controller.switchSessionRole(UserRole.saasAdmin);
      expect(controller.userRole, UserRole.saasAdmin);
      expect(controller.userSession.role, UserRole.saasAdmin);

      controller.switchSessionRole(UserRole.homeOwner);
      expect(controller.userRole, UserRole.homeOwner);
      expect(controller.userSession.role, UserRole.homeOwner);
    });

    test('when toggle theme, updates isDarkMode flag', () {
      final initial = controller.isDarkMode;
      controller.toggleTheme();
      expect(controller.isDarkMode, !initial);
    });

    test('when filter flats, applies OVERDUE and PAID filters', () {
      controller.setFlatFilter('OVERDUE');
      expect(controller.flatsList.every((f) => !f.isPaid && f.daysOverdue > 0), isTrue);

      controller.setFlatFilter('PAID');
      expect(controller.flatsList.every((f) => f.isPaid), isTrue);

      controller.setFlatFilter('ALL');
      expect(controller.flatsList.length, greaterThanOrEqualTo(6));
    });

    test('when delete action-free site, then removes site successfully', () {
      // site-3 (Zambak Konutları) has 0 units and 0 collection volume
      expect(controller.canDeleteSite('site-3'), isTrue);

      final success = controller.deleteSite('site-3');
      expect(success, isTrue);
      expect(controller.saasSites.any((s) => s.id == 'site-3'), isFalse);
    });

    test('when delete site with active units or dues, then rejects deletion and preserves site', () {
      // site-1 (Begonya Sitesi) has active units and collection volume
      expect(controller.canDeleteSite('site-1'), isFalse);

      final success = controller.deleteSite('site-1');
      expect(success, isFalse);
      expect(controller.saasSites.any((s) => s.id == 'site-1'), isTrue);
      expect(controller.authMessage, contains('silinemez'));
    });

    test('when reset site manager password, generates new temporary password and sets credentials', () async {
      final success = await controller.resetSiteManagerPassword('site-1');
      expect(success, isTrue);
      expect(controller.provisionedCredentials, isNotNull);
      final creds = controller.provisionedCredentials!;
      expect(creds.siteId, 'site-1');
      expect(creds.adminEmail, 'mehmet.demir@begonya.com');
      expect(creds.temporaryPassword.startsWith('SP-'), isTrue);
      expect(creds.temporaryPassword.endsWith('-PASS'), isTrue);
      expect(creds.isRenewal, isTrue);
      expect(controller.authMessage, contains('yeni geçici şifre üretildi'));
    });

    test('when reset password for non-existent site, returns false', () async {
      final success = await controller.resetSiteManagerPassword('invalid-site-id');
      expect(success, isFalse);
      expect(controller.provisionedCredentials, isNull);
    });

    test('when loginAs called with test personas, updates session and sets isAuthenticated true', () {
      // Login as Site Admin with myFlatOwner path
      controller.loginAs(
        role: UserRole.siteManager,
        adminPath: SiteAdminActivePath.myFlatOwner,
      );

      expect(controller.isAuthenticated, isTrue);
      expect(controller.userRole, UserRole.siteManager);
      expect(controller.siteAdminPath, SiteAdminActivePath.myFlatOwner);
      expect(controller.activeUnit.block, 'B');
      expect(controller.activeUnit.unitNo, 1);
      expect(controller.unitResidents.first.fullName, 'Mehmet Demir');

      // Toggle to managerCockpit path
      controller.toggleSiteAdminPath();
      expect(controller.siteAdminPath, SiteAdminActivePath.managerCockpit);

      // Logout
      controller.logout();
      expect(controller.isAuthenticated, isFalse);
    });

    test('when initialized, then accountTransactions contains initial transactions and formats amounts correctly', () {
      expect(controller.accountTransactions.isNotEmpty, isTrue);
      final firstTx = controller.accountTransactions.first;
      expect(firstTx.title, 'Eylül 2026 Aidatı');
      expect(firstTx.isCredit, isFalse);
      expect(firstTx.amountStr.startsWith('₺'), isTrue);

      final secondTx = controller.accountTransactions[1];
      expect(secondTx.isCredit, isTrue);
      expect(secondTx.amountStr.startsWith('+₺'), isTrue);
    });

    test('when recordHomeownerPayment with exact debt amount, clears debt and marks flat as paid', () {
      // Unit A-14 initial debt is 1423.33
      final initialTxCount = controller.accountTransactions.length;
      final flatBefore = controller.flatsList.firstWhere((f) => f.block == 'A' && f.unitNo == 14);
      expect(flatBefore.isPaid, isFalse);
      expect(flatBefore.amountDue, Decimal.parse('1423.33'));

      controller.recordHomeownerPayment(
        block: 'A',
        unitNo: 14,
        amount: Decimal.parse('1423.33'),
        paymentMethod: 'CREDIT_CARD',
      );

      final flatAfter = controller.flatsList.firstWhere((f) => f.block == 'A' && f.unitNo == 14);
      expect(flatAfter.isPaid, isTrue);
      expect(flatAfter.daysOverdue, 0);
      expect(controller.activeUnit.advancePayment, isNull);
      expect(controller.accountTransactions.length, initialTxCount + 1);
      expect(controller.accountTransactions.first.title, 'Kart ile Aidat Ödemesi');
      expect(controller.accountTransactions.first.subtitle, contains('Aidat borcu başarıyla kapatıldı'));
    });

    test('when recordHomeownerPayment with surplus, clears debt and credits surplus to advance payment', () {
      // Unit A-14 initial debt is 1423.33, pay 2000.00 -> surplus 576.67
      controller.recordHomeownerPayment(
        block: 'A',
        unitNo: 14,
        amount: Decimal.parse('2000.00'),
        paymentMethod: 'CREDIT_CARD',
      );

      final flatAfter = controller.flatsList.firstWhere((f) => f.block == 'A' && f.unitNo == 14);
      expect(flatAfter.isPaid, isTrue);
      expect(controller.activeUnit.advancePayment, Decimal.parse('576.67'));
      expect(controller.accountTransactions.first.title, 'Kart ile Aidat Ödemesi');
      expect(controller.accountTransactions.first.subtitle, contains('₺1.423,33 borç kapatıldı • ₺576,67 avans bakiyenize aktarıldı'));
    });

    test('when recordHomeownerPayment on unit with zero debt, credits entire amount to advance payment', () {
      // First pay the debt in full
      controller.recordHomeownerPayment(
        block: 'A',
        unitNo: 14,
        amount: Decimal.parse('1423.33'),
      );
      expect(controller.activeUnit.advancePayment, isNull);

      // Now send an additional payment of 500.00 when debt is 0
      controller.recordHomeownerPayment(
        block: 'A',
        unitNo: 14,
        amount: Decimal.parse('500.00'),
      );

      expect(controller.activeUnit.advancePayment, Decimal.parse('500.00'));
      expect(controller.accountTransactions.first.title, 'Kart ile Avans Yükleme');
      expect(controller.accountTransactions.first.subtitle, contains('Aktif borç bulunmuyor • Avans bakiyenize aktarıldı'));
    });

    test('when recordHomeownerPayment with partial amount, reduces debt without advance credit', () {
      // Unit A-14 initial debt is 1423.33, pay 500.00 -> remaining debt 923.33
      controller.recordHomeownerPayment(
        block: 'A',
        unitNo: 14,
        amount: Decimal.parse('500.00'),
      );

      final flatAfter = controller.flatsList.firstWhere((f) => f.block == 'A' && f.unitNo == 14);
      expect(flatAfter.isPaid, isFalse);
      expect(flatAfter.amountDue, Decimal.parse('923.33'));
      expect(controller.activeUnit.advancePayment, isNull);
    });

    test('when confirmReconciliation with payment surplus, credits surplus to advance payment', () {
      // Statement for A Blok D:14 with 2000.00 (debt is 1423.33)
      const line = 'HAVALE - AHMET YILMAZ A BLOK D:14 - ₺2.000,00';
      controller.parseBankStatement(line);

      final match = controller.reconciliationQueue.first;
      expect(match.matchedBlock, 'A');
      expect(match.matchedUnitNumber, 14);

      controller.confirmReconciliation([match.matchId]);

      final flatAfter = controller.flatsList.firstWhere((f) => f.block == 'A' && f.unitNo == 14);
      expect(flatAfter.isPaid, isTrue);
      // Surplus: 2000.00 - 1423.33 = 576.67
      expect(controller.activeUnit.advancePayment, Decimal.parse('576.67'));
    });

    test('when confirmReconciliation for flat with no debt, credits full payment to advance payment', () {
      // First clear debt
      controller.recordHomeownerPayment(
        block: 'A',
        unitNo: 14,
        amount: Decimal.parse('1423.33'),
      );

      // Now reconcile a bank statement line of 750.00
      const line = 'HAVALE - AHMET YILMAZ A BLOK D:14 - ₺750,00';
      controller.parseBankStatement(line);

      final match = controller.reconciliationQueue.first;
      controller.confirmReconciliation([match.matchId]);

      expect(controller.activeUnit.advancePayment, Decimal.parse('750.00'));
    });

    test('when managing unit matching criteria, allows viewing, adding IBAN, deleting IBAN, and updating names', () async {
      // Default matching criteria is present
      final criteria = controller.matchingCriteria;
      expect(criteria, isNotNull);
      expect(criteria!.unitId, 'd-14');
      expect(criteria.virtualIban, contains('TR41'));
      expect(criteria.rememberedIbans.isNotEmpty, isTrue);
      expect(criteria.registeredPayerNames, contains('Ahmet Yılmaz'));

      // Add new sender IBAN
      await controller.addSenderIbanToUnit(
        iban: 'TR55 0006 1000 0000 1234 5678 99',
        label: 'İş Bankası - İkinci Hesap',
        bankName: 'İş Bankası',
      );
      final updatedCriteria = controller.matchingCriteria!;
      expect(updatedCriteria.rememberedIbans.any((i) => i.senderIban.contains('TR550006100000001234567899')), isTrue);

      // Delete sender IBAN
      await controller.deleteSenderIbanFromUnit(iban: 'TR550006100000001234567899');
      final afterDelete = controller.matchingCriteria!;
      expect(afterDelete.rememberedIbans.any((i) => i.senderIban.contains('TR550006100000001234567899')), isFalse);

      // Update payer names
      await controller.updateUnitPayerNames(names: ['Ahmet Yılmaz', 'Zeynep Kaya', 'Ali Yılmaz']);
      final afterNames = controller.matchingCriteria!;
      expect(afterNames.registeredPayerNames.length, 3);
      expect(afterNames.registeredPayerNames, contains('Ali Yılmaz'));
    });

    test('when resetAllDemoData invoked, clears advance payments, dues, and transactions for a clean slate', () async {
      // First credit advance payment and mark due as paid
      controller.recordHomeownerPayment(
        block: 'A',
        unitNo: 14,
        amount: Decimal.parse('3000.00'),
      );
      expect(controller.activeUnit.advancePayment, greaterThan(Decimal.zero));

      // Reset for clean slate: 0 debt, 0 advance, 0 transactions, 0 site manager overdue/debt
      final result = await controller.resetAllDemoData();
      expect(result, isTrue);
      expect(controller.activeUnit.advancePayment, Decimal.zero);
      expect(controller.reconciliationQueue, isEmpty);
      expect(controller.duesList, isEmpty);
      expect(controller.accountTransactions, isEmpty);
      expect(controller.primaryDues.totalAmount, Decimal.zero);

      // Verify site manager cockpit & dues management numbers are completely reset to 0
      expect(controller.collectionSummary.totalExpected, Decimal.zero);
      expect(controller.collectionSummary.totalCollected, Decimal.zero);
      expect(controller.collectionSummary.totalOverdueAmount, Decimal.zero);
      expect(controller.collectionSummary.overdueUnitsCount, 0);
      expect(controller.flatsList.every((f) => f.amountDue == Decimal.zero), isTrue);

      // Test accruing test due on demand
      final accrueResult = await controller.accrueTestDue();
      expect(accrueResult, isTrue);

      // Clean up backend to ensure live demo state remains pristine 0
      await controller.resetAllDemoData();
    });

    test('when accruing a new month after reset, preserves exactly 12 flats and accurate dues calculation without defaulting to 24 units or 96000 collected', () async {
      await controller.resetAllDemoData();
      expect(controller.collectionSummary.totalUnitsCount, 12);
      expect(controller.collectionSummary.totalExpected, Decimal.zero);
      expect(controller.collectionSummary.totalCollected, Decimal.zero);

      // Accrue for Haziran 2026 with 1400.00
      await controller.accrueMonthlyDues(
        period: 'Haziran 2026',
        amount: Decimal.parse('1400.00'),
      );

      expect(controller.selectedDuesMonth, 'Haziran 2026');
      expect(controller.collectionSummary.totalUnitsCount, 12);
      expect(controller.collectionSummary.totalExpected, Decimal.parse('16800.00')); // 12 units * 1400
      expect(controller.collectionSummary.totalCollected, Decimal.zero);
      expect(controller.collectionSummary.totalOverdueAmount, Decimal.parse('16800.00'));
      expect(controller.collectionSummary.paidUnitsCount, 0);
      expect(controller.collectionSummary.overdueUnitsCount, 12);

      // Clean up after test
      await controller.resetAllDemoData();
    });
  });
}


