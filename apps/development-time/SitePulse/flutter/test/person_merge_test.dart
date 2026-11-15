@Tags(['residents'])
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/errors/app_exception.dart';
import 'package:sitepulse/domain/models/person_ref.dart';
import 'package:sitepulse/domain/repositories/person_repository.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/domain/services/person_directory_api.dart';
import 'package:sitepulse/ui/residents/person_profile_page.dart';
import 'package:sitepulse/ui/theme/app_theme.dart';

PersonSummary _person(int id, String name, {int version = 1}) => PersonSummary(
      personId: id,
      fullName: name,
      email: 'p$id@example.com',
      phone: '0532 000 00 0$id',
      role: 'HOME_OWNER',
      ownedUnits: 1,
      occupiedUnits: 0,
      login: PersonLogin.none,
      version: version,
    );

class _MergeApi extends PersonDirectoryApi {
  final List<(int, int, int?)> merges = [];
  bool stepUpNeeded = true;

  @override
  Future<PersonProfile> profile(int personId) async => PersonProfile(
        person: _person(personId, personId == 7 ? 'Kemal Evsahibi' : 'Kemal Ev Sahibi', version: personId == 7 ? 1 : 4),
        units: const [],
        record: const PersonRecord(preferences: ContactPreferences(), consents: []),
      );

  @override
  Future<int?> mergePerson(int sourcePersonId, int targetPersonId, {int? expectedTargetVersion}) async {
    if (stepUpNeeded) {
      throw const ApiException(message: 'Step up', statusCode: 403, code: 'STEP_UP_REQUIRED');
    }
    merges.add((sourcePersonId, targetPersonId, expectedTargetVersion));
    return 5;
  }
}

class _PickerRepository implements PersonRepository {
  final List<PersonSummary> people;
  _PickerRepository(this.people);

  @override
  Future<PersonSearchPage> search({String query = '', String? context, String? unitId, int page = 1, int pageSize = 50}) async =>
      PersonSearchPage(items: [for (final p in people) PersonSearchResult(person: p)], total: people.length, page: 1, pageSize: pageSize);
  @override
  Future<List<DuplicateCandidate>> findDuplicates({required String fullName, String? email, String? phone, int? excludePersonId}) async => const [];
  @override
  Future<PersonSummary> create({required String fullName, String? phone, String? email, bool confirmDistinct = false}) async => people.first;
  @override
  Future<PersonSummary> update(int personId, {required int version, required String fullName, String? phone, String? email}) async => people.first;
  @override
  Future<PersonSummary?> getById(int personId) async => people.firstWhere((p) => p.personId == personId);
  @override
  PersonRef referenceFor(PersonSearchResult result) => PersonRef.existing(result.person.personId);
}

Widget _host(Widget child) => MaterialApp(theme: AppTheme.light(), home: child);

// covers: SC-12-08-01
// covers: SC-12-08-02
void main() {
  late http.Client previousTransport;
  setUp(() {
    previousTransport = ApiClient.transport;
    ApiClient.transport = MockClient((request) async {
      if (request.url.path.endsWith('/auth/step-up')) return http.Response('{}', 200, headers: {'content-type': 'application/json'});
      return http.Response('[]', 200, headers: {'content-type': 'application/json'});
    });
  });
  tearDown(() => ApiClient.transport = previousTransport);

  Future<void> startMerge(WidgetTester tester, _MergeApi api, int pickedId) async {
    final repository = _PickerRepository([_person(7, 'Kemal Evsahibi'), _person(9, 'Kemal Ev Sahibi', version: 4)]);
    await tester.pumpWidget(_host(PersonProfilePage(personId: 7, api: api, repository: repository)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('person_merge_btn')));
    await tester.tap(find.byKey(const Key('person_merge_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('sp_person_result_$pickedId')));
    await tester.pumpAndSettle();
  }

  testWidgets('merge asks for a password check and then sends the target version', (tester) async {
    final api = _MergeApi();
    await startMerge(tester, api, 9);
    await tester.tap(find.byKey(const Key('person_merge_confirm_btn')));
    await tester.pumpAndSettle();
    expect(api.merges, isEmpty);
    expect(find.text('Şifrenizi doğrulayın'), findsOneWidget);

    api.stepUpNeeded = false;
    await tester.enterText(find.byKey(const Key('step_up_password')), 'secret');
    await tester.tap(find.byKey(const Key('btn_step_up_verify')));
    await tester.pumpAndSettle();

    expect(api.merges, [(7, 9, 4)]);
  });

  testWidgets('a card cannot be merged into itself', (tester) async {
    final api = _MergeApi();
    await startMerge(tester, api, 7);
    expect(api.merges, isEmpty);
    expect(find.text('Bir kişi kendisiyle birleştirilemez.'), findsOneWidget);
    expect(find.byKey(const Key('person_merge_confirm_btn')), findsNothing);
  });

  test('mergePerson posts the target and the expected version', () async {
    late http.Request sent;
    ApiClient.setSession({'access_token': 'manager', 'refresh_token': 'refresh'});
    addTearDown(ApiClient.clearSession);
    ApiClient.transport = MockClient((request) async {
      sent = request;
      return http.Response(jsonEncode({'source_person_id': '7', 'target_person_id': '9', 'target_version': 5}), 200,
          headers: {'content-type': 'application/json'});
    });
    final version = await const PersonDirectoryApi().mergePerson(7, 9, expectedTargetVersion: 4);
    expect(sent.method, 'POST');
    expect(sent.url.path, '/api/v1/site-admin/persons/7/merge');
    expect(jsonDecode(sent.body), {'target_person_id': '9', 'expected_target_version': 4});
    expect(version, 5);
  });
}
