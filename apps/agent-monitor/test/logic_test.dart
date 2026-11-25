import 'dart:convert';

import 'package:agent_monitor/github_client.dart';
import 'package:agent_monitor/models.dart';
import 'package:agent_monitor/stuck.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final now = DateTime.utc(2026, 11, 25, 12);

WorkItem item({DateTime? updated, Claim? claim, PullInfo? pull}) => WorkItem(
  repo: 'o/r',
  number: 7,
  title: 't',
  url: '',
  isPull: false,
  updatedAt: updated ?? now,
  labels: const [],
  claim: claim,
  pull: pull,
);

PullInfo pull(CheckState checks) => PullInfo(
  number: 9,
  title: 'p',
  url: '',
  author: 'me',
  headSha: 'abc',
  updatedAt: now,
  labels: const [],
  draft: false,
  checks: checks,
);

void main() {
  test('parses claim labels', () {
    final c = Claim.parse('claim:codex/0199-abc')!;
    expect(c.harness, 'codex');
    expect(c.session, '0199-abc');
    expect(Claim.parse('in progress'), isNull);
    expect(Claim.parse('claim:nosession'), isNull);
  });

  test('stuck when checks fail, idle at half, stuck after threshold', () {
    const h6 = Duration(hours: 6);
    expect(assess(item(pull: pull(CheckState.failure)), UsageSnapshot.empty, h6, now).health, Health.stuck);
    expect(
      assess(item(updated: now.subtract(const Duration(hours: 1))), UsageSnapshot.empty, h6, now).health,
      Health.active,
    );
    expect(
      assess(item(updated: now.subtract(const Duration(hours: 4))), UsageSnapshot.empty, h6, now).health,
      Health.idle,
    );
    expect(
      assess(item(updated: now.subtract(const Duration(hours: 7))), UsageSnapshot.empty, h6, now).health,
      Health.stuck,
    );
  });

  test('recent collector session keeps a quiet issue active', () {
    final snap = UsageSnapshot.fromJson({
      'providers': [
        {
          'id': 'claude',
          'name': 'Claude',
          'sessions': [
            {
              'session_id': 'abcdef123456',
              'tokens': 10,
              'last_activity': now.subtract(const Duration(minutes: 5)).toIso8601String(),
            },
          ],
        },
      ],
    });
    final quiet = item(updated: now.subtract(const Duration(hours: 9)), claim: const Claim('claude', 'abcdef12'));
    expect(assess(quiet, snap, const Duration(hours: 6), now).health, Health.active);
  });

  test('snapshot keeps money as Decimal', () {
    final p = ProviderUsage.fromJson({
      'id': 'deepseek',
      'name': 'DeepSeek',
      'balance': [
        {'currency': 'USD', 'total_balance': '0.10', 'granted_balance': '0.07', 'topped_up_balance': '0.03'},
      ],
    });
    expect(p.balance.single.total, Decimal.parse('0.1'));
    expect(p.balance.single.granted + p.balance.single.toppedUp, p.balance.single.total);
  });

  test('summarizes check runs', () {
    expect(GitHubClient.summarizeChecks(const []), CheckState.none);
    expect(
      GitHubClient.summarizeChecks([
        {'status': 'completed', 'conclusion': 'success'},
        {'status': 'in_progress'},
      ]),
      CheckState.pending,
    );
    expect(
      GitHubClient.summarizeChecks([
        {'status': 'completed', 'conclusion': 'failure'},
        {'status': 'in_progress'},
      ]),
      CheckState.failure,
    );
    expect(
      GitHubClient.summarizeChecks([
        {'status': 'completed', 'conclusion': 'skipped'},
      ]),
      CheckState.success,
    );
  });

  test('fetchWork joins an issue with the PR carrying its claim and lists Copilot PRs', () async {
    final updated = now.toIso8601String();
    final mock = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/issues')) {
        return http.Response(
          jsonEncode([
            {
              'number': 1,
              'title': 'Issue',
              'html_url': 'u1',
              'updated_at': updated,
              'labels': [
                {'name': 'in progress'},
                {'name': 'claim:claude/s1'},
              ],
            },
            {
              'number': 2,
              'title': 'Its PR',
              'html_url': 'u2',
              'updated_at': updated,
              'pull_request': {},
              'labels': [
                {'name': 'in progress'},
                {'name': 'claim:claude/s1'},
              ],
            },
          ]),
          200,
        );
      }
      if (path.endsWith('/pulls')) {
        return http.Response(
          jsonEncode([
            {
              'number': 2,
              'title': 'Its PR',
              'html_url': 'u2',
              'updated_at': updated,
              'user': {'login': 'me'},
              'head': {'sha': 'a'},
              'labels': [
                {'name': 'claim:claude/s1'},
              ],
            },
            {
              'number': 3,
              'title': 'Copilot PR',
              'html_url': 'u3',
              'updated_at': updated,
              'user': {'login': 'Copilot'},
              'head': {'sha': 'b'},
              'labels': [],
            },
          ]),
          200,
        );
      }
      if (path.contains('/check-runs')) {
        return http.Response(
          jsonEncode({
            'check_runs': [
              {'status': 'completed', 'conclusion': 'failure'},
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    final items = await GitHubClient('t', client: mock).fetchWork('o/r');
    expect(items.map((i) => i.number), [1, 3]);
    expect(items.first.pull!.number, 2);
    expect(items.first.pull!.checks, CheckState.failure);
    expect(items.last.harness, 'copilot');
  });

  test('relaunch dispatch sends workflow inputs', () async {
    late Map<String, dynamic> sent;
    final mock = MockClient((req) async {
      expect(req.url.path, '/repos/o/r/actions/workflows/agent-relaunch.yml/dispatches');
      sent = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('', 204);
    });
    await GitHubClient('t', client: mock).dispatchRelaunch(
      repo: 'o/r',
      workflow: 'agent-relaunch.yml',
      ref: 'master',
      issue: 7,
      harness: 'codex',
      note: 'n',
    );
    expect(sent, {
      'ref': 'master',
      'inputs': {'issue': '7', 'harness': 'codex', 'note': 'n'},
    });
  });
}
