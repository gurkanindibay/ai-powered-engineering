import 'package:flutter/material.dart';

import '../app_state.dart';
import '../settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final Settings _s = widget.state.settings;
  late final _token = TextEditingController(text: _s.githubToken);
  late final _repos = TextEditingController(text: _s.repos.join('\n'));
  late final _gist = TextEditingController(text: _s.gistId);
  late final _deepseek = TextEditingController(text: _s.deepseekKey);
  late final _hours = TextEditingController(text: '${_s.stuckAfterHours}');
  late final _workflow = TextEditingController(text: _s.relaunchWorkflow);
  late final _ref = TextEditingController(text: _s.relaunchRef);

  @override
  void dispose() {
    for (final c in [_token, _repos, _gist, _deepseek, _hours, _workflow, _ref]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final repos = _repos.text.split(RegExp(r'[\s,]+')).where((r) => r.contains('/')).toList();
    await widget.state.saveSettings(
      _s.copyWith(
        githubToken: _token.text.trim(),
        repos: repos,
        gistId: _gist.text.trim(),
        deepseekKey: _deepseek.text.trim(),
        stuckAfterHours: int.tryParse(_hours.text.trim())?.clamp(1, 168) ?? _s.stuckAfterHours,
        relaunchWorkflow: _workflow.text.trim(),
        relaunchRef: _ref.text.trim(),
      ),
    );
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      if (!widget.state.settings.configured)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text('Enter a GitHub token and at least one repository to start.'),
        ),
      _field(
        _token,
        'GitHub token',
        help: 'Fine-grained: Issues read/write, Pull requests, Checks, Actions read/write; Gists read.',
        secret: true,
      ),
      _field(_repos, 'Repositories (owner/name, one per line)', lines: 3),
      _field(_gist, 'Usage gist id', help: 'Printed by agent_usage_collector.py --create-gist'),
      _field(
        _deepseek,
        'DeepSeek API key (optional)',
        help: 'Reads the balance directly from the phone.',
        secret: true,
      ),
      _field(_hours, 'Stuck after (hours without activity)', number: true),
      _field(_workflow, 'Relaunch workflow file'),
      _field(_ref, 'Relaunch workflow branch'),
      const SizedBox(height: 8),
      FilledButton(onPressed: _save, child: const Text('Save')),
      const SizedBox(height: 16),
      Text(
        'Keys are stored in Android encrypted storage on this phone only.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );

  Widget _field(
    TextEditingController c,
    String label, {
    String? help,
    bool secret = false,
    bool number = false,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      obscureText: secret,
      maxLines: secret ? 1 : lines,
      keyboardType: number ? TextInputType.number : null,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}
