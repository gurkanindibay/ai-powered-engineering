import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

import '../design_system/sp_feedback.dart';
class VirtualIbanCard extends StatelessWidget {
  final String iban;
  final String unitDesc;
  final VoidCallback? onIbanCopied;

  const VirtualIbanCard({
    super.key,
    this.iban = 'TR12 0006 2000 0000 0000 0014',
    this.unitDesc = 'A Blok D:14',
    this.onIbanCopied,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border(context), width: 1),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.account_balance,
                      color: AppColors.accentCyan,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Daireye Özel Sanal IBAN',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'FAST / EFT ile 7/24 Kesintisiz',
                        style: TextStyle(
                          color: AppColors.textSecondary(context),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.accentGreen.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '%100 Otomatik Eşleşme',
                  style: TextStyle(
                    color: AppColors.successText(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.card(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    iban,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: AppColors.textPrimary(context),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: iban.replaceAll(' ', '')));
                    onIbanCopied?.call();
                    ScaffoldMessenger.of(context).showSnackBar(
                      appSnackBar(
                        content: Text('Sanal IBAN panoya kopyalandı!'),
                        duration: Duration(seconds: 2),
                        backgroundColor: AppColors.successFill,
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.accentCyan.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy, size: 14, color: AppColors.accentCyan),
                        SizedBox(width: 4),
                        Text(
                          AppStrings.copy,
                          style: TextStyle(
                            color: AppColors.primaryText(context),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Bu IBAN sadece $unitDesc için tanımlanmıştır. Açıklamaya hiçbir şey yazmasanız dahi ödemeniz anında sistemde onaylanır.',
            style: TextStyle(
              color: AppColors.textSecondary(context),
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
