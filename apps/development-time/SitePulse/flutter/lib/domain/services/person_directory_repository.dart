import 'dart:convert';

import '../repositories/person_repository.dart';
import 'api_client.dart';
import 'person_directory_api.dart';

/// Connects the shared picker and card form to the scoped person endpoints.
class PersonDirectoryRepository implements PersonRepository {
  const PersonDirectoryRepository();

  @override
  Future<PersonSearchPage> search({
    String query = '',
    String? context,
    String? unitId,
    int page = 1,
    int pageSize = 50,
  }) async {
    final response = await ApiClient.get(
      ApiClient.uri('/api/v1/site-admin/persons/search', {
        if (query.trim().isNotEmpty) 'q': query.trim(),
        'context': ?context,
        'unit_id': ?unitId,
        'page': '$page',
        'limit': '$pageSize',
      }),
    ).timeout(const Duration(seconds: 15));
    final data = ApiClient.decode(response) as Map<String, dynamic>;
    final items = ((data['items'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((item) {
          final card = item['card'] as Map<String, dynamic>? ?? const {};
          final eligibility = item['eligibility'] as Map<String, dynamic>?;
          final roles = ((card['roles'] as List?) ?? const [])
              .map((role) => role.toString())
              .toList();
          return PersonSearchResult(
            person: _summaryFromCard(card),
            roles: roles,
            unitLabels: ((card['unit_labels'] as List?) ?? const [])
                .map((label) => label.toString())
                .toList(),
            allowed: eligibility?['allowed'] as bool? ?? true,
            eligibilityCode: eligibility?['code']?.toString(),
          );
        })
        .toList();
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
  }) => const PersonDirectoryApi().findDuplicates(
    fullName: fullName,
    email: email,
    phone: phone,
    excludePersonId: excludePersonId,
  );

  @override
  Future<PersonSummary> create({
    required String fullName,
    String? phone,
    String? email,
    bool confirmDistinct = false,
  }) async {
    final response = await ApiClient.post(
      ApiClient.uri('/api/v1/site-admin/persons'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'card': {'full_name': fullName, 'phone': ?phone, 'email': ?email},
        'confirm_distinct': confirmDistinct,
      }),
    ).timeout(const Duration(seconds: 15));
    final data = ApiClient.decode(response) as Map<String, dynamic>;
    return _summaryFromCard(data['card'] as Map<String, dynamic>);
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
      ApiClient.uri('/api/v1/site-admin/persons/$personId'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'version': version,
        'full_name': fullName,
        'phone': ?phone,
        'email': ?email,
      }),
    ).timeout(const Duration(seconds: 15));
    final data = ApiClient.decode(response) as Map<String, dynamic>;
    return _summaryFromCard(data['card'] as Map<String, dynamic>);
  }

  @override
  Future<PersonSummary?> getById(int personId) async {
    final response = await ApiClient.get(
      ApiClient.uri('/api/v1/site-admin/persons/$personId/card'),
    ).timeout(const Duration(seconds: 15));
    final data = ApiClient.decode(response) as Map<String, dynamic>;
    final card = data['card'];
    return card is Map<String, dynamic> ? _summaryFromCard(card) : null;
  }

  static PersonSummary _summaryFromCard(Map<String, dynamic> card) {
    final roles = ((card['roles'] as List?) ?? const []).map(
      (role) => role.toString(),
    );
    return PersonSummary(
      personId: (card['person_id'] as num?)?.toInt() ?? 0,
      fullName: card['full_name']?.toString() ?? '',
      email: card['email']?.toString() ?? '',
      phone: card['phone']?.toString() ?? '',
      role: roles.firstOrNull ?? '',
      ownedUnits: 0,
      occupiedUnits: 0,
      login: PersonLogin.fromCode(card['login']?.toString()),
      version: (card['version'] as num?)?.toInt() ?? 0,
      allowedActions: ((card['allowed_actions'] as List?) ?? const [])
          .map((action) => action.toString())
          .toList(),
    );
  }
}
