import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sitepulse/domain/models/person_ref.dart';
import 'package:sitepulse/domain/repositories/person_repository.dart';
import 'package:sitepulse/domain/services/person_directory_api.dart';
import 'package:sitepulse/ui/residents/sp_person_form.dart';
import 'package:sitepulse/ui/residents/sp_person_picker.dart';
import 'package:sitepulse/ui/theme/app_theme.dart';

PersonSummary _person(int id, String name) => PersonSummary(
  personId: id,
  fullName: name,
  email: '$id@example.test',
  phone: '0555000000$id',
  role: 'HOME_OWNER',
  ownedUnits: 1,
  occupiedUnits: 0,
  login: PersonLogin.none,
);

class _FakePersonRepository implements PersonRepository {
  final List<int> requestedPages = [];
  List<DuplicateCandidate> duplicates = [];
  int totalPeople = 121;
  bool secondPersonIneligible = false;
  int createCount = 0;

  @override
  Future<PersonSearchPage> search({
    String query = '',
    String? context,
    String? unitId,
    int page = 1,
    int pageSize = 50,
  }) async {
    requestedPages.add(page);
    final start = (page - 1) * pageSize;
    final end = (start + pageSize).clamp(0, totalPeople);
    final items = [
      for (var i = start; i < end; i++)
        PersonSearchResult(
          person: _person(i + 1, 'Person ${i + 1}'),
          roles: const ['Malik'],
          unitLabels: const ['A-1'],
          allowed: !(secondPersonIneligible && i == 0),
          eligibilityCode: secondPersonIneligible && i == 0
              ? 'ALREADY_OWNER_OF_UNIT'
              : null,
        ),
    ];
    return PersonSearchPage(
      items: items,
      total: totalPeople,
      page: page,
      pageSize: pageSize,
    );
  }

  @override
  Future<List<DuplicateCandidate>> findDuplicates({
    required String fullName,
    String? email,
    String? phone,
    int? excludePersonId,
  }) async => duplicates;

  @override
  Future<PersonSummary> create({
    required String fullName,
    String? phone,
    String? email,
    bool confirmDistinct = false,
  }) async {
    createCount++;
    return _person(500, fullName);
  }

  @override
  Future<PersonSummary> update(
    int personId, {
    required int version,
    required String fullName,
    String? phone,
    String? email,
  }) async => _person(personId, fullName);

  @override
  Future<PersonSummary?> getById(int personId) async =>
      _person(personId, 'Person $personId');

  @override
  PersonRef referenceFor(PersonSearchResult result) =>
      PersonRef.existing(result.person.personId);
}

void main() {
  // covers: SC-12-03-01
  test(
    'PersonRef encodes existing and draft references in the API contract shape',
    () {
      expect(const PersonRef.existing(42).toJson(), {
        'kind': 'existing',
        'person_id': 42,
      });
      const draft = PersonRef.draft(
        fullName: 'Ayşe Demir',
        phone: '0555',
        email: 'ayse@example.test',
        confirmDistinct: true,
      );
      expect(draft.toJson(), {
        'kind': 'new',
        'card': {
          'full_name': 'Ayşe Demir',
          'phone': '0555',
          'email': 'ayse@example.test',
        },
        'confirm_distinct': true,
      });
      expect(PersonRef.fromJson(draft.toJson()).toJson(), draft.toJson());
    },
  );

  // covers: SC-12-03-01
  testWidgets('picker pages through people beyond the first one hundred', (
    tester,
  ) async {
    final repository = _FakePersonRepository();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showSpPersonPicker(context: context, repository: repository),
              child: const Text('Open picker'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    expect(find.text('Person 1'), findsOneWidget);

    for (var page = 2; page <= 3; page++) {
      final more = find.byKey(const Key('sp_person_load_more'));
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
    }
    expect(repository.requestedPages, [1, 2, 3]);
    expect(find.text('Person 121'), findsOneWidget);
  });

  // covers: SC-12-03-02
  testWidgets(
    'picker shows an ineligible result with its reason and keeps it unselectable',
    (tester) async {
      final repository = _FakePersonRepository()
        ..secondPersonIneligible = true
        ..totalPeople = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSpPersonPicker(
                  context: context,
                  repository: repository,
                ),
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      expect(find.text('Person 1'), findsOneWidget);
      expect(find.text('Bu kişi bu dairenin maliki.'), findsOneWidget);
      expect(
        find
            .byType(OutlinedButton)
            .evaluate()
            .any(
              (element) =>
                  element.widget.key == const Key('sp_person_load_more'),
            ),
        isFalse,
      );
    },
  );

  // covers: SC-12-03-03
  testWidgets(
    'form explains duplicate reasons and asks before confirming a distinct person',
    (tester) async {
      final existing = _person(8, 'Ayşe Demir');
      final repository = _FakePersonRepository()
        ..duplicates = [
          DuplicateCandidate(
            person: existing,
            reasons: const ['SAME_PHONE', 'SIMILAR_NAME'],
          ),
        ];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: SpPersonForm(repository: repository),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('person_form_name')),
        'Ayşe Demir',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Benzerlik: aynı telefon, benzer ad'), findsOneWidget);
      expect(find.text('Bu farklı bir kişi'), findsOneWidget);
    },
  );

  testWidgets('form blocks a duplicate email and offers the existing person', (tester) async {
    final existing = _person(8, 'Ayşe Demir');
    final repository = _FakePersonRepository()
      ..duplicates = [DuplicateCandidate(person: existing, reasons: const ['SAME_EMAIL'])];
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: SpPersonForm(repository: repository)));
    await tester.enterText(find.byKey(const Key('person_form_name')), 'Ayşe Demir');
    await tester.enterText(find.byKey(const Key('person_form_email')), existing.email);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Kullan'), findsOneWidget);
    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();
    expect(find.text('Bu e-posta başka bir kişide kayıtlı. Mevcut kişiyi seçin.'), findsOneWidget);
    expect(repository.createCount, 0);
  });
}
