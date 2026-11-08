import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/payments_phase2_models.dart';

void main() {
  test('A resident statement parses buckets, open items and receipts as Decimal', () {
    final st = ResidentStatement.fromJson({
      'unit_id': '14',
      'unit_label': 'A Blok D:14',
      'as_of': '2026-11-08',
      'debtors': [
        {
          'debtor_type': 'OWNER',
          'name': 'Ahmet Yılmaz',
          'current_due': '100.00',
          'overdue_1_30_days': '0',
          'overdue_31_60_days': '200.10',
          'overdue_61_90_days': '0',
          'overdue_90_plus_days': '0',
          'principal_outstanding': '300.10',
          'penalty_outstanding': '10.05',
          'total_outstanding': '310.15',
          'advance_balance': '0',
          'open_items': [
            {
              'due_id': '7',
              'period': 'Eylül 2026',
              'expense_type': 'OPERATIONAL_DUES',
              'due_date': '2026-09-15',
              'days_overdue': 54,
              'principal_outstanding': '200.10',
              'penalty_outstanding': '10.05',
              'total_outstanding': '210.15',
              'operating_budget_id': '3',
              'limitation_warning': false,
            }
          ],
        }
      ],
      'receipts': [
        {
          'receipt_number': 'IAD-2026-000001',
          'receipt_type': 'REVERSAL',
          'issued_at': '2026-11-01T10:00:00Z',
          'payer_role': 'OWNER',
          'payment_channel': 'INTER_LEDGER',
          'total_amount': '9.00',
          'reversed': false,
        }
      ],
    });
    final owner = st.debtors.single;
    expect(owner.totalOutstanding, Decimal.parse('310.15'));
    expect(owner.overdue31To60, Decimal.parse('200.10'));
    expect(owner.openItems.single.operatingBudgetId, '3');
    expect(st.receipts.single.isReversal, isTrue);
  });

  test('A payment intent reports when it is finished', () {
    final created = CardPaymentIntent.fromJson({'id': '1', 'amount': '9.50', 'status': 'CREATED', 'provider': 'SANDBOX'});
    final captured = CardPaymentIntent.fromJson(
        {'id': '1', 'amount': '9.50', 'status': 'CAPTURED', 'provider': 'SANDBOX', 'receipt_number': 'TAH-2026-000004'});
    expect(created.isFinished, isFalse);
    expect(captured.isCaptured && captured.isFinished, isTrue);
    expect(captured.amount, Decimal.parse('9.50'));
  });

  test('A budget line serializes the amount with two decimals', () {
    final line = BudgetLine(category: 'CLEANING', annualAmount: Decimal.parse('1200'), allocationKey: 'EQUAL');
    expect(line.toJson(), {'category': 'CLEANING', 'annual_amount': '1200.00', 'allocation_key': 'EQUAL'});
    final budget = OperatingBudget.fromJson({
      'id': '2',
      'fiscal_year': 2026,
      'status': 'INTERIM',
      'baseline_annual_amount': '38400.00',
      'total_annual_amount': '46080.00',
      'increase_rate': '20.0000',
      'cap_rate': '25.4900',
      'lines': [line.toJson()],
      'unit_shares': [],
      'service_records': [],
      'objections': [],
    });
    expect(budget.isInForce, isTrue);
    expect(budget.statusLabel, contains('Geçici'));
    expect(budget.capRate, Decimal.parse('25.49'));
  });
}
