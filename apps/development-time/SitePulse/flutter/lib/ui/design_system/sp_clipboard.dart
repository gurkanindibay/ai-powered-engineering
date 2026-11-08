import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../../testing/test_id.dart';
import '../theme/app_theme.dart';
import 'sp_feedback.dart';

/// Removes the display grouping spaces from an IBAN (`TR41 0020 ...` →
/// `TR410020...`). Only IBAN copy actions normalise; other text is copied
/// exactly as shown.
String normalizeIban(String iban) => iban.replaceAll(RegExp(r'\s+'), '').toUpperCase();

/// Copies [text] verbatim and reports the outcome through [SpToast].
///
/// The clipboard write is awaited before success is announced; a platform
/// failure shows an error toast instead. Returns whether the copy succeeded.
Future<bool> spCopyToClipboard(
  BuildContext context,
  String text, {
  required String successMessage,
  String failureMessage = 'Panoya kopyalanamadı. Lütfen metni elle seçip kopyalayın.',
}) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (_) {
    if (context.mounted) SpToast.error(context, failureMessage);
    return false;
  }
  if (context.mounted) SpToast.success(context, successMessage);
  return true;
}

/// Copies an IBAN without grouping spaces. An empty IBAN is never copied.
Future<bool> spCopyIban(BuildContext context, String iban, {String successMessage = 'Sanal IBAN panoya kopyalandı!'}) {
  final normalized = normalizeIban(iban);
  if (normalized.isEmpty) return Future.value(false);
  return spCopyToClipboard(context, normalized, successMessage: successMessage);
}

/// Bordered row with a monospaced, selectable IBAN and a "Kopyala" action.
///
/// When [iban] is empty the row shows [emptyLabel] and offers no copy action.
class SpIbanCopyRow extends StatelessWidget {
  final String iban;
  final String emptyLabel;
  final String successMessage;
  final VoidCallback? onCopied;
  final bool compact;

  /// Automation id for the copy button.
  final String copyButtonId;

  const SpIbanCopyRow({
    super.key,
    required this.iban,
    this.emptyLabel = 'Sanal IBAN henüz tahsis edilmedi',
    this.successMessage = 'Sanal IBAN panoya kopyalandı!',
    this.onCopied,
    this.compact = false,
    this.copyButtonId = 'btn_copy_iban_row',
  });

  @override
  Widget build(BuildContext context) {
    final hasIban = iban.trim().isNotEmpty;
    final text = Theme.of(context).textTheme;
    final radius = compact ? AppRadius.control - 2 : AppRadius.control;
    final pillRadius = compact ? AppSpacing.sm - 2 : AppRadius.chip;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppSpacing.md : AppSpacing.md + 2,
        vertical: compact ? AppSpacing.sm + 2 : AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: compact ? AppColors.background(context) : AppColors.card(context),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        children: [
          Expanded(
            child: hasIban
                ? SelectableText(
                    iban,
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: AppColors.textPrimary(context),
                      fontSize: compact ? 12 : 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: compact ? 0.6 : 1.1,
                    ),
                  )
                : Text(emptyLabel, style: text.bodySmall?.copyWith(color: AppColors.textSecondary(context))),
          ),
          if (hasIban) ...[
            const SizedBox(width: AppSpacing.xs),
            testId(copyButtonId, Semantics(
              button: true,
              label: 'IBAN ${AppStrings.copy}',
              child: InkWell(
                key: Key(copyButtonId),
                onTap: () async {
                  final copied = await spCopyIban(context, iban, successMessage: successMessage);
                  if (copied) onCopied?.call();
                },
                borderRadius: BorderRadius.circular(pillRadius),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 32),
                  padding: EdgeInsets.symmetric(horizontal: compact ? AppSpacing.sm : AppSpacing.sm + 2, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.accentCyan.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(pillRadius),
                  ),
                  child: ExcludeSemantics(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy, size: compact ? 12 : 14, color: AppColors.primaryText(context)),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          AppStrings.copy,
                          style: text.labelMedium?.copyWith(color: AppColors.primaryText(context), fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )),
          ],
        ],
      ),
    );
  }
}
