import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/domain/usecases/calculate_dues_usecase.dart';

void main() {
  group('CalculateDuesUseCase KMK Delay Penalty Tests', () {
    final useCase = CalculateDuesUseCase();

    test('when dues are overdue by 10 days, calculates exact 5 percent pro-rated KMK penalty', () {
      // Principal: ₺1400.00, Due: 15 Sep, Today: 25 Sep (10 days overdue)
      // 1400 * 0.05 * (10 / 30) = 23.333... -> ₺23.33
      // Total: ₺1423.33
      final dueDate = DateTime(2026, 9, 15);
      final today = DateTime(2026, 9, 25);

      final dues = DuesLiability(
        id: 'b-01',
        unitId: 'd-14',
        period: 'Eylül 2026',
        principalAmount: Decimal.parse('1400.00'),
        delayPenalty: Decimal.zero,
        totalAmount: Decimal.parse('1400.00'),
        dueDate: dueDate,
        status: DebtStatus.pending,
      );

      final result = useCase.execute(dues, today);

      expect(result.status, DebtStatus.overdue);
      expect(result.daysOverdue, 10);
      expect(result.delayPenalty, Decimal.parse('23.33'));
      expect(result.totalAmount, Decimal.parse('1423.33'));

      // Also verify compatibility getters
      expect(result.status, DebtStatus.overdue);
      expect(result.daysOverdue, 10);
      expect(result.delayPenalty, Decimal.parse('23.33'));
      expect(result.totalAmount, Decimal.parse('1423.33'));
    });

    test('when dues are not overdue, penalty remains zero', () {
      final dueDate = DateTime(2026, 9, 30);
      final today = DateTime(2026, 9, 25);

      final dues = DuesLiability(
        id: 'b-02',
        unitId: 'd-14',
        period: 'Eylül 2026',
        principalAmount: Decimal.parse('1400.00'),
        delayPenalty: Decimal.zero,
        totalAmount: Decimal.parse('1400.00'),
        dueDate: dueDate,
        status: DebtStatus.pending,
      );

      final result = useCase.execute(dues, today);

      expect(result.status, DebtStatus.pending);
      expect(result.daysOverdue, 0);
      expect(result.delayPenalty, Decimal.zero);
      expect(result.totalAmount, Decimal.parse('1400.00'));
    });
  });
}
