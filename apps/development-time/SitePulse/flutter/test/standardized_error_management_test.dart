import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/domain/services/payments_phase2_api.dart';
import 'package:sitepulse/l10n/app_strings.dart';
import 'package:sitepulse/ui/design_system/sp_error_state.dart';
import 'package:sitepulse/ui/design_system/sp_feedback.dart';

void main() {
  group('Standardized Error Management - Flutter Tests', () {
    test('ApiException correctly identifies error categories and details', () {
      final notFound = ApiException(
        message: 'Kayıt bulunamadı',
        statusCode: 404,
        code: 'RESOURCE_NOT_FOUND',
        traceId: 'req-123',
      );
      expect(notFound.isNotFound, isTrue);
      expect(notFound.isValidation, isFalse);
      expect(notFound.statusCode, 404);
      expect(notFound.code, 'RESOURCE_NOT_FOUND');
      expect(notFound.traceId, 'req-123');

      final validation = ApiException(
        message: 'Doğrulama hatası',
        statusCode: 400,
        code: 'VALIDATION_FAILED',
        details: {
          'field_errors': [
            {'field': 'sender_iban', 'message': 'Geçersiz IBAN'},
            {'field': 'amount', 'message': 'Tutar sıfırdan büyük olmalıdır'},
          ],
        },
      );
      expect(validation.isValidation, isTrue);
      expect(validation.isConflict, isFalse);
      expect(validation.fieldErrors('sender_iban'), ['Geçersiz IBAN']);
      expect(validation.fieldErrors('amount'), [
        'Tutar sıfırdan büyük olmalıdır',
      ]);
      expect(validation.fieldErrors('unknown'), isEmpty);
    });

    test('ApiClient.decode successfully parses 2xx JSON payload', () {
      final response = http.Response(
        json.encode({'status': 'ok', 'id': 42}),
        200,
      );
      final decoded = ApiClient.decode(response);
      expect(decoded, isA<Map<String, dynamic>>());
      expect(decoded['status'], 'ok');
      expect(decoded['id'], 42);
    });

    test(
      'ApiClient.decode throws ApiException for standardized error envelope',
      () {
        final envelope = {
          'error': {
            'code': 'CONFLICT',
            'message': 'Dönem aidatı zaten tahakkuk ettirilmiş.',
            'trace_id': 'req-987',
            'timestamp': '2026-11-08T18:00:00Z',
            'details': {'period_id': 105},
          },
        };
        final response = http.Response(
          json.encode(envelope),
          409,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );

        try {
          ApiClient.decode(response);
          fail('Expected ApiException to be thrown');
        } on ApiException catch (e) {
          expect(e.statusCode, 409);
          expect(e.isConflict, isTrue);
          expect(e.code, 'CONFLICT');
          expect(e.message, 'Dönem aidatı zaten tahakkuk ettirilmiş.');
          expect(e.traceId, 'req-987');
          expect(e.details?['period_id'], 105);
        }
      },
    );

    test('ApiClient.decode gracefully handles legacy or plain text error responses', () {
      final plainResponse = http.Response('Sender IBAN cannot be empty.', 400);

      try {
        ApiClient.decode(plainResponse);
        fail('Expected ApiException to be thrown');
      } on ApiException catch (e) {
        expect(e.statusCode, 400);
        expect(e.isValidation, isTrue);
        expect(e.message, 'Sender IBAN cannot be empty.');
      }
    });

    test('PaymentsPhase2Api backwards compatibility with ApiFailure', () {
      final failure = ApiFailure(
        404,
        'Belge bulunamadı',
        code: 'NOT_FOUND',
        traceId: 'req-444',
      );
      expect(failure, isA<ApiException>());
      expect(failure, isA<AppException>());
      expect(failure.status, 404);
      expect(failure.statusCode, 404);
      expect(failure.code, 'NOT_FOUND');
    });

    test(
      'AppStrings.localizedErrorMessage translates standard codes to Turkish',
      () {
        expect(
          AppStrings.localizedErrorMessage('AUTHENTICATION_REQUIRED'),
          contains('Oturum açmanız gerekiyor'),
        );
        expect(
          AppStrings.localizedErrorMessage('PERMISSION_DENIED'),
          contains('yetkiniz bulunmuyor'),
        );
        expect(
          AppStrings.localizedErrorMessage('RESOURCE_NOT_FOUND'),
          contains('bulunamadı'),
        );
        expect(
          AppStrings.localizedErrorMessage('NETWORK_ERROR'),
          contains('İnternet bağlantısı kurulamadı'),
        );
        expect(
          AppStrings.localizedErrorMessage(
            'CUSTOM_UNKNOWN_CODE',
            fallback: 'Özel hata',
          ),
          'Özel hata',
        );
      },
    );

    testWidgets('SpErrorState displays message and calls retry callback', (
      tester,
    ) async {
      var retryCalled = false;
      final exception = ApiException(
        message: 'İşlem gerçekleştirilemedi',
        statusCode: 500,
        code: 'INTERNAL_SERVER_ERROR',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpErrorState(
              error: exception,
              onRetry: () => retryCalled = true,
            ),
          ),
        ),
      );

      expect(find.text('Bir Sorun Oluştu'), findsOneWidget);
      expect(
        find.textContaining('Sunucuda bir hata meydana geldi'),
        findsOneWidget,
      );
      expect(find.text('Tekrar Dene'), findsOneWidget);

      await tester.tap(find.text('Tekrar Dene'));
      await tester.pump();
      expect(retryCalled, isTrue);
    });

    testWidgets('SpToast.exception displays translated error message', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  SpToast.exception(context, const NetworkException());
                },
                child: const Text('Tıkla'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Tıkla'));
      await tester.pump(); // Start animation
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.textContaining('İnternet bağlantısı kurulamadı'),
        findsOneWidget,
      );
    });
  });
}
