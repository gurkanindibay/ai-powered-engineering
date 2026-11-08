import 'dart:convert';
import 'package:flutter/material.dart';
import '../../domain/models/auth_models.dart';
import '../../domain/services/api_client.dart';
import '../theme/app_theme.dart';
import '../../testing/test_id.dart';
import 'app_fullscreen_page.dart';

/// Session verification and tenant-scoped audit access.
class SecurityCenterPage extends StatefulWidget {
  final UserSession session;
  const SecurityCenterPage({super.key, required this.session});

  @override
  State<SecurityCenterPage> createState() => _SecurityCenterPageState();
}

class _SecurityCenterPageState extends State<SecurityCenterPage> {
  final _password = TextEditingController();
  List<Map<String, dynamic>> _events = const [];
  String? _message;
  bool _busy = false;
  int? _before;
  bool _more = true;

  @override
  void initState() {
    super.initState();
    if (widget.session.hasPermission('AUDIT_LOG_READ')) {
      _load();
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    setState(() => _busy = true);
    final password = _password.text;
    _password.clear();
    try {
      final result = await ApiClient.post(ApiClient.uri('/api/v1/auth/step-up'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'password': password}));
      if (mounted) {
        setState(() => _message = result.statusCode == 200
            ? 'Sensitive actions are verified for five minutes.'
            : 'Verification failed. Check your password and try again.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Unable to verify your session.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _load({bool export = false}) async {
    setState(() => _busy = true);
    try {
      final result = await ApiClient.get(ApiClient.uri(
          export ? '/api/v1/audit/export' : '/api/v1/audit/events',
          {'limit': '100', if (!export && _before != null) 'before': '$_before'}));
      if (result.statusCode != 200) {
        if (mounted) {
          setState(() => _message = 'Audit access is unavailable or not permitted.');
        }
        return;
      }
      final data = jsonDecode(result.body) as Map<String, dynamic>;
      final rows = (data['events'] as List<dynamic>)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      if (!mounted) {
        return;
      }
      if (export) {
        await AppFullscreenPage.push<void>(context: context, builder: (_) =>
          AppFullscreenPage(title: 'Audit export', subtitle: 'Up to 100 recent events',
            child: SelectableText(const JsonEncoder.withIndent('  ').convert(rows))));
      } else {
        setState(() {
          _events = [..._events, ...rows];
          _before = rows.isEmpty ? _before : rows.last['event_id'] as int;
          _more = rows.length == 100;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Unable to load audit events.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AppFullscreenPage(
    title: 'Security and audit',
    subtitle: 'Your current authorized scope',
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Verify sensitive actions', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: AppSpacing.md),
      testId('security_password', TextField(
        key: const Key('security_password'), controller: _password,
        obscureText: true, enableSuggestions: false, autocorrect: false,
        decoration: const InputDecoration(labelText: 'Current password'),
      )),
      const SizedBox(height: AppSpacing.md),
      testId('security_verify', FilledButton(
        key: const Key('security_verify'), onPressed: _busy ? null : _verify,
        child: const Text('Verify for five minutes'),
      )),
      if (_message != null) Padding(padding: const EdgeInsets.symmetric(vertical: AppSpacing.md), child: Text(_message!)),
      if (widget.session.hasPermission('AUDIT_LOG_READ')) ...[
        const SizedBox(height: AppSpacing.xl),
        const Text('Audit events', style: TextStyle(fontWeight: FontWeight.w600)),
        if (widget.session.hasPermission('AUDIT_LOG_EXPORT'))
          testId('security_export', TextButton.icon(
            key: const Key('security_export'), onPressed: _busy ? null : () => _load(export: true),
            icon: const Icon(Icons.download_outlined), label: const Text('Open recent events for export'),
          )),
        for (final event in _events)
          ListTile(contentPadding: EdgeInsets.zero,
            title: Text('${event['action']}'),
            subtitle: Text('${event['occurred_at']} · ${event['actor_id'] ?? event['actor_kind']}\n${event['resource_type']} ${event['resource_id'] ?? ''}'),
            trailing: Text('${event['outcome']}')),
        if (!_busy && _events.isEmpty) const Text('No events in your scope.'),
        if (_more)
          testId('security_more', OutlinedButton(
            key: const Key('security_more'), onPressed: _busy ? null : _load,
            child: const Text('Load older events'),
          )),
      ],
      if (_busy) const LinearProgressIndicator(),
    ]),
  );
}
