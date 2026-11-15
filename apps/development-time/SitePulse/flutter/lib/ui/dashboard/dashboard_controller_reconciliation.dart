part of 'dashboard_controller.dart';

/// Bank account configuration, statement ingestion and automated/manual transaction reconciliation.
extension DashboardControllerReconciliation on DashboardController {
  // Site Bank Account Configuration (STORY-08-01)
  Future<void> fetchBankCatalog() async {
    if (_bankCatalog != null) return;
    try {
      final response = await ApiClient.get(
        ApiClient.uri('/api/v1/site-admin/banks'),
      ).timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return;
      final payload = json.decode(utf8.decode(response.bodyBytes));
      if (payload is! List) return;
      _bankCatalog = payload
          .whereType<Map<String, dynamic>>()
          .map(BankCatalogEntry.fromJson)
          .where((bank) => bank.code.isNotEmpty && bank.displayName.isNotEmpty)
          .toList(growable: false);
      notify();
    } catch (error) {
      AppLogger.warn('Fetch bank catalogue error', tag: 'ReconciliationController', error: error);
    }
  }

  bool configureBankAccount({
    required String bankCode,
    required String iban,
    required String accountHolder,
  }) {
    final bank = SupportedBank.fromCode(bankCode);
    if (bank == null) {
      _bankStatementError = 'Geçersiz banka kodu: $bankCode';
      notify();
      return false;
    }
    final cleanIban = iban.replaceAll(' ', '').toUpperCase();
    if (!cleanIban.startsWith('TR') || cleanIban.length != 26) {
      _bankStatementError = 'Geçersiz IBAN! Türk IBAN numarası TR ile başlamalı ve 26 haneli olmalıdır.';
      notify();
      return false;
    }
    if (accountHolder.trim().isEmpty) {
      _bankStatementError = 'Hesap sahibi adı / unvanı boş bırakılamaz.';
      notify();
      return false;
    }

    final effectiveSiteId = _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : '1');
    _siteBankAccount = SiteBankAccount(
      id: '1',
      siteId: effectiveSiteId,
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
    notify();

    if (!isTestMode) {
      _syncBankAccountToBackend(
        siteId: effectiveSiteId,
        bankCode: bank.code,
        iban: cleanIban,
        accountHolder: accountHolder.trim(),
      );
    }
    return true;
  }

  Future<void> fetchBankAccount([String? siteId]) async {
    if (isTestMode) return;
    final effectiveSiteId = siteId ?? _currentManagedSite?.id ?? (_activeUnit.siteId.isNotEmpty ? _activeUnit.siteId : null);
    if (effectiveSiteId == null || effectiveSiteId.isEmpty) return;
    try {
      final url = ApiClient.uri('/api/v1/site-admin/bank-account/$effectiveSiteId');
      final response = await ApiClient.get(url).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        _siteBankAccount = SiteBankAccount.fromJson(data);
        notify();
      } else if (response.statusCode == 404) {
        _siteBankAccount = null;
        notify();
      }
    } catch (e) {
      AppLogger.warn('Fetch bank account error', tag: 'ReconciliationController', error: e);
    }
  }

  Future<void> _syncBankAccountToBackend({
    required String siteId,
    required String bankCode,
    required String iban,
    required String accountHolder,
  }) async {
    try {
      final url = ApiClient.uri('/api/v1/site-admin/bank-account/$siteId');
      final response = await ApiClient.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'bank_code': bankCode,
          'iban': iban,
          'account_holder': accountHolder,
          'configured_by': _userSession.id,
        }),
      ).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        if (data['id'] != null) {
          _siteBankAccount = SiteBankAccount.fromJson(data);
          notify();
        }
      }
    } catch (e) {
      AppLogger.warn('Sync bank account error', tag: 'ReconciliationController', error: e);
    }
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
          notify();
          return false;
        }
        // Verify not MT940 disguised as Excel
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.contains(':20:') && text.contains(':61:')) {
          _bankStatementError = 'Format Reddedildi: ${_siteBankAccount!.bankName} hesabı Excel (.xlsx) formatı gerektirir. SWIFT MT940 formatındaki dosya ($fileName) reddedildi.';
          _reconciliationQueue = [];
          notify();
          return false;
        }
      } else if (expectedFormat == 'MT940') {
        if (!ext.endsWith('.sta') && !ext.endsWith('.txt') && !ext.endsWith('.mt940')) {
          _bankStatementError = 'Format Reddedildi: ${_siteBankAccount!.bankName} hesabı yalnızca SWIFT MT940 (.sta / .txt / .mt940) dosyalarını kabul eder. Yüklenen dosya ($fileName) reddedildi.';
          _reconciliationQueue = [];
          notify();
          return false;
        }
        // Verify content contains MT940 tags
        final text = utf8.decode(bytes, allowMalformed: true);
        if (!text.contains(':61:') || !text.contains(':86:')) {
          _bankStatementError = 'Format Reddedildi: ${_siteBankAccount!.bankName} hesabı için yüklenen dosya geçerli SWIFT MT940 formatında değil (:61:, :86: etiketleri bulunamadı). Dosya reddedildi.';
          _reconciliationQueue = [];
          notify();
          return false;
        }
      } else if (expectedFormat == 'CSV') {
        if (!ext.endsWith('.csv') && !ext.endsWith('.txt')) {
          _bankStatementError = 'Format Reddedildi: ${_siteBankAccount!.bankName} hesabı yalnızca CSV (.csv) dosyalarını kabul eder. Yüklenen dosya ($fileName) reddedildi.';
          _reconciliationQueue = [];
          notify();
          return false;
        }
        // Verify user didn't upload MT940 into CSV bank
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.contains(':20:') && text.contains(':61:')) {
          _bankStatementError = 'Format Reddedildi: ${_siteBankAccount!.bankName} hesabı CSV formatı gerektirir. Yüklenen dosya SWIFT MT940 formatında olduğu için reddedildi.';
          _reconciliationQueue = [];
          notify();
          return false;
        }
      }
    }

    final rows = BankFileParser.parseBytes(fileName: fileName, bytes: bytes);
    if (rows.isEmpty) {
      _bankStatementError = 'Format Reddedildi: Yüklenen dosya ($fileName) ${_siteBankAccount?.bankName ?? "ilgili banka"} formatına uygun hareket içermediği için reddedildi.';
      _reconciliationQueue = [];
      notify();
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
    notify();
    return true;
  }

  bool parseBankStatement(String content, {String format = 'AUTO'}) {
    _bankStatementError = null;
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      _bankStatementError = 'Format Reddedildi: Ekstre içeriği boş.';
      _reconciliationQueue = [];
      notify();
      return false;
    }

    final isMt940 = trimmed.startsWith(':20:') || BankFileParser.isMt940(trimmed);

    // Enforce statement format from active bank or explicit format parameter
    final activeAccount = _siteBankAccount;
    final targetFormat = format != 'AUTO'
        ? format
        : (activeAccount?.statementFormat ?? 'AUTO');

    if (targetFormat != 'AUTO') {
      if (targetFormat == 'MT940' && !isMt940) {
        _bankStatementError = 'Format Reddedildi: ${activeAccount?.bankName ?? "Seçili banka"} hesabı SWIFT MT940 (:61:, :86:) formatı gerektirir. Yapıştırılan içerik MT940 formatında olmadığı için reddedildi.';
        _reconciliationQueue = [];
        notify();
        return false;
      } else if (targetFormat == 'EXCEL' && isMt940) {
        _bankStatementError = 'Format Reddedildi: ${activeAccount?.bankName ?? "Seçili banka"} hesabı Excel (.xlsx) formatı gerektirir. SWIFT MT940 formatındaki içerik reddedildi.';
        _reconciliationQueue = [];
        notify();
        return false;
      } else if (targetFormat == 'CSV' && isMt940) {
        _bankStatementError = 'Format Reddedildi: ${activeAccount?.bankName ?? "Seçili banka"} hesabı CSV (.csv) formatı gerektirir. SWIFT MT940 formatındaki içerik reddedildi.';
        _reconciliationQueue = [];
        notify();
        return false;
      }
    }

    // One parser for pasted text and uploaded files: MT940, CSV/TSV and
    // free-form lines all go through BankFileParser.
    final List<ReconciliationQueueItem> parsedMatches = [];
    final parsedRows = BankFileParser.parseText(content);
    for (int i = 0; i < parsedRows.length; i++) {
      final r = parsedRows[i];
      parsedMatches.add(_matchTransactionToRoster(
        description: r.description,
        amount: r.amount,
        date: r.date,
        rawId: r.rawId.isNotEmpty ? r.rawId : 'TXN-ROW-${i + 1}',
        explicitSender: r.senderName,
        isIncoming: r.isIncoming,
      ));
    }

    if (parsedMatches.isEmpty) {
      _bankStatementError = 'Format Reddedildi: İçerikte ${activeAccount?.bankName ?? "ilgili banka"} formatına uygun işlem satırı bulunamadı.';
      _reconciliationQueue = [];
      notify();
      return false;
    }

    _reconciliationQueue = parsedMatches;
    notify();
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
        final payerNames = [f.residentName, ...f.registeredPayerNames]
            .map(normalizeTr)
            .where((name) => name.isNotEmpty);
        if (payerNames.any((name) =>
            (normSender.isNotEmpty && normSender.contains(name)) ||
            normDesc.contains(name))) {
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
          ? 'Aktif aidat borcu bulunmuyor • ${formatTry(amount)} tutarındaki ödeme avans bakiyesi (Avans Bakiye) olarak eşleştirildi.'
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
    notify();
  }

  Future<void> confirmReconciliation(
    List<String> matchIds, {
    String? optionalHostMessage,
    bool rememberSenderIban = true,
  }) async {
    if (matchIds.isEmpty) return;
    if (!isTestMode) {
      try {
        final uri = ApiClient.uri('/api/v1/bank/statements/confirm-reconciliation');
        final siteId = _currentManagedSite?.id ?? _activeUnit.siteId;
        final selectedMatches = _reconciliationQueue
            .where((item) => matchIds.contains(item.matchId))
            .map((item) => item.toJson(siteId))
            .toList();
        final response = await ApiClient.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'site_id': siteId,
            'match_ids': matchIds,
            'matches': selectedMatches,
            'remember_sender_iban': rememberSenderIban,
            'optional_message': optionalHostMessage,
          }),
        ).timeout(const Duration(seconds: 5));
        if (response.statusCode != 200 && response.statusCode != 204) {
          AppLogger.warn(
            'confirmReconciliation remote rejected',
            tag: 'ReconciliationController',
            context: {'status': response.statusCode},
          );
          return;
        }
      } catch (e) {
        AppLogger.error('confirmReconciliation remote error', tag: 'ReconciliationController', error: e);
        return;
      }
    }

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
        '${formatTry(totalCleared)} tutarındaki banka aidat transferi başarıyla onaylandı$messageNote$ibanNote.';
    notify();

    if (isTestMode) return;

    // Refresh live site overview from backend
    try {
      await fetchSiteManagerOverview(
        siteId: _currentManagedSite?.id,
        period: _selectedDuesMonth,
      );
      await fetchReconciliationQueue(_currentManagedSite?.id ?? _activeUnit.siteId);
    } catch (e) {
      AppLogger.warn('Overview refresh after reconciliation error', tag: 'ReconciliationController', error: e);
    }
  }

  Future<void> _persistRememberedSenderIban({
    required String unitId,
    required String senderIban,
    String? senderName,
  }) async {
    if (isTestMode) return;
    try {
      final url = ApiClient.uri('/api/v1/bank/remembered-ibans');
      await ApiClient.post(
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
    final isCard = paymentMethod == 'CREDIT_CARD';
    if (!isTestMode) {
      try {
        final url = ApiClient.uri('/api/v1/payments/record');
        final response = await ApiClient.post(
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

        if (response.statusCode != 200 && response.statusCode != 201) {
          AppLogger.warn(
            'recordHomeownerPayment rejected',
            tag: 'ReconciliationController',
            context: {'status': response.statusCode},
          );
          return;
        }
        await fetchResidentDashboard(_activeUnit.id);
        if (_currentManagedSite?.id.isNotEmpty == true || _userSession.role == UserRole.siteManager) {
          await fetchSiteManagerOverview(
            siteId: _currentManagedSite?.id,
            period: _selectedDuesMonth,
          );
        }
      } catch (e) {
        AppLogger.error('recordHomeownerPayment backend sync error', tag: 'ReconciliationController', error: e);
        return;
      }
    }

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

    final txTitle = isCard
        ? (clearedDebt > Decimal.zero ? 'Kart ile Aidat Ödemesi' : 'Kart ile Avans Yükleme')
        : (clearedDebt > Decimal.zero ? 'FAST ile Aidat Ödemesi' : 'FAST ile Avans Yükleme');

    final txSubtitle = advanceCredit > Decimal.zero && clearedDebt > Decimal.zero
        ? '${formatTry(clearedDebt)} borç kapatıldı • ${formatTry(advanceCredit)} avans bakiyenize aktarıldı'
        : (clearedDebt > Decimal.zero ? 'Aidat borcu başarıyla kapatıldı' : 'Aktif borç bulunmuyor • Avans bakiyenize aktarıldı');

    final tempTxId = 'draft-${_accountTransactions.length + 1}';
    _accountTransactions.insert(
      0,
      AccountTransactionItem(
        id: tempTxId,
        title: txTitle,
        subtitle: txSubtitle,
        amount: amount,
        date: 'Bugün',
        isCredit: true,
      ),
    );

    notify();
  }

  void clearReconciliationSuccess() {
    _reconciliationSuccessMessage = null;
    notify();
  }


}
