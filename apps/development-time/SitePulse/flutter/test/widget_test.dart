import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/main.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';

void main() {
  testWidgets('SitePulseApp renders LoginScreen when unauthenticated and displays test personas', (WidgetTester tester) async {
    final controller = DashboardController(startAuthenticated: false);
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
    final controller = DashboardController(startAuthenticated: false);
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
    final controller = DashboardController(startAuthenticated: false);
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
    expect(find.text('%80 Tahsil Edildi'), findsOneWidget);
    expect(find.text('Onay Bekleyen Başvurular'), findsOneWidget);
  });

  testWidgets('SitePulseApp renders Home Owner dashboard when authenticated', (WidgetTester tester) async {
    final controller = DashboardController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify SitePulse branding and Kat Maliki default view
    expect(find.text('SitePulse'), findsOneWidget);
    expect(find.text('Kat Maliki (Ev Sahibi)'), findsWidgets);
    expect(find.text('Ödenecek Toplam Tutar'), findsOneWidget);
    expect(find.text('₺1.423,33'), findsWidgets);
    expect(find.text('Daireye Özel Sanal IBAN'), findsOneWidget);
    expect(find.text('TR12 0006 2000 0000 0000 0014'), findsOneWidget);
    expect(find.text('Hemen Öde'), findsOneWidget);
  });

  testWidgets('SitePulseApp switches to Site Manager view and displays collection cockpit', (WidgetTester tester) async {
    final controller = DashboardController(startAuthenticated: true);
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Switch to Site Manager
    controller.switchSessionRole(UserRole.siteManager);
    await tester.pumpAndSettle();

    expect(find.text('Site Yöneticisi'), findsWidgets);
    expect(find.text('Eylül 2026 Tahsilat Durumu'), findsOneWidget);
    expect(find.text('%80 Tahsil Edildi'), findsOneWidget);
    expect(find.text('Onay Bekleyen Başvurular'), findsOneWidget);
    expect(find.text('Daire Aidat Takibi'), findsOneWidget);
  });

  testWidgets('SitePulseApp switches to SaaS SuperAdmin view and displays platform tenants', (WidgetTester tester) async {
    final controller = DashboardController(startAuthenticated: true);
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
    final controller = DashboardController(startAuthenticated: true);
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
    final controller = DashboardController(startAuthenticated: true);
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
    expect(textFields, findsNWidgets(6));
    await tester.enterText(textFields.at(0), 'Nilüfer Sitesi');
    await tester.enterText(textFields.at(3), 'Fatma Demir');

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
    final controller = DashboardController(startAuthenticated: true);
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
    final controller = DashboardController(startAuthenticated: true);
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
