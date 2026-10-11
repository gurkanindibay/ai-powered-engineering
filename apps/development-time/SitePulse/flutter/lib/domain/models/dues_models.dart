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
  final String? virtualIban;
  final Decimal? advancePayment;

  const ApartmentUnit({
    required this.id,
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

  ApartmentUnit copyWith({
    String? id,
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
    return ratio.toDouble().round();
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

  FlatPaymentStatus copyWith({
    String? id,
    String? block,
    int? unitNo,
    String? residentName,
    Decimal? amountDue,
    int? daysOverdue,
    bool? isPaid,
    String? paidDateStr,
  }) {
    return FlatPaymentStatus(
      id: id ?? this.id,
      block: block ?? this.block,
      unitNo: unitNo ?? this.unitNo,
      residentName: residentName ?? this.residentName,
      amountDue: amountDue ?? this.amountDue,
      daysOverdue: daysOverdue ?? this.daysOverdue,
      isPaid: isPaid ?? this.isPaid,
      paidDateStr: paidDateStr ?? this.paidDateStr,
    );
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
  final String? referenceNo;

  const BankStatementParsedItem({
    required this.transactionId,
    required this.date,
    required this.amount,
    required this.currency,
    required this.description,
    this.senderName,
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
      referenceNo: json['reference_no'],
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
      return '$matchedBlock Blok D:$matchedUnitNumber';
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

  const ManualAssignmentResult({
    required this.flat,
    this.sendOptionalMessage = false,
    this.optionalMessageText,
  });
}


