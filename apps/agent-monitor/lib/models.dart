import 'package:decimal/decimal.dart';

/// Harnesses the monitor knows how to show. Unknown claim harnesses are kept
/// as-is so new tools still appear.
const knownHarnesses = ['claude', 'codex', 'antigravity', 'copilot', 'deepseek'];

const inProgressLabel = 'in progress';
const claimPrefix = 'claim:';

/// Owner encoded in one `claim:<harness>/<session>` label (scripts/issue_claim.py).
class Claim {
  const Claim(this.harness, this.session);

  final String harness;
  final String session;

  String get label => '$claimPrefix$harness/$session';

  static Claim? parse(String label) {
    if (!label.startsWith(claimPrefix)) return null;
    final rest = label.substring(claimPrefix.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    return Claim(rest.substring(0, slash), rest.substring(slash + 1));
  }
}

enum CheckState { none, pending, success, failure }

class PullInfo {
  const PullInfo({
    required this.number,
    required this.title,
    required this.url,
    required this.author,
    required this.headSha,
    required this.updatedAt,
    required this.labels,
    required this.draft,
    this.checks = CheckState.none,
  });

  final int number;
  final String title;
  final String url;
  final String author;
  final String headSha;
  final DateTime updatedAt;
  final List<String> labels;
  final bool draft;
  final CheckState checks;

  PullInfo withChecks(CheckState state) => PullInfo(
    number: number,
    title: title,
    url: url,
    author: author,
    headSha: headSha,
    updatedAt: updatedAt,
    labels: labels,
    draft: draft,
    checks: state,
  );

  bool get isCopilot => author == 'Copilot' || author.startsWith('copilot-swe-agent');
}

/// One unit of agent work: a claimed issue (with its PR when there is one),
/// or a PR an agent opened without a claimed issue (Copilot coding agent).
class WorkItem {
  const WorkItem({
    required this.repo,
    required this.number,
    required this.title,
    required this.url,
    required this.isPull,
    required this.updatedAt,
    required this.labels,
    this.claim,
    this.pull,
  });

  final String repo;
  final int number;
  final String title;
  final String url;
  final bool isPull;
  final DateTime updatedAt;
  final List<String> labels;
  final Claim? claim;
  final PullInfo? pull;

  String get harness => claim?.harness ?? (pull?.isCopilot == true ? 'copilot' : 'unclaimed');

  DateTime get lastActivity {
    final pr = pull?.updatedAt;
    return pr != null && pr.isAfter(updatedAt) ? pr : updatedAt;
  }
}

class UsageWindow {
  const UsageWindow({
    required this.label,
    this.tokens,
    this.limitTokens,
    this.usedPercent,
    this.resetsAt,
    this.requests,
    this.limitRequests,
  });

  final String label;
  final int? tokens;
  final int? limitTokens;
  final double? usedPercent;
  final DateTime? resetsAt;
  final Decimal? requests;
  final int? limitRequests;

  factory UsageWindow.fromJson(Map<String, dynamic> json) => UsageWindow(
    label: json['label']?.toString() ?? '',
    tokens: (json['tokens'] as num?)?.toInt(),
    limitTokens: (json['limit_tokens'] as num?)?.toInt(),
    usedPercent: (json['used_percent'] as num?)?.toDouble(),
    resetsAt: _date(json['resets_at']),
    requests: Decimal.tryParse(json['requests']?.toString() ?? ''),
    limitRequests: (json['limit_requests'] as num?)?.toInt(),
  );
}

class Balance {
  const Balance(this.currency, this.total, this.granted, this.toppedUp);

  final String currency;
  final Decimal total;
  final Decimal granted;
  final Decimal toppedUp;

  factory Balance.fromJson(Map<String, dynamic> json) => Balance(
    json['currency']?.toString() ?? '',
    Decimal.tryParse(json['total_balance']?.toString() ?? '') ?? Decimal.zero,
    Decimal.tryParse(json['granted_balance']?.toString() ?? '') ?? Decimal.zero,
    Decimal.tryParse(json['topped_up_balance']?.toString() ?? '') ?? Decimal.zero,
  );
}

class AgentSession {
  const AgentSession({
    required this.id,
    required this.project,
    required this.model,
    required this.tokens,
    this.lastActivity,
  });

  final String id;
  final String project;
  final String model;
  final int tokens;
  final DateTime? lastActivity;

  factory AgentSession.fromJson(Map<String, dynamic> json) => AgentSession(
    id: json['session_id']?.toString() ?? '',
    project: json['project']?.toString() ?? '',
    model: json['model']?.toString() ?? '',
    tokens: (json['tokens'] as num?)?.toInt() ?? 0,
    lastActivity: _date(json['last_activity']),
  );
}

class ProviderUsage {
  const ProviderUsage({
    required this.id,
    required this.name,
    required this.status,
    this.source = '',
    this.note = '',
    this.windows = const [],
    this.balance = const [],
    this.sessions = const [],
  });

  final String id;
  final String name;
  final String status;
  final String source;
  final String note;
  final List<UsageWindow> windows;
  final List<Balance> balance;
  final List<AgentSession> sessions;

  factory ProviderUsage.fromJson(Map<String, dynamic> json) => ProviderUsage(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    status: json['status']?.toString() ?? 'ok',
    source: json['source']?.toString() ?? '',
    note: json['note']?.toString() ?? '',
    windows: _list(json['windows']).map(UsageWindow.fromJson).toList(),
    balance: _list(json['balance']).map(Balance.fromJson).toList(),
    sessions: _list(json['sessions']).map(AgentSession.fromJson).toList(),
  );
}

/// Snapshot written by scripts/agent_usage_collector.py.
class UsageSnapshot {
  const UsageSnapshot({required this.generatedAt, required this.machine, required this.providers});

  final DateTime? generatedAt;
  final String machine;
  final List<ProviderUsage> providers;

  factory UsageSnapshot.fromJson(Map<String, dynamic> json) => UsageSnapshot(
    generatedAt: _date(json['generated_at']),
    machine: json['machine']?.toString() ?? '',
    providers: _list(json['providers']).map(ProviderUsage.fromJson).toList(),
  );

  static const empty = UsageSnapshot(generatedAt: null, machine: '', providers: []);

  /// The collector session a claim refers to, if the collector saw it.
  /// Claim labels truncate long ids, so a prefix match counts.
  AgentSession? sessionFor(Claim claim) {
    final wanted = claim.session.toLowerCase();
    if (wanted.length < 6) return null;
    for (final provider in providers) {
      for (final session in provider.sessions) {
        final id = session.id.toLowerCase();
        if (id.isNotEmpty && (id.startsWith(wanted) || wanted.startsWith(id))) return session;
      }
    }
    return null;
  }
}

DateTime? _date(Object? value) => value is String ? DateTime.tryParse(value) : null;

List<Map<String, dynamic>> _list(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];
