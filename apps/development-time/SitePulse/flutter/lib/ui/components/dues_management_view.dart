import '../design_system/sp_page_header.dart';
import '../../testing/test_id.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import '../../domain/models/dues_models.dart';
import '../../domain/services/bank_file_picker.dart';
import '../../domain/services/bank_statement_sample_generator.dart';
import '../../domain/services/platform_env.dart';
import '../dashboard/dashboard_controller.dart';
import '../theme/app_theme.dart';
import '../design_system/sp_semantics.dart';
import 'app_fullscreen_page.dart';
import 'bank_statement_reconciliation_page.dart';
import 'capital_projects_view.dart';
import 'manual_unit_assignment_page.dart';
import 'payment_tracking_page.dart';
import '../residents/owners_residents_module_page.dart';

import '../design_system/money_formatter.dart';
import '../design_system/sp_feedback.dart';
import 'sp_dialog_pages.dart';
import '../design_system/sp_metric.dart';
import '../design_system/sp_tone.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_status_badge.dart';

class DuesManagementView extends StatefulWidget {
  final DashboardController controller;
  final int initialSegment;

  const DuesManagementView({
    super.key,
    required this.controller,
    this.initialSegment = 0,
  });

  @override
  State<DuesManagementView> createState() => _DuesManagementViewState();
}

class _DuesManagementViewState extends State<DuesManagementView> {
  // 0: Daire Aidat Durumları, 1: Canlı Kasa & Tahsilat, 2: Borç Yaşlandırma, 3: Eşleşmeyenler
  late int _activeSegment;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _activeSegment = widget.initialSegment;
    widget.controller.fetchReconciliationQueue();
    widget.controller.fetchBankAccount();
    widget.controller.fetchDuesPeriods();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _nextMonth() {
    final months = widget.controller.availableDuesMonths;
    if (months.isEmpty) return;
    final currentIdx = months.indexOf(widget.controller.selectedDuesMonth);
    if (currentIdx > 0) {
      widget.controller.setSelectedDuesMonth(months[currentIdx - 1]);
    }
  }

  void _prevMonth() {
    final months = widget.controller.availableDuesMonths;
    if (months.isEmpty) return;
    final currentIdx = months.indexOf(widget.controller.selectedDuesMonth);
    if (currentIdx != -1 && currentIdx < months.length - 1) {
      widget.controller.setSelectedDuesMonth(months[currentIdx + 1]);
    }
  }

  Future<void> _handleFileUpload() async {
    if (widget.controller.siteBankAccount == null) {
      await widget.controller.fetchBankAccount();
    }
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
            appSnackBar(
              content: testId('snackbar_import_error', Row(
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
              )),
              backgroundColor: AppColors.dangerFill,
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


  Future<void> _showImportOptionsDialog() async {
    await widget.controller.fetchBankCatalog();
    if (!mounted) return;
    final isDark = AppColors.isDark(context);
    showSpSheetPage(
      context: context,
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
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
                    Flexible(child: Text(
                      'Banka Ekstresi / Excel İçe Aktar',
                      style: TextStyle(
                        color: AppColors.textPrimary(context),
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    )),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Kuveyt Türk (.xlsx), İş Bankası (.xls / .csv) veya MT940 formatlarını seçin:',
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                ),
                const SizedBox(height: 16),
                testId('btn_import_pick_file', ListTile(
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
                )),

                ..._buildBankSampleDownloads(),

              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildBankSampleDownloads() {
    final excelBanks = widget.controller.bankCatalog
        .where((bank) => bank.supportsExcel)
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    if (excelBanks.isEmpty) return const [];

    return [
      const Divider(height: 24),
      Text(
        'Örnek Excel ekstreleri',
        style: TextStyle(
          color: AppColors.textPrimary(context),
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        'İşleyişi denemek için kurgusal işlem içeren bir örnek indirin.',
        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
      ),
      const SizedBox(height: 8),
      for (final bank in excelBanks)
        testId('btn_download_bank_sample_${bank.code.toLowerCase()}', ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_outlined),
          title: Text('${bank.displayName} örnek ekstresi'),
          subtitle: const Text('Excel çalışma kitabı (.xlsx)'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _downloadBankSample(bank),
        )),
    ];
  }

  void _downloadBankSample(BankCatalogEntry bank) {
    final saved = downloadBytes(
      BankStatementSampleGenerator.fileName(bank),
      BankStatementSampleGenerator.create(bank),
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    ScaffoldMessenger.of(context).showSnackBar(spSnackBar(
      kind: saved ? ToastKind.success : ToastKind.warning,
      content: Text(saved ? 'Örnek ekstre indirildi.' : 'Bu cihazda dosya indirme desteklenmiyor.'),
    ));
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

    showSpPage(
      context: context,
      builder: (ctx) {
        return SpDialogPage(
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
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Breakdown Cards
                testId('import_summary_matched', Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.accentGreen.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.accentGreen.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
                          const Icon(Icons.check_circle, color: AppColors.accentGreen, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Eşleşen Daireler (${matchedItems.length})',
                            style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.successText(context), fontSize: 13),
                          ),
                        ])),
                      Flexible(child: Text(
                        formatTry(matchedSum),
                        style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.successText(context), fontSize: 14),
                      )),
                    ],
                  ),
                )),
                const SizedBox(height: 8),
                testId('import_summary_unmatched', Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.accentOrange.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.accentOrange.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
                          const Icon(Icons.help_outline, color: AppColors.accentOrange, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Eşleşemeyen (${unmatchedItems.length})',
                            style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.warningText(context), fontSize: 13),
                          ),
                        ])),
                      Flexible(child: Text(
                        formatTry(unmatchedSum),
                        style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.warningText(context), fontSize: 14),
                      )),
                    ],
                  ),
                )),
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
                        Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
                            const Icon(Icons.receipt_long, color: Colors.blueGrey, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              'Gider / Masraf (${expenseItems.length})',
                              style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.blueGrey, fontSize: 12),
                            ),
                          ])),
                        Flexible(child: const Text(
                          'Aidattan Düşüldü',
                          style: TextStyle(color: Colors.blueGrey, fontSize: 12),
                        )),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                // Actions
                if (matchedItems.isNotEmpty)
                  SizedBox(
                    width: double.infinity,
                    child: testId('btn_confirm_matched_import', ElevatedButton.icon(
                      onPressed: () async {
                        final ids = matchedItems.map((m) => m.matchId).toList();
                        Navigator.pop(ctx);
                        await widget.controller.confirmReconciliation(ids);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          appSnackBar(
                            content: Text('${matchedItems.length} dairenin aidat tahsilatı onaylandı!'),
                            backgroundColor: AppColors.successFill,
                          ),
                        );
                      },
                      icon: const Icon(Icons.done_all, size: 16),
                      label: Text('Eşleşenleri Onayla & Kaydet (${matchedItems.length})'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.successFill,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    )),
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
                              _activeSegment = 3; // Switch to unmatched pool tab
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
                        child: Text('Tam Ekran Detay', style: TextStyle(fontSize: 12, color: AppColors.primaryText(context))),
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
      await widget.controller.confirmReconciliation(
        [item.matchId],
        optionalHostMessage: sendMsg ? msgText : null,
        rememberSenderIban: rememberIban,
      );

      if (mounted) {
        final flatDesc = selectedFlat.block.contains('Blok')
            ? '${selectedFlat.block} D:${selectedFlat.unitNo}'
            : '${selectedFlat.block} Blok D:${selectedFlat.unitNo}';
        final msgNote = (sendMsg && msgText != null && msgText.trim().isNotEmpty)
            ? ' Ev sahibine (${selectedFlat.residentName}) bilgilendirme mesajı iletildi.'
            : '';
        ScaffoldMessenger.of(context).showSnackBar(
          appSnackBar(
            content: Text(
              '${item.transaction.senderName ?? "İşlem"} -> $flatDesc (${selectedFlat.residentName}) ile eşleştirildi ve onaylandı!$msgNote',
            ),
            backgroundColor: AppColors.successFill,
          ),
        );
      }
    }
  }

  static const List<String> _turkishMonthNames = [
    'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
    'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık',
  ];

  String _formatTurkishMonth(DateTime date) =>
      '${_turkishMonthNames[date.month - 1]} ${date.year}';

  DateTime _parseTurkishMonth(String period) {
    final parts = period.split(' ');
    final monthIndex = _turkishMonthNames.indexOf(parts.first);
    final year = parts.length > 1 ? int.tryParse(parts.last) : null;
    if (monthIndex < 0 || year == null) return DateTime.now();
    return DateTime(year, monthIndex + 1);
  }

  Future<void> _showAccrueDuesDialog() async {
    String selectedMonth = widget.controller.selectedDuesMonth;
    if (selectedMonth.isEmpty) selectedMonth = _formatTurkishMonth(DateTime.now());
    final initialPeriod = _parseTurkishMonth(selectedMonth);
    DateTime selectedDueDate = DateTime(initialPeriod.year, initialPeriod.month, 15);
    final isDark = AppColors.isDark(context);

    await showSpPage(
      context: context,
      builder: (ctx) {
        bool isSubmitting = false;

        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return SpAlertPage(
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
                            Flexible(child: Text('Tahakkuk Dönemi:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13))),
                            testId('accrual_dialog_period', TextButton.icon(
                              onPressed: isSubmitting ? null : () async {
                                final now = DateTime.now();
                                final options = List<DateTime>.generate(13, (index) => DateTime(now.year, now.month - 6 + index));
                                final choice = await showSpSelection<DateTime>(
                                  context: dialogCtx,
                                  title: 'Tahakkuk Dönemi Seçin',
                                  options: options,
                                  selected: _parseTurkishMonth(selectedMonth),
                                  labelOf: _formatTurkishMonth,
                                  idOf: (month) => 'accrual_month_${month.year}_${month.month}',
                                );
                                if (choice != null) {
                                  setDialogState(() {
                                    selectedMonth = _formatTurkishMonth(choice);
                                    selectedDueDate = DateTime(choice.year, choice.month, 15);
                                  });
                                }
                              },
                              icon: const Icon(Icons.calendar_month_outlined, size: 18),
                              label: Text(selectedMonth, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            )),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(child: Text('Daire Başı Aidat:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13))),
                            Flexible(child: Text('₺1.400,00', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.successText(context), fontSize: 13))),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(child: Text('Son Ödeme Tarihi:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13))),
                            testId('accrual_dialog_due_date', TextButton.icon(
                              onPressed: isSubmitting ? null : () async {
                                final choice = await showDatePicker(
                                  context: dialogCtx,
                                  initialDate: selectedDueDate,
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime(2100),
                                  helpText: 'Son ödeme tarihini seçin',
                                );
                                if (choice != null) setDialogState(() => selectedDueDate = choice);
                              },
                              icon: const Icon(Icons.event_outlined, size: 18),
                              label: Text(
                                '${selectedDueDate.day.toString().padLeft(2, '0')}.${selectedDueDate.month.toString().padLeft(2, '0')}.${selectedDueDate.year}',
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                            )),
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
                              fontSize: 12,
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
                testId(
                  'btn_cancel_period_accrual',
                  TextButton(
                    key: const Key('btn_cancel_period_accrual'),
                    onPressed: isSubmitting ? null : () => Navigator.pop(dialogCtx),
                    child: const Text(AppStrings.cancel),
                  ),
                ),
                testId('btn_confirm_period_accrual', ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.successFill,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          setDialogState(() => isSubmitting = true);
                          final result = await widget.controller.accrueMonthlyDues(
                            period: selectedMonth,
                            dueDate: selectedDueDate,
                          );
                          if (mounted) {
                            Navigator.pop(dialogCtx);
                            final alreadyAccrued = result['already_accrued'] == true;
                            final failed = result['success'] == false;
                            final msg = result['message'] as String? ?? '';
                            ScaffoldMessenger.of(context).showSnackBar(
                              appSnackBar(
                                content: testId('snackbar_accrual_result', Row(
                                  children: [
                                    Icon(
                                      failed
                                          ? Icons.error_outline
                                          : alreadyAccrued
                                              ? Icons.info_outline
                                              : Icons.check_circle,
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
                                )),
                                backgroundColor: failed
                                    ? AppColors.accentRed
                                    : alreadyAccrued
                                        ? AppColors.accentOrange
                                        : AppColors.accentGreen,
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
                )),
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
        SpPageHeader(
          title: 'Aidat ve Tahsilat Yönetimi',
          icon: Icons.account_balance_wallet_outlined,
          subtitle: widget.controller.userSession.siteName,
          actions: [
            testId(
              'btn_open_accrual_dialog',
              ElevatedButton.icon(
                onPressed: widget.controller.flatsList.isEmpty ? null : _showAccrueDuesDialog,
                icon: const Icon(Icons.event_repeat, size: 14),
                label: const Text('Toplu Aidat Tahakkuku', style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.successFill,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            testId(
              'btn_open_bank_import',
              ElevatedButton.icon(
                onPressed: _showImportOptionsDialog,
                icon: const Icon(Icons.upload_file, size: 14),
                label: const Text('Excel / Ekstre Yükle', style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryFill,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            testId(
              'action_payment_tracking',
              ElevatedButton.icon(
                key: const Key('action_payment_tracking'),
                onPressed: () {
                  setState(() => _activeSegment = 1);
                  widget.controller.fetchPaymentStream();
                },
                icon: const Icon(Icons.account_balance_wallet, size: 14),
                label: const Text('Tahsilat & Kasa Takibi', style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            testId(
              'btn_dues_more_actions',
              PopupMenuButton<String>(
                tooltip: 'Diğer Kasa İşlemleri',
                icon: const Icon(Icons.more_vert, size: 20),
                onSelected: (val) {
                  if (val == 'manual_cash') {
                    PaymentTrackingPage.openRecordManualPayment(
                      context,
                      controller: widget.controller,
                      onSaved: () => setState(() {}),
                    );
                  } else if (val == 'virman') {
                    PaymentTrackingPage.openInterLedgerTransfer(
                      context,
                      controller: widget.controller,
                      onCompleted: () => setState(() {}),
                    );
                  }
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(
                    value: 'manual_cash',
                    child: Row(
                      children: [
                        Icon(Icons.payments_outlined, size: 16, color: AppColors.accentGreen),
                        SizedBox(width: 8),
                        Text('Nakit / Manuel Tahsilat', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'virman',
                    child: testId(
                      'menu_item_virman',
                      const Row(
                        children: [
                          Icon(Icons.swap_horiz, size: 16, color: Colors.indigo),
                          SizedBox(width: 8),
                          Text('Virman (Aidat ⇄ Demirbaş)', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        if (widget.controller.duesPeriods.isNotEmpty) ...[
          _buildPeriodStatusMatrix(context),
          const SizedBox(height: 12),
        ],
        if (widget.controller.userSession.siteName.isEmpty && widget.controller.currentManagedSite == null) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.accentOrange.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.accentOrange.withOpacity(0.35)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: AppColors.accentOrange, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Tanımlı veya seçili bir site bulunamadı. Lütfen yeni bir site tanımlayınız.',
                    style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
        // 3. Segmented Navigation: 4 Segments (Daire Borçları, Canlı Kasa, Borç Yaşlandırma, Banka Eşleşmeyenler)
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= AppBreakpoints.medium ? 5 : 2;
              final tabWidth = (constraints.maxWidth - AppSpacing.xs * (columns - 1)) / columns;
              return Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  SizedBox(width: tabWidth, child: _buildSegmentTab(0, 'Daire Aidat Durumları')),
                  SizedBox(width: tabWidth, child: _buildSegmentTab(1, 'Canlı Kasa')),
                  SizedBox(width: tabWidth, child: _buildSegmentTab(2, 'Yaşlandırma')),
                  SizedBox(
                    width: tabWidth,
                    child: _buildSegmentTab(3, 'Eşleşmeyenler', count: unmatchedItems.length),
                  ),
                  SizedBox(width: tabWidth, child: _buildSegmentTab(4, 'Demirbaş & Yatırım')),
                ],
              );
            },
          ),
        ),

        const SizedBox(height: AppSpacing.lg),

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
                    tooltip: 'Önceki ay',
                    icon: const Icon(Icons.chevron_left, size: 20),
                    visualDensity: VisualDensity.compact,
                    onPressed: _prevMonth,
                  ),
                  Expanded(child: PopupMenuButton<String>(
                    initialValue: selectedMonth.isNotEmpty ? selectedMonth : null,
                    onSelected: (m) {
                      if (m.isNotEmpty) {
                        widget.controller.setSelectedDuesMonth(m);
                      }
                    },
                    itemBuilder: (ctx) {
                      if (widget.controller.availableDuesMonths.isEmpty) {
                        return [
                          const PopupMenuItem<String>(
                            value: '',
                            enabled: false,
                            child: Text('Henüz aidat dönemi yok'),
                          ),
                        ];
                      }
                      return widget.controller.availableDuesMonths.map((m) {
                        return PopupMenuItem<String>(
                          value: m,
                          child: Text(m, style: TextStyle(fontWeight: m == selectedMonth ? FontWeight.bold : FontWeight.normal)),
                        );
                      }).toList();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_month_outlined, size: 16, color: AppColors.accentCyan),
                          const SizedBox(width: 6),
                          Flexible(child: Text(
                            selectedMonth.isNotEmpty ? selectedMonth : 'Henüz Aidat Dönemi Yok',
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          )),
                          const SizedBox(width: 4),
                          const Icon(Icons.arrow_drop_down, size: 18),
                        ],
                      ),
                    ),
                  )),
                  IconButton(
                    tooltip: 'Sonraki ay',
                    icon: const Icon(Icons.chevron_right, size: 20),
                    visualDensity: VisualDensity.compact,
                    onPressed: _nextMonth,
                  ),
                ],
              ),
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
                    colors: [Color(0xFF1E293B), AppColors.darkBackground],
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
                  Flexible(child: Text(
                    '$selectedMonth Tahsilat Performansı',
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13, fontWeight: FontWeight.w500),
                  )),
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
                      style: TextStyle(color: AppColors.successText(context), fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  Text(
                    formatTry(summary.totalCollected),
                    style: TextStyle(color: AppColors.textPrimary(context), fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '/ ${formatTry(summary.totalExpected)} Toplam',
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
              // Summary metrics wrap when the available width is compact.
              Wrap(
                spacing: AppSpacing.xl,
                runSpacing: AppSpacing.md,
                children: [
                  SpMetricValue(label: AppStrings.totalUnits, value: '${summary.totalUnitsCount}'),
                  SpMetricValue(label: 'Ödeyen Kişi', value: '${summary.paidUnitsCount} Daire', tone: SpTone.success),
                  SpMetricValue(label: 'Ödemeyen / Geciken', value: '${summary.overdueUnitsCount} Daire', tone: SpTone.danger),
                  SpMetricValue(label: AppStrings.remainingDebt, value: formatTry(summary.totalOverdueAmount), tone: SpTone.warning),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),

        // 4. Alert Banner if not in Segment 3 and Unmatched Items Exist
        if (_activeSegment != 3 && unmatchedItems.isNotEmpty) ...[
          InkWell(
            onTap: () => setState(() => _activeSegment = 3),
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
                      style: TextStyle(
                        color: AppColors.warningText(context),
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
        else if (_activeSegment == 1)
          PaymentStreamWidget(controller: widget.controller, isEmbedded: true)
        else if (_activeSegment == 2)
          DebtAgingWidget(controller: widget.controller, isEmbedded: true)
        else if (_activeSegment == 3)
          _buildUnmatchedBankTransactionsSection(unmatchedItems)
        else
          CapitalProjectsView(controller: widget.controller),
      ],
    );
  }

  Widget _buildSegmentTab(int index, String label, {int count = 0}) {
    final isSelected = _activeSegment == index;
    return testId('segment_tab_$index', selectableSemantics(selected: isSelected, child: InkWell(
      key: Key('segment_tab_$index'),
      onTap: () {
        setState(() => _activeSegment = index);
        if (index == 1) widget.controller.fetchPaymentStream();
        if (index == 2) widget.controller.fetchDebtAgingReport();
        if (index == 4) widget.controller.fetchCapitalProjects();
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accentCyan : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : AppColors.textSecondary(context),
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                ),
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white : AppColors.accentOrange,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: isSelected ? AppColors.primaryText(context) : Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    )));
  }

  Widget _buildFlatsDuesSection(List<FlatPaymentStatus> flats) {
    final currentFilter = widget.controller.flatFilter;
    final totalCount = widget.controller.currentMonthFlats.length;
    final paidCount = widget.controller.currentMonthSummary.paidUnitsCount;
    final overdueCount = widget.controller.currentMonthSummary.overdueUnitsCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Referral Button to Owners & Residents Module
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: testId('dues_to_residents_module_btn', InkWell(
            key: const Key('dues_to_residents_module_btn'),
            onTap: () {
              AppFullscreenPage.push(
                context: context,
                builder: (_) => OwnersResidentsModulePage(controller: widget.controller),
              );
            },
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.accentCyan.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accentCyan.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.people_alt_outlined, size: 16, color: AppColors.accentCyan),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Kat Malikleri & Sakinler Yönetim Modülü',
                      style: TextStyle(
                        color: AppColors.primaryText(context),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Icon(Icons.arrow_forward_ios, size: 12, color: AppColors.accentCyan),
                ],
              ),
            ),
          )),
        ),

        // Filter chips wrap before the search field.
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            _buildFilterChip('Tümü ($totalCount)', 'ALL', currentFilter),
            const SizedBox(width: 6),
            _buildFilterChip('Ödeyen ($paidCount)', 'PAID', currentFilter),
            const SizedBox(width: 6),
            _buildFilterChip('Geciken ($overdueCount)', 'OVERDUE', currentFilter),
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
                      tooltip: 'Aramayı temizle',
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
          _buildZeroDataGuidanceCard(context, widget.controller.selectedDuesMonth)
        else
          ...flats.map((flat) => _buildFlatStatusCard(flat)),
      ],
    );
  }

  Widget _buildPeriodStatusMatrix(BuildContext context) {
    String stateLabel(DuesPeriodStatus status) => switch (status) {
      DuesPeriodStatus.draft => 'TASLAK',
      DuesPeriodStatus.active => 'AÇIK',
      DuesPeriodStatus.closed => 'KAPALI',
    };

    SpTone stateTone(DuesPeriodStatus status) => switch (status) {
      DuesPeriodStatus.draft => SpTone.warning,
      DuesPeriodStatus.active => SpTone.success,
      DuesPeriodStatus.closed => SpTone.neutral,
    };

    String allowedActions(DuesPeriodStatus status) => switch (status) {
      DuesPeriodStatus.draft => 'Tahakkuk et',
      DuesPeriodStatus.active => 'Tahakkuk tekrar (zaten yapıldı) · Dönemi kapat',
      DuesPeriodStatus.closed => 'Yeniden açma iste',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Aidat dönemi durumları',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            ...widget.controller.duesPeriods.map((period) => Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Row(
                children: [
                  Expanded(child: Text(period.periodName)),
                  testId(
                    'period_status_${period.id}',
                    SpStatusBadge(
                      label: stateLabel(period.periodStatus),
                      tone: stateTone(period.periodStatus),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  testId(
                    'period_action_${period.id}',
                    Text(allowedActions(period.periodStatus)),
                  ),
                ],
              ),
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildZeroDataGuidanceCard(BuildContext context, String selectedMonth) {
    final hasNoPeriods = widget.controller.availableDuesMonths.isEmpty;
    final hasNoFlats = widget.controller.flatsList.isEmpty;
    final hasNoSite = widget.controller.currentManagedSite == null && widget.controller.managedSitesList.isEmpty && widget.controller.userSession.siteName.isEmpty;

    if (hasNoSite) {
      return const SpGuidanceCard(
        icon: Icons.apartment_outlined,
        tone: SpTone.warning,
        title: AppStrings.noManagedSiteTitle,
        message: 'Sistemde kayıtlı bir site bulunamadı. Aidat tahakkuku ve sakin yönetimi yapabilmek için lütfen bir site oluşturunuz.',
      );
    }

    if (hasNoFlats) {
      return const SpGuidanceCard(
        icon: Icons.people_outline,
        tone: SpTone.warning,
        prominent: true,
        title: 'Kayıtlı Daire ve Kat Maliki Bulunmuyor',
        message: 'Aidat tahakkuku yapabilmek ve Sanal IBAN tahsis edebilmek için sitenize blok, bağımsız bölüm ve kat maliki tanımlamanız gerekmektedir.',
        tip: 'Yönetici kokpitinden sakin davet bağlantısı oluşturarak veya manuel ekleme yaparak başlayabilirsiniz.',
      );
    }

    if (hasNoPeriods) {
      return SpGuidanceCard(
        icon: Icons.calendar_today_outlined,
        tone: SpTone.info,
        prominent: true,
        tonedBorder: true,
        title: 'Henüz Aidat Dönemi Oluşturulmadı',
        message: 'Bu sitede henüz aktif veya geçmiş bir aidat tahakkuku bulunmuyor. Dairelerinize düzenli aylık aidat yansıtmak ve banka/FAST tahsilatlarını otomatik eşleştirmek için yeni bir aidat dönemi başlatabilirsiniz.',
        action: ElevatedButton.icon(
          onPressed: _showAccrueDuesDialog,
          icon: const Icon(Icons.add_circle_outline, size: 18),
          label: const Text('İlk Aidat Dönemini Başlat'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.successFill,
            foregroundColor: AppColors.onFill,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg + 4, vertical: AppSpacing.md),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
          ),
        ),
        tip: 'KMK Madde 20 uyarınca vadesinde ödenmeyen aidatlara aylık %5 gecikme tazminatı uygulanır.',
      );
    }

    // Otherwise: search or filter returned empty
    return SpGuidanceCard(
      icon: Icons.filter_alt_off_outlined,
      tone: SpTone.info,
      title: 'Filtreye Uygun Daire Bulunamadı',
      message: 'Seçtiğiniz filtre (${widget.controller.flatFilter}) veya arama kriterine uygun daire kaydı bulunmuyor.',
      action: TextButton.icon(
        onPressed: () {
          setState(() {
            _searchQuery = '';
          });
          widget.controller.setFlatFilter('ALL');
        },
        icon: const Icon(Icons.refresh, size: 16),
        label: const Text('Filtreyi Temizle (Tümü)'),
      ),
    );
  }

  Widget _buildFilterChip(String label, String filterKey, String currentFilter) {
    final isSelected = currentFilter == filterKey;
    return testId('dues_filter_$filterKey', selectableSemantics(selected: isSelected, child: InkWell(
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
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    )));
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
          Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
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
            ])),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatTry(flat.amountDue),
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
                child: testId(
                  'dues_status_badge_${flat.id}',
                  Text(
                    flat.isPaid
                        ? (flat.amountDue == Decimal.zero ? 'BORÇ YOK' : 'ÖDENDİ (${flat.paidDateStr ?? "Banka"})')
                        : '${flat.daysOverdue} Gün Gecikti',
                    style: TextStyle(
                      color: flat.isPaid ? AppColors.successText(context) : AppColors.dangerText(context),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              if (!flat.isPaid) ...[
                InkWell(
                  onTap: () {
                    PaymentTrackingPage.openRecordManualPayment(
                      context,
                      controller: widget.controller,
                      initialUnitId: flat.id,
                      onSaved: () => setState(() {}),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    margin: const EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add, size: 12, color: AppColors.accentGreen),
                        SizedBox(width: 2),
                        Text(
                          'Tahsilat Gir',
                          style: TextStyle(
                            color: AppColors.successText(context),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              testId('dues_flat_resident_module_${flat.id}', InkWell(
                key: Key('dues_flat_resident_module_${flat.id}'),
                onTap: () {
                  AppFullscreenPage.push(
                    context: context,
                    builder: (_) => OwnersResidentsModulePage(
                      controller: widget.controller,
                      initialUnitId: flat.id,
                    ),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person_search, size: 12, color: AppColors.accentCyan),
                    SizedBox(width: 2),
                    Text(
                      'Sakin Modülü →',
                      style: TextStyle(
                        color: AppColors.primaryText(context),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              )),
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
            color: isDark ? AppColors.lightTextPrimary : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: AppColors.accentCyan, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Aşağıdaki transferler banka ekstresinde mevcut fakat açıklamada daire veya sakin adı bulunamadığı için otomatik eşleştirilemedi. "Daire Seç & Eşle" butonuna tıklayarak ilgili daireye atayabilirsiniz.',
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
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
                    style: TextStyle(color: Colors.grey, fontSize: 12),
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
                child: Text(
                  'Daire Belirlenemedi',
                  style: TextStyle(color: AppColors.warningText(context), fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
              Flexible(child: Text(
                '${item.transaction.date.day.toString().padLeft(2, '0')}.${item.transaction.date.month.toString().padLeft(2, '0')}.${item.transaction.date.year}',
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
              )),
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
              Flexible(child: Text(
                'Referans: ${item.transaction.transactionId}',
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
              )),
              Flexible(child: Text(
                formatTry(item.transaction.amount),
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16, fontWeight: FontWeight.bold),
              )),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: testId('btn_assign_unmatched_${item.matchId}', ElevatedButton.icon(
              onPressed: () => _openManualAssignment(item),
              icon: const Icon(Icons.add_home_work_outlined, size: 16),
              label: const Text('Daire Seç & Eşle'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.warningFill,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 0,
              ),
            )),
          ),
        ],
      ),
    );
  }
}
