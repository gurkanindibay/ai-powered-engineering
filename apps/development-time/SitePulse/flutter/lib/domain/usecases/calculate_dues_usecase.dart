import 'package:decimal/decimal.dart';
import '../models/dues_models.dart';

/// Calculates KMK Statutory Delay Penalty (Article 20).
/// Formula: DelayPenalty = Principal * 0.05 * (daysOverdue / 30)
/// Invariant: High-precision Decimal arithmetic, preserving kuruş precision.
class CalculateDuesUseCase {
  AidatBorcu execute(AidatBorcu borc, DateTime calculationDate) {
    if (calculationDate.isBefore(borc.sonOdemeTarihi) ||
        calculationDate.isAtSameMomentAs(borc.sonOdemeTarihi)) {
      return borc.copyWith(
        durum: BorcDurumu.bekliyor,
        gecikenGunSayisi: 0,
        gecikmeTazminati: Decimal.zero,
        toplamTutar: borc.anaPara,
      );
    }

    final daysOverdue = calculationDate.difference(borc.sonOdemeTarihi).inDays;
    if (daysOverdue <= 0) {
      return borc.copyWith(
        durum: BorcDurumu.bekliyor,
        gecikenGunSayisi: 0,
        gecikmeTazminati: Decimal.zero,
        toplamTutar: borc.anaPara,
      );
    }

    // Delay = Principal * 0.05 * (daysOverdue / 30)
    // Precise integer/kuruş math: (Principal * 5 * daysOverdue) / 3000
    final monthlyRate = Decimal.parse('0.05');
    final daysDecimal = Decimal.fromInt(daysOverdue);
    final monthDays = Decimal.fromInt(30);

    // Rational exact calculation then rounded to 2 decimal places
    final rationalPenalty = (borc.anaPara * monthlyRate * daysDecimal) / monthDays;
    final penaltyDouble = rationalPenalty.toDouble();
    // Round half up to 2 decimal places
    final roundedPenaltyStr = (penaltyDouble).toStringAsFixed(2);
    final penalty = Decimal.parse(roundedPenaltyStr);
    final total = borc.anaPara + penalty;

    return borc.copyWith(
      durum: BorcDurumu.gecikmede,
      gecikenGunSayisi: daysOverdue,
      gecikmeTazminati: penalty,
      toplamTutar: total,
    );
  }
}
