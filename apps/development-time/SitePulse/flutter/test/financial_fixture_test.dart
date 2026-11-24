// Runs the shared financial fixture (harness/fixtures/financial_cases.json)
// against CalculateDuesUseCase. The backend runs the same fixture in
// backend/tests/financial_fixtures.rs, so both sides agree on every number.
@Tags(['finance'])
library;
import 'dart:convert';

import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/domain/models/liability_rules.dart';
import 'package:sitepulse/domain/usecases/calculate_dues_usecase.dart';

void main() {
  final fixture = json.decode(File('../harness/fixtures/financial_cases.json').readAsStringSync()) as Map<String, dynamic>;
  final useCase = CalculateDuesUseCase();

  group('Shared financial fixture: penalty cases', () {
    for (final raw in fixture['penalty_cases'] as List<dynamic>) {
      final c = raw as Map<String, dynamic>;
      test(c['name'] as String, () {
        final principal = Decimal.parse(c['principal'] as String);
        final dues = DuesLiability(
          id: 'x',
          unitId: '1',
          period: 'fixture',
          principalAmount: principal,
          delayPenalty: Decimal.zero,
          totalAmount: principal,
          dueDate: DateTime.parse(c['due_date'] as String),
          daysOverdue: 0,
          status: DebtStatus.pending,
        );
        final result = useCase.execute(dues, DateTime.parse(c['evaluation_date'] as String));
        expect(result.delayPenalty, Decimal.parse(c['expected_penalty'] as String), reason: 'penalty');
        expect(result.totalAmount, Decimal.parse(c['expected_total'] as String), reason: 'total');
        expect(result.status.name.toUpperCase(), c['expected_status'], reason: 'status');
      });
    }
  });

  group('Shared financial fixture: liability decision table', () {
    for (final raw in fixture['liability_decision_table'] as List<dynamic>) {
      final c = raw as Map<String, dynamic>;
      final caseId = c['case_id'] as String;
      test('$caseId (${c['occupancy']} / ${c['expense_type']} / ${c['payer_role']})', () {
        final occupancy = OccupancyStatus.fromCode(c['occupancy'] as String);
        final expenseType = ExpenseType.fromCode(c['expense_type'] as String);
        final payerRole = DebtorType.fromCode(c['payer_role'] as String);
        final settlesOwnerCapitalDues = c['settles_owner_capital_dues'] as bool;
        final settlesTenantJointLiability = c['settles_tenant_joint_liability'] as bool;

        final liableParty = LiabilityRules.accruedDebtorType(
          occupancy: occupancy,
          expenseType: expenseType,
        );
        final jointOwnerLiability = LiabilityRules.hasJointOwnerLiability(
          occupancy: occupancy,
          expenseType: expenseType,
        );
        final maySettle = LiabilityRules.payerMaySettle(
          debtorType: liableParty,
          expenseType: expenseType,
          payerRole: payerRole,
          settlesOwnerCapitalDues: settlesOwnerCapitalDues,
          settlesTenantJointLiability: settlesTenantJointLiability,
        );
        final rentOffset = LiabilityRules.isRentOffsetPayment(
          debtorType: liableParty,
          expenseType: expenseType,
          payerRole: payerRole,
          settlesOwnerCapitalDues: settlesOwnerCapitalDues,
        );

        expect(liableParty.code, c['expected_liable_party'], reason: '$caseId liable_party');
        expect(jointOwnerLiability, c['expected_joint_owner_liability'], reason: '$caseId joint_owner_liability');
        expect(maySettle, c['expected_payer_may_settle'], reason: '$caseId payer_may_settle');
        expect(rentOffset, c['expected_rent_offset'], reason: '$caseId rent_offset');
      });
    }
  });
}
