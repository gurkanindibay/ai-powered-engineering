@Tags(['ui'])
library;
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/ui/components/dues_management_view.dart';
import 'package:sitepulse/ui/components/hero_balance_card.dart';
import 'package:sitepulse/ui/components/manager_cockpit_view.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/dashboard/dashboard_screen.dart';
import 'test_fixtures.dart';

void main() {
  group('Zero Data Guidance Tests (Periodic Payment, Homeowner, Site)', () {
    late DashboardController controller;

    setUp(() {
      controller = DashboardController(startAuthenticated: true);
    });

    testWidgets('DuesManagementView displays guidance when no periodic payment / dues months exist', (tester) async {
      controller.loadZeroDataFixtures(role: UserRole.siteManager);
      controller.setAvailableDuesMonthsForTesting([]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DuesManagementView(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify guidance for zero periodic payment
      expect(find.text('Henüz Aidat Dönemi Oluşturulmadı'), findsOneWidget);
      expect(find.textContaining('Bu sitede henüz aktif veya geçmiş bir aidat tahakkuku bulunmuyor'), findsOneWidget);
      expect(find.text('İlk Aidat Dönemini Başlat'), findsOneWidget);
      expect(find.textContaining('KMK Madde 20 uyarınca'), findsOneWidget);
    });

    testWidgets('DuesManagementView displays guidance when no homeowner / units exist in site', (tester) async {
      controller.loadZeroDataFixtures(role: UserRole.siteManager);
      // A period exists, but flats list is empty
      controller.setAvailableDuesMonthsForTesting(['Ekim 2026']);
      controller.setSelectedDuesMonthForTesting('Ekim 2026');
      controller.setFlatsForTesting([]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DuesManagementView(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify guidance for zero homeowner / units
      expect(find.text('Kayıtlı Daire ve Kat Maliki Bulunmuyor'), findsOneWidget);
      expect(find.textContaining('Aidat tahakkuku yapabilmek ve Sanal IBAN tahsis edebilmek için'), findsOneWidget);
    });

    testWidgets('ManagerCockpitView displays guidance when no periodic payment / dues exist', (tester) async {
      controller.loadZeroDataFixtures(role: UserRole.siteManager);
      controller.setManagedSitesForTesting(
        TenantSiteItem(
          id: 'site-empty',
          name: 'Yalı Konutları',
          city: 'İstanbul',
          address: 'Beşiktaş, İstanbul',
          status: 'ACTIVE',
          planType: 'STANDARD',
          totalUnits: 0,
          monthlyCollectionVolume: Decimal.zero,
          adminName: 'Yönetici',
          adminEmail: 'yonetici@yali.com',
          adminPhone: '+90 532 000 0000',
          actionCount: 0,
        ),
        [],
      );
      controller.setAvailableDuesMonthsForTesting([]);
      controller.setFlatsForTesting([]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ManagerCockpitView(
                controller: controller,
                onAddResidentTap: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify guidance under Daire Aidat Takibi
      expect(find.text('Aidat Takibi İçin Dönem Bulunmuyor'), findsOneWidget);
      expect(find.textContaining('Aidat Yönetimi'), findsWidgets);

      // Verify pending request zero state guidance
      expect(find.text('Onay Bekleyen Başvuru Bulunmuyor'), findsOneWidget);
      expect(find.textContaining('Manuel Sakin Ekle'), findsWidgets);
    });

    testWidgets('ManagerCockpitView displays guidance when no site exists in the system', (tester) async {
      controller.loadZeroDataFixtures(role: UserRole.siteManager);
      // Clear sites completely
      controller.setManagedSitesForTesting(
        TenantSiteItem(
          id: '',
          name: '',
          city: '',
          address: '',
          status: 'ACTIVE',
          planType: 'STANDARD',
          totalUnits: 0,
          monthlyCollectionVolume: Decimal.zero,
          adminName: '',
          adminEmail: '',
          adminPhone: '',
          actionCount: 0,
        ),
        [],
      );
      controller.clearAllDataForTesting();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ManagerCockpitView(
                controller: controller,
                onAddResidentTap: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Yönetilen Site Bulunmuyor'), findsOneWidget);
    });

    testWidgets('DashboardScreen displays guidance when Home Owner has no assigned unit', (tester) async {
      controller.loadZeroDataFixtures(role: UserRole.homeOwner);
      controller.setActiveUnitForTesting(ApartmentUnit.empty);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify resident guidance when no unit is assigned
      expect(find.text('Tanımlı Daireniz Bulunmuyor'), findsOneWidget);
      expect(find.textContaining('SitePulse hesabınıza henüz bir daire kaydı atanmamıştır'), findsOneWidget);
      expect(find.textContaining('Daireniz tanımlandığında'), findsOneWidget);
    });

    testWidgets('HeroBalanceCard displays reassuring zero debt guidance when no dues exist', (tester) async {
      final zeroDues = DuesLiability(
        id: '',
        unitId: 'unit-1',
        period: '',
        principalAmount: Decimal.zero,
        delayPenalty: Decimal.zero,
        totalAmount: Decimal.zero,
        dueDate: DateTime.now(),
        status: DebtStatus.paid,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HeroBalanceCard(
              dues: zeroDues,
              siteName: 'Begonya Sitesi',
              unitName: 'A Blok D:14',
              isOffline: false,
              onPayPressed: () {},
              onDetailPressed: () {},
              advancePayment: Decimal.zero,
              virtualIban: 'TR41 0020 5042 1399 1067 0000 14',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify status pill and guidance message
      expect(find.text('Aktif Aidat Borcu Bulunmuyor'), findsOneWidget);
      expect(find.textContaining('Yönetim tarafından adınıza tahakkuk ettirilmiş aktif bir aidat borcu bulunmamaktadır'), findsOneWidget);
      expect(find.text('Avans Yükle'), findsOneWidget);
      expect(find.text('Hesap Özeti'), findsOneWidget);
      expect(find.text('Kat Maliki Sorumluluğunda'), findsOneWidget);
    });

    testWidgets('HeroBalanceCard shows capital dues separately by project', (tester) async {
      final zeroDues = DuesLiability(
        id: '',
        unitId: 'unit-1',
        period: '',
        principalAmount: Decimal.zero,
        delayPenalty: Decimal.zero,
        totalAmount: Decimal.zero,
        dueDate: DateTime.now(),
        status: DebtStatus.paid,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HeroBalanceCard(
              dues: zeroDues,
              siteName: 'Begonya Sitesi',
              unitName: 'A Blok D:14',
              isOffline: false,
              onPayPressed: () {},
              onDetailPressed: () {},
              capitalDues: [
                CapitalDuesSummary(
                  projectId: 'project-1',
                  projectTitle: 'Roof Renewal',
                  outstandingBalance: Decimal.parse('1400.00'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Demirbaş Toplamı'), findsOneWidget);
      expect(find.text('Roof Renewal'), findsOneWidget);
      expect(find.textContaining('1.400,00'), findsNWidgets(2));
    });
  });
}
