import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Severity level for application logs adhering to docs/standards/LOGGING_STANDARDS.md
enum LogLevel {
  trace(100, 'TRACE', '🔍'),
  debug(500, 'DEBUG', '🐛'),
  info(800, 'INFO', 'ℹ️'),
  warning(900, 'WARN', '⚠️'),
  error(1000, 'ERROR', '🛑'),
  fatal(1200, 'FATAL', '💥');

  final int value;
  final String label;
  final String emoji;

  const LogLevel(this.value, this.label, this.emoji);

  bool operator >=(LogLevel other) => value >= other.value;
  bool operator <=(LogLevel other) => value <= other.value;
  bool operator >(LogLevel other) => value > other.value;
  bool operator <(LogLevel other) => value < other.value;
}

/// A single structured log record.
class LogRecord {
  final DateTime timestamp;
  final LogLevel level;
  final String tag;
  final String message;
  final String? traceId;
  final Map<String, dynamic>? context;
  final Object? error;
  final StackTrace? stackTrace;

  LogRecord({
    DateTime? timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.traceId,
    this.context,
    this.error,
    this.stackTrace,
  }) : timestamp = timestamp ?? DateTime.now().toUtc();

  /// Formatted string representation for console inspection.
  String formatted() {
    final buffer = StringBuffer();
    final timeStr = timestamp.toIso8601String();
    buffer.write('[$timeStr] ${level.emoji} [${level.label}] [$tag]');
    if (traceId != null && traceId!.isNotEmpty) {
      buffer.write(' [trace: $traceId]');
    }
    buffer.write(' $message');

    if (context != null && context!.isNotEmpty) {
      final sanitized = AppLogger.redact(context);
      buffer.write(' context: $sanitized');
    }

    if (error != null) {
      buffer.write('\n  Error: $error');
    }

    if (stackTrace != null) {
      buffer.write('\n  StackTrace:\n$stackTrace');
    }

    return buffer.toString();
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'level': level.label,
    'tag': tag,
    'message': message,
    if (traceId != null) 'trace_id': traceId,
    if (context != null) 'context': AppLogger.redact(context),
    if (error != null) 'error': error.toString(),
  };

  @override
  String toString() => formatted();
}

/// Interface for custom log sinks.
abstract class LogSink {
  void log(LogRecord record);
}

/// Default console log sink using `debugPrint` in debug mode.
class ConsoleLogSink implements LogSink {
  const ConsoleLogSink();

  @override
  void log(LogRecord record) {
    if (kReleaseMode && record.level < LogLevel.info) {
      return;
    }
    // Using debugPrint for thread-safe non-truncating console emission in Flutter
    debugPrint(record.formatted());
    if (kDebugMode) {
      developer.log(
        record.message,
        time: record.timestamp,
        level: record.level.value,
        name: record.tag,
        error: record.error,
        stackTrace: record.stackTrace,
      );
    }
  }
}

/// In-memory ring buffer sink for testing assertions and in-app diagnostics.
class InMemoryLogSink implements LogSink {
  final int maxEntries;
  final List<LogRecord> _history = [];

  InMemoryLogSink({this.maxEntries = 200});

  List<LogRecord> get history => List.unmodifiable(_history);

  @override
  void log(LogRecord record) {
    if (_history.length >= maxEntries) {
      _history.removeAt(0);
    }
    _history.add(record);
  }

  void clear() => _history.clear();

  List<LogRecord> where({LogLevel? level, String? tag, String? traceId}) {
    return _history.where((r) {
      if (level != null && r.level != level) return false;
      if (tag != null && r.tag != tag) return false;
      if (traceId != null && r.traceId != traceId) return false;
      return true;
    }).toList();
  }
}

/// Single application entry point for all frontend logging.
/// Adheres strictly to docs/standards/LOGGING_STANDARDS.md
class AppLogger {
  AppLogger._();

  static LogLevel minLevel = kReleaseMode ? LogLevel.info : LogLevel.debug;
  static final List<LogSink> sinks = [const ConsoleLogSink()];
  static final InMemoryLogSink inMemory = InMemoryLogSink();

  static bool _inMemoryEnabled = true;

  static void enableInMemorySink(bool enabled) {
    _inMemoryEnabled = enabled;
  }

  static const _sensitiveKeys = {
    'password',
    'pass',
    'secret',
    'token',
    'access_token',
    'refresh_token',
    'authorization',
    'cookie',
    'pin',
    'cvv',
    'pan',
  };

  /// Redacts sensitive keys in context maps before logging.
  static Map<String, dynamic> redact(Map<String, dynamic>? data) {
    if (data == null) return {};
    final result = <String, dynamic>{};
    for (final entry in data.entries) {
      final keyLower = entry.key.toLowerCase();
      if (_sensitiveKeys.any((s) => keyLower.contains(s))) {
        result[entry.key] = '[REDACTED]';
      } else if (entry.value is Map<String, dynamic>) {
        result[entry.key] = redact(entry.value as Map<String, dynamic>);
      } else if (entry.value is List) {
        result[entry.key] = (entry.value as List).map((item) {
          if (item is Map<String, dynamic>) {
            return redact(item);
          }
          return item;
        }).toList();
      } else {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  /// Generates a standardized correlation trace ID (UUIDv4).
  static String newTraceId() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    // Set UUIDv4 version (4) and variant (RFC 4122)
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static void log(
    LogLevel level,
    String message, {
    String tag = 'App',
    String? traceId,
    Map<String, dynamic>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level < minLevel) {
      return;
    }

    final record = LogRecord(
      level: level,
      tag: tag,
      message: message,
      traceId: traceId,
      context: context,
      error: error,
      stackTrace: stackTrace,
    );

    if (_inMemoryEnabled) {
      inMemory.log(record);
    }

    for (final sink in sinks) {
      try {
        sink.log(record);
      } catch (_) {
        // Logging failures must not crash the application
      }
    }
  }

  static void trace(
    String message, {
    String tag = 'App',
    String? traceId,
    Map<String, dynamic>? context,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogLevel.trace,
    message,
    tag: tag,
    traceId: traceId,
    context: context,
    error: error,
    stackTrace: stackTrace,
  );

  static void debug(
    String message, {
    String tag = 'App',
    String? traceId,
    Map<String, dynamic>? context,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogLevel.debug,
    message,
    tag: tag,
    traceId: traceId,
    context: context,
    error: error,
    stackTrace: stackTrace,
  );

  static void info(
    String message, {
    String tag = 'App',
    String? traceId,
    Map<String, dynamic>? context,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogLevel.info,
    message,
    tag: tag,
    traceId: traceId,
    context: context,
    error: error,
    stackTrace: stackTrace,
  );

  static void warn(
    String message, {
    String tag = 'App',
    String? traceId,
    Map<String, dynamic>? context,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogLevel.warning,
    message,
    tag: tag,
    traceId: traceId,
    context: context,
    error: error,
    stackTrace: stackTrace,
  );

  static void error(
    String message, {
    String tag = 'App',
    String? traceId,
    Map<String, dynamic>? context,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogLevel.error,
    message,
    tag: tag,
    traceId: traceId,
    context: context,
    error: error,
    stackTrace: stackTrace,
  );

  static void fatal(
    String message, {
    String tag = 'App',
    String? traceId,
    Map<String, dynamic>? context,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogLevel.fatal,
    message,
    tag: tag,
    traceId: traceId,
    context: context,
    error: error,
    stackTrace: stackTrace,
  );

  @visibleForTesting
  static void reset() {
    minLevel = kReleaseMode ? LogLevel.info : LogLevel.debug;
    inMemory.clear();
  }
}
