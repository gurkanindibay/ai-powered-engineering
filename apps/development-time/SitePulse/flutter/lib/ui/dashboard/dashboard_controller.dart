import '../components/sp_effective_date_field.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:decimal/decimal.dart';
import '../../domain/formatting/json_decimal.dart';
import 'dart:async';
import 'dart:ui' show Brightness, PlatformDispatcher;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import '../../domain/models/auth_models.dart';
import '../../domain/models/dues_models.dart';
import '../../domain/models/unit_state.dart';
import '../../domain/models/person_ref.dart';
import '../../domain/services/api_client.dart';
import '../../domain/services/bank_file_parser.dart';
import '../../domain/services/person_directory_api.dart';
import '../../domain/services/payments_phase3_api.dart';
import '../../domain/services/platform_env.dart';
import '../../domain/logging/app_logger.dart';
import '../../testing/test_id.dart';
import '../../domain/usecases/calculate_dues_usecase.dart';
import '../design_system/money_formatter.dart';
import '../../l10n/app_strings.dart';
import 'package:http/http.dart' as http;
import 'package:google_sign_in/google_sign_in.dart';
part 'dashboard_controller_auth.dart';
part 'dashboard_controller_residents.dart';
part 'dashboard_controller_reconciliation.dart';
part 'dashboard_controller_payments.dart';
part 'dashboard_controller_capital.dart';

class DashboardController extends ChangeNotifier {
  static const String _googleClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static Future<void>? _googleSignInInitialization;

  /// Server's reason for the last refused [deleteHomeOwner] call, if any.
  String? lastDeleteHomeOwnerError;

  /// Modular extension helper to dispatch state change notifications.
  void notify() => notifyListeners();

  /// Extracts a user-friendly, localized error message from an HTTP response,
  /// parsing the standard `{"error": {"code": "...", "message": "..."}}` envelope.
  String extractErrorMessage(http.Response response, {String? fallback}) {
    final bodyText = utf8.decode(response.bodyBytes);
    try {
      final decoded = json.decode(bodyText);
      if (decoded is Map<String, dynamic>) {
        if (decoded['error'] is Map<String, dynamic>) {
          final err = decoded['error'] as Map<String, dynamic>;
          final code = err['code']?.toString();
          final serverMsg = err['message']?.toString();
          return AppStrings.localizedErrorMessage(code, fallback: serverMsg ?? fallback);
        } else if (decoded['error'] is String) {
          return AppStrings.localizeBackendMessage(decoded['error'] as String);
        } else if (decoded['message'] != null) {
          return AppStrings.localizeBackendMessage(decoded['message'].toString());
        }
      }
    } catch (_) {
      // Not a valid JSON envelope, fallback below.
    }
    final trimmed = bodyText.trim();
    if (trimmed.isNotEmpty && !trimmed.startsWith('{') && !trimmed.startsWith('[')) {
      return AppStrings.localizeBackendMessage(trimmed);
    }
    return fallback ?? 'İşlem başarısız oldu (HTTP ${response.statusCode})';
  }

  final CalculateDuesUseCase _calculateDuesUseCase;



  DashboardController({
    CalculateDuesUseCase? calculateDuesUseCase,
    bool startAuthenticated = false,
    this.isTestMode = false,
  })  : _calculateDuesUseCase = calculateDuesUseCase ?? CalculateDuesUseCase(),
        _isAuthenticated = startAuthenticated {
    _themeMode = _readSavedThemeMode();
    _isOffline = isPlatformOffline();
    _offlineSubscription = platformOfflineChanges().listen(setNetworkOffline);
    _sessionSubscription = ApiClient.sessionExpired.listen((_) {
      if (kE2E) writePreference(_e2eSessionKey, null);
      _clearSessionAndSiteData();
      _isAuthenticated = false;
      _authMessage = 'Session expired. Please sign in again.';
      notifyListeners();
    });
    _passwordChangeSubscription = ApiClient.passwordChangeRequired.listen((_) {
      if (!_isAuthenticated || _userSession.mustChangePassword) return;
      _userSession = _userSession.copyWith(mustChangePassword: true);
      _authMessage = AppStrings.localizedErrorMessage('PASSWORD_CHANGE_REQUIRED');
      notifyListeners();
    });
    _initData();
  }

  StreamSubscription<bool>? _offlineSubscription;
  StreamSubscription<void>? _sessionSubscription;
  StreamSubscription<void>? _passwordChangeSubscription;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _googleSignInSubscription;

  @override
  void dispose() {
    _offlineSubscription?.cancel();
    _sessionSubscription?.cancel();
    _passwordChangeSubscription?.cancel();
    _googleSignInSubscription?.cancel();
    super.dispose();
  }

  Future<void> prepareGoogleSignIn() {
    if (_googleClientId.isEmpty) {
      // Called from build(): cache the failure and never notify here, or every
      // rebuild would schedule another notify and the login screen would spin.
      return _googleSignInInitialization ??=
          Future<void>.error(StateError('Google sign-in client ID is not configured.'));
    }
    return _googleSignInInitialization ??= GoogleSignIn.instance.initialize(
      clientId: _googleClientId,
    ).then((_) {
      _googleSignInSubscription ??= GoogleSignIn.instance.authenticationEvents.listen(
        (event) {
          if (kIsWeb && event is GoogleSignInAuthenticationEventSignIn) {
            unawaited(_completeGoogleSignIn(event.user));
          }
        },
        onError: (Object error) {
          _authMessage = 'Google hesabıyla giriş yapılamadı. Tekrar deneyin.';
          notify();
        },
      );
    });
  }

  Future<void> _completeGoogleSignIn(GoogleSignInAccount account) async {
    final idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      _authMessage = 'Google hesabından kimlik doğrulama bilgisi alınamadı.';
      notify();
      return;
    }
    try {
      final response = await ApiClient.post(
        ApiClient.uri('/api/v1/auth/google'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'id_token': idToken}),
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        _authMessage = extractErrorMessage(response, fallback: 'Google ile giriş yapılamadı.');
        notify();
        return;
      }
      final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final user = data['user'] as Map<String, dynamic>?;
      if (user == null) throw const FormatException('Missing server profile');
      final email = user['email']?.toString() ?? account.email;
      final role = UserRole.fromApi(user['role']);
      final siteId = user['site_id']?.toString() ?? '';
      final unitId = user['unit_id']?.toString() ?? '';
      final mustChangePassword = user['must_change_password'] == true;
      ApiClient.setSession(data);
      if (!mustChangePassword) {
        await _loadRoleData(role: role, email: email, siteId: siteId, unitId: unitId);
      }
      final permissions = (user['permissions'] as List<dynamic>? ?? const [])
          .map((permission) => PermissionScope(
                code: permission as String,
                title: permission,
                isGranted: true,
                isolationNote: 'Server-authorized scope',
              ))
          .toList(growable: false);
      _userSession = _createSession(
        role,
        AuthProvider.google,
        customName: user['full_name']?.toString() ?? account.displayName ?? email,
        customEmail: email,
        customPhone: user['phone']?.toString() ?? '',
        avatarUrl: user['avatar_url']?.toString() ?? account.photoUrl,
        mustChangePassword: mustChangePassword,
      ).copyWith(id: user['id']?.toString(), permissions: permissions);
      _isAuthenticated = true;
      _authMessage = 'Google hesabı ile giriş yapıldı.';
      notify();
    } catch (error) {
      ApiClient.clearSession();
      _isAuthenticated = false;
      _authMessage = 'Google ile giriş tamamlanamadı. Bağlantınızı kontrol edip tekrar deneyin.';
      notify();
    }
  }

  // Session & Auth
  bool _isAuthenticated;
  bool get isAuthenticated => _isAuthenticated;

  /// Signed in with a temporary password: every role must set a new password
  /// before it may see or do anything else (STORY-06-06). The router shows only
  /// the password change screen while this is true.
  bool get requiresPasswordChange => _isAuthenticated && _userSession.mustChangePassword;

  /// The site's owner/resident directory (`PERSON_READ`) is the site manager's.
  /// Other roles never request it: the server would refuse it with 403.
  bool get canReadSiteDirectory => _userSession.role == UserRole.siteManager;

  /// Household members of a unit (`UNIT_MANAGE_HOUSEHOLD` / `PERSON_MANAGE`):
  /// the owner and the site manager, not a resident or an auditor.
  bool get canManageHousehold =>
      _userSession.role == UserRole.homeOwner || _userSession.role == UserRole.siteManager;

  SiteAdminActivePath _siteAdminPath = SiteAdminActivePath.managerCockpit;
  SiteAdminActivePath get siteAdminPath => _siteAdminPath;

  late UserSession _userSession;
  UserSession get userSession => _userSession;
  UserRole get userRole => _userSession.role;

  String? _authMessage;
  String? get authMessage => _authMessage;
  String? _lastSiteRegistrationError;
  String? get lastSiteRegistrationError => _lastSiteRegistrationError;

  static const _e2eSessionKey = 'e2e_session';
  // Theme: follows the system until the user picks one; the choice is saved.
  static const themePreferenceKey = 'theme_mode';
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;
  Brightness _platformBrightness = PlatformDispatcher.instance.platformBrightness;
  bool get isDarkMode =>
      _themeMode == ThemeMode.dark || (_themeMode == ThemeMode.system && _platformBrightness == Brightness.dark);

  static ThemeMode _readSavedThemeMode() {
    return switch (readPreference(themePreferenceKey)) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
  }

  /// Called by the app shell when the OS switches between light and dark.
  void updatePlatformBrightness(Brightness brightness) {
    if (_platformBrightness == brightness) return;
    _platformBrightness = brightness;
    if (_themeMode == ThemeMode.system) notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    writePreference(themePreferenceKey, mode == ThemeMode.system ? null : mode.name);
    notifyListeners();
  }

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
  String get siteName => activeUnit.siteName.isNotEmpty
      ? activeUnit.siteName
      : (_currentManagedSite?.name ?? (_saasSites.isNotEmpty ? _saasSites.first.name : ''));

  List<DuesLiability> _duesList = [];
  List<DuesLiability> _managerDuesList = [];
  List<CapitalDuesSummary> _capitalDues = [];
  List<CapitalDuesSummary> get capitalDues => List.unmodifiable(_capitalDues);
  List<CapitalProjectItem> _residentCapitalProjects = [];
  List<CapitalProjectItem> get residentCapitalProjects => List.unmodifiable(_residentCapitalProjects);
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

  String _announcementTitle = 'Henüz site duyurusu yok';
  String _announcementContent = 'Yönetim bir duyuru paylaştığında burada görüntülenecek.';
  String get announcementTitle => _announcementTitle;
  String get announcementContent => _announcementContent;

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

  List<DuesPeriodItem> get duesPeriods => _duesPeriods;
  List<DuesPeriodItem> _duesPeriods = [];

  bool get canAccrueSelectedDuesPeriod {
    for (final period in _duesPeriods) {
      if (period.periodName == _selectedDuesMonth) {
        return period.periodStatus != DuesPeriodStatus.closed;
      }
    }
    // The backend enforces the status machine and answers repeat OPEN accruals idempotently.
    return true;
  }

  Future<void> fetchDuesPeriods() async {
    final siteId = _currentManagedSite?.id;
    if (siteId == null || siteId.isEmpty || isTestMode) return;
    try {
      final response = await ApiClient.get(ApiClient.uri(
        '/api/v1/dues/periods',
        {'site_id': siteId},
      )).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) {
        AppLogger.warn(
          'Period list request failed',
          tag: 'DuesPeriods',
          context: {'status_code': response.statusCode},
        );
        return;
      }
      final rows = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
      _duesPeriods = rows
          .whereType<Map<String, dynamic>>()
          .map(DuesPeriodItem.fromJson)
          .toList();
      notifyListeners();
    } catch (error, stackTrace) {
      AppLogger.warn(
        'Period list request failed before receiving a response',
        tag: 'DuesPeriods',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> closeDuesPeriod(String periodId) async {
    try {
      await PaymentsPhase3Api.closeBillingPeriod(periodId);
      await fetchDuesPeriods();
      await fetchSiteManagerOverview(
        siteId: _currentManagedSite?.id,
        period: _selectedDuesMonth,
      );
      return true;
    } catch (error, stackTrace) {
      AppLogger.warn(
        'Billing period close request failed',
        tag: 'DuesPeriods',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<bool> requestDuesPeriodReopen(String periodId, String reason) async {
    try {
      await PaymentsPhase3Api.requestBillingPeriodReopen(periodId, reason);
      await fetchDuesPeriods();
      return true;
    } catch (error, stackTrace) {
      AppLogger.warn(
        'Billing period reopen request failed',
        tag: 'DuesPeriods',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

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

  bool _isRegisteringHomeOwner = false;
  /// True while a home owner registration is waiting for the server.
  bool get isRegisteringHomeOwner => _isRegisteringHomeOwner;
  String? _lastHomeOwnerError;
  /// The last registration failure, for the form to show next to its submit button.
  String? get lastHomeOwnerError => _lastHomeOwnerError;
  bool _homeOwnerUpdateNeedsStepUp = false;
  /// The last edit changed a login email and the server asked for a password check first.
  bool get homeOwnerUpdateNeedsStepUp => _homeOwnerUpdateNeedsStepUp;
  List<String> _pendingEmailChanges = const [];
  /// Login emails from the last edit that wait for confirmation from the new address.
  List<String> get pendingEmailChanges => _pendingEmailChanges;

  List<HomeOwnerItem> _homeOwners = [];
  List<HomeOwnerItem> get homeOwners => _homeOwners;

  final Map<String, List<OccupancyHistoryItem>> _localOccupancyHistory = {};
  Map<String, List<OccupancyHistoryItem>> get localOccupancyHistory => _localOccupancyHistory;

  bool _isLoadingHomeOwners = false;
  bool get isLoadingHomeOwners => _isLoadingHomeOwners;
  Object? _homeOwnersError;
  Object? get homeOwnersError => _homeOwnersError;

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

  List<BankCatalogEntry>? _bankCatalog;
  List<BankCatalogEntry> get bankCatalog => _bankCatalog ?? const [];

  // House Types & Dues Tariffs
  List<HouseTypeTariff> _houseTypes = [];
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
    await refreshHouseTypes(siteId: siteId);
  }

  /// Loads the site's house types and reports whether the server answered, so a
  /// caller that must not guess a tariff can refuse instead.
  Future<bool> refreshHouseTypes({String? siteId}) async {
    if (isTestMode) return true;
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '1';
    try {
      final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/house-types?site_id=$effectiveSiteId');
      final response = await ApiClient.get(url).timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        final list = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
        _houseTypes = list.map((item) => HouseTypeTariff.fromJson(item as Map<String, dynamic>)).toList();
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('fetchHouseTypes error: $e');
    }
    return false;
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
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/house-types?site_id=$effectiveSiteId');
        final response = await ApiClient.post(
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
    int maxHtId = 0;
    for (final ht in _houseTypes) {
      final parsed = int.tryParse(ht.id);
      if (parsed != null && parsed > maxHtId) {
        maxHtId = parsed;
      }
    }
    final nextId = existingIdx != -1
        ? _houseTypes[existingIdx].id
        : '${maxHtId > 0 ? maxHtId + 1 : _houseTypes.length + 1}';
    final newHt = HouseTypeTariff(
      id: nextId,
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
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/house-types/$id?site_id=$effectiveSiteId');
        await ApiClient.delete(url).timeout(const Duration(seconds: 4));
      } catch (e) {
        debugPrint('deleteHouseType error: $e');
      }
    }
    _houseTypes.removeWhere((h) => h.id == id);
    notifyListeners();
    return true;
  }

  // Site Blocks
  List<String> _blocks = [];
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
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/blocks?site_id=$effectiveSiteId');
        final response = await ApiClient.get(url).timeout(const Duration(seconds: 4));
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
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/blocks?site_id=$effectiveSiteId');
        final response = await ApiClient.post(
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

  /// Creates a block together with its units in one manager action (#285).
  ///
  /// Runs the two commands the backend exposes for site structure:
  /// `POST /api/v1/site-admin/blocks` and `POST /api/v1/site-admin/units`, then
  /// reloads the blocks and the unit directory so every screen shows the new
  /// units. When [monthlyDues] is given the tariff is checked against the
  /// site's existing types first: an existing type is reused only at the same
  /// amount, and a new type is created through
  /// `POST /api/v1/site-admin/house-types` (a unit can only point at a
  /// registered house type). This form never reprices another block's units.
  ///
  /// Returns `null` on success, or a Turkish message for the form to show. A
  /// refused or unreachable call never pretends the structure was created.
  Future<String?> createBlockWithUnits({
    required String blockName,
    required int startUnit,
    required int unitCount,
    int totalFloors = 10,
    String? houseType,
    Decimal? monthlyDues,
    String? siteId,
  }) async {
    final trimmedName = blockName.trim();
    final trimmedHouseType = houseType?.trim() ?? '';
    if (trimmedName.isEmpty) {
      return 'Blok adı girin.';
    }
    if (startUnit < 1) {
      return 'Başlangıç daire numarası 1 veya daha büyük olmalıdır.';
    }
    if (unitCount < 1 || unitCount > 500) {
      return 'Bir seferde 1 ile 500 arası daire eklenebilir.';
    }
    if (totalFloors < 1 || totalFloors > 100) {
      return 'Kat sayısı 1 ile 100 arasında olmalıdır.';
    }
    if (monthlyDues != null) {
      if (trimmedHouseType.isEmpty) {
        return 'Aidat tanımlamak için konut tipi girin.';
      }
      if (monthlyDues <= Decimal.zero) {
        return 'Aylık aidat sıfırdan büyük olmalıdır.';
      }
      if (monthlyDues.scale > 2) {
        return 'Aylık aidat en fazla 2 kuruş hanesi içerebilir.';
      }
    }

    final effectiveSiteId = siteId ??
        _currentManagedSite?.id ??
        (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '');
    if (effectiveSiteId.isEmpty) {
      return 'Yönetilen site bilgisi yüklenemedi. Sayfayı yenileyip tekrar deneyin.';
    }

    // A house type and its tariff are site-wide, so an existing type is reused
    // and never repriced from this form: the manager changes a tariff in
    // "Konut Tipleri & Tarifeler", which is the screen built for that.
    HouseTypeTariff? existingTariff;
    if (monthlyDues != null) {
      if (!isTestMode && !await refreshHouseTypes(siteId: effectiveSiteId)) {
        return 'Konut tipleri yüklenemedi; aidat tarifesi doğrulanmadığı için kayıt yapılmadı. Lütfen tekrar deneyin.';
      }
      final wantedName = trimmedHouseType.toLowerCase();
      for (final type in _houseTypes) {
        if (type.typeName.toLowerCase() == wantedName) {
          existingTariff = type;
          break;
        }
      }
      if (existingTariff != null && existingTariff.duesAmount != monthlyDues) {
        return "'${existingTariff.typeName}' konut tipi zaten ${formatTry(existingTariff.duesAmount)} aidatla tanımlı. "
            'Aynı konut tipine farklı aidat kaydedilemez; Konut Tipleri & Tarifeler ekranından güncelleyin '
            'veya yeni bir konut tipi adı girin.';
      }
    }
    final createsTariff = monthlyDues != null && existingTariff == null;
    // Reused types are sent by their registered spelling, so a manager typing
    // "flat" stores the same "Flat" the unit's house_type_id points at.
    final resolvedHouseType = existingTariff?.typeName ??
        (trimmedHouseType.isEmpty ? null : trimmedHouseType);

    if (isTestMode) {
      _addBlockWithUnitsLocally(
        siteId: effectiveSiteId,
        blockName: trimmedName,
        startUnit: startUnit,
        unitCount: unitCount,
        houseType: resolvedHouseType,
        monthlyDues: monthlyDues,
        createTariff: createsTariff,
      );
      notify();
      return null;
    }

    final headers = {'Content-Type': 'application/json'};
    try {
      final blockResponse = await ApiClient.post(
        Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/blocks?site_id=$effectiveSiteId'),
        headers: headers,
        body: json.encode({
          'block_name': trimmedName,
          'total_floors': totalFloors,
        }),
      ).timeout(const Duration(seconds: 10));
      ApiClient.decode(blockResponse);

      if (createsTariff) {
        final tariffResponse = await ApiClient.post(
          Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/house-types?site_id=$effectiveSiteId'),
          headers: headers,
          body: json.encode({
            'type_name': trimmedHouseType,
            'dues_amount': monthlyDues!.toString(),
            'description': 'Blok oluşturulurken tanımlandı',
          }),
        ).timeout(const Duration(seconds: 10));
        ApiClient.decode(tariffResponse);
      }

      final unitsResponse = await ApiClient.post(
        Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/units?site_id=$effectiveSiteId'),
        headers: headers,
        body: json.encode({
          'block_name': trimmedName,
          'start_unit': startUnit,
          'end_unit': startUnit + unitCount - 1,
          if (resolvedHouseType != null) 'house_type': resolvedHouseType,
        }),
      ).timeout(const Duration(seconds: 15));
      ApiClient.decode(unitsResponse);
    } on ApiException catch (e) {
      AppLogger.warn(
        'Block or unit create was refused',
        tag: 'Residents',
        context: {'status_code': e.statusCode, 'code': e.code},
      );
      // A failed unit call after a successful block call leaves the block in
      // place; reload it so the directory reflects what really exists.
      await _reloadStructure(effectiveSiteId, refreshTariffs: createsTariff);
      return e.statusCode >= 500
          ? 'Blok veya daireler oluşturulamadı. Lütfen tekrar deneyin. (Referans: ${e.traceId ?? '-'})'
          : AppStrings.localizedErrorMessage(e.code, fallback: e.message);
    } catch (e) {
      AppLogger.warn('Block or unit create did not reach the server: $e', tag: 'Residents');
      await _reloadStructure(effectiveSiteId, refreshTariffs: createsTariff);
      return 'Sunucuya ulaşılamadı. Blok veya daireler oluşturulmadı; bağlantınızı kontrol edip tekrar deneyin.';
    }

    await _reloadStructure(effectiveSiteId, refreshTariffs: createsTariff);
    return null;
  }

  Future<void> _reloadStructure(String siteId, {required bool refreshTariffs}) async {
    await fetchBlocks(siteId: siteId);
    if (refreshTariffs) {
      await fetchHouseTypes(siteId: siteId);
    }
    await fetchHomeOwners(siteId: siteId);
  }

  /// Offline simulation of the structure commands for widget tests.
  void _addBlockWithUnitsLocally({
    required String siteId,
    required String blockName,
    required int startUnit,
    required int unitCount,
    required String? houseType,
    required Decimal? monthlyDues,
    required bool createTariff,
  }) {
    final existingBlockIdx = _blocks.indexWhere((b) => b.toLowerCase() == blockName.toLowerCase());
    if (existingBlockIdx == -1) {
      _blocks.add(blockName);
    }
    if (createTariff && monthlyDues != null && houseType != null) {
      _houseTypes.add(HouseTypeTariff(
        id: '${_houseTypes.length + 1}',
        siteId: siteId,
        typeName: houseType,
        duesAmount: monthlyDues,
        description: 'Blok oluşturulurken tanımlandı',
      ));
    }
    final existingKeys = {
      for (final unit in _homeOwners) '${unit.block.toLowerCase().trim()}-${unit.unitNo}',
    };
    for (var offset = 0; offset < unitCount; offset++) {
      final unitNo = startUnit + offset;
      if (!existingKeys.add('${blockName.toLowerCase()}-$unitNo')) {
        continue;
      }
      _homeOwners.add(HomeOwnerItem(
        unitId: 'local-${blockName.toLowerCase()}-$unitNo',
        siteId: siteId,
        block: blockName,
        unitNo: unitNo,
        floor: ((unitNo - 1) ~/ 4) + 1,
        ownerFullName: '',
        email: '',
        phone: '',
        landShare: '1',
        monthlyDues: monthlyDues ?? Decimal.zero,
        houseType: houseType,
        isResident: false,
        mustChangePassword: false,
        createdAt: DateTime.now(),
        occupancyStatus: 'VACANT',
      ));
    }
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

    if (isTestMode) {
      _houseTypes = [
        HouseTypeTariff(id: '1', siteId: '1', typeName: '1+1', duesAmount: Decimal.parse('1000.00'), description: '1 Oda 1 Salon'),
        HouseTypeTariff(id: '2', siteId: '1', typeName: '2+1', duesAmount: Decimal.parse('1400.00'), description: '2 Oda 1 Salon'),
        HouseTypeTariff(id: '3', siteId: '1', typeName: '3+1', duesAmount: Decimal.parse('1800.00'), description: '3 Oda 1 Salon'),
        HouseTypeTariff(id: '4', siteId: '1', typeName: '4+1', duesAmount: Decimal.parse('2200.00'), description: '4 Oda 1 Salon'),
        HouseTypeTariff(id: '5', siteId: '1', typeName: 'Dublex', duesAmount: Decimal.parse('2500.00'), description: 'Çatı Dubleks / Bahçe Katı'),
      ];
      _blocks = ['A Blok', 'B Blok'];
    }

    if (_activeUnit.id.isNotEmpty) {
      fetchResidentDashboard();
    }
    if (_currentManagedSite?.id.isNotEmpty == true) {
      fetchReconciliationQueue();
    }
    if (!isTestMode) {
      _restoreE2ESession();
      if (!_isAuthenticated) {
        fetchSaasSites();
      }
    }
  }

  void _restoreE2ESession() {
    if (!kE2E || isTestMode) return;
    final raw = readPreference(_e2eSessionKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final data = json.decode(raw) as Map<String, dynamic>;
      final userData = data['user'] as Map<String, dynamic>?;
      if (userData == null || userData.isEmpty) return;
      final email = userData['email']?.toString().trim() ?? '';
      final role = UserRole.fromApi(userData['role']?.toString() ?? '');
      final siteId = userData['site_id']?.toString() ?? '';
      final unitId = userData['unit_id']?.toString() ?? '';
      final rawName = userData['full_name']?.toString().trim() ?? '';
      final fullName = rawName.isNotEmpty ? rawName : email;
      final phone = userData['phone']?.toString() ?? '';
      final mustChangePassword = userData['must_change_password'] == true;
      final permissions = (userData['permissions'] as List<dynamic>? ?? const [])
          .map(
            (p) => PermissionScope(
              code: p as String,
              title: p,
              isGranted: true,
              isolationNote: 'Server-authorized scope',
            ),
          )
          .toList(growable: false);
      ApiClient.setSession(data);
      _userSession = _createSession(
        role,
        AuthProvider.local,
        customName: fullName,
        customEmail: email,
        customPhone: phone,
        mustChangePassword: mustChangePassword,
      ).copyWith(id: userData['id']?.toString(), permissions: permissions);
      _isAuthenticated = true;
      if (!mustChangePassword) {
        unawaited(
          _loadRoleData(role: role, email: email, siteId: siteId, unitId: unitId)
              .then((_) => notify()),
        );
      }
    } catch (_) {
      writePreference(_e2eSessionKey, null);
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

  Future<bool> resetAllDemoData() async {
    if (!isTestMode) {
      try {
        final url = ApiClient.uri('/api/v1/system/reset-demo-data');
        await ApiClient.post(url).timeout(const Duration(seconds: 3));
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
      final url = ApiClient.uri('/api/v1/system/accrue-test-due');
      await ApiClient.post(url).timeout(const Duration(seconds: 3));
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
    if (isTestMode || canManageHousehold) fetchHouseholdMembers(effectiveUnitId);
    try {
      final url = ApiClient.uri('/api/v1/residents/$effectiveUnitId/dashboard');
      final response = await ApiClient.get(url).timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

        _capitalDues = (data['capital_dues'] as List<dynamic>? ?? const [])
            .map((item) => CapitalDuesSummary.fromJson(item as Map<String, dynamic>))
            .where((item) => item.outstandingBalance > Decimal.zero)
            .toList();

        if (_userSession.role == UserRole.homeResident) {
          unawaited(fetchResidentCapitalProjects(_activeUnit.siteId));
        }

        final viban = data['virtual_iban'] as String?;
        final advance = readDecimal(data, 'advance_payment');
        final totalDebt = readDecimal(data, 'total_debt');
        _announcementTitle = data['announcement_title'] as String? ?? _announcementTitle;
        _announcementContent = data['announcement_content'] as String? ?? _announcementContent;

        _activeUnit = _activeUnit.copyWith(
          virtualIban: viban ?? _activeUnit.virtualIban,
          advancePayment: advance,
        );

        final duesJson = data['dues'] as List<dynamic>?;
        if (duesJson != null && duesJson.isNotEmpty) {
          _duesList = duesJson.map((d) {
            final item = d as Map<String, dynamic>;
            final isItemPaid = item['status'] == 'PAID';
            final dueDate =
                DateTime.tryParse(item['due_date']?.toString() ?? '') ??
                    DateTime.now();
            final today = DateTime.now().toUtc();
            final daysOverdue = isItemPaid
                ? 0
                : (item['days_overdue'] as num?)?.toInt() ?? DateTime.utc(today.year, today.month, today.day)
                    .difference(
                      DateTime.utc(dueDate.year, dueDate.month, dueDate.day),
                    )
                    .inDays
                    .clamp(0, 1 << 31)
                    .toInt();
            return DuesLiability(
              id: item['id'] as String? ?? '',
              unitId: effectiveUnitId,
              period: item['period'] as String? ?? '',
              principalAmount: readDecimal(item, 'principal_amount'),
              delayPenalty: isItemPaid ? Decimal.zero : (readDecimal(item, 'delay_penalty')),
              totalAmount: isItemPaid ? Decimal.zero : (readDecimal(item, 'total_amount')),
              dueDate: dueDate,
              daysOverdue: daysOverdue,
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
    if (!isTestMode && _siteBankAccount == null) {
      unawaited(fetchBankAccount(effectiveSiteId));
    }
    try {
      final url = Uri.parse('${ApiClient.baseUrl}/api/v1/bank/statements/reconciliation-queue?site_id=$effectiveSiteId');
      final response = await ApiClient.get(url).timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final list = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>?;
        if (list != null) {
          final liveItems = list.map((item) => ReconciliationQueueItem.fromJson(item as Map<String, dynamic>)).toList();
          if (!isTestMode) {
            final localUnmatched = _reconciliationQueue
                .where((item) => item.status == 'ESLESTIRILEMEDI')
                .toList();
            _reconciliationQueue = liveItems;
            for (final item in localUnmatched) {
              final exists = _reconciliationQueue.any((liveItem) =>
                  liveItem.matchId == item.matchId ||
                  liveItem.transaction.transactionId == item.transaction.transactionId);
              if (!exists) _reconciliationQueue.add(item);
            }
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
    // SITE_MANAGE is the site manager's; an auditor or resident would only get 403.
    if (isTestMode || _userSession.role != UserRole.siteManager) return;
    try {
      final queryParams = <String, String>{};
      if (siteId != null && siteId.isNotEmpty) {
        queryParams['site_id'] = siteId;
      }
      if (period != null && period.isNotEmpty) {
        queryParams['period'] = period;
      }

      final uri = ApiClient.uri('/api/v1/site-admin/overview', queryParams);
      final response = await ApiClient.get(uri).timeout(const Duration(seconds: 2));

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
          monthlyCollectionVolume: readDecimal(summaryJson, 'total_expected'),
          adminName: managerName,
          adminEmail: managerEmail,
          adminPhone: '',
          actionCount: 0,
        );

        await fetchPendingRegistrations(siteId: fetchedSiteId);

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
            final adv = readDecimal(item, 'advance_balance');
            totalAdvanceFromFlats += adv;
            list.add(FlatPaymentStatus(
              id: item['id'] as String? ?? '',
              block: item['block'] as String? ?? '',
              unitNo: u,
              residentName: item['resident_name'] as String? ?? '',
              amountDue: readDecimal(item, 'amount_due'),
              advanceBalance: adv,
              daysOverdue: (item['days_overdue'] as num?)?.toInt() ?? 0,
              isPaid: item['is_paid'] as bool? ?? false,
              paidDateStr: item['paid_date_str'] as String?,
              houseType: item['house_type'] as String?,
              registeredPayerNames:
                  (item['registered_payer_names'] as List<dynamic>?)
                      ?.map((name) => name.toString())
                      .toList() ??
                  const [],
            ));
          }
          _flatsList = list;
          _monthlyFlats[_selectedDuesMonth] = List.from(_flatsList);
        }

        if (summaryJson != null) {
          final backendAdvance = readDecimal(summaryJson, 'total_advance_balance');
          final effectiveAdvance = backendAdvance > Decimal.zero ? backendAdvance : totalAdvanceFromFlats;
          _collectionSummary = ComplexCollectionSummary(
            totalExpected: readDecimal(summaryJson, 'total_expected'),
            totalCollected: readDecimal(summaryJson, 'total_collected'),
            totalOverdueWithInterest: readDecimal(summaryJson, 'total_overdue_with_interest'),
            totalAdvanceBalance: effectiveAdvance,
            paidUnitsCount: (summaryJson['paid_units_count'] as num?)?.toInt() ?? 0,
            overdueUnitsCount: (summaryJson['overdue_units_count'] as num?)?.toInt() ?? 0,
            totalUnitsCount: totalUnitsCount,
          );
        }

        if (fetchedSiteId.isNotEmpty) {
          await fetchBankAccount(fetchedSiteId);
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
      final url = ApiClient.uri('/api/v1/saas/sites');
      final response = await ApiClient.get(url).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(utf8.decode(response.bodyBytes));
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
            monthlyCollectionVolume: readDecimal(item, 'monthly_dues_volume'),
            adminName: item['primary_manager_name'] as String? ?? 'Yönetici Atanmadı',
            adminEmail: item['primary_manager_email'] as String? ?? '',
            adminPhone: item['primary_manager_phone'] as String? ?? '',
            actionCount: (item['total_units'] as num?)?.toInt() ?? 0,
            blocks: blocks,
          );
        }).toList();
        _managedSitesList = List.from(_saasSites);
        if (_currentManagedSite == null && _saasSites.isNotEmpty) {
          _currentManagedSite = _saasSites.first;
        }
        notifyListeners();
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
    final url = ApiClient.uri('/api/v1/dues/accrue-period');
    // No amount: the server charges each unit its operating-budget share, else
    // its house-type tariff. A typed amount is only sent when the caller has one.
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
            amountDue: amount ?? f.amountDue,
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
        'total_amount_accrued':
            _flatsList.fold<Decimal>(Decimal.zero, (sum, f) => sum + f.amountDue),
        'total_amount_offset_from_advance': Decimal.zero,
        'already_accrued': false,
        'message': "'$period' dönemi için aidat tahakkuk ettirildi.",
      };
    }

    try {
      final response = await ApiClient.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'site_id': effectiveSiteId,
          'period': period,
          if (amount != null) 'amount': amount.toString(),
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
        // The flats and the summary of the period come from the overview just
        // fetched: each unit shows the amount the server actually charged it.

        notifyListeners();
        return data;
      } else {
        final errText = utf8.decode(response.bodyBytes, allowMalformed: true);
        return {
          'success': false,
          'error': 'Dönem aidatı tahakkuk ettirilemedi: ${response.statusCode} - $errText',
          'message': 'İşlem başarısız: Sunucu ${response.statusCode} döndürdü.',
        };
      }
    } catch (e) {
      debugPrint('accrueMonthlyDues remote error: $e');
      return {
        'success': false,
        'error': 'Dönem aidatı tahakkuk ettirilemedi: $e',
        'message': 'Sunucu bağlantı hatası: $e',
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
    final url = ApiClient.uri('/api/v1/dues/periods');
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
      final response = await ApiClient.post(
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

  /// Switches to the opposite of what is shown now and saves the choice.
  void toggleTheme() => setThemeMode(isDarkMode ? ThemeMode.light : ThemeMode.dark);

  /// Real connectivity change reported by the platform (browser online/offline events).
  void setNetworkOffline(bool offline) {
    if (_isOffline == offline) return;
    toggleOfflineMode(offline);
  }

  /// Developer simulation of an offline session (dev tools only).
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
    if (!isTestMode) return;
    _userSession = _createSession(role, provider ?? _userSession.authProvider);
    if (role == UserRole.siteManager && adminPath != null) {
      _siteAdminPath = adminPath;
    }
    if (role == UserRole.saasAdmin) {
      fetchSaasSites();
    } else if (role == UserRole.siteManager) {
      if (_currentManagedSite == null) {
        attachCurrentManagedSiteForUser(email: _userSession.email);
      }
      fetchSiteManagerOverview(siteId: _currentManagedSite?.id, period: _selectedDuesMonth);
    } else if (role == UserRole.homeOwner || role == UserRole.homeResident) {
      if (_activeUnit.id.isEmpty) {
        attachActiveUnitForUser(email: _userSession.email);
      }
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

  // Payment Tracking & Unified Treasury Streams (STORY-09-01 .. STORY-09-07)
  PaymentStreamResponseDto? _paymentStream;
  PaymentStreamResponseDto? get paymentStream => _paymentStream;
  Object? _paymentStreamError;
  Object? get paymentStreamError => _paymentStreamError;

  DebtAgingReportDto? _debtAgingReport;
  DebtAgingReportDto? get debtAgingReport => _debtAgingReport;
  Object? _debtAgingError;
  Object? get debtAgingError => _debtAgingError;
  bool _isDebtAgingLoading = false;
  bool get isDebtAgingLoading => _isDebtAgingLoading;

  PaymentReceiptDto? _selectedReceipt;
  PaymentReceiptDto? get selectedReceipt => _selectedReceipt;

  bool _isPaymentStreamLoading = false;
  bool get isPaymentStreamLoading => _isPaymentStreamLoading;

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

}
