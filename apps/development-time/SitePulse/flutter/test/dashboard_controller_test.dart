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
  });
}
