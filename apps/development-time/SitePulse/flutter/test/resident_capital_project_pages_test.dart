import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/ui/components/resident_capital_project_pages.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';

void main() {
  CapitalProjectItem project({String id = 'project-1'}) => CapitalProjectItem(
    id: id,
    siteId: 'site-1',
    title: 'Çatı Yalıtımı',
    category: 'ROOF_FACADE',
    description: 'A Blok çatı yenilemesi',
    totalBudget: Decimal.parse('42000.00'),
    allocationBasis: 'BY_LAND_SHARE',
    targetStartDate: DateTime(2026, 11),
    contractorName: 'Atlas Çatı Sistemleri',
    contractAmount: Decimal.parse('42000.00'),
    status: 'ACTIVE',
    collectedAmount: Decimal.parse('21000.00'),
    disbursedAmount: Decimal.zero,
    remainingFundBalance: Decimal.parse('21000.00'),
    totalUnitsCount: 12,
    installmentsCount: 2,
  );

  testWidgets('tenant guidance shows active projects and statutory text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TenantCapitalProjectsGuidance(projects: [project()]),
        ),
      ),
    );

    expect(find.text('Çatı Yalıtımı'), findsOneWidget);
    expect(find.text('Kat Maliki Sorumluluğunda'), findsOneWidget);
    expect(find.text(TenantCapitalProjectsGuidance.guidance), findsOneWidget);
  });

  testWidgets(
    'owner project detail shows contractor and installment schedule',
    (tester) async {
      final current = project();
      final details = ResidentCapitalProjectDetails(
        project: current,
        installments: [
          CapitalProjectInstallmentItem(
            id: 'installment-1',
            projectId: current.id,
            installmentNumber: 1,
            totalInstallments: 2,
            dueDate: DateTime(2026, 11, 30),
            installmentBudget: Decimal.parse('21000.00'),
            percentage: Decimal.parse('50.00'),
            isAccrued: true,
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ResidentCapitalProjectDetailsPage(
            details: details,
            outstandingBalance: Decimal.parse('21000.00'),
          ),
        ),
      );

      expect(find.text('Atlas Çatı Sistemleri'), findsOneWidget);
      expect(find.text('1. Taksit'), findsOneWidget);
      expect(find.text('30.11.2026'), findsNothing);
      expect(find.textContaining('2026-11-30'), findsOneWidget);
      expect(find.textContaining('21.000'), findsWidgets);
    },
  );
}
