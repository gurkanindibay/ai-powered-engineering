import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
    if (token == null) {return false;}
    try {
      final response = await transport
          .post(
            uri('/api/v1/auth/refresh'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': token}),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 || epoch != _sessionEpoch) {return false;}
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final access = data['access_token'];
      final refresh = data['refresh_token'];
      if (access is! String || access.isEmpty || refresh is! String || refresh.isEmpty) {
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
      throw ArgumentError('Credentials may only be sent to the configured API origin.');
    }
    final attemptedToken = _accessToken;
    final epoch = _sessionEpoch;
    final response = await send(_headers(headers));
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
    if (_sessionEpoch != epoch) {return response;}
    if (_accessToken != attemptedToken && _accessToken != null) {return _retry(send, headers);}
    final renewal = _renewal ??= _refresh();
    final renewed = await renewal;
    if (identical(_renewal, renewal)) {_renewal = null;}
    if (renewed) {return _retry(send, headers);}
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
      if (!configured.hasAuthority || configured.userInfo.isNotEmpty || configured.hasQuery || configured.hasFragment ||
          !['http', 'https'].contains(configured.scheme) || (kReleaseMode && !e2e && configured.scheme != 'https')) {
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

  static Future<http.Response> _retry(Future<http.Response> Function(Map<String, String>) send,
      Map<String, String>? headers) async {
    final token = _accessToken;
    final epoch = _sessionEpoch;
    final response = await send(_headers(headers));
    if (response.statusCode == 401 && _sessionEpoch == epoch && _accessToken == token) {
      clearSession();
      _expired.add(null);
    }
    return response;
  }

  static Map<String, String> _headers(Map<String, String>? headers) {
    final merged = <String, String>{...?headers};
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
}
