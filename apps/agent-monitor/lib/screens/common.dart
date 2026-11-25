import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../stuck.dart';

const harnessColors = <String, Color>{
  'claude': Color(0xFFD97757),
  'codex': Color(0xFF10A37F),
  'antigravity': Color(0xFF4285F4),
  'copilot': Color(0xFF8957E5),
  'deepseek': Color(0xFF4D6BFE),
};

Color harnessColor(String harness) => harnessColors[harness] ?? Colors.blueGrey;

IconData healthIcon(Health h) => switch (h) {
  Health.active => Icons.play_circle_fill,
  Health.idle => Icons.pause_circle_filled,
  Health.stuck => Icons.error,
};

Color healthColor(Health h) => switch (h) {
  Health.active => Colors.green,
  Health.idle => Colors.amber.shade700,
  Health.stuck => Colors.red,
};

Future<void> openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

String ago(DateTime? t) => t == null ? 'never' : '${describe(DateTime.now().toUtc().difference(t.toUtc()))} ago';

String compactTokens(int? n) {
  if (n == null) return '–';
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.errors, {super.key});

  final List<String> errors;

  @override
  Widget build(BuildContext context) => errors.isEmpty
      ? const SizedBox.shrink()
      : MaterialBanner(
          content: Text(errors.join('\n')),
          leading: const Icon(Icons.warning_amber),
          actions: const [SizedBox.shrink()],
        );
}
