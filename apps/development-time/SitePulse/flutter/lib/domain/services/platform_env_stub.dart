import 'dart:async';

final Map<String, String> _memory = {};

/// Reads a saved preference (in-memory outside the browser).
String? readPreference(String key) => _memory[key];

/// Saves a preference (in-memory outside the browser).
void writePreference(String key, String? value) {
  if (value == null) {
    _memory.remove(key);
  } else {
    _memory[key] = value;
  }
}

/// Whether the platform reports no network. Always false outside the browser.
bool isPlatformOffline() => false;

/// Emits true when the platform goes offline and false when it comes back.
Stream<bool> platformOfflineChanges() => const Stream<bool>.empty();

/// Saving files is only wired up for the web build.
bool downloadBytes(String filename, List<int> bytes, String mimeType) => false;

/// Opening external pages is only wired up for the web build.
bool openUrlInNewTab(String url) => false;
