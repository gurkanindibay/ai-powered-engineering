import 'package:flutter/material.dart';

import '../../domain/models/payments_phase3_models.dart';
import '../../domain/services/payments_phase3_api.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../design_system/money_formatter.dart';
import '../design_system/sp_feedback.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';

/// Four-eyes approval queue for advance payouts and debtor transfers.
class AdvanceExitSettlementQueuePage extends StatefulWidget {
  const AdvanceExitSettlementQueuePage({super.key});

  static Future<void> open(BuildContext context) =>
      AppFullscreenPage.push<void>(
        context: context,
        builder: (_) => const AdvanceExitSettlementQueuePage(),
      );

  @override
  State<AdvanceExitSettlementQueuePage> createState() =>
      _AdvanceExitSettlementQueuePageState();
}

class _AdvanceExitSettlementQueuePageState
    extends State<AdvanceExitSettlementQueuePage> {
  late Future<List<AdvanceExitSettlement>> _settlements;
  int? _workingId;

  @override
  void initState() {
    super.initState();
    _settlements = PaymentsPhase3Api.advanceExitSettlements();
  }

  void _reload() =>
      setState(() => _settlements = PaymentsPhase3Api.advanceExitSettlements());

  Future<void> _decide(
    AdvanceExitSettlement item, {
    required bool approve,
    String? paymentReference,
    String? note,
  }) async {
    setState(() => _workingId = item.id);
    try {
      await PaymentsPhase3Api.decideAdvanceExitSettlement(
        item.id,
        approve: approve,
        paymentReference: paymentReference,
        note: note,
      );
      if (!mounted) return;
      SpToast.success(
        context,
        approve
            ? 'Çıkış avans talebi onaylandı.'
            : 'Çıkış avans talebi reddedildi.',
      );
      _reload();
    } catch (error) {
      if (mounted) {
        // The API message includes the four-eyes distinct-person rule when the
        // requester attempts to approve their own settlement.
        SpToast.error(context, error.toString());
      }
    } finally {
      if (mounted) setState(() => _workingId = null);
    }
  }

  @override
  Widget build(BuildContext context) => AppFullscreenPage(
    title: 'Çıkış avans talepleri',
    subtitle: 'Ödeme veya başka borçluya aktarım için dört göz onayı',
    icon: const Icon(
      Icons.assignment_turned_in_outlined,
      color: AppColors.accentCyan,
    ),
    actions: [
          testId('advance_exit_settlement_refresh', IconButton(
            key: const Key('advance_exit_settlement_refresh'),
            tooltip: 'Yenile',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          )),
    ],
    child: FutureBuilder<List<AdvanceExitSettlement>>(
      future: _settlements,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return SpGuidanceCard(
            icon: Icons.error_outline,
            title: 'Talepler yüklenemedi',
            message: snapshot.error.toString(),
            tone: SpTone.danger,
                action: testId('advance_exit_settlement_retry', OutlinedButton.icon(
                  key: const Key('advance_exit_settlement_retry'),
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Yeniden dene'),
                )),
          );
        }
        final pending = (snapshot.data ?? const <AdvanceExitSettlement>[])
            .where((item) => item.status == 'PENDING')
            .toList();
        if (pending.isEmpty) {
          return const SpGuidanceCard(
            icon: Icons.check_circle_outline,
            title: 'Bekleyen çıkış avans talebi yok',
            message: 'Yeni payout ve borçlu aktarım talepleri burada görünür.',
            tone: SpTone.neutral,
          );
        }
        return ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          children: [
            for (final item in pending)
              _AdvanceExitSettlementCard(
                key: ValueKey(item.id),
                item: item,
                working: _workingId == item.id,
                onDecision: (approve, paymentReference, note) => _decide(
                  item,
                  approve: approve,
                  paymentReference: paymentReference,
                  note: note,
                ),
              ),
          ],
        );
      },
    ),
  );
}

class _AdvanceExitSettlementCard extends StatefulWidget {
  final AdvanceExitSettlement item;
  final bool working;
  final Future<void> Function(
    bool approve,
    String? paymentReference,
    String? note,
  )
  onDecision;

  const _AdvanceExitSettlementCard({
    super.key,
    required this.item,
    required this.working,
    required this.onDecision,
  });

  @override
  State<_AdvanceExitSettlementCard> createState() =>
      _AdvanceExitSettlementCardState();
}

class _AdvanceExitSettlementCardState
    extends State<_AdvanceExitSettlementCard> {
  final _referenceController = TextEditingController();
  final _noteController = TextEditingController();

  bool get _isPayout => widget.item.kind == 'PAYOUT';

  @override
  void dispose() {
    _referenceController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _approve() async {
    final reference = _referenceController.text.trim();
    if (_isPayout && reference.isEmpty) {
      SpToast.error(context, 'Ödeme referansı onay için zorunludur.');
      return;
    }
    await widget.onDecision(
      true,
      reference.isEmpty ? null : reference,
      _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
    );
  }

  Future<void> _reject() => widget.onDecision(
    false,
    null,
    _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
  );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final kindLabel = _isPayout ? 'Ödeme' : 'Borçluya aktarım';
    return testId('advance_exit_settlement_${item.id}', Container(
      key: Key('advance_exit_settlement_${item.id}'),
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
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
              Expanded(
                child: Text(
                  'Daire ${item.unitId} · $kindLabel',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              SpStatusBadge(label: item.status, tone: SpTone.warning),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text('Hak sahibi: ${item.beneficiaryName}'),
          if (item.beneficiaryPersonId?.isNotEmpty == true)
            Text('Kişi kaydı: ${item.beneficiaryPersonId}'),
          Text('Kaynak borçlu: ${item.sourceDebtor}'),
          if (!_isPayout) Text('Hedef borçlu: ${item.targetDebtor ?? '—'}'),
          Text('Tutar: ${formatTry(item.amount)}'),
          Text('Talep eden: ${item.requestedBy}'),
          if (item.note?.isNotEmpty == true) Text('Not: ${item.note}'),
          const SizedBox(height: AppSpacing.sm),
          if (_isPayout) ...[
            testId('advance_exit_payment_reference_${item.id}', TextField(
              key: Key('advance_exit_payment_reference_${item.id}'),
              controller: _referenceController,
              decoration: const InputDecoration(
                labelText: 'Ödeme referansı *',
                hintText: 'Banka işlem numarası veya makbuz numarası',
                border: OutlineInputBorder(),
              ),
            )),
            const SizedBox(height: AppSpacing.sm),
          ],
          testId('advance_exit_decision_note_${item.id}', TextField(
            key: Key('advance_exit_decision_note_${item.id}'),
            controller: _noteController,
            decoration: const InputDecoration(
              labelText: 'Karar notu (isteğe bağlı)',
              border: OutlineInputBorder(),
            ),
          )),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              testId(
                'advance_exit_approve_${item.id}',
                ElevatedButton(
                  key: Key('advance_exit_approve_${item.id}'),
                  onPressed: widget.working ? null : _approve,
                  child: const Text('Onayla'),
                ),
              ),
              testId(
                'advance_exit_reject_${item.id}',
                OutlinedButton(
                  key: Key('advance_exit_reject_${item.id}'),
                  onPressed: widget.working ? null : _reject,
                  child: const Text('Reddet'),
                ),
              ),
            ],
          ),
        ],
      ),
    ));
  }
}
