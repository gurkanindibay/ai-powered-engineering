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
  final String siteName;
  final String block;
  final int unitNo;
  final int floor;
  final int landShare;
  final String ownerName;
  final String tenantName;

  const ApartmentUnit({
    required this.id,
    required this.siteName,
    required this.block,
    required this.unitNo,
    required this.floor,
    required this.landShare,
    required this.ownerName,
    required this.tenantName,
  });

  // Backwards compatibility getters
  String get siteAdi => siteName;
  String get blok => block;
  int get daireNo => unitNo;
  int get kat => floor;
  int get arsaPayi => landShare;
  String get malikAdi => ownerName;
  String get kiraciAdi => tenantName;
}

// Backwards compatibility alias
typedef Daire = ApartmentUnit;

class ComplexCollectionSummary {
  final Decimal totalExpected;
  final Decimal totalCollected;
  final Decimal totalOverdueWithInterest;
  final int paidUnitsCount;
  final int overdueUnitsCount;
  final int totalUnitsCount;

  ComplexCollectionSummary({
    Decimal? totalExpected,
    Decimal? totalCollected,
    Decimal? totalOverdueWithInterest,
    this.paidUnitsCount = 18,
    this.overdueUnitsCount = 6,
    this.totalUnitsCount = 24,
  })  : totalExpected = totalExpected ?? Decimal.parse('120000.00'),
        totalCollected = totalCollected ?? Decimal.parse('96000.00'),
        totalOverdueWithInterest = totalOverdueWithInterest ?? Decimal.parse('24423.33');

  int get collectionRatePercent {
    if (totalExpected == Decimal.zero) return 0;
    final ratio = (totalCollected * Decimal.fromInt(100) / totalExpected);
    return ratio.toDecimal().toDouble().round();
  }

  int get collectionPercentage => collectionRatePercent;
  Decimal get totalOverdueAmount => totalOverdueWithInterest;

  ComplexCollectionSummary copyWith({
    Decimal? totalExpected,
    Decimal? totalCollected,
    Decimal? totalOverdueWithInterest,
    int? paidUnitsCount,
    int? overdueUnitsCount,
    int? totalUnitsCount,
  }) {
    return ComplexCollectionSummary(
      totalExpected: totalExpected ?? this.totalExpected,
      totalCollected: totalCollected ?? this.totalCollected,
      totalOverdueWithInterest: totalOverdueWithInterest ?? this.totalOverdueWithInterest,
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
  final int daysOverdue;
  final bool isPaid;
  final String? paidDateStr;

  const FlatPaymentStatus({
    required this.id,
    required this.block,
    required this.unitNo,
    required this.residentName,
    required this.amountDue,
    required this.daysOverdue,
    required this.isPaid,
    this.paidDateStr,
  });

  String get flatDesc => '$block Blok D:$unitNo';
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
  });
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
    required this.phone,
    required this.email,
    required this.isOwner,
    required this.permissionScope,
  });
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

  const ProvisionedSiteCredentials({
    required this.siteId,
    required this.siteName,
    required this.adminName,
    required this.adminEmail,
    required this.temporaryPassword,
    required this.planType,
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

  const ProvisionedHomeOwnerCredentials({
    required this.block,
    required this.unitNo,
    required this.ownerName,
    required this.email,
    required this.phone,
    required this.temporaryPassword,
    required this.isResident,
    required this.duesAmount,
  });
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
