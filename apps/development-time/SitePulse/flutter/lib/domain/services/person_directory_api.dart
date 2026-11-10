import 'dart:convert';

import 'api_client.dart';

/// A person's login state as the manager sees it (person module U4).
enum PersonLogin {
  none('NONE', 'Giriş hesabı yok'),
  pending('PENDING', 'Etkinleştirme bekliyor'),
  active('ACTIVE', 'Aktif');

  final String code;
  final String label;
  const PersonLogin(this.code, this.label);

  static PersonLogin fromCode(String? code) =>
      values.firstWhere((v) => v.code == code, orElse: () => PersonLogin.none);
}

String personRoleLabel(String role) => switch (role) {
      'HOME_OWNER' => 'Kat Maliki',
      'HOME_RESIDENT' => 'Sakin',
      'SITE_MANAGER' => 'Site Yöneticisi',
      _ => role,
    };

class PersonSummary {
  final int personId;
  final String fullName;
  final String email;
  final String phone;
  final String role;
  final int ownedUnits;
  final int occupiedUnits;
  final PersonLogin login;

  const PersonSummary({
    required this.personId,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.role,
    required this.ownedUnits,
    required this.occupiedUnits,
    required this.login,
  });

  factory PersonSummary.fromJson(Map<String, dynamic> json) => PersonSummary(
        personId: (json['person_id'] as num?)?.toInt() ?? 0,
        fullName: json['full_name']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        phone: json['phone']?.toString() ?? '',
        role: json['role']?.toString() ?? '',
        ownedUnits: (json['owned_units'] as num?)?.toInt() ?? 0,
        occupiedUnits: (json['occupied_units'] as num?)?.toInt() ?? 0,
        login: PersonLogin.fromCode(json['login']?.toString()),
      );
}

class DirectoryPage {
  final List<PersonSummary> items;
  final int total;
  final int page;
  final int pageSize;

  const DirectoryPage({required this.items, required this.total, required this.page, required this.pageSize});

  bool get hasMore => page * pageSize < total;

  factory DirectoryPage.fromJson(Map<String, dynamic> json) => DirectoryPage(
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PersonSummary.fromJson)
            .toList(),
        total: (json['total'] as num?)?.toInt() ?? 0,
        page: (json['page'] as num?)?.toInt() ?? 1,
        pageSize: (json['page_size'] as num?)?.toInt() ?? 25,
      );
}

/// One period of a person's relation to a unit.
class PersonUnit {
  final String unitId;
  final String block;
  final int unitNo;
  final String relation;
  final DateTime? startDate;
  final DateTime? endDate;
  final bool active;

  const PersonUnit({
    required this.unitId,
    required this.block,
    required this.unitNo,
    required this.relation,
    this.startDate,
    this.endDate,
    required this.active,
  });

  String get relationLabel => switch (relation) {
        'OWNER' => 'Malik',
        'OCCUPANT_OWNER' => 'Malik (oturuyor)',
        'TENANT' => 'Kiracı',
        'MEMBER' => 'Hane üyesi',
        _ => relation,
      };

  factory PersonUnit.fromJson(Map<String, dynamic> json) => PersonUnit(
        unitId: json['unit_id']?.toString() ?? '',
        block: json['block']?.toString() ?? '',
        unitNo: (json['unit_no'] as num?)?.toInt() ?? 0,
        relation: json['relation']?.toString() ?? '',
        startDate: DateTime.tryParse(json['start_date']?.toString() ?? ''),
        endDate: DateTime.tryParse(json['end_date']?.toString() ?? ''),
        active: json['active'] as bool? ?? false,
      );
}

class PersonProfile {
  final PersonSummary person;
  final List<PersonUnit> units;

  const PersonProfile({required this.person, required this.units});

  /// A unit where this person is the owner or the tenant, for resending an activation link.
  PersonUnit? get activationUnit => units.cast<PersonUnit?>().firstWhere(
        (u) => u!.active && (u.relation == 'OWNER' || u.relation == 'OCCUPANT_OWNER' || u.relation == 'TENANT'),
        orElse: () => null,
      );

  factory PersonProfile.fromJson(Map<String, dynamic> json) => PersonProfile(
        person: PersonSummary.fromJson((json['person'] as Map<String, dynamic>?) ?? const {}),
        units: ((json['units'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PersonUnit.fromJson)
            .toList(),
      );
}

/// Client for the person-centric endpoints (person module F1/U3/U4/F8).
/// Failures surface as [ApiException] from [ApiClient.decode].
class PersonDirectoryApi {
  const PersonDirectoryApi();

  Future<DirectoryPage> directory({String query = '', String? role, String? login, int page = 1, int pageSize = 25}) async {
    final response = await ApiClient.get(ApiClient.uri('/api/v1/site-admin/persons', {
      if (query.trim().isNotEmpty) 'q': query.trim(),
      'role': ?role,
      'login': ?login,
      'page': '$page',
      'page_size': '$pageSize',
    })).timeout(const Duration(seconds: 15));
    return DirectoryPage.fromJson(ApiClient.decode(response) as Map<String, dynamic>);
  }

  Future<PersonProfile> profile(int personId) async {
    final response =
        await ApiClient.get(ApiClient.uri('/api/v1/site-admin/persons/$personId')).timeout(const Duration(seconds: 15));
    return PersonProfile.fromJson(ApiClient.decode(response) as Map<String, dynamic>);
  }

  /// The filtered directory as CSV bytes. Throws `STEP_UP_REQUIRED` until the caller has
  /// re-entered their password.
  Future<List<int>> exportCsv({String query = '', String? role, String? login}) async {
    final response = await ApiClient.get(ApiClient.uri('/api/v1/site-admin/persons/export', {
      if (query.trim().isNotEmpty) 'q': query.trim(),
      'role': ?role,
      'login': ?login,
    })).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) ApiClient.decode(response);
    return response.bodyBytes;
  }

  /// Sends a fresh activation link to the owner (or tenant) of [unitId]. Returns the delivery status.
  Future<String?> resendActivation(String unitId, {bool tenant = false}) async {
    final response = await ApiClient.post(
      ApiClient.uri('/api/v1/site-admin/home-owners/$unitId/resend-activation'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'role': tenant ? 'TENANT' : 'OWNER'}),
    ).timeout(const Duration(seconds: 15));
    final data = ApiClient.decode(response);
    return data is Map<String, dynamic> ? data['status']?.toString() : null;
  }
}
