@Tags(['residents'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/errors/app_exception.dart';
import 'package:sitepulse/domain/services/person_directory_api.dart';
import 'package:sitepulse/ui/residents/people_directory_page.dart';
import 'package:sitepulse/ui/residents/person_profile_page.dart';
import 'package:sitepulse/ui/theme/app_theme.dart';

PersonSummary _person(
  int id,
  String name, {
  PersonLogin login = PersonLogin.active,
  String role = 'HOME_OWNER',
  int ownedUnits = 1,
  int occupiedUnits = 0,
}) =>
    PersonSummary(
      personId: id,
      fullName: name,
      email: 'p$id@example.com',
      phone: '0532 000 00 0$id',
      role: role,
      ownedUnits: ownedUnits,
      occupiedUnits: occupiedUnits,
      login: login,
    );

class _FakeApi extends PersonDirectoryApi {
  final List<Map<String, String?>> calls = [];
  int resent = 0;
  int exports = 0;
  bool stepUpNeeded = false;

  @override
  Future<DirectoryPage> directory({String query = '', String? role, String? login, int page = 1, int pageSize = 25}) async {
    calls.add({'q': query, 'role': role, 'login': login, 'page': '$page', 'pageSize': '$pageSize'});
    final all = [for (var i = 1; i <= 30; i++) _person(i, 'Kişi $i', login: i.isEven ? PersonLogin.pending : PersonLogin.active)];
    final filtered = all.where((p) => login == null || p.login.code == login).toList();
    final slice = filtered.skip((page - 1) * pageSize).take(pageSize).toList();
    return DirectoryPage(items: slice, total: filtered.length, page: page, pageSize: pageSize);
  }

  @override
  Future<PersonProfile> profile(int personId) async => PersonProfile(
        person: _person(personId, 'Kişi $personId', login: PersonLogin.pending),
        units: [
          PersonUnit(unitId: '14', block: 'A Blok', unitNo: 14, relation: 'OWNER', startDate: DateTime(2025, 1, 1), active: true),
          PersonUnit(unitId: '9', block: 'B Blok', unitNo: 9, relation: 'TENANT', startDate: DateTime(2022, 3, 1), endDate: DateTime(2024, 12, 31), active: false),
        ],
      );

  @override
  Future<String?> resendActivation(String unitId, {bool tenant = false}) async {
    resent++;
    return 'SENT';
  }

  @override
  Future<List<int>> exportCsv({String query = '', String? role, String? login}) async {
    exports++;
    if (stepUpNeeded) {
      throw const ApiException(message: 'Step up', statusCode: 403, code: 'STEP_UP_REQUIRED');
    }
    return [1, 2, 3];
  }
}

Widget _host(Widget child) => MaterialApp(theme: AppTheme.light(), home: child);

void main() {
  // covers: SC-12-04-01
  testWidgets('pages through the directory and filters people waiting for activation', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_host(PeopleDirectoryPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('30 kişi'), findsOneWidget);
    expect(find.text('Kişi 1'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('Sonraki sayfa'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sonraki sayfa'));
    await tester.pumpAndSettle();
    expect(api.calls.last['page'], '2');
    expect(api.calls.last['pageSize'], '25');
    expect(find.text('Kişi 26'), findsOneWidget);

    await tester.ensureVisible(find.text('Etkinleştirme bekleyen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Etkinleştirme bekleyen'));
    await tester.pumpAndSettle();
    expect(api.calls.last['login'], 'PENDING');
    expect(api.calls.last['page'], '1');
    expect(find.text('15 kişi'), findsOneWidget);
  });

  testWidgets('search waits for typing to pause before asking the server', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_host(PeopleDirectoryPage(api: api)));
    await tester.pumpAndSettle();
    final before = api.calls.length;
    await tester.enterText(find.byKey(const Key('people_search_input')), 'Ay');
    await tester.enterText(find.byKey(const Key('people_search_input')), 'Ayşe');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(api.calls.length, before + 1);
    expect(api.calls.last['q'], 'Ayşe');
  });

  // covers: SC-12-04-02
  testWidgets('restores search query and directory page position across restoration', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(
      restorationScopeId: 'people_test_scope',
      theme: AppTheme.light(),
      home: PeopleDirectoryPage(api: api),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('people_search_input')), 'Kişi');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('people_search_input')), findsOneWidget);
    expect(find.text('Kişi'), findsOneWidget);
  });

  testWidgets('export asks for the password when the server requires it', (tester) async {
    final api = _FakeApi()..stepUpNeeded = true;
    await tester.pumpWidget(_host(PeopleDirectoryPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('people_export_btn')));
    await tester.pumpAndSettle();
    expect(find.text('Şifrenizi doğrulayın'), findsOneWidget);
  });

  testWidgets('profile shows the unit timeline and resends a pending activation link', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_host(PersonProfilePage(personId: 4, api: api)));
    await tester.pumpAndSettle();
    expect(find.text('A Blok • Daire 14'), findsOneWidget);
    expect(find.text('01.01.2025 – devam ediyor'), findsOneWidget);
    expect(find.text('01.03.2022 – 31.12.2024'), findsOneWidget);
    await tester.tap(find.byKey(const Key('person_resend_activation_btn')));
    await tester.pumpAndSettle();
    expect(api.resent, 1);
  });

  testWidgets('shows empty state guidance with action when no residents or owners exist', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _StaticApi([
      _person(1, 'Ali Müdür', role: 'SITE_MANAGER', ownedUnits: 0, occupiedUnits: 0),
    ]);
    await tester.pumpWidget(_host(PeopleDirectoryPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('Henüz kayıtlı kat maliki veya sakin bulunmuyor'), findsOneWidget);
    expect(find.byKey(const Key('people_guidance_import_btn')), findsOneWidget);
    expect(find.text('Ali Müdür'), findsOneWidget);
  });

  testWidgets('shows empty state when directory has zero people', (tester) async {
    final api = _StaticApi([]);
    await tester.pumpWidget(_host(PeopleDirectoryPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('Henüz kayıtlı kat maliki veya sakin bulunmuyor'), findsOneWidget);
    expect(find.byKey(const Key('people_empty_import_btn')), findsOneWidget);
  });
}

class _StaticApi extends PersonDirectoryApi {
  final List<PersonSummary> items;
  _StaticApi(this.items);

  @override
  Future<DirectoryPage> directory({String query = '', String? role, String? login, int page = 1, int pageSize = 25}) async {
    return DirectoryPage(items: items, total: items.length, page: page, pageSize: pageSize);
  }
}
