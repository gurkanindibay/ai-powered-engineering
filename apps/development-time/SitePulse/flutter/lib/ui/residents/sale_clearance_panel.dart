import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../domain/models/payments_phase3_models.dart';
import '../../domain/services/payments_phase3_api.dart';
import '../../domain/services/platform_env.dart';
import '../../testing/test_id.dart';
import '../design_system/money_formatter.dart';
import '../design_system/sp_feedback.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';

/// Loads the sale clearance statement of a unit.
typedef SaleClearanceLoader = Future<SaleClearance> Function(String unitId, DateTime? effectiveDate);

/// Downloads the statement; returns false where the platform cannot save files.
typedef SaleClearanceDownloader = Future<bool> Function(String unitId, DateTime? effectiveDate);

Future<bool> _downloadCsv(String unitId, DateTime? effectiveDate) async {
  final bytes = await PaymentsPhase3Api.saleClearanceCsv(unitId, effectiveDate: effectiveDate);
  return downloadBytes('satis-mutabakat-$unitId.csv', bytes, 'text/csv');
}

/// The sale clearance statement shown before a title transfer is confirmed: the seller's open
/// debt (principal and late fee apart), the advance, and the capital installments that are not
/// accrued yet. It moves nothing; its totals are the ledger's.
class SaleClearancePanel extends StatefulWidget {
  final String unitId;
  final DateTime? effectiveDate;
  final SaleClearanceLoader? loader;
  final SaleClearanceDownloader? downloader;

  const SaleClearancePanel({
    super.key,
    required this.unitId,
    this.effectiveDate,
    this.loader,
    this.downloader,
  });

  @override
  State<SaleClearancePanel> createState() => _SaleClearancePanelState();
}

class _SaleClearancePanelState extends State<SaleClearancePanel> {
  late Future<SaleClearance> _statement;

  @override
  void initState() {
    super.initState();
    _statement = _load();
  }

  Future<SaleClearance> _load() => (widget.loader ??
      (unitId, date) => PaymentsPhase3Api.saleClearance(unitId, effectiveDate: date))(
        widget.unitId,
        widget.effectiveDate,
      );

  Future<void> _download() async {
    try {
      final saved = await (widget.downloader ?? _downloadCsv)(widget.unitId, widget.effectiveDate);
      if (!mounted) return;
      if (saved) {
        SpToast.success(context, 'Satış mutabakat bildirimi indirildi.');
      } else {
        SpToast.error(context, 'İndirme bu platformda desteklenmiyor.');
      }
    } catch (error) {
      if (mounted) SpToast.error(context, 'Bildirim indirilemedi: $error');
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<SaleClearance>(
        future: _statement,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError || snapshot.data == null) {
            return SpGuidanceCard(
              icon: Icons.error_outline,
              title: 'Satış mutabakat bildirimi yüklenemedi',
              message: '${snapshot.error}',
              tone: SpTone.danger,
            );
          }
          return _Statement(statement: snapshot.data!, onDownload: _download);
        },
      );
}

class _Statement extends StatelessWidget {
  final SaleClearance statement;
  final VoidCallback onDownload;

  const _Statement({required this.statement, required this.onDownload});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final override = statement.overrideRequest;
    return testId('sale_clearance_panel', Container(
      key: const Key('sale_clearance_panel'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Satış mutabakat bildirimi', style: theme.titleMedium)),
              testId('sale_clearance_download', IconButton(
                key: const Key('sale_clearance_download'),
                tooltip: 'Bildirimi indir (CSV)',
                onPressed: onDownload,
                icon: const Icon(Icons.download_outlined),
              )),
            ],
          ),
          if (statement.sellerName != null) Text('Satıcı: ${statement.sellerName}'),
          const SizedBox(height: AppSpacing.sm),
          _line(context, 'Satıcının açık borcu', statement.openDebtTotal, key: 'sale_clearance_open_debt', bold: true),
          _line(context, 'Anapara', statement.openDebtPrincipal, key: 'sale_clearance_principal'),
          _line(context, 'Gecikme bedeli', statement.openDebtFee, key: 'sale_clearance_fee'),
          for (final debt in statement.debts)
            _line(
              context,
              '${debt.period}  (anapara ${formatTry(debt.principal)}, gecikme ${formatTry(debt.fee)})',
              debt.total,
              indent: true,
            ),
          const Divider(),
          _line(context, 'Satıcının avansı', statement.advance, key: 'sale_clearance_advance'),
          const SizedBox(height: AppSpacing.sm),
          Text('Henüz tahakkuk etmemiş demirbaş taksitleri', style: theme.titleSmall),
          if (statement.upcomingInstallments.isEmpty)
            const Text('Yok.')
          else
            for (final item in statement.upcomingInstallments)
              _line(
                context,
                '${item.projectTitle} ${item.installmentNumber}/${item.totalInstallments}'
                '${item.dueDate == null ? '' : ' · ${item.dueDate!.toIso8601String().substring(0, 10)}'}',
                item.amount,
                indent: true,
              ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Mevcut borç satıcıda kalır. Henüz tahakkuk etmemiş taksitler, tahakkuk tarihindeki '
            'kat maliki olan alıcıya yazılır; ikinci bir yetkili "satıcı öder" talebini onaylamadıkça.',
            style: theme.bodySmall,
          ),
          if (override != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                const Text('Satıcı öder talebi: '),
                SpStatusBadge(
                  label: override.status,
                  tone: switch (override.status) {
                    'APPROVED' => SpTone.success,
                    'REJECTED' => SpTone.danger,
                    _ => SpTone.warning,
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    ));
  }

  Widget _line(BuildContext context, String label, Decimal amount, {String? key, bool bold = false, bool indent = false}) {
    final style = bold ? const TextStyle(fontWeight: FontWeight.bold) : null;
    final value = Text(formatTry(amount), style: style);
    final row = Padding(
      padding: EdgeInsets.only(left: indent ? AppSpacing.md : 0, top: 2, bottom: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          value,
        ],
      ),
    );
    return key == null ? row : testId(key, KeyedSubtree(key: Key(key), child: row));
  }
}
