import 'package:flutter/material.dart';

import '../../domain/models/payments_phase3_models.dart';
import '../../domain/services/payments_phase3_api.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../design_system/sp_feedback.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';

/// Four-eyes approval queue for "seller pays the remaining capital installments" requests.
/// A request changes who is billed only after a different manager approves it.
class SellerPaysOverrideQueuePage extends StatefulWidget {
  /// Replaces the API list call in tests.
  final Future<List<SellerPaysOverrideItem>> Function()? loader;

  /// Replaces the API decision call in tests.
  final Future<void> Function(int id, {required bool approve, String? note})? decider;

  const SellerPaysOverrideQueuePage({super.key, this.loader, this.decider});

  static Future<void> open(BuildContext context) => AppFullscreenPage.push<void>(
        context: context,
        builder: (_) => const SellerPaysOverrideQueuePage(),
      );

  @override
  State<SellerPaysOverrideQueuePage> createState() => _SellerPaysOverrideQueuePageState();
}

class _SellerPaysOverrideQueuePageState extends State<SellerPaysOverrideQueuePage> {
  late Future<List<SellerPaysOverrideItem>> _requests;
  final _noteController = TextEditingController();
  int? _workingId;

  @override
  void initState() {
    super.initState();
    _requests = _load();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<List<SellerPaysOverrideItem>> _load() =>
      (widget.loader ?? PaymentsPhase3Api.sellerPaysOverrides)();

  void _reload() => setState(() => _requests = _load());

  Future<void> _decide(SellerPaysOverrideItem item, {required bool approve}) async {
    setState(() => _workingId = item.id);
    final note = _noteController.text.trim();
    try {
      await (widget.decider ?? PaymentsPhase3Api.decideSellerPaysOverride)(
        item.id,
        approve: approve,
        note: note.isEmpty ? null : note,
      );
      if (!mounted) return;
      SpToast.success(
        context,
        approve ? 'Satıcı öder talebi onaylandı.' : 'Satıcı öder talebi reddedildi.',
      );
      _noteController.clear();
      _reload();
    } catch (error) {
      // The API message names the four-eyes rule when the requester approves their own request.
      if (mounted) SpToast.error(context, error.toString());
    } finally {
      if (mounted) setState(() => _workingId = null);
    }
  }

  @override
  Widget build(BuildContext context) => AppFullscreenPage(
        title: 'Satıcı öder talepleri',
        subtitle: 'Kalan demirbaş taksitlerini satıcıya yazmak için dört göz onayı',
        icon: const Icon(Icons.swap_horiz, color: AppColors.accentCyan),
        isScrollable: false,
        child: FutureBuilder<List<SellerPaysOverrideItem>>(
          future: _requests,
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
              );
            }
            final pending = (snapshot.data ?? const <SellerPaysOverrideItem>[])
                .where((item) => item.status == 'PENDING')
                .toList();
            if (pending.isEmpty) {
              return const SpGuidanceCard(
                icon: Icons.check_circle_outline,
                title: 'Bekleyen satıcı öder talebi yok',
                message: 'Tapu devrinde istenen talepler burada onay bekler.',
                tone: SpTone.neutral,
              );
            }
            return ListView(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              children: [
                testId('seller_pays_decision_note', TextField(
                  key: const Key('seller_pays_decision_note'),
                  controller: _noteController,
                  decoration: const InputDecoration(
                    labelText: 'Karar notu (isteğe bağlı)',
                    border: OutlineInputBorder(),
                  ),
                )),
                const SizedBox(height: AppSpacing.md),
                for (final item in pending) _card(context, item),
              ],
            );
          },
        ),
      );

  Widget _card(BuildContext context, SellerPaysOverrideItem item) => testId(
        'seller_pays_override_${item.id}',
        Container(
          key: Key('seller_pays_override_${item.id}'),
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
                    child: Text('Daire ${item.unitId}', style: Theme.of(context).textTheme.titleMedium),
                  ),
                  SpStatusBadge(label: item.status, tone: SpTone.warning),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text('Gerekçe: ${item.reason}'),
              Text('Talep eden: ${item.requestedBy}'),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  testId('seller_pays_approve_${item.id}', ElevatedButton(
                    key: Key('seller_pays_approve_${item.id}'),
                    onPressed: _workingId == item.id ? null : () => _decide(item, approve: true),
                    child: const Text('Onayla'),
                  )),
                  testId('seller_pays_reject_${item.id}', OutlinedButton(
                    key: Key('seller_pays_reject_${item.id}'),
                    onPressed: _workingId == item.id ? null : () => _decide(item, approve: false),
                    child: const Text('Reddet'),
                  )),
                ],
              ),
            ],
          ),
        ),
      );
}
