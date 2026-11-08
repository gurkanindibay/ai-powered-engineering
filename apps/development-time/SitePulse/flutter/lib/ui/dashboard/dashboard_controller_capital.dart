part of 'dashboard_controller.dart';

/// Capital expenditures, fixtures, contractor installments and disbursement tracking.
extension DashboardControllerCapital on DashboardController {
  Future<List<CapitalProjectItem>> fetchCapitalProjects({String? siteId}) async {
    _isLoadingCapitalProjects = true;
    _capitalProjectError = null;
    notify();

    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '';

    if (!isTestMode) {
      try {
        final uri = ApiClient.uri('/api/v1/capital-projects', {'site_id': effectiveSiteId});
        final response = await ApiClient.get(uri).timeout(const Duration(seconds: 4));
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
          notify();
          return _capitalProjects;
        }
      } catch (e) {
        debugPrint('fetchCapitalProjects error: $e');
      }
    }

    if (!isTestMode) {
      _capitalProjects = [];
      _activeCapitalProject = null;
      _capitalInstallments = [];
      _capitalDisbursements = [];
      _unitCapitalShares = [];
      _isLoadingCapitalProjects = false;
      notify();
      return _capitalProjects;
    }

    _capitalProjects = _getTestFixtureCapitalProjects();
    if (_capitalProjects.isNotEmpty) {
      _activeCapitalProject = _capitalProjects.first;
      _capitalInstallments = _getTestFixtureCapitalInstallments(_activeCapitalProject!.id);
      _unitCapitalShares = _getTestFixtureUnitCapitalShares(_activeCapitalProject!.id);
      _capitalDisbursements = _getTestFixtureCapitalDisbursements(_activeCapitalProject!.id);
    }
    _isLoadingCapitalProjects = false;
    notify();
    return _capitalProjects;
  }

  List<CapitalProjectItem> _getTestFixtureCapitalProjects() {
    return [
      CapitalProjectItem(
        id: '1',
        siteId: '1',
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

  List<CapitalProjectInstallmentItem> _getTestFixtureCapitalInstallments(String projectId) {
    return [
      CapitalProjectInstallmentItem(
        id: '1',
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
        id: '2',
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
        id: '3',
        projectId: projectId,
        installmentNumber: 3,
        totalInstallments: 4,
        dueDate: DateTime(2026, 11, 15),
        installmentBudget: Decimal.parse('30000.00'),
        percentage: Decimal.parse('25.00'),
        isAccrued: false,
      ),
      CapitalProjectInstallmentItem(
        id: '4',
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

  List<CapitalContractorDisbursementItem> _getTestFixtureCapitalDisbursements(String projectId) {
    return [
      CapitalContractorDisbursementItem(
        id: '1',
        projectId: projectId,
        milestoneName: '1. Hakediş: Halat ve Pano Değişimi',
        invoiceNumber: 'FAT-2026-089',
        amount: Decimal.parse('40000.00'),
        disbursementDate: DateTime(2026, 9, 2),
        recipientName: 'Schindler & Doğan Asansör Sanayi',
        recipientIban: 'TR560006200000012345678901',
        paymentReference: 'REF-HAKEDIS-01',
        disbursementMethod: 'BANK_TRANSFER',
        notes: 'Malzeme temini ve avans ödemesi',
        createdAt: DateTime(2026, 9, 2),
      ),
    ];
  }

  List<UnitCapitalShareItem> _getTestFixtureUnitCapitalShares(String projectId) {
    return [
      UnitCapitalShareItem(
        unitId: '1',
        block: 'A',
        unitNumber: 1,
        ownerName: 'Ali Kaya',
        landShare: 24,
        totalProjectShare: Decimal.parse('10000.00'),
        totalAccrued: Decimal.parse('5000.00'),
        totalPaid: Decimal.parse('5000.00'),
        remainingDebt: Decimal.zero,
        isSettled: true,
      ),
      UnitCapitalShareItem(
        unitId: '2',
        block: 'A',
        unitNumber: 2,
        ownerName: 'Mehmet Demir',
        landShare: 24,
        totalProjectShare: Decimal.parse('10000.00'),
        totalAccrued: Decimal.parse('5000.00'),
        totalPaid: Decimal.parse('2500.00'),
        remainingDebt: Decimal.parse('2500.00'),
        isSettled: false,
      ),
      UnitCapitalShareItem(
        unitId: '3',
        block: 'B',
        unitNumber: 1,
        ownerName: 'Ahmet Yılmaz',
        landShare: 24,
        totalProjectShare: Decimal.parse('10000.00'),
        totalAccrued: Decimal.parse('5000.00'),
        totalPaid: Decimal.zero,
        remainingDebt: Decimal.parse('5000.00'),
        isSettled: false,
      ),
    ];
  }

  Future<void> selectCapitalProject(CapitalProjectItem project) async {
    _activeCapitalProject = project;
    notify();
    await Future.wait([
      fetchCapitalInstallments(project.id),
      fetchCapitalDisbursements(project.id),
      fetchUnitCapitalShares(project.id),
    ]);
  }

  Future<List<CapitalProjectInstallmentItem>> fetchCapitalInstallments(String projectId) async {
    if (!isTestMode) {
      try {
        final uri = ApiClient.uri('/api/v1/capital-projects/$projectId/installments');
        final response = await ApiClient.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final raw = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
          _capitalInstallments = raw.map((e) => CapitalProjectInstallmentItem.fromJson(e as Map<String, dynamic>)).toList();
          notify();
          return _capitalInstallments;
        }
      } catch (e) {
        debugPrint('fetchCapitalInstallments error: $e');
      }
    }

    _capitalInstallments = isTestMode ? _getTestFixtureCapitalInstallments(projectId) : [];
    notify();
    return _capitalInstallments;
  }

  Future<List<CapitalContractorDisbursementItem>> fetchCapitalDisbursements(String projectId) async {
    if (!isTestMode) {
      try {
        final uri = ApiClient.uri('/api/v1/capital-projects/$projectId/disbursements');
        final response = await ApiClient.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final raw = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
          _capitalDisbursements = raw.map((e) => CapitalContractorDisbursementItem.fromJson(e as Map<String, dynamic>)).toList();
          notify();
          return _capitalDisbursements;
        }
      } catch (e) {
        debugPrint('fetchCapitalDisbursements error: $e');
      }
    }

    _capitalDisbursements = isTestMode ? _getTestFixtureCapitalDisbursements(projectId) : [];
    notify();
    return _capitalDisbursements;
  }

  Future<List<UnitCapitalShareItem>> fetchUnitCapitalShares(String projectId) async {
    if (!isTestMode) {
      try {
        final uri = ApiClient.uri('/api/v1/capital-projects/$projectId/unit-shares');
        final response = await ApiClient.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final raw = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
          _unitCapitalShares = raw.map((e) => UnitCapitalShareItem.fromJson(e as Map<String, dynamic>)).toList();
          notify();
          return _unitCapitalShares;
        }
      } catch (e) {
        debugPrint('fetchUnitCapitalShares error: $e');
      }
    }

    _unitCapitalShares = isTestMode ? _getTestFixtureUnitCapitalShares(projectId) : [];
    notify();
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
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '';
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
        final uri = ApiClient.uri('/api/v1/capital-projects');
        final response = await ApiClient.post(
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
      return null;
    }

    int maxProjId = 0;
    for (final p in _capitalProjects) {
      final parsed = int.tryParse(p.id);
      if (parsed != null && parsed > maxProjId) {
        maxProjId = parsed;
      }
    }
    final nextProjId = '${maxProjId > 0 ? maxProjId + 1 : _capitalProjects.length + 1}';

    final newProject = CapitalProjectItem(
      id: nextProjId,
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
          id: '${inst['installment_number']}',
          projectId: newProject.id,
          installmentNumber: inst['installment_number'] as int,
          totalInstallments: inst['total_installments'] as int,
          dueDate: DateTime.tryParse(inst['due_date']?.toString() ?? '') ?? DateTime.now(),
          installmentBudget: readDecimal(inst, 'installment_budget'),
          percentage: readDecimal(inst, 'percentage'),
          isAccrued: false,
        );
      }).toList();
    }
    notify();
    return newProject;
  }

  Future<Map<String, dynamic>> accrueCapitalInstallment(String projectId, int installmentNumber) async {
    final payload = {'installment_number': installmentNumber};

    if (!isTestMode) {
      try {
        final uri = ApiClient.uri('/api/v1/capital-projects/$projectId/accrue-installment');
        final response = await ApiClient.post(
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

    if (!isTestMode) {
      return {'success': false, 'message': 'Bağlantı hatası: Taksit tahakkuk ettirilemedi.'};
    }

    // Test mode fallback
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
      notify();
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
        final uri = ApiClient.uri('/api/v1/capital-projects/$projectId/disbursements');
        final response = await ApiClient.post(
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
      return null;
    }

    int maxDisbId = 0;
    for (final d in _capitalDisbursements) {
      final parsed = int.tryParse(d.id);
      if (parsed != null && parsed > maxDisbId) {
        maxDisbId = parsed;
      }
    }
    final nextDisbId = '${maxDisbId > 0 ? maxDisbId + 1 : _capitalDisbursements.length + 1}';

    final newDisbursement = CapitalContractorDisbursementItem(
      id: nextDisbId,
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
    notify();
    return newDisbursement;
  }

}
