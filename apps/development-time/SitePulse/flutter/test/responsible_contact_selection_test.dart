import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/residents/responsible_contact_selection.dart';

void main() {
  late DashboardController controller;
  late HomeOwnerItem unit;
  late http.Client previousTransport;
  setUp(() {
    previousTransport = ApiClient.transport;
    controller = DashboardController(isTestMode: true);
    unit = HomeOwnerItem(
      unitId: '42',
      siteId: '9',
      block: 'A',
      unitNo: 2,
      floor: 1,
      ownerFullName: 'Owner Contact',
      email: 'owner@example.com',
      phone: '05321112233',
      tenantFullName: 'Tenant Contact',
      tenantEmail: 'tenant@example.com',
      occupancyStatus: 'TENANT_OCCUPIED',
      landShare: '1/24',
      monthlyDues: Decimal.parse('1400'),
      isResident: false,
      mustChangePassword: false,
      createdAt: DateTime(2026, 11, 13),
    );
    controller.homeOwners.add(unit);
    controller.isTestMode = false;
  });
  tearDown(() {
    ApiClient.transport.close();
    ApiClient.transport = previousTransport;
    controller.dispose();
  });

  testWidgets('failed contact save never reports success or changes the card', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    ApiClient.transport = MockClient((request) {
      expect(
        request.url.path,
        '/api/v1/site-admin/units/42/responsible-contact',
      );
      expect(jsonDecode(request.body), {
        'role': 'OWNER',
        'resident_name': 'Owner Contact',
      });
      return pending.future;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showResponsibleContactSelection(context, controller, unit),
              child: const Text('Choose'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('responsible_contact_OWNER_42')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('aktif sorumlu olarak belirlendi'),
      findsNothing,
    );
    pending.complete(http.Response('unavailable', 503));
    await tester.pumpAndSettle();
    expect(
      find.text('Sorumlu kişi kaydedilemedi. Lütfen tekrar deneyin.'),
      findsOneWidget,
    );
    expect(controller.homeOwners.single.primaryResponsibleRole, isNull);
    expect(controller.homeOwners.single.tenantFullName, 'Tenant Contact');
  });

  testWidgets('choosing the current contact explains the unchanged selection', (
    tester,
  ) async {
    var requests = 0;
    ApiClient.transport = MockClient((request) async {
      requests++;
      return http.Response('unexpected request', 500);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showResponsibleContactSelection(context, controller, unit),
              child: const Text('Choose'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('responsible_contact_TENANT_42')));
    await tester.pumpAndSettle();
    expect(find.text('Tenant Contact zaten aktif sorumlu.'), findsOneWidget);
    expect(requests, 0);
  });

  test(
    'successful save uses the returned contact without changing identity',
    () async {
      ApiClient.transport = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'primary_responsible_name': 'Owner Contact',
            'primary_responsible_role': 'OWNER',
            'primary_responsible_phone': '05321112233',
            'primary_responsible_email': 'owner@example.com',
          }),
          200,
        ),
      );
      expect(
        await controller.setPrimaryResponsibleResident(
          unitId: unit.unitId,
          residentName: unit.ownerFullName,
          role: 'OWNER',
        ),
        isTrue,
      );
      expect(
        controller.homeOwners.single.activeResponsibleResidentName,
        'Owner Contact',
      );
      expect(controller.homeOwners.single.primaryResponsibleRole, 'OWNER');
      expect(controller.homeOwners.single.tenantFullName, 'Tenant Contact');
    },
  );
}
