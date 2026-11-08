import 'package:decimal/decimal.dart';
import '../formatting/money_formatter.dart';

enum DebtStatus {
  pending('Pending'),
  overdue('Overdue'),
  paid('Paid');

  final String label;
  const DebtStatus(this.label);
}

enum DebtorType {
  tenant('TENANT', 'Kiracı'),
  owner('OWNER', 'Kat Maliki');

  final String code;
  final String label;
  const DebtorType(this.code, this.label);

  static DebtorType fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'TENANT') return DebtorType.tenant;
    return DebtorType.owner;
  }
}

enum ExpenseType {
  operationalDues('OPERATIONAL_DUES', 'İşletme Projesi (Genel Aidat)'),
  capitalDues('CAPITAL_DUES', 'Yatırım / Demirbaş Bütçesi');

  final String code;
  final String label;
  const ExpenseType(this.code, this.label);

  static ExpenseType fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'CAPITAL_DUES' || upper == 'DEMIRBAS' || upper == 'CAPITAL') {
      return ExpenseType.capitalDues;
    }
    return ExpenseType.operationalDues;
  }
}

enum OccupancyStatus {
  ownerOccupied('OWNER_OCCUPIED', 'Ev Sahibi'),
  tenantOccupied('TENANT_OCCUPIED', 'Kiracı'),
  vacant('VACANT', 'Boş');

  final String code;
  final String label;
  const OccupancyStatus(this.code, this.label);

  static OccupancyStatus fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'TENANT_OCCUPIED' || upper == 'TENANT') {
      return OccupancyStatus.tenantOccupied;
    }
    if (upper == 'VACANT') {
      return OccupancyStatus.vacant;
    }
    return OccupancyStatus.ownerOccupied;
  }
}

enum DuesPeriodStatus {
  active('ACTIVE', 'Aktif'),
  closed('CLOSED', 'Kapatıldı'),
  draft('DRAFT', 'Taslak');

  final String code;
  final String label;
  const DuesPeriodStatus(this.code, this.label);

  static DuesPeriodStatus fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'CLOSED') return DuesPeriodStatus.closed;
    if (upper == 'DRAFT') return DuesPeriodStatus.draft;
    return DuesPeriodStatus.active;
  }
}

enum TenantSiteStatus {
  active('ACTIVE', 'Aktif'),
  suspended('SUSPENDED', 'Askıda'),
  deleted('DELETED', 'Silindi');

  final String code;
  final String label;
  const TenantSiteStatus(this.code, this.label);

  static TenantSiteStatus fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'SUSPENDED') return TenantSiteStatus.suspended;
    if (upper == 'DELETED') return TenantSiteStatus.deleted;
    return TenantSiteStatus.active;
  }
}

enum TenantPlanType {
  standard('STANDARD', 'Standart'),
  premium('PREMIUM', 'Premium'),
  enterprise('ENTERPRISE', 'Kurumsal'),
  community('COMMUNITY', 'Topluluk');

  final String code;
  final String label;
  const TenantPlanType(this.code, this.label);

  static TenantPlanType fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'PREMIUM') return TenantPlanType.premium;
    if (upper == 'ENTERPRISE') return TenantPlanType.enterprise;
    if (upper == 'COMMUNITY') return TenantPlanType.community;
    return TenantPlanType.standard;
  }
}

enum BankStatementFormat {
  excel('EXCEL', 'Excel (.xlsx/.xls)'),
  csv('CSV', 'CSV Metin Dosyası'),
  mt940('MT940', 'SWIFT MT940'),
  auto('AUTO', 'Otomatik Tanıma');

  final String code;
  final String label;
  const BankStatementFormat(this.code, this.label);

  static BankStatementFormat fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'CSV') return BankStatementFormat.csv;
    if (upper == 'MT940') return BankStatementFormat.mt940;
    if (upper == 'AUTO') return BankStatementFormat.auto;
    return BankStatementFormat.excel;
  }
}

enum ReconciliationStatus {
  pending('ONAY_BEKLIYOR', 'Onay Bekliyor'),
  approved('ONAYLANDI', 'Onaylandı'),
  unmatched('ESLESTIRILEMEDI', 'Eşleştirilemedi'),
  expense('GIDER', 'Gider'),
  alreadyUploaded('ZATEN_YUKLENDI', 'Zaten Yüklendi');

  final String code;
  final String label;
  const ReconciliationStatus(this.code, this.label);

  static ReconciliationStatus fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'ONAYLANDI' || upper == 'APPROVED') return ReconciliationStatus.approved;
    if (upper == 'ESLESTIRILEMEDI' || upper == 'UNMATCHED') return ReconciliationStatus.unmatched;
    if (upper == 'GIDER' || upper == 'EXPENSE') return ReconciliationStatus.expense;
    if (upper == 'ZATEN_YUKLENDI' || upper == 'ZATEN_ODENDI' || upper == 'ALREADY_UPLOADED') {
      return ReconciliationStatus.alreadyUploaded;
    }
    return ReconciliationStatus.pending;
  }
}

enum PaymentChannel {
  creditCard('CREDIT_CARD', 'Kredi Kartı'),
  bankTransfer('BANK_TRANSFER', 'Banka Havalesi / EFT'),
  bankStatement('BANK_STATEMENT', 'Banka Ekstresi'),
  fast('FAST', 'FAST Anlık Transfer'),
  cash('CASH', 'Nakit'),
  manualCash('MANUAL_CASH', 'Elden Nakit'),
  virtualIban('VIRTUAL_IBAN', 'Sanal IBAN'),
  interLedger('INTER_LEDGER', 'Hesaplar Arası Virman'),
  onlinePayment('ONLINE_PAYMENT', 'Online Ödeme'),
  other('OTHER', 'Diğer');

  final String code;
  final String label;
  const PaymentChannel(this.code, this.label);

  static PaymentChannel fromCode(String? code) {
    final upper = code?.toUpperCase() ?? '';
    if (upper.contains('CARD') || upper.contains('KART')) return PaymentChannel.creditCard;
    if (upper.contains('STATEMENT') || upper.contains('EKSTRE')) return PaymentChannel.bankStatement;
    if (upper.contains('ONLINE')) return PaymentChannel.onlinePayment;
    if (upper.contains('VIRTUAL') || upper.contains('VIBAN')) return PaymentChannel.virtualIban;
    if (upper.contains('FAST')) return PaymentChannel.fast;
    if (upper.contains('INTER_LEDGER')) return PaymentChannel.interLedger;
    if (upper.contains('MANUAL')) return PaymentChannel.manualCash;
    if (upper.contains('CASH') || upper.contains('NAKIT')) return PaymentChannel.cash;
    if (upper.contains('BANK') || upper.contains('HAVALE') || upper.contains('EFT') || upper.contains('TRANSFER')) {
      return PaymentChannel.bankTransfer;
    }
    return PaymentChannel.other;
  }
}

enum SettlementStatus {
  settled('SETTLED', 'Eşleşti ve Kapandı'),
  pending('PENDING', 'Beklemede'),
  unmatched('UNMATCHED', 'Eşleşmedi'),
  reversed('REVERSED', 'İptal / İade Edildi');

  final String code;
  final String label;
  const SettlementStatus(this.code, this.label);

  static SettlementStatus fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'PENDING') return SettlementStatus.pending;
    if (upper == 'UNMATCHED') return SettlementStatus.unmatched;
    if (upper == 'REVERSED') return SettlementStatus.reversed;
    return SettlementStatus.settled;
  }
}

enum CapitalProjectCategory {
  elevator('ELEVATOR', 'Asansör & Revizyon'),
  facadeInsulation('FACADE_INSULATION', 'Çatı & Dış Cephe Yalıtım'),
  roofWaterproofing('ROOF_WATERPROOFING', 'Çatı İzolasyon ve Onarım'),
  generator('GENERATOR', 'Jeneratör & Enerji'),
  securitySystem('SECURITY_SYSTEM', 'Kamera & Güvenlik'),
  fireSafety('FIRE_SAFETY', 'Yangın Güvenlik Tesisatı'),
  other('OTHER', 'Diğer Demirbaş');

  final String code;
  final String label;
  const CapitalProjectCategory(this.code, this.label);

  static CapitalProjectCategory fromCode(String? code) {
    final upper = code?.toUpperCase() ?? '';
    if (upper.contains('ELEVATOR') || upper.contains('ASANSOR')) return CapitalProjectCategory.elevator;
    if (upper.contains('FACADE') || upper.contains('MANTOLAMA')) return CapitalProjectCategory.facadeInsulation;
    if (upper.contains('ROOF') || upper.contains('CATI')) return CapitalProjectCategory.roofWaterproofing;
    if (upper.contains('GENERATOR') || upper.contains('JENERATOR')) return CapitalProjectCategory.generator;
    if (upper.contains('SECURITY') || upper.contains('GUVENLIK') || upper.contains('KAMERA')) {
      return CapitalProjectCategory.securitySystem;
    }
    if (upper.contains('FIRE') || upper.contains('YANGIN')) return CapitalProjectCategory.fireSafety;
    return CapitalProjectCategory.other;
  }
}

enum AllocationBasis {
  byLandShare('BY_LAND_SHARE', 'Arsa Payı Oranında (KMK 20)'),
  equalPerUnit('EQUAL_PER_UNIT', 'Eşit Paylaşım');

  final String code;
  final String label;
  const AllocationBasis(this.code, this.label);

  static AllocationBasis fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'EQUAL_PER_UNIT' || upper == 'EQUAL') return AllocationBasis.equalPerUnit;
    return AllocationBasis.byLandShare;
  }
}

enum CapitalProjectStatus {
  active('ACTIVE', 'Devam Ediyor'),
  completed('COMPLETED', 'Tamamlandı'),
  cancelled('CANCELLED', 'İptal Edildi'),
  draft('DRAFT', 'Taslak');

  final String code;
  final String label;
  const CapitalProjectStatus(this.code, this.label);

  static CapitalProjectStatus fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'COMPLETED') return CapitalProjectStatus.completed;
    if (upper == 'CANCELLED') return CapitalProjectStatus.cancelled;
    if (upper == 'DRAFT') return CapitalProjectStatus.draft;
    return CapitalProjectStatus.active;
  }
}

enum DisbursementMethod {
  bankTransfer('BANK_TRANSFER', 'Banka Transferi / Havale'),
  fast('FAST', 'FAST Transfer'),
  cash('CASH', 'Nakit'),
  check('CHECK', 'Çek');

  final String code;
  final String label;
  const DisbursementMethod(this.code, this.label);

  static DisbursementMethod fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'FAST') return DisbursementMethod.fast;
    if (upper == 'CASH') return DisbursementMethod.cash;
    if (upper == 'CHECK') return DisbursementMethod.check;
    return DisbursementMethod.bankTransfer;
  }
}

enum RegistrationStatus {
  pending('PENDING', 'Onay Bekliyor'),
  approved('APPROVED', 'Onaylandı'),
  rejected('REJECTED', 'Reddedildi');

  final String code;
  final String label;
  const RegistrationStatus(this.code, this.label);

  static RegistrationStatus fromCode(String? code) {
    final upper = code?.toUpperCase();
    if (upper == 'APPROVED') return RegistrationStatus.approved;
    if (upper == 'REJECTED') return RegistrationStatus.rejected;
    return RegistrationStatus.pending;
  }
}


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
  final DebtorType debtorType;
  final ExpenseType expenseType;

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
    this.debtorType = DebtorType.tenant,
    this.expenseType = ExpenseType.operationalDues,
  });

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
    DebtorType? debtorType,
    ExpenseType? expenseType,
  }) {
    return DuesLiability(
      id: id ?? this.id,
      unitId: unitId ?? this.unitId,
      period: period ?? this.period,
      principalAmount: principalAmount ?? this.principalAmount,
      delayPenalty: delayPenalty ?? this.delayPenalty,
      totalAmount: totalAmount ?? this.totalAmount,
      dueDate: dueDate ?? this.dueDate,
      daysOverdue: daysOverdue ?? this.daysOverdue,
      status: status ?? this.status,
      debtorType: debtorType ?? this.debtorType,
      expenseType: expenseType ?? this.expenseType,
    );
  }
}


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

  Decimal get advanceBalance => advancePayment ?? Decimal.zero;
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


class AccountTransactionItem {
  final String id;
  final String title;
  final String subtitle;
  final Decimal amount;
  final String date;
  final bool isCredit;
  /// The receipt the backend issued for this payment; `id` is the bank's transaction id.
  final String? receiptNumber;

  const AccountTransactionItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.date,
    required this.isCredit,
    this.receiptNumber,
  });

  String get amountStr => isCredit ? MoneyFormatter.formatCredit(amount) : MoneyFormatter.format(amount.abs());

  factory AccountTransactionItem.fromJson(Map<String, dynamic> json) {
    return AccountTransactionItem(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? 'Aidat Hareketi',
      subtitle: json['subtitle'] as String? ?? '',
      amount: Decimal.tryParse(json['amount']?.toString() ?? '0') ?? Decimal.zero,
      date: json['date'] as String? ?? 'Bugün',
      isCredit: json['is_credit'] as bool? ?? false,
      receiptNumber: json['receipt_number'] as String?,
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

  TenantSiteStatus get siteStatus => TenantSiteStatus.fromCode(status);
  TenantPlanType get plan => TenantPlanType.fromCode(planType);

  /// Invariant: A site has actions if it has registered units, financial collection volume,
  /// or logged operational actions. Sites with hasActions == false are eligible for deletion.
  bool get hasActions => actionCount > 0 || totalUnits > 0 || monthlyCollectionVolume > Decimal.zero;

  TenantSiteItem copyWith({
    String? id,
    String? name,
    String? city,
    String? address,
    String? status,
    String? planType,
    int? totalUnits,
    Decimal? monthlyCollectionVolume,
    String? adminName,
    String? adminEmail,
    String? adminPhone,
    int? actionCount,
    List<String>? blocks,
  }) {
    return TenantSiteItem(
      id: id ?? this.id,
      name: name ?? this.name,
      city: city ?? this.city,
      address: address ?? this.address,
      status: status ?? this.status,
      planType: planType ?? this.planType,
      totalUnits: totalUnits ?? this.totalUnits,
      monthlyCollectionVolume: monthlyCollectionVolume ?? this.monthlyCollectionVolume,
      adminName: adminName ?? this.adminName,
      adminEmail: adminEmail ?? this.adminEmail,
      adminPhone: adminPhone ?? this.adminPhone,
      actionCount: actionCount ?? this.actionCount,
      blocks: blocks ?? this.blocks,
    );
  }
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
  final String? virtualIban;
  final List<UnitResidentMember> householdResidents;
  final Decimal? _operationalDuesBalance;
  Decimal get operationalDuesBalance => _operationalDuesBalance ?? Decimal.zero;
  final Decimal? _capitalDuesBalance;
  Decimal get capitalDuesBalance => _capitalDuesBalance ?? Decimal.zero;

  /// Owner + tenant advance (avans) balance of the unit, from the backend.
  final Decimal? _advanceBalance;
  Decimal get advanceBalance => _advanceBalance ?? Decimal.zero;
  final String? primaryResponsibleName;
  final String? primaryResponsibleRole;
  final String? primaryResponsiblePhone;
  final String? primaryResponsibleEmail;

  OccupancyStatus get occupancy => OccupancyStatus.fromCode(occupancyStatus);

  bool get isTenantOccupied => occupancy == OccupancyStatus.tenantOccupied || (tenantFullName != null && tenantFullName!.isNotEmpty);
  bool get isVacant => occupancy == OccupancyStatus.vacant;
  bool get isOwnerOccupied => occupancy == OccupancyStatus.ownerOccupied;

  String get activeResponsibleResidentName {
    if (primaryResponsibleName != null && primaryResponsibleName!.isNotEmpty) {
      return primaryResponsibleName!;
    }
    if (isTenantOccupied) {
      return tenantFullName ?? 'Kiracı';
    }
    if (isVacant) {
      return 'Boş Daire';
    }
    return ownerFullName.isNotEmpty ? ownerFullName : 'Kat Maliki';
  }

  String get activeResponsibleRoleLabel {
    if (primaryResponsibleRole != null && primaryResponsibleRole!.isNotEmpty) {
      switch (primaryResponsibleRole) {
        case 'TENANT':
          return 'Kiracı (Aktif Sorumlu)';
        case 'OWNER':
          return 'Kat Maliki (Aktif Sorumlu)';
        case 'RESIDENT':
          return 'Hane Sakini (Aktif Sorumlu)';
        default:
          return primaryResponsibleRole!;
      }
    }
    if (isTenantOccupied) {
      return 'Kiracı (Aktif Sorumlu)';
    }
    if (isVacant) {
      return 'Boş Daire';
    }
    return 'Kat Maliki (Aktif Sorumlu)';
  }

  String get activeResponsiblePhone {
    if (primaryResponsiblePhone != null && primaryResponsiblePhone!.isNotEmpty) {
      return primaryResponsiblePhone!;
    }
    if (primaryResponsibleRole == 'OWNER') {
      return phone;
    }
    if (primaryResponsibleRole == 'TENANT') {
      return tenantPhone ?? phone;
    }
    if (tenantPhone != null && tenantPhone!.isNotEmpty) {
      return tenantPhone!;
    }
    return phone;
  }

  String get activeResponsibleEmail {
    if (primaryResponsibleEmail != null && primaryResponsibleEmail!.isNotEmpty) {
      return primaryResponsibleEmail!;
    }
    if (primaryResponsibleRole == 'OWNER') {
      return email;
    }
    if (primaryResponsibleRole == 'TENANT') {
      return tenantEmail ?? email;
    }
    if (tenantEmail != null && tenantEmail!.isNotEmpty) {
      return tenantEmail!;
    }
    return email;
  }

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
    this.virtualIban,
    this.householdResidents = const [],
    Decimal? operationalDuesBalance,
    Decimal? capitalDuesBalance,
    Decimal? advanceBalance,
    this.primaryResponsibleName,
    this.primaryResponsibleRole,
    this.primaryResponsiblePhone,
    this.primaryResponsibleEmail,
  }) : _operationalDuesBalance = operationalDuesBalance,
       _capitalDuesBalance = capitalDuesBalance,
       _advanceBalance = advanceBalance;

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
      virtualIban: json['virtual_iban']?.toString(),
      householdResidents: (json['household_residents'] as List<dynamic>?)
              ?.map((m) => UnitResidentMember.fromJson(m as Map<String, dynamic>))
              .toList() ??
          const [],
      operationalDuesBalance: Decimal.tryParse(json['operational_dues_balance']?.toString() ?? '0') ?? Decimal.zero,
      capitalDuesBalance: Decimal.tryParse(json['capital_dues_balance']?.toString() ?? '0') ?? Decimal.zero,
      advanceBalance: Decimal.tryParse(json['advance_balance']?.toString() ?? '0') ?? Decimal.zero,
      primaryResponsibleName: json['primary_responsible_name']?.toString(),
      primaryResponsibleRole: json['primary_responsible_role']?.toString(),
      primaryResponsiblePhone: json['primary_responsible_phone']?.toString(),
      primaryResponsibleEmail: json['primary_responsible_email']?.toString(),
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
    String? virtualIban,
    bool clearTenant = false,
    List<UnitResidentMember>? householdResidents,
    Decimal? operationalDuesBalance,
    Decimal? capitalDuesBalance,
    Decimal? advanceBalance,
    String? primaryResponsibleName,
    String? primaryResponsibleRole,
    String? primaryResponsiblePhone,
    String? primaryResponsibleEmail,
    bool clearPrimaryResponsible = false,
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
      virtualIban: virtualIban ?? this.virtualIban,
      householdResidents: householdResidents ?? this.householdResidents,
      operationalDuesBalance: operationalDuesBalance ?? this.operationalDuesBalance,
      capitalDuesBalance: capitalDuesBalance ?? this.capitalDuesBalance,
      advanceBalance: advanceBalance ?? this.advanceBalance,
      primaryResponsibleName: clearPrimaryResponsible ? null : (primaryResponsibleName ?? this.primaryResponsibleName),
      primaryResponsibleRole: clearPrimaryResponsible ? null : (primaryResponsibleRole ?? this.primaryResponsibleRole),
      primaryResponsiblePhone: clearPrimaryResponsible ? null : (primaryResponsiblePhone ?? this.primaryResponsiblePhone),
      primaryResponsibleEmail: clearPrimaryResponsible ? null : (primaryResponsibleEmail ?? this.primaryResponsibleEmail),
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
      'primary_responsible_name': primaryResponsibleName,
      'primary_responsible_role': primaryResponsibleRole,
      'primary_responsible_phone': primaryResponsiblePhone,
      'primary_responsible_email': primaryResponsibleEmail,
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

  DebtorType get debtorRole => DebtorType.fromCode(role);

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

  ReconciliationStatus get reconciliationStatus => ReconciliationStatus.fromCode(status);

  bool get isApproved => reconciliationStatus == ReconciliationStatus.approved;
  bool get isPendingApproval => reconciliationStatus == ReconciliationStatus.pending;
  bool get isAlreadyUploaded => reconciliationStatus == ReconciliationStatus.alreadyUploaded;

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

  BankStatementFormat get format => BankStatementFormat.fromCode(statementFormat);

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
  BankStatementFormat get format => BankStatementFormat.fromCode(statementFormat);

  factory SiteBankAccount.fromJson(Map<String, dynamic> json) {
    return SiteBankAccount(
      id: json['id']?.toString() ?? '',
      siteId: json['site_id']?.toString() ?? '',
      bankCode: json['bank_code']?.toString() ?? '',
      bankName: json['bank_name']?.toString() ?? '',
      iban: json['iban']?.toString() ?? '',
      accountHolder: json['account_holder']?.toString() ?? '',
      statementFormat: json['statement_format']?.toString() ?? 'EXCEL',
      isActive: json['is_active'] as bool? ?? true,
      configuredBy: json['configured_by']?.toString(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'site_id': siteId,
    'bank_code': bankCode,
    'bank_name': bankName,
    'iban': iban,
    'account_holder': accountHolder,
    'statement_format': statementFormat,
    'is_active': isActive,
    'configured_by': configuredBy,
    'updated_at': updatedAt.toIso8601String(),
  };

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

  DuesPeriodStatus get periodStatus => DuesPeriodStatus.fromCode(status);
  bool get isActive => periodStatus == DuesPeriodStatus.active;

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

class AllocationBreakdownItemDto {
  final String? dueId;
  final String period;
  final String expenseType;
  final Decimal principalPaid;
  final Decimal penaltyPaid;

  const AllocationBreakdownItemDto({
    this.dueId,
    required this.period,
    required this.expenseType,
    required this.principalPaid,
    required this.penaltyPaid,
  });

  ExpenseType get type => ExpenseType.fromCode(expenseType);

  factory AllocationBreakdownItemDto.fromJson(Map<String, dynamic> json) {
    return AllocationBreakdownItemDto(
      dueId: json['due_id']?.toString(),
      period: json['period']?.toString() ?? '',
      expenseType: json['expense_type']?.toString() ?? 'OPERATIONAL_DUES',
      principalPaid: Decimal.tryParse(json['principal_paid']?.toString() ?? '0') ?? Decimal.zero,
      penaltyPaid: Decimal.tryParse(json['penalty_paid']?.toString() ?? '0') ?? Decimal.zero,
    );
  }

  Map<String, dynamic> toJson() => {
    'due_id': dueId,
    'period': period,
    'expense_type': expenseType,
    'principal_paid': principalPaid.toString(),
    'penalty_paid': penaltyPaid.toString(),
  };
}

class PaymentReceiptDto {
  final int id;
  final String siteId;
  final String unitId;
  final String receiptNumber;
  final int sequenceNumber;
  final String payerName;
  final String payerRole;
  final String? onBehalfOfName;
  final String? onBehalfOfRole;
  final Decimal totalAmount;
  final String paymentChannel;
  final String? channelReference;
  final Decimal allocatedPrincipal;
  final Decimal allocatedPenalty;
  final Decimal allocatedAdvance;
  final List<AllocationBreakdownItemDto> allocationBreakdown;
  final bool isRentOffsetEligible;
  final String? legalStatutoryNote;
  final String verificationHash;
  final DateTime issuedAt;

  const PaymentReceiptDto({
    required this.id,
    required this.siteId,
    required this.unitId,
    required this.receiptNumber,
    required this.sequenceNumber,
    required this.payerName,
    required this.payerRole,
    this.onBehalfOfName,
    this.onBehalfOfRole,
    required this.totalAmount,
    required this.paymentChannel,
    this.channelReference,
    required this.allocatedPrincipal,
    required this.allocatedPenalty,
    required this.allocatedAdvance,
    this.allocationBreakdown = const [],
    this.isRentOffsetEligible = false,
    this.legalStatutoryNote,
    required this.verificationHash,
    required this.issuedAt,
  });

  DebtorType get payerType => DebtorType.fromCode(payerRole);
  DebtorType? get onBehalfOfType => onBehalfOfRole != null ? DebtorType.fromCode(onBehalfOfRole) : null;
  PaymentChannel get channel => PaymentChannel.fromCode(paymentChannel);

  factory PaymentReceiptDto.fromJson(Map<String, dynamic> json) {
    var rawList = json['allocation_breakdown'];
    List<AllocationBreakdownItemDto> breakdown = [];
    if (rawList is List) {
      breakdown = rawList
          .map((i) => AllocationBreakdownItemDto.fromJson(i as Map<String, dynamic>))
          .toList();
    }

    return PaymentReceiptDto(
      id: (json['id'] as num?)?.toInt() ?? 0,
      siteId: json['site_id']?.toString() ?? '',
      unitId: json['unit_id']?.toString() ?? '',
      receiptNumber: json['receipt_number']?.toString() ?? '',
      sequenceNumber: (json['sequence_number'] as num?)?.toInt() ?? 0,
      payerName: json['payer_name']?.toString() ?? '',
      payerRole: json['payer_role']?.toString() ?? 'TENANT',
      onBehalfOfName: json['on_behalf_of_name']?.toString(),
      onBehalfOfRole: json['on_behalf_of_role']?.toString(),
      totalAmount: Decimal.tryParse(json['total_amount']?.toString() ?? '0') ?? Decimal.zero,
      paymentChannel: json['payment_channel']?.toString() ?? 'MANUAL_CASH',
      channelReference: json['channel_reference']?.toString(),
      allocatedPrincipal: Decimal.tryParse(json['allocated_principal']?.toString() ?? '0') ?? Decimal.zero,
      allocatedPenalty: Decimal.tryParse(json['allocated_penalty']?.toString() ?? '0') ?? Decimal.zero,
      allocatedAdvance: Decimal.tryParse(json['allocated_advance']?.toString() ?? '0') ?? Decimal.zero,
      allocationBreakdown: breakdown,
      isRentOffsetEligible: json['is_rent_offset_eligible'] == true,
      legalStatutoryNote: json['legal_statutory_note']?.toString(),
      verificationHash: json['verification_hash']?.toString() ?? '',
      issuedAt: json['issued_at'] != null
          ? DateTime.tryParse(json['issued_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

class PaymentEntryDto {
  final int id;
  final String siteId;
  final String unitId;
  final String? unitLabel;
  final String payerName;
  final String payerRole;
  final int? receiptId;
  final String? receiptNumber;
  final Decimal amount;
  final String paymentChannel;
  final String settlementStatus;
  final String? description;
  final String? externalReference;
  final DateTime paymentDate;
  final DateTime createdAt;

  DebtorType get payerType => DebtorType.fromCode(payerRole);
  PaymentChannel get channel => PaymentChannel.fromCode(paymentChannel);
  SettlementStatus get settlement => SettlementStatus.fromCode(settlementStatus);

  const PaymentEntryDto({
    required this.id,
    required this.siteId,
    required this.unitId,
    this.unitLabel,
    required this.payerName,
    required this.payerRole,
    this.receiptId,
    this.receiptNumber,
    required this.amount,
    required this.paymentChannel,
    required this.settlementStatus,
    this.description,
    this.externalReference,
    required this.paymentDate,
    required this.createdAt,
  });

  factory PaymentEntryDto.fromJson(Map<String, dynamic> json) {
    return PaymentEntryDto(
      id: (json['id'] as num?)?.toInt() ?? 0,
      siteId: json['site_id']?.toString() ?? '',
      unitId: json['unit_id']?.toString() ?? '',
      unitLabel: json['unit_label']?.toString(),
      payerName: json['payer_name']?.toString() ?? '',
      payerRole: json['payer_role']?.toString() ?? 'TENANT',
      receiptId: (json['receipt_id'] as num?)?.toInt(),
      receiptNumber: json['receipt_number']?.toString(),
      amount: Decimal.tryParse(json['amount']?.toString() ?? '0') ?? Decimal.zero,
      paymentChannel: json['payment_channel']?.toString() ?? 'MANUAL_CASH',
      settlementStatus: json['settlement_status']?.toString() ?? 'SETTLED',
      description: json['description']?.toString(),
      externalReference: json['external_reference']?.toString(),
      paymentDate: json['payment_date'] != null
          ? DateTime.tryParse(json['payment_date'].toString()) ?? DateTime.now()
          : DateTime.now(),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

class PaymentStreamResponseDto {
  final List<PaymentEntryDto> entries;
  final Decimal totalVolume;
  final Decimal settledVolume;
  final Decimal unmatchedVolume;
  final int totalCount;

  const PaymentStreamResponseDto({
    required this.entries,
    required this.totalVolume,
    required this.settledVolume,
    required this.unmatchedVolume,
    required this.totalCount,
  });

  factory PaymentStreamResponseDto.fromJson(Map<String, dynamic> json) {
    var rawEntries = json['entries'];
    List<PaymentEntryDto> list = [];
    if (rawEntries is List) {
      list = rawEntries
          .map((e) => PaymentEntryDto.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    return PaymentStreamResponseDto(
      entries: list,
      totalVolume: Decimal.tryParse(json['total_volume']?.toString() ?? '0') ?? Decimal.zero,
      settledVolume: Decimal.tryParse(json['settled_volume']?.toString() ?? '0') ?? Decimal.zero,
      unmatchedVolume: Decimal.tryParse(json['unmatched_volume']?.toString() ?? '0') ?? Decimal.zero,
      totalCount: (json['total_count'] as num?)?.toInt() ?? list.length,
    );
  }
}

class DebtAgingBracketDto {
  final String unitId;
  final String unitLabel;
  final String residentName;
  final String debtorType;
  final Decimal currentDue;
  final Decimal overdue1to30Days;
  final Decimal overdue31to60Days;
  final Decimal overdue60PlusDays;
  final Decimal accruedDelayPenalty;
  final Decimal totalOutstanding;

  const DebtAgingBracketDto({
    required this.unitId,
    required this.unitLabel,
    required this.residentName,
    required this.debtorType,
    required this.currentDue,
    required this.overdue1to30Days,
    required this.overdue31to60Days,
    required this.overdue60PlusDays,
    required this.accruedDelayPenalty,
    required this.totalOutstanding,
  });

  factory DebtAgingBracketDto.fromJson(Map<String, dynamic> json) {
    return DebtAgingBracketDto(
      unitId: json['unit_id']?.toString() ?? '',
      unitLabel: json['unit_label']?.toString() ?? '',
      residentName: json['resident_name']?.toString() ?? '',
      debtorType: json['debtor_type']?.toString() ?? 'TENANT',
      currentDue: Decimal.tryParse(json['current_due']?.toString() ?? '0') ?? Decimal.zero,
      overdue1to30Days: Decimal.tryParse(json['overdue_1_30_days']?.toString() ?? '0') ?? Decimal.zero,
      overdue31to60Days: Decimal.tryParse(json['overdue_31_60_days']?.toString() ?? '0') ?? Decimal.zero,
      overdue60PlusDays: Decimal.tryParse(json['overdue_60_plus_days']?.toString() ?? '0') ?? Decimal.zero,
      accruedDelayPenalty: Decimal.tryParse(json['accrued_delay_penalty']?.toString() ?? '0') ?? Decimal.zero,
      totalOutstanding: Decimal.tryParse(json['total_outstanding']?.toString() ?? '0') ?? Decimal.zero,
    );
  }
}

class DebtAgingReportDto {
  final DateTime asOfDate;
  final Decimal totalCurrent;
  final Decimal total1to30Days;
  final Decimal total31to60Days;
  final Decimal total60PlusDays;
  final Decimal totalPenalty;
  final Decimal grandTotal;
  final List<DebtAgingBracketDto> brackets;

  const DebtAgingReportDto({
    required this.asOfDate,
    required this.totalCurrent,
    required this.total1to30Days,
    required this.total31to60Days,
    required this.total60PlusDays,
    required this.totalPenalty,
    required this.grandTotal,
    required this.brackets,
  });

  factory DebtAgingReportDto.fromJson(Map<String, dynamic> json) {
    var rawBrackets = json['brackets'];
    List<DebtAgingBracketDto> list = [];
    if (rawBrackets is List) {
      list = rawBrackets
          .map((b) => DebtAgingBracketDto.fromJson(b as Map<String, dynamic>))
          .toList();
    }

    return DebtAgingReportDto(
      asOfDate: json['as_of_date'] != null
          ? DateTime.tryParse(json['as_of_date'].toString()) ?? DateTime.now()
          : DateTime.now(),
      totalCurrent: Decimal.tryParse(json['total_current']?.toString() ?? '0') ?? Decimal.zero,
      total1to30Days: Decimal.tryParse(json['total_1_30_days']?.toString() ?? '0') ?? Decimal.zero,
      total31to60Days: Decimal.tryParse(json['total_31_60_days']?.toString() ?? '0') ?? Decimal.zero,
      total60PlusDays: Decimal.tryParse(json['total_60_plus_days']?.toString() ?? '0') ?? Decimal.zero,
      totalPenalty: Decimal.tryParse(json['total_penalty']?.toString() ?? '0') ?? Decimal.zero,
      grandTotal: Decimal.tryParse(json['grand_total']?.toString() ?? '0') ?? Decimal.zero,
      brackets: list,
    );
  }
}

// ---------------------------------------------------------------------------
// EPIC-10: Capital Expenditure & Fixtures (Demirbaş Yönetimi) Models
// ---------------------------------------------------------------------------

class CapitalProjectItem {
  final String id;
  final String siteId;
  final String title;
  final String category;
  final String? description;
  final Decimal totalBudget;
  final String allocationBasis;
  final DateTime targetStartDate;
  final DateTime? targetCompletionDate;
  final String? contractorName;
  final String? contractorTaxNo;
  final String? contractorIban;
  final Decimal? contractAmount;
  final String status;
  final Decimal collectedAmount;
  final Decimal disbursedAmount;
  final Decimal remainingFundBalance;
  final int totalUnitsCount;
  final int installmentsCount;
  final DateTime? createdAt;

  const CapitalProjectItem({
    required this.id,
    required this.siteId,
    required this.title,
    required this.category,
    this.description,
    required this.totalBudget,
    required this.allocationBasis,
    required this.targetStartDate,
    this.targetCompletionDate,
    this.contractorName,
    this.contractorTaxNo,
    this.contractorIban,
    this.contractAmount,
    required this.status,
    required this.collectedAmount,
    required this.disbursedAmount,
    required this.remainingFundBalance,
    required this.totalUnitsCount,
    required this.installmentsCount,
    this.createdAt,
  });

  CapitalProjectCategory get projectCategory => CapitalProjectCategory.fromCode(category);
  AllocationBasis get basis => AllocationBasis.fromCode(allocationBasis);
  CapitalProjectStatus get projectStatus => CapitalProjectStatus.fromCode(status);

  String get categoryLabel {
    switch (category) {
      case 'ELEVATOR':
        return 'Asansör & Revizyon';
      case 'ROOF_FACADE':
        return 'Çatı & Dış Cephe Yalıtım';
      case 'BOILER_HEATING':
        return 'Merkezi Kazan & Isıtma';
      case 'SECURITY_SYSTEM':
        return 'Kamera & Güvenlik';
      case 'LANDSCAPING':
        return 'Çevre Düzeni & Peyzaj';
      case 'GENERATOR':
        return 'Jeneratör & Enerji';
      default:
        return 'Diğer Demirbaş';
    }
  }

  String get allocationBasisLabel {
    return allocationBasis == 'BY_LAND_SHARE' ? 'Arsa Payı Oranında (KMK 20)' : 'Eşit Paylaşım';
  }

  double get collectionProgressPercentage {
    if (totalBudget <= Decimal.zero) return 0.0;
    final pct = (collectedAmount / totalBudget).toDouble() * 100.0;
    return pct.clamp(0.0, 100.0);
  }

  factory CapitalProjectItem.fromJson(Map<String, dynamic> json) {
    return CapitalProjectItem(
      id: json['id']?.toString() ?? '',
      siteId: json['site_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      category: json['category']?.toString() ?? 'ELEVATOR',
      description: json['description']?.toString(),
      totalBudget: Decimal.tryParse(json['total_budget']?.toString() ?? '0') ?? Decimal.zero,
      allocationBasis: json['allocation_basis']?.toString() ?? 'BY_LAND_SHARE',
      targetStartDate: json['target_start_date'] != null
          ? DateTime.tryParse(json['target_start_date'].toString()) ?? DateTime.now()
          : DateTime.now(),
      targetCompletionDate: json['target_completion_date'] != null
          ? DateTime.tryParse(json['target_completion_date'].toString())
          : null,
      contractorName: json['contractor_name']?.toString(),
      contractorTaxNo: json['contractor_tax_no']?.toString(),
      contractorIban: json['contractor_iban']?.toString(),
      contractAmount: json['contract_amount'] != null
          ? Decimal.tryParse(json['contract_amount'].toString())
          : null,
      status: json['status']?.toString() ?? 'ACTIVE',
      collectedAmount: Decimal.tryParse(json['collected_amount']?.toString() ?? '0') ?? Decimal.zero,
      disbursedAmount: Decimal.tryParse(json['disbursed_amount']?.toString() ?? '0') ?? Decimal.zero,
      remainingFundBalance: Decimal.tryParse(json['remaining_fund_balance']?.toString() ?? '0') ?? Decimal.zero,
      totalUnitsCount: json['total_units_count'] is int ? json['total_units_count'] : 12,
      installmentsCount: json['installments_count'] is int ? json['installments_count'] : 0,
      createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at'].toString()) : null,
    );
  }
}

class CapitalProjectInstallmentItem {
  final String id;
  final String projectId;
  final int installmentNumber;
  final int totalInstallments;
  final DateTime dueDate;
  final Decimal installmentBudget;
  final Decimal percentage;
  final bool isAccrued;
  final DateTime? accruedAt;

  const CapitalProjectInstallmentItem({
    required this.id,
    required this.projectId,
    required this.installmentNumber,
    required this.totalInstallments,
    required this.dueDate,
    required this.installmentBudget,
    required this.percentage,
    required this.isAccrued,
    this.accruedAt,
  });

  factory CapitalProjectInstallmentItem.fromJson(Map<String, dynamic> json) {
    return CapitalProjectInstallmentItem(
      id: json['id']?.toString() ?? '',
      projectId: json['project_id']?.toString() ?? '',
      installmentNumber: json['installment_number'] is int ? json['installment_number'] : 1,
      totalInstallments: json['total_installments'] is int ? json['total_installments'] : 1,
      dueDate: json['due_date'] != null
          ? DateTime.tryParse(json['due_date'].toString()) ?? DateTime.now()
          : DateTime.now(),
      installmentBudget: Decimal.tryParse(json['installment_budget']?.toString() ?? '0') ?? Decimal.zero,
      percentage: Decimal.tryParse(json['percentage']?.toString() ?? '0') ?? Decimal.zero,
      isAccrued: json['is_accrued'] == true,
      accruedAt: json['accrued_at'] != null ? DateTime.tryParse(json['accrued_at'].toString()) : null,
    );
  }
}

class CapitalContractorDisbursementItem {
  final String id;
  final String projectId;
  final String milestoneName;
  final String? invoiceNumber;
  final Decimal amount;
  final DateTime disbursementDate;
  final String recipientName;
  final String recipientIban;
  final String? paymentReference;
  final String disbursementMethod;
  final String? notes;
  final DateTime? createdAt;

  const CapitalContractorDisbursementItem({
    required this.id,
    required this.projectId,
    required this.milestoneName,
    this.invoiceNumber,
    required this.amount,
    required this.disbursementDate,
    required this.recipientName,
    required this.recipientIban,
    this.paymentReference,
    required this.disbursementMethod,
    this.notes,
    this.createdAt,
  });

  DisbursementMethod get method => DisbursementMethod.fromCode(disbursementMethod);

  factory CapitalContractorDisbursementItem.fromJson(Map<String, dynamic> json) {
    return CapitalContractorDisbursementItem(
      id: json['id']?.toString() ?? '',
      projectId: json['project_id']?.toString() ?? '',
      milestoneName: json['milestone_name']?.toString() ?? '',
      invoiceNumber: json['invoice_number']?.toString(),
      amount: Decimal.tryParse(json['amount']?.toString() ?? '0') ?? Decimal.zero,
      disbursementDate: json['disbursement_date'] != null
          ? DateTime.tryParse(json['disbursement_date'].toString()) ?? DateTime.now()
          : DateTime.now(),
      recipientName: json['recipient_name']?.toString() ?? '',
      recipientIban: json['recipient_iban']?.toString() ?? '',
      paymentReference: json['payment_reference']?.toString(),
      disbursementMethod: json['disbursement_method']?.toString() ?? 'BANK_TRANSFER',
      notes: json['notes']?.toString(),
      createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at'].toString()) : null,
    );
  }
}

class UnitCapitalShareItem {
  final String unitId;
  final String block;
  final int unitNumber;
  final String ownerName;
  final String? ownerPhone;
  final int landShare;
  final Decimal totalProjectShare;
  final Decimal totalAccrued;
  final Decimal totalPaid;
  final Decimal remainingDebt;
  final bool isSettled;

  const UnitCapitalShareItem({
    required this.unitId,
    required this.block,
    required this.unitNumber,
    required this.ownerName,
    this.ownerPhone,
    required this.landShare,
    required this.totalProjectShare,
    required this.totalAccrued,
    required this.totalPaid,
    required this.remainingDebt,
    required this.isSettled,
  });

  factory UnitCapitalShareItem.fromJson(Map<String, dynamic> json) {
    return UnitCapitalShareItem(
      unitId: json['unit_id']?.toString() ?? '',
      block: json['block']?.toString() ?? 'A',
      unitNumber: json['unit_number'] is int ? json['unit_number'] : 1,
      ownerName: json['owner_name']?.toString() ?? '',
      ownerPhone: json['owner_phone']?.toString(),
      landShare: json['land_share'] is int ? json['land_share'] : 24,
      totalProjectShare: Decimal.tryParse(json['total_project_share']?.toString() ?? '0') ?? Decimal.zero,
      totalAccrued: Decimal.tryParse(json['total_accrued']?.toString() ?? '0') ?? Decimal.zero,
      totalPaid: Decimal.tryParse(json['total_paid']?.toString() ?? '0') ?? Decimal.zero,
      remainingDebt: Decimal.tryParse(json['remaining_debt']?.toString() ?? '0') ?? Decimal.zero,
      isSettled: json['is_settled'] == true,
    );
  }
}


