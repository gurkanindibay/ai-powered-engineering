@Tags(['finance'])
library;
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/ui/components/capital_projects_view.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/dashboard/dashboard_screen.dart';
import 'test_fixtures.dart';

void main() {
  group('EPIC-10: Capital Expenditure & Fixtures (Demirbaş Yönetimi) UI Tests', () {
    late DashboardController controller;

    setUp(() {
      controller = DashboardController(startAuthenticated: true, isTestMode: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
    });

    test('when fetching mock capital projects then loads active project, installments, and shares', () async {
      final projects = await controller.fetchCapitalProjects();
      expect(projects.isNotEmpty, true);
      final active = controller.activeCapitalProject;
      expect(active, isNotNull);
      expect(active!.title, 'Asansör Revizyonu ve Yeşil Etiket');
      expect(active.category, 'ELEVATOR');
      expect(active.totalBudget, Decimal.parse('120000.00'));

      final installments = controller.capitalInstallments;
      expect(installments.length, 4);
      expect(installments.first.installmentBudget, Decimal.parse('30000.00'));

      final shares = controller.unitCapitalShares;
      expect(shares.isNotEmpty, true);
      expect(shares.first.ownerName, 'Ali Kaya');
    });

    testWidgets('DashboardScreen renders Demirbaş tab and displays Reserve Fund KPIs', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap on Aidat Yönetimi bottom tab
      final duesNavTab = find.text('Aidat Yönetimi');
      expect(duesNavTab, findsOneWidget);
      await tester.ensureVisible(duesNavTab);
      await tester.pumpAndSettle();
      await tester.tap(duesNavTab);
      await tester.pumpAndSettle();

      // Find and tap on Segment 4: Demirbaş & Yatırım
      final demirbasTab = find.byKey(const Key('segment_tab_4'));
      expect(demirbasTab, findsOneWidget);
      await tester.ensureVisible(demirbasTab);
      await tester.pumpAndSettle();
      await tester.tap(demirbasTab);
      await tester.pumpAndSettle();

      // Verify KMK 20/b Statutory Directive Banner
      expect(find.textContaining('634 Sayılı Kat Mülkiyeti Kanunu (KMK 20/b) Standardı'), findsOneWidget);

      // Verify Reserve Fund KPI header
      expect(find.text('Demirbaş & Yatırım Rezerv Fonu'), findsOneWidget);
      expect(find.text('Toplam Bütçe'), findsOneWidget);
      expect(find.text('Tahsil Edilen'), findsOneWidget);
      expect(find.text('Hakediş Ödemeleri'), findsOneWidget);
      expect(find.text('Kalan Rezerv Fon'), findsOneWidget);

      // Verify active project title & sub-tabs
      expect(find.text('Asansör Revizyonu ve Yeşil Etiket'), findsWidgets);
      expect(find.byKey(const Key('subtab_button_0')), findsOneWidget); // Taksit Planı
      expect(find.byKey(const Key('subtab_button_1')), findsOneWidget); // Kat Malikleri
      expect(find.byKey(const Key('subtab_button_2')), findsOneWidget); // Hakedişler
    });

    testWidgets('CapitalProjectsView switches subtabs to show Kat Malikleri and Hakedişler', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 1200,
              child: CapitalProjectsView(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Subtab 1: Kat Malikleri
      final ownersSubtab = find.byKey(const Key('subtab_button_1'));
      await tester.ensureVisible(ownersSubtab);
      await tester.pumpAndSettle();
      await tester.tap(ownersSubtab);
      await tester.pumpAndSettle();

      // Verify owner share distribution list
      expect(find.text('Kat Malikleri Demirbaş Dağılım Tablosu'), findsOneWidget);
      expect(find.text('Ali Kaya'), findsOneWidget);
      expect(find.textContaining('Arsa Payı: 24/1000'), findsWidgets);

      // Switch to Subtab 2: Müteahhit Hakedişleri
      final hakedisSubtab = find.byKey(const Key('subtab_button_2'));
      await tester.ensureVisible(hakedisSubtab);
      await tester.pumpAndSettle();
      await tester.tap(hakedisSubtab);
      await tester.pumpAndSettle();

      // Verify contractor disbursements
      expect(find.text('Müteahhit / Tedarikçi Hakediş Ödemeleri'), findsOneWidget);
      expect(find.text('1. Hakediş: Halat ve Pano Değişimi'), findsOneWidget);
      expect(find.byKey(const Key('btn_record_disbursement')), findsOneWidget);
    });

    testWidgets('CapitalProjectWizardPage validates input and creates new capital project', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CapitalProjectWizardPage(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Fill in project fields
      await tester.enterText(
        find.byKey(const Key('input_capital_project_title')),
        'Çatı İzolasyon ve Su Yalıtımı',
      );
      await tester.enterText(
        find.byKey(const Key('input_capital_project_budget')),
        '240000.00',
      );

      // Submit form
      final submitBtn = find.byKey(const Key('btn_submit_capital_project'));
      expect(submitBtn, findsOneWidget);
      await tester.ensureVisible(submitBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      // Verify new project added to controller
      expect(controller.capitalProjects.any((p) => p.title == 'Çatı İzolasyon ve Su Yalıtımı'), true);
      expect(controller.activeCapitalProject?.totalBudget, Decimal.parse('240000.00'));
    });
  });
}
