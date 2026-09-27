import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/main.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';

void main() {
  testWidgets('SitePulseApp renders Home Owner dashboard by default', (WidgetTester tester) async {
    final controller = DashboardController();
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify SitePulse branding and Kat Maliki default view
    expect(find.text('SitePulse'), findsOneWidget);
    expect(find.text('Kat Maliki (Ev Sahibi)'), findsWidgets);
    expect(find.text('Ödenecek Toplam Tutar'), findsOneWidget);
    expect(find.text('₺1.423,33'), findsOneWidget);
    expect(find.text('Daireye Özel Sanal IBAN'), findsOneWidget);
    expect(find.text('TR12 0006 2000 0000 0000 0014'), findsOneWidget);
    expect(find.text('Hemen Öde'), findsOneWidget);
  });

  testWidgets('SitePulseApp switches to Site Manager view and displays collection cockpit', (WidgetTester tester) async {
    final controller = DashboardController();
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
    final controller = DashboardController();
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
    final controller = DashboardController();
    await tester.pumpWidget(SitePulseApp(controller: controller));
    await tester.pumpAndSettle();

    // Default theme is dark
    expect(controller.isDarkMode, isTrue);

    // Toggle to Light mode
    controller.toggleTheme();
    await tester.pumpAndSettle();

    expect(controller.isDarkMode, isFalse);
    expect(find.text('SitePulse'), findsOneWidget);
    expect(find.text('₺1423.33'), findsOneWidget);

    // Toggle back to Dark mode
    controller.toggleTheme();
    await tester.pumpAndSettle();

    expect(controller.isDarkMode, isTrue);
  });
}
