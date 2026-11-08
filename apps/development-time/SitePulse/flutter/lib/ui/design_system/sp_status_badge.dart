import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'sp_tone.dart';

/// Small tinted pill that shows a status or bucket label.
///
/// Callers map their domain status to a [label] and [tone]; the badge never
/// infers a settlement, occupancy or aging state from its wording. The label
/// text is always present, so the status is never conveyed by colour alone.
class SpStatusBadge extends StatelessWidget {
  final String label;
  final SpTone tone;
  final IconData? icon;

  const SpStatusBadge({super.key, required this.label, this.tone = SpTone.info, this.icon});

  @override
  Widget build(BuildContext context) {
    final fg = tone.foreground(context);
    final iconData = icon;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm - 2, vertical: 2),
      decoration: BoxDecoration(
        color: tone.tint(context),
        borderRadius: BorderRadius.circular(AppSpacing.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (iconData != null) ...[
            ExcludeSemantics(child: Icon(iconData, size: 12, color: fg)),
            const SizedBox(width: AppSpacing.xs),
          ],
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
