import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' show Tristate;
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/main.dart';
import 'package:sitepulse/ui/auth/login_screen.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/dashboard/dashboard_screen.dart';
import 'package:sitepulse/ui/navigation/app_router.dart';
import 'package:sitepulse/ui/navigation/app_routes.dart';
import 'package:sitepulse/ui/theme/app_theme.dart';
import 'test_fixtures.dart';
import 'ui_test_helpers.dart';

DashboardController _controller({bool signedIn = true, UserRole role = UserRole.homeOwner}) {
  final c = DashboardController(startAuthenticated: false);
  c.loadTestFixtures();
  if (signedIn) c.loginAs(role: role);
  return c;
}

Future<void> _pumpDashboard(WidgetTester tester, DashboardController c, {Size size = const Size(800, 600)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: DashboardScreen(controller: c)));
  await tester.pumpAndSettle();
}

void main() {
  group('URL per role and tab (finding 5)', () {
    test('every role has its own paths', () {
      final resident = _controller();
      expect(AppRoutes.pathFor(resident, 0).path, '/resident/home');
      expect(AppRoutes.pathFor(resident, 1).path, '/resident/unit');
      expect(AppRoutes.pathFor(resident, 9).path, '/resident/home', reason: 'out-of-range tab falls back to home');

      final manager = _controller(role: UserRole.siteManager);
      expect(AppRoutes.pathFor(manager, 1).path, '/manager/dues');
      expect(AppRoutes.pathFor(manager, 2).path, '/manager/residents');
      manager.setSiteAdminPath(SiteAdminActivePath.myFlatOwner);
      expect(AppRoutes.pathFor(manager, 1).path, '/manager/my-flat/unit');

      final admin = _controller(role: UserRole.saasAdmin);
      expect(AppRoutes.pathFor(admin, 1).path, '/admin/sites');

      final signedOut = _controller(signedIn: false);
      expect(AppRoutes.pathFor(signedOut, 1).path, AppRoutes.login);
    });

    test('a URL selects the tab and the manager path; another role\'s URL is refused', () {
      final manager = _controller(role: UserRole.siteManager);
      expect(AppRoutes.resolve(manager, Uri.parse('/manager/residents')), 2);
      expect(AppRoutes.resolve(manager, Uri.parse('/manager/my-flat/unit')), 1);
      expect(manager.siteAdminPath, SiteAdminActivePath.myFlatOwner);
      expect(AppRoutes.resolve(manager, Uri.parse('/manager/dues')), 1);
      expect(manager.siteAdminPath, SiteAdminActivePath.managerCockpit);
      expect(AppRoutes.resolve(manager, Uri.parse('/admin/sites')), isNull);
      expect(AppRoutes.resolve(manager, Uri.parse('/manager/unknown')), 0);
    });

    test('router keeps the tab in its URL and applies a deep link after login', () async {
      final c = _controller(signedIn: false);
      final router = AppRouterDelegate(c);
      addTearDown(router.dispose);

      await router.setNewRoutePath(Uri.parse('/resident/unit'));
      expect(router.currentConfiguration.path, AppRoutes.login, reason: 'signed out stays on /login');

      c.loginAs(role: UserRole.homeOwner);
      expect(router.tab, 1, reason: 'the deep link opened before login is applied');
      expect(router.currentConfiguration.path, '/resident/unit');

      router.selectTab(0);
      expect(router.currentConfiguration.path, '/resident/home');

      c.logout();
      expect(router.currentConfiguration.path, AppRoutes.login);
    });

    test('switching the manager path starts again on Home (no silent tab change)', () async {
      final c = _controller(role: UserRole.siteManager);
      final router = AppRouterDelegate(c);
      addTearDown(router.dispose);
      await router.setNewRoutePath(Uri.parse('/manager/residents'));
      expect(router.tab, 2);
      c.setSiteAdminPath(SiteAdminActivePath.myFlatOwner);
      expect(router.tab, 0);
      expect(router.currentConfiguration.path, '/manager/my-flat/home');
    });

    testWidgets('the app shell is router-based and shows login when signed out', (tester) async {
      final c = _controller(signedIn: false);
      await tester.pumpWidget(SitePulseApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      c.loginAs(role: UserRole.homeOwner);
      await tester.pumpAndSettle();
      expect(find.byType(DashboardScreen), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
    });
  });

  group('App bar and navigation (findings 7, 8, 9)', () {
    testWidgets('Profile is not a tab; the app bar keeps only the avatar', (tester) async {
      final c = _controller(role: UserRole.siteManager);
      await _pumpDashboard(tester, c);

      expect(find.text('Profil & Yetki'), findsNothing);
      final bar = tester.widget<BottomNavigationBar>(find.byType(BottomNavigationBar));
      expect(bar.items.map((i) => i.label), ['Ana Sayfa', 'Aidat Yönetimi', 'Sakinler & Malikler']);
      expect(bar.selectedFontSize, greaterThanOrEqualTo(12));

      expect(find.byTooltip('Çıkış Yap / Rol Değiştir'), findsNothing);
      expect(find.byTooltip('Tema Değiştir'), findsNothing);
      expect(find.byTooltip('Çevrimdışı Simüle Et'), findsNothing);
      expect(find.byTooltip('Profil, tema ve çıkış'), findsOneWidget);
    });

    testWidgets('logout asks first; cancelling keeps the session', (tester) async {
      final c = _controller();
      await _pumpDashboard(tester, c);
      await tester.tap(find.byTooltip('Profil, tema ve çıkış'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('btn_logout')));
      await tester.tap(find.byKey(const Key('btn_logout')));
      await tester.pumpAndSettle();

      expect(find.text('Çıkış yapılsın mı?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn_confirm_cancel')));
      await tester.pumpAndSettle();
      expect(c.isAuthenticated, isTrue);
    });

    testWidgets('logout through the profile sheet with confirmation signs out', (tester) async {
      final c = _controller();
      await tester.pumpWidget(SitePulseApp(controller: c));
      await tester.pumpAndSettle();
      await logOutThroughProfile(tester);
      expect(c.isAuthenticated, isFalse);
      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('theme and the dev-only offline simulator live in the profile sheet', (tester) async {
      final c = _controller();
      await _pumpDashboard(tester, c);
      await tester.tap(find.byTooltip('Profil, tema ve çıkış'));
      await tester.pumpAndSettle();

      expect(find.text('Sistem ayarını izliyor'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('btn_profile_toggle_theme')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_profile_toggle_theme')));
      await tester.pumpAndSettle();
      expect(c.themeMode, isNot(ThemeMode.system));
      expect(find.text('Seçiminiz bu cihazda saklanır'), findsOneWidget);

      // Debug/test builds show developer tools; release builds hide them (kShowDevTools).
      await tester.ensureVisible(find.byKey(const Key('btn_dev_simulate_offline')));
      await tester.tap(find.byKey(const Key('btn_dev_simulate_offline')));
      await tester.pumpAndSettle();
      expect(c.isOffline, isTrue);
      c.setThemeMode(ThemeMode.system);
    });

    testWidgets('going offline shows an inline banner and keeps the balance', (tester) async {
      final c = _controller();
      await _pumpDashboard(tester, c);
      expect(find.byKey(const Key('offline_banner')), findsNothing);
      expect(find.text('₺1.423,33'), findsWidgets);

      c.setNetworkOffline(true);
      await tester.pumpAndSettle();
      expect(find.textContaining('Çevrimdışısınız'), findsOneWidget);
      expect(find.text('₺1.423,33'), findsWidgets);

      c.setNetworkOffline(false);
      await tester.pumpAndSettle();
      expect(find.textContaining('Çevrimdışısınız'), findsNothing);
    });

    testWidgets('switching manager path without a router resets to Home', (tester) async {
      final c = _controller(role: UserRole.siteManager);
      await _pumpDashboard(tester, c);
      await tester.tap(find.text('Aidat Yönetimi'));
      await tester.pumpAndSettle();
      c.setSiteAdminPath(SiteAdminActivePath.myFlatOwner);
      await tester.pumpAndSettle();
      final bar = tester.widget<BottomNavigationBar>(find.byType(BottomNavigationBar));
      expect(bar.currentIndex, 0);
      expect(bar.items.map((i) => i.label), ['Ana Sayfa', 'Dairem']);
    });
  });

  group('Responsive layout (finding 11)', () {
    testWidgets('wide screens get a navigation rail and capped content', (tester) async {
      final c = _controller();
      await _pumpDashboard(tester, c, size: const Size(1440, 900));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsNothing);
      final capped = tester.widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
          .where((b) => b.constraints.maxWidth == AppBreakpoints.maxContentWidth);
      expect(capped, isNotEmpty);
    });

    for (final role in [UserRole.homeOwner, UserRole.siteManager, UserRole.saasAdmin]) {
      testWidgets('phone width (375 dp) renders ${role.name} home without overflow', (tester) async {
        final c = _controller(role: role);
        await _pumpDashboard(tester, c, size: const Size(375, 812));
        expect(find.byType(BottomNavigationBar), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('long site names ellipsize in the manager path switch', (tester) async {
      final c = _controller(role: UserRole.siteManager);
      await _pumpDashboard(tester, c, size: const Size(375, 812));
      final label = tester.widget<Text>(find.textContaining('Yönetimi').first);
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
    });
  });

  group('Accessibility (findings 1, 2, 10)', () {
    testWidgets('manager path switch announces selected state', (tester) async {
      final handle = tester.ensureSemantics();
      final c = _controller(role: UserRole.siteManager);
      await _pumpDashboard(tester, c);
      final cockpit = tester.getSemantics(find.bySemanticsLabel(RegExp('^Site yönetimi')));
      final flags = cockpit.getSemanticsData().flagsCollection;
      expect(flags.isButton, isTrue);
      expect(flags.isSelected, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('login role tabs announce selected state', (tester) async {
      final handle = tester.ensureSemantics();
      final c = _controller(signedIn: false);
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: LoginScreen(controller: c)));
      await tester.pumpAndSettle();
      final tab = tester.getSemantics(find.bySemanticsLabel('Kat Maliki Girişi'));
      expect(tab.getSemanticsData().flagsCollection.isButton, isTrue);
      await tester.tap(find.text('Kat Maliki Girişi'));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.bySemanticsLabel('Kat Maliki Girişi')).getSemanticsData().flagsCollection.isSelected,
        Tristate.isTrue,
      );
      handle.dispose();
    });

    testWidgets('login fields support password managers and Enter to submit', (tester) async {
      final c = _controller(signedIn: false);
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: LoginScreen(controller: c)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kat Maliki Girişi'));
      await tester.pumpAndSettle();

      expect(find.byType(AutofillGroup), findsOneWidget);
      final email = tester.widget<TextField>(find.descendant(
          of: find.byKey(const Key('login_homeowner_email_field')).evaluate().isEmpty
              ? find.byType(LoginScreen)
              : find.byKey(const Key('login_homeowner_email_field')),
          matching: find.byWidgetPredicate((w) => w is TextField && (w.autofillHints?.contains(AutofillHints.email) ?? false))).first);
      expect(email.keyboardType, TextInputType.emailAddress);
      expect(email.textInputAction, TextInputAction.next);

      final password = tester.widget<TextField>(find.byWidgetPredicate(
          (w) => w is TextField && (w.autofillHints?.contains(AutofillHints.password) ?? false)).first);
      expect(password.textInputAction, TextInputAction.done);
      expect(password.onSubmitted, isNotNull);

      // Enter on an empty form submits and shows the inline error, not a silent no-op.
      await tester.enterText(find.byWidget(email), '');
      await tester.enterText(find.byWidget(password), '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.textContaining('e-posta ve şifrenizi'), findsWidgets);
    });

    testWidgets('resident home meets text contrast and labelled tap target guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      final c = _controller();
      await _pumpDashboard(tester, c, size: const Size(390, 844));
      await tester.pump(const Duration(seconds: 5)); // let the login toast close
      await tester.pumpAndSettle();
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('login screen meets text contrast guideline in light and dark', (tester) async {
      final handle = tester.ensureSemantics();
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final c = _controller(signedIn: false);
        if (theme.brightness == Brightness.dark) c.setThemeMode(ThemeMode.dark);
        await tester.pumpWidget(MaterialApp(theme: theme, home: LoginScreen(controller: c)));
        await tester.pumpAndSettle();
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        c.setThemeMode(ThemeMode.system);
      }
      handle.dispose();
    });

    test('fixtures still describe the resident used above', () {
      expect(TestFixtures.defaultResidentUnit.block, 'A');
      expect(debugSemanticsDisableAnimations, isNull);
    });
  });
}
