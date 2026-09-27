import 'package:decimal/decimal.dart';

enum BorcDurumu {
  bekliyor('Bekliyor'),
  gecikmede('Gecikmede'),
  odendi('Ödendi');

  final String label;
  const BorcDurumu(this.label);
}

class AidatBorcu {
  final String id;
  final String daireId;
  final String donem;
  final Decimal anaPara;
  final Decimal gecikmeTazminati;
  final Decimal toplamTutar;
  final DateTime sonOdemeTarihi;
  final int gecikenGunSayisi;
  final BorcDurumu durum;

  const AidatBorcu({
    required this.id,
    required this.daireId,
    required this.donem,
    required this.anaPara,
    required this.gecikmeTazminati,
    required this.toplamTutar,
    required this.sonOdemeTarihi,
    this.gecikenGunSayisi = 0,
    required this.durum,
  });

  AidatBorcu copyWith({
    String? id,
    String? daireId,
    String? donem,
    Decimal? anaPara,
    Decimal? gecikmeTazminati,
    Decimal? toplamTutar,
    DateTime? sonOdemeTarihi,
    int? gecikenGunSayisi,
    BorcDurumu? durum,
  }) {
    return AidatBorcu(
      id: id ?? this.id,
      daireId: daireId ?? this.daireId,
      donem: donem ?? this.donem,
      anaPara: anaPara ?? this.anaPara,
      gecikmeTazminati: gecikmeTazminati ?? this.gecikmeTazminati,
      toplamTutar: toplamTutar ?? this.toplamTutar,
      sonOdemeTarihi: sonOdemeTarihi ?? this.sonOdemeTarihi,
      gecikenGunSayisi: gecikenGunSayisi ?? this.gecikenGunSayisi,
      durum: durum ?? this.durum,
    );
  }
}

class Daire {
  final String id;
  final String siteAdi;
  final String blok;
  final int daireNo;
  final int kat;
  final int arsaPayi;
  final String malikAdi;
  final String kiraciAdi;

  const Daire({
    required this.id,
    required this.siteAdi,
    required this.blok,
    required this.daireNo,
    required this.kat,
    required this.arsaPayi,
    required this.malikAdi,
    required this.kiraciAdi,
  });
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
