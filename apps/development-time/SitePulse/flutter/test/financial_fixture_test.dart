// Runs the shared financial fixture (harness/fixtures/financial_cases.json)
// against CalculateDuesUseCase. The backend runs the same fixture in
// backend/tests/financial_fixtures.rs, so both sides agree on every number.
import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
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
}
