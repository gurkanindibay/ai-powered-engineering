import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/main.dart';
import 'package:sitepulse/ui/components/bank_statement_reconciliation_page.dart';
import 'package:sitepulse/ui/components/payment_checkout_dialog.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'test_fixtures.dart';

DashboardController _createE2EController({bool startAuthenticated = false}) {
  final controller = DashboardController(startAuthenticated: startAuthenticated);
  controller.loadTestFixtures();
  return controller;
}

void main() {
  group('SitePulse End-to-End (E2E) App Quality Verification Tests', () {
    testWidgets('E2E Journey 1: SaaS SuperAdmin Site Lifecycle (Provision, Reset Password, Safe Deletion)', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = _createE2EController(startAuthenticated: false);
      await tester.pumpWidget(SitePulseApp(controller: controller));
      await tester.pumpAndSettle();

      // 1. Verify Login Screen renders test personas
      expect(find.text('SitePulse'), findsOneWidget);
      expect(find.text('Test Kullanıcıları ile Hızlı Giriş'), findsOneWidget);

      // 2. Login as SaaS SuperAdmin directly from persona card
      final saasLoginBtn = find.text('SaaS Paneline Gir');
      expect(saasLoginBtn, findsOneWidget);
      await tester.ensureVisible(saasLoginBtn);
      await tester.pumpAndSettle();
      await tester.tap(saasLoginBtn);
      await tester.pumpAndSettle();

      expect(controller.isAuthenticated, isTrue);
      expect(controller.userRole, UserRole.saasAdmin);
      expect(find.text('Begonya Sitesi'), findsWidgets);

      // 3. Open "Yeni Site Kaydet" Dialog
      final addSiteBtn = find.text('Yeni Site Kaydet');
      expect(addSiteBtn, findsOneWidget);
      await tester.tap(addSiteBtn);
      await tester.pumpAndSettle();

      expect(find.text('Yeni Site / Kompleks Kaydet'), findsOneWidget);

      // Fill in required fields
      final textFields = find.byType(TextField);
      expect(textFields, findsNWidgets(7));
      await tester.enterText(textFields.at(0), 'Nilüfer Sitesi');
      await tester.enterText(textFields.at(4), 'Fatma Demir');

      // Tap "Siteyi Kaydet & Yetkilendir"
      final submitBtn = find.text('Siteyi Kaydet & Yetkilendir');
      expect(submitBtn, findsOneWidget);
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      // Verify provisioned credentials dialog appears and dismiss
      expect(find.text('Yeni Site & Yönetici Hazır!'), findsOneWidget);
      expect(find.textContaining('Nilüfer Sitesi'), findsWidgets);
      await tester.tap(find.text('Tamam'));
      await tester.pumpAndSettle();

      // Verify site was added to the tenant list
      expect(find.text('Nilüfer Sitesi'), findsOneWidget);

      // 4. Test Temporary Password Renewal
      final resetButtons = find.text('Şifre Yenile');
      expect(resetButtons, findsWidgets);
      await tester.ensureVisible(resetButtons.first);
      await tester.pumpAndSettle();
      await tester.tap(resetButtons.first);
      await tester.pumpAndSettle();

      expect(find.text('Geçici Şifre Yenile'), findsOneWidget);
      final confirmResetBtn = find.text('Şifreyi Yenile');
      expect(confirmResetBtn, findsOneWidget);
      await tester.tap(confirmResetBtn);
      await tester.pumpAndSettle();

      expect(find.text('Geçici Yönetim Şifresi Yenilendi!'), findsOneWidget);
      await tester.tap(find.text('Tamam'));
      await tester.pumpAndSettle();

      // 5. Test Deletion of Action-Free Site
      final deleteButtons = find.text('Sil');
      expect(deleteButtons, findsWidgets);
      await tester.ensureVisible(deleteButtons.first);
      await tester.pumpAndSettle();
      await tester.tap(deleteButtons.first);
      await tester.pumpAndSettle();

      expect(find.text('Siteyi Sil'), findsOneWidget);
      final confirmDeleteBtn = find.text('Evet, Sil');
      expect(confirmDeleteBtn, findsOneWidget);
      await tester.tap(confirmDeleteBtn);
      await tester.pumpAndSettle();

      // Verify dialog closed and site is removed from state
      expect(find.text('Siteyi Sil'), findsNothing);
      expect(controller.saasSites.any((s) => s.name == 'Nilüfer Sitesi'), isFalse);

      // 6. Logout and return to clean login screen
      final logoutBtn = find.byTooltip('Çıkış Yap / Rol Değiştir');
      expect(logoutBtn, findsOneWidget);
      await tester.tap(logoutBtn);
      await tester.pumpAndSettle();

      expect(controller.isAuthenticated, isFalse);
    });

    testWidgets('E2E Journey 2: Site Manager Cockpit, Dues Accrual & Automated Reconciliation Flow', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = _createE2EController(startAuthenticated: false);
      await tester.pumpWidget(SitePulseApp(controller: controller));
      await tester.pumpAndSettle();

      // 1. Login as Site Manager (Cockpit mode)
      final managerLoginCard = find.text('Site Yöneticisi');
      expect(managerLoginCard, findsOneWidget);
      await tester.ensureVisible(managerLoginCard);
      await tester.pumpAndSettle();
      await tester.tap(managerLoginCard);
      await tester.pumpAndSettle();

      final enterCockpitBtn = find.text('Yönetici Paneli ile Başla');
      expect(enterCockpitBtn, findsOneWidget);
      await tester.ensureVisible(enterCockpitBtn);
      await tester.pumpAndSettle();
      await tester.tap(enterCockpitBtn);
      await tester.pumpAndSettle();

      expect(controller.isAuthenticated, isTrue);
      expect(controller.userRole, UserRole.siteManager);
      expect(controller.siteAdminPath, SiteAdminActivePath.managerCockpit);

      // 2. Verify Cockpit KPIs and Pending Registrations Queue
      expect(find.text('Eylül 2026 Tahsilat Durumu'), findsOneWidget);
      expect(find.text('Onay Bekleyen Başvurular'), findsOneWidget);
      expect(find.text('Kerem Yılmaz'), findsOneWidget);

      // Approve pending registration (scroll into view first)
      final approveBtn = find.text('Onayla & Şifre Üret').first;
      expect(approveBtn, findsOneWidget);
      await tester.ensureVisible(approveBtn);
      await tester.pumpAndSettle();
      await tester.tap(approveBtn);
      await tester.pumpAndSettle();

      // Dismiss approval modal
      expect(find.text('Başvuru Onaylandı!'), findsOneWidget);
      await tester.tap(find.text('Tamam'));
      await tester.pumpAndSettle();

      // Verify pending registration removed from queue
      expect(controller.pendingRegistrations.any((r) => r.fullName == 'Kerem Yılmaz'), isFalse);
      expect(find.text('kerem.yilmaz@gmail.com'), findsNothing);

      // 3. Switch to Aidat Yönetimi bottom tab
      final duesTab = find.text('Aidat Yönetimi');
      expect(duesTab, findsOneWidget);
      await tester.tap(duesTab);
      await tester.pumpAndSettle();

      expect(find.textContaining('Aidat ve Tahsilat Yönetimi'), findsOneWidget);

      // 4. Test Toplu Aidat Tahakkuku Dialog
      final bulkAccrueBtn = find.text('Toplu Aidat Tahakkuku');
      expect(bulkAccrueBtn, findsOneWidget);
      await tester.tap(bulkAccrueBtn);
      await tester.pumpAndSettle();

      expect(find.text('Toplu Aidat Tahakkuku'), findsWidgets);
      expect(find.textContaining('Mükerrer tahakkuklar sistem tarafından engellenir'), findsOneWidget);
      expect(find.text('Tahakkuk Dönemi:'), findsOneWidget);

      // Trigger accrual
      final executeAccrualBtn = find.widgetWithText(ElevatedButton, 'Tahakkuk Ettir');
      expect(executeAccrualBtn, findsOneWidget);
      await tester.tap(executeAccrualBtn);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);

      // 5. Test Bank Reconciliation Navigation and Segment View
      controller.setReconciliationQueueForTesting(TestFixtures.reconciliationQueue);

      final reconPageBtn = find.textContaining('Daireleri belirlemek için tıklayın.');
      expect(reconPageBtn, findsOneWidget);
      await tester.tap(reconPageBtn);
      await tester.pumpAndSettle();

      // Verify switching to unmatched bank transactions segment
      expect(find.textContaining('Aşağıdaki transferler banka ekstresinde mevcut'), findsOneWidget);

      // 6. Navigate to Fullscreen BankStatementReconciliationPage via Aidat Yönetimi tab
      final duesTabBtn = find.text('Aidat Yönetimi');
      expect(duesTabBtn, findsOneWidget);
      await tester.tap(duesTabBtn);
      await tester.pumpAndSettle();

      final paymentTrackingBtn = find.byKey(const Key('action_payment_tracking'));
      expect(paymentTrackingBtn, findsOneWidget);
      await tester.ensureVisible(paymentTrackingBtn);
      await tester.pumpAndSettle();
      await tester.tap(paymentTrackingBtn);
      await tester.pumpAndSettle();

      // From payment stream segment, open Bank Statement Reconciliation
      final bankReconAction = find.byKey(const Key('btn_stream_upload_bank_statement'));
      expect(bankReconAction, findsOneWidget);
      await tester.ensureVisible(bankReconAction);
      await tester.pumpAndSettle();
      await tester.tap(bankReconAction);
      await tester.pumpAndSettle();

      // Verify navigation to BankStatementReconciliationPage
      expect(find.byType(BankStatementReconciliationPage), findsOneWidget);
      expect(find.text('Excel, CSV veya SWIFT MT940 formatında yükleyin'), findsOneWidget);

      // Return back to Dues Management using back button
      final backBtn = find.byIcon(Icons.arrow_back_ios_new_rounded);
      expect(backBtn, findsOneWidget);
      await tester.tap(backBtn);
      await tester.pumpAndSettle();

      expect(find.byType(BankStatementReconciliationPage), findsNothing);

      // Return back to Cockpit via footer bar
      final homeTab = find.text('Ana Sayfa');
      expect(homeTab, findsOneWidget);
      await tester.tap(homeTab);
      await tester.pumpAndSettle();
    });

    testWidgets('E2E Journey 3: Home Owner Dues Inspection, Payment Checkout & Co-Resident Link Flow', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = _createE2EController(startAuthenticated: false);
      await tester.pumpWidget(SitePulseApp(controller: controller));
      await tester.pumpAndSettle();

      // 1. Login as Kat Maliki (Ahmet Yılmaz)
      final homeOwnerCard = find.text('Kat Maliki (Ev Sahibi)');
      expect(homeOwnerCard, findsOneWidget);
      await tester.ensureVisible(homeOwnerCard);
      await tester.pumpAndSettle();
      await tester.tap(homeOwnerCard);
      await tester.pumpAndSettle();

      final enterHomeOwnerBtn = find.text('Kat Maliki Olarak Gir');
      expect(enterHomeOwnerBtn, findsOneWidget);
      await tester.ensureVisible(enterHomeOwnerBtn);
      await tester.pumpAndSettle();
      await tester.tap(enterHomeOwnerBtn);
      await tester.pumpAndSettle();

      expect(controller.isAuthenticated, isTrue);
      expect(controller.userRole, UserRole.homeOwner);

      // 2. Verify Dues Hero Balance Card details
      expect(find.text('Ödenecek Toplam Tutar'), findsOneWidget);
      expect(find.text('₺1.423,33'), findsWidgets);
      expect(find.textContaining('10 Gün Gecikme'), findsOneWidget);

      // 3. Complete Payment Checkout Flow
      final payBtn = find.text('Hemen Öde');
      expect(payBtn, findsOneWidget);
      await tester.tap(payBtn);
      await tester.pumpAndSettle();

      expect(find.byType(PaymentCheckoutDialog), findsOneWidget);
      expect(find.text('Aidat Ödeme Adımı'), findsOneWidget);

      // Enter payment amount
      final amountInput = find.widgetWithText(TextField, 'Tutar Giriniz (₺)');
      expect(amountInput, findsOneWidget);
      await tester.enterText(amountInput, '1423.33');
      await tester.pumpAndSettle();

      // Switch payment method to Sanal IBAN inside dialog
      final ibanMethodBtn = find.descendant(
        of: find.byType(PaymentCheckoutDialog),
        matching: find.text('Sanal IBAN'),
      );
      await tester.tap(ibanMethodBtn);
      await tester.pumpAndSettle();

      // Verify Virtual IBAN details and instructions are shown with updated amount
      expect(find.text('Dairenize Tanımlı Sanal IBAN'), findsOneWidget);
      expect(find.text('TR12 0006 2000 0000 0000 0014'), findsOneWidget);
      expect(find.text('Kopyala'), findsOneWidget);

      // Dismiss dialog cleanly
      final backBtn = find.byIcon(Icons.arrow_back_ios_new_rounded);
      expect(backBtn, findsOneWidget);
      await tester.tap(backBtn);
      await tester.pumpAndSettle();

      expect(find.byType(PaymentCheckoutDialog), findsNothing);

      // 4. Open Dekontlar (Receipts) Dialog
      final receiptsBtn = find.text('Dekontlar');
      expect(receiptsBtn, findsOneWidget);
      await tester.tap(receiptsBtn);
      await tester.pumpAndSettle();

      expect(find.text('Ödeme Makbuzları & Dekontlar'), findsOneWidget);
      await tester.tap(find.text('Kapat'));
      await tester.pumpAndSettle();

      // 5. Open Hane Sakini Invite Dialog from ResidentActionsRow
      final inviteBtn = find.text('Sakin Davet');
      expect(inviteBtn, findsOneWidget);
      await tester.tap(inviteBtn);
      await tester.pumpAndSettle();

      // Verify invite link generation and scope
      expect(find.text('Hane Sakini Davet Linki'), findsOneWidget);
      expect(find.textContaining('bağımsız bölümüne erişim yetkisi verir'), findsOneWidget);
      await tester.tap(find.text('Kapat'));
      await tester.pumpAndSettle();

      // Verify Household card exists and lists residents
      expect(find.textContaining('Hane Sakinleri'), findsWidgets);
      expect(find.text('Ayşe Demir'), findsOneWidget);
    });

    testWidgets('E2E Journey 4: Site Manager Dual-Path Security Isolation (Cockpit vs My Flat)', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = _createE2EController(startAuthenticated: false);
      await tester.pumpWidget(SitePulseApp(controller: controller));
      await tester.pumpAndSettle();

      // 1. Select Site Manager and choose Kendi Dairem (Kat Maliki)
      final myFlatOption = find.textContaining('🏠 Kendi Dairem (Kat Maliki)');
      expect(myFlatOption, findsOneWidget);
      await tester.ensureVisible(myFlatOption);
      await tester.pumpAndSettle();
      await tester.tap(myFlatOption);
      await tester.pumpAndSettle();

      final loginMyFlatBtn = find.text('Kendi Dairem ile Başla (B Blok D:1)');
      expect(loginMyFlatBtn, findsOneWidget);
      await tester.ensureVisible(loginMyFlatBtn);
      await tester.pumpAndSettle();
      await tester.tap(loginMyFlatBtn);
      await tester.pumpAndSettle();

      // 2. Verify restricted personal flat view
      expect(controller.siteAdminPath, SiteAdminActivePath.myFlatOwner);
      expect(find.text('Kendi Dairem (Kat Maliki)'), findsWidgets);
      expect(find.textContaining('B Blok D:1'), findsWidgets);

      // Verify collection cockpit is NOT showing complex-wide data
      expect(find.text('Onay Bekleyen Başvurular'), findsNothing);

      // 3. Toggle back to Manager Cockpit path
      final switchCockpitBtn = find.textContaining('Yönetimi').first;
      expect(switchCockpitBtn, findsOneWidget);
      await tester.tap(switchCockpitBtn);
      await tester.pumpAndSettle();

      expect(controller.siteAdminPath, SiteAdminActivePath.managerCockpit);
      expect(find.text('Onay Bekleyen Başvurular'), findsOneWidget);
      expect(find.textContaining('Tahsilat Durumu'), findsOneWidget);
    });

    testWidgets('E2E Journey 5: Zero-Data Resiliency and Graceful Recovery', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = _createE2EController(startAuthenticated: true);
      // Put system in zero-data state
      controller.loadZeroDataFixtures(role: UserRole.siteManager);
      controller.setAvailableDuesMonthsForTesting([]);

      await tester.pumpWidget(SitePulseApp(controller: controller));
      await tester.pumpAndSettle();

      // 1. Switch to Aidat Yönetimi under zero periods
      final duesTab = find.text('Aidat Yönetimi');
      expect(duesTab, findsOneWidget);
      await tester.tap(duesTab);
      await tester.pumpAndSettle();

      // Verify zero-data guidance card
      expect(find.text('Henüz Aidat Dönemi Oluşturulmadı'), findsOneWidget);
      expect(find.text('İlk Aidat Dönemini Başlat'), findsOneWidget);

      // 2. Graceful recovery: set months and flats
      controller.setAvailableDuesMonthsForTesting(['Ekim 2026']);
      controller.setSelectedDuesMonthForTesting('Ekim 2026');
      controller.setFlatsForTesting(TestFixtures.flatsList);
      await tester.pumpAndSettle();

      // Verify data rendered cleanly after accrual
      expect(find.text('Henüz Aidat Dönemi Oluşturulmadı'), findsNothing);
      expect(find.textContaining('Ahmet Yılmaz'), findsWidgets);
    });
  });
}
