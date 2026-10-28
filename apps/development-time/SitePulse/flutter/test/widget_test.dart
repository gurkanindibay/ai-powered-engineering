import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/main.dart';
import 'package:sitepulse/ui/components/payment_checkout_dialog.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'test_fixtures.dart';

DashboardController _createTestController({bool startAuthenticated = false}) {
  final controller = DashboardController(startAuthenticated: startAuthenticated);
  controller.loadTestFixtures();
  return controller;
}

void main() {
  testWidgets('SitePulseApp renders LoginScreen when unauthenticated and displays test personas', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: false);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify Login Screen branding and persona section
    expect(find.text('SitePulse'), findsOneWidget);
    expect(find.text('Test Kullanıcıları ile Hızlı Giriş'), findsOneWidget);
    expect(find.text('SaaS Platform Admin'), findsWidgets);
    expect(find.text('Site Yöneticisi'), findsWidgets);
    expect(find.text('Kat Maliki (Ev Sahibi)'), findsWidgets);
    expect(find.text('Ev Sakini (Aile / Kiracı)'), findsWidgets);
    expect(find.text('Kat Maliki Olarak Gir'), findsOneWidget);
  });

  testWidgets('Selecting Site Admin shows dual path options and logging in as Kat Maliki enters own flat view', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: false);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify dual path options appear on Site Manager card
    final myFlatOption = find.textContaining('🏠 Kendi Dairem (Kat Maliki)');
    expect(myFlatOption, findsOneWidget);

    // Scroll to option and tap it
    await tester.ensureVisible(myFlatOption);
    await tester.pumpAndSettle();
    await tester.tap(myFlatOption);
    await tester.pumpAndSettle();

    // Tap login button for own flat
    final loginButton = find.text('Kendi Dairem ile Başla (B Blok D:1)');
    expect(loginButton, findsOneWidget);
    await tester.ensureVisible(loginButton);
    await tester.pumpAndSettle();
    await tester.tap(loginButton);
    await tester.pumpAndSettle();

    // Verify Mehmet Demir entered his own flat view
    expect(controller.isAuthenticated, isTrue);
    expect(controller.siteAdminPath, SiteAdminActivePath.myFlatOwner);
    expect(find.text('Kendi Dairem (Kat Maliki)'), findsWidgets);
    expect(find.textContaining('B Blok D:1'), findsWidgets);
    expect(find.text('Mehmet Demir'), findsWidgets);

    // Test AppBar logout button returns to LoginScreen
    final logoutButton = find.byTooltip('Çıkış Yap / Rol Değiştir');
    expect(logoutButton, findsOneWidget);
    await tester.tap(logoutButton);
    await tester.pumpAndSettle();

    expect(controller.isAuthenticated, isFalse);
    expect(find.text('Test Kullanıcıları ile Hızlı Giriş'), findsOneWidget);
  });

  testWidgets('Logging in as Site Admin with Cockpit path displays complex collection cockpit', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: false);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Default path is managerCockpit
    final loginButton = find.text('Yönetici Paneli ile Başla');
    expect(loginButton, findsOneWidget);
    await tester.ensureVisible(loginButton);
    await tester.pumpAndSettle();
    await tester.tap(loginButton);
    await tester.pumpAndSettle();

    expect(controller.isAuthenticated, isTrue);
    expect(controller.siteAdminPath, SiteAdminActivePath.managerCockpit);
    expect(find.text('Eylül 2026 Tahsilat Durumu'), findsOneWidget);
    expect(find.text('₺0 Borç — Güncel'), findsOneWidget);
    expect(find.text('Onay Bekleyen Başvurular'), findsOneWidget);
  });

  testWidgets('SitePulseApp renders Home Owner dashboard cleanly without Virtual IBAN cluttering home screen', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify SitePulse branding and Kat Maliki default view
    expect(find.text('SitePulse'), findsOneWidget);
    expect(find.text('Kat Maliki (Ev Sahibi)'), findsWidgets);
    expect(find.text('Ödenecek Toplam Tutar'), findsOneWidget);
    expect(find.text('₺1.423,33'), findsWidgets);
    expect(find.text('Hemen Öde'), findsOneWidget);

    // Verify Virtual IBAN is NOT cluttering the home screen feed
    expect(find.text('Daireye Özel Sanal IBAN'), findsNothing);
  });

  testWidgets('Tapping Hemen Öde opens PaymentCheckoutDialog with method selection between Card and Virtual IBAN', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Tap "Hemen Öde" on balance card
    final payBtn = find.text('Hemen Öde');
    expect(payBtn, findsOneWidget);
    await tester.tap(payBtn);
    await tester.pumpAndSettle();

    // Verify checkout dialog with payment method selection and free text amount field
    expect(find.text('Aidat Ödeme Adımı'), findsOneWidget);
    expect(find.text('Ödemek İstediğiniz Tutar'), findsOneWidget);
    expect(find.text('Tutar Giriniz (₺)'), findsOneWidget);
    expect(find.text('Ödeme Yöntemini Seçin'), findsOneWidget);
    expect(find.text('Kredi Kartı'), findsOneWidget);
    expect(find.text('Sanal IBAN'), findsOneWidget);
    expect(find.textContaining('3D Secure ile'), findsOneWidget);

    // Enter a custom surplus payment amount in the free text field
    final amountInput = find.widgetWithText(TextField, 'Tutar Giriniz (₺)');
    expect(amountInput, findsOneWidget);
    await tester.enterText(amountInput, '2000.00');
    await tester.pumpAndSettle();

    // Verify dynamic calculation banner displays surplus going to Avans Bakiye
    expect(find.textContaining('avans bakiyenize (Avans Bakiye) aktarılacak'), findsOneWidget);
    expect(find.textContaining('3D Secure ile ₺2000.00 Öde'), findsOneWidget);

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
    expect(find.text('₺2000.00'), findsOneWidget);

    // Dismiss screen using Papara-style chevron return arrow
    final backBtn = find.byIcon(Icons.arrow_back_ios_new_rounded);
    expect(backBtn, findsOneWidget);
    await tester.tap(backBtn);
    await tester.pumpAndSettle();

    expect(find.text('Aidat Ödeme Adımı'), findsNothing);
  });

  testWidgets('Tapping Duyurular and Talep / Arıza action buttons opens respective dialogs', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify simplified ResidentActionsRow eliminates duplicate Aidat Öde
    expect(find.text('Aidat Öde'), findsNothing);

    // Tap "Duyurular"
    final announcementsBtn = find.text('Duyurular');
    expect(announcementsBtn, findsOneWidget);
    await tester.tap(announcementsBtn);
    await tester.pumpAndSettle();

    // Verify announcements dialog opened
    expect(find.text('Site Duyuruları'), findsOneWidget);
    expect(find.text('A ve B Blok Asansör Periyodik Muayenesi'), findsOneWidget);

    // Close dialog
    await tester.tap(find.text('Kapat'));
    await tester.pumpAndSettle();

    // Tap "Talep / Arıza"
    final requestsBtn = find.text('Talep / Arıza');
    expect(requestsBtn, findsOneWidget);
    await tester.tap(requestsBtn);
    await tester.pumpAndSettle();

    // Verify issue report dialog opened
    expect(find.text('Yönetime Talep & Arıza'), findsOneWidget);
    expect(find.text('Talebi Gönder'), findsOneWidget);
  });

  testWidgets('Tapping Dekontlar action button opens receipts dialog aligned with account transactions and allows opening receipt detail', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify Dekontlar button exists in ResidentActionsRow
    final dekontlarBtn = find.text('Dekontlar');
    expect(dekontlarBtn, findsOneWidget);
    await tester.tap(dekontlarBtn);
    await tester.pumpAndSettle();

    // Verify receipts dialog title and that it displays credit transactions from accountTransactions
    expect(find.text('Ödeme Makbuzları & Dekontlar'), findsOneWidget);
    final firstCreditTx = controller.accountTransactions.firstWhere((t) => t.isCredit);
    expect(find.text(firstCreditTx.title), findsWidgets);
    expect(find.text(firstCreditTx.amountStr), findsWidgets);

    // Tap on a receipt item to view official receipt details
    final viewBtn = find.text('Görüntüle').first;
    await tester.tap(viewBtn);
    await tester.pumpAndSettle();

    expect(find.text('Ödeme Dekontu Detayı'), findsOneWidget);
    expect(find.text('TAHSİLAT MAKBUZU'), findsOneWidget);
    expect(find.text('ONAYLANDI'), findsOneWidget);

    // Close detail dialog
    await tester.tap(find.text('Kapat'));
    await tester.pumpAndSettle();
  });

  testWidgets('Tapping Hesap Özeti button when debt is zero and advance is present opens dynamic account balance summary dialog', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: true);
    // Pay off debt and load advance
    controller.recordHomeownerPayment(
      block: 'A',
      unitNo: 14,
      amount: Decimal.parse('2000.00'),
    );

    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify Avans Yükle and Hesap Özeti buttons appear
    expect(find.text('Avans Yükle'), findsOneWidget);
    final hesapOzetiBtn = find.text('Hesap Özeti');
    expect(hesapOzetiBtn, findsOneWidget);

    // Tap Hesap Özeti
    await tester.tap(hesapOzetiBtn);
    await tester.pumpAndSettle();

    // Verify dynamic account and advance balance dialog is rendered
    expect(find.text('Hesap & Bakiye Özeti'), findsOneWidget);
    expect(find.text('Borç Durumu: Güncel'), findsOneWidget);
    expect(find.text('Mevcut Avans Bakiyesi (Alacak)'), findsOneWidget);
    expect(find.textContaining('Avans bakiyeniz, gelecek aylarda yeni aidatlar tahakkuk ettiğinde'), findsOneWidget);
    expect(find.text('DÖNEMSEL AİDAT DURUMU'), findsOneWidget);

    // Close dialog
    await tester.tap(find.text('Kapat'));
    await tester.pumpAndSettle();
  });

  testWidgets('SitePulseApp switches to Site Manager view and displays collection cockpit', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Switch to Site Manager
    controller.switchSessionRole(UserRole.siteManager);
    await tester.pumpAndSettle();

    expect(find.text('Site Yöneticisi'), findsWidgets);
    expect(find.text('Eylül 2026 Tahsilat Durumu'), findsOneWidget);
    expect(find.text('₺0 Borç — Güncel'), findsOneWidget);
    expect(find.text('Onay Bekleyen Başvurular'), findsOneWidget);
    expect(find.byKey(const Key('btn_open_unified_dues_center')), findsOneWidget);
  });

  testWidgets('SitePulseApp switches to SaaS SuperAdmin view and displays platform tenants', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Switch to SaaS Admin
    controller.switchSessionRole(UserRole.saasAdmin);
    await tester.pumpAndSettle();

    expect(find.text('SaaS Platform Admin'), findsWidgets);
    expect(find.text('SitePulse Multi-Tenant Platform'), findsOneWidget);
    expect(find.text('Kayıtlı Siteler & Yöneticiler'), findsOneWidget);
    expect(find.text('Begonya Sitesi'), findsOneWidget);
    expect(find.text('Kardelen Rezidans'), findsOneWidget);
  });

  testWidgets('SitePulseApp toggles theme mode between Dark and Light correctly', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Default theme is dark
    expect(controller.isDarkMode, isTrue);

    // Toggle to Light mode
    controller.toggleTheme();
    await tester.pumpAndSettle();

    expect(controller.isDarkMode, isFalse);
    expect(find.text('SitePulse'), findsOneWidget);
    expect(find.text('₺1.423,33'), findsWidgets);

    // Toggle back to Dark mode
    controller.toggleTheme();
    await tester.pumpAndSettle();

    expect(controller.isDarkMode, isTrue);
  });

  testWidgets('SitePulseApp opens Yeni Site dialog, submits and closes popup cleanly', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Switch to SaaS Admin
    controller.switchSessionRole(UserRole.saasAdmin);
    await tester.pumpAndSettle();

    // Tap "Yeni Site Kaydet" button
    final addSiteBtn = find.text('Yeni Site Kaydet');
    expect(addSiteBtn, findsOneWidget);
    await tester.tap(addSiteBtn);
    await tester.pumpAndSettle();

    // Verify Add Site Dialog is opened
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

    // Verify the input popup is closed
    expect(find.text('Yeni Site / Kompleks Kaydet'), findsNothing);

    // Verify the provisioned credentials dialog appears
    expect(find.text('Yeni Site & Yönetici Hazır!'), findsOneWidget);
    expect(find.textContaining('Nilüfer Sitesi başarıyla platforma kaydedildi.'), findsOneWidget);

    // Tap "Tamam" to dismiss credentials dialog
    await tester.tap(find.text('Tamam'));
    await tester.pumpAndSettle();

    expect(find.text('Yeni Site & Yönetici Hazır!'), findsNothing);
    expect(find.text('Nilüfer Sitesi'), findsOneWidget);
  });

  testWidgets('SitePulseApp allows deleting an action-free site with confirmation dialog', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Switch to SaaS Admin
    controller.switchSessionRole(UserRole.saasAdmin);
    await tester.pumpAndSettle();

    // Verify Zambak Konutları exists and has "Sil" button
    expect(find.text('Zambak Konutları'), findsOneWidget);
    final deleteButtons = find.text('Sil');
    expect(deleteButtons, findsOneWidget);

    // Scroll until visible and tap "Sil"
    await tester.ensureVisible(deleteButtons);
    await tester.pumpAndSettle();
    await tester.tap(deleteButtons);
    await tester.pumpAndSettle();

    // Verify confirmation dialog
    expect(find.text('Siteyi Sil'), findsOneWidget);
    expect(find.textContaining('Zambak Konutları sitesini platformdan tamamen silmek istediğinize emin misiniz?'), findsOneWidget);

    // Tap "Evet, Sil"
    final confirmBtn = find.text('Evet, Sil');
    expect(confirmBtn, findsOneWidget);
    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();

    // Verify dialog closed and site is removed
    expect(find.text('Siteyi Sil'), findsNothing);
    expect(find.text('Zambak Konutları'), findsNothing);
    expect(find.textContaining('başarıyla silindi.'), findsOneWidget);
  });

  testWidgets('SitePulseApp allows renewing temporary management password with confirmation dialog', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Switch to SaaS Admin
    controller.switchSessionRole(UserRole.saasAdmin);
    await tester.pumpAndSettle();

    // Find "Şifre Yenile" button
    final resetButtons = find.text('Şifre Yenile');
    expect(resetButtons, findsWidgets);

    // Tap first "Şifre Yenile"
    await tester.ensureVisible(resetButtons.first);
    await tester.pumpAndSettle();
    await tester.tap(resetButtons.first);
    await tester.pumpAndSettle();

    // Verify confirmation dialog
    expect(find.text('Geçici Şifre Yenile'), findsOneWidget);
    expect(find.textContaining('yeni bir geçici yönetim şifresi üretilecektir'), findsOneWidget);

    // Tap "Şifreyi Yenile"
    final confirmBtn = find.text('Şifreyi Yenile');
    expect(confirmBtn, findsOneWidget);
    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();

    // Verify renewal credentials dialog is shown
    expect(find.text('Geçici Yönetim Şifresi Yenilendi!'), findsOneWidget);
    expect(find.textContaining('Begonya Sitesi yöneticisi için yeni bir geçici şifre üretildi.'), findsOneWidget);
    expect(find.textContaining('SP-'), findsOneWidget);

    // Tap "Tamam" to dismiss
    await tester.tap(find.text('Tamam'));
    await tester.pumpAndSettle();

    expect(find.text('Geçici Yönetim Şifresi Yenilendi!'), findsNothing);
  });
}
