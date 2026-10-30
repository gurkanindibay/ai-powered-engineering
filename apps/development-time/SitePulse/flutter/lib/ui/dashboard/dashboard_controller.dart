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



  DashboardController({
    CalculateDuesUseCase? calculateDuesUseCase,
    bool startAuthenticated = false,
    this.isTestMode = false,
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
  ApartmentUnit _activeUnit = ApartmentUnit.empty;
  /// Flag indicating whether the controller is operating under active test fixtures (for unit/widget testing)
  bool isTestMode = false;

  ApartmentUnit _managerUnit = ApartmentUnit.empty;
  ApartmentUnit get activeUnit =>
      (_userSession.role == UserRole.siteManager && _siteAdminPath == SiteAdminActivePath.myFlatOwner)
          ? _managerUnit
          : _activeUnit;
  ApartmentUnit get activeDaire => activeUnit;
  String get siteName => activeUnit.siteAdi.isNotEmpty
      ? activeUnit.siteAdi
      : (_currentManagedSite?.name ?? (_saasSites.isNotEmpty ? _saasSites.first.name : ''));

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
          id: '',
          unitId: activeUnit.id,
          period: '',
          principalAmount: Decimal.zero,
          delayPenalty: Decimal.zero,
          totalAmount: Decimal.zero,
          dueDate: DateTime.now(),
          daysOverdue: 0,
          status: DebtStatus.paid,
        );

  List<AccountTransactionItem> _accountTransactions = [];
  List<AccountTransactionItem> get accountTransactions => _accountTransactions;

  List<UnitResidentMember> _unitResidents = [];
  List<UnitResidentMember> _managerResidents = [];
  List<UnitResidentMember> get unitResidents {
    if (_userSession.role == UserRole.siteManager && _siteAdminPath == SiteAdminActivePath.myFlatOwner) {
      return _managerResidents;
    }
    return _unitResidents;
  }

  UnitInviteInfo? _unitInviteInfo;
  UnitInviteInfo? get unitInviteInfo => _unitInviteInfo;

  // Manager state
  ComplexCollectionSummary _collectionSummary = ComplexCollectionSummary();
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
  String _selectedDuesMonth = '';
  String get selectedDuesMonth => _selectedDuesMonth;

  List<String> get availableDuesMonths => _availableDuesMonths;
  List<String> _availableDuesMonths = [];

  final Map<String, List<FlatPaymentStatus>> _monthlyFlats = {};

  void setSelectedDuesMonth(String month) {
    if (_selectedDuesMonth != month) {
      _selectedDuesMonth = month;
      if (_monthlyFlats.containsKey(month) && _monthlyFlats[month]!.isNotEmpty) {
        _flatsList = List<FlatPaymentStatus>.from(_monthlyFlats[month]!);
        _syncCollectionSummaryForMonth(month);
      }
      fetchSiteManagerOverview(siteId: _currentManagedSite?.id, period: month);
      notifyListeners();
    }
  }

  void _syncCollectionSummaryForMonth(String month) {
    final list = _monthlyFlats[month] ?? _flatsList;
    int paid = list.where((f) => f.isPaid && f.amountDue > Decimal.zero).length;
    int overdue = list.where((f) => !f.isPaid && f.amountDue > Decimal.zero).length;
    Decimal collected = Decimal.zero;
    Decimal remaining = Decimal.zero;
    Decimal advanceTotal = Decimal.zero;
    for (final f in list) {
      advanceTotal += f.advanceBalance;
      if (f.isPaid) {
        collected += f.amountDue;
      } else {
        remaining += f.amountDue;
      }
    }
    _collectionSummary = ComplexCollectionSummary(
      totalExpected: collected + remaining,
      totalCollected: collected,
      totalOverdueWithInterest: remaining,
      totalAdvanceBalance: advanceTotal,
      paidUnitsCount: paid,
      overdueUnitsCount: overdue,
      totalUnitsCount: list.length,
    );
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
    int paid = list.where((f) => f.isPaid && f.amountDue > Decimal.zero).length;
    int overdue = list.where((f) => !f.isPaid && f.amountDue > Decimal.zero).length;
    Decimal collected = Decimal.zero;
    Decimal remaining = Decimal.zero;
    Decimal advanceTotal = Decimal.zero;
    for (final f in list) {
      advanceTotal += f.advanceBalance;
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
      totalAdvanceBalance: advanceTotal,
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

  List<HomeOwnerItem> _homeOwners = [];
  List<HomeOwnerItem> get homeOwners => _homeOwners;

  final Map<String, List<OccupancyHistoryItem>> _localOccupancyHistory = {};
  Map<String, List<OccupancyHistoryItem>> get localOccupancyHistory => _localOccupancyHistory;

  bool _isLoadingHomeOwners = false;
  bool get isLoadingHomeOwners => _isLoadingHomeOwners;

  // SaaS Admin & Managed Site state
  List<TenantSiteItem> _saasSites = [];
  List<TenantSiteItem> get saasSites => _saasSites;

  TenantSiteItem? _currentManagedSite;
  TenantSiteItem? get currentManagedSite => _currentManagedSite;

  List<TenantSiteItem> _managedSitesList = [];
  List<TenantSiteItem> get managedSitesList => _managedSitesList;

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

  // House Types & Dues Tariffs
  List<HouseTypeTariff> _houseTypes = [
    HouseTypeTariff(id: '1', siteId: '1', typeName: '1+1', duesAmount: Decimal.parse('1000.00'), description: '1 Oda 1 Salon'),
    HouseTypeTariff(id: '2', siteId: '1', typeName: '2+1', duesAmount: Decimal.parse('1400.00'), description: '2 Oda 1 Salon'),
    HouseTypeTariff(id: '3', siteId: '1', typeName: '3+1', duesAmount: Decimal.parse('1800.00'), description: '3 Oda 1 Salon'),
    HouseTypeTariff(id: '4', siteId: '1', typeName: '4+1', duesAmount: Decimal.parse('2200.00'), description: '4 Oda 1 Salon'),
    HouseTypeTariff(id: '5', siteId: '1', typeName: 'Dublex', duesAmount: Decimal.parse('2500.00'), description: 'Çatı Dubleks / Bahçe Katı'),
  ];
  List<HouseTypeTariff> get houseTypes {
    final seen = <String>{};
    final unique = <HouseTypeTariff>[];
    for (final ht in _houseTypes) {
      if (seen.add(ht.typeName.toLowerCase())) {
        unique.add(ht);
      }
    }
    return unique;
  }

  @visibleForTesting
  void setHouseTypesForTesting(List<HouseTypeTariff> types) {
    _houseTypes = List.from(types);
    notifyListeners();
  }

  Future<void> fetchHouseTypes({String? siteId}) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '1';
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/house-types?site_id=$effectiveSiteId');
        final response = await http.get(url).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final list = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
          _houseTypes = list.map((item) => HouseTypeTariff.fromJson(item as Map<String, dynamic>)).toList();
          notifyListeners();
          return;
        }
      } catch (e) {
        debugPrint('fetchHouseTypes error: $e');
      }
    }
    if (_houseTypes.isEmpty) {
      _houseTypes = [
        HouseTypeTariff(id: '1', siteId: effectiveSiteId, typeName: '1+1', duesAmount: Decimal.parse('1000.00'), description: '1 Oda 1 Salon'),
        HouseTypeTariff(id: '2', siteId: effectiveSiteId, typeName: '2+1', duesAmount: Decimal.parse('1400.00'), description: '2 Oda 1 Salon'),
        HouseTypeTariff(id: '3', siteId: effectiveSiteId, typeName: '3+1', duesAmount: Decimal.parse('1800.00'), description: '3 Oda 1 Salon'),
        HouseTypeTariff(id: '4', siteId: effectiveSiteId, typeName: '4+1', duesAmount: Decimal.parse('2200.00'), description: '4 Oda 1 Salon'),
        HouseTypeTariff(id: '5', siteId: effectiveSiteId, typeName: 'Dublex', duesAmount: Decimal.parse('2500.00'), description: 'Çatı Dubleks / Bahçe Katı'),
      ];
      notifyListeners();
    }
  }

  Future<bool> saveHouseType({
    required String typeName,
    required Decimal duesAmount,
    String? description,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '1';
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/house-types?site_id=$effectiveSiteId');
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'type_name': typeName,
            'dues_amount': duesAmount.toString(),
            'description': description,
          }),
        ).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200 || response.statusCode == 201) {
          await fetchHouseTypes(siteId: effectiveSiteId);
          return true;
        }
      } catch (e) {
        debugPrint('saveHouseType error: $e');
      }
    }
    final existingIdx = _houseTypes.indexWhere((h) => h.typeName.toLowerCase() == typeName.toLowerCase());
    final newHt = HouseTypeTariff(
      id: 'ht-${DateTime.now().millisecondsSinceEpoch}',
      siteId: effectiveSiteId,
      typeName: typeName,
      duesAmount: duesAmount,
      description: description,
    );
    if (existingIdx != -1) {
      _houseTypes[existingIdx] = newHt;
    } else {
      _houseTypes.add(newHt);
    }
    notifyListeners();
    return true;
  }

  Future<bool> deleteHouseType(String id, {String? siteId}) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '1';
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/house-types/$id?site_id=$effectiveSiteId');
        await http.delete(url).timeout(const Duration(seconds: 4));
      } catch (e) {
        debugPrint('deleteHouseType error: $e');
      }
    }
    _houseTypes.removeWhere((h) => h.id == id);
    notifyListeners();
    return true;
  }

  // Site Blocks
  List<String> _blocks = ['A Blok', 'B Blok'];
  List<String> get blocks {
    final seen = <String>{};
    final unique = <String>[];
    for (final b in _blocks) {
      final trimmed = b.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed.toLowerCase())) {
        unique.add(trimmed);
      }
    }
    return unique.isNotEmpty ? unique : const ['A Blok', 'B Blok'];
  }

  @visibleForTesting
  void setBlocksForTesting(List<String> b) {
    final seen = <String>{};
    final unique = <String>[];
    for (final item in b) {
      final trimmed = item.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed.toLowerCase())) {
        unique.add(trimmed);
      }
    }
    _blocks = unique;
    notifyListeners();
  }

  Future<void> fetchBlocks({String? siteId}) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '1';
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/blocks?site_id=$effectiveSiteId');
        final response = await http.get(url).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final list = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
          final seen = <String>{};
          final parsed = <String>[];
          for (final item in list) {
            final name = (item as Map<String, dynamic>)['block_name']?.toString().trim() ?? '';
            if (name.isNotEmpty && seen.add(name.toLowerCase())) {
              parsed.add(name);
            }
          }
          if (parsed.isNotEmpty) {
            _blocks = parsed;
            notifyListeners();
            return;
          }
        }
      } catch (e) {
        debugPrint('fetchBlocks error: $e');
      }
    }
    if (_blocks.isEmpty) {
      _blocks = ['A Blok', 'B Blok'];
      notifyListeners();
    }
  }

  Future<bool> saveBlock({
    required String blockName,
    int? totalFloors,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '1';
    final trimmed = blockName.trim();
    if (trimmed.isEmpty) return false;

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/blocks?site_id=$effectiveSiteId');
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'block_name': trimmed,
            'total_floors': totalFloors ?? 10,
          }),
        ).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200 || response.statusCode == 201) {
          await fetchBlocks(siteId: effectiveSiteId);
          return true;
        }
      } catch (e) {
        debugPrint('saveBlock error: $e');
      }
    }
    final existingIdx = _blocks.indexWhere((b) => b.toLowerCase() == trimmed.toLowerCase());
    if (existingIdx == -1) {
      _blocks.add(trimmed);
      notifyListeners();
    }
    return true;
  }

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
    _activeUnit = ApartmentUnit.empty;
    _siteBankAccount = null;
    _duesList = [];
    _managerDuesList = [];
    _flatsList = [];
    _pendingRegistrations = [];
    _saasSites = [];
    _managedSitesList = [];
    _currentManagedSite = null;
    _unitResidents = [];
    _monthlyFlats.clear();
    _reconciliationQueue = [];
    _accountTransactions = [];
    _collectionSummary = ComplexCollectionSummary.zero();
    _matchingCriteria = null;

    if (_activeUnit.id.isNotEmpty) {
      fetchResidentDashboard();
    }
    if (_currentManagedSite?.id.isNotEmpty == true) {
      fetchReconciliationQueue();
    }
  }

  @visibleForTesting
  void setDuesForTesting(List<DuesLiability> dues) {
    _duesList = List.from(dues);
    notifyListeners();
  }

  @visibleForTesting
  void setFlatsForTesting(List<FlatPaymentStatus> flats) {
    _flatsList = List.from(flats);
    _monthlyFlats['Eylül 2026'] = List.from(flats);
    _monthlyFlats['Ağustos 2026'] = flats.map((f) {
      if (f.unitNo == 14 || f.unitNo == 15) {
        return f.copyWith(isPaid: false, daysOverdue: 35);
      }
      return f.copyWith(isPaid: true, daysOverdue: 0, paidDateStr: '12 Ağu');
    }).toList();
    _monthlyFlats['Temmuz 2026'] = flats.map((f) {
      if (f.unitNo == 14) {
        return f.copyWith(isPaid: false, daysOverdue: 65);
      }
      return f.copyWith(isPaid: true, daysOverdue: 0, paidDateStr: '10 Tem');
    }).toList();
    _monthlyFlats['Ekim 2026'] = flats.map((f) {
      if (f.unitNo == 1 || f.unitNo == 7) {
        return f.copyWith(isPaid: true, daysOverdue: 0, paidDateStr: '01 Eki');
      }
      return f.copyWith(isPaid: false, daysOverdue: 0);
    }).toList();
    notifyListeners();
  }

  @visibleForTesting
  void setSelectedDuesMonthForTesting(String month) {
    _selectedDuesMonth = month;
  }

  @visibleForTesting
  void setPendingRegistrationsForTesting(List<RegistrationRequestItem> items) {
    _pendingRegistrations = List.from(items);
    notifyListeners();
  }

  @visibleForTesting
  void setSaasSitesForTesting(List<TenantSiteItem> sites) {
    _saasSites = List.from(sites);
    if (sites.isNotEmpty) {
      _managedSitesList = List.from(sites);
      _currentManagedSite = sites.first;
    }
    notifyListeners();
  }

  @visibleForTesting
  void setManagedSitesForTesting(TenantSiteItem current, List<TenantSiteItem> sites) {
    _currentManagedSite = current;
    _managedSitesList = List.from(sites);
    notifyListeners();
  }

  @visibleForTesting
  void setReconciliationQueueForTesting(List<ReconciliationQueueItem> items) {
    _reconciliationQueue = List.from(items);
    notifyListeners();
  }

  @visibleForTesting
  void setAccountTransactionsForTesting(List<AccountTransactionItem> items) {
    _accountTransactions = List.from(items);
    notifyListeners();
  }

  @visibleForTesting
  void setActiveUnitForTesting(ApartmentUnit unit) {
    _activeUnit = unit;
    notifyListeners();
  }

  @visibleForTesting
  void setMatchingCriteriaForTesting(UnitMatchingCriteria criteria) {
    _matchingCriteria = criteria;
    notifyListeners();
  }

  @visibleForTesting
  void setSiteBankAccountForTesting(SiteBankAccount account) {
    _siteBankAccount = account;
    notifyListeners();
  }

  @visibleForTesting
  void setUnitResidentsForTesting(List<UnitResidentMember> members) {
    _unitResidents = List.from(members);
    notifyListeners();
  }

  @visibleForTesting
  void setManagerUnitForTesting(ApartmentUnit unit) {
    _managerUnit = unit;
    notifyListeners();
  }

  @visibleForTesting
  void setManagerResidentsForTesting(List<UnitResidentMember> members) {
    _managerResidents = List.from(members);
    notifyListeners();
  }

  @visibleForTesting
  void setAvailableDuesMonthsForTesting(List<String> months) {
    _availableDuesMonths = List.from(months);
    notifyListeners();
  }

  @visibleForTesting
  void clearAllDataForTesting() {
    _duesList = [];
    _managerDuesList = [];
    _flatsList = [];
    _monthlyFlats.clear();
    _availableDuesMonths.clear();
    _selectedDuesMonth = '';
    _pendingRegistrations = [];
    _saasSites = [];
    _currentManagedSite = null;
    _managedSitesList = [];
    _reconciliationQueue = [];
    _accountTransactions = [];
    _activeUnit = ApartmentUnit.empty;
    _managerUnit = ApartmentUnit.empty;
    _unitResidents = [];
    _managerResidents = [];
    _collectionSummary = ComplexCollectionSummary();
    _userSession = _createSession(_userSession.role, _userSession.authProvider);
    _capitalProjects = [];
    _activeCapitalProject = null;
    _capitalInstallments = [];
    _capitalDisbursements = [];
    _unitCapitalShares = [];
    notifyListeners();
  }

  @visibleForTesting
  void clearCapitalProjectsForTesting() {
    _capitalProjects = [];
    _activeCapitalProject = null;
    _capitalInstallments = [];
    _capitalDisbursements = [];
    _unitCapitalShares = [];
    notifyListeners();
  }

  UnitMatchingCriteria? _matchingCriteria;
  UnitMatchingCriteria? get matchingCriteria => _matchingCriteria;

  Future<void> fetchUnitMatchingCriteria([String? unitId]) async {
    final effectiveUnitId = unitId ?? (_activeUnit.id.isNotEmpty ? _activeUnit.id : null);
    if (effectiveUnitId == null || effectiveUnitId.isEmpty) return;
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/residents/$effectiveUnitId/matching-criteria');
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
    String? unitId,
  }) async {
    final effectiveUnitId = unitId ?? (_activeUnit.id.isNotEmpty ? _activeUnit.id : null);
    if (effectiveUnitId == null || effectiveUnitId.isEmpty) return;
    final clean = iban.replaceAll(' ', '').toUpperCase();
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/residents/$effectiveUnitId/matching-criteria/ibans');
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
    String? unitId,
  }) async {
    final effectiveUnitId = unitId ?? (_activeUnit.id.isNotEmpty ? _activeUnit.id : null);
    if (effectiveUnitId == null || effectiveUnitId.isEmpty) return;
    final clean = iban.replaceAll(' ', '').toUpperCase();
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/residents/$effectiveUnitId/matching-criteria/ibans/$clean');
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
    String? unitId,
  }) async {
    final effectiveUnitId = unitId ?? (_activeUnit.id.isNotEmpty ? _activeUnit.id : null);
    if (effectiveUnitId == null || effectiveUnitId.isEmpty) return;
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/residents/$effectiveUnitId/matching-criteria/payer-names');
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
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/system/reset-demo-data');
        await http.post(url).timeout(const Duration(seconds: 3));
      } catch (e) {
        debugPrint('resetAllDemoData remote error: $e');
      }
    }

    _activeUnit = _activeUnit.copyWith(
      advancePayment: Decimal.zero,
    );
    _duesList = [];
    _managerDuesList = [];
    _reconciliationQueue.clear();
    _processedTransactionIds.clear();
    _processedUnitKeys.clear();
    _accountTransactions = [];
    _sentHostMessages.clear();
    _reconciliationSuccessMessage = null;
    _pendingRegistrations.clear();

    // Reset site manager & flats list to pristine zero-debt state!
    _flatsList = _flatsList.map((f) => f.copyWith(
      amountDue: Decimal.zero,
      isPaid: true,
      daysOverdue: 0,
      paidDateStr: null,
    )).toList();
    _monthlyFlats.clear();

    _collectionSummary = ComplexCollectionSummary.zero(
      totalUnitsCount: _flatsList.length,
    );

    if (_activeUnit.id.isNotEmpty && !isTestMode) {
      await fetchResidentDashboard(_activeUnit.id);
      await fetchUnitMatchingCriteria(_activeUnit.id);
    }
    if (_currentManagedSite?.id.isNotEmpty == true && !isTestMode) {
      await fetchReconciliationQueue(_currentManagedSite!.id);
    }
    notifyListeners();
    return true;
  }

  Future<bool> accrueTestDue([String? unitId]) async {
    final effectiveUnitId = unitId ?? (_activeUnit.id.isNotEmpty ? _activeUnit.id : null);
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/system/accrue-test-due');
      await http.post(url).timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('accrueTestDue remote error: $e');
    }

    if (effectiveUnitId != null && effectiveUnitId.isNotEmpty) {
      await fetchResidentDashboard(effectiveUnitId);
    }
    notifyListeners();
    return true;
  }

  Future<void> fetchResidentDashboard([String? unitId]) async {
    final effectiveUnitId = unitId ?? (_activeUnit.id.isNotEmpty ? _activeUnit.id : null);
    if (effectiveUnitId == null || effectiveUnitId.isEmpty) return;
    fetchUnitMatchingCriteria(effectiveUnitId);
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/residents/$effectiveUnitId/dashboard');
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
              id: item['id'] as String? ?? '',
              unitId: effectiveUnitId,
              period: item['period'] as String? ?? '',
              principalAmount: Decimal.tryParse(item['principal_amount']?.toString() ?? '0') ?? Decimal.zero,
              delayPenalty: isItemPaid ? Decimal.zero : (Decimal.tryParse(item['delay_penalty']?.toString() ?? '0') ?? Decimal.zero),
              totalAmount: isItemPaid ? Decimal.zero : (Decimal.tryParse(item['total_amount']?.toString() ?? '0') ?? Decimal.zero),
              dueDate: DateTime.tryParse(item['due_date']?.toString() ?? '') ?? DateTime.now(),
              status: isItemPaid
                  ? DebtStatus.paid
                  : (data['is_overdue'] == true ? DebtStatus.overdue : DebtStatus.pending),
            );
          }).toList();
        } else {
          _duesList = [];
          _managerDuesList = [];
          _flatsList = _flatsList.map((f) => f.copyWith(
            amountDue: Decimal.zero,
            isPaid: true,
            daysOverdue: 0,
            paidDateStr: null,
          )).toList();
          _monthlyFlats.clear();
          _collectionSummary = ComplexCollectionSummary.zero(
            totalUnitsCount: _flatsList.length,
          );
        }

        final txList = data['transactions'] as List<dynamic>?;
        if (txList != null) {
          _accountTransactions = txList.map((t) => AccountTransactionItem.fromJson(t as Map<String, dynamic>)).toList();
        }

        notifyListeners();
      }
      if (_currentManagedSite?.id.isNotEmpty == true) {
        fetchReconciliationQueue(_currentManagedSite!.id);
      }
    } catch (e) {
      debugPrint('Dashboard live sync offline fallback: $e');
    }
  }

  Future<void> fetchReconciliationQueue([String? siteId]) async {
    String? effectiveSiteId = siteId ?? (_currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : (_saasSites.isNotEmpty ? _saasSites.first.id : null)));
    if (effectiveSiteId == null || effectiveSiteId.isEmpty) {
      if (!isTestMode) {
        await fetchSiteManagerOverview();
        effectiveSiteId = _currentManagedSite?.id;
      }
    }
    if (effectiveSiteId == null || effectiveSiteId.isEmpty) return;
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/bank/statements/reconciliation-queue?site_id=$effectiveSiteId');
      final response = await http.get(url).timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final list = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>?;
        if (list != null) {
          final liveItems = list.map((item) => ReconciliationQueueItem.fromJson(item as Map<String, dynamic>)).toList();
          if (!isTestMode) {
            _reconciliationQueue = liveItems;
            notifyListeners();
          } else {
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
      }
    } catch (e) {
      debugPrint('Reconciliation queue fetch error: $e');
    }
  }

  Future<void> fetchSiteManagerOverview({String? siteId, String? period}) async {
    if (isTestMode) return;
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final queryParams = <String, String>{};
      if (siteId != null && siteId.isNotEmpty) {
        queryParams['site_id'] = siteId;
      }
      if (period != null && period.isNotEmpty) {
        queryParams['period'] = period;
      }

      final uri = Uri.http('$host:8080', '/api/v1/site-admin/overview', queryParams);
      final response = await http.get(uri).timeout(const Duration(seconds: 2));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

        final fetchedSiteId = data['site_id'] as String? ?? (_currentManagedSite?.id ?? '');
        final fetchedSiteName = data['site_name'] as String? ?? (_currentManagedSite?.name ?? '');
        final address = data['address'] as String? ?? '';
        final managerName = data['manager_name'] as String? ?? '';
        final managerEmail = data['manager_email'] as String? ?? '';
        final city = data['city'] as String? ?? (_currentManagedSite?.city ?? '');

        final summaryJson = data['summary'] as Map<String, dynamic>?;
        final totalUnitsCount = (summaryJson?['total_units_count'] as num?)?.toInt() ?? _flatsList.length;

        _currentManagedSite = TenantSiteItem(
          id: fetchedSiteId,
          name: fetchedSiteName,
          city: city,
          address: address,
          status: 'ACTIVE',
          planType: 'STANDARD',
          totalUnits: totalUnitsCount,
          monthlyCollectionVolume: Decimal.tryParse(summaryJson?['total_expected']?.toString() ?? '0') ?? Decimal.zero,
          adminName: managerName,
          adminEmail: managerEmail,
          adminPhone: '',
          actionCount: 0,
        );

        final sitesJson = data['available_sites'] as List<dynamic>?;
        if (sitesJson != null && sitesJson.isNotEmpty) {
          _managedSitesList = sitesJson.map((s) {
            final item = s as Map<String, dynamic>;
            return TenantSiteItem(
              id: item['id'] as String? ?? '',
              name: item['name'] as String? ?? '',
              city: item['city'] as String? ?? '',
              address: item['address'] as String? ?? '',
              status: 'ACTIVE',
              planType: 'STANDARD',
              totalUnits: (item['total_units'] as num?)?.toInt() ?? 0,
              monthlyCollectionVolume: Decimal.zero,
              adminName: '',
              adminEmail: '',
              adminPhone: '',
              actionCount: 0,
            );
          }).toList();
        }

        final periodsJson = data['available_periods'] as List<dynamic>?;
        _availableDuesMonths.clear();
        if (periodsJson != null && periodsJson.isNotEmpty) {
          for (final p in periodsJson) {
            final periodStr = p.toString();
            if (periodStr.isNotEmpty && !_availableDuesMonths.contains(periodStr)) {
              _availableDuesMonths.add(periodStr);
            }
          }
        }

        final selPeriod = data['selected_period'] as String?;
        if (selPeriod != null && selPeriod.isNotEmpty) {
          _selectedDuesMonth = selPeriod;
        } else if (_availableDuesMonths.isNotEmpty) {
          _selectedDuesMonth = _availableDuesMonths.first;
        } else {
          _selectedDuesMonth = '';
        }

        Decimal totalAdvanceFromFlats = Decimal.zero;
        final flatsJson = data['flats'] as List<dynamic>?;
        if (flatsJson != null) {
          final seenKeys = <String>{};
          final list = <FlatPaymentStatus>[];
          for (final f in flatsJson) {
            final item = f as Map<String, dynamic>;
            final b = (item['block'] as String? ?? '').toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();
            final u = (item['unit_no'] as num?)?.toInt() ?? 0;
            final key = '$b-$u';
            if (b.isNotEmpty && u > 0 && !seenKeys.add(key)) {
              continue;
            }
            final adv = Decimal.tryParse(item['advance_balance']?.toString() ?? '0') ?? Decimal.zero;
            totalAdvanceFromFlats += adv;
            list.add(FlatPaymentStatus(
              id: item['id'] as String? ?? '',
              block: item['block'] as String? ?? '',
              unitNo: u,
              residentName: item['resident_name'] as String? ?? '',
              amountDue: Decimal.tryParse(item['amount_due']?.toString() ?? '0') ?? Decimal.zero,
              advanceBalance: adv,
              daysOverdue: (item['days_overdue'] as num?)?.toInt() ?? 0,
              isPaid: item['is_paid'] as bool? ?? false,
              paidDateStr: item['paid_date_str'] as String?,
              houseType: item['house_type'] as String?,
            ));
          }
          _flatsList = list;
          _monthlyFlats[_selectedDuesMonth] = List.from(_flatsList);
        }

        if (summaryJson != null) {
          final backendAdvance = Decimal.tryParse(summaryJson['total_advance_balance']?.toString() ?? '0') ?? Decimal.zero;
          final effectiveAdvance = backendAdvance > Decimal.zero ? backendAdvance : totalAdvanceFromFlats;
          _collectionSummary = ComplexCollectionSummary(
            totalExpected: Decimal.tryParse(summaryJson['total_expected']?.toString() ?? '0') ?? Decimal.zero,
            totalCollected: Decimal.tryParse(summaryJson['total_collected']?.toString() ?? '0') ?? Decimal.zero,
            totalOverdueWithInterest: Decimal.tryParse(summaryJson['total_overdue_with_interest']?.toString() ?? '0') ?? Decimal.zero,
            totalAdvanceBalance: effectiveAdvance,
            paidUnitsCount: (summaryJson['paid_units_count'] as num?)?.toInt() ?? 0,
            overdueUnitsCount: (summaryJson['overdue_units_count'] as num?)?.toInt() ?? 0,
            totalUnitsCount: totalUnitsCount,
          );
        }

        if (fetchedSiteId.isNotEmpty) {
          await fetchReconciliationQueue(fetchedSiteId);
          await fetchHouseTypes(siteId: fetchedSiteId);
          await fetchBlocks(siteId: fetchedSiteId);
          await fetchHomeOwners(siteId: fetchedSiteId);
        }

        if (_userSession.role == UserRole.siteManager) {
          _userSession = _userSession.copyWith(
            siteName: fetchedSiteName,
            fullName: managerName.isNotEmpty ? managerName : _userSession.fullName,
            email: managerEmail.isNotEmpty ? managerEmail : _userSession.email,
          );
        }

        notifyListeners();
      }
    } catch (e) {
      debugPrint('fetchSiteManagerOverview offline fallback: $e');
    }
  }

  Future<void> changeManagedSite(String siteId) async {
    await fetchSiteManagerOverview(siteId: siteId, period: _selectedDuesMonth);
  }

  Future<void> fetchSaasSites() async {
    if (isTestMode) return;
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/saas/sites');
      final response = await http.get(url).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(utf8.decode(response.bodyBytes));
        if (data.isNotEmpty) {
          _saasSites = data.map<TenantSiteItem>((item) {
            final addr = item['address']?.toString() ?? '';
            final city = addr.contains(',') ? addr.split(',').last.trim() : 'İstanbul';
            final blocksJson = item['blocks'] as List<dynamic>?;
            final blocks = blocksJson != null && blocksJson.isNotEmpty
                ? blocksJson.map((e) => e.toString()).toList()
                : const ['A Blok', 'B Blok'];
            return TenantSiteItem(
              id: item['site_id'] as String? ?? '',
              name: item['site_name'] as String? ?? '',
              city: city,
              address: addr,
              status: item['status'] as String? ?? 'ACTIVE',
              planType: item['plan_type'] as String? ?? 'STANDARD',
              totalUnits: (item['total_units'] as num?)?.toInt() ?? 0,
              monthlyCollectionVolume: Decimal.tryParse(item['monthly_dues_volume']?.toString() ?? '0') ?? Decimal.zero,
              adminName: item['primary_manager_name'] as String? ?? 'Yönetici Atanmadı',
              adminEmail: item['primary_manager_email'] as String? ?? '',
              adminPhone: item['primary_manager_phone'] as String? ?? '',
              actionCount: (item['total_units'] as num?)?.toInt() ?? 0,
              blocks: blocks,
            );
          }).toList();
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('fetchSaasSites error: $e');
    }
  }

  Future<Map<String, dynamic>> accrueMonthlyDues({
    required String period,
    String? siteId,
    Decimal? amount,
    DateTime? dueDate,
  }) async {
    final effectiveSiteId = (siteId != null && siteId.isNotEmpty)
        ? siteId
        : (_currentManagedSite?.id.isNotEmpty == true
            ? _currentManagedSite!.id
            : (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : (_saasSites.isNotEmpty ? _saasSites.first.id : '1')));
    final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
    final url = Uri.parse('http://$host:8080/api/v1/dues/accrue-period');
    final dueAmount = amount ?? Decimal.parse('1400.00');
    final dt = dueDate ?? DateTime.now();
    final formattedDueDate =
        "${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";

    if (isTestMode) {
      if (!_availableDuesMonths.contains(period)) {
        _availableDuesMonths.insert(0, period);
      }
      _selectedDuesMonth = period;
      if (!_monthlyFlats.containsKey(period)) {
        _monthlyFlats[period] = _flatsList.map<FlatPaymentStatus>((f) {
          final isSettled = f.id == _activeUnit.id && _activeUnit.hasAdvancePayment;
          return f.copyWith(
            amountDue: dueAmount,
            isPaid: isSettled,
            daysOverdue: 0,
          );
        }).toList();
        _flatsList = List<FlatPaymentStatus>.from(_monthlyFlats[period]!);
      }
      _syncCollectionSummaryForMonth(period);
      notifyListeners();
      return {
        'site_id': effectiveSiteId,
        'period': period,
        'total_units_accrued': _flatsList.length,
        'newly_accrued_units_count': _flatsList.length,
        'auto_settled_units_count': 0,
        'total_amount_accrued': dueAmount * Decimal.fromInt(_flatsList.length),
        'total_amount_offset_from_advance': Decimal.zero,
        'already_accrued': false,
        'message': "'$period' dönemi için aidat tahakkuk ettirildi.",
      };
    }

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'site_id': effectiveSiteId,
          'period': period,
          'amount': dueAmount.toString(),
          'due_date': formattedDueDate,
        }),
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

        // Refresh resident dashboard state
        if (_activeUnit.id.isNotEmpty) {
          await fetchResidentDashboard(_activeUnit.id);
        }
        await fetchSiteManagerOverview(siteId: effectiveSiteId, period: period);

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
              amountDue: dueAmount,
              isPaid: isSettled,
              daysOverdue: 0,
            );
          }).toList();
          _flatsList = List<FlatPaymentStatus>.from(_monthlyFlats[period]!);
          _syncCollectionSummaryForMonth(period);
        }

        notifyListeners();
        return data;
      } else {
        if (!_availableDuesMonths.contains(period)) {
          _availableDuesMonths.insert(0, period);
        }
        _selectedDuesMonth = period;
        if (!_monthlyFlats.containsKey(period)) {
          _monthlyFlats[period] = _flatsList.map<FlatPaymentStatus>((f) {
            final isSettled = f.id == _activeUnit.id && _activeUnit.hasAdvancePayment;
            return f.copyWith(
              amountDue: dueAmount,
              isPaid: isSettled,
              daysOverdue: 0,
            );
          }).toList();
          _flatsList = List<FlatPaymentStatus>.from(_monthlyFlats[period]!);
        }
        _syncCollectionSummaryForMonth(period);
        notifyListeners();
        return {
          'site_id': effectiveSiteId,
          'period': period,
          'total_units_accrued': _flatsList.length,
          'newly_accrued_units_count': _flatsList.length,
          'auto_settled_units_count': 0,
          'total_amount_accrued': dueAmount * Decimal.fromInt(_flatsList.length),
          'total_amount_offset_from_advance': Decimal.zero,
          'already_accrued': false,
          'message': 'İstek tamamlandı (fallback): ${response.statusCode}',
        };
      }
    } catch (e) {
      debugPrint('accrueMonthlyDues offline fallback: $e');
      if (!_availableDuesMonths.contains(period)) {
        _availableDuesMonths.insert(0, period);
      }
      _selectedDuesMonth = period;
      if (!_monthlyFlats.containsKey(period)) {
        _monthlyFlats[period] = _flatsList.map<FlatPaymentStatus>((f) {
          final isSettled = f.id == _activeUnit.id && _activeUnit.hasAdvancePayment;
          return f.copyWith(
            amountDue: dueAmount,
            isPaid: isSettled,
            daysOverdue: 0,
          );
        }).toList();
        _flatsList = List<FlatPaymentStatus>.from(_monthlyFlats[period]!);
      }
      _syncCollectionSummaryForMonth(period);
      notifyListeners();
      return {
        'site_id': effectiveSiteId,
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

  Future<Map<String, dynamic>> createDuesPeriod({
    required String periodName,
    required DateTime dueDate,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId != null && siteId.isNotEmpty
        ? siteId
        : (_currentManagedSite?.id.isNotEmpty == true
            ? _currentManagedSite!.id
            : (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : (_saasSites.isNotEmpty ? _saasSites.first.id : '1')));
    final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
    final url = Uri.parse('http://$host:8080/api/v1/dues/periods');
    final formattedDueDate =
        "${dueDate.year.toString().padLeft(4, '0')}-${dueDate.month.toString().padLeft(2, '0')}-${dueDate.day.toString().padLeft(2, '0')}";

    if (!_availableDuesMonths.contains(periodName)) {
      _availableDuesMonths.insert(0, periodName);
    }
    _selectedDuesMonth = periodName;

    if (isTestMode) {
      notifyListeners();
      return {
        'status': 'SUCCESS',
        'id': 'PER-test',
        'site_id': effectiveSiteId,
        'period_name': periodName,
        'due_date': formattedDueDate,
      };
    }

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'site_id': effectiveSiteId,
          'period_name': periodName,
          'due_date': formattedDueDate,
        }),
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        await fetchSiteManagerOverview(siteId: effectiveSiteId, period: periodName);
        notifyListeners();
        return {'status': 'SUCCESS', 'data': data};
      }
    } catch (_) {}

    notifyListeners();
    return {'status': 'SUCCESS', 'period_name': periodName};
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
    if (role == UserRole.siteManager && adminPath != null) {
      _siteAdminPath = adminPath;
    }
    if (role == UserRole.saasAdmin) {
      fetchSaasSites();
    } else if (role == UserRole.siteManager) {
      fetchSiteManagerOverview(siteId: _currentManagedSite?.id, period: _selectedDuesMonth);
    } else if (role == UserRole.homeOwner || role == UserRole.homeResident) {
      if (_activeUnit.id.isNotEmpty) {
        fetchResidentDashboard(_activeUnit.id);
      } else if (!isTestMode) {
        fetchSiteManagerOverview().then((_) {
          final firstUnit = _flatsList.isNotEmpty ? _flatsList.first : null;
          if (firstUnit != null && firstUnit.id.isNotEmpty) {
            fetchResidentDashboard(firstUnit.id);
          }
        });
      }
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
    if (role == UserRole.saasAdmin) {
      fetchSaasSites();
    }
    notifyListeners();
  }

  void logout() {
    _isAuthenticated = false;
    _authMessage = null;
    notifyListeners();
  }

  void setSiteAdminPath(SiteAdminActivePath path) {
    _siteAdminPath = path;
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
        : (email.contains('yonetim') || email.contains('manager') || email.contains('mehmet'))
            ? UserRole.siteManager
            : (email.contains('sakin') || email.contains('zeynep'))
                ? UserRole.homeResident
                : UserRole.homeOwner;

    _userSession = _createSession(role, AuthProvider.local, customEmail: email);
    _isAuthenticated = true;
    _authMessage = 'Şifre ile başarıyla giriş yapıldı (${role.displayName}).';
    notifyListeners();
  }

  void loginWithGoogle() {
    const role = UserRole.homeOwner;
    _userSession = _createSession(
      role,
      AuthProvider.google,
      customName: 'Google Kullanıcısı',
      customEmail: 'user@gmail.com',
      avatarUrl: 'https://lh3.googleusercontent.com/a/google-user-icon',
    );
    _isAuthenticated = true;
    _authMessage = 'Google hesabı ile tek tıkla giriş sağlandı.';
    notifyListeners();
  }

  Future<void> registerNewSite({
    required String name,
    required String city,
    required String address,
    required String adminName,
    required String adminEmail,
    required String adminPhone,
    String planType = 'STANDARD',
    List<String>? blocks,
  }) async {
    final siteBlocks = (blocks != null && blocks.isNotEmpty) ? blocks : ['A Blok', 'B Blok'];
    final siteId = 'site-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
    final tempPassword = 'SP-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}-PASS';

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/saas/sites');
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'site_name': name,
            'address': '$address, $city',
            'site_admin_full_name': adminName,
            'site_admin_email': adminEmail,
            'site_admin_phone': adminPhone,
            'plan_type': planType,
            'blocks': siteBlocks,
          }),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200 || response.statusCode == 201) {
          final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          final createdSiteId = data['site_id']?.toString() ?? siteId;
          final createdPassword = data['temporary_password']?.toString() ?? tempPassword;
          final newSite = TenantSiteItem(
            id: createdSiteId,
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
            blocks: siteBlocks,
          );
          _saasSites = [newSite, ..._saasSites];
          _provisionedCredentials = ProvisionedSiteCredentials(
            siteId: createdSiteId,
            siteName: name,
            adminName: adminName,
            adminEmail: adminEmail,
            temporaryPassword: createdPassword,
            planType: planType,
          );
          notifyListeners();
          return;
        }
      } catch (e) {
        debugPrint('registerNewSite remote error: $e');
      }
    }

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
      blocks: siteBlocks,
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

  Future<void> registerHomeOwner({
    required String block,
    required int unitNo,
    required String ownerName,
    required String email,
    required String phone,
    String? tenantFullName,
    String? tenantEmail,
    String? tenantPhone,
    String? houseType,
    Decimal? duesAmount,
    bool isResident = true,
    String role = 'OWNER',
    String? relationship,
  }) async {
    final effectiveHouseType = houseType ?? '2+1';
    final matchedTariff = _houseTypes.cast<HouseTypeTariff?>().firstWhere(
      (h) => h?.typeName.toLowerCase() == effectiveHouseType.toLowerCase(),
      orElse: () => null,
    );
    final dues = duesAmount ?? matchedTariff?.duesAmount ?? Decimal.parse('1400.00');
    final cleanBlock = block.replaceAll('Blok', '').trim();
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    String tempPassword = 'SP-SAKIN-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}';

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/home-owners?site_id=$effectiveSiteId');
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'block': block,
            'unit_no': unitNo,
            'floor': ((unitNo - 1) ~/ 4) + 1,
            'owner_full_name': ownerName,
            'email': email,
            'phone': phone,
            'tenant_full_name': tenantFullName,
            'tenant_email': tenantEmail,
            'tenant_phone': tenantPhone,
            'land_share': '1/24',
            'monthly_dues': dues.toString(),
            'house_type': effectiveHouseType,
            'is_resident': isResident,
            'role': role,
          }),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200 || response.statusCode == 201) {
          final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          if (data['temporary_password'] != null && data['temporary_password'].toString().isNotEmpty) {
            tempPassword = data['temporary_password'].toString();
          }
          await fetchSiteManagerOverview(siteId: effectiveSiteId, period: _selectedDuesMonth);
          await fetchHomeOwners(siteId: effectiveSiteId);
        } else {
          final errorBody = utf8.decode(response.bodyBytes);
          debugPrint('registerHomeOwner remote error: ${response.statusCode} - $errorBody');
          _authMessage = errorBody.isNotEmpty ? errorBody : 'Sakin eklenirken hata oluştu (${response.statusCode})';
          notifyListeners();
          return;
        }
      } catch (e) {
        debugPrint('registerHomeOwner network error: $e');
      }
    }

    final isTenant = role.toUpperCase() == 'TENANT';
    final isResidentRole = role.toUpperCase() == 'RESIDENT';

    if (!isResidentRole) {
      final bool alreadyPresent = _flatsList.any((f) {
        final b1 = f.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
        final b2 = cleanBlock.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
        return f.unitNo == unitNo && b1 == b2 && f.residentName.trim().toLowerCase() == ownerName.trim().toLowerCase();
      });

      if (!alreadyPresent) {
        final newFlat = FlatPaymentStatus(
          id: 'f-${DateTime.now().millisecondsSinceEpoch}',
          block: cleanBlock,
          unitNo: unitNo,
          residentName: ownerName,
          amountDue: dues,
          daysOverdue: 0,
          isPaid: false,
          houseType: effectiveHouseType,
        );

        _flatsList = [newFlat, ..._flatsList];
        if (_selectedDuesMonth.isNotEmpty) {
          _monthlyFlats[_selectedDuesMonth] = [newFlat, ...(_monthlyFlats[_selectedDuesMonth] ?? [])];
        }
        _collectionSummary = _collectionSummary.copyWith(
          totalUnitsCount: _collectionSummary.totalUnitsCount + 1,
          overdueUnitsCount: _collectionSummary.overdueUnitsCount + 1,
          totalExpected: _collectionSummary.totalExpected + dues,
        );
      }
    }

    _provisionedHomeOwner = ProvisionedHomeOwnerCredentials(
      block: block,
      unitNo: unitNo,
      ownerName: ownerName,
      email: email,
      phone: phone,
      temporaryPassword: tempPassword,
      isResident: isResident,
      duesAmount: dues,
      houseType: effectiveHouseType,
    );

    // Also update _homeOwners list locally
    final existingHoIndex = _homeOwners.indexWhere((h) {
      final b1 = h.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
      final b2 = cleanBlock.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
      return h.unitNo == unitNo && b1 == b2;
    });

    final String targetUnitId = existingHoIndex != -1 ? _homeOwners[existingHoIndex].unitId : 'unit-$unitNo';

    // If unit already had an occupant and we're registering a new OWNER or TENANT, archive old occupant to history
    if (existingHoIndex != -1 && !isResidentRole) {
      final old = _homeOwners[existingHoIndex];
      final currentHist = _localOccupancyHistory.putIfAbsent(targetUnitId, () => []);
      if (currentHist.isEmpty) {
        final prevName = old.tenantFullName ?? old.ownerFullName;
        final prevRole = old.tenantFullName != null ? 'TENANT' : 'OWNER';
        currentHist.add(OccupancyHistoryItem(
          id: DateTime.now().millisecondsSinceEpoch - 1000,
          unitId: int.tryParse(targetUnitId.replaceAll(RegExp(r'[^0-9]'), '')) ?? unitNo,
          personId: 101,
          personName: prevName,
          personEmail: old.tenantEmail ?? old.email,
          personPhone: old.tenantPhone ?? old.phone,
          role: prevRole,
          startDate: '2026-01-01',
          endDate: DateTime.now().toIso8601String().split('T').first,
          isActive: false,
          exitBalance: Decimal.zero,
          notes: 'Devir / Yeni taşınma',
          createdAt: DateTime.now().subtract(const Duration(days: 90)),
        ));
      } else {
        _localOccupancyHistory[targetUnitId] = currentHist.map((h) {
          if (h.isActive) {
            return h.copyWith(
              isActive: false,
              endDate: DateTime.now().toIso8601String().split('T').first,
            );
          }
          return h;
        }).toList();
      }

      _localOccupancyHistory[targetUnitId]!.insert(0, OccupancyHistoryItem(
        id: DateTime.now().millisecondsSinceEpoch,
        unitId: int.tryParse(targetUnitId.replaceAll(RegExp(r'[^0-9]'), '')) ?? unitNo,
        personId: 102,
        personName: ownerName,
        personPhone: phone,
        personEmail: email,
        role: role,
        startDate: DateTime.now().toIso8601String().split('T').first,
        endDate: null,
        isActive: true,
        exitBalance: Decimal.zero,
        notes: isResident ? 'Aktif İkamet' : 'Mülk Sahibi (İkamet Etmiyor)',
        createdAt: DateTime.now(),
      ));
    }

    final hasExplicitTenant = tenantFullName != null && tenantFullName.trim().isNotEmpty;
    final effectiveIsTenant = isTenant || hasExplicitTenant;

    final hoItem = HomeOwnerItem(
      unitId: targetUnitId,
      siteId: effectiveSiteId,
      block: cleanBlock,
      unitNo: unitNo,
      floor: ((unitNo - 1) ~/ 4) + 1,
      ownerFullName: hasExplicitTenant
          ? ownerName
          : (existingHoIndex != -1 && isTenant
              ? _homeOwners[existingHoIndex].ownerFullName
              : (isTenant ? 'Bilinmeyen Malik' : ownerName)),
      tenantFullName: hasExplicitTenant
          ? tenantFullName
          : (isTenant
              ? ownerName
              : (existingHoIndex != -1 && !isResidentRole ? null : (existingHoIndex != -1 ? _homeOwners[existingHoIndex].tenantFullName : null))),
      occupancyStatus: effectiveIsTenant ? 'TENANT_OCCUPIED' : (isResident ? 'OWNER_OCCUPIED' : 'VACANT'),
      email: email,
      phone: phone,
      tenantEmail: hasExplicitTenant ? tenantEmail : (isTenant ? email : null),
      tenantPhone: hasExplicitTenant ? tenantPhone : (isTenant ? phone : null),
      landShare: '1/24',
      monthlyDues: dues,
      houseType: effectiveHouseType,
      isResident: isResident,
      temporaryPassword: tempPassword,
      mustChangePassword: true,
      createdAt: DateTime.now(),
    );
    if (existingHoIndex != -1) {
      if (isResidentRole) {
        final existingHo = _homeOwners[existingHoIndex];
        final newMember = UnitResidentMember(
          id: 'usr-res-${DateTime.now().millisecondsSinceEpoch}',
          fullName: ownerName,
          relationship: relationship ?? 'Ev Sakini',
          phone: phone,
          email: email,
          isOwner: false,
        );
        final updatedResidents = List<UnitResidentMember>.from(existingHo.householdResidents)..add(newMember);
        _homeOwners[existingHoIndex] = existingHo.copyWith(
          householdResidents: updatedResidents,
        );
      } else {
        _homeOwners[existingHoIndex] = hoItem;
      }
    } else {
      if (isResidentRole) {
        final newMember = UnitResidentMember(
          id: 'usr-res-${DateTime.now().millisecondsSinceEpoch}',
          fullName: ownerName,
          relationship: relationship ?? 'Ev Sakini',
          phone: phone,
          email: email,
          isOwner: false,
        );
        _homeOwners = [hoItem.copyWith(householdResidents: [newMember]), ..._homeOwners];
      } else {
        _homeOwners = [hoItem, ..._homeOwners];
      }
    }

    notifyListeners();
  }

  void clearProvisionedHomeOwner() {
    _provisionedHomeOwner = null;
    notifyListeners();
  }

  Future<void> fetchHomeOwners({String? siteId}) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    _isLoadingHomeOwners = true;

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/home-owners?site_id=$effectiveSiteId');
        final response = await http.get(url).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final List<dynamic> list = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
          final seenKeys = <String>{};
          final result = <HomeOwnerItem>[];
          for (final item in list) {
            final ho = HomeOwnerItem.fromJson(item as Map<String, dynamic>);
            final b = ho.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();
            final key = '$b-${ho.unitNo}';
            if (!seenKeys.add(key)) {
              continue; // deduplicate by unit
            }
            result.add(ho);
          }
          _homeOwners = result;
          _isLoadingHomeOwners = false;
          notifyListeners();
          return;
        }
      } catch (e) {
        debugPrint('fetchHomeOwners network error: $e');
      }
    }

    // In-memory or fallback sync from _flatsList
    if (_homeOwners.isEmpty && _flatsList.isNotEmpty) {
      final seenKeys = <String>{};
      final fallbackList = <HomeOwnerItem>[];
      for (final f in _flatsList) {
        final b = f.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();
        final key = '$b-${f.unitNo}';
        if (b.isNotEmpty && f.unitNo > 0 && !seenKeys.add(key)) {
          continue;
        }
        fallbackList.add(HomeOwnerItem(
          unitId: f.id,
          siteId: effectiveSiteId,
          block: f.block,
          unitNo: f.unitNo,
          floor: ((f.unitNo - 1) ~/ 4) + 1,
          ownerFullName: f.residentName,
          email: '${f.residentName.toLowerCase().replaceAll(' ', '.')}@example.com',
          phone: '0555 123 4567',
          landShare: '1/24',
          monthlyDues: f.amountDue,
          houseType: f.houseType,
          isResident: true,
          mustChangePassword: false,
          createdAt: DateTime.now(),
        ));
      }
      _homeOwners = fallbackList;
    }
    _isLoadingHomeOwners = false;
    notifyListeners();
  }

  Future<bool> updateHomeOwner({
    required String unitId,
    String? fullName,
    String? email,
    String? phone,
    String? tenantFullName,
    String? tenantEmail,
    String? tenantPhone,
    bool? removeTenant,
    String? houseType,
    Decimal? monthlyDues,
    String? landShare,
    bool? isResident,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');

    // Dues is strictly dependent on the selected house type tariff
    Decimal? effectiveDues = monthlyDues;
    if (houseType != null) {
      final matchingTariff = _houseTypes.where((ht) => ht.typeName == houseType).firstOrNull;
      if (matchingTariff != null) {
        effectiveDues = matchingTariff.duesAmount;
      }
    }

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/home-owners/$unitId?site_id=$effectiveSiteId');
        final response = await http.put(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            if (fullName != null) 'owner_full_name': fullName,
            if (email != null) 'email': email,
            if (phone != null) 'phone': phone,
            if (tenantFullName != null) 'tenant_full_name': tenantFullName,
            if (tenantEmail != null) 'tenant_email': tenantEmail,
            if (tenantPhone != null) 'tenant_phone': tenantPhone,
            if (removeTenant != null) 'remove_tenant': removeTenant,
            if (houseType != null) 'house_type': houseType,
            if (effectiveDues != null) 'monthly_dues': effectiveDues.toString(),
            if (landShare != null) 'land_share': landShare,
            if (isResident != null) 'is_resident': isResident,
          }),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200 || response.statusCode == 204) {
          await fetchHomeOwners(siteId: effectiveSiteId);
          await fetchSiteManagerOverview(siteId: effectiveSiteId, period: _selectedDuesMonth);
          notifyListeners();
          return true;
        } else {
          final err = utf8.decode(response.bodyBytes);
          debugPrint('updateHomeOwner failed: ${response.statusCode} - $err');
        }
      } catch (e) {
        debugPrint('updateHomeOwner error: $e');
      }
    }

    // In-memory update
    final index = _homeOwners.indexWhere((h) => h.unitId == unitId || (email != null && h.email.toLowerCase() == email.toLowerCase()));
    if (index != -1) {
      final current = _homeOwners[index];
      final targetIsResident = isResident ?? current.isResident;
      final targetOccupancy = removeTenant == true
          ? (targetIsResident ? 'OWNER_OCCUPIED' : 'VACANT')
          : (tenantFullName != null
              ? 'TENANT_OCCUPIED'
              : (isResident != null ? (isResident ? 'OWNER_OCCUPIED' : 'VACANT') : current.occupancyStatus));

      _homeOwners[index] = current.copyWith(
        ownerFullName: fullName ?? current.ownerFullName,
        email: email ?? current.email,
        phone: phone ?? current.phone,
        tenantFullName: tenantFullName,
        tenantEmail: tenantEmail,
        tenantPhone: tenantPhone,
        clearTenant: removeTenant == true,
        occupancyStatus: targetOccupancy,
        houseType: houseType,
        monthlyDues: effectiveDues,
        landShare: landShare,
        isResident: isResident,
        clearPrimaryResponsible: removeTenant == true && current.primaryResponsibleRole == 'TENANT',
      );
    }
    // Update matching flat in _flatsList
    final flatIndex = _flatsList.indexWhere((f) => f.id == unitId || (index != -1 && f.unitNo == _homeOwners[index].unitNo));
    if (flatIndex != -1) {
      final targetIsResident = isResident ?? (index != -1 ? _homeOwners[index].isResident : false);
      final activeResident = removeTenant == true
          ? (targetIsResident ? (fullName ?? (index != -1 ? _homeOwners[index].ownerFullName : _flatsList[flatIndex].residentName)) : 'Boş Daire')
          : (tenantFullName ?? (index != -1 ? _homeOwners[index].tenantFullName : null) ?? fullName ?? _flatsList[flatIndex].residentName);
      _flatsList[flatIndex] = _flatsList[flatIndex].copyWith(
        residentName: activeResident,
        houseType: houseType,
        amountDue: effectiveDues ?? _flatsList[flatIndex].amountDue,
      );
    }
    notifyListeners();
    return true;
  }

  Future<bool> setPrimaryResponsibleResident({
    required String unitId,
    required String residentName,
    required String role,
    String? phone,
    String? email,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');

    final index = _homeOwners.indexWhere((h) => h.unitId == unitId);
    if (index != -1) {
      _homeOwners[index] = _homeOwners[index].copyWith(
        primaryResponsibleName: residentName,
        primaryResponsibleRole: role,
        primaryResponsiblePhone: phone,
        primaryResponsibleEmail: email,
      );
    }

    final flatIndex = _flatsList.indexWhere((f) => f.id == unitId || (index != -1 && f.unitNo == _homeOwners[index].unitNo));
    if (flatIndex != -1) {
      _flatsList[flatIndex] = _flatsList[flatIndex].copyWith(
        residentName: residentName,
      );
    }

    notifyListeners();
    return true;
  }

  Future<bool> deleteHomeOwner({
    required String unitId,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/home-owners/$unitId?site_id=$effectiveSiteId');
        final response = await http.delete(
          url,
          headers: {'Content-Type': 'application/json'},
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200 || response.statusCode == 204) {
          await fetchHomeOwners(siteId: effectiveSiteId);
          await fetchSiteManagerOverview(siteId: effectiveSiteId, period: _selectedDuesMonth);
          notifyListeners();
          return true;
        } else {
          final err = utf8.decode(response.bodyBytes);
          debugPrint('deleteHomeOwner failed: ${response.statusCode} - $err');
        }
      } catch (e) {
        debugPrint('deleteHomeOwner error: $e');
      }
    }

    // In-memory removal (fallback and test mode)
    final hoIndex = _homeOwners.indexWhere((h) => h.unitId == unitId);
    int? unitNo;
    String? block;
    if (hoIndex != -1) {
      unitNo = _homeOwners[hoIndex].unitNo;
      block = _homeOwners[hoIndex].block;
      _homeOwners.removeAt(hoIndex);
    } else {
      _homeOwners.removeWhere((h) => h.unitId == unitId);
    }

    _flatsList.removeWhere((f) => f.id == unitId || (unitNo != null && f.unitNo == unitNo && (block == null || f.block == block)));
    for (final month in _monthlyFlats.keys) {
      _monthlyFlats[month]?.removeWhere((f) => f.id == unitId || (unitNo != null && f.unitNo == unitNo && (block == null || f.block == block)));
    }

    notifyListeners();
    return true;
  }

  Future<bool> deleteHouseholdMember({
    required String unitId,
    required String residentId,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/home-residents/members/$unitId/$residentId?site_id=$effectiveSiteId');
        final response = await http.delete(url).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200 || response.statusCode == 204) {
          await fetchHomeOwners(siteId: effectiveSiteId);
          notifyListeners();
          return true;
        }
      } catch (e) {
        debugPrint('deleteHouseholdMember error: $e');
      }
    }

    // In-memory update
    final hoIndex = _homeOwners.indexWhere((h) => h.unitId == unitId);
    if (hoIndex != -1) {
      final updatedResidents = _homeOwners[hoIndex].householdResidents.where((m) => m.id != residentId && m.fullName != residentId).toList();
      _homeOwners[hoIndex] = _homeOwners[hoIndex].copyWith(householdResidents: updatedResidents);
      notifyListeners();
    }
    return true;
  }

  Future<bool> updateHouseholdMember({
    required String unitId,
    required String residentId,
    required String fullName,
    required String phone,
    required String email,
    required String relationship,
  }) async {
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/home-residents/members/$unitId/$residentId?site_id=$effectiveSiteId');
        final response = await http.put(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'full_name': fullName,
            'phone': phone,
            'email': email,
            'relationship': relationship,
          }),
        ).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200 || response.statusCode == 204) {
          await fetchHomeOwners(siteId: effectiveSiteId);
          notifyListeners();
          return true;
        }
      } catch (e) {
        debugPrint('updateHouseholdMember error: $e');
      }
    }

    // In-memory update
    final hoIndex = _homeOwners.indexWhere((h) => h.unitId == unitId);
    if (hoIndex != -1) {
      final updatedResidents = _homeOwners[hoIndex].householdResidents.map((m) {
        if (m.id == residentId || m.fullName == residentId) {
          return UnitResidentMember(
            id: m.id,
            fullName: fullName,
            relationship: relationship,
            phone: phone,
            email: email,
            isOwner: m.isOwner,
          );
        }
        return m;
      }).toList();
      _homeOwners[hoIndex] = _homeOwners[hoIndex].copyWith(householdResidents: updatedResidents);
      notifyListeners();
    }
    return true;
  }

  Future<bool> addHouseholdMember({
    required String unitId,
    required String block,
    required int unitNo,
    required String fullName,
    required String phone,
    required String email,
    required String relationship,
  }) async {
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/home-owners?site_id=$effectiveSiteId');
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'block': block,
            'unit_no': unitNo,
            'floor': ((unitNo - 1) ~/ 4) + 1,
            'owner_full_name': fullName,
            'email': email,
            'phone': phone,
            'role': 'RESIDENT',
            'relationship': relationship,
          }),
        ).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200 || response.statusCode == 201) {
          await fetchHomeOwners(siteId: effectiveSiteId);
          notifyListeners();
          return true;
        }
      } catch (e) {
        debugPrint('addHouseholdMember error: $e');
      }
    }

    // In-memory update
    final hoIndex = _homeOwners.indexWhere((h) => h.unitId == unitId);
    if (hoIndex != -1) {
      final newMember = UnitResidentMember(
        id: 'mem-${DateTime.now().millisecondsSinceEpoch}',
        fullName: fullName,
        relationship: relationship,
        phone: phone,
        email: email,
        isOwner: false,
      );
      final updatedResidents = List<UnitResidentMember>.from(_homeOwners[hoIndex].householdResidents)..add(newMember);
      _homeOwners[hoIndex] = _homeOwners[hoIndex].copyWith(householdResidents: updatedResidents);
      notifyListeners();
    }
    return true;
  }

  Future<bool> moveOutResident(String unitId, {String? notes}) async {
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/units/$unitId/move-out?site_id=$effectiveSiteId');
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'notes': notes}),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200) {
          await fetchHomeOwners(siteId: effectiveSiteId);
          return true;
        }
      } catch (e) {
        debugPrint('moveOutResident error: $e');
      }
    }
    // Fallback locally
    final idx = _homeOwners.indexWhere((h) => h.unitId == unitId);
    if (idx != -1) {
      _homeOwners[idx] = _homeOwners[idx].copyWith(
        occupancyStatus: 'VACANT',
        tenantFullName: null,
        tenantEmail: null,
        tenantPhone: null,
      );
      final currentHist = _localOccupancyHistory[unitId];
      if (currentHist != null) {
        _localOccupancyHistory[unitId] = currentHist.map((h) {
          if (h.isActive) {
            return h.copyWith(
              isActive: false,
              endDate: DateTime.now().toIso8601String().split('T').first,
              notes: notes,
            );
          }
          return h;
        }).toList();
      }
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<bool> moveInResident(
    String unitId, {
    required String role,
    required String fullName,
    required String email,
    String? phone,
    String? notes,
  }) async {
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/units/$unitId/move-in?site_id=$effectiveSiteId');
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'role': role,
            'full_name': fullName,
            'email': email,
            'phone': phone,
            'notes': notes,
          }),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200) {
          await fetchHomeOwners(siteId: effectiveSiteId);
          return true;
        }
      } catch (e) {
        debugPrint('moveInResident error: $e');
      }
    }
    // Fallback locally
    final idx = _homeOwners.indexWhere((h) => h.unitId == unitId);
    if (idx != -1) {
      final isTenant = role.toUpperCase() == 'TENANT';
      _homeOwners[idx] = _homeOwners[idx].copyWith(
        occupancyStatus: isTenant ? 'TENANT_OCCUPIED' : 'OWNER_OCCUPIED',
        tenantFullName: isTenant ? fullName : null,
        tenantEmail: isTenant ? email : null,
        tenantPhone: isTenant ? phone : null,
        ownerFullName: !isTenant ? fullName : _homeOwners[idx].ownerFullName,
      );

      final currentHist = _localOccupancyHistory.putIfAbsent(unitId, () => []);
      _localOccupancyHistory[unitId] = currentHist.map((h) {
        if (h.isActive) {
          return h.copyWith(
            isActive: false,
            endDate: DateTime.now().toIso8601String().split('T').first,
          );
        }
        return h;
      }).toList();

      _localOccupancyHistory[unitId]!.insert(0, OccupancyHistoryItem(
        id: DateTime.now().millisecondsSinceEpoch,
        unitId: int.tryParse(unitId.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
        personId: 105,
        personName: fullName,
        personPhone: phone,
        personEmail: email,
        role: role,
        startDate: DateTime.now().toIso8601String().split('T').first,
        endDate: null,
        isActive: true,
        exitBalance: Decimal.zero,
        notes: notes,
        createdAt: DateTime.now(),
      ));

      notifyListeners();
      return true;
    }
    return false;
  }

  Future<List<OccupancyHistoryItem>> fetchOccupancyHistory(String unitId) async {
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/site-admin/units/$unitId/occupancy-history?site_id=$effectiveSiteId');
        final response = await http.get(url).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200) {
          final List<dynamic> list = jsonDecode(response.body);
          final items = list.map((item) => OccupancyHistoryItem.fromJson(item)).toList();
          if (items.isNotEmpty) {
            return items;
          }
        }
      } catch (e) {
        debugPrint('fetchOccupancyHistory error: $e');
      }
    }
    return _localOccupancyHistory[unitId] ?? [];
  }

  Future<void> approveRegistration(String requestId) async {
    final index = _pendingRegistrations.indexWhere((r) => r.id == requestId);
    if (index == -1) return;

    final target = _pendingRegistrations[index];
    String tempPassword = 'SP-SAKIN-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}';

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final url = Uri.parse('http://$host:8080/api/v1/registration/approve/$requestId');
        final response = await http.post(url).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          if (data['temporary_password'] != null && data['temporary_password'].toString().isNotEmpty) {
            tempPassword = data['temporary_password'].toString();
          }
          await fetchSiteManagerOverview(siteId: _currentManagedSite?.id, period: _selectedDuesMonth);
        }
      } catch (e) {
        debugPrint('approveRegistration network error: $e');
      }
    }

    _pendingRegistrations = _pendingRegistrations.where((r) => r.id != requestId).toList();

    final cleanBlock = target.block.replaceAll('Blok', '').trim();
    final existingIdx = _flatsList.indexWhere((f) => f.unitNo == target.unitNo && f.block == cleanBlock);
    if (existingIdx == -1) {
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
      if (_selectedDuesMonth.isNotEmpty) {
        _monthlyFlats[_selectedDuesMonth] = [newFlat, ...(_monthlyFlats[_selectedDuesMonth] ?? [])];
      }

      _collectionSummary = _collectionSummary.copyWith(
        totalUnitsCount: _collectionSummary.totalUnitsCount + 1,
        overdueUnitsCount: _collectionSummary.overdueUnitsCount + 1,
        totalExpected: _collectionSummary.totalExpected + target.duesAmount,
      );
    } else {
      if (_selectedDuesMonth.isNotEmpty) {
        _monthlyFlats[_selectedDuesMonth] = List.from(_flatsList);
      }
    }

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
    final unitLabel = _activeUnit.displayLabel.isNotEmpty ? _activeUnit.displayLabel : 'Yetkili Bağımsız Bölüm';
    final siteSlug = _activeUnit.siteName.isNotEmpty ? _activeUnit.siteName.toLowerCase().replaceAll(' ', '-') : 'site';
    final unitId = _activeUnit.id.isNotEmpty ? _activeUnit.id : (_activeUnit.unitNumber.isNotEmpty ? 'd-${_activeUnit.unitNumber}' : 'unit');
    _unitInviteInfo = UnitInviteInfo(
      inviteUrl: 'https://sitepulse.app/join/$siteSlug/units/$unitId?token=$token',
      token: token,
      unitLabel: unitLabel,
      expiresAtStr: '7 gün geçerli',
      securityNotice: 'Bu link sadece $unitLabel bağımsız bölümüne erişim yetkisi verir. Diğer daire veya yönetim yetkileri kapalıdır.',
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
      siteId: _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : ''),
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
        final amt = Decimal.tryParse(amtStr) ?? Decimal.zero;
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

  static String cleanBlock(String? b) {
    if (b == null) return '';
    return b
        .toUpperCase()
        .replaceAll(RegExp(r'BLOK|BLOCK', caseSensitive: false), '')
        .replaceAll(RegExp(r'[\s\-_]'), '')
        .trim();
  }

  static bool isSameBlock(String? b1, String? b2) {
    final c1 = cleanBlock(b1);
    final c2 = cleanBlock(b2);
    if (c1.isEmpty || c2.isEmpty) return false;
    return c1 == c2;
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
        if (f.unitNo == matchedUnitNo && (matchedBlock == null || isSameBlock(f.block, matchedBlock))) {
          candidateFlat = f;
          matchedBlock ??= f.block;
          matchedResidentName = f.residentName;
          matchedUnitId = f.id.isNotEmpty ? f.id : 'd-${f.unitNo}';
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
          matchedUnitId = f.id.isNotEmpty ? f.id : 'd-${f.unitNo}';
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
        ? '${cleanBlock(effectiveBlock)}_$effectiveUnitNo'
        : null;

    final bool isTxnAlreadyProcessed = _processedTransactionIds.contains(rawId);
    final bool isFlatAlreadyPaid = candidateFlat != null &&
        candidateFlat.isPaid &&
        candidateFlat.paidDateStr != null &&
        candidateFlat.paidDateStr!.isNotEmpty;
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
      matchedDueId = outstandingBalance > Decimal.zero ? candidateFlat.id : null;
      amountMatchesBalance = (amount == outstandingBalance);
      confidence = amountMatchesBalance ? 100 : 90;
      status = confidence >= 70 ? 'ONAY_BEKLIYOR' : 'ESLESTIRILEMEDI';
      notes = outstandingBalance == Decimal.zero
          ? 'Aktif aidat borcu bulunmuyor • ₺$amount tutarındaki ödeme avans bakiyesi (Avans Bakiye) olarak eşleştirildi.'
          : (amountMatchesBalance
              ? 'Aidat borcuyla (%5 KMK gecikme tazminatı dahil) birebir eşleşti'
              : 'Daire ve sakin tespit edildi');
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
      if (f.unitNo == unitNo && isSameBlock(f.block, block)) {
        candidateFlat = f;
        break;
      }
    }

    final balance = candidateFlat?.amountDue;
    final amtMatch = (balance != null && target.transaction.amount == balance);

    final updated = target.copyWith(
      matchedUnitId: candidateFlat?.id.isNotEmpty == true ? candidateFlat!.id : 'd-$unitNo',
      matchedBlock: block,
      matchedUnitNumber: unitNo,
      matchedResidentName: candidateFlat?.residentName ?? 'Daire $unitNo',
      confidenceScore: 100,
      matchedDueId: candidateFlat != null ? 'due-$unitNo' : '',
      outstandingBalance: balance,
      amountMatchesBalance: amtMatch,
      status: 'ONAY_BEKLIYOR',
      notes: 'Yönetici tarafından manuel olarak eşleştirildi${amtMatch ? " (Borçla tam eşleşti)" : ""}',
    );

    _reconciliationQueue[idx] = updated;
    notifyListeners();
  }

  Future<void> confirmReconciliation(
    List<String> matchIds, {
    String? optionalHostMessage,
    bool rememberSenderIban = true,
  }) async {
    if (matchIds.isEmpty) return;

    Decimal totalCleared = Decimal.zero;
    final List<ReconciliationQueueItem> updatedQueue = [];
    int rememberedIbansCount = 0;

    for (final item in _reconciliationQueue) {
      if (matchIds.contains(item.matchId)) {
        updatedQueue.add(item.copyWith(status: 'ONAYLANDI'));
        _processedTransactionIds.add(item.transaction.transactionId);
        if (item.matchedUnitNumber != null) {
          _processedUnitKeys.add('${cleanBlock(item.matchedBlock)}_${item.matchedUnitNumber}');
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
              (item.matchedBlock == null || isSameBlock(f.block, item.matchedBlock)));

          if (flatIndex != -1) {
            final flat = _flatsList[flatIndex];
            final paymentAmount = item.transaction.amount;

            if (!flat.isPaid && flat.amountDue > Decimal.zero) {
              final cleared = paymentAmount >= flat.amountDue ? flat.amountDue : paymentAmount;
              final surplus = paymentAmount > flat.amountDue ? paymentAmount - flat.amountDue : Decimal.zero;

              _flatsList[flatIndex] = flat.copyWith(
                isPaid: true,
                daysOverdue: 0,
                paidDateStr: 'Banka Ekstresi',
                advanceBalance: flat.advanceBalance + surplus,
              );
              totalCleared += paymentAmount;
              if (surplus > Decimal.zero) {
                _creditUnitAdvance(item.matchedBlock ?? flat.block, flat.unitNo, surplus);
              }

              _collectionSummary = _collectionSummary.copyWith(
                paidUnitsCount: _collectionSummary.paidUnitsCount + 1,
                overdueUnitsCount: _collectionSummary.overdueUnitsCount > 0
                    ? _collectionSummary.overdueUnitsCount - 1
                    : 0,
                totalCollected: _collectionSummary.totalCollected + cleared,
                totalAdvanceBalance: _collectionSummary.totalAdvanceBalance + surplus,
                totalOverdueWithInterest: _collectionSummary.totalOverdueAmount > flat.amountDue
                    ? _collectionSummary.totalOverdueAmount - flat.amountDue
                    : Decimal.zero,
              );
            } else {
              // Flat has NO debt (already paid or zero debt): match entire payment as advance payment!
              totalCleared += paymentAmount;
              _flatsList[flatIndex] = flat.copyWith(
                advanceBalance: flat.advanceBalance + paymentAmount,
              );
              _creditUnitAdvance(item.matchedBlock ?? flat.block, flat.unitNo, paymentAmount);
              _collectionSummary = _collectionSummary.copyWith(
                totalAdvanceBalance: _collectionSummary.totalAdvanceBalance + paymentAmount,
              );
            }
          }

          // Also update _monthlyFlats across ALL cached monthly maps
          for (final monthKey in _monthlyFlats.keys) {
            final monthList = _monthlyFlats[monthKey];
            if (monthList != null) {
              final mIdx = monthList.indexWhere((f) =>
                  f.unitNo == item.matchedUnitNumber &&
                  (item.matchedBlock == null || isSameBlock(f.block, item.matchedBlock)));
              if (mIdx != -1) {
                final mf = monthList[mIdx];
                if (!mf.isPaid) {
                  monthList[mIdx] = mf.copyWith(
                    isPaid: true,
                    daysOverdue: 0,
                    paidDateStr: 'Banka Ekstresi',
                  );
                }
              }
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

    // Dispatch to Rust Backend to persist reconciliation settlement
    if (isTestMode) return;
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/bank/statements/confirm-reconciliation');
      final payload = {
        'site_id': _currentManagedSite?.id ?? _activeUnit.siteId,
        'match_ids': matchIds,
        'optional_message': optionalHostMessage,
        'remember_sender_iban': rememberSenderIban,
      };
      await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode(payload),
      ).timeout(const Duration(seconds: 4));
    } catch (e) {
      debugPrint('Confirm reconciliation backend error: $e');
    }

    // Refresh live site overview from backend
    try {
      await fetchSiteManagerOverview(
        siteId: _currentManagedSite?.id,
        period: _selectedDuesMonth,
      );
      await fetchReconciliationQueue(_currentManagedSite?.id ?? _activeUnit.siteId);
    } catch (e) {
      debugPrint('Overview refresh after reconciliation error: $e');
    }
  }

  Future<void> _persistRememberedSenderIban({
    required String unitId,
    required String senderIban,
    String? senderName,
  }) async {
    if (isTestMode) return;
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/bank/remembered-ibans');
      await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'site_id': _currentManagedSite?.id ?? _activeUnit.siteId,
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
    final flatIndex = _flatsList.indexWhere((f) => f.unitNo == unitNo && isSameBlock(f.block, block));
    Decimal clearedDebt = Decimal.zero;
    Decimal advanceCredit = Decimal.zero;

    if (flatIndex != -1) {
      final flat = _flatsList[flatIndex];
      if (!flat.isPaid && flat.amountDue > Decimal.zero) {
        if (amount >= flat.amountDue) {
          clearedDebt = flat.amountDue;
          advanceCredit = amount - flat.amountDue;
          final updated = flat.copyWith(
            isPaid: true,
            daysOverdue: 0,
            advanceBalance: flat.advanceBalance + advanceCredit,
            paidDateStr: paymentMethod == 'CREDIT_CARD' ? 'Kredi Kartı (3D Secure)' : 'FAST / Havale',
          );
          _flatsList[flatIndex] = updated;
          _collectionSummary = _collectionSummary.copyWith(
            paidUnitsCount: _collectionSummary.paidUnitsCount + 1,
            overdueUnitsCount: _collectionSummary.overdueUnitsCount > 0 ? _collectionSummary.overdueUnitsCount - 1 : 0,
            totalCollected: _collectionSummary.totalCollected + clearedDebt,
            totalAdvanceBalance: _collectionSummary.totalAdvanceBalance + advanceCredit,
            totalOverdueWithInterest: _collectionSummary.totalOverdueAmount > clearedDebt
                ? _collectionSummary.totalOverdueAmount - clearedDebt
                : Decimal.zero,
          );

          for (final monthList in _monthlyFlats.values) {
            final mIdx = monthList.indexWhere((f) => f.unitNo == unitNo && isSameBlock(f.block, block));
            if (mIdx != -1) {
              monthList[mIdx] = updated;
            }
          }
        } else {
          clearedDebt = amount;
          final updated = flat.copyWith(amountDue: flat.amountDue - amount);
          _flatsList[flatIndex] = updated;
          _collectionSummary = _collectionSummary.copyWith(
            totalCollected: _collectionSummary.totalCollected + amount,
            totalOverdueWithInterest: _collectionSummary.totalOverdueAmount > amount
                ? _collectionSummary.totalOverdueAmount - amount
                : Decimal.zero,
          );

          for (final monthList in _monthlyFlats.values) {
            final mIdx = monthList.indexWhere((f) => f.unitNo == unitNo && isSameBlock(f.block, block));
            if (mIdx != -1) {
              monthList[mIdx] = updated;
            }
          }
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
    if (isTestMode) return;
    try {
      final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final url = Uri.parse('http://$host:8080/api/v1/payments/record');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'site_id': _activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : (_currentManagedSite?.id ?? ''),
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
        if (_currentManagedSite?.id.isNotEmpty == true || _userSession.role == UserRole.siteManager) {
          await fetchSiteManagerOverview(
            siteId: _currentManagedSite?.id,
            period: _selectedDuesMonth,
          );
        }
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
          PermissionScope(code: 'SITE_MANAGE', title: 'Site Yönetimi', isGranted: true, isolationNote: 'Blok, daire ve personel yönetimi'),
          PermissionScope(code: 'RESIDENT_INVITE_SITE', title: 'Site Kayıt Linki Üretme', isGranted: true, isolationNote: 'Site geneli self-registration'),
          PermissionScope(code: 'RESIDENT_APPROVE', title: 'Sakin Başvuru Onayı', isGranted: true, isolationNote: 'Onay kuyruğu ve şifre üretimi'),
          PermissionScope(code: 'LEDGER_MANAGE_ALL', title: 'Aidat & Finans Yönetimi', isGranted: true, isolationNote: 'Tüm dairelerin borç ve faiz takibi'),
          PermissionScope(code: 'ANNOUNCEMENT_BROADCAST', title: 'Site Geneli Duyuru', isGranted: true, isolationNote: 'Tüm dairelere SMS/bildirim'),
        ];
        break;
      case UserRole.homeOwner:
        permissions = const [
          PermissionScope(code: 'UNIT_READ', title: 'Daire Aidat & Makbuz Görüntüleme', isGranted: true, isolationNote: 'Sadece yetkili bağımsız bölüm'),
          PermissionScope(code: 'UNIT_PAY', title: 'Online Aidat Ödeme (Kredi Kartı)', isGranted: true, isolationNote: 'Sadece yetkili bağımsız bölüm'),
          PermissionScope(code: 'UNIT_INVITE_CO_RESIDENT', title: 'Hane Sakini Davet Linki Üretme', isGranted: true, isolationNote: 'Sadece yetkili bağımsız bölüm'),
          PermissionScope(code: 'UNIT_MANAGE_HOUSEHOLD', title: 'Hane Sakinlerini Listeleme/Ekleme', isGranted: true, isolationNote: 'Sadece yetkili bağımsız bölüm'),
          PermissionScope(code: 'LEDGER_MANAGE_ALL', title: 'Site Finansını Yönetme', isGranted: false, isolationNote: 'Engelli: Kat malikleri diğer daireleri göremez'),
        ];
        break;
      case UserRole.homeResident:
        permissions = const [
          PermissionScope(code: 'UNIT_READ', title: 'Daire Aidat & Makbuz Görüntüleme', isGranted: true, isolationNote: 'Sadece yetkili bağımsız bölüm'),
          PermissionScope(code: 'UNIT_PAY', title: 'Online Aidat Ödeme', isGranted: true, isolationNote: 'Sadece yetkili bağımsız bölüm'),
          PermissionScope(code: 'UNIT_INVITE_CO_RESIDENT', title: 'Hane Sakini Davet Linki', isGranted: false, isolationNote: 'Engelli: Sadece Kat Maliki davet linki üretebilir'),
          PermissionScope(code: 'UNIT_MANAGE_HOUSEHOLD', title: 'Hane Sakinlerini Yönetme', isGranted: false, isolationNote: 'Engelli: Aile sakinleri üye ekleyemez'),
          PermissionScope(code: 'LEDGER_MANAGE_ALL', title: 'Site Finansını Yönetme', isGranted: false, isolationNote: 'Engelli: Site yönetimi yetkisi yok'),
        ];
        break;
    }

    final name = customName ?? role.displayName;
    final email = customEmail ?? (role == UserRole.saasAdmin ? 'admin@sitepulse.local' : '');
    final phone = customPhone ?? '';

    final resolvedSiteName = (role == UserRole.siteManager && _currentManagedSite != null && _currentManagedSite!.name.isNotEmpty)
        ? _currentManagedSite!.name
        : (_activeUnit.siteName.isNotEmpty
            ? _activeUnit.siteName
            : (_saasSites.isNotEmpty ? _saasSites.first.name : ''));

    return UserSession(
      id: 'usr-${role.name}',
      fullName: name,
      email: email,
      phone: phone,
      role: role,
      siteName: resolvedSiteName,
      unitName: (role == UserRole.homeOwner || role == UserRole.homeResident)
          ? (_activeUnit.displayLabel.isNotEmpty ? _activeUnit.displayLabel : 'Bağımsız Bölüm')
          : 'Tüm Kompleks',
      authProvider: provider,
      avatarUrl: avatarUrl,
      permissions: permissions,
    );
  }

  // Payment Tracking & Unified Treasury Streams (STORY-09-01 .. STORY-09-07)
  PaymentStreamResponseDto? _paymentStream;
  PaymentStreamResponseDto? get paymentStream => _paymentStream;

  DebtAgingReportDto? _debtAgingReport;
  DebtAgingReportDto? get debtAgingReport => _debtAgingReport;

  PaymentReceiptDto? _selectedReceipt;
  PaymentReceiptDto? get selectedReceipt => _selectedReceipt;

  bool _isPaymentStreamLoading = false;
  bool get isPaymentStreamLoading => _isPaymentStreamLoading;

  Future<PaymentStreamResponseDto> fetchPaymentStream({
    String? channel,
    String? payerRole,
    String? settlementStatus,
    String? unitId,
    String? search,
    String? siteId,
  }) async {
    _isPaymentStreamLoading = true;
    notifyListeners();

    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? 'site-1';
    final queryParams = <String, String>{
      'site_id': effectiveSiteId,
    };
    if (channel != null && channel.isNotEmpty && channel != 'ALL') queryParams['channel'] = channel;
    if (payerRole != null && payerRole.isNotEmpty && payerRole != 'ALL') queryParams['payer_role'] = payerRole;
    if (settlementStatus != null && settlementStatus.isNotEmpty && settlementStatus != 'ALL') queryParams['settlement_status'] = settlementStatus;
    if (unitId != null && unitId.isNotEmpty) queryParams['unit_id'] = unitId;
    if (search != null && search.isNotEmpty) queryParams['search'] = search;

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.http('$host:8080', '/api/v1/payments/stream', queryParams);
        final response = await http.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final jsonMap = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          _paymentStream = PaymentStreamResponseDto.fromJson(jsonMap);
          _isPaymentStreamLoading = false;
          notifyListeners();
          return _paymentStream!;
        }
      } catch (e) {
        debugPrint('fetchPaymentStream error: $e');
      }
    }

    // Default mock stream for test fixtures or offline demo
    final mockEntries = [
      PaymentEntryDto(
        id: 1,
        siteId: effectiveSiteId,
        unitId: 'd-14',
        unitLabel: 'A Blok D:14',
        payerName: 'Ahmet Yılmaz',
        payerRole: 'OWNER',
        receiptNumber: 'TAH-2026-000001',
        amount: Decimal.parse('1400.00'),
        paymentChannel: 'VIRTUAL_IBAN',
        settlementStatus: 'SETTLED',
        description: 'Eylül 2026 Aidatı Sanal IBAN Otomatik Eşleşme',
        paymentDate: DateTime.now().subtract(const Duration(days: 2)),
        createdAt: DateTime.now().subtract(const Duration(days: 2)),
      ),
      PaymentEntryDto(
        id: 2,
        siteId: effectiveSiteId,
        unitId: 'd-14',
        unitLabel: 'A Blok D:14',
        payerName: 'Kerem Yılmaz',
        payerRole: 'TENANT',
        receiptNumber: 'TAH-2026-000002',
        amount: Decimal.parse('2500.00'),
        paymentChannel: 'BANK_STATEMENT',
        settlementStatus: 'SETTLED',
        description: 'Asansör Revizyon ve Demirbaş Katkı Payı [Kira Mahsubu]',
        paymentDate: DateTime.now().subtract(const Duration(days: 1)),
        createdAt: DateTime.now().subtract(const Duration(days: 1)),
      ),
      PaymentEntryDto(
        id: 3,
        siteId: effectiveSiteId,
        unitId: 'd-14',
        unitLabel: 'A Blok D:14',
        payerName: 'Site Yönetimi',
        payerRole: 'OWNER',
        receiptNumber: 'TAH-2026-000003',
        amount: Decimal.parse('500.00'),
        paymentChannel: 'INTER_LEDGER',
        settlementStatus: 'SETTLED',
        description: 'Avans Bakiyesinden Demirbaş Borcuna Virman',
        paymentDate: DateTime.now(),
        createdAt: DateTime.now(),
      ),
    ];

    _paymentStream = PaymentStreamResponseDto(
      entries: mockEntries,
      totalVolume: Decimal.parse('4400.00'),
      settledVolume: Decimal.parse('4400.00'),
      unmatchedVolume: Decimal.zero,
      totalCount: mockEntries.length,
    );
    _isPaymentStreamLoading = false;
    notifyListeners();
    return _paymentStream!;
  }

  Future<DebtAgingReportDto> fetchDebtAgingReport({String? siteId}) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? 'site-1';
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.parse('http://$host:8080/api/v1/payments/debt-aging?site_id=$effectiveSiteId');
        final response = await http.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final jsonMap = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          _debtAgingReport = DebtAgingReportDto.fromJson(jsonMap);
          notifyListeners();
          return _debtAgingReport!;
        }
      } catch (e) {
        debugPrint('fetchDebtAgingReport error: $e');
      }
    }

    _debtAgingReport = DebtAgingReportDto(
      asOfDate: DateTime.now(),
      totalCurrent: Decimal.parse('1400.00'),
      total1to30Days: Decimal.parse('1000.00'),
      total31to60Days: Decimal.parse('800.00'),
      total60PlusDays: Decimal.parse('2200.00'),
      totalPenalty: Decimal.parse('245.50'),
      grandTotal: Decimal.parse('5645.50'),
      brackets: [
        DebtAgingBracketDto(
          unitId: 'd-14',
          unitLabel: 'A Blok D:14',
          residentName: 'Ahmet Yılmaz',
          debtorType: 'OWNER',
          currentDue: Decimal.parse('1400.00'),
          overdue1to30Days: Decimal.parse('1000.00'),
          overdue31to60Days: Decimal.parse('800.00'),
          overdue60PlusDays: Decimal.parse('2200.00'),
          accruedDelayPenalty: Decimal.parse('245.50'),
          totalOutstanding: Decimal.parse('5645.50'),
        ),
      ],
    );
    notifyListeners();
    return _debtAgingReport!;
  }

  Future<PaymentReceiptDto?> recordManualPayment({
    required String unitId,
    required double amount,
    required String payerName,
    required String payerRole,
    required String paymentChannel,
    String? description,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? 'site-1';
    final payload = {
      'site_id': effectiveSiteId,
      'unit_id': unitId,
      'amount': amount.toStringAsFixed(2),
      'payer_name': payerName,
      'payer_role': payerRole,
      'payment_channel': paymentChannel,
      'description': description,
    };

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.parse('http://$host:8080/api/v1/payments/record-manual');
        final response = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 201 || response.statusCode == 200) {
          final jsonMap = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          final receipt = PaymentReceiptDto.fromJson(jsonMap);
          await fetchPaymentStream(siteId: effectiveSiteId);
          await fetchDebtAgingReport(siteId: effectiveSiteId);
          return receipt;
        }
      } catch (e) {
        debugPrint('recordManualPayment error: $e');
      }
    }

    final receipt = PaymentReceiptDto(
      id: 99,
      siteId: effectiveSiteId,
      unitId: unitId,
      receiptNumber: 'TAH-2026-000099',
      sequenceNumber: 99,
      payerName: payerName,
      payerRole: payerRole,
      totalAmount: Decimal.parse(amount.toStringAsFixed(2)),
      paymentChannel: paymentChannel,
      allocatedPrincipal: Decimal.parse(amount.toStringAsFixed(2)),
      allocatedPenalty: Decimal.zero,
      allocatedAdvance: Decimal.zero,
      isRentOffsetEligible: payerRole == 'TENANT' && (description?.toUpperCase().contains('DEMİRBAŞ') ?? false),
      verificationHash: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      issuedAt: DateTime.now(),
    );
    return receipt;
  }

  Future<Map<String, dynamic>?> executeInterLedgerTransfer({
    required String unitId,
    required double amount,
    String? note,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? 'site-1';
    final payload = {
      'site_id': effectiveSiteId,
      'unit_id': unitId,
      'amount': amount.toStringAsFixed(2),
      'note': note,
    };

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.parse('http://$host:8080/api/v1/payments/inter-ledger-transfer');
        final response = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200) {
          final res = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          await fetchPaymentStream(siteId: effectiveSiteId);
          await fetchDebtAgingReport(siteId: effectiveSiteId);
          return res;
        }
      } catch (e) {
        debugPrint('executeInterLedgerTransfer error: $e');
      }
    }

    return {
      'success': true,
      'message': '₺${amount.toStringAsFixed(2)} avans bakiyesinden demirbaş borcuna başarıyla aktarıldı.',
      'receipt_number': 'TAH-2026-000101',
      'remaining_advance_balance': '500.00',
    };
  }

  Future<PaymentReceiptDto?> fetchReceipt(String identifier, {String? siteId}) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? 'site-1';
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.parse('http://$host:8080/api/v1/payments/receipts/$identifier?site_id=$effectiveSiteId');
        final response = await http.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final jsonMap = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          _selectedReceipt = PaymentReceiptDto.fromJson(jsonMap);
          notifyListeners();
          return _selectedReceipt;
        }
      } catch (e) {
        debugPrint('fetchReceipt error: $e');
      }
    }

    _selectedReceipt = PaymentReceiptDto(
      id: 1,
      siteId: effectiveSiteId,
      unitId: 'd-14',
      receiptNumber: identifier,
      sequenceNumber: 1,
      payerName: 'Ahmet Yılmaz',
      payerRole: 'OWNER',
      totalAmount: Decimal.parse('1400.00'),
      paymentChannel: 'VIRTUAL_IBAN',
      allocatedPrincipal: Decimal.parse('1400.00'),
      allocatedPenalty: Decimal.zero,
      allocatedAdvance: Decimal.zero,
      verificationHash: '4a533b37b01a755d7f02d08a0d78386f68809ff44f2bbcf8fb0d5a4208a0ab2b',
      issuedAt: DateTime.now(),
    );
    notifyListeners();
    return _selectedReceipt;
  }

  Future<Map<String, dynamic>?> transferUnitOwnership({
    required String unitId,
    required String newOwnerName,
    String? newOwnerPhone,
    String? newOwnerEmail,
    String? notes,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? 'site-1';
    final payload = {
      'site_id': effectiveSiteId,
      'unit_id': unitId,
      'new_owner_name': newOwnerName,
      'new_owner_phone': newOwnerPhone,
      'new_owner_email': newOwnerEmail,
      'notes': notes,
    };

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.parse('http://$host:8080/api/v1/site-admin/units/$unitId/transfer-ownership');
        final response = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200) {
          final res = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          await fetchHomeOwners(siteId: effectiveSiteId);
          return res;
        }
      } catch (e) {
        debugPrint('transferUnitOwnership error: $e');
      }
    }

    return {
      'success': true,
      'message': 'Mülk tapu devri başarıyla tamamlandı. Yeni malik ($newOwnerName) kaydedildi.',
      'new_owner_name': newOwnerName,
      'old_owner_exit_balance': '0.00',
    };
  }

  // ---------------------------------------------------------------------------
  // EPIC-10: Capital Expenditure & Fixtures (Demirbaş Yönetimi) State & Methods
  // ---------------------------------------------------------------------------
  List<CapitalProjectItem> _capitalProjects = [];
  List<CapitalProjectItem> get capitalProjects => _capitalProjects;

  CapitalProjectItem? _activeCapitalProject;
  CapitalProjectItem? get activeCapitalProject => _activeCapitalProject;

  List<CapitalProjectInstallmentItem> _capitalInstallments = [];
  List<CapitalProjectInstallmentItem> get capitalInstallments => _capitalInstallments;

  List<CapitalContractorDisbursementItem> _capitalDisbursements = [];
  List<CapitalContractorDisbursementItem> get capitalDisbursements => _capitalDisbursements;

  List<UnitCapitalShareItem> _unitCapitalShares = [];
  List<UnitCapitalShareItem> get unitCapitalShares => _unitCapitalShares;

  bool _isLoadingCapitalProjects = false;
  bool get isLoadingCapitalProjects => _isLoadingCapitalProjects;

  String? _capitalProjectError;
  String? get capitalProjectError => _capitalProjectError;

  @visibleForTesting
  void setCapitalProjectsForTesting(List<CapitalProjectItem> projects) {
    _capitalProjects = List.from(projects);
    if (_capitalProjects.isNotEmpty) {
      _activeCapitalProject = _capitalProjects.first;
    }
    notifyListeners();
  }

  List<CapitalProjectItem> _getMockCapitalProjects() {
    return [
      CapitalProjectItem(
        id: 'cproj-1',
        siteId: 'site-1',
        title: 'Asansör Revizyonu ve Yeşil Etiket',
        category: 'ELEVATOR',
        description: 'A ve B Blok 2 adet asansörün TSE standardına uyumlu yeşil etiket revizyonu ve halat değişimi',
        totalBudget: Decimal.parse('120000.00'),
        allocationBasis: 'BY_LAND_SHARE',
        targetStartDate: DateTime(2026, 9, 1),
        targetCompletionDate: DateTime(2026, 12, 1),
        contractorName: 'Schindler & Doğan Asansör Sanayi',
        contractorTaxNo: '3120495811',
        contractorIban: 'TR560006200000012345678901',
        contractAmount: Decimal.parse('120000.00'),
        status: 'ACTIVE',
        collectedAmount: Decimal.parse('60000.00'),
        disbursedAmount: Decimal.parse('40000.00'),
        remainingFundBalance: Decimal.parse('20000.00'),
        totalUnitsCount: 12,
        installmentsCount: 4,
        createdAt: DateTime(2026, 8, 20),
      ),
    ];
  }

  List<CapitalProjectInstallmentItem> _getMockCapitalInstallments(String projectId) {
    return [
      CapitalProjectInstallmentItem(
        id: 'cinst-1',
        projectId: projectId,
        installmentNumber: 1,
        totalInstallments: 4,
        dueDate: DateTime(2026, 9, 15),
        installmentBudget: Decimal.parse('30000.00'),
        percentage: Decimal.parse('25.00'),
        isAccrued: true,
        accruedAt: DateTime(2026, 9, 1),
      ),
      CapitalProjectInstallmentItem(
        id: 'cinst-2',
        projectId: projectId,
        installmentNumber: 2,
        totalInstallments: 4,
        dueDate: DateTime(2026, 10, 15),
        installmentBudget: Decimal.parse('30000.00'),
        percentage: Decimal.parse('25.00'),
        isAccrued: true,
        accruedAt: DateTime(2026, 10, 1),
      ),
      CapitalProjectInstallmentItem(
        id: 'cinst-3',
        projectId: projectId,
        installmentNumber: 3,
        totalInstallments: 4,
        dueDate: DateTime(2026, 11, 15),
        installmentBudget: Decimal.parse('30000.00'),
        percentage: Decimal.parse('25.00'),
        isAccrued: false,
      ),
      CapitalProjectInstallmentItem(
        id: 'cinst-4',
        projectId: projectId,
        installmentNumber: 4,
        totalInstallments: 4,
        dueDate: DateTime(2026, 12, 15),
        installmentBudget: Decimal.parse('30000.00'),
        percentage: Decimal.parse('25.00'),
        isAccrued: false,
      ),
    ];
  }

  List<CapitalContractorDisbursementItem> _getMockCapitalDisbursements(String projectId) {
    return [
      CapitalContractorDisbursementItem(
        id: 'cdisb-1',
        projectId: projectId,
        milestoneName: '1. Hakediş: Halat ve Pano Değişimi',
        invoiceNumber: 'FTR-2026-0089',
        amount: Decimal.parse('40000.00'),
        disbursementDate: DateTime(2026, 9, 20),
        recipientName: 'Schindler & Doğan Asansör Sanayi',
        recipientIban: 'TR560006200000012345678901',
        paymentReference: 'CPROJ-1-HK1',
        disbursementMethod: 'BANK_TRANSFER',
        notes: 'Halat ve kumanda paneli montaj tutanağı onaylandı',
        createdAt: DateTime(2026, 9, 20),
      ),
    ];
  }

  List<UnitCapitalShareItem> _getMockUnitCapitalShares(String projectId) {
    return [
      UnitCapitalShareItem(
        unitId: 'd-1',
        block: 'A',
        unitNumber: 1,
        ownerName: 'Ali Kaya',
        ownerPhone: '0532 111 22 33',
        landShare: 24,
        totalProjectShare: Decimal.parse('10000.00'),
        totalAccrued: Decimal.parse('5000.00'),
        totalPaid: Decimal.parse('5000.00'),
        remainingDebt: Decimal.zero,
        isSettled: true,
      ),
      UnitCapitalShareItem(
        unitId: 'd-2',
        block: 'A',
        unitNumber: 2,
        ownerName: 'Fatma Şahin',
        ownerPhone: '0533 222 33 44',
        landShare: 24,
        totalProjectShare: Decimal.parse('10000.00'),
        totalAccrued: Decimal.parse('5000.00'),
        totalPaid: Decimal.parse('2500.00'),
        remainingDebt: Decimal.parse('2500.00'),
        isSettled: false,
      ),
      UnitCapitalShareItem(
        unitId: 'd-14',
        block: 'A',
        unitNumber: 14,
        ownerName: 'Ahmet Yılmaz',
        ownerPhone: '0555 123 45 67',
        landShare: 24,
        totalProjectShare: Decimal.parse('10000.00'),
        totalAccrued: Decimal.parse('5000.00'),
        totalPaid: Decimal.parse('5000.00'),
        remainingDebt: Decimal.zero,
        isSettled: true,
      ),
    ];
  }

  Future<List<CapitalProjectItem>> fetchCapitalProjects({String? siteId}) async {
    _isLoadingCapitalProjects = true;
    _capitalProjectError = null;
    notifyListeners();

    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? 'site-1';

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.http('$host:8080', '/api/v1/capital-projects', {'site_id': effectiveSiteId});
        final response = await http.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final rawList = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
          _capitalProjects = rawList.map((e) => CapitalProjectItem.fromJson(e as Map<String, dynamic>)).toList();
          if (_capitalProjects.isNotEmpty) {
            _activeCapitalProject = _capitalProjects.first;
            await selectCapitalProject(_activeCapitalProject!);
          } else {
            _activeCapitalProject = null;
          }
          _isLoadingCapitalProjects = false;
          notifyListeners();
          return _capitalProjects;
        }
      } catch (e) {
        debugPrint('fetchCapitalProjects error: $e');
      }
    }

    _capitalProjects = _getMockCapitalProjects();
    if (_capitalProjects.isNotEmpty) {
      _activeCapitalProject = _capitalProjects.first;
      _capitalInstallments = _getMockCapitalInstallments(_activeCapitalProject!.id);
      _capitalDisbursements = _getMockCapitalDisbursements(_activeCapitalProject!.id);
      _unitCapitalShares = _getMockUnitCapitalShares(_activeCapitalProject!.id);
    }
    _isLoadingCapitalProjects = false;
    notifyListeners();
    return _capitalProjects;
  }

  Future<void> selectCapitalProject(CapitalProjectItem project) async {
    _activeCapitalProject = project;
    notifyListeners();
    await Future.wait([
      fetchCapitalInstallments(project.id),
      fetchCapitalDisbursements(project.id),
      fetchUnitCapitalShares(project.id),
    ]);
  }

  Future<List<CapitalProjectInstallmentItem>> fetchCapitalInstallments(String projectId) async {
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.parse('http://$host:8080/api/v1/capital-projects/$projectId/installments');
        final response = await http.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final raw = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
          _capitalInstallments = raw.map((e) => CapitalProjectInstallmentItem.fromJson(e as Map<String, dynamic>)).toList();
          notifyListeners();
          return _capitalInstallments;
        }
      } catch (e) {
        debugPrint('fetchCapitalInstallments error: $e');
      }
    }

    _capitalInstallments = _getMockCapitalInstallments(projectId);
    notifyListeners();
    return _capitalInstallments;
  }

  Future<List<CapitalContractorDisbursementItem>> fetchCapitalDisbursements(String projectId) async {
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.parse('http://$host:8080/api/v1/capital-projects/$projectId/disbursements');
        final response = await http.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final raw = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
          _capitalDisbursements = raw.map((e) => CapitalContractorDisbursementItem.fromJson(e as Map<String, dynamic>)).toList();
          notifyListeners();
          return _capitalDisbursements;
        }
      } catch (e) {
        debugPrint('fetchCapitalDisbursements error: $e');
      }
    }

    _capitalDisbursements = _getMockCapitalDisbursements(projectId);
    notifyListeners();
    return _capitalDisbursements;
  }

  Future<List<UnitCapitalShareItem>> fetchUnitCapitalShares(String projectId) async {
    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.parse('http://$host:8080/api/v1/capital-projects/$projectId/unit-shares');
        final response = await http.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final raw = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
          _unitCapitalShares = raw.map((e) => UnitCapitalShareItem.fromJson(e as Map<String, dynamic>)).toList();
          notifyListeners();
          return _unitCapitalShares;
        }
      } catch (e) {
        debugPrint('fetchUnitCapitalShares error: $e');
      }
    }

    _unitCapitalShares = _getMockUnitCapitalShares(projectId);
    notifyListeners();
    return _unitCapitalShares;
  }

  Future<CapitalProjectItem?> createCapitalProject({
    String? siteId,
    required String title,
    String? category,
    String? description,
    required Decimal totalBudget,
    String? allocationBasis,
    DateTime? targetStartDate,
    DateTime? targetCompletionDate,
    String? contractorName,
    String? contractorTaxNo,
    String? contractorIban,
    Decimal? contractAmount,
    List<Map<String, dynamic>>? installments,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? 'site-1';
    final payload = {
      'site_id': effectiveSiteId,
      'title': title,
      'category': category ?? 'ELEVATOR',
      'description': description,
      'total_budget': totalBudget.toString(),
      'allocation_basis': allocationBasis ?? 'BY_LAND_SHARE',
      'target_start_date': (targetStartDate ?? DateTime.now()).toIso8601String().substring(0, 10),
      if (targetCompletionDate != null)
        'target_completion_date': targetCompletionDate.toIso8601String().substring(0, 10),
      'contractor_name': contractorName,
      'contractor_tax_no': contractorTaxNo,
      'contractor_iban': contractorIban,
      if (contractAmount != null) 'contract_amount': contractAmount.toString(),
      if (installments != null) 'installments': installments,
    };

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.parse('http://$host:8080/api/v1/capital-projects');
        final response = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 201 || response.statusCode == 200) {
          final resJson = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          final created = CapitalProjectItem.fromJson(resJson);
          await fetchCapitalProjects(siteId: effectiveSiteId);
          await selectCapitalProject(created);
          return created;
        }
      } catch (e) {
        debugPrint('createCapitalProject error: $e');
      }
    }

    final newProject = CapitalProjectItem(
      id: 'cproj-${DateTime.now().millisecondsSinceEpoch}',
      siteId: effectiveSiteId,
      title: title,
      category: category ?? 'ELEVATOR',
      description: description,
      totalBudget: totalBudget,
      allocationBasis: allocationBasis ?? 'BY_LAND_SHARE',
      targetStartDate: targetStartDate ?? DateTime.now(),
      targetCompletionDate: targetCompletionDate,
      contractorName: contractorName,
      contractorTaxNo: contractorTaxNo,
      contractorIban: contractorIban,
      contractAmount: contractAmount,
      status: 'ACTIVE',
      collectedAmount: Decimal.zero,
      disbursedAmount: Decimal.zero,
      remainingFundBalance: Decimal.zero,
      totalUnitsCount: 12,
      installmentsCount: installments?.length ?? 1,
      createdAt: DateTime.now(),
    );
    _capitalProjects.insert(0, newProject);
    _activeCapitalProject = newProject;
    if (installments != null) {
      _capitalInstallments = installments.map((inst) {
        return CapitalProjectInstallmentItem(
          id: 'inst-${inst['installment_number']}-${newProject.id}',
          projectId: newProject.id,
          installmentNumber: inst['installment_number'] as int,
          totalInstallments: inst['total_installments'] as int,
          dueDate: DateTime.tryParse(inst['due_date']?.toString() ?? '') ?? DateTime.now(),
          installmentBudget: Decimal.tryParse(inst['installment_budget']?.toString() ?? '0') ?? Decimal.zero,
          percentage: Decimal.tryParse(inst['percentage']?.toString() ?? '0') ?? Decimal.zero,
          isAccrued: false,
        );
      }).toList();
    }
    notifyListeners();
    return newProject;
  }

  Future<Map<String, dynamic>> accrueCapitalInstallment(String projectId, int installmentNumber) async {
    final payload = {'installment_number': installmentNumber};

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.parse('http://$host:8080/api/v1/capital-projects/$projectId/accrue-installment');
        final response = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final res = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          await Future.wait([
            fetchCapitalInstallments(projectId),
            fetchUnitCapitalShares(projectId),
            fetchCapitalProjects(),
          ]);
          return res;
        } else {
          return {'success': false, 'message': utf8.decode(response.bodyBytes)};
        }
      } catch (e) {
        debugPrint('accrueCapitalInstallment error: $e');
      }
    }

    // Mock fallback
    final idx = _capitalInstallments.indexWhere((i) => i.projectId == projectId && i.installmentNumber == installmentNumber);
    if (idx != -1) {
      final old = _capitalInstallments[idx];
      _capitalInstallments[idx] = CapitalProjectInstallmentItem(
        id: old.id,
        projectId: old.projectId,
        installmentNumber: old.installmentNumber,
        totalInstallments: old.totalInstallments,
        dueDate: old.dueDate,
        installmentBudget: old.installmentBudget,
        percentage: old.percentage,
        isAccrued: true,
        accruedAt: DateTime.now(),
      );
      notifyListeners();
    }
    return {
      'success': true,
      'message': '$installmentNumber. Taksit tüm kat maliklerine başarıyla tahakkuk ettirildi.',
    };
  }

  Future<CapitalContractorDisbursementItem?> recordCapitalDisbursement(
    String projectId, {
    required String milestoneName,
    String? invoiceNumber,
    required Decimal amount,
    DateTime? disbursementDate,
    required String recipientName,
    required String recipientIban,
    String? paymentReference,
    String? disbursementMethod,
    String? notes,
  }) async {
    final payload = {
      'milestone_name': milestoneName,
      'invoice_number': invoiceNumber,
      'amount': amount.toString(),
      'disbursement_date': (disbursementDate ?? DateTime.now()).toIso8601String().substring(0, 10),
      'recipient_name': recipientName,
      'recipient_iban': recipientIban,
      'payment_reference': paymentReference,
      'disbursement_method': disbursementMethod ?? 'BANK_TRANSFER',
      'notes': notes,
    };

    if (!isTestMode) {
      try {
        final host = kIsWeb && Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
        final uri = Uri.parse('http://$host:8080/api/v1/capital-projects/$projectId/disbursements');
        final response = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 201 || response.statusCode == 200) {
          final resJson = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          final created = CapitalContractorDisbursementItem.fromJson(resJson);
          await Future.wait([
            fetchCapitalDisbursements(projectId),
            fetchCapitalProjects(),
          ]);
          return created;
        }
      } catch (e) {
        debugPrint('recordCapitalDisbursement error: $e');
      }
    }

    final newDisbursement = CapitalContractorDisbursementItem(
      id: 'cdisb-${DateTime.now().millisecondsSinceEpoch}',
      projectId: projectId,
      milestoneName: milestoneName,
      invoiceNumber: invoiceNumber,
      amount: amount,
      disbursementDate: disbursementDate ?? DateTime.now(),
      recipientName: recipientName,
      recipientIban: recipientIban,
      paymentReference: paymentReference,
      disbursementMethod: disbursementMethod ?? 'BANK_TRANSFER',
      notes: notes,
      createdAt: DateTime.now(),
    );
    _capitalDisbursements.insert(0, newDisbursement);
    if (_activeCapitalProject != null && _activeCapitalProject!.id == projectId) {
      final old = _activeCapitalProject!;
      final newDisbursed = old.disbursedAmount + amount;
      final newRemaining = old.collectedAmount - newDisbursed;
      _activeCapitalProject = CapitalProjectItem(
        id: old.id,
        siteId: old.siteId,
        title: old.title,
        category: old.category,
        description: old.description,
        totalBudget: old.totalBudget,
        allocationBasis: old.allocationBasis,
        targetStartDate: old.targetStartDate,
        targetCompletionDate: old.targetCompletionDate,
        contractorName: old.contractorName,
        contractorTaxNo: old.contractorTaxNo,
        contractorIban: old.contractorIban,
        contractAmount: old.contractAmount,
        status: old.status,
        collectedAmount: old.collectedAmount,
        disbursedAmount: newDisbursed,
        remainingFundBalance: newRemaining,
        totalUnitsCount: old.totalUnitsCount,
        installmentsCount: old.installmentsCount,
        createdAt: old.createdAt,
      );
    }
    notifyListeners();
    return newDisbursement;
  }
}
