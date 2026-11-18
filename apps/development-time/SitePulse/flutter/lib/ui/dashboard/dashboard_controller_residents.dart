part of 'dashboard_controller.dart';

/// Homeowners, resident directory, household members, registration approvals and occupancy management.
extension DashboardControllerResidents on DashboardController {
  /// Creates a pending advance settlement request after a resident exit.
  /// A second authorized person must approve it before any ledger is changed.
  Future<String?> requestAdvanceExitSettlement({
    required String unitId,
    required String kind,
    required String sourceDebtor,
    required String requestKey,
    required Decimal amount,
    required String beneficiaryName,
    int? beneficiaryPersonId,
    String? targetDebtor,
    String? note,
  }) async {
    if (isTestMode) return null;
    try {
      await PaymentsPhase3Api.createAdvanceExitSettlement(
        unitId,
        kind: kind,
        sourceDebtor: sourceDebtor,
        requestKey: requestKey,
        amount: amount,
        beneficiaryName: beneficiaryName,
        beneficiaryPersonId: beneficiaryPersonId?.toString(),
        targetDebtor: targetDebtor,
        note: note,
      );
      return null;
    } catch (e) {
      AppLogger.warn('Advance exit settlement request failed: $e', tag: 'Residents');
      return AppStrings.localizeBackendMessage(e.toString());
    }
  }

  /// F9: people of the site who may be the person about to be registered. The offline
  /// simulation compares the homeowners it holds; a failed check never blocks a
  /// registration, the server still refuses a taken login email.
  Future<List<DuplicateCandidate>> findPossibleDuplicates({
    required String fullName,
    required String email,
    required String phone,
    PersonDirectoryApi api = const PersonDirectoryApi(),
  }) async {
    if (!isTestMode) {
      try {
        return await api.findDuplicates(fullName: fullName, email: email, phone: phone);
      } catch (e) {
        AppLogger.warn('Duplicate check did not reach the server: $e', tag: 'Residents');
        return const [];
      }
    }
    String digits(String v) {
      final d = v.replaceAll(RegExp(r'\D'), '');
      return d.length >= 10 ? d.substring(d.length - 10) : '';
    }
    String name(String v) => (v.toLowerCase().split(RegExp(r'\s+'))..sort()).join(' ').trim();
    final found = <DuplicateCandidate>[];
    for (final h in homeOwners) {
      final reasons = <String>[
        if (email.trim().isNotEmpty && h.email.toLowerCase() == email.trim().toLowerCase()) 'SAME_EMAIL',
        if (digits(phone).isNotEmpty && digits(h.phone) == digits(phone)) 'SAME_PHONE',
        if (name(fullName).isNotEmpty && name(h.ownerFullName) == name(fullName)) 'SIMILAR_NAME',
      ];
      if (reasons.isEmpty) continue;
      found.add(DuplicateCandidate(
        person: PersonSummary(
          personId: 0,
          fullName: h.ownerFullName,
          email: h.email,
          phone: h.phone,
          role: 'HOME_OWNER',
          ownedUnits: 1,
          occupiedUnits: h.isResident ? 1 : 0,
          login: PersonLogin.fromCode(h.activationStatus == null ? 'ACTIVE' : 'PENDING'),
        ),
        reasons: reasons,
      ));
    }
    return found;
  }

  Future<void> registerHomeOwner({
    required String block,
    required int unitNo,
    String ownerName = '',
    String email = '',
    String phone = '',
    PersonRef? ownerRef,
    PersonRef? tenantRef,
    List<RegistrationMember> members = const [],
    String? tenantFullName,
    String? tenantEmail,
    String? tenantPhone,
    String? houseType,
    Decimal? duesAmount,
    bool isResident = true,
    String role = 'OWNER',
    String? relationship,
    int? landShare,
  }) async {
    _lastHomeOwnerError = null;
    final effectiveHouseType = houseType ?? '2+1';
    final matchedTariff = _houseTypes.cast<HouseTypeTariff?>().firstWhere(
      (h) => h?.typeName.toLowerCase() == effectiveHouseType.toLowerCase(),
      orElse: () => null,
    );
    final dues = duesAmount ?? matchedTariff?.duesAmount ?? Decimal.parse('1400.00');
    final cleanBlock = block.replaceAll('Blok', '').trim();
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    if (!isTestMode) {
      // U1/S4: the server is the only source of truth. A failed or unreachable request
      // changes nothing locally and is reported, so a save never looks done when it is not.
      _isRegisteringHomeOwner = true;
      _authMessage = null;
      notify();
      try {
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/home-owners?site_id=$effectiveSiteId');
        final response = await ApiClient.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'block': block,
            'unit_no': unitNo,
            'floor': ((unitNo - 1) ~/ 4) + 1,
            if (ownerRef != null) 'owner': ownerRef.toJson(),
            if (tenantRef != null) 'tenant': tenantRef.toJson(),
            if (members.isNotEmpty)
              'members': [
                for (final m in members)
                  {'person': m.person.toJson(), 'relationship': m.relationship},
              ],
            if (ownerRef == null) 'owner_full_name': ownerName,
            if (ownerRef == null) 'email': email,
            if (ownerRef == null) 'phone': phone,
            if (tenantRef == null) 'tenant_full_name': tenantFullName,
            if (tenantRef == null) 'tenant_email': tenantEmail,
            if (tenantRef == null) 'tenant_phone': tenantPhone,
            // F3: the entered share; without one the server uses the site's usual share and says so.
            if (landShare != null) 'land_share': '$landShare',
            // F4: only a known tariff is sent; otherwise the server applies and reports its default.
            if (duesAmount != null) 'monthly_dues': duesAmount.toString(),
            'house_type': effectiveHouseType,
            'is_resident': isResident,
            'role': role,
          }),
        ).timeout(const Duration(seconds: 15));
        final data = ApiClient.decode(response) as Map<String, dynamic>;
        final created = HomeOwnerItem.fromJson(data);
        await fetchSiteManagerOverview(siteId: effectiveSiteId, period: _selectedDuesMonth);
        await fetchHomeOwners(siteId: effectiveSiteId);
        _provisionedHomeOwner = ProvisionedHomeOwnerCredentials(
          block: block,
          unitNo: unitNo,
          ownerName: ownerName,
          email: email,
          phone: phone,
          activationStatus: created.activationStatus,
          warnings: created.warnings,
          isResident: isResident,
          duesAmount: dues,
          houseType: effectiveHouseType,
        );
        _lastHomeOwnerError = null;
      } on ApiException catch (e) {
        _lastHomeOwnerError = e.statusCode >= 500
            ? 'Sakin kaydedilemedi. Lütfen tekrar deneyin. (Referans: ${e.traceId ?? '-'})'
            : AppStrings.localizedErrorMessage(e.code, fallback: e.message);
        _authMessage = _lastHomeOwnerError;
      } catch (e) {
        AppLogger.warn('Home owner registration did not reach the server', tag: 'Residents');
        _lastHomeOwnerError = 'Sunucuya ulaşılamadı. Kayıt yapılmadı; bağlantınızı kontrol edip tekrar deneyin.';
        _authMessage = _lastHomeOwnerError;
      } finally {
        _isRegisteringHomeOwner = false;
        notify();
      }
      return;
    }

    // Test mode only: an in-memory simulation of the backend for widget tests.
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
          id: '${_flatsList.length + 1}',
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
      activationStatus: 'SENT',
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

    final String targetUnitId = existingHoIndex != -1 ? _homeOwners[existingHoIndex].unitId : '$unitNo';

    // If unit already had an occupant and we're registering a new OWNER or TENANT, archive old occupant to history
    if (existingHoIndex != -1 && !isResidentRole) {
      final old = _homeOwners[existingHoIndex];
      final currentHist = _localOccupancyHistory.putIfAbsent(targetUnitId, () => []);
      if (currentHist.isEmpty) {
        final prevName = old.tenantFullName ?? old.ownerFullName;
        final prevRole = old.tenantFullName != null ? 'TENANT' : 'OWNER';
        currentHist.add(OccupancyHistoryItem(
          id: currentHist.length + 1,
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
        id: (_localOccupancyHistory[targetUnitId]?.length ?? 0) + 1,
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
      landShare: '${landShare ?? 1}/24',
      monthlyDues: dues,
      houseType: effectiveHouseType,
      isResident: isResident,
      activationStatus: 'SENT',
      mustChangePassword: true,
      createdAt: DateTime.now(),
    );
    if (existingHoIndex != -1) {
      if (isResidentRole) {
        final existingHo = _homeOwners[existingHoIndex];
        final newMember = UnitResidentMember(
          id: '${existingHo.householdResidents.length + 1}',
          fullName: ownerName,
          relationship: relationship ?? 'OTHER',
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
          id: '1',
          fullName: ownerName,
          relationship: relationship ?? 'OTHER',
          phone: phone,
          email: email,
          isOwner: false,
        );
        _homeOwners = [hoItem.copyWith(householdResidents: [newMember]), ..._homeOwners];
      } else {
        _homeOwners = [hoItem, ..._homeOwners];
      }
    }

    for (final member in members) {
      await addHouseholdMember(
        unitId: targetUnitId,
        block: block,
        unitNo: unitNo,
        fullName: member.fullName,
        phone: member.phone,
        email: member.email,
        relationship: member.relationship,
      );
    }
    notify();
  }

  void clearProvisionedHomeOwner() {
    _provisionedHomeOwner = null;
    notify();
  }

  /// A person card was edited: every unit role held by [personId] (owner, tenant,
  /// household member) takes the new name and contact at once, before any reload.
  void applyPersonUpdate(int personId, {required String fullName, required String phone, required String email}) {
    var changed = false;
    _homeOwners = [
      for (final ho in _homeOwners)
        () {
          final isOwner = ho.ownerPersonId == personId;
          final isTenant = ho.tenantPersonId == personId;
          final hasMember = ho.householdResidents.any((m) => m.personId == personId);
          if (!isOwner && !isTenant && !hasMember) return ho;
          changed = true;
          return ho.copyWith(
            ownerFullName: isOwner ? fullName : null,
            email: isOwner ? email : null,
            phone: isOwner ? phone : null,
            tenantFullName: isTenant ? fullName : null,
            tenantEmail: isTenant ? email : null,
            tenantPhone: isTenant ? phone : null,
            householdResidents: hasMember
                ? [
                    for (final m in ho.householdResidents)
                      m.personId == personId ? m.copyWith(fullName: fullName, phone: phone, email: email) : m,
                  ]
                : null,
          );
        }(),
    ];
    if (changed) notify();
  }

  Future<void> fetchHomeOwners({String? siteId}) async {
    if (!isTestMode && !canReadSiteDirectory) return;
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    _isLoadingHomeOwners = true;

    if (!isTestMode) {
      try {
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/home-owners?site_id=$effectiveSiteId');
        final response = await ApiClient.get(url).timeout(const Duration(seconds: 4));
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
          notify();
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
    notify();
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
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/home-owners/$unitId?site_id=$effectiveSiteId');
        final response = await ApiClient.put(
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

        _homeOwnerUpdateNeedsStepUp = false;
        _pendingEmailChanges = const [];
        _lastHomeOwnerError = null;
        try {
          final data = ApiClient.decode(response);
          final pending = (data is Map<String, dynamic> && data['pending_email_changes'] is List)
              ? (data['pending_email_changes'] as List)
                  .whereType<Map<String, dynamic>>()
                  .map((c) => c['new_email']?.toString() ?? '')
                  .where((e) => e.isNotEmpty)
                  .toList()
              : const <String>[];
          _pendingEmailChanges = pending;
          // S5: a login email stays as it is until the new address confirms the change.
          _applyLocalHomeOwnerUpdate(
            unitId: unitId,
            fullName: fullName,
            email: pending.contains(email?.trim().toLowerCase()) ? null : email,
            phone: phone,
            tenantFullName: tenantFullName,
            tenantEmail: pending.contains(tenantEmail?.trim().toLowerCase()) ? null : tenantEmail,
            tenantPhone: tenantPhone,
            removeTenant: removeTenant,
            houseType: houseType,
            effectiveDues: effectiveDues,
            landShare: landShare,
            isResident: isResident,
          );
          notify();
          fetchHomeOwners(siteId: effectiveSiteId).catchError((e) => debugPrint('bg fetchHomeOwners error: $e'));
          fetchSiteManagerOverview(siteId: effectiveSiteId, period: _selectedDuesMonth).catchError((e) => debugPrint('bg fetchSiteManagerOverview error: $e'));
          return true;
        } on ApiException catch (e) {
          _homeOwnerUpdateNeedsStepUp = e.code == 'STEP_UP_REQUIRED';
          _lastHomeOwnerError = e.statusCode >= 500
              ? 'Değişiklik kaydedilemedi. Lütfen tekrar deneyin. (Referans: ${e.traceId ?? '-'})'
              : AppStrings.localizedErrorMessage(e.code, fallback: e.message);
          notify();
          return false;
        }
      } catch (e) {
        AppLogger.warn('Home owner update did not reach the server', tag: 'Residents');
        _lastHomeOwnerError = 'Sunucuya ulaşılamadı. Değişiklik kaydedilmedi.';
        notify();
        return false;
      }
    }

    // In-memory update
    _applyLocalHomeOwnerUpdate(
      unitId: unitId,
      fullName: fullName,
      email: email,
      phone: phone,
      tenantFullName: tenantFullName,
      tenantEmail: tenantEmail,
      tenantPhone: tenantPhone,
      removeTenant: removeTenant,
      houseType: houseType,
      effectiveDues: effectiveDues,
      landShare: landShare,
      isResident: isResident,
    );
    notify();
    return true;
  }

  void _applyLocalHomeOwnerUpdate({
    required String unitId,
    String? fullName,
    String? email,
    String? phone,
    String? tenantFullName,
    String? tenantEmail,
    String? tenantPhone,
    bool? removeTenant,
    String? houseType,
    Decimal? effectiveDues,
    String? landShare,
    bool? isResident,
  }) {
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
  }

  Future<bool> setPrimaryResponsibleResident({
    required String unitId,
    required String residentName,
    required String role,
    String? phone,
    String? email,
    String? siteId,
    String? memberId,
    int? personId,
  }) async {
    final index = _homeOwners.indexWhere((unit) => unit.unitId == unitId);
    if (index == -1) return false;
    final effectiveSiteId = siteId ?? _homeOwners[index].siteId;
    var name = residentName;
    var contactRole = role;
    var contactPhone = phone;
    var contactEmail = email;
    var savedMemberId = memberId;
    if (!isTestMode) {
      try {
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/units/$unitId/responsible-contact?site_id=$effectiveSiteId');
        final response = await ApiClient.put(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            if (personId != null) 'person_id': personId,
            'role': role,
            'resident_name': residentName,
            if (memberId != null) 'member_id': memberId,
          }),
        ).timeout(const Duration(seconds: 4));
        if (response.statusCode != 200) return false;
        final saved = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        name = saved['primary_responsible_name'] as String;
        contactRole = saved['primary_responsible_role'] as String;
        contactPhone = saved['primary_responsible_phone'] as String?;
        contactEmail = saved['primary_responsible_email'] as String?;
        savedMemberId = saved['primary_responsible_member_id'] as String?;
      } catch (error) {
        AppLogger.warn('Responsible contact save failed', tag: 'Residents');
        return false;
      }
    }
    // The contact selection never changes ownership or the actual occupant.
    final currentIndex = _homeOwners.indexWhere((unit) => unit.unitId == unitId);
    if (currentIndex == -1) return false;
    _homeOwners[currentIndex] = _homeOwners[currentIndex]
        .copyWith(clearPrimaryResponsible: true).copyWith(
      primaryResponsibleName: name,
      primaryResponsibleRole: contactRole,
      primaryResponsiblePhone: contactPhone,
      primaryResponsibleEmail: contactEmail,
      primaryResponsibleMemberId: savedMemberId,
    );
    notify();
    return true;
  }


  Future<bool> deleteHomeOwner({
    required String unitId,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');

    if (!isTestMode) {
      try {
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/home-owners/$unitId?site_id=$effectiveSiteId');
        final response = await ApiClient.delete(
          url,
          headers: {'Content-Type': 'application/json'},
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200 || response.statusCode == 204) {
          lastDeleteHomeOwnerError = null;
          await fetchHomeOwners(siteId: effectiveSiteId);
          await fetchSiteManagerOverview(siteId: effectiveSiteId, period: _selectedDuesMonth);
          notify();
          return true;
        }
        // The server refused (e.g. 409: the unit has financial history). The card
        // must stay: removing it locally would show data the server still holds.
        final err = utf8.decode(response.bodyBytes);
        debugPrint('deleteHomeOwner failed: ${response.statusCode} - $err');
        lastDeleteHomeOwnerError = err.trim().isNotEmpty ? err.trim() : null;
        return false;
      } catch (e) {
        debugPrint('deleteHomeOwner error: $e');
        lastDeleteHomeOwnerError = null;
        return false;
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

    notify();
    return true;
  }

  Future<void> fetchHouseholdMembers([String? unitId]) async {
    final effectiveUnitId = unitId ?? (_activeUnit.id.isNotEmpty ? _activeUnit.id : null);
    if (effectiveUnitId == null || effectiveUnitId.isEmpty) return;

    if (!isTestMode) {
      try {
        final url = ApiClient.uri('/api/v1/home-residents/members/$effectiveUnitId');
        final response = await ApiClient.get(url).timeout(const Duration(seconds: 3));
        if (response.statusCode == 200) {
          final list = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
          final members = list.map((m) => UnitResidentMember.fromJson(m as Map<String, dynamic>)).toList();
          _unitResidents = members;
          if (_userSession.role == UserRole.siteManager && _siteAdminPath == SiteAdminActivePath.myFlatOwner) {
            _managerResidents = members;
          }
          notify();
          return;
        }
      } catch (e) {
        debugPrint('fetchHouseholdMembers error: $e');
      }
    }
  }

  Future<bool> deleteHouseholdMember({
    String? unitId,
    required String residentId,
    String? siteId,
  }) async {
    final effectiveUnitId = unitId ?? (_activeUnit.id.isNotEmpty ? _activeUnit.id : (_activeUnit.unitNumber.isNotEmpty ? _activeUnit.unitNumber : '1'));
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');

    if (!isTestMode) {
      try {
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/home-residents/members/$effectiveUnitId/$residentId?site_id=$effectiveSiteId');
        final response = await ApiClient.delete(url).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200 || response.statusCode == 204) {
          await fetchHouseholdMembers(effectiveUnitId);
          await fetchHomeOwners(siteId: effectiveSiteId);
          notify();
          return true;
        }
        return false;
      } catch (e) {
        debugPrint('deleteHouseholdMember error: $e');
        return false;
      }
    }

    // In-memory update
    _unitResidents = _unitResidents.where((m) => m.id != residentId && m.fullName != residentId).toList();
    if (_userSession.role == UserRole.siteManager && _siteAdminPath == SiteAdminActivePath.myFlatOwner) {
      _managerResidents = _managerResidents.where((m) => m.id != residentId && m.fullName != residentId).toList();
    }
    final hoIndex = _homeOwners.indexWhere((h) => h.unitId == effectiveUnitId);
    if (hoIndex != -1) {
      final updatedResidents = _homeOwners[hoIndex].householdResidents.where((m) => m.id != residentId && m.fullName != residentId).toList();
      _homeOwners[hoIndex] = _homeOwners[hoIndex].copyWith(householdResidents: updatedResidents);
    }
    notify();
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
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/home-residents/members/$unitId/$residentId?site_id=$effectiveSiteId');
        final response = await ApiClient.put(
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
          await fetchHouseholdMembers(unitId);
          await fetchHomeOwners(siteId: effectiveSiteId);
          notify();
          return true;
        }
        return false;
      } catch (e) {
        debugPrint('updateHouseholdMember error: $e');
        return false;
      }
      return false;
    }

    // In-memory update
    _unitResidents = _unitResidents.map((m) {
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
    if (_userSession.role == UserRole.siteManager && _siteAdminPath == SiteAdminActivePath.myFlatOwner) {
      _managerResidents = _unitResidents;
    }

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
    }
    notify();
    return true;
  }

  Future<bool> addHouseholdMember({
    String? unitId,
    String? block,
    int? unitNo,
    required String fullName,
    required String phone,
    required String email,
    required String relationship,
    PersonRef? person,
  }) async {
    final effectiveUnitId = unitId ?? (_activeUnit.id.isNotEmpty ? _activeUnit.id : (_activeUnit.unitNumber.isNotEmpty ? _activeUnit.unitNumber : '1'));
    final effectiveBlock = block ?? (_activeUnit.block.isNotEmpty ? _activeUnit.block : 'A');
    final effectiveUnitNo = unitNo ?? (_activeUnit.unitNo > 0 ? _activeUnit.unitNo : 1);
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');

    if (!isTestMode) {
      try {
        final memberUrl = Uri.parse('${ApiClient.baseUrl}/api/v1/home-residents/members/$effectiveUnitId?site_id=$effectiveSiteId');
        final response = await ApiClient.post(
          memberUrl,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'person': (person ??
                    PersonRef.draft(
                      fullName: fullName,
                      phone: phone.isEmpty ? null : phone,
                      email: email.isEmpty ? null : email,
                      confirmDistinct: true,
                    ))
                .toJson(),
            'relationship': relationship,
          }),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200 || response.statusCode == 201) {
          await fetchHouseholdMembers(effectiveUnitId);
          await fetchHomeOwners(siteId: effectiveSiteId);
          notify();
          return true;
        }
        return false;
      } catch (e) {
        debugPrint('addHouseholdMember remote error: $e');
        return false;
      }
    }

    int maxMemId = 0;
    for (final m in _unitResidents) {
      final parsed = int.tryParse(m.id);
      if (parsed != null && parsed > maxMemId) {
        maxMemId = parsed;
      }
    }
    final nextMemId = '${maxMemId > 0 ? maxMemId + 1 : _unitResidents.length + 1}';

    // In-memory update
    final newMember = UnitResidentMember(
      id: nextMemId,
      fullName: fullName,
      relationship: relationship,
      phone: phone,
      email: email,
      isOwner: false,
    );
    _unitResidents = [..._unitResidents, newMember];
    if (_userSession.role == UserRole.siteManager && _siteAdminPath == SiteAdminActivePath.myFlatOwner) {
      _managerResidents = [..._managerResidents, newMember];
    }

    final hoIndex = _homeOwners.indexWhere((h) => h.unitId == effectiveUnitId);
    if (hoIndex != -1) {
      final updatedResidents = List<UnitResidentMember>.from(_homeOwners[hoIndex].householdResidents)..add(newMember);
      _homeOwners[hoIndex] = _homeOwners[hoIndex].copyWith(householdResidents: updatedResidents);
    }
    notify();
    return true;
  }

  /// EPIC-08 §3.3: one guarded occupancy command (move-in, move-out, or a
  /// compound move). The server checks the unit's state and refuses a command
  /// that is not legal there; its reason is returned for the screen.
  Future<OccupancyTransitionResult> applyOccupancyTransition(
    String unitId, {
    required OccupancyCommand command,
    int? personId,
    String? fullName,
    String? email,
    String? phone,
    int? ownerPersonId,
    PersonRef? person,
    String? notes,
  }) async {
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    if (!isTestMode) {
      try {
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/units/$unitId/occupancy-transitions?site_id=$effectiveSiteId');
        final response = await ApiClient.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'command': command.code,
            if (person != null) 'person': person.toJson(),
            'person_id': ?personId,
            'full_name': ?fullName,
            'email': ?email,
            'phone': ?phone,
            'owner_person_id': ?ownerPersonId,
            'notes': ?notes,
          }),
        ).timeout(const Duration(seconds: 8));
        if (response.statusCode == 200) {
          await fetchHomeOwners(siteId: effectiveSiteId);
          return const OccupancyTransitionResult.success();
        }
        return OccupancyTransitionResult.failure(
          extractErrorMessage(response, fallback: 'İşlem kaydedilemedi.'),
        );
      } catch (e) {
        AppLogger.warn('Occupancy transition did not reach the server: $e', tag: 'Residents');
        return const OccupancyTransitionResult.failure('Sunucuya ulaşılamadı. Lütfen tekrar deneyin.');
      }
    }
    return _applyOccupancyTransitionLocally(unitId, command, fullName: fullName, email: email, phone: phone, notes: notes);
  }

  /// The unit's owners on record and legal commands, from the server.
  Future<UnitOccupancyState?> fetchOccupancyState(String unitId) async {
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    if (isTestMode) {
      final idx = _homeOwners.indexWhere((h) => h.unitId == unitId);
      return idx == -1 ? null : UnitOccupancyState.fromHomeOwner(_homeOwners[idx]);
    }
    try {
      final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/units/$unitId/occupancy-state?site_id=$effectiveSiteId');
      final response = await ApiClient.get(url).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? UnitOccupancyState.fromJson(decoded) : null;
    } catch (e) {
      AppLogger.warn('Occupancy state did not reach the server: $e', tag: 'Residents');
      return null;
    }
  }

  /// Demonstration storage: the same transition table, applied to the list.
  OccupancyTransitionResult _applyOccupancyTransitionLocally(
    String unitId,
    OccupancyCommand command, {
    String? fullName,
    String? email,
    String? phone,
    String? notes,
  }) {
    final idx = _homeOwners.indexWhere((h) => h.unitId == unitId);
    if (idx == -1) return const OccupancyTransitionResult.failure('Daire bulunamadı.');
    final ho = _homeOwners[idx];
    if (!ho.allows(command)) {
      return OccupancyTransitionResult.failure('${command.label} bu dairenin mevcut durumunda yapılamaz.');
    }
    final today = DateTime.now().toIso8601String().split('T').first;
    final history = _localOccupancyHistory.putIfAbsent(unitId, () => []);
    _localOccupancyHistory[unitId] = history
        .map((h) => h.isActive ? h.copyWith(isActive: false, endDate: today, notes: notes) : h)
        .toList();
    if (command == OccupancyCommand.moveOut) {
      _homeOwners[idx] = ho.copyWith(occupancyStatus: 'VACANT', tenantFullName: null, tenantEmail: null, tenantPhone: null);
    } else if (command.opensOwnerSession) {
      _homeOwners[idx] = ho.copyWith(occupancyStatus: 'OWNER_OCCUPIED', tenantFullName: null, tenantEmail: null, tenantPhone: null);
    } else {
      _homeOwners[idx] = ho.copyWith(
        occupancyStatus: 'TENANT_OCCUPIED',
        tenantFullName: fullName,
        tenantEmail: email,
        tenantPhone: phone,
      );
    }
    notify();
    return const OccupancyTransitionResult.success();
  }

  Future<bool> moveOutResident(String unitId, {String? notes, DateTime? effectiveDate}) async {
    final endDate = formatEffectiveDate(effectiveDate ?? DateTime.now());
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    if (!isTestMode) {
      try {
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/units/$unitId/move-out?site_id=$effectiveSiteId');
        final response = await ApiClient.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'notes': notes, 'end_date': endDate}),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200) {
          await fetchHomeOwners(siteId: effectiveSiteId);
          return true;
        }
        return false;
      } catch (e) {
        debugPrint('moveOutResident error: $e');
        return false;
      }
      return false;
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
              endDate: endDate,
              notes: notes,
            );
          }
          return h;
        }).toList();
      }
      notify();
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
    int? personId,
  }) async {
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    if (!isTestMode) {
      try {
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/units/$unitId/move-in?site_id=$effectiveSiteId');
        final response = await ApiClient.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'role': role,
            // U7: an existing person of the site is linked instead of being re-typed.
            'person_id': ?personId,
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
        return false;
      } catch (e) {
        debugPrint('moveInResident error: $e');
        return false;
      }
      return false;
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
        // STORY-08-06: a move-in never changes the owner on record.
        ownerFullName: _homeOwners[idx].ownerFullName,
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

      int maxOccId = 0;
      for (final h in _localOccupancyHistory.values.expand((list) => list)) {
        if (h.id > maxOccId) maxOccId = h.id;
      }
      final nextOccId = maxOccId > 0 ? maxOccId + 1 : (_localOccupancyHistory[unitId]?.length ?? 0) + 1;

      _localOccupancyHistory[unitId]!.insert(0, OccupancyHistoryItem(
        id: nextOccId,
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

      notify();
      return true;
    }
    return false;
  }

  Future<List<OccupancyHistoryItem>> fetchOccupancyHistory(String unitId) async {
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    if (!isTestMode) {
      try {
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/units/$unitId/occupancy-history?site_id=$effectiveSiteId');
        final response = await ApiClient.get(url).timeout(const Duration(seconds: 4));

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
    // A placeholder exists only in the offline test mode; a live approval shows what the server sent.
    String tempPassword =
        isTestMode ? 'SP-SAKIN-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}' : '';

    if (!isTestMode) {
      try {
        final url = ApiClient.uri('/api/v1/registration/approve/$requestId');
        final response = await ApiClient.post(url).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          if (data['temporary_password'] != null && data['temporary_password'].toString().isNotEmpty) {
            tempPassword = data['temporary_password'].toString();
          }
          await fetchSiteManagerOverview(siteId: _currentManagedSite?.id, period: _selectedDuesMonth);
        } else {
          debugPrint('approveRegistration remote error: ${response.statusCode}');
          return;
        }
      } catch (e) {
        debugPrint('approveRegistration network error: $e');
        return;
      }
    }

    _pendingRegistrations = _pendingRegistrations.where((r) => r.id != requestId).toList();

    final cleanBlock = target.block.replaceAll('Blok', '').trim();
    final existingIdx = _flatsList.indexWhere((f) => f.unitNo == target.unitNo && f.block == cleanBlock);
    if (existingIdx == -1) {
      int maxFlatId = 0;
      for (final f in _flatsList) {
        final parsed = int.tryParse(f.id);
        if (parsed != null && parsed > maxFlatId) {
          maxFlatId = parsed;
        }
      }
      final nextFlatId = '${maxFlatId > 0 ? maxFlatId + 1 : _flatsList.length + 1}';
      final newFlat = FlatPaymentStatus(
        id: nextFlatId,
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
    notify();
  }

  /// Loads the manager's queue of submitted registrations from the server.
  Future<void> fetchPendingRegistrations({String? siteId}) async {
    if (isTestMode || _userSession.role != UserRole.siteManager) return;
    try {
      final params = <String, String>{};
      if (siteId != null && siteId.isNotEmpty) params['site_id'] = siteId;
      final response = await ApiClient.get(ApiClient.uri('/api/v1/registration/pending', params))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) {
        debugPrint('fetchPendingRegistrations remote error: ${response.statusCode}');
        return;
      }
      final list = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
      _pendingRegistrations = list
          .map((e) => e as Map<String, dynamic>)
          .where((m) => (m['status'] as String? ?? 'PENDING').toUpperCase() == 'PENDING')
          .map((m) => RegistrationRequestItem(
                id: m['request_id'] as String? ?? '',
                block: m['block'] as String? ?? '',
                unitNo: (m['unit_no'] as num?)?.toInt() ?? 0,
                floor: (m['floor'] as num?)?.toInt() ?? 0,
                fullName: m['full_name'] as String? ?? '',
                email: m['email'] as String? ?? '',
                phone: m['phone'] as String? ?? '',
                isResident: m['is_resident'] as bool? ?? false,
                duesAmount: Decimal.zero,
                timeAgoStr: m['submitted_at'] as String? ?? '',
              ))
          .toList();
      notify();
    } catch (e) {
      debugPrint('fetchPendingRegistrations network error: $e');
    }
  }

  Future<bool> createAnnouncement(String title, String body) async {
    final cleanTitle = title.trim();
    final cleanBody = body.trim();
    if (cleanTitle.isEmpty || cleanBody.isEmpty) {
      setAuthError('Duyuru başlığı ve açıklaması zorunludur.');
      return false;
    }
    if (isTestMode) {
      _announcementTitle = cleanTitle;
      _announcementContent = cleanBody;
      setAuthError('Duyuru yayınlandı.');
      return true;
    }
    final siteId = _currentManagedSite?.id;
    if (siteId == null || siteId.isEmpty) {
      setAuthError('Duyuru yayınlamak için yönetilen bir site seçin.');
      return false;
    }
    try {
      final response = await ApiClient.post(
        ApiClient.uri('/api/v1/announcements'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'site_id': siteId, 'title': cleanTitle, 'body': cleanBody}),
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode != 201) {
        setAuthError(extractErrorMessage(response, fallback: 'Duyuru yayınlanamadı.'));
        return false;
      }
      _announcementTitle = cleanTitle;
      _announcementContent = cleanBody;
      notify();
      return true;
    } catch (_) {
      setAuthError('Duyuru yayınlanamadı. Bağlantınızı kontrol edip tekrar deneyin.');
      return false;
    }
  }

  Future<void> rejectRegistration(String requestId) async {
    if (!isTestMode) {
      try {
        final response = await ApiClient.post(ApiClient.uri('/api/v1/registration/reject/$requestId'))
            .timeout(const Duration(seconds: 4));
        if (response.statusCode != 200) {
          debugPrint('rejectRegistration remote error: ${response.statusCode}');
          return;
        }
      } catch (e) {
        debugPrint('rejectRegistration network error: $e');
        return;
      }
    }
    _pendingRegistrations = _pendingRegistrations.where((r) => r.id != requestId).toList();
    notify();
  }

  void clearApprovalSuccess() {
    _approvalSuccessInfo = null;
    notify();
  }

  Future<void> generateUnitInviteLink() async {
    if (!isTestMode) {
      try {
        final unitId = _activeUnit.id;
        if (unitId.isEmpty) throw StateError('Active unit is missing an ID');
        final response = await ApiClient.get(
          ApiClient.uri('/api/v1/home-residents/invite-link/$unitId'),
        ).timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) {
          throw StateError('Invite endpoint returned ${response.statusCode}');
        }
        final data = json.decode(response.body) as Map<String, dynamic>;
        final expiresAt = DateTime.parse(data['expires_at'] as String).toLocal();
        _unitInviteInfo = UnitInviteInfo(
          inviteUrl: data['invite_url'] as String,
          token: data['token'] as String,
          unitLabel: '${data['building']} D:${data['unit_number']}',
          expiresAtStr: 'Geçerlilik: ${expiresAt.day}.${expiresAt.month}.${expiresAt.year}',
          securityNotice: data['security_notice'] as String,
        );
      } catch (error) {
        AppLogger.warn('Could not generate unit invitation: $error', tag: 'Residents');
        _authMessage = 'Davet bağlantısı oluşturulamadı. Lütfen tekrar deneyin.';
      }
      notify();
      return;
    }

    // The offline preview has no invitation service; keep a clearly local fixture.
    const token = 'SP-HANE-test-token';
    final unitLabel = '${_activeUnit.block} D:${_activeUnit.unitNo}';
    _unitInviteInfo = UnitInviteInfo(
      inviteUrl: 'https://sitepulse.app/join/begonya-sitesi/units/${_activeUnit.id}?token=$token',
      token: token,
      unitLabel: unitLabel,
      expiresAtStr: '7 gün geçerli',
      securityNotice: 'Bu link sadece $unitLabel bağımsız bölümüne erişim yetkisi verir. Diğer daire veya yönetim yetkileri kapalıdır.',
    );
    notify();
  }

  Future<void> generateSiteInviteLink() async {
    if (isTestMode) {
      const siteName = 'Begonya Sitesi';
      const token = 'SP-INV-E2ETEST';
      _unitInviteInfo = const UnitInviteInfo(
        inviteUrl: 'https://sitepulse.app/join/begonya-sitesi?token=$token',
        token: token,
        unitLabel: siteName,
        expiresAtStr: '7 gün geçerli',
        securityNotice: 'Bu bağlantı siteye kayıt başvurusu oluşturur ve 7 gün içinde geçerliliğini yitirir.',
        title: 'Site Sakinlerini Davet Et',
      );
      notify();
      return;
    }

    final siteId = _currentManagedSite?.id;
    if (siteId == null || siteId.isEmpty) {
      setAuthError('Davet bağlantısı oluşturmak için yönetilen bir site seçin.');
      return;
    }
    try {
      final response = await ApiClient.get(
        ApiClient.uri('/api/v1/registration/invite-link', {'site_id': siteId}),
      ).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        setAuthError(extractErrorMessage(response, fallback: 'Davet bağlantısı oluşturulamadı.'));
        return;
      }
      final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final inviteUrl = data['join_url']?.toString() ?? '';
      final token = data['token']?.toString() ?? '';
      final siteName = data['site_name']?.toString() ?? '';
      if (inviteUrl.isEmpty || token.isEmpty || siteName.isEmpty) {
        throw const FormatException('The invitation response is incomplete.');
      }
      _unitInviteInfo = UnitInviteInfo(
        inviteUrl: inviteUrl,
        token: token,
        unitLabel: siteName,
        expiresAtStr: '7 gün geçerli',
        securityNotice: 'Bu bağlantı $siteName için kayıt başvurusu oluşturur ve 7 gün içinde geçerliliğini yitirir.',
        title: 'Site Sakinlerini Davet Et',
      );
      notify();
    } catch (_) {
      setAuthError('Davet bağlantısı alınamadı. Bağlantınızı kontrol edip tekrar deneyin.');
    }
  }

  void clearUnitInviteInfo() {
    _unitInviteInfo = null;
    notify();
  }


  Future<Map<String, dynamic>?> transferUnitOwnership({
    required String unitId,
    required String newOwnerName,
    String? newOwnerPhone,
    String? newOwnerEmail,
    String? notes,
    String? siteId,
    bool newOwnerMovesIn = false,
    PersonRef? newOwner,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '';
    final payload = {
      // STORY-08-09: an owner-occupied unit becomes vacant unless the new owner moves in.
      'new_owner_moves_in': newOwnerMovesIn,
      if (newOwner?.personId != null) 'new_owner_person_id': newOwner!.personId,
      'site_id': effectiveSiteId,
      'unit_id': unitId,
      'new_owner_name': newOwnerName,
      'new_owner_phone': newOwnerPhone,
      'new_owner_email': newOwnerEmail,
      'notes': notes,
    };

    if (!isTestMode) {
      try {
        final uri = ApiClient.uri('/api/v1/site-admin/units/$unitId/transfer-ownership');
        final response = await ApiClient.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200) {
          final res = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          await fetchHomeOwners(siteId: effectiveSiteId);
          return res;
        } else {
          final body = utf8.decode(response.bodyBytes);
          // The server asks for a recent password check before moving ownership.
          return {
            'success': false,
            'needs_step_up': response.statusCode == 403 && body.contains('STEP_UP_REQUIRED'),
            'message': body,
          };
        }
      } catch (e) {
        debugPrint('transferUnitOwnership error: $e');
        return {'success': false, 'message': e.toString()};
      }
    }

    return {
      'success': true,
      'message': 'Mülk tapu devri başarıyla tamamlandı. Yeni malik ($newOwnerName) kaydedildi.',
      'new_owner_name': newOwnerName,
      'old_owner_exit_balance': '0.00',
    };
  }


}
