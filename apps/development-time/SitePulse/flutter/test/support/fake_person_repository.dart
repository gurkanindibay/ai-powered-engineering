import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/person_ref.dart';
import 'package:sitepulse/domain/repositories/person_repository.dart';
import 'package:sitepulse/domain/services/person_directory_api.dart';

/// In-memory [PersonRepository] for widget tests of screens that use `SpPersonField`.
class FakePersonRepository implements PersonRepository {
  final Map<int, PersonSummary> people;

  FakePersonRepository(Map<int, String> names)
    : people = {
        for (final entry in names.entries)
          entry.key: PersonSummary(
            personId: entry.key,
            fullName: entry.value,
            email: 'person${entry.key}@example.test',
            phone: '053300000${entry.key.toString().padLeft(2, '0')}',
            role: 'HOME_OWNER',
            ownedUnits: 0,
            occupiedUnits: 0,
            login: PersonLogin.none,
          ),
      };

  @override
  Future<PersonSearchPage> search({
    String query = '',
    String? context,
    String? unitId,
    int page = 1,
    int pageSize = 50,
  }) async {
    final items = [
      for (final person in people.values) PersonSearchResult(person: person),
    ];
    return PersonSearchPage(
      items: items,
      total: items.length,
      page: 1,
      pageSize: pageSize,
    );
  }

  @override
  Future<List<DuplicateCandidate>> findDuplicates({
    required String fullName,
    String? email,
    String? phone,
    int? excludePersonId,
  }) async => const [];

  @override
  Future<PersonSummary> create({
    required String fullName,
    String? phone,
    String? email,
    bool confirmDistinct = false,
  }) => throw UnimplementedError();

  @override
  Future<PersonSummary> update(
    int personId, {
    required int version,
    required String fullName,
    String? phone,
    String? email,
  }) => throw UnimplementedError();

  @override
  Future<PersonSummary?> getById(int personId) async => people[personId];

  @override
  PersonRef referenceFor(PersonSearchResult result) =>
      PersonRef.existing(result.person.personId);
}

/// Opens the person field [fieldId], then picks [personId] from the shared picker.
Future<void> pickPerson(
  WidgetTester tester,
  String fieldId,
  int personId,
) async {
  final field = find.byKey(Key(fieldId));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  final result = find.byKey(Key('sp_person_result_$personId'));
  await tester.ensureVisible(result);
  await tester.tap(result);
  await tester.pumpAndSettle();
}
