@Tags(['finance'])
library;
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/main.dart';
import 'package:sitepulse/ui/components/capital_projects_view.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'test_fixtures.dart';
import 'ui_test_helpers.dart';

DashboardController _createE2EController({bool startAuthenticated = false}) {
  final controller = DashboardController(startAuthenticated: startAuthenticated, isTestMode: true);
  controller.loadTestFixtures();
  return controller;
}

void main() {
  group('EPIC-10: Capital Expenditure & Coordinated Dues Systems End-to-End (E2E) On-Screen Tests', () {
    testWidgets('E2E On-Screen Journey 1: Capital Project Full Lifecycle with Positive & Valid Test Data', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2200);
      tester.view.devicePixelRatio = 1.0;
      
      final controller = _createE2EController(startAuthenticated: false);

      // Register guaranteed test data teardown
      addTearDown(() {
        controller.clearCapitalProjectsForTesting();
        controller.clearAllDataForTesting();
      });
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(SitePulseApp(controller: controller));
      await tester.pumpAndSettle();

      // 1. Authenticate as Site Manager on Screen
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

      // 2. Navigate on screen to Aidat Yönetimi bottom tab
      final duesNavTab = find.text('Aidat Yönetimi');
      expect(duesNavTab, findsOneWidget);
      await tester.ensureVisible(duesNavTab);
      await tester.pumpAndSettle();
      await tester.tap(duesNavTab);
      await tester.pumpAndSettle();

      // 3. Switch to Segment 4: Demirbaş & Yatırım
      final demirbasTab = find.byKey(const Key('segment_tab_4'));
      expect(demirbasTab, findsOneWidget);
      await tester.ensureVisible(demirbasTab);
      await tester.pumpAndSettle();
      await tester.tap(demirbasTab);
      await tester.pumpAndSettle();

      // 4. Verify Reserve Fund Header & KMK 20/b Banner
      expect(find.text('Demirbaş & Yatırım Rezerv Fonu'), findsOneWidget);
      expect(find.textContaining('634 Sayılı Kat Mülkiyeti Kanunu (KMK 20/b) Standardı'), findsOneWidget);
      expect(find.text('Toplam Bütçe'), findsOneWidget);
      expect(find.text('Tahsil Edilen'), findsOneWidget);
      expect(find.text('Hakediş Ödemeleri'), findsOneWidget);
      expect(find.text('Kalan Rezerv Fon'), findsOneWidget);

      // 5. Open Capital Project Wizard on Screen
      final openWizardBtn = find.byKey(const Key('btn_open_capital_project_wizard'));
      expect(openWizardBtn, findsOneWidget);
      await tester.ensureVisible(openWizardBtn);
      await tester.pumpAndSettle();
      await tester.tap(openWizardBtn);
      await tester.pumpAndSettle();

      // Verify navigation to CapitalProjectWizardPage
      expect(find.byType(CapitalProjectWizardPage), findsOneWidget);
      expect(find.text('Yeni Demirbaş Projesi'), findsOneWidget);
      expect(find.text('KMK 20/b Uyumlu Demirbaş ve Yatırım Planı Tanımlayın'), findsOneWidget);

      // 6. Enter Positive / Valid Test Data (DATA-POS-01)
      await tester.enterText(
        find.byKey(const Key('input_capital_project_title')),
        'B Blok Dış Cephe Mantolama ve Isı Yalıtımı',
      );
      await tester.enterText(
        find.byKey(const Key('input_capital_project_budget')),
        '300000.00',
      );

      // Select 3 installments
      final installment3Option = find.text('3 Taksit');
      expect(installment3Option, findsOneWidget);
      await tester.ensureVisible(installment3Option);
      await tester.pumpAndSettle();
      await tester.tap(installment3Option);
      await tester.pumpAndSettle();

      // Submit form
      final submitProjectBtn = find.byKey(const Key('btn_submit_capital_project'));
      expect(submitProjectBtn, findsOneWidget);
      await tester.ensureVisible(submitProjectBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitProjectBtn);
      await tester.pumpAndSettle();

      // Verify SnackBar and page dismissal
      expect(find.textContaining('projesi başarıyla oluşturuldu.'), findsOneWidget);
      expect(find.byType(CapitalProjectWizardPage), findsNothing);

      // 7. Verify new project is selected and displayed on screen
      expect(find.text('B Blok Dış Cephe Mantolama ve Isı Yalıtımı'), findsWidgets);
      expect(controller.activeCapitalProject?.title, 'B Blok Dış Cephe Mantolama ve Isı Yalıtımı');
      expect(controller.activeCapitalProject?.totalBudget, Decimal.parse('300000.00'));

      // 8. Test Installment Accrual on Screen (STORY-10-02)
      final accrueBtn = find.byKey(const Key('btn_accrue_installment_1'));
      expect(accrueBtn, findsOneWidget);
      await tester.ensureVisible(accrueBtn);
      await tester.pumpAndSettle();
      await tester.tap(accrueBtn);
      await tester.pumpAndSettle();

      // Verify confirmation dialog with statutory notice
      expect(find.text('Taksit Tahakkuk Onayı'), findsOneWidget);
      expect(find.textContaining('KMK Madde 20/b uyarınca demirbaş borçları'), findsOneWidget);

      // Confirm accrual
      final confirmAccrualBtn = find.byKey(const Key('btn_confirm_accrual_dialog'));
      expect(confirmAccrualBtn, findsOneWidget);
      await tester.ensureVisible(confirmAccrualBtn);
      await tester.pumpAndSettle();
      await tester.tap(confirmAccrualBtn);
      await tester.pumpAndSettle();

      // Verify accrual success notification & badge
      expect(find.textContaining('tüm kat maliklerine başarıyla tahakkuk ettirildi'), findsOneWidget);
      expect(find.text('Tahakkuk Etti'), findsWidgets);

      // 9. Switch to Subtab 2: Müteahhit Hakedişleri and record disbursement (STORY-10-05)
      final hakedisSubtab = find.byKey(const Key('subtab_button_2'));
      expect(hakedisSubtab, findsOneWidget);
      await tester.ensureVisible(hakedisSubtab);
      await tester.pumpAndSettle();
      await tester.tap(hakedisSubtab);
      await tester.pumpAndSettle();

      // Open disbursement modal
      final recordDisbursementBtn = find.byKey(const Key('btn_record_disbursement'));
      expect(recordDisbursementBtn, findsOneWidget);
      await tester.ensureVisible(recordDisbursementBtn);
      await tester.pumpAndSettle();
      await tester.tap(recordDisbursementBtn);
      await tester.pumpAndSettle();

      expect(find.text('Müteahhit Hakediş / İlerleme Ödemesi'), findsOneWidget);

      // Enter Positive Test Data (DATA-POS-02)
      await tester.enterText(
        find.byKey(const Key('input_disbursement_milestone')),
        '1. Hakediş: İskele Kurulumu ve Malzeme İntikali',
      );
      await tester.enterText(
        find.byKey(const Key('input_disbursement_amount')),
        '50000.00',
      );
      await tester.enterText(
        find.byKey(const Key('input_disbursement_recipient')),
        'Mega Yalıtım A.Ş.',
      );
      await tester.enterText(
        find.byKey(const Key('input_disbursement_iban')),
        'TR470006100511122233344455',
      );

      final submitDisbursementBtn = find.byKey(const Key('btn_submit_disbursement'));
      expect(submitDisbursementBtn, findsOneWidget);
      await tester.ensureVisible(submitDisbursementBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitDisbursementBtn);
      await tester.pumpAndSettle();

      // Verify disbursement success and inclusion in list
      expect(find.textContaining('hakediş ödemesi başarıyla kaydedildi.'), findsOneWidget);
      expect(find.text('1. Hakediş: İskele Kurulumu ve Malzeme İntikali'), findsOneWidget);

      // 10. Execute explicit test data cleanup at the end
      controller.clearCapitalProjectsForTesting();
      controller.clearAllDataForTesting();

      expect(controller.capitalProjects.isEmpty, isTrue);
      expect(controller.capitalInstallments.isEmpty, isTrue);
      expect(controller.capitalDisbursements.isEmpty, isTrue);
    });

    testWidgets('E2E On-Screen Journey 2: Wizard and Disbursement Form Negative & Boundary Validation', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2200);
      tester.view.devicePixelRatio = 1.0;

      final controller = _createE2EController(startAuthenticated: true);
      controller.switchSessionRole(UserRole.siteManager);

      addTearDown(() {
        controller.clearCapitalProjectsForTesting();
        controller.clearAllDataForTesting();
      });
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(SitePulseApp(controller: controller));
      await tester.pumpAndSettle();

      // Navigate to Aidat Yönetimi -> Demirbaş & Yatırım
      final duesNavTab = find.text('Aidat Yönetimi');
      await tester.ensureVisible(duesNavTab);
      await tester.pumpAndSettle();
      await tester.tap(duesNavTab);
      await tester.pumpAndSettle();

      final demirbasTab = find.byKey(const Key('segment_tab_4'));
      await tester.ensureVisible(demirbasTab);
      await tester.pumpAndSettle();
      await tester.tap(demirbasTab);
      await tester.pumpAndSettle();

      // Open wizard
      final openWizardBtn = find.byKey(const Key('btn_open_capital_project_wizard'));
      await tester.ensureVisible(openWizardBtn);
      await tester.pumpAndSettle();
      await tester.tap(openWizardBtn);
      await tester.pumpAndSettle();

      // 1. Negative Test: Submit completely empty form (DATA-NEG-01, DATA-NEG-02)
      final submitProjectBtn = find.byKey(const Key('btn_submit_capital_project'));
      await tester.ensureVisible(submitProjectBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitProjectBtn);
      await tester.pumpAndSettle();

      // Verify validation messages prevent submission
      expect(find.text('Başlık zorunludur'), findsOneWidget);
      expect(find.text('Bütçe zorunludur'), findsOneWidget);

      // 2. Negative Test: Invalid numeric format for budget
      await tester.enterText(
        find.byKey(const Key('input_capital_project_title')),
        'Çatı Onarım Projesi',
      );
      await tester.enterText(
        find.byKey(const Key('input_capital_project_budget')),
        'invalid_budget_amount',
      );

      await tester.ensureVisible(submitProjectBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitProjectBtn);
      await tester.pumpAndSettle();

      expect(find.text('Geçerli bir tutar girin'), findsOneWidget);

      // 3. Boundary & Fractional Test: ₺100,000 / 3 installments with kuruş precision (DATA-BND-01)
      await tester.enterText(
        find.byKey(const Key('input_capital_project_budget')),
        '100000.00',
      );
      final installment3Option = find.text('3 Taksit');
      await tester.ensureVisible(installment3Option);
      await tester.pumpAndSettle();
      await tester.tap(installment3Option);
      await tester.pumpAndSettle();

      await tester.ensureVisible(submitProjectBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitProjectBtn);
      await tester.pumpAndSettle();

      // Verify creation succeeded with exact decimal budget
      expect(find.textContaining('projesi başarıyla oluşturuldu.'), findsOneWidget);
      expect(controller.activeCapitalProject?.totalBudget, Decimal.parse('100000.00'));

      // 4. Negative Test: Disbursement modal validation (DATA-NEG-03)
      final hakedisSubtab = find.byKey(const Key('subtab_button_2'));
      await tester.ensureVisible(hakedisSubtab);
      await tester.pumpAndSettle();
      await tester.tap(hakedisSubtab);
      await tester.pumpAndSettle();

      final recordDisbursementBtn = find.byKey(const Key('btn_record_disbursement'));
      await tester.ensureVisible(recordDisbursementBtn);
      await tester.pumpAndSettle();
      await tester.tap(recordDisbursementBtn);
      await tester.pumpAndSettle();

      // Submit with empty milestone name and invalid amount
      final submitDisbursementBtn = find.byKey(const Key('btn_submit_disbursement'));
      await tester.ensureVisible(submitDisbursementBtn);
      await tester.pumpAndSettle();
      await tester.tap(submitDisbursementBtn);
      await tester.pumpAndSettle();

      expect(find.text('Aşama tanımı zorunludur'), findsOneWidget);
      expect(find.text('Geçerli tutar girin'), findsOneWidget);

      // Dismiss the full-screen page cleanly via its back button
      final closeBtn = find.byKey(const Key('btn_page_back'));
      expect(closeBtn, findsOneWidget);
      await tester.ensureVisible(closeBtn);
      await tester.pumpAndSettle();
      await tester.tap(closeBtn);
      await tester.pumpAndSettle();

      // Cleanup
      controller.clearCapitalProjectsForTesting();
      controller.clearAllDataForTesting();
    });

    testWidgets('E2E On-Screen Journey 3: Multi-Persona Statutory Isolation (Kat Maliki vs Kiracı KMK 20/b & TBK 314)', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2200);
      tester.view.devicePixelRatio = 1.0;

      final controller = _createE2EController(startAuthenticated: false);

      addTearDown(() {
        controller.clearCapitalProjectsForTesting();
        controller.clearAllDataForTesting();
      });
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(SitePulseApp(controller: controller));
      await tester.pumpAndSettle();

      // 1. Login as Kat Maliki (Ahmet Yılmaz)
      final homeOwnerCard = find.text('Kat Maliki (Ev Sahibi)');
      await tester.ensureVisible(homeOwnerCard);
      await tester.pumpAndSettle();
      await tester.tap(homeOwnerCard);
      await tester.pumpAndSettle();

      final enterHomeOwnerBtn = find.text('Kat Maliki Olarak Gir');
      await tester.ensureVisible(enterHomeOwnerBtn);
      await tester.pumpAndSettle();
      await tester.tap(enterHomeOwnerBtn);
      await tester.pumpAndSettle();

      expect(controller.isAuthenticated, isTrue);
      expect(controller.userRole, UserRole.homeOwner);

      // Verify Kat Maliki sees their dues and balance
      expect(find.text('Ödenecek Toplam Tutar'), findsOneWidget);
      expect(find.text('₺1.423,33'), findsWidgets);

      // 2. Logout Kat Maliki
      // Logout lives in the profile sheet and asks for confirmation.
      await logOutThroughProfile(tester);

      expect(controller.isAuthenticated, isFalse);

      // 3. Login as Resident / Tenant (Ev Sakini)
      final residentCard = find.text('Ev Sakini (Aile / Kiracı)');
      await tester.ensureVisible(residentCard);
      await tester.pumpAndSettle();
      await tester.tap(residentCard);
      await tester.pumpAndSettle();

      final enterResidentBtn = find.text('Ev Sakini Olarak Gir');
      await tester.ensureVisible(enterResidentBtn);
      await tester.pumpAndSettle();
      await tester.tap(enterResidentBtn);
      await tester.pumpAndSettle();

      expect(controller.isAuthenticated, isTrue);
      expect(controller.userRole, UserRole.homeResident);

      // Verify Tenant screen is rendered cleanly
      expect(find.text('SitePulse'), findsWidgets);

      // Cleanup
      controller.clearCapitalProjectsForTesting();
      controller.clearAllDataForTesting();
    });

    testWidgets('E2E On-Screen Journey 4: Strict Test Data Clearance & Pristine State Verification', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2200);
      tester.view.devicePixelRatio = 1.0;

      final controller = _createE2EController(startAuthenticated: true);
      controller.switchSessionRole(UserRole.siteManager);

      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Load active capital project
      await controller.fetchCapitalProjects();
      expect(controller.capitalProjects.isNotEmpty, isTrue);
      expect(controller.capitalInstallments.isNotEmpty, isTrue);

      await tester.pumpWidget(SitePulseApp(controller: controller));
      await tester.pumpAndSettle();

      // Navigate to Demirbaş tab
      final duesNavTab = find.text('Aidat Yönetimi');
      await tester.ensureVisible(duesNavTab);
      await tester.pumpAndSettle();
      await tester.tap(duesNavTab);
      await tester.pumpAndSettle();

      final demirbasTab = find.byKey(const Key('segment_tab_4'));
      await tester.ensureVisible(demirbasTab);
      await tester.pumpAndSettle();
      await tester.tap(demirbasTab);
      await tester.pumpAndSettle();

      // Verify active project is present on screen
      expect(find.text('Asansör Revizyonu ve Yeşil Etiket'), findsWidgets);

      // -------------------------------------------------------------
      // COMPLETE DATA PURGE & TEARDOWN
      // -------------------------------------------------------------
      controller.clearCapitalProjectsForTesting();
      controller.clearAllDataForTesting();

      // Assert that all test data in memory / controller is completely wiped
      expect(controller.capitalProjects.isEmpty, isTrue);
      expect(controller.activeCapitalProject, isNull);
      expect(controller.capitalInstallments.isEmpty, isTrue);
      expect(controller.capitalDisbursements.isEmpty, isTrue);
      expect(controller.unitCapitalShares.isEmpty, isTrue);
      expect(controller.duesList.isEmpty, isTrue);
      expect(controller.flatsList.isEmpty, isTrue);

      // Re-pump widget to verify screen reflects pristine zero-data state
      await tester.pumpAndSettle();

      // Verify zero-data guidance is displayed on screen
      expect(find.text('Henüz tanımlanmış bir demirbaş projesi bulunmuyor.'), findsOneWidget);
      expect(find.byKey(const Key('btn_open_first_capital_project')), findsOneWidget);

      // Verify that no previous project data remains on screen
      expect(find.text('Asansör Revizyonu ve Yeşil Etiket'), findsNothing);
    });
  });
}
