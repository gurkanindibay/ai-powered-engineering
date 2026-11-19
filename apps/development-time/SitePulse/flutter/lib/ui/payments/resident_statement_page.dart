import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../design_system/sp_typography.dart';
import 'package:intl/intl.dart';

import '../../domain/models/payments_phase2_models.dart';
import '../../domain/services/payments_phase2_api.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../design_system/money_formatter.dart';
import '../theme/app_theme.dart';
import 'receipt_actions.dart';
import 'resident_self_service.dart';

/// Hesap ekstresi: the signed-in debtor's open items aged by days overdue, the
/// accrued delay penalty, the advance balance and their receipts (as PDF).
class ResidentStatementPage extends StatefulWidget {
  final String unitId;
  final String subtitle;

  const ResidentStatementPage({super.key, required this.unitId, required this.subtitle});

  @override
  State<ResidentStatementPage> createState() => _ResidentStatementPageState();
}

class _ResidentStatementPageState extends State<ResidentStatementPage> {
  late Future<ResidentStatement> _future;

  @override
  void initState() {
    super.initState();
    _future = PaymentsPhase2Api.statement(widget.unitId);
  }

  @override
  Widget build(BuildContext context) {
    return AppFullscreenPage(
      title: 'Hesap Ekstresi',
      subtitle: widget.subtitle,
      icon: const Icon(Icons.account_balance_wallet_outlined, color: AppColors.accentCyan),
      child: FutureBuilder<ResidentStatement>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError) {
            return testId('statement_error', Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Ekstre alınamadı: ${snap.error}', style: TextStyle(color: AppColors.dangerText(context))),
            ));
          }
          final st = snap.data!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tarih: ${st.asOf == null ? '-' : DateFormat('dd.MM.yyyy').format(st.asOf!)} · Gecikme tazminatı bugüne kadar işletilmiştir (KMK 20).',
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption),
              ),
              const SizedBox(height: 12),
              for (final d in st.debtors) ...[_DebtorCard(debtor: d), const SizedBox(height: 14)],
              StatementSelfService(
                unitId: widget.unitId,
                statement: st,
                onChanged: () => setState(() => _future = PaymentsPhase2Api.statement(widget.unitId)),
              ),
              const SizedBox(height: 14),
              Text('Makbuzlar', style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.title, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (st.receipts.isEmpty)
                Text('Henüz makbuz yok.', style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.body)),
              for (final r in st.receipts) _ReceiptRow(receipt: r),
            ],
          );
        },
      ),
    );
  }
}

class _DebtorCard extends StatelessWidget {
  final StatementDebtor debtor;
  const _DebtorCard({required this.debtor});

  @override
  Widget build(BuildContext context) {
    final role = debtor.debtorType == 'TENANT' ? 'Kiracı' : 'Kat maliki';
    final buckets = <(String, Decimal)>[
      ('Vadesi gelmemiş', debtor.currentDue),
      ('1–30 gün', debtor.overdue1To30),
      ('31–60 gün', debtor.overdue31To60),
      ('61–90 gün', debtor.overdue61To90),
      ('90+ gün', debtor.overdue90Plus),
    ];
    return testId('statement_debtor_${debtor.debtorType.toLowerCase()}', Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${debtor.name} · $role', style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, amount) in buckets)
                Container(
                  width: 120,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.surface(context),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border(context)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption)),
                      const SizedBox(height: 2),
                      Text(formatTry(amount), style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _line(context, 'Anapara', debtor.principalOutstanding),
          _line(context, 'Gecikme tazminatı', debtor.penaltyOutstanding),
          _line(context, 'Toplam borç', debtor.totalOutstanding, bold: true, id: 'statement_total_${debtor.debtorType.toLowerCase()}'),
          if (debtor.advanceBalance > Decimal.zero) _line(context, 'Avans bakiyesi', debtor.advanceBalance),
          if (debtor.openItems.isNotEmpty) ...[
            const Divider(height: 20),
            for (final i in debtor.openItems)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(i.period, style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.body)),
                          Text(
                            [
                              i.expenseType == 'CAPITAL_DUES' ? 'Demirbaş' : 'Aidat',
                              if (i.dueDate != null) 'vade ${DateFormat('dd.MM.yyyy').format(i.dueDate!)}',
                              if (i.chargeCreatedLate) 'borç geç oluşturuldu',
                              if (i.daysOverdue > 0) '${i.daysOverdue} gün gecikme',
                              if (i.operatingBudgetId != null) 'işletme projesi #${i.operatingBudgetId}',
                              if (i.limitationWarning) '5 yıllık zamanaşımı riski',
                            ].join(' · '),
                            style: TextStyle(
                              color: i.limitationWarning ? AppColors.warningText(context) : AppColors.textSecondary(context),
                              fontSize: SpFontSize.caption,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(formatTry(i.totalOutstanding), style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.body)),
                  ],
                ),
              ),
          ],
          if (debtor.debtorType == 'OWNER' &&
              debtor.jointlyLiableTotal > Decimal.zero) ...[
            const Divider(height: 20),
            Text(
              'Kiracı borçlarında müşterek sorumluluk',
              style: TextStyle(
                color: AppColors.textPrimary(context),
                fontSize: SpFontSize.body,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            for (final item in debtor.jointlyLiableOpenItems)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.period,
                        style: TextStyle(
                          color: AppColors.textSecondary(context),
                          fontSize: SpFontSize.body,
                        ),
                      ),
                    ),
                    Text(
                      formatTry(item.totalOutstanding),
                      style: TextStyle(
                        color: AppColors.textPrimary(context),
                        fontSize: SpFontSize.body,
                      ),
                    ),
                  ],
                ),
              ),
            _line(
              context,
              'Müşterek sorumluluk toplamı',
              debtor.jointlyLiableTotal,
              bold: true,
              id: 'statement_joint_liability_total',
            ),
          ],
        ],
      ),
    ));
  }

  Widget _line(BuildContext context, String label, Decimal amount, {bool bold = false, String? id}) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.body)),
          Text(formatTry(amount),
              style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.body, fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
        ],
      ),
    );
    return id == null ? row : testId(id, row, label: '$label ${formatTry(amount)}');
  }
}

class _ReceiptRow extends StatelessWidget {
  final StatementReceipt receipt;
  const _ReceiptRow({required this.receipt});

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (receipt.issuedAt != null) DateFormat('dd.MM.yyyy HH:mm').format(receipt.issuedAt!.toLocal()),
      if (receipt.isReversal) 'İptal / iade makbuzu',
      if (receipt.reversed) 'iptal edildi',
    ].join(' · ');
    return testId('statement_receipt_${receipt.receiptNumber}', ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(receipt.isReversal ? Icons.undo : Icons.receipt_long_outlined, color: AppColors.accentCyan),
      title: Text('${receipt.receiptNumber} · ${formatTry(receipt.totalAmount)}',
          style: TextStyle(
            color: AppColors.textPrimary(context),
            fontSize: SpFontSize.body,
            decoration: receipt.reversed ? TextDecoration.lineThrough : null,
          )),
      subtitle: Text(subtitle, style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption)),
      trailing: testId('statement_receipt_pdf_${receipt.receiptNumber}', IconButton(
        tooltip: 'PDF indir',
        icon: const Icon(Icons.picture_as_pdf_outlined),
        onPressed: () => downloadReceiptPdf(context, receipt.receiptNumber),
      )),
    ));
  }
}
