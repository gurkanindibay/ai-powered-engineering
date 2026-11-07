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

  static const String _configuredBaseUrl = String.fromEnvironment('SITEPULSE_API_BASE_URL');

  static String? _accessToken;

  static String? get accessToken => _accessToken;

  static void setAccessToken(String? token) {
    _accessToken = (token == null || token.isEmpty) ? null : token;
  }

  static String get baseUrl {
    if (_configuredBaseUrl.isNotEmpty) {
      return _configuredBaseUrl.endsWith('/')
          ? _configuredBaseUrl.substring(0, _configuredBaseUrl.length - 1)
          : _configuredBaseUrl;
    }
    if (kReleaseMode) {
      throw StateError('SITEPULSE_API_BASE_URL must be provided for release builds (HTTPS only).');
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
    final query = queryParameters?.map((k, v) => MapEntry(k, v?.toString() ?? ''));
    return base.replace(
      path: '${base.path}$path',
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
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
      http.get(url, headers: _headers(headers));

  static Future<http.Response> post(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      http.post(url, headers: _headers(headers), body: body, encoding: encoding);

  static Future<http.Response> put(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      http.put(url, headers: _headers(headers), body: body, encoding: encoding);

  static Future<http.Response> delete(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      http.delete(url, headers: _headers(headers), body: body, encoding: encoding);

  /// Random key identifying one user action, so a retried request is applied once.
  static String newIdempotencyKey() {
    final rnd = Random.secure();
    return List<int>.generate(16, (_) => rnd.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// POSTs a money-moving request with an `Idempotency-Key`; on timeout the same
  /// request is retried once with the same key, so the server applies it once.
  static Future<http.Response> postIdempotent(Uri url, {required Object body, Duration timeout = const Duration(seconds: 8)}) async {
    final headers = {'Content-Type': 'application/json', 'Idempotency-Key': newIdempotencyKey()};
    try {
      return await post(url, headers: headers, body: body).timeout(timeout);
    } on TimeoutException {
      return await post(url, headers: headers, body: body).timeout(timeout);
    }
  }
}
