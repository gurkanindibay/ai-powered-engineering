import 'dart:convert';
import 'dart:typed_data';
import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../domain/models/auth_models.dart';
import '../../domain/models/dues_models.dart';
import '../../domain/services/bank_file_parser.dart';
import '../../domain/usecases/calculate_dues_usecase.dart';

class DashboardController extends ChangeNotifier {
  final CalculateDuesUseCase _calculateDuesUseCase;

  static const defaultResidentUnit = ApartmentUnit(
    id: 'd-14',
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

  DashboardController({
    CalculateDuesUseCase? calculateDuesUseCase,
    bool startAuthenticated = false,
  })  : _calculateDuesUseCase = calculateDuesUseCase ?? CalculateDuesUseCase(),
        _isAuthenticated = startAuthenticated {
    _initData();
  }

  // Session & Auth
  bool _isAuthenticated;
  bool get isAuthenticated => _isAuthenticated;

  SiteAdminActivePath _siteAdminPath = SiteAdminActivePath.managerCockpit;
  SiteAdminActivePath get siteAdminPath => _siteAdminPath;

  late UserSession _userSession;
  UserSession get userSession => _userSession;
  UserRole get userRole => _userSession.role;

  String? _authMessage;
  String? get authMessage => _authMessage;

  // Theme (Papara Dark default)
  bool _isDarkMode = true;
  bool get isDarkMode => _isDarkMode;

  // Offline Sync State
  bool _isOffline = false;
  bool get isOffline => _isOffline;
  String _lastSyncTime = 'Az önce';
  String get lastSyncTime => _lastSyncTime;

  // Home Owner state
  late ApartmentUnit _activeUnit;
  ApartmentUnit get activeUnit =>
      (_userSession.role == UserRole.siteManager && _siteAdminPath == SiteAdminActivePath.myFlatOwner)
          ? managerUnit
          : _activeUnit;
  ApartmentUnit get activeDaire => activeUnit;

  List<DuesLiability> _duesList = [];
  List<DuesLiability> _managerDuesList = [];
  List<DuesLiability> get duesList {
    if (_userSession.role == UserRole.siteManager && _siteAdminPath == SiteAdminActivePath.myFlatOwner) {
      return _managerDuesList;
    }
    return _duesList;
  }
  DuesLiability get primaryDues => duesList.isNotEmpty
      ? duesList.first
      : DuesLiability(
          id: 'due-clean',
          unitId: activeUnit.id,
          period: 'Eylül 2026',
          principalAmount: Decimal.zero,
          delayPenalty: Decimal.zero,
          totalAmount: Decimal.zero,
          dueDate: DateTime(2026, 9, 15),
          daysOverdue: 0,
          status: DebtStatus.paid,
        );

  List<AccountTransactionItem> _accountTransactions = [];
  List<AccountTransactionItem> get accountTransactions => _accountTransactions;

  List<UnitResidentMember> _unitResidents = [];
  List<UnitResidentMember> get unitResidents {
    if (_userSession.role == UserRole.siteManager && _siteAdminPath == SiteAdminActivePath.myFlatOwner) {
      return managerResidents;
    }
    return _unitResidents;
  }

  UnitInviteInfo? _unitInviteInfo;
  UnitInviteInfo? get unitInviteInfo => _unitInviteInfo;

  // Manager state
  late ComplexCollectionSummary _collectionSummary;
  ComplexCollectionSummary get collectionSummary => _collectionSummary;

  List<FlatPaymentStatus> _flatsList = [];
  List<FlatPaymentStatus> get flatsList {
    if (_flatFilter == 'OVERDUE') {
      return _flatsList.where((f) => !f.isPaid && f.daysOverdue > 0).toList();
    } else if (_flatFilter == 'PAID') {
      return _flatsList.where((f) => f.isPaid).toList();
    }
    return _flatsList;
  }

  String _flatFilter = 'ALL';
  String get flatFilter => _flatFilter;

  // Monthly Dues State
  String _selectedDuesMonth = 'Eylül 2026';
  String get selectedDuesMonth => _selectedDuesMonth;

  List<String> get availableDuesMonths => _availableDuesMonths;
  final List<String> _availableDuesMonths = [
    'Ekim 2026',
    'Eylül 2026',
    'Ağustos 2026',
    'Temmuz 2026',
    'Haziran 2026',
  ];

  final Map<String, List<FlatPaymentStatus>> _monthlyFlats = {};

  void setSelectedDuesMonth(String month) {
    if (_selectedDuesMonth != month) {
      _selectedDuesMonth = month;
      notifyListeners();
    }
  }

  List<FlatPaymentStatus> get currentMonthFlats {
    final list = _monthlyFlats[_selectedDuesMonth] ?? _flatsList;
    if (_flatFilter == 'OVERDUE') {
      return list.where((f) => !f.isPaid && f.daysOverdue > 0).toList();
    } else if (_flatFilter == 'PAID') {
      return list.where((f) => f.isPaid).toList();
    }
    return list;
  }

  ComplexCollectionSummary get currentMonthSummary {
    final list = _monthlyFlats[_selectedDuesMonth] ?? _flatsList;
    int paid = list.where((f) => f.isPaid).length;
    int overdue = list.where((f) => !f.isPaid).length;
    Decimal collected = Decimal.zero;
    Decimal remaining = Decimal.zero;
    for (final f in list) {
      if (f.isPaid) {
        collected += f.amountDue;
      } else {
        remaining += f.amountDue;
      }
    }
    return ComplexCollectionSummary(
      totalExpected: collected + remaining,
      totalCollected: collected,
      totalOverdueWithInterest: remaining,
      paidUnitsCount: paid,
      overdueUnitsCount: overdue,
      totalUnitsCount: list.length,
    );
  }

  List<ReconciliationQueueItem> get unmatchedBankTransactions =>
      _reconciliationQueue.where((item) => item.status == 'ESLESTIRILEMEDI').toList();

  int get unmatchedBankCount => unmatchedBankTransactions.length;

  List<RegistrationRequestItem> _pendingRegistrations = [];
  List<RegistrationRequestItem> get pendingRegistrations => _pendingRegistrations;

  ApprovalSuccessInfo? _approvalSuccessInfo;
  ApprovalSuccessInfo? get approvalSuccessInfo => _approvalSuccessInfo;

  ProvisionedHomeOwnerCredentials? _provisionedHomeOwner;
  ProvisionedHomeOwnerCredentials? get provisionedHomeOwner => _provisionedHomeOwner;

  // SaaS Admin state
  List<TenantSiteItem> _saasSites = [];
  List<TenantSiteItem> get saasSites => _saasSites;

  ProvisionedSiteCredentials? _provisionedCredentials;
  ProvisionedSiteCredentials? get provisionedCredentials => _provisionedCredentials;

  // Bank Statement Ingestion & Automated Reconciliation State (STORY-07-02)
  List<ReconciliationQueueItem> _reconciliationQueue = [];
  List<ReconciliationQueueItem> get reconciliationQueue => _reconciliationQueue;

  final Set<String> _processedTransactionIds = {};
  final Set<String> _processedUnitKeys = {};

  String? _reconciliationSuccessMessage;
  String? get reconciliationSuccessMessage => _reconciliationSuccessMessage;

  final List<ReconciliationHostMessage> _sentHostMessages = [];
  List<ReconciliationHostMessage> get sentHostMessages => List.unmodifiable(_sentHostMessages);

  // Site Bank Account Configuration State (STORY-08-01)
  SiteBankAccount? _siteBankAccount;
  SiteBankAccount? get siteBankAccount => _siteBankAccount;

  String? _bankStatementError;
  String? get bankStatementError => _bankStatementError;
  void clearBankStatementError() {
    _bankStatementError = null;
    notifyListeners();
  }
  void setBankStatementError(String error) {
    _bankStatementError = error;
    notifyListeners();
  }

  void _initData() {
    _userSession = _createSession(UserRole.homeOwner, AuthProvider.local);

    _activeUnit = defaultResidentUnit;

    // Seed Begonya Sitesi active bank account (Kuveyt Türk -> EXCEL format)
    _siteBankAccount = SiteBankAccount(
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

    // Initial dues with 10 days overdue calculation (Spec-001)
    final baseDues = DuesLiability(
      id: 'b-101',
      unitId: 'd-14',
      period: 'Eylül 2026',
      principalAmount: Decimal.parse('1400.00'),
      delayPenalty: Decimal.zero,
      totalAmount: Decimal.parse('1400.00'),
      dueDate: DateTime(2026, 9, 15),
      status: DebtStatus.pending,
    );
    _duesList = [_calculateDuesUseCase.execute(baseDues, DateTime(2026, 9, 25))];

    final managerBaseDues = DuesLiability(
      id: 'b-201',
      unitId: 'd-1',
      period: 'Eylül 2026',
      principalAmount: Decimal.parse('1400.00'),
      delayPenalty: Decimal.zero,
      totalAmount: Decimal.parse('1400.00'),
      dueDate: DateTime(2026, 9, 15),
      status: DebtStatus.pending,
    );
    _managerDuesList = [_calculateDuesUseCase.execute(managerBaseDues, DateTime(2026, 9, 25))];

    _collectionSummary = ComplexCollectionSummary();

    _flatsList = [
      FlatPaymentStatus(id: '1', block: 'A', unitNo: 14, residentName: 'Ahmet Yılmaz', amountDue: Decimal.parse('1423.33'), daysOverdue: 10, isPaid: false),
      FlatPaymentStatus(id: '2', block: 'A', unitNo: 15, residentName: 'Fatma Kaya', amountDue: Decimal.parse('1411.67'), daysOverdue: 5, isPaid: false),
      FlatPaymentStatus(id: '3', block: 'B', unitNo: 3, residentName: 'Mehmet Öz', amountDue: Decimal.parse('1404.67'), daysOverdue: 2, isPaid: false),
      FlatPaymentStatus(id: '4', block: 'A', unitNo: 1, residentName: 'Selim Ak', amountDue: Decimal.parse('1400.00'), daysOverdue: 0, isPaid: true, paidDateStr: '12 Eyl'),
      FlatPaymentStatus(id: '5', block: 'B', unitNo: 7, residentName: 'Canan Ece', amountDue: Decimal.parse('1400.00'), daysOverdue: 0, isPaid: true, paidDateStr: '14 Eyl'),
      FlatPaymentStatus(id: '6', block: 'A', unitNo: 2, residentName: 'Ali Demir', amountDue: Decimal.parse('1400.00'), daysOverdue: 0, isPaid: true, paidDateStr: '10 Eyl'),
      // Kuveyt Türk & İş Bankası Sakinleri (STORY-07-02 Eşleştirme)
      FlatPaymentStatus(id: '7', block: 'A', unitNo: 10, residentName: 'Alaettin Çelik', amountDue: Decimal.parse('1320.00'), daysOverdue: 0, isPaid: false),
      FlatPaymentStatus(id: '8', block: 'B', unitNo: 4, residentName: 'Mustafa Rüzgar', amountDue: Decimal.parse('715.00'), daysOverdue: 0, isPaid: false),
      FlatPaymentStatus(id: '9', block: 'A', unitNo: 8, residentName: 'Mustafa Burak Türkmen', amountDue: Decimal.parse('1000.00'), daysOverdue: 0, isPaid: false),
      FlatPaymentStatus(id: '10', block: 'B', unitNo: 12, residentName: 'Sait Şener', amountDue: Decimal.parse('715.00'), daysOverdue: 0, isPaid: false),
      FlatPaymentStatus(id: '11', block: 'A', unitNo: 6, residentName: 'Servet Karaca', amountDue: Decimal.parse('715.00'), daysOverdue: 0, isPaid: false),
      FlatPaymentStatus(id: '12', block: 'B', unitNo: 16, residentName: 'Hasan İndibay', amountDue: Decimal.parse('28000.00'), daysOverdue: 0, isPaid: false),
    ];

    _pendingRegistrations = [
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

    _saasSites = [
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
        adminName: 'Kemal Aksoy',
        adminEmail: 'kemal@zambakkonutlari.com',
        adminPhone: '+90 535 777 88 99',
        actionCount: 0,
      ),
    ];

    _unitResidents = [
      const UnitResidentMember(
        id: 'res-ahmet-14',
        fullName: 'Ahmet Yılmaz',
        relationship: 'Kat Maliki (Ev Sahibi)',
        phone: '0532 111 22 33',
        email: 'ahmet.yilmaz@begonya.com',
        isOwner: true,
        permissionScope: 'Sadece A Blok D:14',
      ),
    ];

    _monthlyFlats['Eylül 2026'] = List<FlatPaymentStatus>.from(_flatsList);
    _monthlyFlats['Ağustos 2026'] = _flatsList.map((f) {
      if (f.unitNo == 14 || f.unitNo == 15) {
        return f.copyWith(isPaid: false, daysOverdue: 35);
      }
      return f.copyWith(isPaid: true, daysOverdue: 0, paidDateStr: '12 Ağu');
    }).toList();
    _monthlyFlats['Temmuz 2026'] = _flatsList.map((f) {
      if (f.unitNo == 14) {
        return f.copyWith(isPaid: false, daysOverdue: 65);
      }
      return f.copyWith(isPaid: true, daysOverdue: 0, paidDateStr: '10 Tem');
    }).toList();
    _monthlyFlats['Ekim 2026'] = _flatsList.map((f) {
      if (f.unitNo == 1 || f.unitNo == 7) {
        return f.copyWith(isPaid: true, daysOverdue: 0, paidDateStr: '01 Eki');
      }
      return f.copyWith(isPaid: false, daysOverdue: 0);
    }).toList();

    _reconciliationQueue = [
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

    _accountTransactions = [
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
      AccountTransactionItem(
        id: 'tx-2',
        title: 'Demirbaş Katılım Payı',
        subtitle: 'Yönetim Hesabına Transfer',
        amount: Decimal.parse('500.00'),
        date: '02.08.2026 16:45',
        isCredit: true,
      ),
    ];

    _matchingCriteria = UnitMatchingCriteria(
      unitId: 'd-14',
      block: 'A',
      unitNumber: 14,
      residentName: 'Ahmet Yılmaz',
      virtualIban: 'TR41 0020 5042 1399 1067 0000 14',
      rememberedIbans: const [
        RegisteredSenderIban(
          senderIban: 'TR120006200000000000000001',
          formattedIban: 'TR12 0006 2000 0000 0000 0001',
          label: 'Garanti BBVA - Maaş Hesabı',
          bankName: 'Garanti BBVA',
        ),
      ],
      registeredPayerNames: const ['Ahmet Yılmaz', 'Zeynep Kaya'],
      recommendedDescription: 'A Blok D:14',
    );

    fetchResidentDashboard();
  }

  UnitMatchingCriteria? _matchingCriteria;
  UnitMatchingCriteria? get matchingCriteria => _matchingCriteria;

  Future<void> fetchUnitMatchingCriteria([String unitId = 'd-14']) async {
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/residents/$unitId/matching-criteria');
      final response = await http.get(url).timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        _matchingCriteria = UnitMatchingCriteria.fromJson(data);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Matching criteria fetch error: $e');
    }
  }

  Future<void> addSenderIbanToUnit({
    required String iban,
    String? label,
    String? bankName,
    String unitId = 'd-14',
  }) async {
    final clean = iban.replaceAll(' ', '').toUpperCase();
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/residents/$unitId/matching-criteria/ibans');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'sender_iban': iban,
          'label': label,
          'bank_name': bankName,
        }),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        _matchingCriteria = UnitMatchingCriteria.fromJson(data);
        notifyListeners();
        return;
      }
    } catch (e) {
      debugPrint('addSenderIbanToUnit remote error: $e');
    }

    // Local fallback
    final currentList = List<RegisteredSenderIban>.from(_matchingCriteria?.rememberedIbans ?? []);
    currentList.removeWhere((i) => i.senderIban == clean);
    currentList.add(RegisteredSenderIban(
      senderIban: clean,
      formattedIban: iban,
      label: label,
      bankName: bankName,
    ));
    _matchingCriteria = _matchingCriteria?.copyWith(rememberedIbans: currentList);
    notifyListeners();
  }

  Future<void> deleteSenderIbanFromUnit({
    required String iban,
    String unitId = 'd-14',
  }) async {
    final clean = iban.replaceAll(' ', '').toUpperCase();
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/residents/$unitId/matching-criteria/ibans/$clean');
      final response = await http.delete(url).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        _matchingCriteria = UnitMatchingCriteria.fromJson(data);
        notifyListeners();
        return;
      }
    } catch (e) {
      debugPrint('deleteSenderIbanFromUnit remote error: $e');
    }

    // Local fallback
    final currentList = List<RegisteredSenderIban>.from(_matchingCriteria?.rememberedIbans ?? []);
    currentList.removeWhere((i) => i.senderIban == clean);
    _matchingCriteria = _matchingCriteria?.copyWith(rememberedIbans: currentList);
    notifyListeners();
  }

  Future<void> updateUnitPayerNames({
    required List<String> names,
    String unitId = 'd-14',
  }) async {
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/residents/$unitId/matching-criteria/payer-names');
      final response = await http.put(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'payer_names': names}),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        _matchingCriteria = UnitMatchingCriteria.fromJson(data);
        notifyListeners();
        return;
      }
    } catch (e) {
      debugPrint('updateUnitPayerNames remote error: $e');
    }

    // Local fallback
    _matchingCriteria = _matchingCriteria?.copyWith(registeredPayerNames: names);
    notifyListeners();
  }

  Future<bool> resetAllDemoData() async {
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/system/reset-demo-data');
      await http.post(url).timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('resetAllDemoData remote error: $e');
    }

    _activeUnit = _activeUnit.copyWith(
      advancePayment: Decimal.zero,
    );
    _duesList = [];
    _reconciliationQueue.clear();
    _accountTransactions = [];

    await fetchResidentDashboard('d-14');
    await fetchUnitMatchingCriteria('d-14');
    notifyListeners();
    return true;
  }

  Future<bool> accrueTestDue([String unitId = 'd-14']) async {
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/system/accrue-test-due');
      await http.post(url).timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('accrueTestDue remote error: $e');
    }

    await fetchResidentDashboard(unitId);
    notifyListeners();
    return true;
  }

  Future<void> fetchResidentDashboard([String unitId = 'd-14']) async {
    fetchUnitMatchingCriteria(unitId);
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/residents/$unitId/dashboard');
      final response = await http.get(url).timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

        final viban = data['virtual_iban'] as String?;
        final advance = Decimal.tryParse(data['advance_payment']?.toString() ?? '0') ?? Decimal.zero;
        final totalDebt = Decimal.tryParse(data['total_debt']?.toString() ?? '0') ?? Decimal.zero;

        _activeUnit = _activeUnit.copyWith(
          virtualIban: viban ?? _activeUnit.virtualIban,
          advancePayment: advance,
        );

        final duesJson = data['dues'] as List<dynamic>?;
        if (duesJson != null && duesJson.isNotEmpty) {
          _duesList = duesJson.map((d) {
            final item = d as Map<String, dynamic>;
            final isItemPaid = item['status'] == 'PAID';
            return DuesLiability(
              id: item['id'] as String? ?? 'b-101',
              unitId: unitId,
              period: item['period'] as String? ?? 'Eylül 2026',
              principalAmount: Decimal.tryParse(item['principal_amount']?.toString() ?? '1400.00') ?? Decimal.parse('1400.00'),
              delayPenalty: isItemPaid ? Decimal.zero : (Decimal.tryParse(item['delay_penalty']?.toString() ?? '0') ?? Decimal.zero),
              totalAmount: isItemPaid ? Decimal.zero : (Decimal.tryParse(item['total_amount']?.toString() ?? '0') ?? Decimal.zero),
              dueDate: DateTime.tryParse(item['due_date']?.toString() ?? '2026-09-15') ?? DateTime(2026, 9, 15),
              status: isItemPaid
                  ? DebtStatus.paid
                  : (data['is_overdue'] == true ? DebtStatus.overdue : DebtStatus.pending),
            );
          }).toList();
        } else if (totalDebt <= Decimal.zero) {
          _duesList = [];
        }

        final txList = data['transactions'] as List<dynamic>?;
        if (txList != null) {
          _accountTransactions = txList.map((t) => AccountTransactionItem.fromJson(t as Map<String, dynamic>)).toList();
        }

        notifyListeners();
      }
      fetchReconciliationQueue();
    } catch (e) {
      debugPrint('Dashboard live sync offline fallback: $e');
    }
  }

  Future<void> fetchReconciliationQueue([String siteId = 'site-1']) async {
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/bank/statements/reconciliation-queue?site_id=$siteId');
      final response = await http.get(url).timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final list = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>?;
        if (list != null && list.isNotEmpty) {
          final liveItems = list.map((item) => ReconciliationQueueItem.fromJson(item as Map<String, dynamic>)).toList();
          bool added = false;
          for (final liveItem in liveItems) {
            final exists = _reconciliationQueue.any((q) =>
                q.matchId == liveItem.matchId ||
                q.transaction.transactionId == liveItem.transaction.transactionId);
            if (!exists) {
              _reconciliationQueue.insert(0, liveItem);
              added = true;
            }
          }
          if (added) {
            notifyListeners();
          }
        }
      }
    } catch (e) {
      debugPrint('Reconciliation queue fetch error: $e');
    }
  }

  Future<Map<String, dynamic>> accrueMonthlyDues({
    required String period,
    String siteId = 'site-1',
    Decimal? amount,
    DateTime? dueDate,
  }) async {
    final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
    final url = Uri.parse('http://$host:8080/api/v1/dues/accrue-period');
    final dueAmount = amount ?? Decimal.parse('1400.00');
    final dt = dueDate ?? DateTime(2026, 10, 15);
    final formattedDueDate =
        "${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'site_id': siteId,
          'period': period,
          'amount': dueAmount.toString(),
          'due_date': formattedDueDate,
        }),
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

        // Refresh resident dashboard state
        await fetchResidentDashboard(_activeUnit.id);

        if (!_availableDuesMonths.contains(period)) {
          _availableDuesMonths.insert(0, period);
        }
        _selectedDuesMonth = period;

        final isAlreadyAccrued = data['already_accrued'] == true;
        if (!isAlreadyAccrued) {
          final autoSettled = (data['auto_settled_units_count'] as num?)?.toInt() ?? 0;
          _monthlyFlats[period] = _flatsList.map<FlatPaymentStatus>((f) {
            final isSettled = f.id == _activeUnit.id && autoSettled > 0;
            return f.copyWith(
              isPaid: isSettled,
              daysOverdue: 0,
            );
          }).toList();
        }

        notifyListeners();
        return data;
      } else {
        return {
          'already_accrued': false,
          'message': 'İstek başarısız oldu (${response.statusCode}): ${response.body}',
        };
      }
    } catch (e) {
      debugPrint('accrueMonthlyDues offline fallback: $e');
      if (!_availableDuesMonths.contains(period)) {
        _availableDuesMonths.insert(0, period);
      }
      _selectedDuesMonth = period;
      notifyListeners();
      return {
        'site_id': siteId,
        'period': period,
        'total_units_accrued': _flatsList.length,
        'newly_accrued_units_count': _flatsList.length,
        'auto_settled_units_count': 1,
        'total_amount_accrued': dueAmount * Decimal.fromInt(_flatsList.length),
        'total_amount_offset_from_advance': dueAmount,
        'already_accrued': false,
        'message': "'$period' dönemi için aidat tahakkuk ettirildi.",
      };
    }
  }

  void toggleTheme() {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
  }

  void toggleOfflineMode(bool offline) {
    _isOffline = offline;
    _lastSyncTime = offline ? 'Çevrimdışı önbellekten yüklendi' : 'Az önce';
    notifyListeners();
  }

  void setFlatFilter(String filter) {
    _flatFilter = filter;
    notifyListeners();
  }

  void switchSessionRole(UserRole role, {AuthProvider? provider, SiteAdminActivePath? adminPath}) {
    _userSession = _createSession(role, provider ?? _userSession.authProvider);
    if (role == UserRole.siteManager) {
      if (adminPath != null) {
        _siteAdminPath = adminPath;
      }
      _activeUnit = (_siteAdminPath == SiteAdminActivePath.myFlatOwner) ? managerUnit : defaultResidentUnit;
    } else {
      _activeUnit = defaultResidentUnit;
    }
    notifyListeners();
  }

  void loginAs({
    required UserRole role,
    SiteAdminActivePath? adminPath,
    AuthProvider provider = AuthProvider.local,
  }) {
    switchSessionRole(role, provider: provider, adminPath: adminPath);
    _isAuthenticated = true;
    _authMessage = '${role.displayName} olarak giriş yapıldı.';
    notifyListeners();
  }

  void logout() {
    _isAuthenticated = false;
    _authMessage = null;
    notifyListeners();
  }

  void setSiteAdminPath(SiteAdminActivePath path) {
    _siteAdminPath = path;
    if (path == SiteAdminActivePath.myFlatOwner) {
      _activeUnit = managerUnit;
    } else {
      _activeUnit = defaultResidentUnit;
    }
    notifyListeners();
  }

  void toggleSiteAdminPath() {
    if (_siteAdminPath == SiteAdminActivePath.managerCockpit) {
      setSiteAdminPath(SiteAdminActivePath.myFlatOwner);
    } else {
      setSiteAdminPath(SiteAdminActivePath.managerCockpit);
    }
  }

  void loginWithPassword(String email, String password) {
    if (email.trim().isEmpty || password.trim().isEmpty) {
      _authMessage = 'E-posta ve şifre zorunludur.';
      notifyListeners();
      return;
    }

    final role = email.contains('admin')
        ? UserRole.saasAdmin
        : (email.contains('yonetim') || email.contains('mehmet'))
            ? UserRole.siteManager
            : email.contains('zeynep')
                ? UserRole.homeResident
                : UserRole.homeOwner;

    _userSession = _createSession(role, AuthProvider.local, customEmail: email);
    if (role == UserRole.siteManager) {
      _activeUnit = (_siteAdminPath == SiteAdminActivePath.myFlatOwner) ? managerUnit : defaultResidentUnit;
    } else {
      _activeUnit = defaultResidentUnit;
    }
    _isAuthenticated = true;
    _authMessage = 'Şifre ile başarıyla giriş yapıldı (${role.displayName}).';
    notifyListeners();
  }

  void loginWithGoogle() {
    const role = UserRole.homeOwner;
    _userSession = _createSession(
      role,
      AuthProvider.google,
      customName: 'Ahmet Yılmaz (Google)',
      customEmail: 'ahmet.yilmaz@gmail.com',
      avatarUrl: 'https://lh3.googleusercontent.com/a/google-user-icon',
    );
    _activeUnit = defaultResidentUnit;
    _isAuthenticated = true;
    _authMessage = 'Google hesabı ile tek tıkla giriş sağlandı.';
    notifyListeners();
  }

  void registerNewSite({
    required String name,
    required String city,
    required String address,
    required String adminName,
    required String adminEmail,
    required String adminPhone,
    String planType = 'STANDARD',
  }) {
    final siteId = 'site-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
    final tempPassword = 'SP-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}-PASS';

    final newSite = TenantSiteItem(
      id: siteId,
      name: name,
      city: city,
      address: address,
      status: 'ACTIVE',
      planType: planType,
      totalUnits: 0,
      monthlyCollectionVolume: Decimal.zero,
      adminName: adminName,
      adminEmail: adminEmail,
      adminPhone: adminPhone,
      actionCount: 0,
    );

    _saasSites = [newSite, ..._saasSites];
    _provisionedCredentials = ProvisionedSiteCredentials(
      siteId: siteId,
      siteName: name,
      adminName: adminName,
      adminEmail: adminEmail,
      temporaryPassword: tempPassword,
      planType: planType,
    );
    notifyListeners();
  }

  /// Invariant Guard: Check if a site can be deleted.
  /// Allowed if and only if hasActions is false.
  bool canDeleteSite(String siteId) {
    for (final s in _saasSites) {
      if (s.id == siteId) return !s.hasActions;
    }
    return false;
  }

  /// Deletes a site if there are no related actions (units, dues, transactions).
  /// Strictly rejects deletion if site has active entities or records.
  bool deleteSite(String siteId) {
    final index = _saasSites.indexWhere((s) => s.id == siteId);
    if (index == -1) return false;
    final site = _saasSites[index];
    if (site.hasActions) {
      _authMessage = '${site.name} sitesine ait aktif hareketler bulunduğundan silinemez.';
      notifyListeners();
      return false;
    }
    _saasSites.removeAt(index);
    _authMessage = '${site.name} başarıyla silindi.';
    notifyListeners();
    return true;
  }

  /// Generates/renews a temporary management password for a site manager.
  /// Sets mustChangePassword and triggers credentials presentation dialog.
  bool resetSiteManagerPassword(String siteId) {
    final index = _saasSites.indexWhere((s) => s.id == siteId);
    if (index == -1) return false;
    final site = _saasSites[index];

    final randomPart = DateTime.now().millisecondsSinceEpoch.toString().substring(8);
    final tempPassword = 'SP-$randomPart-PASS';

    _provisionedCredentials = ProvisionedSiteCredentials(
      siteId: site.id,
      siteName: site.name,
      adminName: site.adminName,
      adminEmail: site.adminEmail,
      temporaryPassword: tempPassword,
      planType: site.planType,
      isRenewal: true,
    );
    _authMessage = '${site.name} yöneticisi için yeni geçici şifre üretildi.';
    notifyListeners();
    return true;
  }

  void clearProvisionedCredentials() {
    _provisionedCredentials = null;
    notifyListeners();
  }

  void registerHomeOwner({
    required String block,
    required int unitNo,
    required String ownerName,
    required String email,
    required String phone,
    Decimal? duesAmount,
    bool isResident = true,
  }) {
    final dues = duesAmount ?? Decimal.parse('1400.00');
    final tempPassword = 'SP-SAKIN-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}';
    final cleanBlock = block.replaceAll('Blok', '').trim();

    final newFlat = FlatPaymentStatus(
      id: 'f-${DateTime.now().millisecondsSinceEpoch}',
      block: cleanBlock,
      unitNo: unitNo,
      residentName: ownerName,
      amountDue: dues,
      daysOverdue: 0,
      isPaid: false,
    );

    _flatsList = [newFlat, ..._flatsList];
    _collectionSummary = _collectionSummary.copyWith(
      totalUnitsCount: _collectionSummary.totalUnitsCount + 1,
      overdueUnitsCount: _collectionSummary.overdueUnitsCount + 1,
      totalExpected: _collectionSummary.totalExpected + dues,
    );

    _provisionedHomeOwner = ProvisionedHomeOwnerCredentials(
      block: block,
      unitNo: unitNo,
      ownerName: ownerName,
      email: email,
      phone: phone,
      temporaryPassword: tempPassword,
      isResident: isResident,
      duesAmount: dues,
    );
    notifyListeners();
  }

  void clearProvisionedHomeOwner() {
    _provisionedHomeOwner = null;
    notifyListeners();
  }

  void approveRegistration(String requestId) {
    final index = _pendingRegistrations.indexWhere((r) => r.id == requestId);
    if (index == -1) return;

    final target = _pendingRegistrations[index];
    final tempPassword = 'SP-SAKIN-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}';

    _pendingRegistrations = _pendingRegistrations.where((r) => r.id != requestId).toList();

    final cleanBlock = target.block.replaceAll('Blok', '').trim();
    final newFlat = FlatPaymentStatus(
      id: 'f-${DateTime.now().millisecondsSinceEpoch}',
      block: cleanBlock,
      unitNo: target.unitNo,
      residentName: target.fullName,
      amountDue: target.duesAmount,
      daysOverdue: 0,
      isPaid: false,
    );
    _flatsList = [newFlat, ..._flatsList];

    _collectionSummary = _collectionSummary.copyWith(
      totalUnitsCount: _collectionSummary.totalUnitsCount + 1,
      overdueUnitsCount: _collectionSummary.overdueUnitsCount + 1,
      totalExpected: _collectionSummary.totalExpected + target.duesAmount,
    );

    _approvalSuccessInfo = ApprovalSuccessInfo(
      fullName: target.fullName,
      flatDesc: target.flatDesc,
      email: target.email,
      temporaryPassword: tempPassword,
    );
    notifyListeners();
  }

  void rejectRegistration(String requestId) {
    _pendingRegistrations = _pendingRegistrations.where((r) => r.id != requestId).toList();
    notifyListeners();
  }

  void clearApprovalSuccess() {
    _approvalSuccessInfo = null;
    notifyListeners();
  }

  void generateUnitInviteLink() {
    final token = 'SP-HANE-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}';
    _unitInviteInfo = UnitInviteInfo(
      inviteUrl: 'https://sitepulse.app/join/begonya-sitesi/units/d-14?token=$token',
      token: token,
      unitLabel: 'A Blok D:14',
      expiresAtStr: '7 gün geçerli',
      securityNotice: 'Bu link sadece A Blok D:14 bağımsız bölümüne erişim yetkisi verir. Diğer daire veya yönetim yetkileri kapalıdır.',
    );
    notifyListeners();
  }

  void clearUnitInviteInfo() {
    _unitInviteInfo = null;
    notifyListeners();
  }

  void clearAuthMessage() {
    _authMessage = null;
    notifyListeners();
  }

  // Bank Statement Ingestion & Automated Reconciliation Methods (STORY-07-02)

  // Site Bank Account Configuration (STORY-08-01)
  bool configureBankAccount({
    required String bankCode,
    required String iban,
    required String accountHolder,
  }) {
    final bank = SupportedBank.fromCode(bankCode);
    if (bank == null) {
      _bankStatementError = 'Geçersiz banka kodu: $bankCode';
      notifyListeners();
      return false;
    }
    final cleanIban = iban.replaceAll(' ', '').toUpperCase();
    if (!cleanIban.startsWith('TR') || cleanIban.length != 26) {
      _bankStatementError = 'Geçersiz IBAN! Türk IBAN numarası TR ile başlamalı ve 26 haneli olmalıdır.';
      notifyListeners();
      return false;
    }
    if (accountHolder.trim().isEmpty) {
      _bankStatementError = 'Hesap sahibi adı / unvanı boş bırakılamaz.';
      notifyListeners();
      return false;
    }

    _siteBankAccount = SiteBankAccount(
      id: 'sba-${DateTime.now().millisecondsSinceEpoch}',
      siteId: 'site-1',
      bankCode: bank.code,
      bankName: bank.displayName,
      iban: cleanIban,
      accountHolder: accountHolder.trim(),
      statementFormat: bank.statementFormat,
      isActive: true,
      configuredBy: _userSession.id,
      updatedAt: DateTime.now(),
    );

    _bankStatementError = null;
    notifyListeners();
    return true;
  }

  bool parseBankStatementFile({
    required String fileName,
    required Uint8List bytes,
  }) {
    _bankStatementError = null;

    // Validate format against configured bank account
    if (_siteBankAccount != null) {
      final ext = fileName.toLowerCase();
      final expectedFormat = _siteBankAccount!.statementFormat;
      if (expectedFormat == 'EXCEL') {
        if (!ext.endsWith('.xlsx') && !ext.endsWith('.xls')) {
          _bankStatementError = 'Format Reddedildi: ${_siteBankAccount!.bankName} hesabı yalnızca Excel (.xlsx / .xls) dosyalarını kabul eder. Yüklenen dosya ($fileName) reddedildi.';
          _reconciliationQueue = [];
          notifyListeners();
          return false;
        }
        // Verify not MT940 disguised as Excel
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.contains(':20:') && text.contains(':61:')) {
          _bankStatementError = 'Format Reddedildi: ${_siteBankAccount!.bankName} hesabı Excel (.xlsx) formatı gerektirir. SWIFT MT940 formatındaki dosya ($fileName) reddedildi.';
          _reconciliationQueue = [];
          notifyListeners();
          return false;
        }
      } else if (expectedFormat == 'MT940') {
        if (!ext.endsWith('.sta') && !ext.endsWith('.txt') && !ext.endsWith('.mt940')) {
          _bankStatementError = 'Format Reddedildi: ${_siteBankAccount!.bankName} hesabı yalnızca SWIFT MT940 (.sta / .txt / .mt940) dosyalarını kabul eder. Yüklenen dosya ($fileName) reddedildi.';
          _reconciliationQueue = [];
          notifyListeners();
          return false;
        }
        // Verify content contains MT940 tags
        final text = utf8.decode(bytes, allowMalformed: true);
        if (!text.contains(':61:') || !text.contains(':86:')) {
          _bankStatementError = 'Format Reddedildi: ${_siteBankAccount!.bankName} hesabı için yüklenen dosya geçerli SWIFT MT940 formatında değil (:61:, :86: etiketleri bulunamadı). Dosya reddedildi.';
          _reconciliationQueue = [];
          notifyListeners();
          return false;
        }
      } else if (expectedFormat == 'CSV') {
        if (!ext.endsWith('.csv') && !ext.endsWith('.txt')) {
          _bankStatementError = 'Format Reddedildi: ${_siteBankAccount!.bankName} hesabı yalnızca CSV (.csv) dosyalarını kabul eder. Yüklenen dosya ($fileName) reddedildi.';
          _reconciliationQueue = [];
          notifyListeners();
          return false;
        }
        // Verify user didn't upload MT940 into CSV bank
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.contains(':20:') && text.contains(':61:')) {
          _bankStatementError = 'Format Reddedildi: ${_siteBankAccount!.bankName} hesabı CSV formatı gerektirir. Yüklenen dosya SWIFT MT940 formatında olduğu için reddedildi.';
          _reconciliationQueue = [];
          notifyListeners();
          return false;
        }
      }
    }

    final rows = BankFileParser.parseBytes(fileName: fileName, bytes: bytes);
    if (rows.isEmpty) {
      _bankStatementError = 'Format Reddedildi: Yüklenen dosya ($fileName) ${_siteBankAccount?.bankName ?? "ilgili banka"} formatına uygun hareket içermediği için reddedildi.';
      _reconciliationQueue = [];
      notifyListeners();
      return false;
    }

    final List<ReconciliationQueueItem> parsedMatches = [];

    for (int i = 0; i < rows.length; i++) {
      final r = rows[i];
      final matchItem = _matchTransactionToRoster(
        description: r.description,
        amount: r.amount,
        date: r.date,
        rawId: r.rawId.isNotEmpty ? r.rawId : 'FILE-ROW-${i + 1}',
        explicitSender: r.senderName,
        isIncoming: r.isIncoming,
      );
      parsedMatches.add(matchItem);
    }

    _reconciliationQueue = parsedMatches;
    notifyListeners();
    return true;
  }

  bool parseBankStatement(String content, {String format = 'AUTO'}) {
    _bankStatementError = null;
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      _bankStatementError = 'Format Reddedildi: Ekstre içeriği boş.';
      _reconciliationQueue = [];
      notifyListeners();
      return false;
    }

    final isMt940 = trimmed.startsWith(':20:') || (trimmed.contains(':61:') && trimmed.contains(':86:'));

    // Enforce statement format from active bank or explicit format parameter
    final activeAccount = _siteBankAccount;
    final targetFormat = format != 'AUTO'
        ? format
        : (activeAccount?.statementFormat ?? 'AUTO');

    if (targetFormat != 'AUTO') {
      if (targetFormat == 'MT940' && !isMt940) {
        _bankStatementError = 'Format Reddedildi: ${activeAccount?.bankName ?? "Seçili banka"} hesabı SWIFT MT940 (:61:, :86:) formatı gerektirir. Yapıştırılan içerik MT940 formatında olmadığı için reddedildi.';
        _reconciliationQueue = [];
        notifyListeners();
        return false;
      } else if (targetFormat == 'EXCEL' && isMt940) {
        _bankStatementError = 'Format Reddedildi: ${activeAccount?.bankName ?? "Seçili banka"} hesabı Excel (.xlsx) formatı gerektirir. SWIFT MT940 formatındaki içerik reddedildi.';
        _reconciliationQueue = [];
        notifyListeners();
        return false;
      } else if (targetFormat == 'CSV' && isMt940) {
        _bankStatementError = 'Format Reddedildi: ${activeAccount?.bankName ?? "Seçili banka"} hesabı CSV (.csv) formatı gerektirir. SWIFT MT940 formatındaki içerik reddedildi.';
        _reconciliationQueue = [];
        notifyListeners();
        return false;
      }
    }

    final lines = content.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final List<ReconciliationQueueItem> parsedMatches = [];

    // Check MT940 format
    if (content.contains(':61:') && content.contains(':86:')) {
      final reg61 = RegExp(r':61:\s*(\d{6})(?:\d{4})?(?:C|D|RC|RD|CR|DR)([0-9]+,[0-9]{2})');
      final reg86 = RegExp(r':86:\s*(.+?)(?=(?:\r?\n:[0-9]{2}[A-Z]?:)|$)', dotAll: true);

      final m61 = reg61.firstMatch(content);
      final m86 = reg86.firstMatch(content);

      if (m61 != null && m86 != null) {
        final amtStr = m61.group(2)!.replaceAll(',', '.');
        final amt = Decimal.tryParse(amtStr) ?? Decimal.parse('1423.33');
        final narrative = m86.group(1)!.replaceAll('\n', ' ').trim();

        final matchItem = _matchTransactionToRoster(
          description: narrative,
          amount: amt,
          date: DateTime(2026, 9, 15),
          rawId: 'TXN-MT940-001',
        );
        parsedMatches.add(matchItem);
      }
    } else {
      final parsedRows = BankFileParser.parseText(content);
      if (parsedRows.isNotEmpty) {
        for (int i = 0; i < parsedRows.length; i++) {
          final r = parsedRows[i];
          final matchItem = _matchTransactionToRoster(
            description: r.description,
            amount: r.amount,
            date: r.date,
            rawId: r.rawId.isNotEmpty ? r.rawId : 'TXN-ROW-${i + 1}',
            explicitSender: r.senderName,
            isIncoming: r.isIncoming,
          );
          parsedMatches.add(matchItem);
        }
      } else {
        // Delimited or free-form text lines (Excel / CSV)
        int rowIdx = 1;
        for (final line in lines) {
          if (line.toLowerCase().contains('tarih') &&
              (line.toLowerCase().contains('tutar') || line.toLowerCase().contains('alacak'))) {
            continue; // header
          }

          final amtReg = RegExp(r'₺?\s*([0-9]{1,3}(?:\.[0-9]{3})*,[0-9]{2}|[0-9]+[.,][0-9]{2})');
          final amtMatch = amtReg.firstMatch(line);
          if (amtMatch != null) {
            var cleanAmt = amtMatch.group(1)!;
            if (cleanAmt.contains('.') && cleanAmt.contains(',')) {
              cleanAmt = cleanAmt.replaceAll('.', '').replaceAll(',', '.');
            } else if (cleanAmt.contains(',')) {
              cleanAmt = cleanAmt.replaceAll(',', '.');
            }
            final amt = Decimal.tryParse(cleanAmt) ?? Decimal.zero;

            final matchItem = _matchTransactionToRoster(
              description: line,
              amount: amt,
              date: DateTime(2026, 9, 15),
              rawId: 'TXN-EXCEL-${rowIdx.toString().padLeft(3, '0')}',
            );
            parsedMatches.add(matchItem);
            rowIdx++;
          }
        }
      }
    }

    if (parsedMatches.isEmpty) {
      _bankStatementError = 'Format Reddedildi: İçerikte ${activeAccount?.bankName ?? "ilgili banka"} formatına uygun işlem satırı bulunamadı.';
      _reconciliationQueue = [];
      notifyListeners();
      return false;
    }

    _reconciliationQueue = parsedMatches;
    notifyListeners();
    return true;
  }

  ReconciliationQueueItem _matchTransactionToRoster({
    required String description,
    required Decimal amount,
    required DateTime date,
    required String rawId,
    String? explicitSender,
    bool isIncoming = true,
  }) {
    // 1. Detect block and flat
    String? matchedBlock;
    int? matchedUnitNo;
    String? matchedResidentName;
    String? matchedUnitId;
    String? matchedDueId;
    Decimal? outstandingBalance;
    bool amountMatchesBalance = false;
    int confidence = 0;

    final blockReg = RegExp(r'\b([A-Z0-9]+)\s*blok\b', caseSensitive: false);
    final flatReg = RegExp(r'\b(?:d[:\.\s-]*|daire[:\.\s-]*|no[:\.\s-]*)(\d+)\b', caseSensitive: false);

    final bMatch = blockReg.firstMatch(description);
    if (bMatch != null) {
      matchedBlock = bMatch.group(1)!.toUpperCase();
    }

    final fMatch = flatReg.firstMatch(description);
    if (fMatch != null) {
      matchedUnitNo = int.tryParse(fMatch.group(1)!);
    }

    // Match against flats by UnitNo
    FlatPaymentStatus? candidateFlat;
    if (matchedUnitNo != null) {
      for (final f in _flatsList) {
        if (f.unitNo == matchedUnitNo && (matchedBlock == null || f.block == matchedBlock)) {
          candidateFlat = f;
          matchedBlock ??= f.block;
          matchedResidentName = f.residentName;
          matchedUnitId = f.unitNo == 14 ? 'd-14' : 'd-${f.unitNo}';
          break;
        }
      }
    }

    // Check explicitSender or resident name in description
    if (matchedResidentName == null) {
      String normalizeTr(String text) {
        return text
            .toUpperCase()
            .replaceAll('İ', 'I')
            .replaceAll('ı', 'I')
            .replaceAll('Ğ', 'G')
            .replaceAll('Ü', 'U')
            .replaceAll('Ş', 'S')
            .replaceAll('Ö', 'O')
            .replaceAll('Ç', 'C');
      }

      final normDesc = normalizeTr(description);
      final normSender = explicitSender != null ? normalizeTr(explicitSender) : '';

      for (final f in _flatsList) {
        final normName = normalizeTr(f.residentName);
        if ((normSender.isNotEmpty && normSender.contains(normName)) || normDesc.contains(normName)) {
          candidateFlat = f;
          matchedBlock = f.block;
          matchedUnitNo = f.unitNo;
          matchedResidentName = f.residentName;
          matchedUnitId = f.unitNo == 14 ? 'd-14' : 'd-${f.unitNo}';
          break;
        }
      }
    }

    if (!isIncoming) {
      // Outgoing expense or transfer, not an incoming dues payment
      return ReconciliationQueueItem(
        matchId: 'MATCH-${DateTime.now().millisecondsSinceEpoch}-${rawId.hashCode.abs() % 1000}',
        transaction: BankStatementParsedItem(
          transactionId: rawId,
          date: date,
          amount: amount,
          currency: 'TRY',
          description: description,
        ),
        matchedUnitId: null,
        matchedBlock: null,
        matchedUnitNumber: null,
        matchedResidentName: explicitSender,
        confidenceScore: 0,
        matchedDueId: null,
        outstandingBalance: null,
        amountMatchesBalance: false,
        status: 'GIDER',
        notes: 'Giden Transfer / Banka Masrafı (Aidat Tahsilatı Değil)',
      );
    }

    final effectiveBlock = matchedBlock ?? candidateFlat?.block;
    final effectiveUnitNo = matchedUnitNo ?? candidateFlat?.unitNo;
    final String? unitKey = (effectiveBlock != null && effectiveUnitNo != null)
        ? '${effectiveBlock}_$effectiveUnitNo'
        : null;

    final bool isTxnAlreadyProcessed = _processedTransactionIds.contains(rawId);
    final bool isFlatAlreadyPaid = candidateFlat != null && candidateFlat.isPaid;
    final bool isUnitAlreadyProcessed = unitKey != null && _processedUnitKeys.contains(unitKey);
    final bool isAlreadyUploaded = isTxnAlreadyProcessed || isFlatAlreadyPaid || isUnitAlreadyProcessed;

    String status;
    String? notes;

    if (isAlreadyUploaded) {
      confidence = 100;
      status = 'ZATEN_YUKLENDI';
      final paidDate = candidateFlat?.paidDateStr != null ? ' (${candidateFlat!.paidDateStr})' : '';
      notes = 'Daha önce zaten yüklenmiş / ödenmiş aidat$paidDate. Mükerrer işlem önlendi.';
      outstandingBalance = Decimal.zero;
      amountMatchesBalance = true;
    } else if (candidateFlat != null) {
      outstandingBalance = candidateFlat.amountDue;
      matchedDueId = 'b-101';
      amountMatchesBalance = (amount == outstandingBalance);
      confidence = amountMatchesBalance ? 100 : 90;
      status = confidence >= 70 ? 'ONAY_BEKLIYOR' : 'ESLESTIRILEMEDI';
      notes = amountMatchesBalance
          ? 'Aidat borcuyla (%5 KMK gecikme tazminatı dahil) birebir eşleşti'
          : 'Daire ve sakin tespit edildi';
    } else {
      confidence = 0;
      status = 'ESLESTIRILEMEDI';
      notes = null;
    }

    return ReconciliationQueueItem(
      matchId: 'MATCH-${DateTime.now().millisecondsSinceEpoch}-${rawId.hashCode.abs() % 1000}',
      transaction: BankStatementParsedItem(
        transactionId: rawId,
        date: date,
        amount: amount,
        currency: 'TRY',
        description: description,
      ),
      matchedUnitId: matchedUnitId,
      matchedBlock: matchedBlock,
      matchedUnitNumber: matchedUnitNo,
      matchedResidentName: matchedResidentName,
      confidenceScore: confidence,
      matchedDueId: matchedDueId,
      outstandingBalance: outstandingBalance,
      amountMatchesBalance: amountMatchesBalance,
      status: status,
      notes: notes,
    );
  }

  void manuallyAssignFlatToTransaction({
    required String matchId,
    required String block,
    required int unitNo,
  }) {
    final idx = _reconciliationQueue.indexWhere((m) => m.matchId == matchId);
    if (idx == -1) return;

    final target = _reconciliationQueue[idx];
    FlatPaymentStatus? candidateFlat;
    for (final f in _flatsList) {
      if (f.unitNo == unitNo && f.block == block) {
        candidateFlat = f;
        break;
      }
    }

    final balance = candidateFlat?.amountDue;
    final amtMatch = (balance != null && target.transaction.amount == balance);

    final updated = target.copyWith(
      matchedUnitId: candidateFlat != null ? (unitNo == 14 ? 'd-14' : 'd-$unitNo') : 'd-$unitNo',
      matchedBlock: block,
      matchedUnitNumber: unitNo,
      matchedResidentName: candidateFlat?.residentName ?? 'Daire $unitNo',
      confidenceScore: 100,
      matchedDueId: 'b-101',
      outstandingBalance: balance,
      amountMatchesBalance: amtMatch,
      status: 'ONAY_BEKLIYOR',
      notes: 'Yönetici tarafından manuel olarak eşleştirildi${amtMatch ? " (Borçla tam eşleşti)" : ""}',
    );

    _reconciliationQueue[idx] = updated;
    notifyListeners();
  }

  void confirmReconciliation(
    List<String> matchIds, {
    String? optionalHostMessage,
    bool rememberSenderIban = true,
  }) {
    if (matchIds.isEmpty) return;

    Decimal totalCleared = Decimal.zero;
    final List<ReconciliationQueueItem> updatedQueue = [];
    int rememberedIbansCount = 0;

    for (final item in _reconciliationQueue) {
      if (matchIds.contains(item.matchId)) {
        updatedQueue.add(item.copyWith(status: 'ONAYLANDI'));
        _processedTransactionIds.add(item.transaction.transactionId);
        if (item.matchedUnitNumber != null) {
          _processedUnitKeys.add('${item.matchedBlock ?? "A"}_${item.matchedUnitNumber}');
        }

        // Persist remembered sender IBAN for future automatic payments matching
        if (rememberSenderIban && item.transaction.senderIban != null && item.transaction.senderIban!.isNotEmpty) {
          final unitId = item.matchedUnitId ?? 'd-${item.matchedUnitNumber ?? 14}';
          _persistRememberedSenderIban(
            unitId: unitId,
            senderIban: item.transaction.senderIban!,
            senderName: item.transaction.senderName,
          );
          rememberedIbansCount++;
        }

        // Record optional message dispatch to host
        if (optionalHostMessage != null && optionalHostMessage.trim().isNotEmpty) {
          _sentHostMessages.add(
            ReconciliationHostMessage(
              messageId: 'MSG-${DateTime.now().millisecondsSinceEpoch}-${item.matchId}',
              matchId: item.matchId,
              block: item.matchedBlock ?? 'A',
              unitNo: item.matchedUnitNumber ?? 0,
              residentName: item.matchedResidentName ?? 'Kat Sakini',
              amount: item.transaction.amount,
              messageText: optionalHostMessage.trim(),
              sentAt: DateTime.now(),
            ),
          );
        }

        // Clear in flats list
        if (item.matchedUnitNumber != null) {
          final flatIndex = _flatsList.indexWhere((f) =>
              f.unitNo == item.matchedUnitNumber &&
              (item.matchedBlock == null || f.block == item.matchedBlock));

          if (flatIndex != -1) {
            final flat = _flatsList[flatIndex];
            final paymentAmount = item.transaction.amount;

            if (!flat.isPaid) {
              _flatsList[flatIndex] = flat.copyWith(
                isPaid: true,
                daysOverdue: 0,
                paidDateStr: 'Banka Ekstresi',
              );
              totalCleared += paymentAmount;
              if (paymentAmount > flat.amountDue) {
                final surplus = paymentAmount - flat.amountDue;
                _creditUnitAdvance(item.matchedBlock ?? flat.block, flat.unitNo, surplus);
              }

              _collectionSummary = _collectionSummary.copyWith(
                paidUnitsCount: _collectionSummary.paidUnitsCount + 1,
                overdueUnitsCount: _collectionSummary.overdueUnitsCount > 0
                    ? _collectionSummary.overdueUnitsCount - 1
                    : 0,
                totalCollected: _collectionSummary.totalCollected + paymentAmount,
                totalOverdueWithInterest: _collectionSummary.totalOverdueAmount > flat.amountDue
                    ? _collectionSummary.totalOverdueAmount - flat.amountDue
                    : Decimal.zero,
              );
            } else {
              // Flat has NO debt (already paid or zero debt): match entire payment as advance payment!
              totalCleared += paymentAmount;
              _creditUnitAdvance(item.matchedBlock ?? flat.block, flat.unitNo, paymentAmount);
            }
          }
        }
      } else {
        updatedQueue.add(item);
      }
    }

    _reconciliationQueue = updatedQueue;
    final messageNote = (optionalHostMessage != null && optionalHostMessage.trim().isNotEmpty)
        ? ' ve kat sakin(ler)ine bilgilendirme mesajı iletildi'
        : ' ve borç kapatıldı';
    final ibanNote = rememberedIbansCount > 0
        ? ' (Gönderici IBAN gelecekteki ödemeler için kalıcı olarak eşleştirildi)'
        : '';
    _reconciliationSuccessMessage =
        '₺${totalCleared.toStringAsFixed(2)} tutarındaki banka aidat transferi başarıyla onaylandı$messageNote$ibanNote.';
    notifyListeners();
  }

  Future<void> _persistRememberedSenderIban({
    required String unitId,
    required String senderIban,
    String? senderName,
  }) async {
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/bank/remembered-ibans');
      await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'site_id': 'site-1',
          'unit_id': unitId,
          'sender_iban': senderIban,
          'sender_name': senderName,
        }),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {
      // Best-effort in offline/test environment
    }
  }

  void _creditUnitAdvance(String block, int unitNo, Decimal amount) {
    if (_activeUnit.unitNo == unitNo && _activeUnit.block == block) {
      final currentAdv = _activeUnit.advancePayment ?? Decimal.zero;
      _activeUnit = _activeUnit.copyWith(
        advancePayment: currentAdv + amount,
      );
    }
  }

  /// Records an in-app payment sent by a homeowner.
  /// Matches against outstanding unit debts first.
  /// If no debt exists (or if payment exceeds debt), credits remainder to advancePayment (Avans Bakiye).
  Future<void> recordHomeownerPayment({
    required String block,
    required int unitNo,
    required Decimal amount,
    String paymentMethod = 'CREDIT_CARD',
    String? note,
  }) async {
    final flatIndex = _flatsList.indexWhere((f) => f.unitNo == unitNo && f.block == block);
    Decimal clearedDebt = Decimal.zero;
    Decimal advanceCredit = Decimal.zero;

    if (flatIndex != -1) {
      final flat = _flatsList[flatIndex];
      if (!flat.isPaid && flat.amountDue > Decimal.zero) {
        if (amount >= flat.amountDue) {
          clearedDebt = flat.amountDue;
          advanceCredit = amount - flat.amountDue;
          _flatsList[flatIndex] = flat.copyWith(
            isPaid: true,
            daysOverdue: 0,
            paidDateStr: paymentMethod == 'CREDIT_CARD' ? 'Kredi Kartı (3D Secure)' : 'FAST / Havale',
          );
          _collectionSummary = _collectionSummary.copyWith(
            paidUnitsCount: _collectionSummary.paidUnitsCount + 1,
            overdueUnitsCount: _collectionSummary.overdueUnitsCount > 0 ? _collectionSummary.overdueUnitsCount - 1 : 0,
            totalCollected: _collectionSummary.totalCollected + clearedDebt,
            totalOverdueWithInterest: _collectionSummary.totalOverdueAmount > clearedDebt
                ? _collectionSummary.totalOverdueAmount - clearedDebt
                : Decimal.zero,
          );
        } else {
          clearedDebt = amount;
          _flatsList[flatIndex] = flat.copyWith(amountDue: flat.amountDue - amount);
          _collectionSummary = _collectionSummary.copyWith(
            totalCollected: _collectionSummary.totalCollected + amount,
            totalOverdueWithInterest: _collectionSummary.totalOverdueAmount > amount
                ? _collectionSummary.totalOverdueAmount - amount
                : Decimal.zero,
          );
        }
      } else {
        // No debt: full amount is advance payment
        advanceCredit = amount;
      }
    } else {
      advanceCredit = amount;
    }

    if (advanceCredit > Decimal.zero) {
      _creditUnitAdvance(block, unitNo, advanceCredit);
    }

    // Optimistically update resident dues list for active unit
    if (_activeUnit.unitNo == unitNo && _activeUnit.block == block) {
      if (clearedDebt > Decimal.zero) {
        _duesList = _duesList.map((d) {
          if (clearedDebt >= d.totalAmount) {
            return d.copyWith(
              status: DebtStatus.paid,
              totalAmount: Decimal.zero,
              delayPenalty: Decimal.zero,
              daysOverdue: 0,
            );
          } else {
            return d.copyWith(
              totalAmount: d.totalAmount - clearedDebt,
            );
          }
        }).toList();
      }
    }

    final isCard = paymentMethod == 'CREDIT_CARD';
    final txTitle = isCard
        ? (clearedDebt > Decimal.zero ? 'Kart ile Aidat Ödemesi' : 'Kart ile Avans Yükleme')
        : (clearedDebt > Decimal.zero ? 'FAST ile Aidat Ödemesi' : 'FAST ile Avans Yükleme');

    final txSubtitle = advanceCredit > Decimal.zero && clearedDebt > Decimal.zero
        ? '₺${clearedDebt.toStringAsFixed(2)} borç kapatıldı • ₺${advanceCredit.toStringAsFixed(2)} avans bakiyenize aktarıldı'
        : (clearedDebt > Decimal.zero ? 'Aidat borcu başarıyla kapatıldı' : 'Aktif borç bulunmuyor • Avans bakiyenize aktarıldı');

    _accountTransactions.insert(
      0,
      AccountTransactionItem(
        id: 'TXN-APP-${DateTime.now().millisecondsSinceEpoch}',
        title: txTitle,
        subtitle: txSubtitle,
        amount: amount,
        date: 'Bugün',
        isCredit: true,
      ),
    );

    notifyListeners();

    // Sync with backend API
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/payments/record');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'site_id': 'site-1',
          'unit_id': _activeUnit.id,
          'block': block,
          'unit_no': unitNo,
          'amount': amount.toString(),
          'payment_method': paymentMethod,
          'note': note ?? (isCard ? 'Kart ile Aidat Ödemesi' : 'FAST ile Aidat Ödemesi'),
        }),
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        await fetchResidentDashboard(_activeUnit.id);
      }
    } catch (e) {
      debugPrint('recordHomeownerPayment backend sync: $e');
    }
  }

  void clearReconciliationSuccess() {
    _reconciliationSuccessMessage = null;
    notifyListeners();
  }

  UserSession _createSession(
    UserRole role,
    AuthProvider provider, {
    String? customName,
    String? customEmail,
    String? customPhone,
    String? avatarUrl,
  }) {
    final List<PermissionScope> permissions;
    switch (role) {
      case UserRole.saasAdmin:
        permissions = const [
          PermissionScope(code: 'TENANT_MANAGE', title: 'Site & Abonelik Yönetimi', isGranted: true, isolationNote: 'Platform geneli tüm kiracılar'),
          PermissionScope(code: 'SITE_MANAGE', title: 'Site Altyapı Denetimi', isGranted: true, isolationNote: 'Tüm siteleri yapılandırma'),
          PermissionScope(code: 'ANNOUNCEMENT_BROADCAST', title: 'Global Duyuru', isGranted: true, isolationNote: 'Tüm platform duyuruları'),
        ];
        break;
      case UserRole.siteManager:
        permissions = const [
          PermissionScope(code: 'SITE_MANAGE', title: 'Begonya Sitesi Yönetimi', isGranted: true, isolationNote: 'Blok, daire ve personel yönetimi'),
          PermissionScope(code: 'RESIDENT_INVITE_SITE', title: 'Site Kayıt Linki Üretme', isGranted: true, isolationNote: 'Site geneli self-registration'),
          PermissionScope(code: 'RESIDENT_APPROVE', title: 'Sakin Başvuru Onayı', isGranted: true, isolationNote: 'Onay kuyruğu ve şifre üretimi'),
          PermissionScope(code: 'LEDGER_MANAGE_ALL', title: 'Aidat & Finans Yönetimi', isGranted: true, isolationNote: 'Tüm dairelerin borç ve faiz takibi'),
          PermissionScope(code: 'ANNOUNCEMENT_BROADCAST', title: 'Site Geneli Duyuru', isGranted: true, isolationNote: 'Tüm dairelere SMS/bildirim'),
        ];
        break;
      case UserRole.homeOwner:
        permissions = const [
          PermissionScope(code: 'UNIT_READ', title: 'Daire Aidat & Makbuz Görüntüleme', isGranted: true, isolationNote: 'Sadece A Blok D:14'),
          PermissionScope(code: 'UNIT_PAY', title: 'Online Aidat Ödeme (Kredi Kartı)', isGranted: true, isolationNote: 'Sadece A Blok D:14'),
          PermissionScope(code: 'UNIT_INVITE_CO_RESIDENT', title: 'Hane Sakini Davet Linki Üretme', isGranted: true, isolationNote: 'Sadece A Blok D:14'),
          PermissionScope(code: 'UNIT_MANAGE_HOUSEHOLD', title: 'Hane Sakinlerini Listeleme/Ekleme', isGranted: true, isolationNote: 'Sadece A Blok D:14'),
          PermissionScope(code: 'LEDGER_MANAGE_ALL', title: 'Site Finansını Yönetme', isGranted: false, isolationNote: 'Engelli: Kat malikleri diğer daireleri göremez'),
        ];
        break;
      case UserRole.homeResident:
        permissions = const [
          PermissionScope(code: 'UNIT_READ', title: 'Daire Aidat & Makbuz Görüntüleme', isGranted: true, isolationNote: 'Sadece A Blok D:14'),
          PermissionScope(code: 'UNIT_PAY', title: 'Online Aidat Ödeme', isGranted: true, isolationNote: 'Sadece A Blok D:14'),
          PermissionScope(code: 'UNIT_INVITE_CO_RESIDENT', title: 'Hane Sakini Davet Linki', isGranted: false, isolationNote: 'Engelli: Sadece Kat Maliki davet linki üretebilir'),
          PermissionScope(code: 'UNIT_MANAGE_HOUSEHOLD', title: 'Hane Sakinlerini Yönetme', isGranted: false, isolationNote: 'Engelli: Aile sakinleri üye ekleyemez'),
          PermissionScope(code: 'LEDGER_MANAGE_ALL', title: 'Site Finansını Yönetme', isGranted: false, isolationNote: 'Engelli: Site yönetimi yetkisi yok'),
        ];
        break;
    }

    final name = customName ??
        (role == UserRole.saasAdmin
            ? 'SaaS Platform Admin'
            : role == UserRole.siteManager
                ? 'Mehmet Demir'
                : role == UserRole.homeResident
                    ? 'Zeynep Yılmaz'
                    : 'Ahmet Yılmaz');

    final email = customEmail ??
        (role == UserRole.saasAdmin
            ? 'admin@sitepulse.io'
            : role == UserRole.siteManager
                ? 'mehmet.demir@begonya.com'
                : role == UserRole.homeResident
                    ? 'zeynep.yilmaz@gmail.com'
                    : 'ahmet.yilmaz@gmail.com');

    return UserSession(
      id: 'usr-${role.name}',
      fullName: name,
      email: email,
      phone: customPhone ?? '0532 111 22 33',
      role: role,
      siteName: 'Begonya Sitesi',
      unitName: (role == UserRole.homeOwner || role == UserRole.homeResident)
          ? 'A Blok D:14'
          : 'Tüm Kompleks',
      authProvider: provider,
      avatarUrl: avatarUrl,
      permissions: permissions,
    );
  }
}
