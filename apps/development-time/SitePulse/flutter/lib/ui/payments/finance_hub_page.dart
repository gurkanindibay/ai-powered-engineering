import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../domain/models/payments_phase3_models.dart';
import '../../domain/services/payments_phase3_api.dart';
import '../../domain/services/platform_env.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../components/sp_dialog_pages.dart';
import '../design_system/money_formatter.dart';
import '../design_system/sp_feedback.dart';
import '../design_system/sp_filter_chip.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_metric.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../design_system/sp_typography.dart';
import '../theme/app_theme.dart';

/// The manager's finance desk (SPEC-009): expenses with four-eyes approval,
/// the derived ledger and yearly account report, collections and payment
/// plans, resident requests, the decisions book, analytics and the KVKK log.
class FinanceHubPage extends StatelessWidget {
  final String siteName;
  const FinanceHubPage({super.key, required this.siteName});

  @override
  Widget build(BuildContext context) => AppFullscreenPage(
        title: 'Finans Masası',
        subtitle: siteName,
        icon: const Icon(Icons.account_balance_outlined, color: AppColors.accentCyan),
        child: const FinanceHubView(),
      );
}

/// The finance desk's content. [readOnly] is the auditor's (denetçi) view: the
/// books, collections, decisions, analytics and the access log, with expense
/// approval but no other changes and no resident requests.
class FinanceHubView extends StatefulWidget {
  final bool readOnly;
  const FinanceHubView({super.key, this.readOnly = false});

  @override
  State<FinanceHubView> createState() => _FinanceHubViewState();
}

enum FinanceSection { expenses, ledger, collections, requests, assembly, analytics, kvkk }

extension on FinanceSection {
  String get label => switch (this) {
        FinanceSection.expenses => 'Giderler',
        FinanceSection.ledger => 'Defter',
        FinanceSection.collections => 'Tahsilat',
        FinanceSection.requests => 'Talepler',
        FinanceSection.assembly => 'Karar defteri',
        FinanceSection.analytics => 'Analiz',
        FinanceSection.kvkk => 'KVKK',
      };
}

class _FinanceHubViewState extends State<FinanceHubView> {
  FinanceSection _section = FinanceSection.expenses;
  int _reload = 0;

  void _refresh() => setState(() => _reload++);

  Future<void> _run(Future<void> Function() action, String success) async {
    try {
      await action();
      if (!mounted) return;
      SpToast.success(context, success);
      _refresh();
    } catch (e) {
      if (mounted) SpToast.error(context, e.toString());
    }
  }

  bool get _manage => !widget.readOnly;

  @override
  Widget build(BuildContext context) {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final s in FinanceSection.values.where((s) => _manage || s != FinanceSection.requests))
                SpFilterChip(
                  id: 'finance_tab_${s.name}',
                  label: s.label,
                  selected: _section == s,
                  onSelected: () => setState(() => _section = s),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          KeyedSubtree(key: ValueKey('${_section.name}-$_reload'), child: _body()), // testid-lint: ignore
        ],
    );
  }

  Widget _body() => switch (_section) {
        FinanceSection.expenses => _Loader<List<ExpenseItem>>(load: PaymentsPhase3Api.expenses, build: _expenses),
        FinanceSection.ledger => _Loader<TrialBalanceData>(load: PaymentsPhase3Api.trialBalance, build: _ledger),
        FinanceSection.collections => _Loader<(List<CaseItem>, List<PlanItem>, List<AdjustmentItem>)>(
            load: () async => (await PaymentsPhase3Api.cases(), await PaymentsPhase3Api.plans(), await PaymentsPhase3Api.adjustments()),
            build: _collections,
          ),
        FinanceSection.requests => _Loader<(List<VirmanRequestItem>, List<DisputeItem>)>(
            load: () async => (await PaymentsPhase3Api.siteVirmanRequests(), await PaymentsPhase3Api.siteDisputes()),
            build: _requests,
          ),
        FinanceSection.assembly => _Loader<List<DecisionItem>>(load: PaymentsPhase3Api.decisions, build: _decisions),
        FinanceSection.analytics => _Loader<CollectionAnalyticsData>(load: PaymentsPhase3Api.analytics, build: _analytics),
        FinanceSection.kvkk => _Loader<List<AccessLogItem>>(load: PaymentsPhase3Api.accessLog, build: _kvkk),
      };

  // ---- expenses ----------------------------------------------------------

  Widget _expenses(BuildContext context, List<ExpenseItem> rows) {
    if (rows.isEmpty) {
      return const SpGuidanceCard(
        icon: Icons.receipt_outlined,
        title: 'Gider faturası yok',
        message: 'Tedarikçi faturaları kaydedildiğinde onay ve ödeme burada izlenir. Kaydeden kişi faturayı onaylayamaz; limit üstü faturalar denetçi onayı da ister.',
      );
    }
    return Column(children: [
      for (final e in rows)
        _Row(
          id: 'expense_${e.id}',
          title: '${e.vendorName} · ${e.invoiceNumber}',
          subtitle: '${e.category} · açık ${formatTry(e.open)}${e.needsAuditor ? ' · denetçi onayı bekleniyor' : ''}',
          amount: e.total,
          badge: SpStatusBadge(label: e.status, tone: _tone(e.status)),
          actions: [
            if (e.status == 'PENDING_APPROVAL') ...[
              _Action('expense_approve_${e.id}', 'Onayla', () => _run(() => PaymentsPhase3Api.approveExpense(e.id), 'Onay kaydedildi.')),
              _Action('expense_reject_${e.id}', 'Reddet', () async {
                final reason = await showSpTextPrompt(context: context, title: 'Faturayı reddet', label: 'Gerekçe');
                if (reason != null) await _run(() => PaymentsPhase3Api.rejectExpense(e.id, reason), 'Fatura reddedildi.');
              }),
            ],
            if (_manage && (e.status == 'APPROVED' || e.status == 'PARTIALLY_PAID'))
              _Action('expense_pay_${e.id}', 'Kalanı öde', () => _run(() => PaymentsPhase3Api.payExpense(e.id, e.open), 'Ödeme kaydedildi.')),
          ],
        ),
    ]);
  }

  // ---- ledger ------------------------------------------------------------

  Widget _ledger(BuildContext context, TrialBalanceData tb) {
    final year = DateTime.now().year;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: AppSpacing.xl, runSpacing: AppSpacing.md, children: [
          SpMetricValue(label: 'Toplam borç', value: formatTry(tb.totalDebit)),
          SpMetricValue(label: 'Toplam alacak', value: formatTry(tb.totalCredit)),
          SpMetricValue(label: 'Mizan', value: tb.balanced ? 'Denk' : 'Denk değil', tone: tb.balanced ? SpTone.success : SpTone.danger),
        ]),
        const SizedBox(height: AppSpacing.md),
        testId('finance_account_report_pdf', OutlinedButton.icon(
          key: const Key('finance_account_report_pdf'),
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: Text('$year hesap raporu (KMK 35)'),
          onPressed: () => _download(() => PaymentsPhase3Api.accountReportPdf(year), 'hesap-raporu-$year.pdf'),
        )),
        const SizedBox(height: AppSpacing.md),
        for (final r in tb.rows)
          testId('trial_balance_${r.code}', Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(children: [
              SizedBox(width: 64, child: Text(r.code, style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption))),
              Expanded(child: Text(r.name, style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.body))),
              Text(formatTry(r.balance), style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.body, fontWeight: FontWeight.w600)),
            ]),
          )),
      ],
    );
  }

  Future<void> _download(Future<List<int>> Function() load, String filename) async {
    try {
      final bytes = await load();
      final saved = downloadBytes(filename, bytes, 'application/pdf');
      if (!mounted) return;
      saved ? SpToast.success(context, '$filename indirildi.') : SpToast.warning(context, 'PDF indirme bu platformda desteklenmiyor.');
    } catch (e) {
      if (mounted) SpToast.error(context, e.toString());
    }
  }

  // ---- collections ---------------------------------------------------------

  Widget _collections(BuildContext context, (List<CaseItem>, List<PlanItem>, List<AdjustmentItem>) data) {
    final (cases, plans, adjustments) = data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_manage) testId('finance_run_dunning', FilledButton.icon(
          key: const Key('finance_run_dunning'),
          icon: const Icon(Icons.notifications_active_outlined),
          label: const Text('Hatırlatma planını çalıştır'),
          onPressed: () async {
            try {
              final r = await PaymentsPhase3Api.runDunning();
              if (!mounted) return;
              SpToast.info(this.context, '${r['sent']} gönderildi, ${r['blocked']} engellendi (KVKK), ${r['paused']} beklemede.');
            } catch (e) {
              if (mounted) SpToast.error(this.context, e.toString());
            }
          },
        )),
        const SizedBox(height: AppSpacing.lg),
        _heading(context, 'Takip dosyaları'),
        if (cases.isEmpty) _empty(context, 'Açık takip dosyası yok.'),
        for (final c in cases)
          _Row(
            id: 'case_${c.id}',
            title: '${c.unitLabel} · ${c.debtorType == 'TENANT' ? 'Kiracı' : 'Kat maliki'}',
            subtitle: [
              if (!c.evidenceReady) 'hukuki dayanak eksik',
              if (c.kmk25) 'KMK 25 eşiği',
              if (c.limitationWarnings > 0) 'zamanaşımı uyarısı',
              if (c.lawyerName != null) c.lawyerName!,
            ].join(' · '),
            amount: c.outstanding,
            badge: SpStatusBadge(label: c.status, tone: SpTone.warning),
            actions: [
              if (_manage && c.nextStatus != null)
                _Action('case_advance_${c.id}', 'İlerlet: ${c.nextStatus}', () async {
                  String? lawyer;
                  if (c.nextStatus == 'LAWYER_ASSIGNED') {
                    lawyer = await showSpTextPrompt(context: context, title: 'Avukat ata', label: 'Avukat adı');
                    if (lawyer == null) return;
                  }
                  await _run(() => PaymentsPhase3Api.advanceCase(c.id, c.nextStatus!, lawyerName: lawyer), 'Dosya güncellendi.');
                }),
              if (c.evidenceReady)
                _Action('case_pack_${c.id}', 'Delil dosyası', () => _download(() => PaymentsPhase3Api.evidencePackPdf(c.id), 'delil-dosyasi-${c.id}.pdf')),
            ],
          ),
        const SizedBox(height: AppSpacing.lg),
        _heading(context, 'Ödeme planları'),
        if (plans.isEmpty) _empty(context, 'Ödeme planı yok.'),
        for (final p in plans)
          _Row(
            id: 'plan_${p.id}',
            title: p.unitLabel,
            subtitle: '${p.installments.length} taksit · ödenen ${formatTry(p.paid)}',
            amount: p.total,
            badge: SpStatusBadge(label: p.status, tone: _tone(p.status)),
          ),
        const SizedBox(height: AppSpacing.lg),
        _heading(context, 'Vazgeçme ve silme onayları'),
        if (adjustments.where((a) => a.status == 'PENDING').isEmpty) _empty(context, 'Onay bekleyen kayıt yok.'),
        for (final a in adjustments.where((a) => a.status == 'PENDING'))
          _Row(
            id: 'adjustment_${a.id}',
            title: a.kind == 'PENALTY_WAIVER' ? 'Gecikme tazminatı vazgeçme' : 'Anapara silme',
            subtitle: '${a.reason} · talep: ${a.requestedBy}',
            amount: a.amount,
            badge: const SpStatusBadge(label: 'PENDING', tone: SpTone.warning),
            actions: [
              if (_manage) _Action('adjustment_approve_${a.id}', 'Onayla', () => _run(() => PaymentsPhase3Api.decideAdjustment(a.id, true), 'Onaylandı.')),
              if (_manage) _Action('adjustment_reject_${a.id}', 'Reddet', () => _run(() => PaymentsPhase3Api.decideAdjustment(a.id, false), 'Reddedildi.')),
            ],
          ),
      ],
    );
  }

  // ---- requests ----------------------------------------------------------

  Widget _requests(BuildContext context, (List<VirmanRequestItem>, List<DisputeItem>) data) {
    final (virman, disputes) = data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'Virman talepleri'),
        if (virman.isEmpty) _empty(context, 'Virman talebi yok.'),
        for (final v in virman)
          _Row(
            id: 'virman_request_${v.id}',
            title: 'Daire ${v.unitId}: ${v.sourceDebtor} → ${v.targetDebtor}',
            subtitle: v.note ?? '',
            amount: v.amount,
            badge: SpStatusBadge(label: v.status, tone: _tone(v.status)),
            actions: [
              if (v.status == 'PENDING') ...[
                _Action('virman_approve_${v.id}', 'Onayla', () => _run(() => PaymentsPhase3Api.decideVirman(v.id, true), 'Virman yapıldı.')),
                _Action('virman_reject_${v.id}', 'Reddet', () => _run(() => PaymentsPhase3Api.decideVirman(v.id, false), 'Talep reddedildi.')),
              ],
            ],
          ),
        const SizedBox(height: AppSpacing.lg),
        _heading(context, 'İtirazlar'),
        if (disputes.isEmpty) _empty(context, 'İtiraz yok.'),
        for (final d in disputes)
          _Row(
            id: 'dispute_${d.id}',
            title: 'Daire ${d.unitId} · borç #${d.dueId}',
            subtitle: d.resolutionNote ?? d.reason,
            badge: SpStatusBadge(label: d.status, tone: _tone(d.status)),
            actions: [
              if (d.status == 'OPEN') ...[
                for (final accept in [true, false])
                  _Action('dispute_${accept ? 'accept' : 'reject'}_${d.id}', accept ? 'Kabul et' : 'Reddet', () async {
                    final note = await showSpTextPrompt(context: context, title: 'İtirazı sonuçlandır', label: 'Açıklama');
                    if (note != null) await _run(() => PaymentsPhase3Api.resolveDispute(d.id, accept, note), 'İtiraz sonuçlandı.');
                  }),
              ],
            ],
          ),
      ],
    );
  }

  // ---- decisions, analytics, KVKK ------------------------------------------

  Widget _decisions(BuildContext context, List<DecisionItem> rows) {
    if (rows.isEmpty) {
      return const SpGuidanceCard(icon: Icons.gavel_outlined, title: 'Karar defteri boş', message: 'Genel kurul kararları numaralı olarak burada tutulur; bütçeye bağlı karar işletme projesini onaylar.');
    }
    return Column(children: [
      for (final d in rows)
        _Row(
          id: 'decision_${d.number}',
          title: 'Karar ${d.number}: ${d.title}',
          subtitle: '${d.decidedOn == null ? '' : DateFormat('dd.MM.yyyy').format(d.decidedOn!)} · kabul ${d.yes} / ret ${d.no}',
          badge: SpStatusBadge(label: d.outcome, tone: d.outcome == 'ACCEPTED' ? SpTone.success : SpTone.danger),
        ),
    ]);
  }

  Widget _analytics(BuildContext context, CollectionAnalyticsData a) {
    String pct(Decimal? v) => v == null ? '—' : '%${v.toStringAsFixed(1)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: AppSpacing.xl, runSpacing: AppSpacing.md, children: [
          SpMetricValue(label: 'Son 3 ay tahsilat', value: pct(a.trailingRate)),
          SpMetricValue(label: 'Dijital ödeme payı', value: pct(a.digitalShare)),
          SpMetricValue(label: 'Elle eşleştirmesiz', value: pct(a.zeroTouchShare)),
        ]),
        const SizedBox(height: AppSpacing.lg),
        _heading(context, 'Aylık tahsilat'),
        for (final m in a.months)
          testId('kpi_${m.month}', Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Text(
              '${m.month} · tahakkuk ${formatTry(m.principalDue)} · tahsilat ${pct(m.collectionRate)} · vadesinde ${pct(m.onTimeRate)} · DSO ${m.dsoDays?.toStringAsFixed(1) ?? '—'} gün',
              style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.body),
            ),
          )),
        const SizedBox(height: AppSpacing.lg),
        _heading(context, 'Riskli daireler'),
        if (a.atRisk.isEmpty) _empty(context, 'Riskli daire yok.'),
        for (final r in a.atRisk)
          _Row(
            id: 'risk_${r.unitLabel}',
            title: r.unitLabel,
            subtitle: 'Skor ${r.score}',
            amount: r.overdue,
            badge: SpStatusBadge(label: r.tier, tone: r.tier == 'HIGH' ? SpTone.danger : r.tier == 'MEDIUM' ? SpTone.warning : SpTone.neutral),
          ),
      ],
    );
  }

  Widget _kvkk(BuildContext context, List<AccessLogItem> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_manage) testId('kvkk_publish_notice', OutlinedButton.icon(
          key: const Key('kvkk_publish_notice'),
          icon: const Icon(Icons.policy_outlined),
          label: const Text('Aydınlatma metni yayınla'),
          onPressed: () async {
            final body = await showSpTextPrompt(
              context: context,
              title: 'Aydınlatma metni',
              label: 'Metin',
              message: 'Yeni sürüm yayınlanınca sakinler uygulamada onaylar (KVKK 10).',
              minLength: 20,
              maxLines: 10,
            );
            if (body != null) await _run(() => PaymentsPhase3Api.publishPrivacyNotice('Aydınlatma Metni', body), 'Yayınlandı.');
          },
        )),
        const SizedBox(height: AppSpacing.lg),
        _heading(context, 'Finansal veri erişim kaydı'),
        if (rows.isEmpty) _empty(context, 'Kayıt yok.'),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Text(
              '${r.at == null ? '' : DateFormat('dd.MM.yyyy HH:mm').format(r.at!.toLocal())} · ${r.action} · ${r.resource} · ${r.actor}',
              style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption),
            ),
          ),
      ],
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(text, style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.title, fontWeight: FontWeight.w700)),
      );

  Widget _empty(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(text, style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.body)),
      );

  SpTone _tone(String status) => switch (status) {
        'APPROVED' || 'PAID' || 'COMPLETED' || 'ACCEPTED' => SpTone.success,
        'REJECTED' || 'BROKEN' || 'CANCELLED' => SpTone.danger,
        'PENDING' || 'PENDING_APPROVAL' || 'OPEN' || 'PARTIALLY_PAID' || 'ACTIVE' => SpTone.warning,
        _ => SpTone.neutral,
      };
}

/// Loads one section and shows a skeleton, an error or the content.
class _Loader<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T) build;
  const _Loader({super.key, required this.load, required this.build});

  @override
  State<_Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<_Loader<T>> {
  late final Future<T> _future = widget.load();

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(padding: EdgeInsets.all(AppSpacing.xl), child: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError) {
            return testId('finance_section_error', SpGuidanceCard(
              icon: Icons.error_outline,
              title: 'Veri alınamadı',
              message: snap.error.toString(),
              tone: SpTone.danger,
            ));
          }
          return widget.build(context, snap.data as T);
        },
      );
}

class _Action {
  final String id;
  final String label;
  final VoidCallback onTap;
  const _Action(this.id, this.label, this.onTap);
}

/// One record: title, details, optional amount and status, and its actions.
class _Row extends StatelessWidget {
  final String id;
  final String title;
  final String subtitle;
  final Decimal? amount;
  final Widget? badge;
  final List<_Action> actions;

  const _Row({required this.id, required this.title, required this.subtitle, this.amount, this.badge, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return testId(id, Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(title, style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.body, fontWeight: FontWeight.w700))),
            if (amount != null) Text(formatTry(amount!), style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.body, fontWeight: FontWeight.w600)),
            if (badge != null) ...[const SizedBox(width: AppSpacing.sm), badge!],
          ]),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(subtitle, style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption)),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(spacing: AppSpacing.sm, children: [
              for (final a in actions)
                testId(a.id, TextButton(key: Key(a.id), onPressed: a.onTap, child: Text(a.label))),
            ]),
          ],
        ],
      ),
    ));
  }
}
