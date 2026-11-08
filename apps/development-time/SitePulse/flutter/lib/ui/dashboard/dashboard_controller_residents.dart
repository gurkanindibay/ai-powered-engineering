part of 'dashboard_controller.dart';

/// Homeowners, resident directory, household members, registration approvals and occupancy management.
extension DashboardControllerResidents on DashboardController {
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
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/home-owners?site_id=$effectiveSiteId');
        final response = await ApiClient.post(
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
          notify();
          return;
        } else {
          final errorBody = utf8.decode(response.bodyBytes);
          debugPrint('registerHomeOwner remote error: ${response.statusCode} - $errorBody');
          _authMessage = errorBody.isNotEmpty ? errorBody : 'Sakin eklenirken hata oluştu (${response.statusCode})';
          notify();
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
          id: '${existingHo.householdResidents.length + 1}',
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
          id: '1',
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

    notify();
  }

  void clearProvisionedHomeOwner() {
    _provisionedHomeOwner = null;
    notify();
  }

  Future<void> fetchHomeOwners({String? siteId}) async {
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

        if (response.statusCode == 200 || response.statusCode == 204) {
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
          fetchHomeOwners(siteId: effectiveSiteId).catchError((e) => debugPrint('bg fetchHomeOwners error: $e'));
          fetchSiteManagerOverview(siteId: effectiveSiteId, period: _selectedDuesMonth).catchError((e) => debugPrint('bg fetchSiteManagerOverview error: $e'));
          return true;
        } else {
          final err = utf8.decode(response.bodyBytes);
          debugPrint('updateHomeOwner failed: ${response.statusCode} - $err');
          return false;
        }
      } catch (e) {
        debugPrint('updateHomeOwner error: $e');
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
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');

    if (!isTestMode) {
      try {
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/home-owners/$unitId?site_id=$effectiveSiteId');
        final isOwner = role.toUpperCase() == 'OWNER';
        final payload = <String, dynamic>{
          if (isOwner) 'owner_full_name': residentName else 'tenant_full_name': residentName,
          if (phone != null) (isOwner ? 'phone' : 'tenant_phone'): phone,
          if (email != null) (isOwner ? 'email' : 'tenant_email'): email,
        };
        final response = await ApiClient.put(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        ).timeout(const Duration(seconds: 4));
        if (response.statusCode != 200 && response.statusCode != 204) {
          debugPrint('setPrimaryResponsibleResident remote failed: ${response.statusCode}');
          return false;
        }
      } catch (e) {
        debugPrint('setPrimaryResponsibleResident remote error: $e');
        return false;
      }
    }

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
            'full_name': fullName,
            'phone': phone,
            'email': email,
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

  Future<bool> moveOutResident(String unitId, {String? notes}) async {
    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    if (!isTestMode) {
      try {
        final url = Uri.parse('${ApiClient.baseUrl}/api/v1/site-admin/units/$unitId/move-out?site_id=$effectiveSiteId');
        final response = await ApiClient.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'notes': notes}),
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
              endDate: DateTime.now().toIso8601String().split('T').first,
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
    String tempPassword = 'SP-SAKIN-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}';

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

  void rejectRegistration(String requestId) {
    _pendingRegistrations = _pendingRegistrations.where((r) => r.id != requestId).toList();
    notify();
  }

  void clearApprovalSuccess() {
    _approvalSuccessInfo = null;
    notify();
  }

  void generateUnitInviteLink() {
    final token = 'SP-HANE-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}';
    final unitLabel = _activeUnit.displayLabel.isNotEmpty ? _activeUnit.displayLabel : 'Yetkili Bağımsız Bölüm';
    final siteSlug = _activeUnit.siteName.isNotEmpty ? _activeUnit.siteName.toLowerCase().replaceAll(' ', '-') : 'site';
    final unitId = _activeUnit.id.isNotEmpty ? _activeUnit.id : (_activeUnit.unitNumber.isNotEmpty ? _activeUnit.unitNumber : '1');
    _unitInviteInfo = UnitInviteInfo(
      inviteUrl: 'https://sitepulse.app/join/$siteSlug/units/$unitId?token=$token',
      token: token,
      unitLabel: unitLabel,
      expiresAtStr: '7 gün geçerli',
      securityNotice: 'Bu link sadece $unitLabel bağımsız bölümüne erişim yetkisi verir. Diğer daire veya yönetim yetkileri kapalıdır.',
    );
    notify();
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
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '';
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
          return {'success': false, 'message': utf8.decode(response.bodyBytes)};
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
