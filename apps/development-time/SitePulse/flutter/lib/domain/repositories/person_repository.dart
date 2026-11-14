import '../models/person_ref.dart';
import '../services/person_directory_api.dart';

/// Search result metadata needed to explain role eligibility in a person picker.
class PersonSearchResult {
  final PersonSummary person;
  final List<String> roles;
  final List<String> unitLabels;
  final bool allowed;
  final String? eligibilityCode;

  const PersonSearchResult({
    required this.person,
    this.roles = const [],
    this.unitLabels = const [],
    this.allowed = true,
    this.eligibilityCode,
  });

  String get eligibilityMessage => switch (eligibilityCode) {
    'ALREADY_OWNER_OF_UNIT' => 'Bu kişi bu dairenin maliki.',
    'ALREADY_TENANT_OF_UNIT' => 'Bu kişi bu dairenin kiracısı.',
    'RELATIONSHIP_EXISTS' => 'Bu kişiyle ilişki zaten kayıtlı.',
    _ => eligibilityCode ?? 'Bu işlem için uygun değil.',
  };

  static String roleLabel(String role) => switch (role) {
    'OWNER' => 'Malik',
    'OCCUPANT_OWNER' => 'Malik (oturuyor)',
    'TENANT' => 'Kiracı',
    'MEMBER' => 'Hane üyesi',
    'PRIMARY_CONTACT' => 'İletişim kişisi',
    'HOME_OWNER' => 'Kat maliki',
    'HOME_RESIDENT' => 'Sakin',
    _ => role,
  };
}

/// One server page. Paging is explicit so callers can search beyond the first 100.
class PersonSearchPage {
  final List<PersonSearchResult> items;
  final int total;
  final int page;
  final int pageSize;

  const PersonSearchPage({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  bool get hasMore => page * pageSize < total;
}

/// Repository boundary for person search, duplicate checks and card writes.
abstract interface class PersonRepository {
  Future<PersonSearchPage> search({
    String query,
    String? context,
    String? unitId,
    int page,
    int pageSize,
  });

  Future<List<DuplicateCandidate>> findDuplicates({
    required String fullName,
    String? email,
    String? phone,
    int? excludePersonId,
  });

  Future<PersonSummary> create({
    required String fullName,
    String? phone,
    String? email,
    bool confirmDistinct,
  });

  Future<PersonSummary> update(
    int personId, {
    required int version,
    required String fullName,
    String? phone,
    String? email,
  });

  Future<PersonSummary?> getById(int personId);

  PersonRef referenceFor(PersonSearchResult result) =>
      PersonRef.existing(result.person.personId);
}
