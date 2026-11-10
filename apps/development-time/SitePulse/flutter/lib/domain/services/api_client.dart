import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../errors/app_exception.dart';
import '../logging/app_logger.dart';
export '../errors/app_exception.dart';
export '../logging/app_logger.dart';

/// Single entry point for every call to the SitePulse backend.
///
/// * The base URL comes from `--dart-define=SITEPULSE_API_BASE_URL=https://api.example.com`.
///   Without it, debug builds fall back to the local development server
///   (`10.0.2.2` on the Android emulator, which maps to the host machine).
///   Release builds refuse to fall back to clear-text HTTP.
/// * The bearer token from the last successful login is attached to every request.
class ApiClient {
  ApiClient._();

  static const String _configuredBaseUrl = String.fromEnvironment(
    'SITEPULSE_API_BASE_URL',
  );

  static String? _accessToken;
  static String? _refreshToken;
  static int _sessionEpoch = 0;
  static Future<bool>? _renewal;
  static final _expired = StreamController<void>.broadcast(sync: true);
  static Stream<void> get sessionExpired => _expired.stream;
  static final _passwordChangeRequired = StreamController<void>.broadcast(sync: true);

  /// Fires when the server answers `403 PASSWORD_CHANGE_REQUIRED`: the signed-in
  /// user must set a new password before any other operation (STORY-06-06).
  static Stream<void> get passwordChangeRequired => _passwordChangeRequired.stream;
  @visibleForTesting
  static http.Client transport = http.Client();

  static void setSession(Map<String, dynamic> data) {
    final access = data['access_token'];
    final refresh = data['refresh_token'];
    if (access is! String ||
        access.isEmpty ||
        refresh is! String ||
        refresh.isEmpty) {
      throw const FormatException('Invalid server session');
    }
    _sessionEpoch++;
    _renewal = null;
    _accessToken = access;
    _refreshToken = refresh;
  }

  static void clearSession() {
    _sessionEpoch++;
    _renewal = null;
    _accessToken = null;
    _refreshToken = null;
  }

  static Future<void> logout() async {
    final headers = _headers(null);
    clearSession();
    try {
      await transport
          .post(uri('/api/v1/auth/logout'), headers: headers)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Offline logout clears local credentials; the server session expires normally.
    }
  }

  static Future<bool> _refresh() async {
    final token = _refreshToken;
    final epoch = _sessionEpoch;
    if (token == null) {
      return false;
    }
    try {
      final response = await transport
          .post(
            uri('/api/v1/auth/refresh'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': token}),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 || epoch != _sessionEpoch) {
        return false;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final access = data['access_token'];
      final refresh = data['refresh_token'];
      if (access is! String ||
          access.isEmpty ||
          refresh is! String ||
          refresh.isEmpty) {
        return false;
      }
      _accessToken = access;
      _refreshToken = refresh;
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<http.Response> _send(
    Uri url,
    Future<http.Response> Function(Map<String, String>) send,
    Map<String, String>? headers,
  ) async {
    if (url.origin != Uri.parse(baseUrl).origin) {
      throw ArgumentError(
        'Credentials may only be sent to the configured API origin.',
      );
    }
    final reqHeaders = _headers(headers);
    final traceId = reqHeaders['x-request-id'];
    final stopwatch = Stopwatch()..start();

    AppLogger.debug(
      '--> HTTP request: ${url.path}',
      tag: 'ApiClient',
      traceId: traceId,
      context: {'origin': url.origin, 'query': url.queryParameters},
    );

    final attemptedToken = _accessToken;
    final epoch = _sessionEpoch;
    http.Response response;
    try {
      response = await send(reqHeaders);
    } catch (e, stack) {
      stopwatch.stop();
      AppLogger.error(
        '<-- Network failure: ${url.path} (${stopwatch.elapsedMilliseconds}ms)',
        tag: 'ApiClient',
        traceId: traceId,
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }

    stopwatch.stop();
    final respTraceId = response.headers['x-request-id'] ?? traceId;
    if (response.statusCode >= 500) {
      AppLogger.error(
        '<-- ${response.statusCode} ${url.path} (${stopwatch.elapsedMilliseconds}ms)',
        tag: 'ApiClient',
        traceId: respTraceId,
      );
    } else if (response.statusCode >= 400) {
      AppLogger.warn(
        '<-- ${response.statusCode} ${url.path} (${stopwatch.elapsedMilliseconds}ms)',
        tag: 'ApiClient',
        traceId: respTraceId,
      );
    } else {
      AppLogger.info(
        '<-- ${response.statusCode} ${url.path} (${stopwatch.elapsedMilliseconds}ms)',
        tag: 'ApiClient',
        traceId: respTraceId,
      );
    }

    if (response.statusCode == 403 &&
        attemptedToken != null &&
        response.body.contains('PASSWORD_CHANGE_REQUIRED')) {
      _passwordChangeRequired.add(null);
      return response;
    }
    if (response.statusCode != 401 ||
        attemptedToken == null ||
        const {
          '/api/v1/auth/login',
          '/api/v1/auth/google',
          '/api/v1/auth/register',
          '/api/v1/auth/refresh',
        }.contains(url.path)) {
      return response;
    }
    if (_sessionEpoch != epoch) {
      return response;
    }
    if (_accessToken != attemptedToken && _accessToken != null) {
      return _retry(send, headers);
    }
    final renewal = _renewal ??= _refresh();
    final renewed = await renewal;
    if (identical(_renewal, renewal)) {
      _renewal = null;
    }
    if (renewed) {
      return _retry(send, headers);
    }
    if (_sessionEpoch == epoch) {
      clearSession();
      _expired.add(null);
    }
    return response;
  }

  static String? get accessToken => _accessToken;

  static void setAccessToken(String? token) {
    clearSession();
    _accessToken = token == null || token.isEmpty ? null : token;
  }

  static String get baseUrl {
    if (_configuredBaseUrl.isNotEmpty) {
      final configured = Uri.parse(_configuredBaseUrl);
      const e2e = bool.fromEnvironment('E2E');
      if (!configured.hasAuthority ||
          configured.userInfo.isNotEmpty ||
          configured.hasQuery ||
          configured.hasFragment ||
          !['http', 'https'].contains(configured.scheme) ||
          (kReleaseMode && !e2e && configured.scheme != 'https')) {
        throw StateError('A valid HTTPS API origin is required.');
      }
      return _configuredBaseUrl.endsWith('/')
          ? _configuredBaseUrl.substring(0, _configuredBaseUrl.length - 1)
          : _configuredBaseUrl;
    }
    if (kReleaseMode) {
      throw StateError(
        'SITEPULSE_API_BASE_URL must be provided for release builds (HTTPS only).',
      );
    }
    return 'http://${_developmentHost()}:8080';
  }

  static String _developmentHost() {
    if (kIsWeb) {
      final host = Uri.base.host;
      return (host.isNotEmpty && host != '0.0.0.0') ? host : 'localhost';
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return '10.0.2.2';
    }
    return 'localhost';
  }

  /// Builds a backend URI from a path (starting with `/`) and optional query parameters.
  static Uri uri(String path, [Map<String, dynamic>? queryParameters]) {
    final base = Uri.parse(baseUrl);
    final query = queryParameters?.map(
      (k, v) => MapEntry(k, v?.toString() ?? ''),
    );
    return base.replace(
      path: '${base.path}$path',
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  static Future<http.Response> _retry(
    Future<http.Response> Function(Map<String, String>) send,
    Map<String, String>? headers,
  ) async {
    final token = _accessToken;
    final epoch = _sessionEpoch;
    final response = await send(_headers(headers));
    if (response.statusCode == 401 &&
        _sessionEpoch == epoch &&
        _accessToken == token) {
      clearSession();
      _expired.add(null);
    }
    return response;
  }

  static Map<String, String> _headers(Map<String, String>? headers) {
    final merged = <String, String>{...?headers};
    merged.putIfAbsent('x-request-id', () => AppLogger.newTraceId());
    final token = _accessToken;
    if (token != null) {
      merged['Authorization'] = 'Bearer $token';
    }
    return merged;
  }

  static Future<http.Response> get(Uri url, {Map<String, String>? headers}) =>
      _send(url, (h) => transport.get(url, headers: h), headers);

  static Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _send(
    url,
    (h) => transport.post(url, headers: h, body: body, encoding: encoding),
    headers,
  );

  static Future<http.Response> put(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _send(
    url,
    (h) => transport.put(url, headers: h, body: body, encoding: encoding),
    headers,
  );

  static Future<http.Response> delete(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _send(
    url,
    (h) => transport.delete(url, headers: h, body: body, encoding: encoding),
    headers,
  );

  /// Random key identifying one user action, so a retried request is applied once.
  static String newIdempotencyKey() {
    final rnd = Random.secure();
    return List<int>.generate(
      16,
      (_) => rnd.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// POSTs a money-moving request with an `Idempotency-Key`; on timeout the same
  /// request is retried once with the same key, so the server applies it once.
  static Future<http.Response> postIdempotent(
    Uri url, {
    required Object body,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final headers = {
      'Content-Type': 'application/json',
      'Idempotency-Key': newIdempotencyKey(),
    };
    try {
      return await post(url, headers: headers, body: body).timeout(timeout);
    } on TimeoutException {
      return await post(url, headers: headers, body: body).timeout(timeout);
    }
  }

  /// Decodes an HTTP response body.
  ///
  /// On success (2xx): returns the parsed JSON (Map, List, or null if body is empty).
  /// On failure: parses standard error envelope `{"error": {"code", "message", ...}}`
  /// or legacy/fallback formats and throws a strongly-typed [ApiException].
  static dynamic decode(http.Response response) {
    final bodyText = utf8.decode(response.bodyBytes);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (bodyText.trim().isEmpty) return null;
      try {
        return json.decode(bodyText);
      } catch (e) {
        throw const FormatException('Sunucudan geçersiz JSON verisi alındı.');
      }
    }

    String? code;
    String? message;
    String? traceId;
    Map<String, dynamic>? details;

    try {
      final decoded = json.decode(bodyText);
      if (decoded is Map<String, dynamic>) {
        if (decoded['error'] is Map<String, dynamic>) {
          final err = decoded['error'] as Map<String, dynamic>;
          code = err['code']?.toString();
          message = err['message']?.toString();
          traceId = err['trace_id']?.toString();
          if (err['details'] is Map<String, dynamic>) {
            details = err['details'] as Map<String, dynamic>;
          }
        } else if (decoded['error'] is String) {
          message = decoded['error'] as String;
        } else if (decoded['message'] != null) {
          message = decoded['message'].toString();
        }
      }
    } catch (_) {
      final trimmed = bodyText.trim();
      if (trimmed.isNotEmpty) {
        message = trimmed;
      }
    }

    final resolvedMessage = (message != null && message.isNotEmpty)
        ? message
        : _defaultStatusMessage(response.statusCode);

    traceId ??= response.headers['x-request-id'];

    final errorContext = <String, dynamic>{'status': response.statusCode};
    if (code != null) errorContext['code'] = code;
    if (details != null) errorContext['details'] = details;

    AppLogger.error(
      'API Error: ${response.statusCode} - $resolvedMessage',
      tag: 'ApiClient',
      traceId: traceId,
      context: errorContext,
    );

    throw ApiException(
      message: resolvedMessage,
      statusCode: response.statusCode,
      code: code,
      traceId: traceId,
      details: details,
    );
  }

  static Map<String, dynamic> decodeMap(http.Response response) {
    final result = decode(response);
    if (result is! Map<String, dynamic>) {
      throw const FormatException('Beklenen veri haritası (Map) alınamadı.');
    }
    return result;
  }

  static List<dynamic> decodeList(http.Response response) {
    final result = decode(response);
    if (result is! List) {
      throw const FormatException('Beklenen veri listesi (List) alınamadı.');
    }
    return result;
  }

  static String _defaultStatusMessage(int statusCode) {
    return switch (statusCode) {
      400 => 'Geçersiz istek parametreleri (400).',
      401 => 'Oturum açmanız gerekiyor (401).',
      403 => 'Bu işlem için yetkiniz bulunmuyor (403).',
      404 => 'İstenen kaynak bulunamadı (404).',
      409 => 'İşlem mevcut durum ile çakışıyor (409).',
      422 => 'İşlem kurallara uygun değil (422).',
      429 => 'Çok fazla istek yapıldı. Lütfen biraz bekleyin (429).',
      500 => 'Sunucu hatası oluştu (500).',
      503 => 'Hizmet şu anda kullanılamıyor (503).',
      _ => 'İstek başarısız oldu ($statusCode).',
    };
  }
}
