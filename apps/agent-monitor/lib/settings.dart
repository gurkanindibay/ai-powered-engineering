import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Settings {
  const Settings({
    this.githubToken = '',
    this.repos = const ['gurkanindibay/ai-powered-engineering'],
    this.gistId = '',
    this.deepseekKey = '',
    this.stuckAfterHours = 6,
    this.relaunchWorkflow = 'agent-relaunch.yml',
    this.relaunchRef = 'master',
  });

  final String githubToken;
  final List<String> repos;
  final String gistId;
  final String deepseekKey;
  final int stuckAfterHours;
  final String relaunchWorkflow;
  final String relaunchRef;

  bool get configured => githubToken.isNotEmpty && repos.isNotEmpty;

  Settings copyWith({
    String? githubToken,
    List<String>? repos,
    String? gistId,
    String? deepseekKey,
    int? stuckAfterHours,
    String? relaunchWorkflow,
    String? relaunchRef,
  }) => Settings(
    githubToken: githubToken ?? this.githubToken,
    repos: repos ?? this.repos,
    gistId: gistId ?? this.gistId,
    deepseekKey: deepseekKey ?? this.deepseekKey,
    stuckAfterHours: stuckAfterHours ?? this.stuckAfterHours,
    relaunchWorkflow: relaunchWorkflow ?? this.relaunchWorkflow,
    relaunchRef: relaunchRef ?? this.relaunchRef,
  );

  Map<String, dynamic> toJson() => {
    'githubToken': githubToken,
    'repos': repos,
    'gistId': gistId,
    'deepseekKey': deepseekKey,
    'stuckAfterHours': stuckAfterHours,
    'relaunchWorkflow': relaunchWorkflow,
    'relaunchRef': relaunchRef,
  };

  factory Settings.fromJson(Map<String, dynamic> json) {
    const d = Settings();
    return Settings(
      githubToken: json['githubToken'] as String? ?? d.githubToken,
      repos: (json['repos'] as List?)?.map((e) => e.toString()).toList() ?? d.repos,
      gistId: json['gistId'] as String? ?? d.gistId,
      deepseekKey: json['deepseekKey'] as String? ?? d.deepseekKey,
      stuckAfterHours: (json['stuckAfterHours'] as num?)?.toInt() ?? d.stuckAfterHours,
      relaunchWorkflow: json['relaunchWorkflow'] as String? ?? d.relaunchWorkflow,
      relaunchRef: json['relaunchRef'] as String? ?? d.relaunchRef,
    );
  }
}

/// Settings, tokens included, live in Android's encrypted storage only.
class SettingsStore {
  SettingsStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'agent_monitor_settings_v1';
  final FlutterSecureStorage _storage;

  Future<Settings> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return const Settings();
      return Settings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Exception {
      return const Settings();
    }
  }

  Future<void> save(Settings settings) => _storage.write(key: _key, value: jsonEncode(settings.toJson()));
}
