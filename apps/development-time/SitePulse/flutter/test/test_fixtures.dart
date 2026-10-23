import 'package:decimal/decimal.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';

class TestFixtures {
  static const defaultResidentUnit = ApartmentUnit(
    id: 'd-14',
    siteId: 'site-1',
    siteName: 'Begonya Sitesi',
    block: 'A',
    unitNo: 14,
    floor: 4,
    landShare: 24,
    ownerName: 'Ahmet Yılmaz',
    tenantName: 'Zeynep Kaya',
    virtualIban: 'TR41 0020 5042 1399 1067 0000 14',
  );

  static const managerUnit = ApartmentUnit(
    id: 'd-1',
    siteId: 'site-1',
    siteName: 'Begonya Sitesi',
    block: 'B',
    unitNo: 1,
    floor: 1,
    landShare: 24,
    ownerName: 'Mehmet Demir',
    tenantName: 'Mehmet Demir (Oturuyor)',
    virtualIban: 'TR91 0020 5000 0986 3791 6000 01',
  );

  static final List<UnitResidentMember> managerResidents = [
    const UnitResidentMember(
      id: 'u-m1',
      fullName: 'Mehmet Demir',
      relationship: 'Kat Maliki & Yönetici',
      phone: '+90 532 100 2030',
      email: 'mehmet.demir@begonya.com',
      isOwner: true,
      permissionScope: 'Tam Yetki (Daire + Yönetim)',
    ),
    const UnitResidentMember(
      id: 'u-m2',
      fullName: 'Ayşe Demir',
      relationship: 'Eş / Aile Sakini',
      phone: '+90 532 100 2031',
      email: 'ayse.demir@begonya.com',
      isOwner: false,
      permissionScope: 'Sakin Yetkisi',
    ),
  ];

  static final siteBankAccount = SiteBankAccount(
    id: 'sba-site-1-kt',
    siteId: 'site-1',
    bankCode: 'KUVEYT_TURK',
    bankName: 'Kuveyt Türk Katılım Bankası',
    iban: 'TR620020500009863791600001',
    accountHolder: 'Begonya Sitesi Yönetimi',
    statementFormat: 'EXCEL',
    isActive: true,
    configuredBy: 'usr-site-manager-1',
    updatedAt: DateTime(2026, 9, 1),
  );

  static final List<FlatPaymentStatus> flatsList = [
    FlatPaymentStatus(id: '1', block: 'A', unitNo: 14, residentName: 'Ahmet Yılmaz', amountDue: Decimal.parse('1423.33'), daysOverdue: 10, isPaid: false),
    FlatPaymentStatus(id: '2', block: 'A', unitNo: 15, residentName: 'Fatma Kaya', amountDue: Decimal.parse('1411.67'), daysOverdue: 5, isPaid: false),
    FlatPaymentStatus(id: '3', block: 'B', unitNo: 3, residentName: 'Mehmet Öz', amountDue: Decimal.parse('1404.67'), daysOverdue: 2, isPaid: false),
    FlatPaymentStatus(id: '4', block: 'A', unitNo: 1, residentName: 'Selim Ak', amountDue: Decimal.parse('1400.00'), daysOverdue: 0, isPaid: true, paidDateStr: '12 Eyl'),
    FlatPaymentStatus(id: '5', block: 'B', unitNo: 7, residentName: 'Canan Ece', amountDue: Decimal.parse('1400.00'), daysOverdue: 0, isPaid: true, paidDateStr: '14 Eyl'),
    FlatPaymentStatus(id: '6', block: 'A', unitNo: 2, residentName: 'Ali Demir', amountDue: Decimal.parse('1400.00'), daysOverdue: 0, isPaid: true, paidDateStr: '10 Eyl'),
    FlatPaymentStatus(id: '7', block: 'A', unitNo: 10, residentName: 'Alaettin Çelik', amountDue: Decimal.parse('1320.00'), daysOverdue: 0, isPaid: false),
    FlatPaymentStatus(id: '8', block: 'B', unitNo: 4, residentName: 'Mustafa Rüzgar', amountDue: Decimal.parse('715.00'), daysOverdue: 0, isPaid: false),
    FlatPaymentStatus(id: '9', block: 'A', unitNo: 8, residentName: 'Mustafa Burak Türkmen', amountDue: Decimal.parse('1000.00'), daysOverdue: 0, isPaid: false),
    FlatPaymentStatus(id: '10', block: 'B', unitNo: 12, residentName: 'Sait Şener', amountDue: Decimal.parse('715.00'), daysOverdue: 0, isPaid: false),
    FlatPaymentStatus(id: '11', block: 'A', unitNo: 6, residentName: 'Servet Karaca', amountDue: Decimal.parse('715.00'), daysOverdue: 0, isPaid: false),
    FlatPaymentStatus(id: '12', block: 'B', unitNo: 16, residentName: 'Hasan İndibay', amountDue: Decimal.parse('28000.00'), daysOverdue: 0, isPaid: false),
  ];

  static final List<RegistrationRequestItem> pendingRegistrations = [
    RegistrationRequestItem(
      id: 'req-1',
      block: 'B Blok',
      unitNo: 18,
      floor: 5,
      fullName: 'Kerem Yılmaz',
      email: 'kerem.yilmaz@gmail.com',
      phone: '0533 111 22 33',
      isResident: true,
      duesAmount: Decimal.parse('1400.00'),
      timeAgoStr: '15 dk önce',
    ),
    RegistrationRequestItem(
      id: 'req-2',
      block: 'A Blok',
      unitNo: 5,
      floor: 2,
      fullName: 'Deniz Aydın',
      email: 'deniz.aydin@hotmail.com',
      phone: '0542 333 44 55',
      isResident: false,
      duesAmount: Decimal.parse('1400.00'),
      timeAgoStr: '1 saat önce',
    ),
  ];

  static final List<TenantSiteItem> saasSites = [
    TenantSiteItem(
      id: 'site-1',
      name: 'Begonya Sitesi',
      city: 'İstanbul',
      address: 'Ataşehir, Begonya Sok. No:14',
      status: 'ACTIVE',
      planType: 'PREMIUM',
      totalUnits: 24,
      monthlyCollectionVolume: Decimal.parse('96000.00'),
      adminName: 'Mehmet Demir',
      adminEmail: 'mehmet.demir@begonya.com',
      adminPhone: '+90 532 100 2030',
    ),
    TenantSiteItem(
      id: 'site-2',
      name: 'Kardelen Rezidans',
      city: 'Ankara',
      address: 'Çankaya, Kardelen Cad. No:8',
      status: 'ACTIVE',
      planType: 'STANDARD',
      totalUnits: 36,
      monthlyCollectionVolume: Decimal.parse('144000.00'),
      adminName: 'Selin Vural',
      adminEmail: 'selin@kardelenrezidans.com',
      adminPhone: '+90 533 222 4050',
    ),
    TenantSiteItem(
      id: 'site-3',
      name: 'Zambak Konutları',
      city: 'İzmir',
      address: 'Bornova, Zambak Sok. No:5',
      status: 'ACTIVE',
      planType: 'STANDARD',
      totalUnits: 0,
      monthlyCollectionVolume: Decimal.zero,
      adminName: 'Kemal Sunal',
      adminEmail: 'kemal@zambak.com',
      adminPhone: '+90 535 333 5060',
    ),
  ];

  static final List<ReconciliationQueueItem> reconciliationQueue = [
    ReconciliationQueueItem(
      matchId: 'DEMO-TXN-1',
      transaction: BankStatementParsedItem(
        transactionId: 'TXN-KUV-01',
        date: DateTime(2026, 7, 13),
        amount: Decimal.parse('715.00'),
        currency: 'TRY',
        description: 'FAST Para Transferi - Gönderen: SAİT ŞENER, Alıcı: GÜRKAN İNDİBAY',
      ),
      matchedUnitId: 'd-12',
      matchedBlock: 'B',
      matchedUnitNumber: 12,
      matchedResidentName: 'Sait Şener',
      confidenceScore: 100,
      amountMatchesBalance: true,
      status: 'ONAY_BEKLIYOR',
      notes: 'Sakin adı ve borç tutarı birebir eşleşti',
    ),
    ReconciliationQueueItem(
      matchId: 'DEMO-TXN-2',
      transaction: BankStatementParsedItem(
        transactionId: 'TXN-ISB-02',
        date: DateTime(2026, 8, 6),
        amount: Decimal.parse('1400.00'),
        currency: 'TRY',
        description: 'Havale - EFEKTİF YATAN ATM KART HESABINA',
      ),
      matchedUnitId: null,
      matchedBlock: null,
      matchedUnitNumber: null,
      matchedResidentName: null,
      confidenceScore: 0,
      amountMatchesBalance: false,
      status: 'ESLESTIRILEMEDI',
      notes: 'Açıklamada daire veya sakin adı bulunamadı, manuel eşleme bekliyor',
    ),
    ReconciliationQueueItem(
      matchId: 'DEMO-TXN-3',
      transaction: BankStatementParsedItem(
        transactionId: 'TXN-KUV-03',
        date: DateTime(2026, 7, 14),
        amount: Decimal.parse('715.00'),
        currency: 'TRY',
        description: 'Para Transferi - Gönderen: BİLİNMEYEN HAVALE, Alıcı: GÜRKAN İNDİBAY',
        senderName: 'Bilinmeyen Gönderici',
        senderIban: 'TR12 0006 2000 0000 0000 0001',
      ),
      matchedUnitId: null,
      matchedBlock: null,
      matchedUnitNumber: null,
      matchedResidentName: null,
      confidenceScore: 0,
      amountMatchesBalance: false,
      status: 'ESLESTIRILEMEDI',
      notes: 'Kayıtlı olmayan gönderen, daire ataması gerekiyor',
    ),
  ];

  static final List<AccountTransactionItem> accountTransactions = [
    AccountTransactionItem(
      id: 'tx-0',
      title: 'Eylül 2026 Aidatı',
      subtitle: 'Aylık Aidat Tahakkuku',
      amount: Decimal.parse('1423.33'),
      date: '15.09.2026',
      isCredit: false,
    ),
    AccountTransactionItem(
      id: 'tx-1',
      title: 'Ağustos 2026 Aidatı',
      subtitle: 'Kredi Kartı ile Ödendi',
      amount: Decimal.parse('1400.00'),
      date: '15.08.2026 10:20',
      isCredit: true,
    ),
  ];

  static const matchingCriteria = UnitMatchingCriteria(
    unitId: 'd-14',
    block: 'A',
    unitNumber: 14,
    residentName: 'Ahmet Yılmaz',
    virtualIban: 'TR41 0020 5042 1399 1067 0000 14',
    rememberedIbans: [
      RegisteredSenderIban(
        senderIban: 'TR120006200000000000000001',
        formattedIban: 'TR12 0006 2000 0000 0000 0001',
        label: 'Garanti BBVA - Maaş Hesabı',
        bankName: 'Garanti BBVA',
      ),
    ],
    registeredPayerNames: ['Ahmet Yılmaz', 'Zeynep Kaya'],
    recommendedDescription: 'A Blok D:14',
  );

  static final List<DuesLiability> duesList = [
    DuesLiability(
      id: 'b-101',
      unitId: 'd-14',
      period: 'Eylül 2026',
      principalAmount: Decimal.parse('1400.00'),
      delayPenalty: Decimal.parse('23.33'),
      totalAmount: Decimal.parse('1423.33'),
      dueDate: DateTime(2026, 9, 15),
      daysOverdue: 10,
      status: DebtStatus.overdue,
    ),
  ];
}

extension DashboardControllerTestFixtures on DashboardController {
  void loadTestFixtures() {
    isTestMode = true;
    setActiveUnitForTesting(TestFixtures.defaultResidentUnit);
    setManagerUnitForTesting(TestFixtures.managerUnit);
    setDuesForTesting(TestFixtures.duesList);
    setFlatsForTesting(TestFixtures.flatsList);
    setPendingRegistrationsForTesting(TestFixtures.pendingRegistrations);
    setSaasSitesForTesting(TestFixtures.saasSites);
    setReconciliationQueueForTesting(TestFixtures.reconciliationQueue);
    setAccountTransactionsForTesting(TestFixtures.accountTransactions);
    setMatchingCriteriaForTesting(TestFixtures.matchingCriteria);
    setSiteBankAccountForTesting(TestFixtures.siteBankAccount);
    setUnitResidentsForTesting(TestFixtures.managerResidents);
    setManagerResidentsForTesting(TestFixtures.managerResidents);
    setSelectedDuesMonthForTesting('Eylül 2026');
    switchSessionRole(UserRole.homeOwner);
  }

  void loadZeroDataFixtures({
    UserRole role = UserRole.siteManager,
    bool includeSite = true,
  }) {
    isTestMode = true;
    clearAllDataForTesting();
    if (includeSite) {
      final zeroSite = TenantSiteItem(
        id: 'site-zero-1',
        name: 'Begonya Sitesi',
        city: 'İstanbul',
        address: 'Ataşehir, İstanbul',
        status: 'ACTIVE',
        planType: 'STANDARD',
        totalUnits: 0,
        monthlyCollectionVolume: Decimal.zero,
        adminName: 'Site Yöneticisi',
        adminEmail: 'yonetici@begonya.com',
        adminPhone: '+90 532 111 22 33',
        actionCount: 0,
      );
      setManagedSitesForTesting(zeroSite, [zeroSite]);
    }
    switchSessionRole(role);
  }
}
