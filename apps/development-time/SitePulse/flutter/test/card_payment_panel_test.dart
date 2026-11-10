@Tags(['finance', 'ui'])
library;

import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/payments/card_payment_panel.dart';

void main() {
  late http.Client previousTransport;

  setUp(() => previousTransport = ApiClient.transport);
  tearDown(() {
    ApiClient.transport = previousTransport;
    ApiClient.clearSession();
  });

  testWidgets('hosted card payment opens, polls, and reports capture', (
    tester,
  ) async {
    final requests = <http.Request>[];
    ApiClient.transport = MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'id': 'intent-17',
            'amount': '1600.75',
            'status': 'CREATED',
            'provider': 'SANDBOX',
            'checkout_url': 'https://payments.example.test/checkout/intent-17',
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response(
        jsonEncode({
          'id': 'intent-17',
          'amount': '1600.75',
          'status': 'CAPTURED',
          'provider': 'SANDBOX',
          'receipt_number': 'TAH-2026-000017',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    var capturedIntentId = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CardPaymentPanel(
            unitId: 'unit-14',
            amount: Decimal.parse('1600.75'),
            settlesDebt: true,
            onCaptured: (intent) => capturedIntentId = intent.id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.textContaining('3D Secure ile'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Ödeme sayfası yeni sekmede açıldı.'),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.textContaining('TAH-2026-000017'), findsOneWidget);
    expect(capturedIntentId, 'intent-17');
    expect(requests.map((request) => request.method), ['POST', 'GET']);
    expect(
      requests.first.url.path,
      '/api/v1/residents/unit-14/payment-intents',
    );
    expect(jsonDecode(requests.first.body)['amount'], '1600.75');
  });
}
