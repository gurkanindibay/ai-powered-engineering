import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/dues_models.dart';

void main() {
  AccountTransactionItem row(String id, String subtitle) => AccountTransactionItem(
        id: id,
        title: 'Eylül 2026 Aidatı',
        subtitle: subtitle,
        amount: Decimal.parse('1400.00'),
        date: '15.09.2026',
        isCredit: false,
      );

  test('an overdue principal row is not shown as a credit', () {
    expect(row('due-1', 'Gecikmeli Aidat Borcu').amountStr, isNot(startsWith('+')));
  });

  test('the itemised delay penalty row is shown with a plus sign', () {
    expect(row('due-1-penalty', 'Eylül 2026 Gecikme Zammı').amountStr, startsWith('+'));
  });
}
