import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../components/sp_dialog_pages.dart';

import '../design_system/sp_typography.dart';
import 'package:intl/intl.dart';

import '../../domain/models/payments_phase2_models.dart';
import '../../domain/services/payments_phase2_api.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../design_system/money_formatter.dart';
import '../design_system/sp_feedback.dart';
import '../design_system/sp_money_field.dart';
import '../theme/app_theme.dart';

/// İşletme projesi (KMK 35/37 as amended by Law 7579): the manager drafts the
/// yearly budget, issues it as an interim project (capped by the revaluation
/// rate) or records the assembly's approval, serves it on the owners, handles
/// objections and finalizes it. Monthly dues are accrued from its unit shares.
class OperatingBudgetPage extends StatefulWidget {
  final String? siteId;
  final String siteName;

  const OperatingBudgetPage({super.key, required this.siteId, required this.siteName});

  @override
  State<OperatingBudgetPage> createState() => _OperatingBudgetPageState();
}

class _OperatingBudgetPageState extends State<OperatingBudgetPage> {
  BudgetCompliance? _compliance;
  List<OperatingBudget> _budgets = const [];
  String? _error;
  bool _loading = true;
  bool _prorationEnabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        PaymentsPhase2Api.compliance(siteId: widget.siteId),
        PaymentsPhase2Api.budgets(siteId: widget.siteId),
        PaymentsPhase2Api.prorationPolicy(siteId: widget.siteId),
      ]);
      if (!mounted) return;
      setState(() {
        _compliance = results[0] as BudgetCompliance;
        _budgets = results[1] as List<OperatingBudget>;
        _prorationEnabled = results[2] as bool;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<Object?> Function() action, String success) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      messenger.showSnackBar(appSnackBar(content: Text(success), backgroundColor: AppColors.successFill));
      await _load();
    } catch (e) {
      messenger.showSnackBar(appSnackBar(content: Text(e.toString()), backgroundColor: AppColors.dangerFill, duration: const Duration(seconds: 6)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppFullscreenPage(
      title: 'İşletme Projesi',
      subtitle: widget.siteName,
      icon: const Icon(Icons.account_tree_outlined, color: AppColors.accentCyan),
      actions: [
        IconButton(tooltip: 'Yenile', onPressed: _load, icon: const Icon(Icons.refresh)),
      ],
      bottomBar: AppFullscreenPage.buildBottomBar(context: context, children: [
        testId('budget_new_button', ElevatedButton.icon(
          onPressed: _openCreate,
          icon: const Icon(Icons.add),
          label: const Text('Yeni bütçe taslağı'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primaryFill,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        )),
      ]),
      child: _loading && _compliance == null
          ? const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_error != null)
                  Text('Yüklenemedi: $_error', style: TextStyle(color: AppColors.dangerText(context))),
                if (_compliance != null) _complianceCard(_compliance!),
                const SizedBox(height: 14),
                if (_budgets.isEmpty)
                  Text('Henüz bütçe yok. Yeni bir taslak oluşturun.', style: TextStyle(color: AppColors.textSecondary(context))),
                for (final b in _budgets) ...[_budgetCard(b), const SizedBox(height: 12)],
              ],
            ),
    );
  }

  Widget _complianceCard(BudgetCompliance c) {
    final ok = c.budgetInForce != null;
    return testId('budget_compliance', Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ok ? AppColors.border(context) : AppColors.accentOrange),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(ok ? Icons.verified_outlined : Icons.warning_amber_rounded,
                color: ok ? AppColors.successText(context) : AppColors.warningText(context)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ok
                    ? 'Yürürlükte: ${c.budgetInForce!.fiscalYear} · ${c.budgetInForce!.statusLabel}'
                    : 'Yürürlükte işletme projesi yok',
                style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.w700),
              ),
            ),
          ]),
          for (final w in c.warnings)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('• $w', style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption)),
            ),
          const SizedBox(height: 6),
          testId('budget_policy_switch', SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Bütçesiz aidat tahakkukunu engelle', style: TextStyle(fontSize: SpFontSize.body)),
            subtitle: const Text('Açıkken aidat yalnızca yürürlükteki projenin paylarından tahakkuk eder.', style: TextStyle(fontSize: SpFontSize.caption)),
            value: c.requireOperatingBudget,
            onChanged: (v) => _run(() => PaymentsPhase2Api.setPolicy(v, siteId: widget.siteId), v ? 'Bütçe zorunlu' : 'Bütçe zorunluluğu kaldırıldı'),
          )),
          testId('occupancy_proration_switch', SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('İşgal süresine göre aidat paylaştır', style: TextStyle(fontSize: SpFontSize.body)),
            subtitle: const Text('Varsayılan kapalıdır. Yalnızca yönetim planınız izin veriyorsa açın; hukuki uygunluk ayrıca doğrulanmalıdır.', style: TextStyle(fontSize: SpFontSize.caption)),
            value: _prorationEnabled,
            onChanged: (v) => _run(() async {
              final enabled = await PaymentsPhase2Api.setProrationPolicy(v, siteId: widget.siteId);
              if (mounted) setState(() => _prorationEnabled = enabled);
              return null;
            }, v ? 'İşgal süresiyle orantılı tahakkuk açıldı' : 'İşgal süresiyle orantılı tahakkuk kapatıldı'),
          )),
        ],
      ),
    ));
  }

  Widget _budgetCard(OperatingBudget b) {
    final pct = b.increaseRate == null ? '-' : '%${b.increaseRate!.toStringAsFixed(2)}';
    final openObjections = b.objections.where((o) => o.status == 'OPEN').toList();
    return testId('budget_card_${b.id}', Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text('${b.fiscalYear} işletme projesi · #${b.id}',
                  style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.w700)),
            ),
            testId('budget_status_${b.id}', Text(b.statusLabel, style: TextStyle(color: AppColors.primaryText(context), fontSize: SpFontSize.caption))),
          ]),
          const SizedBox(height: 6),
          Text(
            'Yıllık ${formatTry(b.totalAnnualAmount)} · önceki ${formatTry(b.baselineAnnualAmount)} · artış $pct'
            '${b.capRate == null ? '' : ' (sınır %${b.capRate!.toStringAsFixed(2)})'}',
            style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption),
          ),
          if (b.assemblyDecisionRef != null)
            Text('Genel kurul kararı: ${b.assemblyDecisionRef}', style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption)),
          if (b.interimDeadline != null && b.status == 'INTERIM')
            Text('Genel kurula sunma son tarihi: ${_d(b.interimDeadline)}', style: TextStyle(color: AppColors.warningText(context), fontSize: SpFontSize.caption)),
          if (b.objectionDeadline != null && b.status == 'APPROVED')
            Text('İtiraz süresi sonu: ${_d(b.objectionDeadline)} · tebliğ ${b.servedUnitIds.length}/${b.unitShares.length}',
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption)),
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Kalemler ve daire payları (${b.unitShares.length} daire)', style: const TextStyle(fontSize: SpFontSize.body)),
            children: [
              for (final l in b.lines)
                _row(budgetCategories[l.category] ?? l.category,
                    '${formatTry(l.annualAmount)} · ${l.allocationKey == 'EQUAL' ? 'eşit' : 'arsa payı'}'),
              const Divider(),
              for (final s in b.unitShares)
                _row('${s.unitLabel} (arsa payı ${s.landShare})', '${formatTry(s.monthlyAmount)} / ay',
                    trailing: b.status == 'APPROVED' && !b.servedUnitIds.contains(s.unitId)
                        ? TextButton(onPressed: () => _serve(b, s), child: const Text('Tebliğ'))
                        : null),
            ],
          ),
          for (final o in openObjections)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                Expanded(child: Text('İtiraz: ${o.objectorName} — ${o.reason}', style: const TextStyle(fontSize: SpFontSize.caption))),
                TextButton(
                  onPressed: () => _run(() => PaymentsPhase2Api.resolveObjection(b.id, o.id, 'DISMISSED', siteId: widget.siteId), 'İtiraz reddedildi'),
                  child: const Text('Reddet'),
                ),
                TextButton(
                  onPressed: () => _run(() => PaymentsPhase2Api.resolveObjection(b.id, o.id, 'UPHELD', siteId: widget.siteId), 'İtiraz kabul edildi'),
                  child: const Text('Kabul'),
                ),
              ]),
            ),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: _actions(b)),
        ],
      ),
    ));
  }

  List<Widget> _actions(OperatingBudget b) {
    final site = widget.siteId;
    switch (b.status) {
      case 'DRAFT':
        return [
          testId('budget_issue_interim_${b.id}', OutlinedButton(
            onPressed: () => _run(() => PaymentsPhase2Api.issueInterim(b.id, siteId: site), 'Geçici proje yürürlüğe girdi'),
            child: const Text('Geçici proje olarak yayımla'),
          )),
          testId('budget_approve_${b.id}', OutlinedButton(onPressed: () => _approve(b), child: const Text('Genel kurul onayı'))),
          TextButton(
            onPressed: () => _run(() => PaymentsPhase2Api.deleteDraft(b.id, siteId: site), 'Taslak silindi'),
            child: const Text('Sil'),
          ),
        ];
      case 'INTERIM':
        return [
          testId('budget_approve_${b.id}', OutlinedButton(onPressed: () => _approve(b), child: const Text('Genel kurul onayı'))),
          TextButton(onPressed: () => _reject(b), child: const Text('Reddet')),
        ];
      case 'APPROVED':
        return [
          OutlinedButton(onPressed: () => _object(b), child: const Text('İtiraz kaydet')),
          testId('budget_finalize_${b.id}', OutlinedButton(
            onPressed: () => _run(() => PaymentsPhase2Api.finalize(b.id, siteId: site), 'Proje kesinleşti'),
            child: const Text('Kesinleştir'),
          )),
          TextButton(onPressed: () => _reject(b), child: const Text('Reddet')),
        ];
      default:
        return const [];
    }
  }

  Widget _row(String label, String value, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.caption))),
          Text(value, style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.caption)),
          ?trailing,
        ]),
      );

  String _d(DateTime? d) => d == null ? '-' : DateFormat('dd.MM.yyyy').format(d);

  Future<String?> _ask(String title, String label) async {
    final ctrl = TextEditingController();
    final ok = await showSpPage<bool>(
      context: context,
      builder: (ctx) => SpAlertPage(
        title: Text(title),
        content: TextField(controller: ctrl, autofocus: true, decoration: InputDecoration(labelText: label, border: const OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Kaydet')),
        ],
      ),
    );
    final text = ctrl.text.trim();
    ctrl.dispose();
    return ok == true && text.isNotEmpty ? text : null;
  }

  Future<void> _approve(OperatingBudget b) async {
    final ref = await _ask('Genel kurul onayı', 'Karar defteri referansı (ör. Karar 2026/3)');
    if (ref == null || !mounted) return;
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(DateTime.now().year - 2),
      lastDate: DateTime.now(),
      helpText: 'Genel kurul karar tarihi',
    );
    if (date == null) return;
    await _run(() => PaymentsPhase2Api.approve(b.id, ref, date, siteId: widget.siteId), 'Genel kurul onayı kaydedildi');
  }

  Future<void> _reject(OperatingBudget b) async {
    final reason = await _ask('Bütçeyi reddet', 'Gerekçe');
    if (reason == null) return;
    await _run(() => PaymentsPhase2Api.reject(b.id, reason, siteId: widget.siteId), 'Bütçe reddedildi');
  }

  Future<void> _serve(OperatingBudget b, BudgetUnitShare s) async {
    final recipient = await _ask('${s.unitLabel} tebliğ', 'Tebliğ edilen kişi');
    if (recipient == null || !mounted) return;
    final method = await showSpSelection<String>(
      context: context,
      title: 'Tebliğ yöntemi',
      options: const ['IN_ASSEMBLY', 'SIGNATURE', 'REGISTERED_MAIL', 'E_NOTIFICATION'],
      labelOf: (m) => const {
        'IN_ASSEMBLY': 'Genel kurulda imza',
        'SIGNATURE': 'İmza karşılığı',
        'REGISTERED_MAIL': 'İadeli taahhütlü posta',
        'E_NOTIFICATION': 'Elektronik tebligat',
      }[m] ?? m,
    );
    if (method == null) return;
    await _run(() => PaymentsPhase2Api.recordService(b.id, s.unitId, recipient, method, DateTime.now(), siteId: widget.siteId),
        'Tebliğ kaydedildi');
  }

  Future<void> _object(OperatingBudget b) async {
    if (b.unitShares.isEmpty) return;
    final unit = await showSpSelection<BudgetUnitShare>(
      context: context,
      title: 'İtiraz eden daire',
      options: b.unitShares,
      labelOf: (s) => s.unitLabel,
    );
    if (unit == null) return;
    final name = await _ask('İtiraz', 'İtiraz eden');
    if (name == null) return;
    final reason = await _ask('İtiraz', 'Gerekçe');
    if (reason == null) return;
    await _run(() => PaymentsPhase2Api.fileObjection(b.id, unit.unitId, name, reason, siteId: widget.siteId), 'İtiraz kaydedildi');
  }

  Future<void> _openCreate() async {
    final created = await AppFullscreenPage.push<bool>(
      context: context,
      builder: (ctx) => _CreateBudgetPage(siteId: widget.siteId),
    );
    if (created == true) await _load();
  }
}

class _LineDraft {
  String category = 'CLEANING';
  String allocationKey = 'LAND_SHARE';
  final TextEditingController amount = TextEditingController();
}

class _CreateBudgetPage extends StatefulWidget {
  final String? siteId;
  const _CreateBudgetPage({required this.siteId});

  @override
  State<_CreateBudgetPage> createState() => _CreateBudgetPageState();
}

class _CreateBudgetPageState extends State<_CreateBudgetPage> {
  int _year = DateTime.now().year;
  final List<_LineDraft> _lines = [_LineDraft()];
  bool _saving = false;

  @override
  void dispose() {
    for (final l in _lines) {
      l.amount.dispose();
    }
    super.dispose();
  }

  Decimal get _total => _lines.fold(Decimal.zero, (sum, l) => sum + (MoneyInput.parse(l.amount.text).amount ?? Decimal.zero));

  Future<void> _save() async {
    final lines = <BudgetLine>[];
    for (final l in _lines) {
      final amount = MoneyInput.parse(l.amount.text).amount;
      if (amount == null || amount <= Decimal.zero) continue;
      lines.add(BudgetLine(category: l.category, annualAmount: amount, allocationKey: l.allocationKey));
    }
    if (lines.isEmpty) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await PaymentsPhase2Api.createBudget(_year, lines, siteId: widget.siteId);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      messenger.showSnackBar(appSnackBar(content: Text(e.toString()), backgroundColor: AppColors.dangerFill));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppFullscreenPage(
      title: 'Yeni İşletme Projesi Taslağı',
      subtitle: 'Yıllık gider kalemleri ve paylaşım anahtarı',
      bottomBar: AppFullscreenPage.buildBottomBar(context: context, children: [
        testId('budget_save_button', ElevatedButton(
          onPressed: _saving ? null : _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primaryFill,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text('Taslağı kaydet · ${formatTry(_total)}'),
        )),
      ]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            initialValue: _year,
            decoration: const InputDecoration(labelText: 'Bütçe yılı', border: OutlineInputBorder()),
            items: [for (final y in [DateTime.now().year, DateTime.now().year + 1]) DropdownMenuItem(value: y, child: Text('$y'))],
            onChanged: (v) => setState(() => _year = v ?? _year),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < _lines.length; i++) ...[
            _lineEditor(i),
            const SizedBox(height: 10),
          ],
          TextButton.icon(
            onPressed: () => setState(() => _lines.add(_LineDraft())),
            icon: const Icon(Icons.add),
            label: const Text('Kalem ekle'),
          ),
          Text(
            'Arsa payı (KMK 20) varsayılan paylaşım anahtarıdır; yönetim planı eşit paylaşım öngörüyorsa "Eşit" seçin.',
            style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption),
          ),
        ],
      ),
    );
  }

  Widget _lineEditor(int i) {
    final l = _lines[i];
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border(context))),
      child: Column(children: [
        testId('budget_line_category_$i', DropdownButtonFormField<String>(
          initialValue: l.category,
          decoration: const InputDecoration(labelText: 'Gider kalemi', border: OutlineInputBorder()),
          items: [for (final e in budgetCategories.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => setState(() => l.category = v ?? l.category),
        )),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: testId('budget_line_amount_$i', TextField(
              controller: l.amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Yıllık tutar (₺)', border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            )),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: l.allocationKey,
              decoration: const InputDecoration(labelText: 'Paylaşım', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'LAND_SHARE', child: Text('Arsa payı')),
                DropdownMenuItem(value: 'EQUAL', child: Text('Eşit')),
              ],
              onChanged: (v) => setState(() => l.allocationKey = v ?? l.allocationKey),
            ),
          ),
          if (_lines.length > 1)
            IconButton(
              tooltip: 'Kalemi sil',
              onPressed: () => setState(() => _lines.removeAt(i).amount.dispose()),
              icon: const Icon(Icons.delete_outline),
            ),
        ]),
      ]),
    );
  }
}
