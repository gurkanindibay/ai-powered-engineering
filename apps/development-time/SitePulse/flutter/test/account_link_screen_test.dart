@Tags(['auth', 'residents'])
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/auth/account_link_screen.dart';

/// The page behind the single-use links (person module S2/S3/S5).
void main() {
  late http.Client previous;
  setUp(() => previous = ApiClient.transport);
  tearDown(() => ApiClient.transport = previous);

  Widget app(AccountLinkKind kind, String token, {VoidCallback? onDone}) => MaterialApp(
        home: AccountLinkScreen(kind: kind, token: token, onDone: onDone ?? () {}),
      );

  http.Response invalidToken() => http.Response(
        jsonEncode({
          'error': {
            'code': 'VALIDATION_ERROR',
            'message': 'This link is invalid or has expired. Ask your site manager for a new one.',
            'trace_id': 'req-9',
            'timestamp': '2026-11-10T00:00:00Z'
          }
        }),
        400,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  testWidgets('the person sets their own password and the token goes to the server once', (tester) async {
    final bodies = <Map<String, dynamic>>[];
    ApiClient.transport = MockClient((request) async {
      expect(request.url.path, '/api/v1/auth/activate');
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response('', 204);
    });
    await tester.pumpWidget(app(AccountLinkKind.activate, 'tok-123'));
    await tester.enterText(find.byKey(const Key('account_link_password')), 'Chosen-Pass-2026');
    await tester.enterText(find.byKey(const Key('account_link_password_repeat')), 'Chosen-Pass-2026');
    await tester.tap(find.byKey(const Key('account_link_submit')));
    await tester.pumpAndSettle();
    expect(bodies, [
      {'token': 'tok-123', 'new_password': 'Chosen-Pass-2026'}
    ]);
    expect(find.text('Hesabınız hazır'), findsOneWidget);
  });

  testWidgets('a short or mismatched password is caught before anything is sent', (tester) async {
    var calls = 0;
    ApiClient.transport = MockClient((_) async {
      calls++;
      return http.Response('', 204);
    });
    await tester.pumpWidget(app(AccountLinkKind.activate, 'tok-123'));
    await tester.enterText(find.byKey(const Key('account_link_password')), 'short');
    await tester.enterText(find.byKey(const Key('account_link_password_repeat')), 'different');
    await tester.tap(find.byKey(const Key('account_link_submit')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('Şifre en az 10 karakter olmalı.'), findsOneWidget);
    expect(find.text('Şifreler aynı değil.'), findsOneWidget);
  });

  testWidgets('an expired link says what to do next instead of showing the form again', (tester) async {
    ApiClient.transport = MockClient((_) async => invalidToken());
    await tester.pumpWidget(app(AccountLinkKind.activate, 'old'));
    await tester.enterText(find.byKey(const Key('account_link_password')), 'Chosen-Pass-2026');
    await tester.enterText(find.byKey(const Key('account_link_password_repeat')), 'Chosen-Pass-2026');
    await tester.tap(find.byKey(const Key('account_link_submit')));
    await tester.pumpAndSettle();
    expect(find.text('Bağlantı kullanılamıyor'), findsOneWidget);
    expect(find.textContaining('yeni bir bağlantı isteyin'), findsOneWidget);
    expect(find.byKey(const Key('account_link_submit')), findsNothing);
  });

  testWidgets('an email confirmation link is applied on open', (tester) async {
    ApiClient.transport = MockClient((request) async {
      expect(request.url.path, '/api/v1/auth/confirm-email');
      expect(jsonDecode(request.body), {'token': 'mail-1'});
      return http.Response('', 204);
    });
    await tester.pumpWidget(app(AccountLinkKind.confirmEmail, 'mail-1'));
    await tester.pumpAndSettle();
    expect(find.text('E-posta adresiniz güncellendi'), findsOneWidget);
  });

  testWidgets('a link without a token is refused without a request', (tester) async {
    var calls = 0;
    ApiClient.transport = MockClient((_) async {
      calls++;
      return http.Response('', 204);
    });
    await tester.pumpWidget(app(AccountLinkKind.activate, ''));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('Bağlantı kullanılamıyor'), findsOneWidget);
  });
}
