import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'common.dart';

/// Harnesses that can be started from the phone, and how.
const relaunchTargets = <String, String>{
  'claude': 'Claude Code in GitHub Actions',
  'codex': 'Codex in GitHub Actions',
  'deepseek': 'Claude Code on DeepSeek (Anthropic-compatible API)',
  'copilot': 'Assign to the Copilot coding agent',
};

Future<void> showRelaunchSheet(BuildContext context, AppState state, WorkItem item) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _RelaunchSheet(state: state, item: item),
  );
}

class _RelaunchSheet extends StatefulWidget {
  const _RelaunchSheet({required this.state, required this.item});

  final AppState state;
  final WorkItem item;

  @override
  State<_RelaunchSheet> createState() => _RelaunchSheetState();
}

class _RelaunchSheetState extends State<_RelaunchSheet> {
  late String _harness = relaunchTargets.containsKey(widget.item.harness) ? widget.item.harness : 'claude';
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final message = await widget.state.relaunch(widget.item, _harness, _note.text.trim());
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(message)));
      await widget.state.refresh();
    } on Exception catch (e) {
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('Could not start: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final claim = item.claim;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Start a new session for #${item.number}', style: Theme.of(context).textTheme.titleMedium),
          if (claim != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Takes the claim over from ${claim.harness}/${claim.session}. '
                'Make sure that session is really gone.',
              ),
            ),
          if (item.harness == 'antigravity')
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Antigravity runs only in its desktop app, so pick a cloud harness to continue.'),
            ),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: _harness,
            onChanged: (v) => setState(() => _harness = v ?? _harness),
            child: Column(
              children: [
                for (final e in relaunchTargets.entries)
                  RadioListTile<String>(
                    value: e.key,
                    title: Text(e.key),
                    subtitle: Text(e.value),
                    secondary: CircleAvatar(backgroundColor: harnessColor(e.key), radius: 6),
                    contentPadding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
          if (_harness != 'copilot')
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Extra instructions (optional)'),
              maxLines: 2,
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _go,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.rocket_launch),
              label: const Text('Start'),
            ),
          ),
        ],
      ),
    );
  }
}
