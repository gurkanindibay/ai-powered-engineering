import 'package:flutter/material.dart';

import '../../domain/repositories/person_repository.dart';
import '../../domain/services/person_directory_api.dart';
import '../../testing/test_id.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';

enum SpPersonCardSize { row, compact, full }

/// Read-only presentation of a person; actions remain with the feature owner.
class SpPersonCard extends StatelessWidget {
  final PersonSummary person;
  final SpPersonCardSize size;
  final List<String> roles;
  final List<String> unitLabels;
  final VoidCallback? onTap;
  final String id;

  const SpPersonCard({
    super.key,
    required this.person,
    this.size = SpPersonCardSize.compact,
    this.roles = const [],
    this.unitLabels = const [],
    this.onTap,
    this.id = 'sp_person_card',
  });

  @override
  Widget build(BuildContext context) {
    final isFull = size == SpPersonCardSize.full;
    final isRow = size == SpPersonCardSize.row;
    final titleStyle = Theme.of(context).textTheme.titleSmall;
    final rolesToShow = roles.isEmpty && person.role.isNotEmpty
        ? [PersonSearchResult.roleLabel(person.role)]
        : roles.map(PersonSearchResult.roleLabel).toList();
    return testId(
      id,
      Card(
        key: Key(id),
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.control),
          child: Padding(
            padding: EdgeInsets.all(isFull ? AppSpacing.lg : AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  child: Text(
                    person.fullName.isEmpty
                        ? '?'
                        : person.fullName.characters.first.toUpperCase(),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        person.fullName,
                        style: titleStyle,
                        maxLines: isRow ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (person.phone.isNotEmpty ||
                          person.email.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          [
                            if (person.phone.isNotEmpty) person.phone,
                            if (person.email.isNotEmpty) person.email,
                          ].join(' · '),
                          maxLines: isRow ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (rolesToShow.isNotEmpty ||
                          (isFull && unitLabels.isNotEmpty)) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: AppSpacing.xs,
                          children: [
                            for (final role in rolesToShow)
                              SpStatusBadge(label: role, tone: SpTone.info),
                            if (isFull)
                              for (final unit in unitLabels)
                                SpStatusBadge(
                                  label: unit,
                                  tone: SpTone.neutral,
                                ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (onTap != null) const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
      label: onTap == null ? null : 'Open ${person.fullName}',
    );
  }
}
