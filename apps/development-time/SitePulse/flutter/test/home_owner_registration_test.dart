@Tags(['residents'])
library;

import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/residents/activation_status.dart';

/// Person module U1/S3/S4: against a real server, registration is either confirmed
/// by the server or reported as failed. Nothing is invented locally and no
/// password ever reaches the manager's screen.
void main() {
  late http.Client previous;
  late DashboardController controller;

  setUp(() {
    previous = ApiClient.transport;
    ApiClient.setSession({'access_token': 'manager', 'refresh_token': 'refresh'});
    controller = DashboardController(isTestMode: false);
  });

  tearDown(() {
    ApiClient.clearSession();
    ApiClient.transport = previous;
  });

  Future<void> register() => controller.registerHomeOwner(
        block: 'C Blok',
        unitNo: 31,
        ownerName: 'Ece Yalın',
        email: 'ece.yalin@example.com',
        phone: '0532 111 22 33',
        duesAmount: Decimal.parse('1400.00'),
      );

  http.Response envelope(int status, String code, String message) => http.Response(
        jsonEncode({
          'error': {'code': code, 'message': message, 'trace_id': 'req-1', 'timestamp': '2026-11-10T00:00:00Z'}
        }),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  test('a refused registration changes nothing locally and shows the server reason', () async {
    ApiClient.transport = MockClient((request) async {
      if (request.method == 'POST') {
        return envelope(409, 'CONFLICT', 'This email address cannot be used for a new account. Check it or contact support.');
      }
      return http.Response('[]', 200);
    });
    final before = controller.flatsList.length;
    await register();
    expect(controller.flatsList.length, before);
    expect(controller.homeOwners.any((h) => h.ownerFullName == 'Ece Yalın'), isFalse);
    expect(controller.provisionedHomeOwner, isNull);
    expect(controller.lastHomeOwnerError, contains('cannot be used'));
    expect(controller.isRegisteringHomeOwner, isFalse);
  });

  test('an unreachable server is reported and no record or password is invented', () async {
    ApiClient.transport = MockClient((_) async => throw http.ClientException('offline'));
    final before = controller.flatsList.length;
    await register();
    expect(controller.flatsList.length, before);
    expect(controller.provisionedHomeOwner, isNull);
    expect(controller.lastHomeOwnerError, contains('Kayıt yapılmadı'));
  });

  test('a server error is shown generically with its reference, not raw text', () async {
    ApiClient.transport = MockClient((request) async =>
        request.method == 'POST' ? envelope(500, 'INTERNAL_ERROR', 'db error: relation x') : http.Response('[]', 200));
    await register();
    expect(controller.lastHomeOwnerError, isNot(contains('db error')));
    expect(controller.lastHomeOwnerError, contains('req-1'));
  });

  test('a confirmed registration reports the activation link, never a password', () async {
    ApiClient.transport = MockClient((request) async {
      if (request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'unit_id': '77', 'site_id': '1', 'block': 'C', 'unit_no': 31, 'floor': 8,
            'owner_full_name': 'Ece Yalın', 'email': 'ece.yalin@example.com', 'phone': '0532 111 22 33',
            'land_share': '1/24', 'monthly_dues': '1400.00', 'is_resident': true,
            'activation': {'status': 'SENT', 'expires_at': '2026-11-13T00:00:00Z'},
            'must_change_password': true, 'created_at': '2026-11-10T00:00:00Z',
          }),
          201,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('[]', 200);
    });
    await register();
    final created = controller.provisionedHomeOwner;
    expect(created, isNotNull);
    expect(created!.activationStatus, 'SENT');
    expect(controller.lastHomeOwnerError, isNull);
    expect(activationStatusMessage(created.activationStatus, created.email), contains('etkinleştirme bağlantısı'));
  });
}
