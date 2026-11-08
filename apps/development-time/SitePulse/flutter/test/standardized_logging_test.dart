import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/services/api_client.dart';

void main() {
  group('Standardized Logging - Flutter Tests', () {
    setUp(() {
      AppLogger.reset();
      AppLogger.minLevel = LogLevel.trace;
    });

    test('AppLogger records logs across all severity levels', () {
      AppLogger.trace('trace event', tag: 'TestTag');
      AppLogger.debug('debug event', tag: 'TestTag');
      AppLogger.info('info event', tag: 'TestTag');
      AppLogger.warn('warn event', tag: 'TestTag');
      AppLogger.error('error event', tag: 'TestTag');
      AppLogger.fatal('fatal event', tag: 'TestTag');

      final records = AppLogger.inMemory.history;
      expect(records.length, 6);
      expect(records[0].level, LogLevel.trace);
      expect(records[1].level, LogLevel.debug);
      expect(records[2].level, LogLevel.info);
      expect(records[3].level, LogLevel.warning);
      expect(records[4].level, LogLevel.error);
      expect(records[5].level, LogLevel.fatal);
    });

    test('AppLogger respects minLevel threshold', () {
      AppLogger.minLevel = LogLevel.warning;

      AppLogger.trace('trace should be ignored');
      AppLogger.debug('debug should be ignored');
      AppLogger.info('info should be ignored');
      AppLogger.warn('warning should be logged');
      AppLogger.error('error should be logged');

      final records = AppLogger.inMemory.history;
      expect(records.length, 2);
      expect(records[0].message, 'warning should be logged');
      expect(records[1].message, 'error should be logged');
    });

    test('AppLogger.redact masks sensitive fields recursively', () {
      final sensitive = {
        'username': 'admin',
        'password': 'SuperSecretPassword123!',
        'auth_token': 'jwt.token.abc',
        'nested': {
          'refresh_token': 'refresh_xyz',
          'public_info': 'visible',
          'card': {
            'cvv': '123',
            'last4': '4321',
          },
        },
        'list': [
          {'secret_key': 'hidden', 'id': 1},
        ],
      };

      final redacted = AppLogger.redact(sensitive);
      expect(redacted['username'], 'admin');
      expect(redacted['password'], '[REDACTED]');
      expect(redacted['auth_token'], '[REDACTED]');
      final nested = redacted['nested'] as Map<String, dynamic>;
      expect(nested['refresh_token'], '[REDACTED]');
      expect(nested['public_info'], 'visible');
      final card = nested['card'] as Map<String, dynamic>;
      expect(card['cvv'], '[REDACTED]');
      expect(card['last4'], '4321');
      final list = redacted['list'] as List;
      final listItem = list[0] as Map<String, dynamic>;
      expect(listItem['secret_key'], '[REDACTED]');
      expect(listItem['id'], 1);
    });

    test('AppLogger.newTraceId generates valid UUIDv4 format', () {
      final traceId1 = AppLogger.newTraceId();
      final traceId2 = AppLogger.newTraceId();

      expect(traceId1, isNot(equals(traceId2)));
      final uuidRegex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(uuidRegex.hasMatch(traceId1), isTrue);
      expect(uuidRegex.hasMatch(traceId2), isTrue);
    });

    test('LogRecord formats structured string output correctly', () {
      final record = LogRecord(
        timestamp: DateTime.utc(2026, 11, 8, 18, 30, 0),
        level: LogLevel.info,
        tag: 'AuthService',
        message: 'Login successful',
        traceId: 'trace-456',
        context: {'user_id': 'u1'},
      );

      final formatted = record.formatted();
      expect(formatted, contains('[2026-11-08T18:30:00.000Z]'));
      expect(formatted, contains('[INFO]'));
      expect(formatted, contains('[AuthService]'));
      expect(formatted, contains('[trace: trace-456]'));
      expect(formatted, contains('Login successful'));
      expect(formatted, contains('context: {user_id: u1}'));
    });

    test('ApiClient automatically injects x-request-id and logs network requests', () async {
      String? capturedRequestId;
      ApiClient.transport = MockClient((request) async {
        capturedRequestId = request.headers['x-request-id'];
        return http.Response(
          json.encode({'status': 'ok'}),
          200,
          headers: {'x-request-id': capturedRequestId ?? 'server-req-1'},
        );
      });

      final uri = ApiClient.uri('/api/v1/health');
      final response = await ApiClient.get(uri);
      expect(response.statusCode, 200);
      expect(capturedRequestId, isNotNull);
      expect(capturedRequestId!.isNotEmpty, isTrue);

      final logs = AppLogger.inMemory.where(tag: 'ApiClient');
      expect(logs.any((l) => l.message.contains('--> HTTP request: /api/v1/health')), isTrue);
      expect(logs.any((l) => l.message.contains('<-- 200 /api/v1/health')), isTrue);
    });

    test('ApiClient.decode captures traceId from x-request-id and logs API error', () {
      final response = http.Response.bytes(
        utf8.encode(json.encode({
          'error': {
            'code': 'RESOURCE_NOT_FOUND',
            'message': 'Site bulunamadı',
            'trace_id': 'trace-site-not-found',
          },
        })),
        404,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'x-request-id': 'trace-site-not-found',
        },
      );

      try {
        ApiClient.decode(response);
        fail('Expected ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 404);
        expect(e.code, 'RESOURCE_NOT_FOUND');
        expect(e.traceId, 'trace-site-not-found');
        expect(e.message, 'Site bulunamadı');

        final errorLogs = AppLogger.inMemory.where(
          tag: 'ApiClient',
          level: LogLevel.error,
        );
        expect(errorLogs.isNotEmpty, isTrue);
        expect(errorLogs.last.traceId, 'trace-site-not-found');
        expect(errorLogs.last.message, contains('API Error: 404 - Site bulunamadı'));
      }
    });

    test('ApiClient.decode fallbacks to x-request-id header when body has no trace_id', () {
      final response = http.Response.bytes(
        utf8.encode(json.encode({'error': 'Geçersiz parametre'})),
        400,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'x-request-id': 'trace-fallback-header-id',
        },
      );

      try {
        ApiClient.decode(response);
        fail('Expected ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 400);
        expect(e.traceId, 'trace-fallback-header-id');
      }
    });
  });
}
