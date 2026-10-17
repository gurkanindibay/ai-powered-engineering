import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../domain/models/dues_models.dart';
import '../../domain/services/bank_file_picker.dart';
import '../dashboard/dashboard_controller.dart';
import '../theme/app_theme.dart';
import 'app_fullscreen_page.dart';
import 'bank_statement_reconciliation_page.dart';
import 'manual_unit_assignment_page.dart';

class DuesManagementView extends StatefulWidget {
  final DashboardController controller;

  const DuesManagementView({
    super.key,
    required this.controller,
  });

  @override
  State<DuesManagementView> createState() => _DuesManagementViewState();
}

class _DuesManagementViewState extends State<DuesManagementView> {
  // 0: Daire Aidat Durumları, 1: Eşleşmeyen Banka Hareketleri
  int _activeSegment = 0;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.fetchReconciliationQueue();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _nextMonth() {
    final months = widget.controller.availableDuesMonths;
    final currentIdx = months.indexOf(widget.controller.selectedDuesMonth);
    if (currentIdx > 0) {
      widget.controller.setSelectedDuesMonth(months[currentIdx - 1]);
    }
  }

  void _prevMonth() {
    final months = widget.controller.availableDuesMonths;
    final currentIdx = months.indexOf(widget.controller.selectedDuesMonth);
    if (currentIdx != -1 && currentIdx < months.length - 1) {
      widget.controller.setSelectedDuesMonth(months[currentIdx + 1]);
    }
  }

  Future<void> _handleFileUpload() async {
    final activeAccount = widget.controller.siteBankAccount;
    final acceptFilter = activeAccount?.supportedBank?.fileExtension;
    final picked = await pickBankFile(accept: acceptFilter);
    if (picked != null) {
      final success = widget.controller.parseBankStatementFile(
        fileName: picked.name,
        bytes: picked.bytes,
      );
      if (!success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.controller.bankStatementError ?? 'Format uyuşmazlığı nedeniyle dosya reddedildi.',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              backgroundColor: AppColors.accentRed,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }
      if (mounted) {
        _showImportSummaryModal(picked.name);
      }
    }
  }

  void _handlePresetUpload(String name, String content) {
    final success = widget.controller.parseBankStatement(content);
    if (!success) {
      if (mounted && widget.controller.bankStatementError != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.controller.bankStatementError!,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            backgroundColor: AppColors.accentRed,
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }
    _showImportSummaryModal(name);
  }

  void _showImportOptionsDialog() {
    final isDark = AppColors.isDark(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Banka Ekstresi / Excel İçe Aktar',
                      style: TextStyle(
                        color: AppColors.textPrimary(context),
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Kuveyt Türk (.xlsx), İş Bankası (.xls / .csv) veya MT940 formatlarını seçin:',
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accentCyan.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.file_upload_outlined, color: AppColors.accentCyan),
                  ),
                  title: const Text('Cihazdan Dosya Seç (.xlsx, .xls, .csv)', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Kuveyt Türk, İş Bankası, Garanti vb.'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _handleFileUpload();
                  },
                ),
                const Divider(),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.receipt_long, color: AppColors.accentGreen),
                  ),
                  title: const Text('Kuveyt Türk Test Ekstresi Yükle', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('8 gerçek hareket (Alaettin Çelik, Sait Şener, vb.)'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _handlePresetUpload('Kuveyt Türk (.xlsx)', BankStatementReconciliationPage.sampleKuveytTurkExcel);
                  },
                ),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accentOrange.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.credit_card, color: AppColors.accentOrange),
                  ),
                  title: const Text('İş Bankası Test Ekstresi Yükle', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('4 ATM ve virman hareketi'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _handlePresetUpload('İş Bankası (.xls)', BankStatementReconciliationPage.sampleIsBankExcel);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showImportSummaryModal(String fileName) {
    final queue = widget.controller.reconciliationQueue;
    final matchedItems = queue.where((q) => q.confidenceScore >= 70 && q.status != 'GIDER').toList();
    final unmatchedItems = queue.where((q) => q.status == 'ESLESTIRILEMEDI').toList();
    final expenseItems = queue.where((q) => q.status == 'GIDER').toList();

    Decimal matchedSum = Decimal.zero;
    for (final m in matchedItems) {
      matchedSum += m.transaction.amount;
    }

    Decimal unmatchedSum = Decimal.zero;
    for (final u in unmatchedItems) {
      unmatchedSum += u.transaction.amount;
    }

    final isDark = AppColors.isDark(context);

    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.accentCyan.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.analytics_outlined, color: AppColors.accentCyan, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'İçe Aktarma Ara Sonucu',
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            fileName,
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Breakdown Cards
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.accentGreen.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.accentGreen.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.check_circle, color: AppColors.accentGreen, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Eşleşen Daireler (${matchedItems.length})',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.accentGreen, fontSize: 13),
                          ),
                        ],
                      ),
                      Text(
                        '₺${matchedSum.toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.accentGreen, fontSize: 14),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.accentOrange.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.accentOrange.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.help_outline, color: AppColors.accentOrange, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Eşleşemeyen (${unmatchedItems.length})',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.accentOrange, fontSize: 13),
                          ),
                        ],
                      ),
                      Text(
                        '₺${unmatchedSum.toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.accentOrange, fontSize: 14),
                      ),
                    ],
                  ),
                ),
                if (expenseItems.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.withOpacity(0.3)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.receipt_long, color: Colors.blueGrey, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              'Gider / Masraf (${expenseItems.length})',
                              style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.blueGrey, fontSize: 12),
                            ),
                          ],
                        ),
                        const Text(
                          'Aidattan Düşüldü',
                          style: TextStyle(color: Colors.blueGrey, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                // Actions
                if (matchedItems.isNotEmpty)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        final ids = matchedItems.map((m) => m.matchId).toList();
                        widget.controller.confirmReconciliation(ids);
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${matchedItems.length} dairenin aidat tahsilatı onaylandı!'),
                            backgroundColor: AppColors.accentGreen,
                          ),
                        );
                      },
                      icon: const Icon(Icons.done_all, size: 16),
                      label: Text('Eşleşenleri Onayla & Kaydet (${matchedItems.length})'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accentGreen,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (unmatchedItems.isNotEmpty)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            setState(() {
                              _activeSegment = 1; // Switch to unmatched pool tab
                            });
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.accentOrange,
                            side: const BorderSide(color: AppColors.accentOrange),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          child: const Text('Eşleşmeyenleri Gör', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                    if (unmatchedItems.isNotEmpty) const SizedBox(width: 8),
                    Expanded(
                      child: TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          AppFullscreenPage.push(
                            context: context,
                            builder: (_) => BankStatementReconciliationPage(controller: widget.controller),
                          );
                        },
                        child: const Text('Tam Ekran Detay', style: TextStyle(fontSize: 12, color: AppColors.accentCyan)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openManualAssignment(ReconciliationQueueItem item) async {
    final result = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => ManualUnitAssignmentPage(
          item: item,
          flats: widget.controller.flatsList,
        ),
      ),
    );

    if (result != null) {
      final FlatPaymentStatus selectedFlat = (result is ManualAssignmentResult)
          ? result.flat
          : (result as FlatPaymentStatus);
      final bool sendMsg = (result is ManualAssignmentResult) ? result.sendOptionalMessage : false;
      final String? msgText = (result is ManualAssignmentResult) ? result.optionalMessageText : null;
      final bool rememberIban = (result is ManualAssignmentResult) ? result.rememberSenderIban : true;

      widget.controller.manuallyAssignFlatToTransaction(
        matchId: item.matchId,
        block: selectedFlat.block,
        unitNo: selectedFlat.unitNo,
      );
      // Auto confirm if manager chooses with optional message to host and remember sender IBAN
      widget.controller.confirmReconciliation(
        [item.matchId],
        optionalHostMessage: sendMsg ? msgText : null,
        rememberSenderIban: rememberIban,
      );

      if (mounted) {
        final msgNote = (sendMsg && msgText != null && msgText.trim().isNotEmpty)
            ? ' Ev sahibine (${selectedFlat.residentName}) bilgilendirme mesajı iletildi.'
            : '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${item.transaction.senderName ?? "İşlem"} -> ${selectedFlat.block} Blok D:${selectedFlat.unitNo} (${selectedFlat.residentName}) ile eşleştirildi ve onaylandı!$msgNote',
            ),
            backgroundColor: AppColors.accentGreen,
          ),
        );
      }
    }
  }

  Future<void> _showAccrueDuesDialog() async {
    final selectedMonth = widget.controller.selectedDuesMonth;
    final isDark = AppColors.isDark(context);

    await showDialog(
      context: context,
      builder: (ctx) {
        bool isSubmitting = false;

        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: isDark ? AppColors.darkCard : AppColors.lightCard,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.event_repeat, color: AppColors.accentGreen, size: 22),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Toplu Aidat Tahakkuku',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tüm bağımsız bölümler için aylık aidat borç tahakkukunu başlatın.',
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border(context)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Tahakkuk Dönemi:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13)),
                            Text(selectedMonth, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Daire Başı Aidat:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13)),
                            const Text('₺1.400,00', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.accentGreen, fontSize: 13)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Son Ödeme Tarihi:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13)),
                            const Text('15.10.2026', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.accentCyan.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.accentCyan.withOpacity(0.2)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline, color: AppColors.accentCyan, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Avans bakiyesi bulunan daireler tahakkuk anında otomatik olarak mahsup edilecektir. Mükerrer tahakkuklar sistem tarafından engellenir.',
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 11,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isSubmitting ? null : () => Navigator.pop(dialogCtx),
                  child: const Text('Vazgeç'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentGreen,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          setDialogState(() => isSubmitting = true);
                          final result = await widget.controller.accrueMonthlyDues(
                            period: selectedMonth,
                          );
                          if (mounted) {
                            Navigator.pop(dialogCtx);
                            final alreadyAccrued = result['already_accrued'] == true;
                            final msg = result['message'] as String? ?? '';
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Row(
                                  children: [
                                    Icon(
                                      alreadyAccrued ? Icons.info_outline : Icons.check_circle,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        msg,
                                        style: const TextStyle(fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),
                                backgroundColor:
                                    alreadyAccrued ? AppColors.accentOrange : AppColors.accentGreen,
                                duration: const Duration(seconds: 4),
                              ),
                            );
                          }
                        },
                  child: isSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Tahakkuk Ettir'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppColors.isDark(context);
    final summary = widget.controller.currentMonthSummary;
    final selectedMonth = widget.controller.selectedDuesMonth;
    final unmatchedItems = widget.controller.unmatchedBankTransactions;

    // Filtered flats for the month
    final flats = widget.controller.currentMonthFlats.where((f) {
      if (_searchQuery.isEmpty) return true;
      final query = _searchQuery.toLowerCase();
      final desc = f.flatDesc.toLowerCase();
      final name = f.residentName.toLowerCase();
      return desc.contains(query) || name.contains(query);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Header: Month Selector & Upload Button
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            // Month Selector Pill
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left, size: 20),
                    visualDensity: VisualDensity.compact,
                    onPressed: _prevMonth,
                  ),
                  PopupMenuButton<String>(
                    initialValue: selectedMonth,
                    onSelected: (m) => widget.controller.setSelectedDuesMonth(m),
                    itemBuilder: (ctx) => widget.controller.availableDuesMonths.map((m) {
                      return PopupMenuItem<String>(
                        value: m,
                        child: Text(m, style: TextStyle(fontWeight: m == selectedMonth ? FontWeight.bold : FontWeight.normal)),
                      );
                    }).toList(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_month_outlined, size: 16, color: AppColors.accentCyan),
                          const SizedBox(width: 6),
                          Text(
                            selectedMonth,
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.arrow_drop_down, size: 18),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right, size: 20),
                    visualDensity: VisualDensity.compact,
                    onPressed: _nextMonth,
                  ),
                ],
              ),
            ),

            // Action Buttons: Accrue Dues & Import Bank File
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: _showAccrueDuesDialog,
                  icon: const Icon(Icons.event_repeat, size: 16),
                  label: const Text('Toplu Aidat Tahakkuku'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _showImportOptionsDialog,
                  icon: const Icon(Icons.upload_file, size: 16),
                  label: const Text('Excel / Ekstre Yükle'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentCyan,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => widget.controller.resetAllDemoData(),
                  icon: const Icon(Icons.refresh, size: 16, color: AppColors.accentRed),
                  label: const Text('Sıfırla (₺0)', style: TextStyle(color: AppColors.accentRed, fontWeight: FontWeight.bold)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.accentRed),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ],
        ),

        const SizedBox(height: 16),

        // 2. Monthly Financial KPI Summary Card
        Container(
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
            gradient: isDark
                ? const LinearGradient(
                    colors: [Color(0xFF1E293B), Color(0xFF121317)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
              width: 1.5,
            ),
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '$selectedMonth Tahsilat Performansı',
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      summary.totalExpected == Decimal.zero
                          ? '₺0 Borç — Güncel'
                          : '%${summary.collectionPercentage} Tahsil Edildi',
                      style: const TextStyle(color: AppColors.accentGreen, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '₺${summary.totalCollected.toStringAsFixed(0)}',
                    style: TextStyle(color: AppColors.textPrimary(context), fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '/ ₺${summary.totalExpected.toStringAsFixed(0)} Toplam',
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: summary.totalExpected == Decimal.zero ? 0.0 : summary.collectionPercentage / 100.0,
                  backgroundColor: AppColors.card(context),
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accentGreen),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 14),
              // 4 Person/Count Metrics Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildStatTile('Toplam Daire', '${summary.totalUnitsCount}', AppColors.textPrimary(context)),
                  _buildStatTile('Ödeyen Kişi', '${summary.paidUnitsCount} Daire', AppColors.accentGreen),
                  _buildStatTile('Ödemeyen / Geciken', '${summary.overdueUnitsCount} Daire', AppColors.accentRed),
                  _buildStatTile('Kalan Borç', '₺${summary.totalOverdueAmount.toStringAsFixed(0)}', AppColors.accentOrange),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),

        // 3. Segmented Navigation: [ Daire Aidat Durumları ] vs [ Eşleşmeyen Banka Hareketleri ]
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _activeSegment = 0),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: _activeSegment == 0 ? AppColors.accentCyan : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '📋 Daire Aidat Durumları',
                      style: TextStyle(
                        color: _activeSegment == 0 ? Colors.white : AppColors.textSecondary(context),
                        fontSize: 13,
                        fontWeight: _activeSegment == 0 ? FontWeight.bold : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _activeSegment = 1),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: _activeSegment == 1 ? AppColors.accentCyan : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '🏦 Eşleşmeyenler',
                          style: TextStyle(
                            color: _activeSegment == 1 ? Colors.white : AppColors.textSecondary(context),
                            fontSize: 13,
                            fontWeight: _activeSegment == 1 ? FontWeight.bold : FontWeight.w500,
                          ),
                        ),
                        if (unmatchedItems.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: _activeSegment == 1 ? Colors.white : AppColors.accentOrange,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${unmatchedItems.length}',
                              style: TextStyle(
                                color: _activeSegment == 1 ? AppColors.accentCyan : Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // 4. Alert Banner if in Segment 0 and Unmatched Items Exist
        if (_activeSegment == 0 && unmatchedItems.isNotEmpty) ...[
          InkWell(
            onTap: () => setState(() => _activeSegment = 1),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.accentOrange.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accentOrange.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: AppColors.accentOrange, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Banka hesabında henüz daireyle eşleşmemiş ${unmatchedItems.length} adet transfer bulunuyor. Daireleri belirlemek için tıklayın.',
                      style: const TextStyle(
                        color: AppColors.accentOrange,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios, size: 12, color: AppColors.accentOrange),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],

        // 5. Segment Content
        if (_activeSegment == 0)
          _buildFlatsDuesSection(flats)
        else
          _buildUnmatchedBankTransactionsSection(unmatchedItems),
      ],
    );
  }

  Widget _buildStatTile(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: AppColors.textSecondary(context), fontSize: 10)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildFlatsDuesSection(List<FlatPaymentStatus> flats) {
    final currentFilter = widget.controller.flatFilter;
    final totalCount = widget.controller.currentMonthFlats.length;
    final paidCount = widget.controller.currentMonthSummary.paidUnitsCount;
    final overdueCount = widget.controller.currentMonthSummary.overdueUnitsCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Filter Chips & Search Bar
        Row(
          children: [
            _buildFilterChip('Tümü ($totalCount)', 'ALL', currentFilter),
            const SizedBox(width: 6),
            _buildFilterChip('🟢 Ödeyen ($paidCount)', 'PAID', currentFilter),
            const SizedBox(width: 6),
            _buildFilterChip('🔴 Geciken ($overdueCount)', 'OVERDUE', currentFilter),
          ],
        ),

        const SizedBox(height: 10),

        // Search Input
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: TextField(
            controller: _searchController,
            onChanged: (val) => setState(() => _searchQuery = val),
            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
            decoration: InputDecoration(
              icon: const Icon(Icons.search, size: 18),
              hintText: 'Daire No veya Sakin Adı ile Ara...',
              hintStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
              border: InputBorder.none,
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
            ),
          ),
        ),

        const SizedBox(height: 12),

        // Flats List
        if (flats.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Center(
              child: Text(
                'Filtreye uygun daire bulunmuyor.',
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
              ),
            ),
          )
        else
          ...flats.map((flat) => _buildFlatStatusCard(flat)),
      ],
    );
  }

  Widget _buildFilterChip(String label, String filterKey, String currentFilter) {
    final isSelected = currentFilter == filterKey;
    return InkWell(
      onTap: () => widget.controller.setFlatFilter(filterKey),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accentCyan : AppColors.surface(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isSelected ? AppColors.accentCyan : AppColors.border(context)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : AppColors.textPrimary(context),
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildFlatStatusCard(FlatPaymentStatus flat) {
    final isDark = AppColors.isDark(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: flat.isPaid ? AppColors.accentGreen.withOpacity(0.3) : AppColors.accentRed.withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: flat.isPaid ? AppColors.accentGreen.withOpacity(0.15) : AppColors.accentRed.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  flat.isPaid ? Icons.check : Icons.priority_high,
                  color: flat.isPaid ? AppColors.accentGreen : AppColors.accentRed,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    flat.flatDesc,
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    flat.residentName,
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '₺${flat.amountDue.toStringAsFixed(2)}',
                style: TextStyle(
                  color: AppColors.textPrimary(context),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: flat.isPaid ? AppColors.accentGreen.withOpacity(0.15) : AppColors.accentRed.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  flat.isPaid
                      ? (flat.amountDue == Decimal.zero ? 'BORÇ YOK' : 'ÖDENDİ (${flat.paidDateStr ?? "Banka"})')
                      : '${flat.daysOverdue} Gün Gecikti',
                  style: TextStyle(
                    color: flat.isPaid ? AppColors.accentGreen : AppColors.accentRed,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUnmatchedBankTransactionsSection(List<ReconciliationQueueItem> unmatchedItems) {
    final isDark = AppColors.isDark(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: AppColors.accentCyan, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Aşağıdaki transferler banka ekstresinde mevcut fakat açıklamada daire veya sakin adı bulunamadığı için otomatik eşleştirilemedi. "Daire Seç & Eşle" butonuna tıklayarak ilgili daireye atayabilirsiniz.',
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        if (unmatchedItems.isEmpty)
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: const Center(
              child: Column(
                children: [
                  Icon(Icons.check_circle_outline, color: AppColors.accentGreen, size: 36),
                  SizedBox(height: 8),
                  Text(
                    'Harika! Eşleşmeyen banka hareketi bulunmuyor.',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Tüm gelen transferler daireleriyle başarıyla eşleştirildi.',
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ],
              ),
            ),
          )
        else
          ...unmatchedItems.map((item) => _buildUnmatchedItemCard(item)),
      ],
    );
  }

  Widget _buildUnmatchedItemCard(ReconciliationQueueItem item) {
    final isDark = AppColors.isDark(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accentOrange.withOpacity(0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accentOrange.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Daire Belirlenemedi',
                  style: TextStyle(color: AppColors.accentOrange, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                '${item.transaction.date.day.toString().padLeft(2, '0')}.${item.transaction.date.month.toString().padLeft(2, '0')}.${item.transaction.date.year}',
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            item.transaction.description,
            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Referans: ${item.transaction.transactionId}',
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
              ),
              Text(
                '₺${item.transaction.amount.toStringAsFixed(2)}',
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _openManualAssignment(item),
              icon: const Icon(Icons.add_home_work_outlined, size: 16),
              label: const Text('Daire Seç & Eşle'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentOrange,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
