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

      final borc = AidatBorcu(
        id: 'b-01',
        daireId: 'd-14',
        donem: 'Eylül 2026',
        anaPara: Decimal.parse('1400.00'),
        gecikmeTazminati: Decimal.zero,
        toplamTutar: Decimal.parse('1400.00'),
        sonOdemeTarihi: dueDate,
        durum: BorcDurumu.bekliyor,
      );

      final result = useCase.execute(borc, today);

      expect(result.durum, BorcDurumu.gecikmede);
      expect(result.gecikenGunSayisi, 10);
      expect(result.gecikmeTazminati, Decimal.parse('23.33'));
      expect(result.toplamTutar, Decimal.parse('1423.33'));
    });

    test('when dues are not overdue, penalty remains zero', () {
      final dueDate = DateTime(2026, 9, 30);
      final today = DateTime(2026, 9, 25);

      final borc = AidatBorcu(
        id: 'b-02',
        daireId: 'd-14',
        donem: 'Eylül 2026',
        anaPara: Decimal.parse('1400.00'),
        gecikmeTazminati: Decimal.zero,
        toplamTutar: Decimal.parse('1400.00'),
        sonOdemeTarihi: dueDate,
        durum: BorcDurumu.bekliyor,
      );

      final result = useCase.execute(borc, today);

      expect(result.durum, BorcDurumu.bekliyor);
      expect(result.gecikenGunSayisi, 0);
      expect(result.gecikmeTazminati, Decimal.zero);
      expect(result.toplamTutar, Decimal.parse('1400.00'));
    });
  });
}
