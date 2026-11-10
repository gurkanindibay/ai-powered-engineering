import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/money.dart';

void main() {
  String fmt(String v) => Money.fromString(v).toTurkishString();

  test('toTurkishString formats exact Decimal amounts in Turkish locale', () {
    expect(fmt('0'), '₺0,00');
    expect(fmt('1423.33'), '₺1.423,33');
    expect(fmt('1234567.8'), '₺1.234.567,80');
    expect(fmt('999.999'), '₺1.000,00');
    expect(fmt('-1234.5'), '-₺1.234,50');
  });

  test('kuruş-level balances are not lost to floating point', () {
    final debt = Decimal.parse('0.1') + Decimal.parse('0.2') - Decimal.parse('0.3');
    expect(debt > Decimal.zero, isFalse);
    expect(Money.fromString('0.01').toTurkishString(), '₺0,01');
  });
}
