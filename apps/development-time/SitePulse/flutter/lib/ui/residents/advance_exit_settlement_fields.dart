import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../design_system/money_formatter.dart';
import '../design_system/sp_money_field.dart';
import '../../testing/test_id.dart';

enum AdvanceExitSettlementChoice { keep, payout, transfer }

/// Choice fields shared by tenant move-out and owner title-transfer flows.
class AdvanceExitSettlementFields extends StatelessWidget {
  final Decimal advanceBalance;
  final AdvanceExitSettlementChoice choice;
  final ValueChanged<AdvanceExitSettlementChoice> onChoiceChanged;
  final String sourceDebtor;
  final TextEditingController amountController;
  final ValueChanged<Decimal?> onAmountChanged;

  const AdvanceExitSettlementFields({
    super.key,
    required this.advanceBalance,
    required this.choice,
    required this.onChoiceChanged,
    required this.sourceDebtor,
    required this.amountController,
    required this.onAmountChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (advanceBalance <= Decimal.zero) return const SizedBox.shrink();
    final targetDebtor = sourceDebtor == 'OWNER' ? 'TENANT' : 'OWNER';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Toplam avans bakiyesi: ${formatTry(advanceBalance)}'),
        if (choice != AdvanceExitSettlementChoice.keep)
          Text('İşlem yapılacak hesap: ${sourceDebtor == 'OWNER' ? 'Malik' : 'Kiracı'}'),
        testId(
          'exit_advance_keep',
          RadioListTile<AdvanceExitSettlementChoice>(
            key: const Key('exit_advance_keep'),
            value: AdvanceExitSettlementChoice.keep,
            groupValue: choice,
            onChanged: (value) {
              if (value != null) onChoiceChanged(value);
            },
            title: const Text('Avansı mevcut hesapta bırak'),
            dense: true,
          ),
        ),
        testId(
          'exit_advance_payout',
          RadioListTile<AdvanceExitSettlementChoice>(
            key: const Key('exit_advance_payout'),
            value: AdvanceExitSettlementChoice.payout,
            groupValue: choice,
            onChanged: (value) {
              if (value != null) onChoiceChanged(value);
            },
            title: const Text('Ödeme iadesi talep et'),
            subtitle: const Text(
              'İade, başka bir yetkili onayladıktan sonra kaydedilir.',
            ),
            dense: true,
          ),
        ),
        testId(
          'exit_advance_transfer',
          RadioListTile<AdvanceExitSettlementChoice>(
            key: const Key('exit_advance_transfer'),
            value: AdvanceExitSettlementChoice.transfer,
            groupValue: choice,
            onChanged: (value) {
              if (value != null) onChoiceChanged(value);
            },
            title: Text(
              'Avansı ${targetDebtor == 'OWNER' ? 'malik' : 'kiracı'} hesabına aktar',
            ),
            subtitle: const Text(
              'Aktarım, başka bir yetkili onayladıktan sonra yapılır.',
            ),
            dense: true,
          ),
        ),
        if (choice != AdvanceExitSettlementChoice.keep) ...[
          const SizedBox(height: 8),
          testId(
            'exit_advance_amount',
            SpMoneyFormField(
              key: const Key('exit_advance_amount'),
              controller: amountController,
              requiredMessage: 'İşlem tutarını girin',
              invalidMessage: 'Geçerli bir tutar girin',
              decoration: const InputDecoration(
                labelText: 'İade/aktarım tutarı (₺)',
              ),
              onAmountChanged: onAmountChanged,
            ),
          ),
        ],
      ],
    );
  }
}
