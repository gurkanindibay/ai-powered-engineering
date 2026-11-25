import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class GitHubException implements Exception {
  GitHubException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'GitHub $status: $message';
}

/// The few GitHub REST calls the monitor needs.
class GitHubClient {
  GitHubClient(this.token, {http.Client? client}) : _http = client ?? http.Client();

  static const copilotAssignee = 'copilot-swe-agent[bot]';
  final String token;
  final http.Client _http;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  Future<dynamic> _send(String method, String path, {Object? body}) async {
    final uri = Uri.parse(path.startsWith('http') ? path : 'https://api.github.com/$path');
    final request = http.Request(method, uri)..headers.addAll(_headers);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(await _http.send(request));
    if (response.statusCode >= 300) {
      var message = response.reasonPhrase ?? '';
      try {
        message = (jsonDecode(response.body) as Map<String, dynamic>)['message']?.toString() ?? message;
      } on FormatException {
        // keep the reason phrase
      }
      throw GitHubException(response.statusCode, message);
    }
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }

  /// Claimed issues and PRs, plus open PRs by the Copilot coding agent.
  Future<List<WorkItem>> fetchWork(String repo) async {
    final claimed = await _send(
      'GET',
      'repos/$repo/issues?state=open&per_page=100&labels=${Uri.encodeQueryComponent(inProgressLabel)}',
    ) as List;
    final pullsRaw = await _send('GET', 'repos/$repo/pulls?state=open&per_page=100') as List;
    final pulls = pullsRaw.cast<Map<String, dynamic>>().map(_pull).toList();

    final interesting = pulls.where((p) => p.isCopilot || p.labels.any((l) => l.startsWith(claimPrefix))).toList();
    final checked = await Future.wait(interesting.map((p) async => p.withChecks(await checkState(repo, p.headSha))));
    final byNumber = {for (final p in checked) p.number: p};

    final items = <WorkItem>[];
    final usedPulls = <int>{};
    for (final raw in claimed.cast<Map<String, dynamic>>()) {
      final labels = _labels(raw);
      final claim = labels.map(Claim.parse).whereType<Claim>().firstOrNull;
      final number = raw['number'] as int;
      final isPull = raw['pull_request'] != null;
      PullInfo? pull;
      if (isPull) {
        pull = byNumber[number];
      } else if (claim != null) {
        // rule 10: the PR that delivers an issue carries the same claim label.
        pull = checked.where((p) => p.labels.contains(claim.label)).firstOrNull;
      }
      if (pull != null) usedPulls.add(pull.number);
      if (isPull &&
          claim != null &&
          claimed.any((o) => o['pull_request'] == null && _labels(o).contains(claim.label))) {
        continue; // shown with its issue
      }
      items.add(
        WorkItem(
          repo: repo,
          number: number,
          title: raw['title']?.toString() ?? '',
          url: raw['html_url']?.toString() ?? '',
          isPull: isPull,
          updatedAt: DateTime.parse(raw['updated_at'] as String),
          labels: labels,
          claim: claim,
          pull: pull,
        ),
      );
    }
    for (final p in checked.where((p) => p.isCopilot && !usedPulls.contains(p.number))) {
      items.add(
        WorkItem(
          repo: repo,
          number: p.number,
          title: p.title,
          url: p.url,
          isPull: true,
          updatedAt: p.updatedAt,
          labels: p.labels,
          pull: p,
        ),
      );
    }
    return items;
  }

  Future<CheckState> checkState(String repo, String sha) async {
    if (sha.isEmpty) return CheckState.none;
    final data = await _send('GET', 'repos/$repo/commits/$sha/check-runs?per_page=100') as Map<String, dynamic>;
    final runs = (data['check_runs'] as List? ?? const []).cast<Map<String, dynamic>>();
    return summarizeChecks(runs);
  }

  static CheckState summarizeChecks(List<Map<String, dynamic>> runs) {
    if (runs.isEmpty) return CheckState.none;
    const bad = {'failure', 'timed_out', 'cancelled', 'action_required', 'startup_failure'};
    if (runs.any((r) => bad.contains(r['conclusion']))) return CheckState.failure;
    if (runs.any((r) => r['status'] != 'completed')) return CheckState.pending;
    return CheckState.success;
  }

  /// Raw JSON of the collector's gist file.
  Future<UsageSnapshot> fetchSnapshot(String gistId) async {
    final gist = await _send('GET', 'gists/$gistId') as Map<String, dynamic>;
    final file = (gist['files'] as Map<String, dynamic>?)?['agent-usage.json'] as Map<String, dynamic>?;
    if (file == null) throw GitHubException(404, 'agent-usage.json not in gist');
    var content = file['content']?.toString() ?? '';
    if (file['truncated'] == true && file['raw_url'] != null) {
      final raw = await _http.get(Uri.parse(file['raw_url'] as String), headers: _headers);
      content = raw.body;
    }
    return UsageSnapshot.fromJson(jsonDecode(content) as Map<String, dynamic>);
  }

  /// Starts the relaunch workflow (a claude, codex or deepseek run).
  Future<void> dispatchRelaunch({
    required String repo,
    required String workflow,
    required String ref,
    required int issue,
    required String harness,
    String note = '',
  }) => _send(
    'POST',
    'repos/$repo/actions/workflows/$workflow/dispatches',
    body: {
      'ref': ref,
      'inputs': {'issue': '$issue', 'harness': harness, 'note': note},
    },
  );

  /// Hands the issue to the Copilot coding agent, which opens its own PR.
  Future<void> assignCopilot(String repo, int issue) => _send(
    'POST',
    'repos/$repo/issues/$issue/assignees',
    body: {
      'assignees': [copilotAssignee],
    },
  );

  /// Drops a stale claim so the new session can claim the issue.
  Future<void> releaseClaim(String repo, int issue, Claim claim) async {
    for (final label in [claim.label, inProgressLabel]) {
      try {
        await _send('DELETE', 'repos/$repo/issues/$issue/labels/${Uri.encodeComponent(label)}');
      } on GitHubException catch (e) {
        if (e.status != 404) rethrow;
      }
    }
  }

  void close() => _http.close();

  static List<String> _labels(dynamic raw) => ((raw as Map<String, dynamic>)['labels'] as List? ?? const [])
      .map((l) => l is Map ? l['name']?.toString() ?? '' : l.toString())
      .where((l) => l.isNotEmpty)
      .toList();

  static PullInfo _pull(Map<String, dynamic> raw) => PullInfo(
    number: raw['number'] as int,
    title: raw['title']?.toString() ?? '',
    url: raw['html_url']?.toString() ?? '',
    author: (raw['user'] as Map<String, dynamic>?)?['login']?.toString() ?? '',
    headSha: (raw['head'] as Map<String, dynamic>?)?['sha']?.toString() ?? '',
    updatedAt: DateTime.parse(raw['updated_at'] as String),
    labels: _labels(raw),
    draft: raw['draft'] == true,
  );
}

/// Balance straight from DeepSeek when the key is stored in the app.
Future<ProviderUsage> fetchDeepSeek(String key, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final response = await c.get(
      Uri.parse('https://api.deepseek.com/user/balance'),
      headers: {'Authorization': 'Bearer $key', 'Accept': 'application/json'},
    );
    if (response.statusCode != 200) {
      return ProviderUsage(id: 'deepseek', name: 'DeepSeek', status: 'error', note: 'HTTP ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return ProviderUsage.fromJson({
      'id': 'deepseek',
      'name': 'DeepSeek',
      'status': 'ok',
      'source': 'api.deepseek.com (from phone)',
      'note': data['is_available'] == false ? 'Balance too low for API calls.' : '',
      'balance': data['balance_infos'] ?? const [],
    });
  } finally {
    if (client == null) c.close();
  }
}
