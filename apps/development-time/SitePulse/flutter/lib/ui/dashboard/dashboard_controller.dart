import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';
import '../../domain/models/auth_models.dart';
import '../../domain/models/dues_models.dart';
import '../../domain/usecases/calculate_dues_usecase.dart';

class DashboardController extends ChangeNotifier {
  final CalculateDuesUseCase _calculateDuesUseCase;

  DashboardController({CalculateDuesUseCase? calculateDuesUseCase})
      : _calculateDuesUseCase = calculateDuesUseCase ?? CalculateDuesUseCase() {
    _initData();
  }

  // Session & Auth
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
  ApartmentUnit get activeUnit => _activeUnit;
  ApartmentUnit get activeDaire => _activeUnit;

  List<DuesLiability> _duesList = [];
  List<DuesLiability> get duesList => _duesList;
  DuesLiability? get primaryDues => _duesList.isNotEmpty ? _duesList.first : null;

  List<UnitResidentMember> _unitResidents = [];
  List<UnitResidentMember> get unitResidents => _unitResidents;

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

  void _initData() {
    _userSession = _createSession(UserRole.homeOwner, AuthProvider.local);

    _activeUnit = const ApartmentUnit(
      id: 'd-14',
      siteName: 'Begonya Sitesi',
      block: 'A',
      unitNo: 14,
      floor: 4,
      landShare: 24,
      ownerName: 'Ahmet Yılmaz',
      tenantName: 'Zeynep Kaya',
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

    _collectionSummary = ComplexCollectionSummary();

    _flatsList = [
      FlatPaymentStatus(id: '1', block: 'A', unitNo: 14, residentName: 'Ahmet Yılmaz', amountDue: Decimal.parse('1423.33'), daysOverdue: 10, isPaid: false),
      FlatPaymentStatus(id: '2', block: 'A', unitNo: 15, residentName: 'Fatma Kaya', amountDue: Decimal.parse('1411.67'), daysOverdue: 5, isPaid: false),
      FlatPaymentStatus(id: '3', block: 'B', unitNo: 3, residentName: 'Mehmet Öz', amountDue: Decimal.parse('1404.67'), daysOverdue: 2, isPaid: false),
      FlatPaymentStatus(id: '4', block: 'A', unitNo: 1, residentName: 'Selim Ak', amountDue: Decimal.parse('1400.00'), daysOverdue: 0, isPaid: true, paidDateStr: '12 Eyl'),
      FlatPaymentStatus(id: '5', block: 'B', unitNo: 7, residentName: 'Canan Ece', amountDue: Decimal.parse('1400.00'), daysOverdue: 0, isPaid: true, paidDateStr: '14 Eyl'),
      FlatPaymentStatus(id: '6', block: 'A', unitNo: 2, residentName: 'Ali Demir', amountDue: Decimal.parse('1400.00'), daysOverdue: 0, isPaid: true, paidDateStr: '10 Eyl'),
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

  void switchSessionRole(UserRole role) {
    _userSession = _createSession(role, _userSession.authProvider);
    notifyListeners();
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
