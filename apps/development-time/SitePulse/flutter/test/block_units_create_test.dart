@Tags(['residents', 'ui'])
library;

import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/dashboard/dashboard_screen.dart';
import 'package:sitepulse/ui/residents/block_units_create_page.dart';

import 'test_fixtures.dart';

Widget _host(DashboardController controller) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          key: const Key('open_block_form'),
          onPressed: () => showBlockUnitsCreatePage(context, controller),
          child: const Text('Blok Ekle'),
        ),
      ),
    ),
  );
}

Future<void> _openForm(
  WidgetTester tester,
  DashboardController controller,
) async {
  await tester.pumpWidget(_host(controller));
  await tester.tap(find.byKey(const Key('open_block_form')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key(BlockUnitsCreatePage.nameId)), findsOneWidget);
}

Future<void> _fillForm(
  WidgetTester tester, {
  String name = 'A Blok',
  String start = '1',
  String count = '7',
  String floors = '7',
  String? houseType,
  String? dues,
}) async {
  await tester.enterText(
    find.byKey(const Key(BlockUnitsCreatePage.nameId)),
    name,
  );
  await tester.enterText(
    find.byKey(const Key(BlockUnitsCreatePage.startUnitId)),
    start,
  );
  await tester.enterText(
    find.byKey(const Key(BlockUnitsCreatePage.unitCountId)),
    count,
  );
  await tester.enterText(
    find.byKey(const Key(BlockUnitsCreatePage.totalFloorsId)),
    floors,
  );
  if (houseType != null) {
    await tester.enterText(
      find.byKey(const Key(BlockUnitsCreatePage.houseTypeId)),
      houseType,
    );
  }
  if (dues != null) {
    await tester.enterText(
      find.byKey(const Key(BlockUnitsCreatePage.monthlyDuesId)),
      dues,
    );
  }
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key(BlockUnitsCreatePage.submitId)));
  await tester.pump();
  await tester.pumpAndSettle();
}

void _withManagedSite(DashboardController controller, {String id = '42'}) {
  controller.setManagedSitesForTesting(
    TenantSiteItem(
      id: id,
      name: 'Test Sitesi',
      city: 'İstanbul',
      address: '',
      status: 'ACTIVE',
      planType: 'STANDARD',
      totalUnits: 0,
      monthlyCollectionVolume: Decimal.zero,
      adminName: 'Test Manager',
      adminEmail: 'manager@sitepulse.test',
      adminPhone: '',
    ),
    const [],
  );
}

void _seedExistingTariff(DashboardController controller) {
  controller.setHouseTypesForTesting([
    HouseTypeTariff(
      id: '2',
      siteId: 'site-1',
      typeName: '2+1',
      duesAmount: Decimal.parse('1400.00'),
      description: '2 Oda 1 Salon',
    ),
  ]);
}

Map<String, dynamic> _auth() => {
  'access_token': 'access',
  'refresh_token': 'refresh',
  'token_type': 'Bearer',
  'expires_in': 900,
  'user': {
    'id': '7',
    'full_name': 'Structure Manager',
    'email': 'manager@sitepulse.test',
    'phone': '',
    'role': 'SITE_MANAGER',
    'site_id': '42',
    'unit_id': '',
    'auth_provider': 'LOCAL',
    'must_change_password': false,
    'permissions': const <String>[],
  },
};

http.Response _json(Object? data, [int status = 200]) => http.Response(
  data == null ? '' : jsonEncode(data),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Block and units creation from the manager screens (#285)', () {
    late http.Client previous;
    setUp(() {
      previous = ApiClient.transport;
      ApiClient.clearSession();
    });
    tearDown(() {
      ApiClient.clearSession();
      ApiClient.transport = previous;
    });

    testWidgets(
      'the residents screen offers btn_add_block and opens the form',
      (tester) async {
        final controller = DashboardController()
          ..loadZeroDataFixtures(role: UserRole.siteManager);
        addTearDown(controller.dispose);
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: DashboardScreen(controller: controller, selectedTab: 2),
          ),
        );
        await tester.pumpAndSettle();

        final addBlock = find.byKey(const Key('btn_add_block'));
        expect(addBlock, findsOneWidget);
        await tester.ensureVisible(addBlock);
        await tester.tap(addBlock);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key(BlockUnitsCreatePage.nameId)),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key(BlockUnitsCreatePage.submitId)),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'submitting without a block name or unit count shows field errors',
      (tester) async {
        final controller = DashboardController()
          ..loadZeroDataFixtures(role: UserRole.siteManager);
        addTearDown(controller.dispose);
        await _openForm(tester, controller);

        await _fillForm(tester, name: '', count: '');
        await _submit(tester);

        expect(find.text('Blok adı girin.'), findsOneWidget);
        expect(find.text('Daire sayısı girin.'), findsOneWidget);
        expect(
          find.byKey(const Key(BlockUnitsCreatePage.nameId)),
          findsOneWidget,
        );
        expect(controller.homeOwners, isEmpty);
      },
    );

    testWidgets('a tariff without a house type is refused before any call', (
      tester,
    ) async {
      final controller = DashboardController()
        ..loadZeroDataFixtures(role: UserRole.siteManager);
      addTearDown(controller.dispose);
      await _openForm(tester, controller);

      await _fillForm(tester, dues: '1.500,00');
      await _submit(tester);

      expect(
        find.text('Aidat tanımlamak için konut tipi girin.'),
        findsOneWidget,
      );
      expect(controller.homeOwners, isEmpty);
    });

    testWidgets(
      'an existing house type with a different tariff is refused without repricing',
      (tester) async {
        final controller = DashboardController()
          ..loadZeroDataFixtures(role: UserRole.siteManager);
        addTearDown(controller.dispose);
        _seedExistingTariff(controller);
        await _openForm(tester, controller);

        await _fillForm(tester, houseType: '2+1', dues: '1.600,00');
        await _submit(tester);

        expect(find.textContaining("'2+1' konut tipi zaten"), findsOneWidget);
        expect(
          find.byKey(const Key(BlockUnitsCreatePage.nameId)),
          findsOneWidget,
        );
        expect(controller.homeOwners, isEmpty);
        expect(controller.houseTypes, hasLength(1));
        expect(
          controller.houseTypes.single.duesAmount,
          Decimal.parse('1400.00'),
        );
      },
    );

    testWidgets(
      'an existing house type at the same tariff is reused, not rewritten',
      (tester) async {
        final controller = DashboardController()
          ..loadZeroDataFixtures(role: UserRole.siteManager);
        addTearDown(controller.dispose);
        _seedExistingTariff(controller);
        await _openForm(tester, controller);

        await _fillForm(tester, houseType: '2+1', dues: '1.400,00');
        await _submit(tester);

        expect(
          find.byKey(const Key(BlockUnitsCreatePage.nameId)),
          findsNothing,
        );
        expect(controller.homeOwners, hasLength(7));
        expect(
          controller.homeOwners.every((unit) => unit.houseType == '2+1'),
          isTrue,
        );
        expect(
          controller.homeOwners.every(
            (unit) => unit.monthlyDues == Decimal.parse('1400.00'),
          ),
          isTrue,
        );
        expect(controller.houseTypes, hasLength(1));
        expect(
          controller.houseTypes.single.duesAmount,
          Decimal.parse('1400.00'),
        );
      },
    );

    testWidgets(
      'a successful create adds the block, seven units and the tariff',
      (tester) async {
        final controller = DashboardController()
          ..loadZeroDataFixtures(role: UserRole.siteManager);
        addTearDown(controller.dispose);
        await _openForm(tester, controller);

        await _fillForm(tester, houseType: '2+1', dues: '1.500,00');
        await _submit(tester);

        expect(
          find.byKey(const Key(BlockUnitsCreatePage.nameId)),
          findsNothing,
        );
        expect(controller.blocks, contains('A Blok'));
        expect(controller.homeOwners, hasLength(7));
        final units =
            controller.homeOwners
                .where((unit) => unit.block == 'A Blok')
                .toList()
              ..sort((a, b) => a.unitNo.compareTo(b.unitNo));
        expect(units.map((unit) => unit.unitNo), [1, 2, 3, 4, 5, 6, 7]);
        expect(units.every((unit) => unit.isVacant), isTrue);
        expect(units.every((unit) => unit.houseType == '2+1'), isTrue);
        expect(
          units.every((unit) => unit.monthlyDues == Decimal.parse('1500.00')),
          isTrue,
        );
        expect(
          controller.houseTypes.any(
            (type) =>
                type.typeName == '2+1' &&
                type.duesAmount == Decimal.parse('1500.00'),
          ),
          isTrue,
        );
      },
    );

    test(
      'the command posts block, tariff and units, then reloads the directory',
      () async {
        final calls = <http.Request>[];
        ApiClient.transport = MockClient((request) async {
          calls.add(request);
          final path = request.url.path;
          if (path == '/api/v1/auth/login') {
            return _json(_auth());
          }
          if (request.method == 'POST' && path == '/api/v1/site-admin/blocks') {
            return _json({
              'id': '5',
              'site_id': '42',
              'block_name': 'A Blok',
              'total_floors': 7,
            }, 201);
          }
          if (request.method == 'POST' &&
              path == '/api/v1/site-admin/house-types') {
            return _json({
              'id': '9',
              'site_id': '42',
              'type_name': '2+1',
              'dues_amount': '1500.00',
              'description': 'Blok oluşturulurken tanımlandı',
            }, 201);
          }
          if (request.method == 'POST' && path == '/api/v1/site-admin/units') {
            return _json(const <Object>[], 201);
          }
          if (path.endsWith('/overview') || path.endsWith('/dashboard')) {
            return _json(const <String, Object>{});
          }
          return _json(const <Object>[]);
        });

        final controller = DashboardController();
        addTearDown(controller.dispose);
        expect(
          await controller.loginWithPassword(
            'manager@sitepulse.test',
            'Permanent-Pass-1',
          ),
          isTrue,
        );
        calls.clear();

        final error = await controller.createBlockWithUnits(
          blockName: 'A Blok',
          startUnit: 1,
          unitCount: 7,
          totalFloors: 7,
          houseType: '2+1',
          monthlyDues: Decimal.parse('1500.00'),
          siteId: '42',
        );

        expect(error, isNull);
        final posts = calls.where((call) => call.method == 'POST').toList();
        expect(posts.map((call) => call.url.path), [
          '/api/v1/site-admin/blocks',
          '/api/v1/site-admin/house-types',
          '/api/v1/site-admin/units',
        ]);
        expect(
          posts.every((call) => call.url.queryParameters['site_id'] == '42'),
          isTrue,
        );

        expect(jsonDecode(posts[0].body), {
          'block_name': 'A Blok',
          'total_floors': 7,
        });
        expect(jsonDecode(posts[1].body), {
          'type_name': '2+1',
          'dues_amount': '1500',
          'description': 'Blok oluşturulurken tanımlandı',
        });
        expect(jsonDecode(posts[2].body), {
          'block_name': 'A Blok',
          'start_unit': 1,
          'end_unit': 7,
          'house_type': '2+1',
        });

        final gets = calls
            .where((call) => call.method == 'GET')
            .map((call) => call.url.path)
            .toList();
        expect(gets, contains('/api/v1/site-admin/blocks'));
        expect(gets, contains('/api/v1/site-admin/house-types'));
        expect(gets, contains('/api/v1/site-admin/home-owners'));
      },
    );

    test('the command sends no tariff when none was entered', () async {
      final calls = <http.Request>[];
      ApiClient.transport = MockClient((request) async {
        calls.add(request);
        final path = request.url.path;
        if (request.method == 'POST' && path == '/api/v1/site-admin/blocks') {
          return _json(const <String, Object>{}, 201);
        }
        if (request.method == 'POST' && path == '/api/v1/site-admin/units') {
          return _json(const <Object>[], 201);
        }
        return _json(const <Object>[]);
      });

      final controller = DashboardController();
      addTearDown(controller.dispose);
      final error = await controller.createBlockWithUnits(
        blockName: 'B Blok',
        startUnit: 3,
        unitCount: 2,
        siteId: '42',
      );

      expect(error, isNull);
      final paths = calls.map((call) => call.url.path).toList();
      expect(paths, isNot(contains('/api/v1/site-admin/house-types')));
      final units = calls.firstWhere(
        (call) => call.url.path == '/api/v1/site-admin/units',
      );
      expect(jsonDecode(units.body), {
        'block_name': 'B Blok',
        'start_unit': 3,
        'end_unit': 4,
      });
    });

    test(
      'an existing tariff at the same amount is reused without a tariff write',
      () async {
        final calls = <http.Request>[];
        ApiClient.transport = MockClient((request) async {
          calls.add(request);
          final path = request.url.path;
          if (path == '/api/v1/auth/login') {
            return _json(_auth());
          }
          if (request.method == 'GET' &&
              path == '/api/v1/site-admin/house-types') {
            return _json([
              {
                'id': '2',
                'site_id': '42',
                'type_name': 'Flat',
                'dues_amount': '1400.00',
                'description': '2 Oda 1 Salon',
              },
            ]);
          }
          if (request.method == 'POST' && path == '/api/v1/site-admin/blocks') {
            return _json(const <String, Object>{}, 201);
          }
          if (request.method == 'POST' && path == '/api/v1/site-admin/units') {
            return _json(const <Object>[], 201);
          }
          if (path.endsWith('/overview')) {
            return _json(const <String, Object>{});
          }
          return _json(const <Object>[]);
        });

        final controller = DashboardController();
        addTearDown(controller.dispose);
        expect(
          await controller.loginWithPassword(
            'manager@sitepulse.test',
            'Permanent-Pass-1',
          ),
          isTrue,
        );
        calls.clear();

        final error = await controller.createBlockWithUnits(
          blockName: 'A Blok',
          startUnit: 1,
          unitCount: 7,
          houseType: 'flat',
          monthlyDues: Decimal.parse('1400.00'),
          siteId: '42',
        );

        expect(error, isNull);
        expect(
          calls
              .where((call) => call.method == 'POST')
              .map((call) => call.url.path),
          ['/api/v1/site-admin/blocks', '/api/v1/site-admin/units'],
        );
        final units = calls.firstWhere(
          (call) =>
              call.method == 'POST' &&
              call.url.path == '/api/v1/site-admin/units',
        );
        // The reused type keeps its registered spelling, which is what the
        // unit's house_type_id must point at.
        expect(jsonDecode(units.body)['house_type'], 'Flat');
        expect(
          controller.houseTypes.single.duesAmount,
          Decimal.parse('1400.00'),
        );
      },
    );

    test(
      'an existing tariff at a different amount is refused before any write',
      () async {
        final calls = <http.Request>[];
        ApiClient.transport = MockClient((request) async {
          calls.add(request);
          final path = request.url.path;
          if (path == '/api/v1/auth/login') {
            return _json(_auth());
          }
          if (request.method == 'GET' &&
              path == '/api/v1/site-admin/house-types') {
            return _json([
              {
                'id': '2',
                'site_id': '42',
                'type_name': '2+1',
                'dues_amount': '1400.00',
                'description': '2 Oda 1 Salon',
              },
            ]);
          }
          if (path.endsWith('/overview')) {
            return _json(const <String, Object>{});
          }
          return _json(const <Object>[]);
        });

        final controller = DashboardController();
        addTearDown(controller.dispose);
        expect(
          await controller.loginWithPassword(
            'manager@sitepulse.test',
            'Permanent-Pass-1',
          ),
          isTrue,
        );
        calls.clear();

        final error = await controller.createBlockWithUnits(
          blockName: 'A Blok',
          startUnit: 1,
          unitCount: 7,
          houseType: '2+1',
          monthlyDues: Decimal.parse('1600.00'),
          siteId: '42',
        );

        expect(error, contains("'2+1' konut tipi zaten"));
        expect(error, contains('₺1.400,00'));
        expect(calls.where((call) => call.method == 'POST'), isEmpty);
        expect(
          controller.houseTypes.single.duesAmount,
          Decimal.parse('1400.00'),
        );
      },
    );

    test(
      'refuses when no managed site is loaded instead of posting to site 1',
      () async {
        final calls = <http.Request>[];
        ApiClient.transport = MockClient((request) async {
          calls.add(request);
          return _json(const <Object>[]);
        });

        final controller = DashboardController();
        addTearDown(controller.dispose);
        final error = await controller.createBlockWithUnits(
          blockName: 'A Blok',
          startUnit: 1,
          unitCount: 7,
        );

        expect(error, contains('Yönetilen site bilgisi yüklenemedi'));
        expect(calls, isEmpty);
      },
    );

    testWidgets(
      'a refused create keeps the form open and shows the server reason',
      (tester) async {
        ApiClient.transport = MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST' && path == '/api/v1/site-admin/blocks') {
            return _json(const <String, Object>{}, 201);
          }
          if (request.method == 'POST' &&
              path == '/api/v1/site-admin/house-types') {
            return _json(const <String, Object>{}, 201);
          }
          if (request.method == 'POST' && path == '/api/v1/site-admin/units') {
            return _json({
              'error': {
                'code': 'CONFLICT',
                'message': 'Units already exist in block A Blok: [1, 2]',
              },
            }, 409);
          }
          return _json(const <Object>[]);
        });

        final controller = DashboardController();
        addTearDown(controller.dispose);
        _withManagedSite(controller);
        await _openForm(tester, controller);

        await _fillForm(tester, houseType: '2+1', dues: '1.500,00');
        await _submit(tester);

        expect(
          find.byKey(const Key(BlockUnitsCreatePage.nameId)),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key(BlockUnitsCreatePage.errorId)),
          findsOneWidget,
        );
        expect(
          find.text('Bu işlem mevcut kayıtla veya durumla çakışıyor.'),
          findsOneWidget,
        );
        expect(controller.homeOwners, isEmpty);
      },
    );
  });
}
