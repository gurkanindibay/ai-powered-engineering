import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../design_system/sp_typography.dart';

import '../../domain/models/payments_phase2_models.dart';
import '../../domain/services/payments_phase2_api.dart';
import '../../domain/services/platform_env.dart';
import '../../testing/test_id.dart';
import '../design_system/money_formatter.dart';
import '../theme/app_theme.dart';
import 'receipt_actions.dart';

/// Card payment through the licensed provider's hosted page (6493): SitePulse
/// never shows card fields. The panel opens a payment intent, sends the payer to
/// the provider's 3-D Secure page in a new tab, and follows the intent until the
/// provider reports it captured (a receipt was issued) or failed.
class CardPaymentPanel extends StatefulWidget {
  final String unitId;
  final Decimal amount;
  final bool settlesDebt;
  final void Function(CardPaymentIntent intent)? onCaptured;

  const CardPaymentPanel({super.key, required this.unitId, required this.amount, required this.settlesDebt, this.onCaptured});

  @override
  State<CardPaymentPanel> createState() => _CardPaymentPanelState();
}

class _CardPaymentPanelState extends State<CardPaymentPanel> {
  CardPaymentIntent? _intent;
  String? _error;
  bool _busy = false;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final intent = await PaymentsPhase2Api.createCardPayment(widget.unitId, widget.amount);
      if (!mounted) return;
      setState(() => _intent = intent);
      final url = intent.checkoutUrl;
      if (url != null) openUrlInNewTab(url);
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final current = _intent;
    if (current == null) return;
    try {
      final next = await PaymentsPhase2Api.cardPayment(widget.unitId, current.id);
      if (!mounted) return;
      setState(() => _intent = next);
      if (next.isFinished) {
        _poll?.cancel();
        if (next.isCaptured) widget.onCaptured?.call(next);
      }
    } catch (_) {
      // Transient: the next tick retries.
    }
  }

  @override
  Widget build(BuildContext context) {
    final intent = _intent;
    if (intent != null && intent.isCaptured) {
      return testId('card_payment_captured', _notice(
        context,
        icon: Icons.check_circle,
        color: AppColors.successText(context),
        text: '${formatTry(intent.amount)} kart ödemeniz alındı. Makbuz: ${intent.receiptNumber ?? '-'}',
        action: intent.receiptNumber == null
            ? null
            : TextButton.icon(
                onPressed: () => downloadReceiptPdf(context, intent.receiptNumber!),
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
                label: const Text('Makbuz PDF'),
              ),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _notice(
          context,
          icon: Icons.verified_user_outlined,
          color: AppColors.successText(context),
          text: 'Kart bilgileriniz lisanslı ödeme kuruluşunun 3-D Secure sayfasında girilir; SitePulse kart verisi görmez ve saklamaz. '
              'Tutar doğrudan sitenin banka hesabına geçer.',
        ),
        const SizedBox(height: 12),
        if (intent != null && !intent.isFinished)
          testId('card_payment_waiting', _notice(
            context,
            icon: Icons.hourglass_top,
            color: AppColors.primaryText(context),
            text: 'Ödeme sayfası yeni sekmede açıldı. Ödemeyi orada tamamlayın; sonuç burada otomatik görünecek.',
            action: TextButton(
              onPressed: intent.checkoutUrl == null ? null : () => openUrlInNewTab(intent.checkoutUrl!),
              child: const Text('Sayfayı tekrar aç'),
            ),
          )),
        if (intent != null && intent.isFailed)
          testId('card_payment_failed', _notice(
            context,
            icon: Icons.error_outline,
            color: AppColors.dangerText(context),
            text: 'Ödeme tamamlanmadı: ${intent.failureReason ?? 'sağlayıcı reddetti'}',
          )),
        if (_error != null)
          testId('card_payment_error', _notice(context, icon: Icons.error_outline, color: AppColors.dangerText(context), text: _error!)),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: testId('card_payment_start', ElevatedButton.icon(
            onPressed: widget.amount > Decimal.zero && !_busy && (intent == null || intent.isFinished) ? _start : null,
            icon: const Icon(Icons.lock, size: 16),
            label: Text(
              widget.settlesDebt
                  ? '3D Secure ile ${formatTry(widget.amount)} Öde'
                  : '3D Secure ile ${formatTry(widget.amount)} Avans Yükle',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: SpFontSize.body),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryFill,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          )),
        ),
      ],
    );
  }

  Widget _notice(BuildContext context, {required IconData icon, required Color color, required String text, Widget? action}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.caption, height: 1.35))),
          ?action,
        ],
      ),
    );
  }
}
