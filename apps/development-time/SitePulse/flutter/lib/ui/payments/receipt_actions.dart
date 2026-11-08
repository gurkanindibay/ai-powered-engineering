import 'package:flutter/material.dart';

import '../components/sp_dialog_pages.dart';

import '../design_system/sp_typography.dart';

import '../../domain/services/payments_phase2_api.dart';
import '../../domain/services/platform_env.dart';
import '../design_system/sp_feedback.dart';
import '../theme/app_theme.dart';
import '../../testing/test_id.dart';

/// Downloads a receipt as PDF (the backend renders it with its verification QR code).
Future<void> downloadReceiptPdf(BuildContext context, String receiptNumber, {String? siteId}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final bytes = await PaymentsPhase2Api.receiptPdf(receiptNumber, siteId: siteId);
    final saved = downloadBytes('$receiptNumber.pdf', bytes, 'application/pdf');
    messenger.showSnackBar(appSnackBar(
      content: Text(saved ? '$receiptNumber.pdf indirildi.' : 'PDF indirme bu platformda desteklenmiyor.'),
      backgroundColor: saved ? AppColors.successFill : AppColors.warningFill,
    ));
  } catch (e) {
    messenger.showSnackBar(appSnackBar(content: Text('Makbuz PDF alınamadı: $e'), backgroundColor: AppColors.dangerFill));
  }
}

/// Asks for a reason and reverses a receipt (a collection or a virman). Returns the
/// reversal receipt number, or null when cancelled or refused.
Future<String?> reverseReceiptWithReason(BuildContext context, String receiptNumber, {String? siteId}) async {
  final reasonCtrl = TextEditingController();
  final confirmed = await showSpPage<bool>(
    context: context,
    builder: (ctx) => SpAlertPage(
      title: const Text('Makbuzu iptal et'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$receiptNumber için ters kayıt (İAD) makbuzu düzenlenir; mahsup edilen borçlar yeniden açılır. '
            'Virman makbuzunda tutar avans bakiyesine geri alınır.',
            style: const TextStyle(fontSize: SpFontSize.body),
          ),
          const SizedBox(height: 12),
          testId('reverse_reason_input', TextField(
            controller: reasonCtrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Gerekçe (zorunlu)', border: OutlineInputBorder()),
          )),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
        testId('reverse_confirm_button', ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.dangerFill, foregroundColor: Colors.white),
          child: const Text('İptal et'),
        )),
      ],
    ),
  );
  final reason = reasonCtrl.text.trim();
  reasonCtrl.dispose();
  if (confirmed != true || !context.mounted) return null;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final number = await PaymentsPhase2Api.reverseReceipt(receiptNumber, reason, siteId: siteId);
    messenger.showSnackBar(appSnackBar(content: Text('$receiptNumber iptal edildi: $number'), backgroundColor: AppColors.successFill));
    return number;
  } catch (e) {
    messenger.showSnackBar(appSnackBar(content: Text('İptal edilemedi: $e'), backgroundColor: AppColors.dangerFill));
    return null;
  }
}
