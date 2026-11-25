import 'dart:async';

import 'package:flutter/foundation.dart';

import 'github_client.dart';
import 'models.dart';
import 'settings.dart';
import 'stuck.dart';

class AppState extends ChangeNotifier {
  AppState(this._store);

  final SettingsStore _store;
  Settings settings = const Settings();
  List<WorkItem> work = const [];
  UsageSnapshot snapshot = UsageSnapshot.empty;
  ProviderUsage? deepseekLive;
  final List<String> errors = [];
  bool loading = false;
  DateTime? refreshedAt;
  Timer? _timer;

  Duration get stuckAfter => Duration(hours: settings.stuckAfterHours);

  Future<void> init() async {
    settings = await _store.load();
    notifyListeners();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => refresh());
    await refresh();
  }

  Future<void> saveSettings(Settings value) async {
    settings = value;
    await _store.save(value);
    notifyListeners();
    await refresh();
  }

  GitHubClient get _client => GitHubClient(settings.githubToken);

  Future<void> refresh() async {
    if (loading || !settings.configured) return;
    loading = true;
    errors.clear();
    notifyListeners();
    final client = _client;
    try {
      final found = <WorkItem>[];
      for (final repo in settings.repos) {
        try {
          found.addAll(await client.fetchWork(repo));
        } on Exception catch (e) {
          errors.add('$repo: $e');
        }
      }
      work = found;
      if (settings.gistId.isNotEmpty) {
        try {
          snapshot = await client.fetchSnapshot(settings.gistId);
        } on Exception catch (e) {
          errors.add('Usage gist: $e');
        }
      }
      if (settings.deepseekKey.isNotEmpty) {
        try {
          deepseekLive = await fetchDeepSeek(settings.deepseekKey);
        } on Exception catch (e) {
          errors.add('DeepSeek: $e');
        }
      } else {
        deepseekLive = null;
      }
      refreshedAt = DateTime.now();
    } finally {
      client.close();
      loading = false;
      notifyListeners();
    }
  }

  Assessment assessItem(WorkItem item) => assess(item, snapshot, stuckAfter, DateTime.now().toUtc());

  /// Providers to show: the collector's, with DeepSeek replaced by the live call.
  List<ProviderUsage> get providers {
    final list = snapshot.providers.where((p) => !(deepseekLive != null && p.id == 'deepseek')).toList();
    if (deepseekLive != null) list.add(deepseekLive!);
    return list;
  }

  /// Starts a fresh agent on a stuck item. Returns a message for the user.
  Future<String> relaunch(WorkItem item, String harness, String note) async {
    final client = _client;
    try {
      if (harness == 'copilot') {
        final claim = item.claim;
        if (claim != null) await client.releaseClaim(item.repo, item.number, claim);
        await client.assignCopilot(item.repo, item.number);
        return 'Assigned #${item.number} to the Copilot coding agent.';
      }
      await client.dispatchRelaunch(
        repo: item.repo,
        workflow: settings.relaunchWorkflow,
        ref: settings.relaunchRef,
        issue: item.number,
        harness: harness,
        note: note,
      );
      return 'Started a $harness run for #${item.number}. It takes over the claim when it starts.';
    } finally {
      client.close();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
