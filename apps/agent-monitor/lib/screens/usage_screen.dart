import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'common.dart';

class UsageScreen extends StatelessWidget {
  const UsageScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final providers = state.providers;
    final snap = state.snapshot;
    return RefreshIndicator(
      onRefresh: state.refresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ErrorBanner(state.errors),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              snap.generatedAt == null
                  ? 'No usage snapshot yet. Run scripts/agent_usage_collector.py on your computer and enter the gist id in Settings.'
                  : 'Collected on ${snap.machine} ${ago(snap.generatedAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          for (final p in providers) _ProviderCard(p),
        ],
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard(this.p);

  final ProviderUsage p;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = harnessColor(p.id);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ExpansionTile(
        leading: CircleAvatar(backgroundColor: color, radius: 8),
        title: Text(p.name),
        subtitle: Text(_headline(), maxLines: 2, overflow: TextOverflow.ellipsis),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final w in p.windows) _WindowRow(w, color),
          for (final b in p.balance)
            Text('Balance ${b.total} ${b.currency} (granted ${b.granted}, topped up ${b.toppedUp})'),
          if (p.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(p.note, style: theme.textTheme.bodySmall),
            ),
          if (p.sessions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Recent sessions', style: theme.textTheme.labelLarge),
            for (final s in p.sessions.take(8))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(s.project.isEmpty ? s.id : s.project),
                subtitle: Text('${s.model} · ${s.id.length > 12 ? s.id.substring(0, 12) : s.id}'),
                trailing: Text('${compactTokens(s.tokens)}\n${ago(s.lastActivity)}', textAlign: TextAlign.right),
              ),
          ],
        ],
      ),
    );
  }

  String _headline() {
    if (p.status != 'ok') return p.note.isEmpty ? p.status : p.note;
    final pct = p.windows.where((w) => w.usedPercent != null).toList();
    if (pct.isNotEmpty) {
      return pct.map((w) => '${w.label}: ${(100 - w.usedPercent!).toStringAsFixed(0)}% left').join(' · ');
    }
    if (p.balance.isNotEmpty) return p.balance.map((b) => '${b.total} ${b.currency} left').join(' · ');
    return p.windows.map((w) => '${w.label}: ${compactTokens(w.tokens)}').join(' · ');
  }
}

class _WindowRow extends StatelessWidget {
  const _WindowRow(this.w, this.color);

  final UsageWindow w;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final pct = w.usedPercent;
    final parts = <String>[
      if (w.requests != null) '${w.requests} / ${w.limitRequests ?? '?'} requests',
      if (w.tokens != null)
        '${compactTokens(w.tokens)}${w.limitTokens != null ? ' / ${compactTokens(w.limitTokens)}' : ''} tokens',
      if (pct != null) '${pct.toStringAsFixed(1)}% used',
      if (w.resetsAt != null) 'resets in ${_until(w.resetsAt!)}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${w.label}  ${parts.join(' · ')}'),
          if (pct != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: (pct / 100).clamp(0.0, 1.0),
                color: pct >= 90 ? Colors.red : color,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }

  static String _until(DateTime t) {
    final d = t.toUtc().difference(DateTime.now().toUtc());
    if (d.isNegative) return 'now';
    return d.inHours >= 24 ? '${d.inDays}d ${d.inHours % 24}h' : '${d.inHours}h ${d.inMinutes % 60}m';
  }
}
