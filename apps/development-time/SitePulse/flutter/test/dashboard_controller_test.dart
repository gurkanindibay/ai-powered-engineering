import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';

void main() {
  group('DashboardController Unit & Integration Tests', () {
    late DashboardController controller;

    setUp(() {
      controller = DashboardController();
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
      expect(session.fullName, 'Ahmet Yılmaz (Google)');
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

    test('when reset site manager password, generates new temporary password and sets credentials', () {
      final success = controller.resetSiteManagerPassword('site-1');
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

    test('when reset password for non-existent site, returns false', () {
      final success = controller.resetSiteManagerPassword('invalid-site-id');
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
      expect(controller.activeUnit.blok, 'B');
      expect(controller.activeUnit.daireNo, 1);
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
      expect(controller.accountTransactions.first.subtitle, contains('₺1423.33 borç kapatıldı • ₺576.67 avans bakiyenize aktarıldı'));
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
  });
}
