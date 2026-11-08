import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Semantic colour role for shared design-system widgets.
///
/// Widgets take a tone instead of a raw [Color] so that text stays readable in
/// both themes: each tone resolves through the [StatusColors] theme extension
/// (falling back to the matching [AppColors] helper when a test pumps a bare
/// `MaterialApp` without the SitePulse theme).
enum SpTone { neutral, info, success, warning, danger, accent }

extension SpToneColors on SpTone {
  /// Foreground colour for text and icons drawn in this tone.
  Color foreground(BuildContext context) {
    final status = Theme.of(context).extension<StatusColors>();
    return switch (this) {
      SpTone.neutral => AppColors.textPrimary(context),
      SpTone.info => status?.info ?? AppColors.primaryText(context),
      SpTone.success => status?.success ?? AppColors.successText(context),
      SpTone.warning => status?.warning ?? AppColors.warningText(context),
      SpTone.danger => status?.danger ?? AppColors.dangerText(context),
      SpTone.accent => AppColors.purpleText(context),
    };
  }

  /// Bright accent used for decorative icons, borders and tinted backgrounds.
  Color accent(BuildContext context) {
    return switch (this) {
      SpTone.neutral => AppColors.textSecondary(context),
      SpTone.info => AppColors.accentCyan,
      SpTone.success => AppColors.accentGreen,
      SpTone.warning => AppColors.accentOrange,
      SpTone.danger => AppColors.accentRed,
      SpTone.accent => AppColors.accentPurple,
    };
  }

  /// Low-emphasis background tint for pills, badges and icon wells.
  Color tint(BuildContext context) => accent(context).withValues(alpha: 0.12);
}
