import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../stuck.dart';
import 'common.dart';
import 'relaunch_sheet.dart';

class WorkScreen extends StatelessWidget {
  const WorkScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final assessed = [for (final w in state.work) (w, state.assessItem(w))]
      ..sort((a, b) => b.$2.health.index.compareTo(a.$2.health.index));
    final counts = <String, int>{};
    for (final (w, _) in assessed) {
      counts[w.harness] = (counts[w.harness] ?? 0) + 1;
    }
    return RefreshIndicator(
      onRefresh: state.refresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ErrorBanner(state.errors),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final e in counts.entries)
                  Chip(
                    avatar: CircleAvatar(backgroundColor: harnessColor(e.key), radius: 6),
                    label: Text('${e.key} · ${e.value}'),
                  ),
              ],
            ),
          ),
          if (assessed.isEmpty && !state.loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('No claimed issues or agent PRs right now.', textAlign: TextAlign.center),
            ),
          for (final (item, a) in assessed) _WorkTile(state: state, item: item, assessment: a),
          if (state.refreshedAt != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Refreshed ${ago(state.refreshedAt)}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _WorkTile extends StatelessWidget {
  const _WorkTile({required this.state, required this.item, required this.assessment});

  final AppState state;
  final WorkItem item;
  final Assessment assessment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pull = item.pull;
    final claim = item.claim;
    final session = claim == null ? null : state.snapshot.sessionFor(claim);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        onTap: () => openUrl(item.url),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(healthIcon(assessment.health), color: healthColor(assessment.health), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${item.isPull ? 'PR' : '#'}${item.number}  ${item.title}',
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _Pill(item.harness, harnessColor(item.harness)),
                  if (claim != null) Text(claim.session, style: theme.textTheme.bodySmall),
                  if (state.settings.repos.length > 1) Text(item.repo, style: theme.textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                assessment.reason,
                style: theme.textTheme.bodySmall?.copyWith(color: healthColor(assessment.health)),
              ),
              if (pull != null && !item.isPull)
                TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                  onPressed: () => openUrl(pull.url),
                  icon: Icon(_checkIcon(pull.checks), size: 16),
                  label: Text('PR #${pull.number}${pull.draft ? ' (draft)' : ''} · checks ${pull.checks.name}'),
                )
              else if (pull != null)
                Text('checks ${pull.checks.name}', style: theme.textTheme.bodySmall),
              if (session != null)
                Text(
                  '${session.model} · ${compactTokens(session.tokens)} tokens · ${session.project}',
                  style: theme.textTheme.bodySmall,
                ),
              if (assessment.health != Health.active)
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: () => showRelaunchSheet(context, state, item),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Start new session'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _checkIcon(CheckState s) => switch (s) {
    CheckState.success => Icons.check_circle_outline,
    CheckState.failure => Icons.cancel_outlined,
    CheckState.pending => Icons.schedule,
    CheckState.none => Icons.remove_circle_outline,
  };
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
    child: Text(
      text,
      style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
    ),
  );
}
