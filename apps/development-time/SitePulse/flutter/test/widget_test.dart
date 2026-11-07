import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/main.dart';
import 'package:sitepulse/ui/components/payment_checkout_dialog.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'test_fixtures.dart';
import 'ui_test_helpers.dart';

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
    final myFlatOption = find.textContaining('Kendi Dairem (Kat Maliki)');
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
    // Logout lives in the profile sheet and asks for confirmation.
    await logOutThroughProfile(tester);

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
    await tester.ensureVisible(payBtn);
    await tester.pumpAndSettle();
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
    expect(find.textContaining('3D Secure ile ₺2.000,00 Öde'), findsOneWidget);

    // Switch payment method to Sanal IBAN inside dialog
    final ibanMethodBtn = find.descendant(
      of: find.byType(PaymentCheckoutDialog),
      matching: find.text('Sanal IBAN'),
    );
    await tester.ensureVisible(ibanMethodBtn);
    await tester.pumpAndSettle();
    await tester.tap(ibanMethodBtn);
    await tester.pumpAndSettle();

    // Verify Virtual IBAN details and instructions are shown with updated amount
    expect(find.text('Dairenize Tanımlı Sanal IBAN'), findsOneWidget);
    expect(find.text('TR12 0006 2000 0000 0000 0014'), findsOneWidget);
    expect(find.text('Kopyala'), findsOneWidget);
    expect(find.text('₺2.000,00'), findsOneWidget);

    // Dismiss screen using Papara-style chevron return arrow
    final backBtn = find.byIcon(Icons.arrow_back_ios_new_rounded);
    expect(backBtn, findsOneWidget);
    await tester.ensureVisible(backBtn);
    await tester.pumpAndSettle();
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
    await tester.ensureVisible(announcementsBtn);
    await tester.pumpAndSettle();
    await tester.tap(announcementsBtn);
    await tester.pumpAndSettle();

    // Verify announcements dialog opened
    expect(find.text('Site Duyuruları'), findsOneWidget);
    expect(find.text('A ve B Blok Asansör Periyodik Muayenesi'), findsOneWidget);

    // Close dialog
    await tester.ensureVisible(find.text('Kapat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kapat'));
    await tester.pumpAndSettle();

    // Tap "Talep / Arıza"
    final requestsBtn = find.text('Talep / Arıza');
    expect(requestsBtn, findsOneWidget);
    await tester.ensureVisible(requestsBtn);
    await tester.pumpAndSettle();
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
    final receiptsButton = find.text('Dekontlar');
    expect(receiptsButton, findsOneWidget);
    await tester.ensureVisible(receiptsButton);
    await tester.pumpAndSettle();
    await tester.tap(receiptsButton);
    await tester.pumpAndSettle();

    // Verify receipts dialog title and that it displays credit transactions from accountTransactions
    expect(find.text('Ödeme Makbuzları & Dekontlar'), findsOneWidget);
    final firstCreditTx = controller.accountTransactions.firstWhere((t) => t.isCredit);
    expect(find.text(firstCreditTx.title), findsWidgets);
    expect(find.text(firstCreditTx.amountStr), findsWidgets);

    // Tap on a receipt item to view official receipt details
    final viewBtn = find.text('Görüntüle').first;
    await tester.ensureVisible(viewBtn);
    await tester.pumpAndSettle();
    await tester.tap(viewBtn);
    await tester.pumpAndSettle();

    expect(find.text('Ödeme Dekontu Detayı'), findsOneWidget);
    expect(find.text('TAHSİLAT MAKBUZU'), findsOneWidget);
    expect(find.text('ONAYLANDI'), findsOneWidget);

    // Close detail dialog
    await tester.ensureVisible(find.text('Kapat'));
    await tester.pumpAndSettle();
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
    final accountSummaryButton = find.text('Hesap Özeti');
    expect(accountSummaryButton, findsOneWidget);

    // Tap Hesap Özeti
    await tester.ensureVisible(accountSummaryButton);
    await tester.pumpAndSettle();
    await tester.tap(accountSummaryButton);
    await tester.pumpAndSettle();

    // Verify dynamic account and advance balance dialog is rendered
    expect(find.text('Hesap & Bakiye Özeti'), findsOneWidget);
    expect(find.text('Borç Durumu: Güncel'), findsOneWidget);
    expect(find.text('Mevcut Avans Bakiyesi (Alacak)'), findsOneWidget);
    expect(find.textContaining('Avans bakiyeniz, gelecek aylarda yeni aidatlar tahakkuk ettiğinde'), findsOneWidget);
    expect(find.text('DÖNEMSEL AİDAT DURUMU'), findsOneWidget);

    // Close dialog
    await tester.ensureVisible(find.text('Kapat'));
    await tester.pumpAndSettle();
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

    // Default follows the system (light in the test environment) until the user picks one.
    expect(controller.themeMode, ThemeMode.system);
    expect(controller.isDarkMode, isFalse);

    // Pick Dark mode
    controller.toggleTheme();
    await tester.pumpAndSettle();
    expect(controller.isDarkMode, isTrue);
    expect(controller.themeMode, ThemeMode.dark);

    // Toggle to Light mode
    controller.toggleTheme();
    await tester.pumpAndSettle();

    expect(controller.isDarkMode, isFalse);
    expect(find.text('SitePulse'), findsOneWidget);
    expect(find.text('₺1.423,33'), findsWidgets);

    // The OS switching to dark does not override an explicit choice...
    controller.updatePlatformBrightness(Brightness.dark);
    await tester.pumpAndSettle();
    expect(controller.isDarkMode, isFalse);

    // ...but once the user goes back to "system", it does.
    controller.setThemeMode(ThemeMode.system);
    await tester.pumpAndSettle();
    expect(controller.isDarkMode, isTrue);
    controller.updatePlatformBrightness(Brightness.light);
    controller.setThemeMode(ThemeMode.system);
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
    await tester.ensureVisible(addSiteBtn);
    await tester.pumpAndSettle();
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
    await tester.ensureVisible(submitBtn);
    await tester.pumpAndSettle();
    await tester.tap(submitBtn);
    await tester.pumpAndSettle();

    // Verify the input popup is closed
    expect(find.text('Yeni Site / Kompleks Kaydet'), findsNothing);

    // Verify the provisioned credentials dialog appears
    expect(find.text('Yeni Site & Yönetici Hazır!'), findsOneWidget);
    expect(find.textContaining('Nilüfer Sitesi başarıyla platforma kaydedildi.'), findsOneWidget);

    // Tap "Tamam" to dismiss credentials dialog
    await tester.ensureVisible(find.text('Tamam'));
    await tester.pumpAndSettle();
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
    await tester.ensureVisible(confirmBtn);
    await tester.pumpAndSettle();
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
    await tester.ensureVisible(confirmBtn);
    await tester.pumpAndSettle();
    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();

    // Verify renewal credentials dialog is shown
    expect(find.text('Geçici Yönetim Şifresi Yenilendi!'), findsOneWidget);
    expect(find.textContaining('Begonya Sitesi yöneticisi için yeni bir geçici şifre üretildi.'), findsOneWidget);
    expect(find.textContaining('SP-'), findsOneWidget);

    // Tap "Tamam" to dismiss
    await tester.ensureVisible(find.text('Tamam'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tamam'));
    await tester.pumpAndSettle();

    expect(find.text('Geçici Yönetim Şifresi Yenilendi!'), findsNothing);
  });

  testWidgets('SitePulseApp allows editing site information from SaaS Admin view', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Switch to SaaS Admin
    controller.switchSessionRole(UserRole.saasAdmin);
    await tester.pumpAndSettle();

    final targetSite = controller.saasSites.first;
    final editBtn = find.byKey(Key('btn_edit_site_${targetSite.id}'));
    expect(editBtn, findsOneWidget);

    await tester.ensureVisible(editBtn);
    await tester.pumpAndSettle();
    await tester.tap(editBtn);
    await tester.pumpAndSettle();

    expect(find.text('${targetSite.name} Bilgilerini Düzenle'), findsOneWidget);

    final nameField = find.byKey(const Key('edit_site_name_field'));
    expect(nameField, findsOneWidget);

    await tester.enterText(nameField, 'Begonya Modern Sitesi');
    await tester.pumpAndSettle();

    final saveBtn = find.byKey(const Key('btn_save_site_edit'));
    expect(saveBtn, findsOneWidget);
    await tester.ensureVisible(saveBtn);
    await tester.pumpAndSettle();
    await tester.tap(saveBtn);
    await tester.pumpAndSettle();

    expect(controller.saasSites.firstWhere((s) => s.id == targetSite.id).name, 'Begonya Modern Sitesi');
    expect(find.text('Begonya Modern Sitesi'), findsWidgets);
  });

  testWidgets('Selecting Kat Maliki Girişi tab renders dedicated Homeowner Login Screen and allows login', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: false);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Tap Kat Maliki Girişi tab
    final homeOwnerTab = find.text('Kat Maliki Girişi');
    expect(homeOwnerTab, findsOneWidget);
    await tester.ensureVisible(homeOwnerTab);
    await tester.pumpAndSettle();
    await tester.tap(homeOwnerTab);
    await tester.pumpAndSettle();

    // Verify dedicated Homeowner screen elements
    expect(find.text('Kat Maliki & Ev Sakini Girişi'), findsOneWidget);
    expect(find.text('E-posta & Şifre ile Kat Maliki Girişi'), findsOneWidget);
    expect(find.text('Kat Maliki Olarak Giriş Yap'), findsOneWidget);
    expect(find.text('Google ile Giriş Yap'), findsOneWidget);

    // Tap login button after scrolling into view
    final loginBtn = find.text('Kat Maliki Olarak Giriş Yap');
    await tester.ensureVisible(loginBtn);
    await tester.pumpAndSettle();
    await tester.tap(loginBtn);
    await tester.pumpAndSettle();

    expect(controller.isAuthenticated, isTrue);
    expect(controller.userRole, UserRole.homeOwner);
  });

  testWidgets('Selecting Site Yöneticisi Girişi tab renders dedicated Site Manager Login Screen with dual path selector', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: false);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Tap Site Yöneticisi Girişi tab
    final siteManagerTab = find.text('Site Yöneticisi Girişi');
    expect(siteManagerTab, findsOneWidget);
    await tester.ensureVisible(siteManagerTab);
    await tester.pumpAndSettle();
    await tester.tap(siteManagerTab);
    await tester.pumpAndSettle();

    // Verify dedicated Site Manager screen elements
    expect(find.text('Site Yöneticisi Girişi'), findsWidgets);
    expect(find.text('Yönetici E-posta & Şifre ile Giriş'), findsOneWidget);
    expect(find.text('Site Yöneticisi Olarak Giriş Yap'), findsOneWidget);
    expect(find.textContaining('Giriş Yolu Seçimi'), findsWidgets);

    // Tap login button
    final managerLoginBtn = find.text('Site Yöneticisi Olarak Giriş Yap');
    await tester.ensureVisible(managerLoginBtn);
    await tester.pumpAndSettle();
    await tester.tap(managerLoginBtn);
    await tester.pumpAndSettle();

    expect(controller.isAuthenticated, isTrue);
    expect(controller.userRole, UserRole.siteManager);
  });

  testWidgets('When homeowner is newly registered, LoginScreen displays quick login card and logs into their unit', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: false);
    await controller.registerHomeOwner(
      block: 'C Blok',
      unitNo: 9,
      ownerName: 'Ayşe Kaya',
      email: 'ayse.kaya@gmail.com',
      phone: '+90 532 999 88 77',
    );

    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify newly registered homeowner card on login screen
    expect(find.text('Yeni Eklenen Kat Maliki'), findsOneWidget);
    expect(find.text('Ayşe Kaya'), findsWidgets);
    expect(find.text('C Blok D:9'), findsOneWidget);

    // Tap quick login button
    final quickLoginBtn = find.text('Ayşe Kaya Olarak Hemen Gir');
    expect(quickLoginBtn, findsOneWidget);
    await tester.ensureVisible(quickLoginBtn);
    await tester.pumpAndSettle();
    await tester.tap(quickLoginBtn);
    await tester.pumpAndSettle();

    expect(controller.isAuthenticated, isTrue);
    expect(controller.userRole, UserRole.homeOwner);
    expect(controller.activeUnit.ownerName, 'Ayşe Kaya');
    expect(controller.activeUnit.block, 'C Blok');
    expect(controller.activeUnit.unitNo, 9);
  });

  testWidgets('When site is newly registered, LoginScreen displays quick login card and logs into their site', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: false);
    await controller.registerNewSite(
      name: 'Lale Evleri',
      city: 'İzmir',
      address: 'Alsancak',
      adminName: 'Murat Can',
      adminEmail: 'murat.can@lale.com',
      adminPhone: '+90 533 111 22 33',
    );

    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify newly created site manager card on login screen
    expect(find.text('Yeni Oluşturulan Site Yöneticisi'), findsOneWidget);
    expect(find.text('Murat Can'), findsWidgets);
    expect(find.text('Lale Evleri'), findsOneWidget);

    // Tap quick login button
    final quickLoginBtn = find.text('Lale Evleri Yöneticisi Olarak Gir');
    expect(quickLoginBtn, findsOneWidget);
    await tester.ensureVisible(quickLoginBtn);
    await tester.pumpAndSettle();
    await tester.tap(quickLoginBtn);
    await tester.pumpAndSettle();

    expect(controller.isAuthenticated, isTrue);
    expect(controller.userRole, UserRole.siteManager);
    expect(controller.currentManagedSite?.name, 'Lale Evleri');
    expect(controller.currentManagedSite?.adminName, 'Murat Can');
  });

  testWidgets('When homeowner logs in, they can manually add and delete household co-residents via UI', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;

    final controller = _createTestController(startAuthenticated: false);
    controller.loginAs(role: UserRole.homeOwner);

    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify Dairem & Hane Bilgileri has manual add button and invite link button
    final addResidentBtn = find.byKey(const Key('btn_manual_add_resident'));
    final inviteLinkBtn = find.byKey(const Key('btn_invite_resident_link'));
    expect(addResidentBtn, findsOneWidget);
    expect(inviteLinkBtn, findsOneWidget);

    // Tap + Sakin Ekle
    await tester.ensureVisible(addResidentBtn);
    await tester.tap(addResidentBtn);
    await tester.pumpAndSettle();

    // Verify modal inputs are present
    expect(find.text('Yeni Hane Sakini Ekle'), findsOneWidget);
    final nameField = find.byKey(const Key('household_name_field'));
    final phoneField = find.byKey(const Key('household_phone_field'));
    final emailField = find.byKey(const Key('household_email_field'));
    final saveBtn = find.byKey(const Key('household_save_button'));

    expect(nameField, findsOneWidget);
    expect(phoneField, findsOneWidget);
    expect(emailField, findsOneWidget);
    expect(saveBtn, findsOneWidget);

    // Enter details
    await tester.enterText(nameField, 'Mehmet Kaya');
    await tester.enterText(phoneField, '0533 999 88 77');
    await tester.enterText(emailField, 'mehmet.kaya@example.com');
    await tester.pumpAndSettle();

    // Submit
    await tester.ensureVisible(saveBtn);
    await tester.pumpAndSettle();
    await tester.tap(saveBtn);
    await tester.pumpAndSettle();

    // Verify resident is added and displayed in household card
    expect(find.text('Mehmet Kaya'), findsOneWidget);
    expect(find.textContaining('0533 999 88 77'), findsOneWidget);

    // Now delete the resident
    final addedResident = controller.unitResidents.firstWhere((r) => r.fullName == 'Mehmet Kaya');
    final deleteBtn = find.byKey(Key('btn_delete_resident_${addedResident.id}'));
    expect(deleteBtn, findsOneWidget);
    await tester.ensureVisible(deleteBtn);
    await tester.tap(deleteBtn);
    await tester.pumpAndSettle();

    // Confirm dialog
    expect(find.text('Hane Sakinini Sil'), findsOneWidget);
    final confirmDeleteBtn = find.byKey(const Key('btn_confirm_delete_resident'));
    expect(confirmDeleteBtn, findsOneWidget);
    await tester.ensureVisible(confirmDeleteBtn);
    await tester.pumpAndSettle();
    await tester.tap(confirmDeleteBtn);
    await tester.pumpAndSettle();

    // Verify deleted
    expect(find.text('Mehmet Kaya'), findsNothing);
  });

  testWidgets('When tenant (homeResident) logs in, they also have manual add resident and invite permissions', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;

    final controller = _createTestController(startAuthenticated: false);
    controller.loginAs(role: UserRole.homeResident);

    // Verify tenant permissions include household management and invite
    final canInvite = controller.userSession.permissions.any((p) => p.code == 'UNIT_INVITE_CO_RESIDENT' && p.isGranted);
    final canManageHousehold = controller.userSession.permissions.any((p) => p.code == 'UNIT_MANAGE_HOUSEHOLD' && p.isGranted);
    expect(canInvite, isTrue);
    expect(canManageHousehold, isTrue);

    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify tenant sees + Sakin Ekle and Davet Linki buttons
    final addResidentBtn = find.byKey(const Key('btn_manual_add_resident'));
    final inviteLinkBtn = find.byKey(const Key('btn_invite_resident_link'));
    expect(addResidentBtn, findsOneWidget);
    expect(inviteLinkBtn, findsOneWidget);

    // Tap + Sakin Ekle as tenant
    await tester.ensureVisible(addResidentBtn);
    await tester.tap(addResidentBtn);
    await tester.pumpAndSettle();

    expect(find.text('Yeni Hane Sakini Ekle'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('household_name_field')), 'Canan Demir');
    await tester.enterText(find.byKey(const Key('household_phone_field')), '0544 111 22 33');
    await tester.enterText(find.byKey(const Key('household_email_field')), 'canan.demir@example.com');
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('household_save_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('household_save_button')));
    await tester.pumpAndSettle();

    expect(find.text('Canan Demir'), findsOneWidget);
  });

  testWidgets('When user taps Temizle on Site Manager login screen, clears login cache and form inputs', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: false);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Select Site Yöneticisi Girişi tab
    final siteManagerTab = find.text('Site Yöneticisi Girişi');
    await tester.ensureVisible(siteManagerTab);
    await tester.pumpAndSettle();
    await tester.tap(siteManagerTab);
    await tester.pumpAndSettle();

    final clearBtn = find.byKey(const Key('btn_clear_login_cache_manager'));
    expect(clearBtn, findsOneWidget);

    await tester.ensureVisible(clearBtn);
    await tester.pumpAndSettle();
    await tester.tap(clearBtn);
    await tester.pumpAndSettle();

    expect(find.text('Giriş önbelleği ve form alanları temizlendi.'), findsOneWidget);
  });

  testWidgets('When login has empty inputs or fails, displays visible error banner and feedback', (WidgetTester tester) async {
    final controller = _createTestController(startAuthenticated: false);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Select Site Yöneticisi Girişi tab
    final siteManagerTab = find.text('Site Yöneticisi Girişi');
    await tester.ensureVisible(siteManagerTab);
    await tester.pumpAndSettle();
    await tester.tap(siteManagerTab);
    await tester.pumpAndSettle();

    // First clear inputs using Temizle
    final clearBtn = find.byKey(const Key('btn_clear_login_cache_manager'));
    await tester.ensureVisible(clearBtn);
    await tester.pumpAndSettle();
    await tester.tap(clearBtn);
    await tester.pumpAndSettle();

    // Tap login button with empty fields
    final managerLoginBtn = find.text('Site Yöneticisi Olarak Giriş Yap');
    await tester.ensureVisible(managerLoginBtn);
    await tester.tap(managerLoginBtn);
    await tester.pumpAndSettle();

    // Verify error banner is visible with validation message
    expect(find.byKey(const Key('login_error_banner')), findsOneWidget);
    expect(find.text('Giriş Yapılamadı'), findsOneWidget);
    expect(find.text('Lütfen e-posta ve şifrenizi eksiksiz giriniz.'), findsWidgets);
    expect(controller.isAuthenticated, isFalse);

    // Tap close button on validation error banner
    final closeErrorBtn = find.byTooltip('Kapat');
    expect(closeErrorBtn, findsOneWidget);
    await tester.ensureVisible(closeErrorBtn);
    await tester.pumpAndSettle();
    await tester.tap(closeErrorBtn);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login_error_banner')), findsNothing);

    // Simulate controller error
    controller.setAuthError('Hatalı e-posta veya şifre. Lütfen girdiğiniz bilgileri kontrol edin.');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('login_error_banner')), findsOneWidget);
    expect(find.text('Hatalı e-posta veya şifre. Lütfen girdiğiniz bilgileri kontrol edin.'), findsOneWidget);

    // Close second error banner
    await tester.ensureVisible(find.byTooltip('Kapat'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Kapat'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login_error_banner')), findsNothing);
  });
}
