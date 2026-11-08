import 'package:flutter/material.dart';

import '../../testing/test_id.dart';
import '../theme/app_theme.dart';
import 'sp_tone.dart';

/// Themed Material [FilterChip] used by directory filters.
///
/// The chip applies a selection directly; use a button that opens
/// `showSpSelection` when the choice needs its own page. Filter state stays
/// with the caller.
class SpFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final SpTone tone;

  /// Optional automation id (also used as the widget key).
  final String? id;

  const SpFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.tone = SpTone.info,
    this.id,
  });

  @override
  Widget build(BuildContext context) {
    final accent = tone.accent(context);
    final chip = FilterChip(
      key: id == null ? null : Key(id!),
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      selectedColor: accent.withValues(alpha: 0.2),
      checkmarkColor: accent,
      labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: selected ? tone.foreground(context) : AppColors.textSecondary(context),
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
    );
    final chipId = id;
    return chipId == null ? chip : testId(chipId, chip);
  }
}
