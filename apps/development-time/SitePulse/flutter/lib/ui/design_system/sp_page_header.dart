import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'sp_tone.dart';

/// Shared module identity and wrapping actions, placed before section navigation.
class SpPageHeader extends StatelessWidget {
  const SpPageHeader({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(AppSpacing.lg),
    decoration: BoxDecoration(
      color: AppColors.surface(context),
      borderRadius: BorderRadius.circular(AppRadius.card),
      border: Border.all(color: AppColors.border(context)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Icon(icon, color: SpTone.info.accent(context)),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      subtitle!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: actions,
          ),
        ],
      ],
    ),
  );
}
