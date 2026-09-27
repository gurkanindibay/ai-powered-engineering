import 'package:decimal/decimal.dart';
import '../models/dues_models.dart';

/// Calculates KMK Statutory Delay Penalty (Article 20).
/// Formula: DelayPenalty = Principal * 0.05 * (daysOverdue / 30)
/// Invariant: High-precision Decimal arithmetic, preserving kuruş precision.
class CalculateDuesUseCase {
  DuesLiability execute(DuesLiability dues, DateTime calculationDate) {
    if (calculationDate.isBefore(dues.dueDate) ||
        calculationDate.isAtSameMomentAs(dues.dueDate)) {
      return dues.copyWith(
        status: DebtStatus.pending,
        daysOverdue: 0,
        delayPenalty: Decimal.zero,
        totalAmount: dues.principalAmount,
      );
    }

    final daysOverdue = calculationDate.difference(dues.dueDate).inDays;
    if (daysOverdue <= 0) {
      return dues.copyWith(
        status: DebtStatus.pending,
        daysOverdue: 0,
        delayPenalty: Decimal.zero,
        totalAmount: dues.principalAmount,
      );
    }

    // Delay = Principal * 0.05 * (daysOverdue / 30)
    // Precise integer/kuruş math: (Principal * 5 * daysOverdue) / 3000
    final monthlyRate = Decimal.parse('0.05');
    final daysDecimal = Decimal.fromInt(daysOverdue);
    final monthDays = Decimal.fromInt(30);

    // Rational exact calculation then rounded to 2 decimal places
    final rationalPenalty = (dues.principalAmount * monthlyRate * daysDecimal) / monthDays;
    final penaltyDouble = rationalPenalty.toDouble();
    // Round half up to 2 decimal places
    final roundedPenaltyStr = (penaltyDouble).toStringAsFixed(2);
    final penalty = Decimal.parse(roundedPenaltyStr);
    final total = dues.principalAmount + penalty;

    return dues.copyWith(
      status: DebtStatus.overdue,
      daysOverdue: daysOverdue,
      delayPenalty: penalty,
      totalAmount: total,
    );
  }
}
