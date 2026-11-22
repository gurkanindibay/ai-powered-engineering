import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../domain/models/payments_phase2_models.dart';
import '../../domain/models/payments_phase3_models.dart';
import '../../domain/services/payments_phase3_api.dart';
import '../../domain/services/platform_env.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../components/sp_dialog_pages.dart';
import '../design_system/money_formatter.dart';
import '../design_system/sp_feedback.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../design_system/sp_typography.dart';
import '../theme/app_theme.dart';

/// The sum of the selected open items (the designated payment amount).
Decimal designatedTotal(
  Iterable<StatementOpenItem> items,
  Set<String> selected,
) => items
    .where((i) => selected.contains(i.dueId))
    .fold(Decimal.zero, (sum, i) => sum + i.totalOutstanding);

/// SPEC-009 R5: choose which debts to pay (TBK 101), dispute an item, and ask
/// for a virman. Shown under the resident's statement.
class StatementSelfService extends StatefulWidget {
  final String unitId;
  final ResidentStatement statement;
  final VoidCallback onChanged;

  const StatementSelfService({
    super.key,
    required this.unitId,
    required this.statement,
    required this.onChanged,
  });

  @override
  State<StatementSelfService> createState() => _StatementSelfServiceState();
}

class _StatementSelfServiceState extends State<StatementSelfService> {
  final Set<String> _selected = {};
  bool _saveCard = false;
  bool _busy = false;

  /// The dues the resident can pay here, one entry per due id.
  ///
  /// A tenant charge with joint owners reaches the manager's statement once per
  /// debtor section -- the tenant's own open items and a copy in each former
  /// joint owner's section -- so counting every section would add the same
  /// amount twice to the designated payment total.
  List<StatementOpenItem> get _items {
    final byDueId = <String, StatementOpenItem>{};
    for (final d in widget.statement.debtors) {
      for (final i in d.openItems) {
        byDueId.putIfAbsent(i.dueId, () => i);
      }
    }
    for (final i in _jointItems) {
      byDueId.putIfAbsent(i.dueId, () => i);
    }
    return byDueId.values.toList();
  }

  /// Joint liability that is not already an item of a section of its own: these
  /// are the ones the resident pays on another debtor's behalf.
  List<StatementOpenItem> get _jointItems {
    final ownDueIds = {
      for (final d in widget.statement.debtors)
        for (final i in d.openItems) i.dueId,
    };
    final byDueId = <String, StatementOpenItem>{};
    for (final d in widget.statement.debtors) {
      for (final i in d.jointlyLiableOpenItems) {
        if (!ownDueIds.contains(i.dueId)) {
          byDueId.putIfAbsent(i.dueId, () => i);
        }
      }
    }
    return byDueId.values.toList();
  }

  Set<String> get _jointDueIds => _jointItems.map((item) => item.dueId).toSet();

  Future<void> _pay() async {
    final total = designatedTotal(_items, _selected);
    if (total <= Decimal.zero) return;
    setState(() => _busy = true);
    try {
      final intent = await PaymentsPhase3Api.payDesignated(
        widget.unitId,
        total,
        _selected.toList(),
        saveCard: _saveCard,
        paysTenantLiability: _selected.any(_jointDueIds.contains),
      );
      final url = intent.checkoutUrl;
      if (url != null) openUrlInNewTab(url);
      if (mounted)
        SpToast.info(
          context,
          'Ödeme sayfası açıldı. Ödeme onaylanınca seçtiğiniz borçlar kapanır.',
        );
    } catch (e) {
      if (mounted) SpToast.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dispute(StatementOpenItem item) async {
    final reason = await showSpTextPrompt(
      context: context,
      title: 'Borca itiraz et',
      label: 'İtiraz gerekçesi',
      message:
          '${item.period} · ${formatTry(item.totalOutstanding)}. İtiraz sonuçlanana kadar bu borç için hatırlatma gönderilmez.',
      minLength: 5,
    );
    if (reason == null) return;
    try {
      await PaymentsPhase3Api.dispute(widget.unitId, item.dueId, reason);
      if (mounted) SpToast.success(context, 'İtirazınız yönetime iletildi.');
      widget.onChanged();
    } catch (e) {
      if (mounted) SpToast.error(context, e.toString());
    }
  }

  Future<void> _virman(StatementDebtor debtor) async {
    final note = await showSpTextPrompt(
      context: context,
      title: 'Virman talebi',
      label: 'Not',
      message:
          '${formatTry(debtor.advanceBalance)} avans bakiyenizin diğer cari hesaba aktarılmasını yönetimden talep edin.',
      minLength: 0,
      submitLabel: 'Talep et',
    );
    if (note == null) return;
    try {
      await PaymentsPhase3Api.requestVirman(
        widget.unitId,
        debtor.advanceBalance,
        note: note,
      );
      if (mounted) SpToast.success(context, 'Virman talebi gönderildi.');
      widget.onChanged();
    } catch (e) {
      if (mounted) SpToast.error(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = designatedTotal(_items, _selected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Ödeme ve talepler',
          style: TextStyle(
            color: AppColors.textPrimary(context),
            fontSize: SpFontSize.title,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_items.isEmpty)
          Text(
            'Açık borcunuz yok.',
            style: TextStyle(
              color: AppColors.textSecondary(context),
              fontSize: SpFontSize.body,
            ),
          ),
        for (final i in _items)
          testId(
            'designate_${i.dueId}',
            CheckboxListTile(
              key: Key('designate_${i.dueId}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _selected.contains(i.dueId),
              onChanged: (v) => setState(() {
                if (v != true) {
                  _selected.remove(i.dueId);
                  return;
                }
                final isJointLiability = _jointDueIds.contains(i.dueId);
                _selected.removeWhere(
                  (selectedId) =>
                      _jointDueIds.contains(selectedId) != isJointLiability,
                );
                _selected.add(i.dueId);
              }),
              title: Text(
                '${i.period} · ${formatTry(i.totalOutstanding)}${_jointDueIds.contains(i.dueId) ? ' · müşterek sorumluluk' : ''}',
                style: TextStyle(
                  color: AppColors.textPrimary(context),
                  fontSize: SpFontSize.body,
                ),
              ),
              secondary: _jointDueIds.contains(i.dueId)
                  ? null
                  : testId(
                      'dispute_${i.dueId}',
                      IconButton(
                        key: Key('dispute_${i.dueId}'),
                        tooltip: 'İtiraz et',
                        icon: const Icon(Icons.report_problem_outlined),
                        onPressed: () => _dispute(i),
                      ),
                    ),
            ),
          ),
        if (_items.isNotEmpty) ...[
          testId(
            'designate_save_card',
            SwitchListTile(
              key: const Key('designate_save_card'),
              contentPadding: EdgeInsets.zero,
              value: _saveCard,
              onChanged: (v) => setState(() => _saveCard = v),
              title: Text(
                'Kartımı otomatik ödeme için kaydet',
                style: TextStyle(
                  color: AppColors.textPrimary(context),
                  fontSize: SpFontSize.body,
                ),
              ),
              subtitle: Text(
                'Kart bilgileri lisanslı ödeme kuruluşunda saklanır; SitePulse yalnızca son 4 haneyi görür.',
                style: TextStyle(
                  color: AppColors.textSecondary(context),
                  fontSize: SpFontSize.caption,
                ),
              ),
            ),
          ),
          testId(
            'designate_pay',
            FilledButton.icon(
              key: const Key('designate_pay'),
              icon: const Icon(Icons.credit_card),
              label: Text(
                _selected.isEmpty
                    ? 'Ödenecek borçları seçin'
                    : 'Seçilenleri öde · ${formatTry(total)}',
              ),
              onPressed: _selected.isEmpty || _busy ? null : _pay,
            ),
          ),
        ],
        for (final d in widget.statement.debtors.where(
          (d) => d.advanceBalance > Decimal.zero,
        ))
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: testId(
              'virman_request_${d.debtorType.toLowerCase()}',
              OutlinedButton.icon(
                key: Key('virman_request_${d.debtorType.toLowerCase()}'),
                icon: const Icon(Icons.swap_horiz),
                label: Text(
                  'Avansımı diğer hesaba aktar (${formatTry(d.advanceBalance)})',
                ),
                onPressed: () => _virman(d),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          children: [
            testId(
              'open_autopay',
              TextButton.icon(
                key: const Key('open_autopay'),
                icon: const Icon(Icons.autorenew),
                label: const Text('Otomatik ödeme'),
                onPressed: () => AppFullscreenPage.push(
                  context: context,
                  builder: (_) => ResidentAutopayPage(unitId: widget.unitId),
                ),
              ),
            ),
            testId(
              'open_privacy',
              TextButton.icon(
                key: const Key('open_privacy'),
                icon: const Icon(Icons.privacy_tip_outlined),
                label: const Text('Gizlilik ve izinler'),
                onPressed: () => AppFullscreenPage.push(
                  context: context,
                  builder: (_) => const ResidentPrivacyPage(),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// SPEC-009 R6: saved cards (provider tokens) and autopay mandates.
class ResidentAutopayPage extends StatefulWidget {
  final String unitId;
  const ResidentAutopayPage({super.key, required this.unitId});

  @override
  State<ResidentAutopayPage> createState() => _ResidentAutopayPageState();
}

class _ResidentAutopayPageState extends State<ResidentAutopayPage> {
  late Future<AutopayOverviewData> _future = PaymentsPhase3Api.autopay(
    widget.unitId,
  );

  void _reload() =>
      setState(() => _future = PaymentsPhase3Api.autopay(widget.unitId));

  Future<void> _act(Future<void> Function() action, String ok) async {
    try {
      await action();
      if (mounted) SpToast.success(context, ok);
      _reload();
    } catch (e) {
      if (mounted) SpToast.error(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppFullscreenPage(
      title: 'Otomatik Ödeme',
      icon: const Icon(Icons.autorenew, color: AppColors.accentCyan),
      child: FutureBuilder<AutopayOverviewData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done)
            return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return SpGuidanceCard(
              icon: Icons.error_outline,
              title: 'Bilgi alınamadı',
              message: snap.error.toString(),
              tone: SpTone.danger,
            );
          }
          final data = snap.data!;
          if (data.cards.isEmpty) {
            return const SpGuidanceCard(
              icon: Icons.credit_card_off_outlined,
              title: 'Kayıtlı kart yok',
              message: 'Ekstreden kartla öderken "Kartımı kaydet" seçeneğini işaretleyin; kart lisanslı ödeme kuruluşunda saklanır.',
            );
          }
          final active = data.mandates
              .where((m) => m.status == 'ACTIVE')
              .toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final c in data.cards)
                testId(
                  'saved_card_${c.id}',
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.credit_card),
                    title: Text('${c.brand} •••• ${c.last4}'),
                    subtitle: Text(
                      'Son kullanma ${c.expMonth.toString().padLeft(2, '0')}/${c.expYear}',
                    ),
                    trailing: active.isEmpty && c.status == 'ACTIVE'
                        ? testId(
                            'autopay_enable_${c.id}',
                            FilledButton(
                              key: Key('autopay_enable_${c.id}'),
                              onPressed: () => _act(
                                () => PaymentsPhase3Api.createMandate(
                                  widget.unitId,
                                  c.id,
                                ),
                                'Otomatik ödeme açıldı.',
                              ),
                              child: const Text('Otomatik öde'),
                            ),
                          )
                        : SpStatusBadge(
                            label: c.status,
                            tone: c.status == 'ACTIVE'
                                ? SpTone.success
                                : SpTone.warning,
                          ),
                  ),
                ),
              const SizedBox(height: AppSpacing.md),
              for (final m in data.mandates)
                testId(
                  'mandate_${m.id}',
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Talimat #${m.id} · ${m.debtorType == 'TENANT' ? 'Kiracı' : 'Kat maliki'}',
                    ),
                    subtitle: Text(
                      m.suspendedReason ?? 'Vadesi gelen borçlar kayıtlı karttan tahsil edilir; red durumunda 2. ve 5. gün tekrar denenir.',
                    ),
                    trailing: m.status == 'ACTIVE'
                        ? testId(
                            'mandate_cancel_${m.id}',
                            TextButton(
                              key: Key('mandate_cancel_${m.id}'),
                              onPressed: () => _act(
                                () => PaymentsPhase3Api.cancelMandate(
                                  widget.unitId,
                                  m.id,
                                ),
                                'Talimat iptal edildi.',
                              ),
                              child: const Text('İptal'),
                            ),
                          )
                        : SpStatusBadge(label: m.status, tone: SpTone.neutral),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// SPEC-009 R2: the site's privacy notice and the resident's channel consents.
class ResidentPrivacyPage extends StatefulWidget {
  const ResidentPrivacyPage({super.key});

  @override
  State<ResidentPrivacyPage> createState() => _ResidentPrivacyPageState();
}

class _ResidentPrivacyPageState extends State<ResidentPrivacyPage> {
  late Future<PrivacyStatus> _future = PaymentsPhase3Api.privacyStatus();

  Future<void> _update(Future<PrivacyStatus> Function() action) async {
    try {
      final status = await action();
      if (mounted) setState(() => _future = Future.value(status));
    } catch (e) {
      if (mounted) SpToast.error(context, e.toString());
    }
  }

  static const _channelLabels = {
    'EMAIL': 'E-posta',
    'SMS': 'SMS',
    'PUSH': 'Uygulama bildirimi',
    'WHATSAPP': 'WhatsApp (doğrudan)',
  };

  @override
  Widget build(BuildContext context) {
    return AppFullscreenPage(
      title: 'Gizlilik ve İzinler',
      icon: const Icon(Icons.privacy_tip_outlined, color: AppColors.accentCyan),
      child: FutureBuilder<PrivacyStatus>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done)
            return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return SpGuidanceCard(
              icon: Icons.error_outline,
              title: 'Bilgi alınamadı',
              message: snap.error.toString(),
              tone: SpTone.danger,
            );
          }
          final s = snap.data!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (s.noticeBody == null)
                const SpGuidanceCard(
                  icon: Icons.policy_outlined,
                  title: 'Aydınlatma metni yok',
                  message: 'Site yönetimi henüz aydınlatma metni yayınlamadı.',
                )
              else ...[
                Text(
                  '${s.noticeTitle} (sürüm ${s.noticeVersion})',
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontSize: SpFontSize.title,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  s.noticeBody!,
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontSize: SpFontSize.body,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                s.acknowledged
                    ? const SpStatusBadge(
                        label: 'Okudum, anladım',
                        tone: SpTone.success,
                        icon: Icons.check,
                      )
                    : testId(
                        'privacy_acknowledge',
                        FilledButton(
                          key: const Key('privacy_acknowledge'),
                          onPressed: () =>
                              _update(PaymentsPhase3Api.acknowledgePrivacy),
                          child: const Text('Okudum, anladım'),
                        ),
                      ),
              ],
              const SizedBox(height: AppSpacing.xl),
              Text(
                'Bildirim kanalları',
                style: TextStyle(
                  color: AppColors.textPrimary(context),
                  fontSize: SpFontSize.title,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Borç bildirimleri yalnızca size özel kanallardan gönderilir, hiçbir zaman grup sohbetine veya panoya yazılmaz. Hatırlatmaları kapatabilirsiniz; yasal ihtarlar yine gönderilir.',
                style: TextStyle(
                  color: AppColors.textSecondary(context),
                  fontSize: SpFontSize.caption,
                ),
              ),
              for (final c in s.consents)
                testId(
                  'consent_${c.channel.toLowerCase()}',
                  SwitchListTile(
                    key: Key('consent_${c.channel.toLowerCase()}'),
                    contentPadding: EdgeInsets.zero,
                    value: c.granted,
                    title: Text(_channelLabels[c.channel] ?? c.channel),
                    onChanged: (v) => _update(
                      () => PaymentsPhase3Api.setConsent(c.channel, v),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
