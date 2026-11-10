part of 'dashboard_controller.dart';

/// Authentication, user sessions, credentials and site lifecycle management.
extension DashboardControllerAuth on DashboardController {
  void loginAs({
    required UserRole role,
    SiteAdminActivePath? adminPath,
    AuthProvider provider = AuthProvider.local,
  }) {
    if (!isTestMode) return;
    switchSessionRole(role, provider: provider, adminPath: adminPath);
    _isAuthenticated = true;
    _authMessage = '${role.displayName} olarak giriş yapıldı.';
    if (role == UserRole.saasAdmin) {
      fetchSaasSites();
    }
    notify();
  }

  void logout() {
    unawaited(ApiClient.logout());
    _userSession = _userSession.copyWith(permissions: const []);
    _isAuthenticated = false;
    _authMessage = null;
    _provisionedCredentials = null;
    _provisionedHomeOwner = null;
    _clearSessionAndSiteData();
    notify();
  }

  void _clearSessionAndSiteData() {
    _activeUnit = ApartmentUnit.empty;
    _managerUnit = ApartmentUnit.empty;
    _duesList = [];
    _managerDuesList = [];
    _flatsList = [];
    _monthlyFlats.clear();
    _availableDuesMonths.clear();
    _selectedDuesMonth = '';
    _pendingRegistrations = [];
    _reconciliationQueue = [];
    _accountTransactions = [];
    _unitResidents = [];
    _managerResidents = [];
    _unitInviteInfo = null;
    _collectionSummary = ComplexCollectionSummary.zero();
    _homeOwners = [];
    _siteBankAccount = null;
    _currentManagedSite = null;
    _managedSitesList = [];
    _capitalProjects = [];
    _activeCapitalProject = null;
    _capitalInstallments = [];
    _capitalDisbursements = [];
    _unitCapitalShares = [];
    _selectedReceipt = null;
    _userSession = _createSession(UserRole.homeOwner, AuthProvider.local);
  }

  void clearAllLoginCache() {
    _provisionedCredentials = null;
    _provisionedHomeOwner = null;
    _authMessage = null;
    notify();
  }

  void setSiteAdminPath(SiteAdminActivePath path) {
    _siteAdminPath = path;
    notify();
  }

  void toggleSiteAdminPath() {
    if (_siteAdminPath == SiteAdminActivePath.managerCockpit) {
      setSiteAdminPath(SiteAdminActivePath.myFlatOwner);
    } else {
      setSiteAdminPath(SiteAdminActivePath.managerCockpit);
    }
  }

  void attachActiveUnitForUser({required String email, String? siteId, String? unitId}) {
    _activeUnit = ApartmentUnit.empty;
    // 1. If unitId is explicitly provided
    if (unitId != null && unitId.isNotEmpty) {
      final ho = _homeOwners.cast<HomeOwnerItem?>().firstWhere(
        (h) => h?.unitId == unitId || h?.unitNo.toString() == unitId,
        orElse: () => null,
      );
      if (ho != null) {
        _activeUnit = ApartmentUnit(
          id: ho.unitId.isNotEmpty ? ho.unitId : 'unit-${ho.unitNo}',
          siteId: siteId ?? _currentManagedSite?.id ?? '',
          siteName: _currentManagedSite?.name ?? 'Sitemiz',
          block: ho.block,
          unitNo: ho.unitNo,
          floor: ((ho.unitNo - 1) ~/ 4) + 1,
          landShare: 1,
          ownerName: ho.ownerFullName,
          tenantName: ho.tenantFullName ?? '',
          virtualIban: ho.virtualIban,
          advancePayment: Decimal.zero,
        );
        fetchResidentDashboard(_activeUnit.id);
        return;
      }
      final flat = _flatsList.cast<FlatPaymentStatus?>().firstWhere(
        (f) => f?.id == unitId || f?.unitNo.toString() == unitId,
        orElse: () => null,
      );
      if (flat != null) {
        _activeUnit = ApartmentUnit(
          id: flat.id,
          siteId: siteId ?? _currentManagedSite?.id ?? '',
          siteName: _currentManagedSite?.name ?? 'Sitemiz',
          block: flat.block,
          unitNo: flat.unitNo,
          floor: ((flat.unitNo - 1) ~/ 4) + 1,
          landShare: 1,
          ownerName: flat.residentName,
          tenantName: '',
          virtualIban: 'TR91 0020 5000 0986 3791 6000 01',
          advancePayment: Decimal.zero,
        );
        fetchResidentDashboard(_activeUnit.id);
        return;
      }
      _activeUnit = ApartmentUnit(
        id: unitId,
        siteId: siteId ?? _currentManagedSite?.id ?? '',
        siteName: _currentManagedSite?.name ?? 'Sitemiz',
        block: 'A Blok',
        unitNo: int.tryParse(unitId.replaceAll(RegExp(r'[^0-9]'), '')) ?? 1,
        floor: 1,
        landShare: 1,
        ownerName: email,
        tenantName: '',
        virtualIban: 'TR91 0020 5000 0986 3791 6000 01',
        advancePayment: Decimal.zero,
      );
      fetchResidentDashboard(_activeUnit.id);
      return;
    }

    // 2. Match by email in _homeOwners
    final ho = _homeOwners.cast<HomeOwnerItem?>().firstWhere(
      (h) => h?.email.toLowerCase() == email.toLowerCase() || h?.tenantEmail?.toLowerCase() == email.toLowerCase(),
      orElse: () => null,
    );
    if (ho != null) {
      _activeUnit = ApartmentUnit(
        id: ho.unitId.isNotEmpty ? ho.unitId : 'unit-${ho.unitNo}',
        siteId: siteId ?? _currentManagedSite?.id ?? '',
        siteName: _currentManagedSite?.name ?? 'Sitemiz',
        block: ho.block,
        unitNo: ho.unitNo,
        floor: ((ho.unitNo - 1) ~/ 4) + 1,
        landShare: 1,
        ownerName: ho.ownerFullName,
        tenantName: ho.tenantFullName ?? '',
        virtualIban: ho.virtualIban,
        advancePayment: Decimal.zero,
      );
      fetchResidentDashboard(_activeUnit.id);
      return;
    }

    // 3. Match by provisioned homeowner
    if (_provisionedHomeOwner != null && _provisionedHomeOwner!.email.toLowerCase() == email.toLowerCase()) {
      _activeUnit = ApartmentUnit(
        id: 'unit-${_provisionedHomeOwner!.unitNo}',
        siteId: siteId ?? _currentManagedSite?.id ?? '',
        siteName: _currentManagedSite?.name ?? 'Sitemiz',
        block: _provisionedHomeOwner!.block,
        unitNo: _provisionedHomeOwner!.unitNo,
        floor: ((_provisionedHomeOwner!.unitNo - 1) ~/ 4) + 1,
        landShare: 1,
        ownerName: _provisionedHomeOwner!.ownerName,
        tenantName: '',
        virtualIban: 'TR91 0020 5000 0986 3791 6000 01',
        advancePayment: Decimal.zero,
      );
      fetchResidentDashboard(_activeUnit.id);
      return;
    }

    // 4. Match by flatsList
    if (_flatsList.isNotEmpty) {
      final f = _flatsList.cast<FlatPaymentStatus?>().firstWhere(
        (flat) => flat?.residentName.toLowerCase() == email.toLowerCase(),
        orElse: () => null,
      );
      if (f != null) {
        _activeUnit = ApartmentUnit(
          id: f.id,
          siteId: siteId ?? _currentManagedSite?.id ?? '',
          siteName: _currentManagedSite?.name ?? 'Sitemiz',
          block: f.block,
          unitNo: f.unitNo,
          floor: ((f.unitNo - 1) ~/ 4) + 1,
          landShare: 1,
          ownerName: f.residentName,
          tenantName: '',
          virtualIban: 'TR91 0020 5000 0986 3791 6000 01',
          advancePayment: Decimal.zero,
        );
        fetchResidentDashboard(_activeUnit.id);
        return;
      }
    }

    _activeUnit = ApartmentUnit.empty;

    // 5. If no units matched, fetch overview to check remote
    if (!isTestMode) {
      fetchSiteManagerOverview(siteId: siteId).then((_) {
        if (_flatsList.isNotEmpty && _activeUnit.id.isEmpty) {
          final f = _flatsList.cast<FlatPaymentStatus?>().firstWhere(
            (flat) => flat?.residentName.toLowerCase() == email.toLowerCase(),
            orElse: () => null,
          );
          if (f != null) {
            _activeUnit = ApartmentUnit(
              id: f.id,
              siteId: siteId ?? _currentManagedSite?.id ?? '',
              siteName: _currentManagedSite?.name ?? 'Sitemiz',
              block: f.block,
              unitNo: f.unitNo,
              floor: ((f.unitNo - 1) ~/ 4) + 1,
              landShare: 1,
              ownerName: f.residentName,
              tenantName: '',
              virtualIban: 'TR91 0020 5000 0986 3791 6000 01',
              advancePayment: Decimal.zero,
            );
            fetchResidentDashboard(_activeUnit.id);
            notify();
          }
        }
      });
    }
  }

  void attachCurrentManagedSiteForUser({required String email, String? siteId}) {
    if (siteId != null && siteId.isNotEmpty) {
      final s = _saasSites.cast<TenantSiteItem?>().firstWhere(
        (site) => site?.id == siteId,
        orElse: () => null,
      );
      if (s != null) {
        _currentManagedSite = s;
        return;
      }
    }
    final s = _saasSites.cast<TenantSiteItem?>().firstWhere(
      (site) => site?.adminEmail.toLowerCase() == email.toLowerCase(),
      orElse: () => null,
    );
    if (s != null) {
      _currentManagedSite = s;
      return;
    }
    if (_provisionedCredentials != null && _provisionedCredentials!.adminEmail.toLowerCase() == email.toLowerCase()) {
      _currentManagedSite = TenantSiteItem(
        id: _provisionedCredentials!.siteId,
        name: _provisionedCredentials!.siteName,
        city: 'İstanbul',
        address: '',
        status: 'ACTIVE',
        planType: _provisionedCredentials!.planType,
        totalUnits: 0,
        monthlyCollectionVolume: Decimal.zero,
        adminName: _provisionedCredentials!.adminName,
        adminEmail: _provisionedCredentials!.adminEmail,
        adminPhone: '',
        actionCount: 0,
      );
      return;
    }
    if (_saasSites.isNotEmpty) {
      _currentManagedSite = _saasSites.first;
    }
  }

  void loginAsHomeOwner(HomeOwnerItem owner) {
    if (!isTestMode) return;
    _activeUnit = ApartmentUnit(
      id: owner.unitId.isNotEmpty ? owner.unitId : 'unit-${owner.unitNo}',
      siteId: _currentManagedSite?.id ?? '',
      siteName: _currentManagedSite?.name ?? 'Sitemiz',
      block: owner.block,
      unitNo: owner.unitNo,
      floor: ((owner.unitNo - 1) ~/ 4) + 1,
      landShare: 1,
      ownerName: owner.ownerFullName,
      tenantName: owner.tenantFullName ?? '',
      virtualIban: owner.virtualIban,
      advancePayment: Decimal.zero,
    );
    _userSession = _createSession(
      UserRole.homeOwner,
      AuthProvider.local,
      customName: owner.ownerFullName,
      customEmail: owner.email,
      customPhone: owner.phone,
    );
    _isAuthenticated = true;
    _authMessage = '${owner.ownerFullName} (${owner.block} D:${owner.unitNo}) olarak giriş yapıldı.';
    fetchResidentDashboard(_activeUnit.id);
    notify();
  }

  void loginAsProvisionedHomeOwner() {
    if (!isTestMode) return;
    if (_provisionedHomeOwner == null) return;
    final p = _provisionedHomeOwner!;
    _activeUnit = ApartmentUnit(
      id: 'unit-${p.unitNo}',
      siteId: _currentManagedSite?.id ?? '',
      siteName: _currentManagedSite?.name ?? 'Sitemiz',
      block: p.block,
      unitNo: p.unitNo,
      floor: ((p.unitNo - 1) ~/ 4) + 1,
      landShare: 1,
      ownerName: p.ownerName,
      tenantName: '',
      virtualIban: 'TR91 0020 5000 0986 3791 6000 01',
      advancePayment: Decimal.zero,
    );
    _userSession = _createSession(
      UserRole.homeOwner,
      AuthProvider.local,
      customName: p.ownerName,
      customEmail: p.email,
      customPhone: p.phone,
    );
    _isAuthenticated = true;
    _authMessage = '${p.ownerName} (${p.block} D:${p.unitNo}) olarak giriş yapıldı.';
    fetchResidentDashboard(_activeUnit.id);
    notify();
  }

  void loginAsSiteManager(TenantSiteItem site, {SiteAdminActivePath? adminPath}) {
    if (!isTestMode) return;
    _currentManagedSite = site;
    if (adminPath != null) {
      _siteAdminPath = adminPath;
    }
    _userSession = _createSession(
      UserRole.siteManager,
      AuthProvider.local,
      customName: site.adminName,
      customEmail: site.adminEmail,
      customPhone: site.adminPhone,
    );
    _isAuthenticated = true;
    _authMessage = '${site.name} Yöneticisi (${site.adminName}) olarak giriş yapıldı.';
    fetchSiteManagerOverview(siteId: site.id, period: _selectedDuesMonth);
    notify();
  }

  void loginAsProvisionedSiteManager({SiteAdminActivePath? adminPath}) {
    if (!isTestMode) return;
    if (_provisionedCredentials == null) return;
    final p = _provisionedCredentials!;
    final site = TenantSiteItem(
      id: p.siteId,
      name: p.siteName,
      city: 'İstanbul',
      address: '',
      status: 'ACTIVE',
      planType: p.planType,
      totalUnits: 0,
      monthlyCollectionVolume: Decimal.zero,
      adminName: p.adminName,
      adminEmail: p.adminEmail,
      adminPhone: '',
      actionCount: 0,
    );
    loginAsSiteManager(site, adminPath: adminPath);
  }

  Future<bool> loginWithPassword(
    String email,
    String password, {
    UserRole? targetRole,
    SiteAdminActivePath? adminPath,
  }) async {
    if (email.trim().isEmpty || password.trim().isEmpty) {
      _authMessage = 'E-posta ve şifre zorunludur.';
      notify();
      return false;
    }

    final trimmedEmail = email.trim();
    final trimmedPass = password.trim();

    // 1. Try remote authentication if not test mode
    if (!isTestMode) {
      try {
        final url = ApiClient.uri('/api/v1/auth/login');
        final response = await ApiClient.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'email': trimmedEmail,
            'password': trimmedPass,
          }),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200) {
          final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          final userData = data['user'] as Map<String, dynamic>?;
          if (userData == null) {
            throw const FormatException('Missing server profile');
          }
          if (userData.isNotEmpty) {
            final roleStr = userData['role']?.toString() ?? '';
            final siteId = userData['site_id']?.toString() ?? '';
            final unitId = userData['unit_id']?.toString() ?? '';
            final rawName = userData['full_name']?.toString().trim() ?? '';
            final fullName = rawName.isNotEmpty ? rawName : trimmedEmail;
            final phone = userData['phone']?.toString() ?? '';

            final resolvedRole = UserRole.fromApi(roleStr);
            final serverPermissions = (userData['permissions'] as List<dynamic>? ?? const [])
                .map((p) => PermissionScope(code: p as String, title: p, isGranted: true,
                    isolationNote: 'Server-authorized scope')).toList(growable: false);
            ApiClient.setSession(data);

            if (adminPath != null) {
              _siteAdminPath = adminPath;
            }

            final mustChange = userData['must_change_password'] == true;
            if (!mustChange && resolvedRole == UserRole.saasAdmin) {
              await fetchSaasSites();
            } else if (!mustChange && resolvedRole == UserRole.siteManager) {
              attachCurrentManagedSiteForUser(email: trimmedEmail, siteId: siteId);
              await fetchSiteManagerOverview(siteId: siteId.isNotEmpty ? siteId : _currentManagedSite?.id, period: _selectedDuesMonth);
            } else if (!mustChange) {
              attachActiveUnitForUser(email: trimmedEmail, siteId: siteId, unitId: unitId);
            }

            final mustChangePassword = userData['must_change_password'] == true;

            _userSession = _createSession(
              resolvedRole,
              AuthProvider.local,
              customName: fullName,
              customEmail: trimmedEmail,
              customPhone: phone,
              mustChangePassword: mustChangePassword,
            ).copyWith(id: userData['id']?.toString(), permissions: serverPermissions);
            _isAuthenticated = true;
            _authMessage = 'Şifre ile başarıyla giriş yapıldı (${resolvedRole.displayName}).';
            notify();
            return true;
          }
          throw const FormatException('Missing server profile');
        } else if (response.statusCode == 401 || response.statusCode == 400) {
          final errorBody = utf8.decode(response.bodyBytes);
          if (errorBody.contains('Invalid email or password') || errorBody.contains('kullanıcı adı veya şifre hatalı')) {
            _authMessage = 'Hatalı e-posta veya şifre. Lütfen girdiğiniz bilgileri kontrol edin.';
          } else {
            _authMessage = errorBody.isNotEmpty ? errorBody : 'E-posta veya şifre hatalı.';
          }
          notify();
          return false;
        } else {
          _authMessage = 'Giriş yapılamadı (Sunucu yanıt kodu: ${response.statusCode}).';
          notify();
          return false;
        }
      } catch (e) {
        ApiClient.clearSession();
        _isAuthenticated = false;
        debugPrint('loginWithPassword backend call error: $e');
        _authMessage = 'Sunucuya bağlanılamadı. Lütfen arka uç servisinin (port 8080) çalıştığından emin olun.';
        notify();
        return false;
      }
    }

    // 2. Local / Test Mode / Offline resolution
    if (_provisionedCredentials != null && _provisionedCredentials!.adminEmail.toLowerCase() == trimmedEmail.toLowerCase()) {
      loginAsProvisionedSiteManager(adminPath: adminPath);
      return true;
    }

    if (_provisionedHomeOwner != null && _provisionedHomeOwner!.email.toLowerCase() == trimmedEmail.toLowerCase()) {
      loginAsProvisionedHomeOwner();
      return true;
    }

    final matchedSite = _saasSites.cast<TenantSiteItem?>().firstWhere(
      (s) => s?.adminEmail.toLowerCase() == trimmedEmail.toLowerCase(),
      orElse: () => null,
    );
    if (matchedSite != null) {
      loginAsSiteManager(matchedSite, adminPath: adminPath);
      return true;
    }

    final matchedHo = _homeOwners.cast<HomeOwnerItem?>().firstWhere(
      (h) => h?.email.toLowerCase() == trimmedEmail.toLowerCase() || h?.tenantEmail?.toLowerCase() == trimmedEmail.toLowerCase(),
      orElse: () => null,
    );
    if (matchedHo != null) {
      loginAsHomeOwner(matchedHo);
      return true;
    }

    final role = targetRole ?? (trimmedEmail.contains('admin')
        ? UserRole.saasAdmin
        : (trimmedEmail.contains('yonetim') || trimmedEmail.contains('manager') || trimmedEmail.contains('mehmet'))
            ? UserRole.siteManager
            : (trimmedEmail.contains('sakin') || trimmedEmail.contains('zeynep'))
                ? UserRole.homeResident
                : UserRole.homeOwner);

    if (adminPath != null) {
      _siteAdminPath = adminPath;
    }

    if (role == UserRole.saasAdmin) {
      fetchSaasSites();
    } else if (role == UserRole.siteManager) {
      attachCurrentManagedSiteForUser(email: trimmedEmail);
      fetchSiteManagerOverview(siteId: _currentManagedSite?.id, period: _selectedDuesMonth);
    } else {
      attachActiveUnitForUser(email: trimmedEmail);
    }

    _userSession = _createSession(role, AuthProvider.local, customEmail: trimmedEmail);
    _isAuthenticated = true;
    _authMessage = 'Şifre ile başarıyla giriş yapıldı (${role.displayName}).';
    notify();
    return true;
  }

  void loginWithGoogle() {
    if (!isTestMode) {
      _authMessage = 'Use the configured Google identity sign-in flow.';
      notify();
      return;
    }
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
    notify();
  }

  Future<bool> registerNewSite({
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
    final tempPassword = 'SP-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}-PASS';

    if (!isTestMode) {
      try {
        final url = ApiClient.uri('/api/v1/saas/sites');
        final response = await ApiClient.post(
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
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200 || response.statusCode == 201) {
          final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          final createdSiteId = (data['site_id'] ?? data['id'])?.toString() ?? '${_saasSites.length + 1}';
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
          _saasSites = [newSite, ..._saasSites.where((s) => s.id != createdSiteId)];
          _managedSitesList = List.from(_saasSites);
          _provisionedCredentials = ProvisionedSiteCredentials(
            siteId: createdSiteId,
            siteName: name,
            adminName: adminName,
            adminEmail: adminEmail,
            temporaryPassword: createdPassword,
            planType: planType,
          );
          _authMessage = '$name sitesi başarıyla kaydedildi.';
          notify();
          return true;
        } else {
          final errorBody = utf8.decode(response.bodyBytes);
          _authMessage = errorBody.isNotEmpty
              ? errorBody
              : 'Site kaydı başarısız oldu (HTTP ${response.statusCode})';
          debugPrint('registerNewSite error: ${response.statusCode} - $errorBody');
          notify();
          return false;
        }
      } catch (e) {
        debugPrint('registerNewSite remote error: $e');
        _authMessage = 'Bağlantı hatası: Sunucuya ulaşılamadı ($e)';
        notify();
        return false;
      }
    }

    int maxSiteId = 0;
    for (final s in _saasSites) {
      final parsed = int.tryParse(s.id);
      if (parsed != null && parsed > maxSiteId) {
        maxSiteId = parsed;
      }
    }
    final simulatedSiteId = '${maxSiteId > 0 ? maxSiteId + 1 : _saasSites.length + 1}';

    final newSite = TenantSiteItem(
      id: simulatedSiteId,
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
    _managedSitesList = List.from(_saasSites);
    _provisionedCredentials = ProvisionedSiteCredentials(
      siteId: simulatedSiteId,
      siteName: name,
      adminName: adminName,
      adminEmail: adminEmail,
      temporaryPassword: tempPassword,
      planType: planType,
    );
    notify();
    return true;
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
      notify();
      return false;
    }
    _saasSites.removeAt(index);
    _authMessage = '${site.name} başarıyla silindi.';
    notify();

    if (!isTestMode) {
      final url = ApiClient.uri('/api/v1/saas/sites/$siteId');
      ApiClient.delete(url).catchError((e) {
        debugPrint('deleteSite remote sync notice: $e');
      });
    }

    return true;
  }

  /// Updates existing site information and manager details.
  Future<bool> updateSite({
    required String siteId,
    String? name,
    String? city,
    String? address,
    String? status,
    String? planType,
    String? adminName,
    String? adminEmail,
    String? adminPhone,
    List<String>? blocks,
  }) async {
    final index = _saasSites.indexWhere((s) => s.id == siteId);
    if (index == -1) return false;
    final currentSite = _saasSites[index];

    final updatedSite = currentSite.copyWith(
      name: name ?? currentSite.name,
      city: city ?? currentSite.city,
      address: address ?? currentSite.address,
      status: status ?? currentSite.status,
      planType: planType ?? currentSite.planType,
      adminName: adminName ?? currentSite.adminName,
      adminEmail: adminEmail ?? currentSite.adminEmail,
      adminPhone: adminPhone ?? currentSite.adminPhone,
      blocks: blocks ?? currentSite.blocks,
    );

    _saasSites[index] = updatedSite;
    if (_currentManagedSite?.id == siteId) {
      _currentManagedSite = updatedSite;
    }
    _authMessage = '${updatedSite.name} bilgileri başarıyla güncellendi.';
    notify();

    if (!isTestMode) {
      try {
        final url = ApiClient.uri('/api/v1/saas/sites/$siteId');
        final payload = <String, dynamic>{};
        if (name != null) payload['site_name'] = name;
        if (address != null) payload['address'] = address;
        if (status != null) payload['status'] = status;
        if (planType != null) payload['plan_type'] = planType;
        if (adminName != null) payload['site_admin_full_name'] = adminName;
        if (adminEmail != null) payload['site_admin_email'] = adminEmail;
        if (adminPhone != null) payload['site_admin_phone'] = adminPhone;
        if (blocks != null) payload['blocks'] = blocks;

        final response = await ApiClient.put(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        );

        if (response.statusCode == 200) {
          final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          final freshBlocks = (data['blocks'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? updatedSite.blocks;
          _saasSites[index] = updatedSite.copyWith(
            name: data['site_name']?.toString() ?? updatedSite.name,
            address: data['address']?.toString() ?? updatedSite.address,
            status: data['status']?.toString() ?? updatedSite.status,
            planType: data['plan_type']?.toString() ?? updatedSite.planType,
            adminName: data['primary_manager_name']?.toString() ?? updatedSite.adminName,
            adminEmail: data['primary_manager_email']?.toString() ?? updatedSite.adminEmail,
            adminPhone: data['primary_manager_phone']?.toString() ?? updatedSite.adminPhone,
            blocks: freshBlocks,
          );
          if (_currentManagedSite?.id == siteId) {
            _currentManagedSite = _saasSites[index];
          }
          notify();
          return true;
        } else {
          debugPrint('updateSite failed with status: ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('updateSite remote sync error: $e');
      }
    }

    return true;
  }

  /// Generates/renews a temporary management password for a site manager.
  /// Sets mustChangePassword and triggers credentials presentation dialog.
  Future<bool> resetSiteManagerPassword(String siteId) async {
    final index = _saasSites.indexWhere((s) => s.id == siteId);
    if (index == -1) return false;
    final site = _saasSites[index];

    String tempPassword = 'SP-${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}-PASS';

    if (!isTestMode) {
      try {
        final url = ApiClient.uri('/api/v1/saas/sites/$siteId/reset-admin-password');
        final response = await ApiClient.post(url).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          if (data['temporary_password'] != null) {
            tempPassword = data['temporary_password'].toString();
          }
        } else {
          final err = utf8.decode(response.bodyBytes);
          _authMessage = 'Şifre yenilenemedi: $err';
          notify();
          return false;
        }
      } catch (e) {
        debugPrint('resetSiteManagerPassword remote sync error: $e');
        _authMessage = 'Bağlantı hatası: Şifre yenilenemedi.';
        notify();
        return false;
      }
    }

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
    notify();
    return true;
  }

  Future<bool> changePassword({
    required String email,
    required String currentPassword,
    required String newPassword,
  }) async {
    if (email.trim().isEmpty || currentPassword.trim().isEmpty || newPassword.trim().isEmpty) {
      _authMessage = 'Lütfen tüm şifre alanlarını eksiksiz doldurunuz.';
      notify();
      return false;
    }

    if (newPassword.trim().length < 10) {
      _authMessage = 'Yeni şifre en az 10 karakter olmalıdır.';
      notify();
      return false;
    }

    if (!isTestMode) {
      try {
        final url = ApiClient.uri('/api/v1/auth/change-password');
        final response = await ApiClient.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'email': email.trim().toLowerCase(),
            'current_password': currentPassword.trim(),
            'new_password': newPassword.trim(),
          }),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          ApiClient.setSession(data);
          _userSession = _userSession.copyWith(mustChangePassword: false);
          if (_userSession.role == UserRole.saasAdmin) {
            await fetchSaasSites();
          } else if (_userSession.role == UserRole.siteManager) {
            await fetchSiteManagerOverview(siteId: _currentManagedSite?.id, period: _selectedDuesMonth);
          }
          _authMessage = 'Şifreniz başarıyla güncellendi.';
          notify();
          return true;
        } else {
          final err = utf8.decode(response.bodyBytes);
          _authMessage = err.isNotEmpty ? err : 'Şifre değiştirilemedi.';
          notify();
          return false;
        }
      } catch (e) {
        debugPrint('changePassword error: $e');
        _authMessage = 'Bağlantı hatası: Şifre değiştirilemedi.';
        notify();
        return false;
      }
    }

    _userSession = _userSession.copyWith(mustChangePassword: false);
    _authMessage = 'Şifreniz başarıyla güncellendi (Test Modu).';
    notify();
    return true;
  }

  void clearProvisionedCredentials() {
    _provisionedCredentials = null;
    notify();
  }


  void clearAuthMessage() {
    _authMessage = null;
    notify();
  }

  void setAuthError(String message) {
    _authMessage = message;
    notify();
  }

  // Bank Statement Ingestion & Automated Reconciliation Methods (STORY-07-02)


  UserSession _createSession(
    UserRole role,
    AuthProvider provider, {
    String? customName,
    String? customEmail,
    String? customPhone,
    String? avatarUrl,
    bool mustChangePassword = false,
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
          PermissionScope(code: 'UNIT_INVITE_CO_RESIDENT', title: 'Hane Sakini Davet Linki Üretme', isGranted: true, isolationNote: 'Sadece yetkili bağımsız bölüm'),
          PermissionScope(code: 'UNIT_MANAGE_HOUSEHOLD', title: 'Hane Sakinlerini Listeleme/Ekleme', isGranted: true, isolationNote: 'Sadece yetkili bağımsız bölüm'),
          PermissionScope(code: 'LEDGER_MANAGE_ALL', title: 'Site Finansını Yönetme', isGranted: false, isolationNote: 'Engelli: Site yönetimi yetkisi yok'),
        ];
        break;
      case UserRole.auditor:
        permissions = const [
          PermissionScope(code: 'FINANCE_READ', title: 'Defter, Rapor ve Tahsilat Görüntüleme', isGranted: true, isolationNote: 'Yalnızca kendi sitesi, salt okunur'),
          PermissionScope(code: 'EXPENSE_APPROVE', title: 'Limit Üstü Gider Onayı', isGranted: true, isolationNote: 'Kaydeden kişiden farklı onaycı'),
          PermissionScope(code: 'AUDIT_LOG_READ', title: 'Erişim Kaydı', isGranted: true, isolationNote: 'Finansal veri erişimleri'),
          PermissionScope(code: 'LEDGER_MANAGE_ALL', title: 'Site Finansını Yönetme', isGranted: false, isolationNote: 'Engelli: Denetçi değişiklik yapmaz'),
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
      mustChangePassword: mustChangePassword,
    );
  }


}
