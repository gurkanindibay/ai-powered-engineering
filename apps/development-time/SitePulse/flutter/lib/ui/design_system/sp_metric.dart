import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'sp_tone.dart';

/// A label above a bold value, used in summary rows and dashboards.
///
/// [value] is already formatted by the caller: monetary values must come from
/// `MoneyFormatter` / `formatTry`, never from string literals or `double`.
class SpMetricValue extends StatelessWidget {
  final String label;
  final String value;
  final SpTone tone;

  const SpMetricValue({
    super.key,
    required this.label,
    required this.value,
    this.tone = SpTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: text.labelMedium?.copyWith(color: AppColors.textSecondary(context))),
        const SizedBox(height: 2),
        Text(
          value,
          style: text.titleSmall?.copyWith(color: tone.foreground(context), fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

/// An icon, a bold value and a centred label stacked vertically.
///
/// [dense] selects the compact variant used inside embedded dashboards.
class SpIconMetric extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final SpTone tone;
  final bool dense;

  const SpIconMetric({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.tone = SpTone.info,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(child: Icon(icon, size: dense ? 15 : 18, color: tone.accent(context))),
        SizedBox(height: dense ? 2 : AppSpacing.xs),
        Text(
          value,
          style: (dense ? text.titleSmall : text.titleMedium)
              ?.copyWith(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold),
        ),
        Text(
          label,
          textAlign: TextAlign.center,
          style: text.labelMedium?.copyWith(color: AppColors.textSecondary(context), fontWeight: FontWeight.w400),
        ),
      ],
    );
  }
}
