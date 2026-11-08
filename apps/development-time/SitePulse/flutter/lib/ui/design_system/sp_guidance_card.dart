import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'sp_tone.dart';

/// Empty-state / guidance card: icon, title, message, optional action and tip.
///
/// The card only lays content out. Deciding *which* state applies (no site, no
/// dues period, no matching rows, ...) stays with the caller, and loading must
/// keep using `SpSkeletonList` rather than showing guidance while data is
/// pending.
class SpGuidanceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final SpTone tone;

  /// Draws the icon inside a tinted circle (the prominent, first-run variant).
  final bool prominent;

  /// Tints the border with [tone] instead of the neutral border colour.
  final bool tonedBorder;

  /// Optional call to action placed below the message.
  final Widget? action;

  /// Optional one-line tip shown in a bordered strip at the bottom.
  final String? tip;

  const SpGuidanceCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.tone = SpTone.info,
    this.prominent = false,
    this.tonedBorder = false,
    this.action,
    this.tip,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final accent = tone.accent(context);
    final tipText = tip;
    final actionWidget = action;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(prominent ? AppSpacing.xl : AppSpacing.lg + 4),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(prominent ? AppRadius.card - 2 : AppRadius.control + 4),
        border: Border.all(
          color: tonedBorder ? accent.withValues(alpha: 0.35) : AppColors.border(context),
        ),
      ),
      child: Column(
        children: [
          ExcludeSemantics(
            child: prominent
                ? Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(color: tone.tint(context), shape: BoxShape.circle),
                    child: Icon(icon, size: 28, color: accent),
                  )
                : Icon(icon, size: 36, color: accent),
          ),
          SizedBox(height: prominent ? AppSpacing.md + 2 : AppSpacing.sm),
          Text(
            title,
            textAlign: TextAlign.center,
            style: (prominent ? text.titleMedium : text.titleSmall)
                ?.copyWith(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold),
          ),
          SizedBox(height: prominent ? AppSpacing.sm : AppSpacing.xs),
          Text(
            message,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(
              color: AppColors.textSecondary(context),
              fontSize: prominent ? 13 : null,
              height: 1.4,
            ),
          ),
          if (actionWidget != null) ...[
            const SizedBox(height: AppSpacing.lg),
            actionWidget,
          ],
          if (tipText != null) ...[
            const SizedBox(height: AppSpacing.md + 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md + 2, vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.surface(context),
                borderRadius: BorderRadius.circular(AppRadius.control - 2),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(
                    child: Icon(Icons.lightbulb_outline_rounded, size: 16, color: SpTone.warning.accent(context)),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: Text(tipText, style: text.bodySmall?.copyWith(color: AppColors.textSecondary(context))),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
