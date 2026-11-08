part of 'dashboard_controller.dart';

/// Matching criteria, treasury payment stream, debt aging analytics and receipts.
extension DashboardControllerPayments on DashboardController {
  Future<void> fetchUnitMatchingCriteria([String? unitId]) async {
    final effectiveUnitId = unitId ?? (_activeUnit.id.isNotEmpty ? _activeUnit.id : null);
    if (effectiveUnitId == null || effectiveUnitId.isEmpty) return;
    try {
      final url = ApiClient.uri('/api/v1/residents/$effectiveUnitId/matching-criteria');
      final response = await ApiClient.get(url).timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        _matchingCriteria = UnitMatchingCriteria.fromJson(data);
        notify();
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
      final url = ApiClient.uri('/api/v1/residents/$effectiveUnitId/matching-criteria/ibans');
      final response = await ApiClient.post(
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
        notify();
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
    notify();
  }

  Future<void> deleteSenderIbanFromUnit({
    required String iban,
    String? unitId,
  }) async {
    final effectiveUnitId = unitId ?? (_activeUnit.id.isNotEmpty ? _activeUnit.id : null);
    if (effectiveUnitId == null || effectiveUnitId.isEmpty) return;
    final clean = iban.replaceAll(' ', '').toUpperCase();
    try {
      final url = ApiClient.uri('/api/v1/residents/$effectiveUnitId/matching-criteria/ibans/$clean');
      final response = await ApiClient.delete(url).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        _matchingCriteria = UnitMatchingCriteria.fromJson(data);
        notify();
        return;
      }
    } catch (e) {
      debugPrint('deleteSenderIbanFromUnit remote error: $e');
    }

    // Local fallback
    final currentList = List<RegisteredSenderIban>.from(_matchingCriteria?.rememberedIbans ?? []);
    currentList.removeWhere((i) => i.senderIban == clean);
    _matchingCriteria = _matchingCriteria?.copyWith(rememberedIbans: currentList);
    notify();
  }

  Future<void> updateUnitPayerNames({
    required List<String> names,
    String? unitId,
  }) async {
    final effectiveUnitId = unitId ?? (_activeUnit.id.isNotEmpty ? _activeUnit.id : null);
    if (effectiveUnitId == null || effectiveUnitId.isEmpty) return;
    try {
      final url = ApiClient.uri('/api/v1/residents/$effectiveUnitId/matching-criteria/payer-names');
      final response = await ApiClient.put(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'payer_names': names}),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        _matchingCriteria = UnitMatchingCriteria.fromJson(data);
        notify();
        return;
      }
    } catch (e) {
      debugPrint('updateUnitPayerNames remote error: $e');
    }

    // Local fallback
    _matchingCriteria = _matchingCriteria?.copyWith(registeredPayerNames: names);
    notify();
  }


  Future<PaymentStreamResponseDto> fetchPaymentStream({
    String? channel,
    String? payerRole,
    String? settlementStatus,
    String? unitId,
    String? search,
    String? siteId,
  }) async {
    _isPaymentStreamLoading = true;
    notify();

    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '';
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
        final uri = ApiClient.uri('/api/v1/payments/stream', queryParams);
        final response = await ApiClient.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final jsonMap = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          _paymentStream = PaymentStreamResponseDto.fromJson(jsonMap);
          _isPaymentStreamLoading = false;
          notify();
          return _paymentStream!;
        }
      } catch (e) {
        debugPrint('fetchPaymentStream error: $e');
      }
    }

    if (isTestMode) {
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
        totalCount: 3,
      );
      _isPaymentStreamLoading = false;
      notify();
      return _paymentStream!;
    }

    _paymentStream = PaymentStreamResponseDto(
      entries: const [],
      totalVolume: Decimal.zero,
      settledVolume: Decimal.zero,
      unmatchedVolume: Decimal.zero,
      totalCount: 0,
    );
    _isPaymentStreamLoading = false;
    notify();
    return _paymentStream!;
  }

  Future<DebtAgingReportDto> fetchDebtAgingReport({String? siteId}) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '';
    if (!isTestMode) {
      try {
        final uri = Uri.parse('${ApiClient.baseUrl}/api/v1/payments/debt-aging?site_id=$effectiveSiteId');
        final response = await ApiClient.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final jsonMap = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          _debtAgingReport = DebtAgingReportDto.fromJson(jsonMap);
          notify();
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
    notify();
    return _debtAgingReport!;
  }

  Future<PaymentReceiptDto?> recordManualPayment({
    required String unitId,
    required Decimal amount,
    required String payerName,
    required String payerRole,
    required String paymentChannel,
    String? description,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '';
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
        final uri = ApiClient.uri('/api/v1/payments/record-manual');
        final response = await ApiClient.postIdempotent(uri, body: json.encode(payload));

        if (response.statusCode == 201 || response.statusCode == 200) {
          final jsonMap = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          final receipt = PaymentReceiptDto.fromJson(jsonMap);
          await fetchPaymentStream(siteId: effectiveSiteId);
          await fetchDebtAgingReport(siteId: effectiveSiteId);
          return receipt;
        }
        debugPrint('recordManualPayment rejected: ${response.statusCode} ${utf8.decode(response.bodyBytes)}');
      } catch (e) {
        debugPrint('recordManualPayment error: $e');
      }
      // Never show a receipt for a payment the server did not confirm.
      return null;
    }

    final receipt = PaymentReceiptDto(
      id: 99,
      siteId: effectiveSiteId,
      unitId: unitId,
      receiptNumber: 'TAH-2026-000099',
      sequenceNumber: 99,
      payerName: payerName,
      payerRole: payerRole,
      totalAmount: amount,
      paymentChannel: paymentChannel,
      allocatedPrincipal: amount,
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
    required Decimal amount,
    String? note,
    String? siteId,
  }) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '';
    final payload = {
      'site_id': effectiveSiteId,
      'unit_id': unitId,
      'amount': amount.toStringAsFixed(2),
      'note': note,
    };

    if (!isTestMode) {
      try {
        final uri = ApiClient.uri('/api/v1/payments/inter-ledger-transfer');
        final response = await ApiClient.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: json.encode(payload),
        ).timeout(const Duration(seconds: 8));

        if (response.statusCode == 200) {
          final res = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          await fetchPaymentStream(siteId: effectiveSiteId);
          await fetchDebtAgingReport(siteId: effectiveSiteId);
          return res;
        }
        debugPrint('executeInterLedgerTransfer rejected: ${response.statusCode}');
      } catch (e) {
        debugPrint('executeInterLedgerTransfer error: $e');
      }
      return null;
    }

    return {
      'success': true,
      'message': '${formatTry(amount)} avans bakiyesinden demirbaş borcuna başarıyla aktarıldı.',
      'receipt_number': 'TAH-2026-000101',
      'remaining_advance_balance': '500.00',
    };
  }

  Future<PaymentReceiptDto?> fetchReceipt(String identifier, {String? siteId}) async {
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? '';
    if (!isTestMode) {
      try {
        final uri = Uri.parse('${ApiClient.baseUrl}/api/v1/payments/receipts/$identifier?site_id=$effectiveSiteId');
        final response = await ApiClient.get(uri).timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final jsonMap = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          _selectedReceipt = PaymentReceiptDto.fromJson(jsonMap);
          notify();
          return _selectedReceipt;
        }
      } catch (e) {
        debugPrint('fetchReceipt error: $e');
      }
      return null;
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
    notify();
    return _selectedReceipt;
  }


}
