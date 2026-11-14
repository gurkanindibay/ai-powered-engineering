import 'dart:convert';

import '../models/person_ref.dart';
import '../services/api_client.dart';
import '../services/person_directory_api.dart';
import 'person_repository.dart';

/// [PersonRepository] backed by the site-admin person endpoints.
///
/// Failures surface as [ApiException] from [ApiClient.decode]; a stale card version
/// arrives as the `PERSON_VERSION_CONFLICT` code.
class ApiPersonRepository implements PersonRepository {
  final PersonDirectoryApi _directory;

  const ApiPersonRepository({PersonDirectoryApi directory = const PersonDirectoryApi()}) : _directory = directory;

  static const _base = '/api/v1/site-admin/persons';
  static const _timeout = Duration(seconds: 15);
  static const _json = {'Content-Type': 'application/json'};

  PersonSummary _card(Object? data) {
    final map = data as Map<String, dynamic>;
    return PersonSummary.fromJson((map['card'] as Map<String, dynamic>?) ?? map);
  }

  @override
  Future<PersonSearchPage> search({
    String query = '',
    String? context,
    String? unitId,
    int page = 1,
    int pageSize = 50,
  }) async {
    final response = await ApiClient.get(ApiClient.uri('$_base/search', {
      if (query.trim().isNotEmpty) 'q': query.trim(),
      'context': ?context,
      'unit_id': ?unitId,
      'limit': '$pageSize',
      'page': '$page',
    })).timeout(_timeout);
    final data = ApiClient.decode(response) as Map<String, dynamic>;
    final items = ((data['items'] as List?) ?? const []).whereType<Map<String, dynamic>>().map((item) {
      final card = (item['card'] as Map<String, dynamic>?) ?? const {};
      final eligibility = item['eligibility'] as Map<String, dynamic>?;
      return PersonSearchResult(
        person: PersonSummary.fromJson(card),
        roles: ((card['roles'] as List?) ?? const []).map((r) => r.toString()).toList(),
        unitLabels: ((card['unit_labels'] as List?) ?? const []).map((l) => l.toString()).toList(),
        allowed: eligibility?['allowed'] as bool? ?? true,
        eligibilityCode: eligibility?['code']?.toString(),
      );
    }).toList();
    return PersonSearchPage(
      items: items,
      total: (data['total'] as num?)?.toInt() ?? items.length,
      page: (data['page'] as num?)?.toInt() ?? page,
      pageSize: (data['page_size'] as num?)?.toInt() ?? pageSize,
    );
  }

  @override
  Future<List<DuplicateCandidate>> findDuplicates({
    required String fullName,
    String? email,
    String? phone,
    int? excludePersonId,
  }) =>
      _directory.findDuplicates(fullName: fullName, email: email, phone: phone, excludePersonId: excludePersonId);

  @override
  Future<PersonSummary> create({
    required String fullName,
    String? phone,
    String? email,
    bool confirmDistinct = false,
  }) async {
    final response = await ApiClient.post(
      ApiClient.uri(_base),
      headers: _json,
      body: jsonEncode({
        'card': {'full_name': fullName, 'phone': phone, 'email': email},
        'confirm_distinct': confirmDistinct,
      }),
    ).timeout(_timeout);
    return _card(ApiClient.decode(response));
  }

  @override
  Future<PersonSummary> update(
    int personId, {
    required int version,
    required String fullName,
    String? phone,
    String? email,
  }) async {
    final response = await ApiClient.patch(
      ApiClient.uri('$_base/$personId'),
      headers: _json,
      body: jsonEncode({'full_name': fullName, 'phone': phone, 'email': email, 'version': version}),
    ).timeout(_timeout);
    return _card(ApiClient.decode(response));
  }

  @override
  Future<PersonSummary?> getById(int personId) async {
    final response = await ApiClient.get(ApiClient.uri('$_base/$personId/card')).timeout(_timeout);
    return _card(ApiClient.decode(response));
  }

  @override
  PersonRef referenceFor(PersonSearchResult result) => PersonRef.existing(result.person.personId);
}
