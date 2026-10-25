import 'package:decimal/decimal.dart';

enum DebtStatus {
  pending('Pending'),
  overdue('Overdue'),
  paid('Paid');

  final String label;
  const DebtStatus(this.label);

  // Backwards compatibility getters
  static DebtStatus get bekliyor => DebtStatus.pending;
  static DebtStatus get gecikmede => DebtStatus.overdue;
  static DebtStatus get odendi => DebtStatus.paid;
}

// Backwards compatibility alias
typedef BorcDurumu = DebtStatus;

class DuesLiability {
  final String id;
  final String unitId;
  final String period;
  final Decimal principalAmount;
  final Decimal delayPenalty;
  final Decimal totalAmount;
  final DateTime dueDate;
  final int daysOverdue;
  final DebtStatus status;

  const DuesLiability({
    required this.id,
    required this.unitId,
    required this.period,
    required this.principalAmount,
    required this.delayPenalty,
    required this.totalAmount,
    required this.dueDate,
    this.daysOverdue = 0,
    required this.status,
  });

  // Backwards compatibility getters
  String get daireId => unitId;
  String get donem => period;
  Decimal get anaPara => principalAmount;
  Decimal get gecikmeTazminati => delayPenalty;
  Decimal get toplamTutar => totalAmount;
  DateTime get sonOdemeTarihi => dueDate;
  int get gecikenGunSayisi => daysOverdue;
  DebtStatus get durum => status;

  DuesLiability copyWith({
    String? id,
    String? unitId,
    String? period,
    Decimal? principalAmount,
    Decimal? delayPenalty,
    Decimal? totalAmount,
    DateTime? dueDate,
    int? daysOverdue,
    DebtStatus? status,
    // Backwards compatibility params
    String? daireId,
    String? donem,
    Decimal? anaPara,
    Decimal? gecikmeTazminati,
    Decimal? toplamTutar,
    DateTime? sonOdemeTarihi,
    int? gecikenGunSayisi,
    DebtStatus? durum,
  }) {
    return DuesLiability(
      id: id ?? this.id,
      unitId: unitId ?? daireId ?? this.unitId,
      period: period ?? donem ?? this.period,
      principalAmount: principalAmount ?? anaPara ?? this.principalAmount,
      delayPenalty: delayPenalty ?? gecikmeTazminati ?? this.delayPenalty,
      totalAmount: totalAmount ?? toplamTutar ?? this.totalAmount,
      dueDate: dueDate ?? sonOdemeTarihi ?? this.dueDate,
      daysOverdue: daysOverdue ?? gecikenGunSayisi ?? this.daysOverdue,
      status: status ?? durum ?? this.status,
    );
  }
}

// Backwards compatibility alias
typedef AidatBorcu = DuesLiability;

class ApartmentUnit {
  final String id;
  final String siteId;
  final String siteName;
  final String block;
  final int unitNo;
  final int floor;
  final int landShare;
  final String ownerName;
  final String tenantName;
  final String? virtualIban;
  final Decimal? advancePayment;

  static const empty = ApartmentUnit(
    id: '',
    siteId: '',
    siteName: '',
    block: '',
    unitNo: 0,
    floor: 0,
    landShare: 0,
    ownerName: '',
    tenantName: '',
  );

  const ApartmentUnit({
    required this.id,
    this.siteId = '',
    required this.siteName,
    required this.block,
    required this.unitNo,
    required this.floor,
    required this.landShare,
    required this.ownerName,
    required this.tenantName,
    this.virtualIban,
    this.advancePayment,
  });

  // Backwards compatibility getters
  String get siteAdi => siteName;
  String get blok => block;
  int get daireNo => unitNo;
  int get kat => floor;
  int get arsaPayi => landShare;
  String get malikAdi => ownerName;
  String get kiraciAdi => tenantName;
  Decimal get avansBakiye => advancePayment ?? Decimal.zero;
  bool get hasAdvancePayment => (advancePayment ?? Decimal.zero) > Decimal.zero;
  String get displayLabel => block.isNotEmpty && unitNo > 0 ? '$block Blok D:$unitNo' : '';
  String get unitNumber => unitNo > 0 ? unitNo.toString() : '';

  ApartmentUnit copyWith({
    String? id,
    String? siteId,
    String? siteName,
    String? block,
    int? unitNo,
    int? floor,
    int? landShare,
    String? ownerName,
    String? tenantName,
    String? virtualIban,
    Decimal? advancePayment,
  }) {
    return ApartmentUnit(
      id: id ?? this.id,
      siteId: siteId ?? this.siteId,
      siteName: siteName ?? this.siteName,
      block: block ?? this.block,
      unitNo: unitNo ?? this.unitNo,
      floor: floor ?? this.floor,
      landShare: landShare ?? this.landShare,
      ownerName: ownerName ?? this.ownerName,
      tenantName: tenantName ?? this.tenantName,
      virtualIban: virtualIban ?? this.virtualIban,
      advancePayment: advancePayment ?? this.advancePayment,
    );
  }
}

// Backwards compatibility alias
typedef Daire = ApartmentUnit;

class AccountTransactionItem {
  final String id;
  final String title;
  final String subtitle;
  final Decimal amount;
  final String date;
  final bool isCredit;

  const AccountTransactionItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.date,
    required this.isCredit,
  });

  String get amountStr {
    final formatted = amount.toStringAsFixed(2).replaceAll('.', ',');
    return isCredit ? '+₺$formatted' : '₺$formatted';
  }

  factory AccountTransactionItem.fromJson(Map<String, dynamic> json) {
    return AccountTransactionItem(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? 'Aidat Hareketi',
      subtitle: json['subtitle'] as String? ?? '',
      amount: Decimal.tryParse(json['amount']?.toString() ?? '0') ?? Decimal.zero,
      date: json['date'] as String? ?? 'Bugün',
      isCredit: json['is_credit'] as bool? ?? false,
    );
  }
}

class ComplexCollectionSummary {
  final Decimal totalExpected;
  final Decimal totalCollected;
  final Decimal totalOverdueWithInterest;
  final Decimal totalAdvanceBalance;
  final int paidUnitsCount;
  final int overdueUnitsCount;
  final int totalUnitsCount;

  ComplexCollectionSummary({
    Decimal? totalExpected,
    Decimal? totalCollected,
    Decimal? totalOverdueWithInterest,
    Decimal? totalAdvanceBalance,
    this.paidUnitsCount = 0,
    this.overdueUnitsCount = 0,
    this.totalUnitsCount = 0,
  })  : totalExpected = totalExpected ?? Decimal.zero,
        totalCollected = totalCollected ?? Decimal.zero,
        totalOverdueWithInterest = totalOverdueWithInterest ?? Decimal.zero,
        totalAdvanceBalance = totalAdvanceBalance ?? Decimal.zero;

  factory ComplexCollectionSummary.zero({int totalUnitsCount = 0}) => ComplexCollectionSummary(
        totalExpected: Decimal.zero,
        totalCollected: Decimal.zero,
        totalOverdueWithInterest: Decimal.zero,
        totalAdvanceBalance: Decimal.zero,
        paidUnitsCount: 0,
        overdueUnitsCount: 0,
        totalUnitsCount: totalUnitsCount,
      );

  int get collectionRatePercent {
    if (totalExpected == Decimal.zero) return 0;
    final ratio = (totalCollected * Decimal.fromInt(100) / totalExpected);
    return ratio.toDouble().round();
  }

  int get collectionPercentage => collectionRatePercent;
  Decimal get totalOverdueAmount => totalOverdueWithInterest;

  ComplexCollectionSummary copyWith({
    Decimal? totalExpected,
    Decimal? totalCollected,
    Decimal? totalOverdueWithInterest,
    Decimal? totalAdvanceBalance,
    int? paidUnitsCount,
    int? overdueUnitsCount,
    int? totalUnitsCount,
  }) {
    return ComplexCollectionSummary(
      totalExpected: totalExpected ?? this.totalExpected,
      totalCollected: totalCollected ?? this.totalCollected,
      totalOverdueWithInterest: totalOverdueWithInterest ?? this.totalOverdueWithInterest,
      totalAdvanceBalance: totalAdvanceBalance ?? this.totalAdvanceBalance,
      paidUnitsCount: paidUnitsCount ?? this.paidUnitsCount,
      overdueUnitsCount: overdueUnitsCount ?? this.overdueUnitsCount,
      totalUnitsCount: totalUnitsCount ?? this.totalUnitsCount,
    );
  }
}

class FlatPaymentStatus {
  final String id;
  final String block;
  final int unitNo;
  final String residentName;
  final Decimal amountDue;
  final Decimal advanceBalance;
  final int daysOverdue;
  final bool isPaid;
  final String? paidDateStr;
  final String? houseType;

  FlatPaymentStatus({
    required this.id,
    required this.block,
    required this.unitNo,
    required this.residentName,
    required this.amountDue,
    Decimal? advanceBalance,
    required this.daysOverdue,
    required this.isPaid,
    this.paidDateStr,
    this.houseType,
  }) : advanceBalance = advanceBalance ?? Decimal.zero;

  bool get hasAdvanceBalance => advanceBalance > Decimal.zero;

  String get shortLabel {
    final match = RegExp(r'[a-zA-Z0-9]').firstMatch(block);
    final letter = match != null ? block.substring(match.start, match.end).toUpperCase() : (block.isNotEmpty ? block[0].toUpperCase() : 'A');
    return '$letter$unitNo';
  }

  String get flatDesc => block.contains('Blok') ? '$block D:$unitNo' : '$block Blok D:$unitNo';

  FlatPaymentStatus copyWith({
    String? id,
    String? block,
    int? unitNo,
    String? residentName,
    Decimal? amountDue,
    Decimal? advanceBalance,
    int? daysOverdue,
    bool? isPaid,
    String? paidDateStr,
    String? houseType,
  }) {
    return FlatPaymentStatus(
      id: id ?? this.id,
      block: block ?? this.block,
      unitNo: unitNo ?? this.unitNo,
      residentName: residentName ?? this.residentName,
      amountDue: amountDue ?? this.amountDue,
      advanceBalance: advanceBalance ?? this.advanceBalance,
      daysOverdue: daysOverdue ?? this.daysOverdue,
      isPaid: isPaid ?? this.isPaid,
      paidDateStr: paidDateStr ?? this.paidDateStr,
      houseType: houseType ?? this.houseType,
    );
  }
}

class HouseTypeTariff {
  final String id;
  final String siteId;
  final String typeName;
  final Decimal duesAmount;
  final String? description;

  HouseTypeTariff({
    required this.id,
    required this.siteId,
    required this.typeName,
    required this.duesAmount,
    this.description,
  });

  factory HouseTypeTariff.fromJson(Map<String, dynamic> json) {
    return HouseTypeTariff(
      id: json['id']?.toString() ?? '',
      siteId: json['site_id']?.toString() ?? '',
      typeName: json['type_name']?.toString() ?? '',
      duesAmount: Decimal.tryParse(json['dues_amount']?.toString() ?? '0') ?? Decimal.zero,
      description: json['description'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'site_id': siteId,
      'type_name': typeName,
      'dues_amount': duesAmount.toString(),
      'description': description,
    };
  }
}

class TenantSiteItem {
  final String id;
  final String name;
  final String city;
  final String address;
  final String status;
  final String planType;
  final int totalUnits;
  final Decimal monthlyCollectionVolume;
  final String adminName;
  final String adminEmail;
  final String adminPhone;
  final int actionCount;
  final List<String> blocks;

  const TenantSiteItem({
    required this.id,
    required this.name,
    required this.city,
    required this.address,
    required this.status,
    required this.planType,
    required this.totalUnits,
    required this.monthlyCollectionVolume,
    required this.adminName,
    required this.adminEmail,
    required this.adminPhone,
    this.actionCount = 0,
    this.blocks = const ['A Blok', 'B Blok'],
  });

  /// Invariant: A site has actions if it has registered units, financial collection volume,
  /// or logged operational actions. Sites with hasActions == false are eligible for deletion.
  bool get hasActions => actionCount > 0 || totalUnits > 0 || monthlyCollectionVolume > Decimal.zero;
}

class UnitResidentMember {
  final String id;
  final String fullName;
  final String relationship;
  final String phone;
  final String email;
  final bool isOwner;
  final String permissionScope;

  const UnitResidentMember({
    required this.id,
    required this.fullName,
    required this.relationship,
    this.phone = '',
    this.email = '',
    this.isOwner = false,
    this.permissionScope = 'Sakin Yetkisi',
  });

  String get residentId => id;

  factory UnitResidentMember.fromJson(Map<String, dynamic> json) {
    return UnitResidentMember(
      id: json['resident_id']?.toString() ?? json['id']?.toString() ?? '',
      fullName: json['full_name']?.toString() ?? json['fullName']?.toString() ?? '',
      relationship: json['relationship']?.toString() ?? 'Ev Sakini',
      phone: json['phone']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      isOwner: json['is_owner'] as bool? ?? json['isOwner'] as bool? ?? false,
      permissionScope: json['permission_scope']?.toString() ?? json['permissionScope']?.toString() ?? 'Sakin Yetkisi',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'resident_id': id,
      'full_name': fullName,
      'relationship': relationship,
      'phone': phone,
      'email': email,
      'is_owner': isOwner,
      'permission_scope': permissionScope,
    };
  }
}

class UnitInviteInfo {
  final String inviteUrl;
  final String token;
  final String unitLabel;
  final String expiresAtStr;
  final String securityNotice;

  const UnitInviteInfo({
    required this.inviteUrl,
    required this.token,
    required this.unitLabel,
    required this.expiresAtStr,
    required this.securityNotice,
  });
}

class RegistrationRequestItem {
  final String id;
  final String block;
  final int unitNo;
  final int floor;
  final String fullName;
  final String email;
  final String phone;
  final bool isResident;
  final Decimal duesAmount;
  final String timeAgoStr;

  const RegistrationRequestItem({
    required this.id,
    required this.block,
    required this.unitNo,
    required this.floor,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.isResident,
    required this.duesAmount,
    required this.timeAgoStr,
  });

  String get flatDesc => '$block D:$unitNo';
}

class ProvisionedSiteCredentials {
  final String siteId;
  final String siteName;
  final String adminName;
  final String adminEmail;
  final String temporaryPassword;
  final String planType;
  final bool isRenewal;

  const ProvisionedSiteCredentials({
    required this.siteId,
    required this.siteName,
    required this.adminName,
    required this.adminEmail,
    required this.temporaryPassword,
    required this.planType,
    this.isRenewal = false,
  });
}

class ProvisionedHomeOwnerCredentials {
  final String block;
  final int unitNo;
  final String ownerName;
  final String email;
  final String phone;
  final String temporaryPassword;
  final bool isResident;
  final Decimal duesAmount;
  final String? houseType;

  const ProvisionedHomeOwnerCredentials({
    required this.block,
    required this.unitNo,
    required this.ownerName,
    required this.email,
    required this.phone,
    required this.temporaryPassword,
    required this.isResident,
    required this.duesAmount,
    this.houseType,
  });
}

class HomeOwnerItem {
  final String unitId;
  final String siteId;
  final String block;
  final int unitNo;
  final int floor;
  final String ownerFullName;
  final String email;
  final String phone;
  final String landShare;
  final Decimal monthlyDues;
  final String? houseType;
  final bool isResident;
  final String? temporaryPassword;
  final bool mustChangePassword;
  final DateTime createdAt;
  final String occupancyStatus;
  final String? tenantFullName;
  final String? tenantEmail;
  final String? tenantPhone;
  final List<UnitResidentMember> householdResidents;
  final Decimal? _operationalDuesBalance;
  Decimal get operationalDuesBalance => _operationalDuesBalance ?? Decimal.zero;
  final Decimal? _capitalDuesBalance;
  Decimal get capitalDuesBalance => _capitalDuesBalance ?? Decimal.zero;

  const HomeOwnerItem({
    required this.unitId,
    required this.siteId,
    required this.block,
    required this.unitNo,
    required this.floor,
    required this.ownerFullName,
    required this.email,
    required this.phone,
    required this.landShare,
    required this.monthlyDues,
    this.houseType,
    required this.isResident,
    this.temporaryPassword,
    required this.mustChangePassword,
    required this.createdAt,
    this.occupancyStatus = 'OWNER_OCCUPIED',
    this.tenantFullName,
    this.tenantEmail,
    this.tenantPhone,
    this.householdResidents = const [],
    Decimal? operationalDuesBalance,
    Decimal? capitalDuesBalance,
  }) : _operationalDuesBalance = operationalDuesBalance,
       _capitalDuesBalance = capitalDuesBalance;

  factory HomeOwnerItem.fromJson(Map<String, dynamic> json) {
    return HomeOwnerItem(
      unitId: json['unit_id']?.toString() ?? '',
      siteId: json['site_id']?.toString() ?? '',
      block: json['block']?.toString() ?? '',
      unitNo: (json['unit_no'] as num?)?.toInt() ?? 0,
      floor: (json['floor'] as num?)?.toInt() ?? 1,
      ownerFullName: json['owner_full_name']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      landShare: json['land_share']?.toString() ?? '1/24',
      monthlyDues: Decimal.tryParse(json['monthly_dues']?.toString() ?? '0') ?? Decimal.zero,
      houseType: json['house_type']?.toString(),
      isResident: json['is_resident'] as bool? ?? true,
      temporaryPassword: json['temporary_password']?.toString(),
      mustChangePassword: json['must_change_password'] as bool? ?? false,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
      occupancyStatus: json['occupancy_status']?.toString() ?? 'OWNER_OCCUPIED',
      tenantFullName: json['tenant_full_name']?.toString(),
      tenantEmail: json['tenant_email']?.toString(),
      tenantPhone: json['tenant_phone']?.toString(),
      householdResidents: (json['household_residents'] as List<dynamic>?)
              ?.map((m) => UnitResidentMember.fromJson(m as Map<String, dynamic>))
              .toList() ??
          const [],
      operationalDuesBalance: Decimal.tryParse(json['operational_dues_balance']?.toString() ?? '0') ?? Decimal.zero,
      capitalDuesBalance: Decimal.tryParse(json['capital_dues_balance']?.toString() ?? '0') ?? Decimal.zero,
    );
  }

  HomeOwnerItem copyWith({
    String? unitId,
    String? siteId,
    String? block,
    int? unitNo,
    int? floor,
    String? ownerFullName,
    String? email,
    String? phone,
    String? landShare,
    Decimal? monthlyDues,
    String? houseType,
    bool? isResident,
    String? temporaryPassword,
    bool? mustChangePassword,
    DateTime? createdAt,
    String? occupancyStatus,
    String? tenantFullName,
    String? tenantEmail,
    String? tenantPhone,
    bool clearTenant = false,
    List<UnitResidentMember>? householdResidents,
    Decimal? operationalDuesBalance,
    Decimal? capitalDuesBalance,
  }) {
    return HomeOwnerItem(
      unitId: unitId ?? this.unitId,
      siteId: siteId ?? this.siteId,
      block: block ?? this.block,
      unitNo: unitNo ?? this.unitNo,
      floor: floor ?? this.floor,
      ownerFullName: ownerFullName ?? this.ownerFullName,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      landShare: landShare ?? this.landShare,
      monthlyDues: monthlyDues ?? this.monthlyDues,
      houseType: houseType ?? this.houseType,
      isResident: isResident ?? this.isResident,
      temporaryPassword: temporaryPassword ?? this.temporaryPassword,
      mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      createdAt: createdAt ?? this.createdAt,
      occupancyStatus: occupancyStatus ?? this.occupancyStatus,
      tenantFullName: clearTenant ? null : (tenantFullName ?? this.tenantFullName),
      tenantEmail: clearTenant ? null : (tenantEmail ?? this.tenantEmail),
      tenantPhone: clearTenant ? null : (tenantPhone ?? this.tenantPhone),
      householdResidents: householdResidents ?? this.householdResidents,
      operationalDuesBalance: operationalDuesBalance ?? this.operationalDuesBalance,
      capitalDuesBalance: capitalDuesBalance ?? this.capitalDuesBalance,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'unit_id': unitId,
      'site_id': siteId,
      'block': block,
      'unit_no': unitNo,
      'floor': floor,
      'owner_full_name': ownerFullName,
      'email': email,
      'phone': phone,
      'land_share': landShare,
      'monthly_dues': monthlyDues.toString(),
      'house_type': houseType,
      'is_resident': isResident,
      'temporary_password': temporaryPassword,
      'must_change_password': mustChangePassword,
      'created_at': createdAt.toIso8601String(),
      'occupancy_status': occupancyStatus,
      'tenant_full_name': tenantFullName,
      'tenant_email': tenantEmail,
      'tenant_phone': tenantPhone,
      'household_residents': householdResidents.map((m) => m.toJson()).toList(),
      'operational_dues_balance': operationalDuesBalance.toString(),
      'capital_dues_balance': capitalDuesBalance.toString(),
    };
  }
}

class OccupancyHistoryItem {
  final int id;
  final int unitId;
  final int personId;
  final String personName;
  final String? personPhone;
  final String? personEmail;
  final String role;
  final String startDate;
  final String? endDate;
  final bool isActive;
  final Decimal exitBalance;
  final String? notes;
  final DateTime createdAt;

  const OccupancyHistoryItem({
    required this.id,
    required this.unitId,
    required this.personId,
    required this.personName,
    this.personPhone,
    this.personEmail,
    required this.role,
    required this.startDate,
    this.endDate,
    required this.isActive,
    required this.exitBalance,
    this.notes,
    required this.createdAt,
  });

  factory OccupancyHistoryItem.fromJson(Map<String, dynamic> json) {
    return OccupancyHistoryItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      unitId: (json['unit_id'] as num?)?.toInt() ?? 0,
      personId: (json['person_id'] as num?)?.toInt() ?? 0,
      personName: json['person_name']?.toString() ?? '',
      personPhone: json['person_phone']?.toString(),
      personEmail: json['person_email']?.toString(),
      role: json['role']?.toString() ?? 'TENANT',
      startDate: json['start_date']?.toString() ?? '',
      endDate: json['end_date']?.toString(),
      isActive: json['is_active'] as bool? ?? false,
      exitBalance: Decimal.tryParse(json['exit_balance']?.toString() ?? '0') ?? Decimal.zero,
      notes: json['notes']?.toString(),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  OccupancyHistoryItem copyWith({
    int? id,
    int? unitId,
    int? personId,
    String? personName,
    String? personPhone,
    String? personEmail,
    String? role,
    String? startDate,
    String? endDate,
    bool? isActive,
    Decimal? exitBalance,
    String? notes,
    DateTime? createdAt,
  }) {
    return OccupancyHistoryItem(
      id: id ?? this.id,
      unitId: unitId ?? this.unitId,
      personId: personId ?? this.personId,
      personName: personName ?? this.personName,
      personPhone: personPhone ?? this.personPhone,
      personEmail: personEmail ?? this.personEmail,
      role: role ?? this.role,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      isActive: isActive ?? this.isActive,
      exitBalance: exitBalance ?? this.exitBalance,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}


class ApprovalSuccessInfo {
  final String fullName;
  final String flatDesc;
  final String email;
  final String temporaryPassword;

  const ApprovalSuccessInfo({
    required this.fullName,
    required this.flatDesc,
    required this.email,
    required this.temporaryPassword,
  });
}

// ============================================================================
// Bank Statement Ingestion & Automated Reconciliation Models (STORY-07-02)
// ============================================================================

class BankStatementParsedItem {
  final String transactionId;
  final DateTime date;
  final Decimal amount;
  final String currency;
  final String description;
  final String? senderName;
  final String? senderIban;
  final String? referenceNo;

  const BankStatementParsedItem({
    required this.transactionId,
    required this.date,
    required this.amount,
    required this.currency,
    required this.description,
    this.senderName,
    this.senderIban,
    this.referenceNo,
  });

  factory BankStatementParsedItem.fromJson(Map<String, dynamic> json) {
    return BankStatementParsedItem(
      transactionId: json['transaction_id'] ?? '',
      date: DateTime.tryParse(json['date'] ?? '') ?? DateTime.now(),
      amount: Decimal.tryParse(json['amount']?.toString() ?? '0') ?? Decimal.zero,
      currency: json['currency'] ?? 'TRY',
      description: json['description'] ?? '',
      senderName: json['sender_name'],
      senderIban: json['sender_iban'],
      referenceNo: json['reference_no'],
    );
  }

  BankStatementParsedItem copyWith({
    String? transactionId,
    DateTime? date,
    Decimal? amount,
    String? currency,
    String? description,
    String? senderName,
    String? senderIban,
    String? referenceNo,
  }) {
    return BankStatementParsedItem(
      transactionId: transactionId ?? this.transactionId,
      date: date ?? this.date,
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      description: description ?? this.description,
      senderName: senderName ?? this.senderName,
      senderIban: senderIban ?? this.senderIban,
      referenceNo: referenceNo ?? this.referenceNo,
    );
  }
}

class ReconciliationQueueItem {
  final String matchId;
  final BankStatementParsedItem transaction;
  final String? matchedUnitId;
  final String? matchedBlock;
  final int? matchedUnitNumber;
  final String? matchedResidentName;
  final int confidenceScore;
  final String? matchedDueId;
  final Decimal? outstandingBalance;
  final bool amountMatchesBalance;
  final String status; // "ONAY_BEKLIYOR", "ONAYLANDI", "ESLESTIRILEMEDI"
  final String? notes;

  const ReconciliationQueueItem({
    required this.matchId,
    required this.transaction,
    this.matchedUnitId,
    this.matchedBlock,
    this.matchedUnitNumber,
    this.matchedResidentName,
    required this.confidenceScore,
    this.matchedDueId,
    this.outstandingBalance,
    required this.amountMatchesBalance,
    required this.status,
    this.notes,
  });

  String get matchedUnitDesc {
    if (matchedBlock != null && matchedUnitNumber != null) {
      final clean = matchedBlock!.replaceAll(RegExp(r'\s*blok\b', caseSensitive: false), '').trim();
      return '$clean Blok D:$matchedUnitNumber';
    }
    return 'Belirlenemedi';
  }

  bool get isApproved => status == 'ONAYLANDI';
  bool get isPendingApproval => status == 'ONAY_BEKLIYOR';
  bool get isAlreadyUploaded => status == 'ZATEN_YUKLENDI' || status == 'ZATEN_ODENDI';

  factory ReconciliationQueueItem.fromJson(Map<String, dynamic> json) {
    return ReconciliationQueueItem(
      matchId: json['match_id'] ?? '',
      transaction: BankStatementParsedItem.fromJson(
        Map<String, dynamic>.from(json['transaction'] ?? {}),
      ),
      matchedUnitId: json['matched_unit_id'],
      matchedBlock: json['matched_block'],
      matchedUnitNumber: json['matched_unit_number'],
      matchedResidentName: json['matched_resident_name'],
      confidenceScore: json['confidence_score'] ?? 0,
      matchedDueId: json['matched_due_id'],
      outstandingBalance: json['outstanding_balance'] != null
          ? Decimal.tryParse(json['outstanding_balance'].toString())
          : null,
      amountMatchesBalance: json['amount_matches_balance'] ?? false,
      status: json['status_code'] ?? json['status'] ?? 'ONAY_BEKLIYOR',
      notes: json['notes'],
    );
  }

  ReconciliationQueueItem copyWith({
    String? matchedUnitId,
    String? matchedBlock,
    int? matchedUnitNumber,
    String? matchedResidentName,
    int? confidenceScore,
    String? matchedDueId,
    Decimal? outstandingBalance,
    bool? amountMatchesBalance,
    String? status,
    String? notes,
  }) {
    return ReconciliationQueueItem(
      matchId: matchId,
      transaction: transaction,
      matchedUnitId: matchedUnitId ?? this.matchedUnitId,
      matchedBlock: matchedBlock ?? this.matchedBlock,
      matchedUnitNumber: matchedUnitNumber ?? this.matchedUnitNumber,
      matchedResidentName: matchedResidentName ?? this.matchedResidentName,
      confidenceScore: confidenceScore ?? this.confidenceScore,
      matchedDueId: matchedDueId ?? this.matchedDueId,
      outstandingBalance: outstandingBalance ?? this.outstandingBalance,
      amountMatchesBalance: amountMatchesBalance ?? this.amountMatchesBalance,
      status: status ?? this.status,
      notes: notes ?? this.notes,
    );
  }
}

enum SupportedBank {
  kuveytTurk('KUVEYT_TURK', 'Kuveyt Türk Katılım Bankası', 'EXCEL', '.xlsx'),
  isBankasi('IS_BANKASI', 'Türkiye İş Bankası', 'CSV', '.csv'),
  ziraatBankasi('ZIRAAT_BANKASI', 'Ziraat Bankası', 'MT940', '.sta'),
  garantiBbva('GARANTI_BBVA', 'Garanti BBVA', 'CSV', '.csv'),
  akbank('AKBANK', 'Akbank', 'CSV', '.csv'),
  yapiKredi('YAPI_KREDI', 'Yapı Kredi Bankası', 'EXCEL', '.xlsx'),
  halkbank('HALKBANK', 'Halkbank', 'MT940', '.sta'),
  vakifbank('VAKIFBANK', 'Vakıfbank', 'MT940', '.sta'),
  denizBank('DENIZBANK', 'DenizBank', 'CSV', '.csv'),
  qnbFinansbank('QNB_FINANSBANK', 'QNB Finansbank', 'CSV', '.csv');

  final String code;
  final String displayName;
  final String statementFormat; // 'EXCEL', 'CSV', 'MT940'
  final String fileExtension;

  const SupportedBank(this.code, this.displayName, this.statementFormat, this.fileExtension);

  static SupportedBank? fromCode(String code) {
    for (final b in SupportedBank.values) {
      if (b.code.toUpperCase() == code.toUpperCase()) return b;
    }
    return null;
  }
}

class SiteBankAccount {
  final String id;
  final String siteId;
  final String bankCode;
  final String bankName;
  final String iban;
  final String accountHolder;
  final String statementFormat;
  final bool isActive;
  final String? configuredBy;
  final DateTime updatedAt;

  const SiteBankAccount({
    required this.id,
    required this.siteId,
    required this.bankCode,
    required this.bankName,
    required this.iban,
    required this.accountHolder,
    required this.statementFormat,
    this.isActive = true,
    this.configuredBy,
    required this.updatedAt,
  });

  SupportedBank? get supportedBank => SupportedBank.fromCode(bankCode);

  SiteBankAccount copyWith({
    String? id,
    String? siteId,
    String? bankCode,
    String? bankName,
    String? iban,
    String? accountHolder,
    String? statementFormat,
    bool? isActive,
    String? configuredBy,
    DateTime? updatedAt,
  }) {
    return SiteBankAccount(
      id: id ?? this.id,
      siteId: siteId ?? this.siteId,
      bankCode: bankCode ?? this.bankCode,
      bankName: bankName ?? this.bankName,
      iban: iban ?? this.iban,
      accountHolder: accountHolder ?? this.accountHolder,
      statementFormat: statementFormat ?? this.statementFormat,
      isActive: isActive ?? this.isActive,
      configuredBy: configuredBy ?? this.configuredBy,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class ReconciliationHostMessage {
  final String messageId;
  final String matchId;
  final String block;
  final int unitNo;
  final String residentName;
  final Decimal amount;
  final String messageText;
  final DateTime sentAt;

  const ReconciliationHostMessage({
    required this.messageId,
    required this.matchId,
    required this.block,
    required this.unitNo,
    required this.residentName,
    required this.amount,
    required this.messageText,
    required this.sentAt,
  });

  String get flatDesc => '$block Blok D:$unitNo';
}

class ManualAssignmentResult {
  final FlatPaymentStatus flat;
  final bool sendOptionalMessage;
  final String? optionalMessageText;
  final bool rememberSenderIban;

  const ManualAssignmentResult({
    required this.flat,
    this.sendOptionalMessage = false,
    this.optionalMessageText,
    this.rememberSenderIban = true,
  });
}

class RegisteredSenderIban {
  final String senderIban;
  final String formattedIban;
  final String? label;
  final String? bankName;

  const RegisteredSenderIban({
    required this.senderIban,
    required this.formattedIban,
    this.label,
    this.bankName,
  });

  factory RegisteredSenderIban.fromJson(Map<String, dynamic> json) {
    return RegisteredSenderIban(
      senderIban: json['sender_iban'] ?? '',
      formattedIban: json['formatted_iban'] ?? json['sender_iban'] ?? '',
      label: json['label'],
      bankName: json['bank_name'],
    );
  }

  Map<String, dynamic> toJson() => {
    'sender_iban': senderIban,
    'formatted_iban': formattedIban,
    'label': label,
    'bank_name': bankName,
  };
}

class UnitMatchingCriteria {
  final String unitId;
  final String block;
  final int unitNumber;
  final String residentName;
  final String? virtualIban;
  final List<RegisteredSenderIban> rememberedIbans;
  final List<String> registeredPayerNames;
  final String recommendedDescription;

  const UnitMatchingCriteria({
    required this.unitId,
    required this.block,
    required this.unitNumber,
    required this.residentName,
    this.virtualIban,
    required this.rememberedIbans,
    required this.registeredPayerNames,
    required this.recommendedDescription,
  });

  String get flatDesc => '$block Blok D:$unitNumber';

  factory UnitMatchingCriteria.fromJson(Map<String, dynamic> json) {
    return UnitMatchingCriteria(
      unitId: json['unit_id'] ?? '',
      block: json['block'] ?? 'A',
      unitNumber: json['unit_number'] ?? 1,
      residentName: json['resident_name'] ?? '',
      virtualIban: json['virtual_iban'],
      rememberedIbans: (json['remembered_ibans'] as List<dynamic>?)
              ?.map((i) => RegisteredSenderIban.fromJson(Map<String, dynamic>.from(i)))
              .toList() ??
          [],
      registeredPayerNames: (json['registered_payer_names'] as List<dynamic>?)
              ?.map((n) => n.toString())
              .toList() ??
          [],
      recommendedDescription: json['recommended_description'] ?? '',
    );
  }

  UnitMatchingCriteria copyWith({
    List<RegisteredSenderIban>? rememberedIbans,
    List<String>? registeredPayerNames,
  }) {
    return UnitMatchingCriteria(
      unitId: unitId,
      block: block,
      unitNumber: unitNumber,
      residentName: residentName,
      virtualIban: virtualIban,
      rememberedIbans: rememberedIbans ?? this.rememberedIbans,
      registeredPayerNames: registeredPayerNames ?? this.registeredPayerNames,
      recommendedDescription: recommendedDescription,
    );
  }
}

class DuesPeriodItem {
  final String id;
  final String siteId;
  final String periodName;
  final DateTime dueDate;
  final String status;
  final DateTime? createdAt;

  const DuesPeriodItem({
    required this.id,
    required this.siteId,
    required this.periodName,
    required this.dueDate,
    this.status = 'ACTIVE',
    this.createdAt,
  });

  factory DuesPeriodItem.fromJson(Map<String, dynamic> json) {
    return DuesPeriodItem(
      id: json['id']?.toString() ?? '',
      siteId: json['site_id']?.toString() ?? '',
      periodName: json['period_name']?.toString() ?? '',
      dueDate: json['due_date'] != null
          ? DateTime.tryParse(json['due_date'].toString()) ?? DateTime.now()
          : DateTime.now(),
      status: json['status']?.toString() ?? 'ACTIVE',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'site_id': siteId,
    'period_name': periodName,
    'due_date': dueDate.toIso8601String().split('T').first,
    'status': status,
  };
}


