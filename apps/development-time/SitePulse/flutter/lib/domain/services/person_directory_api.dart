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

/// How the site reaches a person (person module F7).
class ContactPreferences {
  final String channel;
  final String language;
  final String? emergencyName;
  final String? emergencyPhone;

  const ContactPreferences({
    this.channel = 'EMAIL',
    this.language = 'tr',
    this.emergencyName,
    this.emergencyPhone,
  });

  static const channels = {'EMAIL': 'E-posta', 'SMS': 'SMS', 'WHATSAPP': 'WhatsApp', 'PHONE': 'Telefon'};
  static const languages = {'tr': 'Türkçe', 'en': 'English'};

  String get channelLabel => channels[channel] ?? channel;
  String get languageLabel => languages[language] ?? language;

  factory ContactPreferences.fromJson(Map<String, dynamic> json) => ContactPreferences(
        channel: json['preferred_channel']?.toString() ?? 'EMAIL',
        language: json['preferred_language']?.toString() ?? 'tr',
        emergencyName: json['emergency_contact_name']?.toString(),
        emergencyPhone: json['emergency_contact_phone']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'preferred_channel': channel,
        'preferred_language': language,
        'emergency_contact_name': emergencyName,
        'emergency_contact_phone': emergencyPhone,
      };
}

/// A channel consent the person set themselves (read-only for managers, KVKK).
class ChannelConsent {
  final String channel;
  final bool granted;

  const ChannelConsent({required this.channel, required this.granted});

  String get label => switch (channel) {
        'EMAIL' => 'E-posta',
        'SMS' => 'SMS',
        'PUSH' => 'Bildirim',
        'WHATSAPP' => 'WhatsApp',
        _ => channel,
      };
}

/// National ID (masked), preferences and consents shown on the profile (F7/F10).
class PersonRecord {
  final String? nationalIdMasked;
  final ContactPreferences preferences;
  final List<ChannelConsent> consents;

  const PersonRecord({this.nationalIdMasked, this.preferences = const ContactPreferences(), this.consents = const []});

  factory PersonRecord.fromJson(Map<String, dynamic> json) => PersonRecord(
        nationalIdMasked: json['national_id_masked']?.toString(),
        preferences: ContactPreferences.fromJson((json['preferences'] as Map<String, dynamic>?) ?? const {}),
        consents: ((json['consents'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((c) => ChannelConsent(channel: c['channel']?.toString() ?? '', granted: c['granted'] as bool? ?? true))
            .toList(),
      );
}

/// A person of the site who may be the one being entered (F9).
class DuplicateCandidate {
  final PersonSummary person;
  final List<String> reasons;

  const DuplicateCandidate({required this.person, required this.reasons});

  static String reasonLabel(String reason) => switch (reason) {
        'SAME_NATIONAL_ID' => 'aynı kimlik no',
        'SAME_EMAIL' => 'aynı e-posta',
        'SAME_PHONE' => 'aynı telefon',
        'SIMILAR_NAME' => 'benzer ad',
        _ => reason,
      };

  String get reasonText => reasons.map(reasonLabel).join(', ');

  factory DuplicateCandidate.fromJson(Map<String, dynamic> json) => DuplicateCandidate(
        person: PersonSummary.fromJson((json['person'] as Map<String, dynamic>?) ?? const {}),
        reasons: ((json['reasons'] as List?) ?? const []).map((r) => r.toString()).toList(),
      );
}

/// One row of an import report (F8).
class ImportRowResult {
  final int line;
  final String block;
  final int? unitNo;
  final String ownerName;
  final List<String> errors;
  final List<String> warnings;
  final String? activation;

  const ImportRowResult({
    required this.line,
    required this.block,
    this.unitNo,
    required this.ownerName,
    this.errors = const [],
    this.warnings = const [],
    this.activation,
  });

  bool get ok => errors.isEmpty;

  factory ImportRowResult.fromJson(Map<String, dynamic> json) => ImportRowResult(
        line: (json['line'] as num?)?.toInt() ?? 0,
        block: json['block']?.toString() ?? '',
        unitNo: (json['unit_no'] as num?)?.toInt(),
        ownerName: json['owner_full_name']?.toString() ?? '',
        errors: ((json['errors'] as List?) ?? const []).map((e) => e.toString()).toList(),
        warnings: ((json['warnings'] as List?) ?? const []).map((e) => e.toString()).toList(),
        activation: json['activation']?.toString(),
      );
}

class ImportReport {
  final bool dryRun;
  final bool committed;
  final int total;
  final int invalid;
  final int created;
  final List<ImportRowResult> rows;

  const ImportReport({
    required this.dryRun,
    required this.committed,
    required this.total,
    required this.invalid,
    required this.created,
    required this.rows,
  });

  factory ImportReport.fromJson(Map<String, dynamic> json) => ImportReport(
        dryRun: json['dry_run'] as bool? ?? true,
        committed: json['committed'] as bool? ?? false,
        total: (json['total'] as num?)?.toInt() ?? 0,
        invalid: (json['invalid'] as num?)?.toInt() ?? 0,
        created: (json['created'] as num?)?.toInt() ?? 0,
        rows: ((json['rows'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ImportRowResult.fromJson)
            .toList(),
      );
}

/// Header of the import template; the backend reads the same columns.
const personImportColumns = [
  'block', 'unit_no', 'floor', 'owner_full_name', 'owner_email', 'owner_phone', 'land_share',
  'monthly_dues', 'is_resident', 'tenant_full_name', 'tenant_email', 'tenant_phone',
];

class PersonProfile {
  final PersonSummary person;
  final List<PersonUnit> units;
  final PersonRecord record;

  const PersonProfile({required this.person, required this.units, this.record = const PersonRecord()});

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
        record: PersonRecord.fromJson((json['record'] as Map<String, dynamic>?) ?? const {}),
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

  /// Records (or, with an empty value, clears) the person's national ID. Returns the
  /// masked form. Throws `STEP_UP_REQUIRED` until the caller has re-entered their password.
  Future<String?> setNationalId(int personId, String nationalId) async {
    final response = await ApiClient.put(
      ApiClient.uri('/api/v1/site-admin/persons/$personId/national-id'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'national_id': nationalId.trim().isEmpty ? null : nationalId.trim()}),
    ).timeout(const Duration(seconds: 15));
    final data = ApiClient.decode(response);
    return data is Map<String, dynamic> ? data['national_id_masked']?.toString() : null;
  }

  Future<ContactPreferences> updatePreferences(int personId, ContactPreferences preferences) async {
    final response = await ApiClient.put(
      ApiClient.uri('/api/v1/site-admin/persons/$personId/preferences'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(preferences.toJson()),
    ).timeout(const Duration(seconds: 15));
    return ContactPreferences.fromJson(ApiClient.decode(response) as Map<String, dynamic>);
  }

  /// People of the site who may be the one being entered. Sent as a POST so a national
  /// ID never ends up in a URL.
  Future<List<DuplicateCandidate>> findDuplicates({
    String? fullName,
    String? email,
    String? phone,
    String? nationalId,
    int? excludePersonId,
  }) async {
    final response = await ApiClient.post(
      ApiClient.uri('/api/v1/site-admin/persons/duplicate-check'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'full_name': ?fullName,
        'email': ?email,
        'phone': ?phone,
        'national_id': ?nationalId,
        'exclude_person_id': ?excludePersonId,
      }),
    ).timeout(const Duration(seconds: 15));
    final data = ApiClient.decode(response);
    return ((data as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(DuplicateCandidate.fromJson)
        .toList();
  }

  /// Checks a CSV of owners; with [dryRun] false it also registers them when no row
  /// has an error.
  Future<ImportReport> importCsv(String csv, {required bool dryRun}) async {
    final response = await ApiClient.post(
      ApiClient.uri('/api/v1/site-admin/persons/import'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'csv': csv, 'dry_run': dryRun}),
    ).timeout(const Duration(seconds: 120));
    return ImportReport.fromJson(ApiClient.decode(response) as Map<String, dynamic>);
  }
}
