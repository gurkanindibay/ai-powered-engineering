import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../domain/models/dues_models.dart';
import '../../domain/services/bank_file_picker.dart';
import '../dashboard/dashboard_controller.dart';
import '../theme/app_theme.dart';
import 'app_fullscreen_page.dart';
import 'manual_unit_assignment_page.dart';

class BankStatementReconciliationPage extends StatefulWidget {
  final DashboardController controller;

  static const String sampleGarantiExcel =
      'HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33';

  static const String sampleKuveytTurkExcel =
      '01.07.2026;A07MY;Para Transferi, Gönderen: ALAETTİN ÇELİK  , Alıcı: GÜRKAN İNDİBAY, Ödeme Türü:  Diğer Ödeme Türleri;1.320,00;TL\n'
      '01.07.2026;A03JZ;Para Transferi, Gönderen: MUSTAFA RÜZGAR  , Alıcı: GÜRKAN İNDİBAY, Ödeme Türü:  Diğer Ödeme Türleri;660,00;TL\n'
      '13.07.2026;A045C;Para Transferi, Gönderen: MUSTAFA BURAK TÜRKMEN  , Alıcı: GÜRKAN İNDİBAY, Ödeme Türü:  Diğer Ödeme Türleri;1.000,00;TL\n'
      '13.07.2026;A0475;Para Transferi, Gönderen: MUSTAFA RÜZGAR  , Alıcı: GÜRKAN İNDİBAY, Ödeme Türü:  Diğer Ödeme Türleri;715,00;TL\n'
      '13.07.2026;ADS09;sait - Gönderen:SAİT ŞENER, Alıcı:gürkan indibay, FAST Para Transferi;715,00;TL\n'
      '14.07.2026;A00A0;Cami çikolata - Para Transferi, Gönderen: SERVET KARACA  , Alıcı: GÜRKAN İNDİBAY;715,00;TL\n'
      '17.09.2026;A01YN;Para Transferi, Gönderen: HASAN İNDİBAY  , Alıcı: GÜRKAN İNDİBAY, Ödeme Türü:  Diğer Ödeme Türleri;28.000,00;TL\n'
      '18.09.2026;AKVJW;Gönderen:GÜRKAN İNDİBAY, Alıcı:Abdullah haidari, FAST Para Transferi;-20.000,00;TL';

  static const String sampleIsBankExcel =
      '06/08/2026-21:06:38,06/08/2026,Bankamatik,500,500,AD,Para Yatırma,EFEKTİF YATAN 6500********57 62.KART HESABINA PARA YATIRMA,,,,,,21348010002120260806210638613\n'
      '02/08/2026-07:55:32,03/08/2026,Bankamatik,1000,1000,AD,Para Yatırma,EFEKTİF YATAN 6500********57 62.KART HESABINA PARA YATIRMA,,,,,,21348010002120260802075532281\n'
      '06/08/2026-21:07:50,06/08/2026,İşCep,-500,0,0S,Havale,MİDAS MENKUL DEĞERLER ANONİM ŞİRKETİ*GÜRKAN İNDİBAY tarafından aktarılan,,,,,,21348010002120260806210750091\n'
      '02/08/2026-07:56:51,02/08/2026,İşCep,-1000,0,0S,Havale,MİDAS MENKUL DEĞERLER ANONİM ŞİRKETİ*GÜRKAN İNDİBAY tarafından aktarılan,,,,,,21348010002120260802075651398';

  static const String sampleIsBankCsv =
      'Tarih;Açıklama;Tutar;Para Birimi\n'
      '15.09.2026;HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT;1.423,33;TL\n'
      '16.09.2026;EFT - MEHMET DEMIR B BLOK NO:1 AIDAT;1.200,00;TL';

  static const String sampleSwiftMt940 =
      ':20:STARTMR\n'
      ':25:TR120006200000000000001001\n'
      ':28C:00001/001\n'
      ':60F:C260901TRY50000,00\n'
      ':61:2609150915CR1423,33NTRFNONREF//TXN77889\n'
      ':86:HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT\n'
      ':62F:C260930TRY51423,33\n'
      '-';

  const BankStatementReconciliationPage({
    super.key,
    required this.controller,
  });

  @override
  State<BankStatementReconciliationPage> createState() => _BankStatementReconciliationPageState();
}

class _BankStatementReconciliationPageState extends State<BankStatementReconciliationPage> {
  final TextEditingController _textController = TextEditingController();
  final Set<String> _selectedMatchIds = {};
  String _activePreset = 'Garanti BBVA';
  String _filterStatus = 'ALL'; // 'ALL', 'MATCHED', 'UNMATCHED', 'GIDER'


  @override
  void initState() {
    super.initState();
    _textController.text = BankStatementReconciliationPage.sampleGarantiExcel;
    // Auto-parse default sample on open after the initial build frame
    // to prevent notifyListeners() from triggering setState() during widget mount
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.parseBankStatement(BankStatementReconciliationPage.sampleGarantiExcel);
      setState(() {
        _selectAllPending();
      });
    });
  }

  void _selectAllPending() {
    _selectedMatchIds.clear();
    for (final item in widget.controller.reconciliationQueue) {
      if (item.isPendingApproval) {
        _selectedMatchIds.add(item.matchId);
      }
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _applyPreset(String name, String content) {
    setState(() {
      _activePreset = name;
      _textController.text = content;
    });
    final success = widget.controller.parseBankStatement(content);
    if (!success) {
      setState(() {
        _selectedMatchIds.clear();
      });
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
    setState(() {
      _selectAllPending();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppColors.isDark(context);
    final queue = widget.controller.reconciliationQueue;

    final selectedTotal = queue
        .where((q) => _selectedMatchIds.contains(q.matchId) && q.isPendingApproval)
        .fold<Decimal>(Decimal.zero, (sum, item) => sum + item.transaction.amount);

    final matchedItems = queue.where((q) => q.status == 'ONAY_BEKLIYOR').toList();
    final unmatchedItems = queue.where((q) => q.status == 'ESLESTIRILEMEDI').toList();
    final approvedItems = queue.where((q) => q.status == 'ONAYLANDI').toList();
    final expenseItems = queue.where((q) => q.status == 'GIDER').toList();
    final alreadyUploadedItems = queue.where((q) => q.isAlreadyUploaded).toList();

    final matchedCount = matchedItems.length + approvedItems.length;
    final unmatchedCount = unmatchedItems.length;
    final expenseCount = expenseItems.length;
    final alreadyUploadedCount = alreadyUploadedItems.length;

    final matchedTotal = queue
        .where((q) => q.status == 'ONAY_BEKLIYOR' || q.status == 'ONAYLANDI')
        .fold<Decimal>(Decimal.zero, (sum, i) => sum + i.transaction.amount);

    final alreadyUploadedTotal = alreadyUploadedItems
        .fold<Decimal>(Decimal.zero, (sum, i) => sum + i.transaction.amount);

    final unmatchedTotal = unmatchedItems
        .fold<Decimal>(Decimal.zero, (sum, i) => sum + i.transaction.amount);

    final expenseTotal = expenseItems
        .fold<Decimal>(Decimal.zero, (sum, i) => sum + i.transaction.amount);

    List<ReconciliationQueueItem> displayedQueue = queue;
    if (_filterStatus == 'MATCHED') {
      displayedQueue = queue.where((q) => q.status == 'ONAY_BEKLIYOR' || q.status == 'ONAYLANDI').toList();
    } else if (_filterStatus == 'ALREADY_UPLOADED') {
      displayedQueue = alreadyUploadedItems;
    } else if (_filterStatus == 'UNMATCHED') {
      displayedQueue = unmatchedItems;
    } else if (_filterStatus == 'GIDER') {
      displayedQueue = expenseItems;
    }

    return AppFullscreenPage(
      title: 'Banka Ekstresi & Eşleştirme',
      subtitle: 'Excel, CSV veya SWIFT MT940 formatında yükleyin',
      icon: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.accentCyan.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.account_balance, color: AppColors.accentCyan, size: 20),
      ),
      bottomBar: AppFullscreenPage.buildBottomBar(
        context: context,
        children: [
          ElevatedButton.icon(
            onPressed: _selectedMatchIds.isEmpty
                ? null
                : () => _showBatchConfirmationDialog(context),
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: Text(
              _selectedMatchIds.isEmpty
                  ? 'Seçili İşlem Yok'
                  : 'Seçilenleri Onayla & Aidatları Düş (₺${selectedTotal.toStringAsFixed(2)})',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentGreen,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Info Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
            ),
            child: Row(
              children: [
                const Icon(Icons.flash_on, color: AppColors.accentCyan, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sıfır Onaylı (Zero-Approval) Akıllı Eşleştirici',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Banka internet şubenizden indirdiğiniz hareketleri yapıştırın. Sistem blok, daire no ve sakin adını analiz ederek aidat borçlarını eşleştirir.',
                        style: TextStyle(
                          color: AppColors.textSecondary(context),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 1b. Active Bank Account Configuration Card (STORY-08-01)
          Builder(
            builder: (ctx) {
              final activeAccount = widget.controller.siteBankAccount;
              final bankName = activeAccount?.bankName ?? 'Kuveyt Türk Katılım Bankası';
              final iban = activeAccount?.iban ?? 'TR62 0020 5000 0986 3791 6000 01';
              final holder = activeAccount?.accountHolder ?? 'Begonya Sitesi Yönetimi';
              final formatStr = activeAccount?.statementFormat ?? 'EXCEL';

              Color formatColor = AppColors.accentGreen;
              if (formatStr == 'CSV') formatColor = AppColors.accentCyan;
              if (formatStr == 'MT940') formatColor = const Color(0xFFA855F7); // purple

              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.accentCyan.withOpacity(0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.accentCyan.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.account_balance, color: AppColors.accentCyan, size: 20),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  Text(
                                    bankName,
                                    style: TextStyle(
                                      color: AppColors.textPrimary(context),
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: formatColor.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: formatColor.withOpacity(0.4)),
                                    ),
                                    child: Text(
                                      'Format: $formatStr',
                                      style: TextStyle(
                                        color: formatColor,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'IBAN: $iban • $holder',
                                style: TextStyle(
                                  color: AppColors.textSecondary(context),
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () => _showChangeBankAccountDialog(context),
                          icon: const Icon(Icons.edit, size: 13),
                          label: const Text('Değiştir', style: TextStyle(fontSize: 11)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.accentCyan,
                            side: BorderSide(color: AppColors.accentCyan.withOpacity(0.5)),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Tek aktif banka hesabı kuralı geçerlidir. Banka değiştirildiğinde yeni bankanın ekstre formatı otomatik olarak izinli hale gelir.',
                      style: TextStyle(
                        color: AppColors.textSecondary(context).withOpacity(0.7),
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          if (widget.controller.bankStatementError != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.accentRed.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accentRed.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: AppColors.accentRed, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.controller.bankStatementError!,
                      style: const TextStyle(color: AppColors.accentRed, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.accentRed, size: 16),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => widget.controller.clearBankStatementError(),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 14),

          // 2. Direct File Upload Action
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.accentCyan.withOpacity(0.35)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.accentCyan.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.file_upload_outlined, color: AppColors.accentCyan, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Doğrudan Banka Dosyası Yükle',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        widget.controller.siteBankAccount != null
                            ? '${widget.controller.siteBankAccount!.bankName} (${widget.controller.siteBankAccount!.statementFormat} - ${widget.controller.siteBankAccount!.supportedBank?.fileExtension ?? ""})'
                            : 'Kuveyt Türk (.xlsx), İş Bankası (.xls), CSV veya MT940',
                        style: TextStyle(
                          color: AppColors.textSecondary(context),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    final activeAccount = widget.controller.siteBankAccount;
                    final acceptFilter = activeAccount?.supportedBank?.fileExtension;
                    final picked = await pickBankFile(accept: acceptFilter);
                    if (picked != null) {
                      final success = widget.controller.parseBankStatementFile(
                        fileName: picked.name,
                        bytes: picked.bytes,
                      );
                      if (!success) {
                        setState(() {
                          _selectedMatchIds.clear();
                        });
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
                      setState(() {
                        _activePreset = picked.name;
                        _textController.text = '${picked.name} yüklendi (${widget.controller.reconciliationQueue.length} hareket ayrıştırıldı)';
                        _selectAllPending();
                      });
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${picked.name} başarıyla yüklendi ve dairelerle eşleştirildi!'),
                            backgroundColor: AppColors.accentGreen,
                          ),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.upload_file, size: 16),
                  label: const Text('Dosya Yükle'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentCyan,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 3. Preset Selectors
          Text(
            'Hızlı Test & Örnek Ekstre Formatları',
            style: TextStyle(
              color: AppColors.textPrimary(context),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildPresetChip('Garanti BBVA', BankStatementReconciliationPage.sampleGarantiExcel),
                const SizedBox(width: 8),
                _buildPresetChip('Kuveyt Türk (.xlsx)', BankStatementReconciliationPage.sampleKuveytTurkExcel),
                const SizedBox(width: 8),
                _buildPresetChip('İş Bankası (.xls)', BankStatementReconciliationPage.sampleIsBankExcel),
                const SizedBox(width: 8),
                _buildPresetChip('İş Bankası CSV', BankStatementReconciliationPage.sampleIsBankCsv),
                const SizedBox(width: 8),
                _buildPresetChip('SWIFT MT940', BankStatementReconciliationPage.sampleSwiftMt940),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 3. Text Area
          Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border(context)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: TextField(
              controller: _textController,
              maxLines: 4,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: AppColors.textPrimary(context),
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: 'Banka ekstresi satırlarını veya MT940 içeriğini buraya yapıştırın...',
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Action Button: Parse
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                final text = _textController.text.trim();
                if (text.isEmpty) return;
                final success = widget.controller.parseBankStatement(text);
                if (!success) {
                  setState(() {
                    _selectedMatchIds.clear();
                  });
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
                setState(() {
                  _selectAllPending();
                });
              },
              icon: const Icon(Icons.sync_alt, size: 16),
              label: const Text('Ekstre Ayrıştır & Daireleri Eşleştir'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accentCyan,
                side: const BorderSide(color: AppColors.accentCyan),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // 4. Ara Adım: Eşleştirme Analiz Raporu & Filtreleme (Intermediate Step)
          if (queue.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.analytics_outlined, color: AppColors.accentCyan, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Eşleştirme Analiz Raporu (Ara Adım)',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isNarrow = constraints.maxWidth < 650;
                      if (isNarrow) {
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            SizedBox(
                              width: (constraints.maxWidth - 8) / 2,
                              child: _buildMetricCard(
                                title: 'Eşleşen Daireler',
                                count: matchedCount,
                                amount: matchedTotal,
                                color: AppColors.accentGreen,
                                icon: Icons.check_circle_outline,
                              ),
                            ),
                            SizedBox(
                              width: (constraints.maxWidth - 8) / 2,
                              child: _buildMetricCard(
                                title: 'Zaten Yüklenmiş',
                                count: alreadyUploadedCount,
                                amount: alreadyUploadedTotal,
                                color: Colors.blue,
                                icon: Icons.verified_outlined,
                              ),
                            ),
                            SizedBox(
                              width: (constraints.maxWidth - 8) / 2,
                              child: _buildMetricCard(
                                title: 'Eşleşemeyen',
                                count: unmatchedCount,
                                amount: unmatchedTotal,
                                color: AppColors.accentOrange,
                                icon: Icons.help_outline,
                              ),
                            ),
                            SizedBox(
                              width: (constraints.maxWidth - 8) / 2,
                              child: _buildMetricCard(
                                title: 'Gider / Masraf',
                                count: expenseCount,
                                amount: expenseTotal,
                                color: Colors.blueGrey,
                                icon: Icons.receipt_long,
                              ),
                            ),
                          ],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(
                            child: _buildMetricCard(
                              title: 'Eşleşen Daireler',
                              count: matchedCount,
                              amount: matchedTotal,
                              color: AppColors.accentGreen,
                              icon: Icons.check_circle_outline,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildMetricCard(
                              title: 'Zaten Yüklenmiş',
                              count: alreadyUploadedCount,
                              amount: alreadyUploadedTotal,
                              color: Colors.blue,
                              icon: Icons.verified_outlined,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildMetricCard(
                              title: 'Eşleşemeyen',
                              count: unmatchedCount,
                              amount: unmatchedTotal,
                              color: AppColors.accentOrange,
                              icon: Icons.help_outline,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildMetricCard(
                              title: 'Gider / Masraf',
                              count: expenseCount,
                              amount: expenseTotal,
                              color: Colors.blueGrey,
                              icon: Icons.receipt_long,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  if (alreadyUploadedCount > 0) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.blue.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.verified, color: Colors.blue, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '$alreadyUploadedCount aidat işlemi daha önce zaten yüklenmiş / ödenmiş olarak tespit edildi. Mükerrer tahsilatı önlemek için bu işlemler onaya sunulmadı.',
                              style: const TextStyle(
                                color: Colors.blue,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (unmatchedCount > 0) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.accentOrange.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.accentOrange.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: AppColors.accentOrange, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '$unmatchedCount işlem daire ile eşleşmedi. Aşağıdaki "Daire Seç & Eşle" butonundan ilgili daireyi belirleyin.',
                              style: const TextStyle(
                                color: AppColors.accentOrange,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  // Filter Chips
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildFilterTab('Tümü (${queue.length})', 'ALL'),
                        const SizedBox(width: 8),
                        _buildFilterTab('🟢 Eşleşenler ($matchedCount)', 'MATCHED'),
                        const SizedBox(width: 8),
                        _buildFilterTab('🔵 Zaten Yüklenenler ($alreadyUploadedCount)', 'ALREADY_UPLOADED'),
                        const SizedBox(width: 8),
                        _buildFilterTab('🟠 Eşleşmeyenler ($unmatchedCount)', 'UNMATCHED'),
                        const SizedBox(width: 8),
                        _buildFilterTab('⚪ Giderler ($expenseCount)', 'GIDER'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
          ],

          // 5. Reconciliation Queue Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    _filterStatus == 'MATCHED'
                        ? 'Eşleşen İşlemler'
                        : (_filterStatus == 'ALREADY_UPLOADED'
                            ? 'Daha Önce Yüklenen / Ödenen İşlemler'
                            : (_filterStatus == 'UNMATCHED'
                                ? 'Eşleşmeyen İşlemler'
                                : (_filterStatus == 'GIDER' ? 'Gider / Masraf İşlemleri' : 'Tüm Hareketler'))),
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: displayedQueue.isNotEmpty ? AppColors.accentCyan : AppColors.border(context),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${displayedQueue.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              if (displayedQueue.isNotEmpty)
                TextButton(
                  onPressed: () {
                    setState(() {
                      final pendingIds = displayedQueue.where((q) => q.isPendingApproval).map((q) => q.matchId).toSet();
                      if (_selectedMatchIds.containsAll(pendingIds) && pendingIds.isNotEmpty) {
                        _selectedMatchIds.removeAll(pendingIds);
                      } else {
                        _selectedMatchIds.addAll(pendingIds);
                      }
                    });
                  },
                  child: Text(
                    _selectedMatchIds.isNotEmpty ? 'Seçimi Düzenle' : 'Tümünü Seç',
                    style: const TextStyle(fontSize: 12, color: AppColors.accentCyan),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 8),

          // 6. Results List
          if (displayedQueue.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.surface(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Center(
                child: Text(
                  queue.isEmpty
                      ? 'Ayrıştırılmış işlem bulunmuyor. Yukarıdaki formatlardan birini seçerek "Ayrıştır & Eşleştir" butonuna basınız.'
                      : 'Seçili filtreye uygun işlem bulunmuyor.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                ),
              ),
            )
          else
            ...displayedQueue.map((item) => _buildQueueItemCard(context, item)),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildPresetChip(String name, String content) {
    final isSelected = _activePreset == name;
    return InkWell(
      onTap: () => _applyPreset(name, content),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accentCyan.withOpacity(0.15) : AppColors.surface(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppColors.accentCyan : AppColors.border(context),
          ),
        ),
        child: Text(
          name,
          style: TextStyle(
            color: isSelected ? AppColors.accentCyan : AppColors.textSecondary(context),
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildQueueItemCard(BuildContext context, ReconciliationQueueItem item) {
    final isDark = AppColors.isDark(context);
    final isSelected = _selectedMatchIds.contains(item.matchId);
    final isApproved = item.isApproved;
    final isUnmatched = item.status == 'ESLESTIRILEMEDI';
    final isExpense = item.status == 'GIDER';
    final isAlreadyUploaded = item.isAlreadyUploaded;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isApproved
              ? AppColors.accentGreen
              : (isAlreadyUploaded
                  ? Colors.blueAccent
                  : (isUnmatched
                      ? AppColors.accentOrange.withOpacity(0.6)
                      : (isSelected ? AppColors.accentCyan : AppColors.border(context)))),
          width: isApproved || isSelected || isUnmatched || isAlreadyUploaded ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Row: Badges & Checkbox
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isAlreadyUploaded
                          ? Colors.blue.withOpacity(0.15)
                          : (item.confidenceScore == 100
                              ? AppColors.accentGreen.withOpacity(0.15)
                              : (isUnmatched
                                  ? AppColors.accentOrange.withOpacity(0.2)
                                  : AppColors.accentOrange.withOpacity(0.15))),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      isAlreadyUploaded
                          ? 'Daha Önce İşlendi'
                          : (isUnmatched ? 'Daire Bulunamadı' : '%${item.confidenceScore} Güven'),
                      style: TextStyle(
                        color: isAlreadyUploaded
                            ? Colors.blueAccent
                            : (item.confidenceScore == 100
                                ? AppColors.accentGreen
                                : (isUnmatched ? AppColors.accentOrange : AppColors.accentOrange)),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isApproved
                          ? AppColors.accentGreen.withOpacity(0.15)
                          : (isAlreadyUploaded
                              ? Colors.blue.withOpacity(0.15)
                              : (isExpense
                                  ? Colors.grey.withOpacity(0.15)
                                  : (isUnmatched
                                      ? AppColors.accentOrange.withOpacity(0.15)
                                      : AppColors.accentCyan.withOpacity(0.15)))),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      isAlreadyUploaded
                          ? 'ZATEN YÜKLENDİ'
                          : (isExpense
                              ? 'GİDEN / MASRAF'
                              : (isUnmatched ? 'ESLESTIRILEMEDI' : item.status)),
                      style: TextStyle(
                        color: isApproved
                            ? AppColors.accentGreen
                            : (isAlreadyUploaded
                                ? Colors.blueAccent
                                : (isExpense
                                    ? Colors.grey
                                    : (isUnmatched ? AppColors.accentOrange : AppColors.accentCyan))),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              if (!isApproved && !isExpense && !isUnmatched && !isAlreadyUploaded)
                Checkbox(
                  value: isSelected,
                  activeColor: AppColors.accentCyan,
                  onChanged: (val) {
                    setState(() {
                      if (val == true) {
                        _selectedMatchIds.add(item.matchId);
                      } else {
                        _selectedMatchIds.remove(item.matchId);
                      }
                    });
                  },
                )
              else if (isApproved)
                const Icon(Icons.check_circle, color: AppColors.accentGreen, size: 22)
              else if (isAlreadyUploaded)
                Tooltip(
                  message: 'Bu aidat daha önce zaten yüklendi / ödendi. Mükerrer işleme alınamaz.',
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.history, color: Colors.blueAccent, size: 16),
                        SizedBox(width: 4),
                        Text(
                          'Mükerrer Kayıt',
                          style: TextStyle(
                            color: Colors.blueAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 8),

          // Narrative / Description
          Text(
            item.transaction.description,
            style: TextStyle(
              color: AppColors.textPrimary(context),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),

          const SizedBox(height: 10),

          // Matched Details
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isUnmatched ? Icons.home_work_outlined : Icons.apartment,
                          size: 14,
                          color: isUnmatched ? AppColors.accentOrange : AppColors.accentCyan,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          item.matchedUnitDesc,
                          style: TextStyle(
                            color: isUnmatched ? AppColors.accentOrange : AppColors.accentCyan,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (item.matchedResidentName != null) ...[
                          Text(
                            ' • ${item.matchedResidentName}',
                            style: TextStyle(
                              color: AppColors.textSecondary(context),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (item.notes != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.notes!,
                        style: TextStyle(
                          color: isAlreadyUploaded
                              ? Colors.blueAccent
                              : (isUnmatched ? AppColors.accentOrange : AppColors.accentGreen),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '₺${item.transaction.amount.toStringAsFixed(2)}',
                style: TextStyle(
                  color: isExpense ? Colors.redAccent : AppColors.textPrimary(context),
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),

          // Action Buttons: Manual Unit Assignment & Edit
          if (isUnmatched) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _openManualAssignment(context, item),
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
          ] else if (!isApproved && !isExpense && !isAlreadyUploaded) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (item.matchedUnitNumber != null) ...[
                  TextButton.icon(
                    onPressed: () => _showSingleItemConfirmationDialog(context, item),
                    icon: const Icon(Icons.check_circle_outline, size: 15, color: AppColors.accentGreen),
                    label: const Text(
                      'Eşleşmeyi Onayla',
                      style: TextStyle(
                        color: AppColors.accentGreen,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                TextButton.icon(
                  onPressed: () => _openManualAssignment(context, item),
                  icon: const Icon(Icons.edit_note, size: 15, color: AppColors.accentCyan),
                  label: const Text(
                    'Daireyi Değiştir',
                    style: TextStyle(
                      color: AppColors.accentCyan,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openManualAssignment(BuildContext context, ReconciliationQueueItem item) async {
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

      // Confirm reconciliation with optional message to host and remember sender IBAN preference
      widget.controller.confirmReconciliation(
        [item.matchId],
        optionalHostMessage: sendMsg ? msgText : null,
        rememberSenderIban: rememberIban,
      );

      setState(() {
        _selectedMatchIds.remove(item.matchId);
      });

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

  Future<void> _showSingleItemConfirmationDialog(
    BuildContext context,
    ReconciliationQueueItem item,
  ) async {
    final residentName = item.matchedResidentName ?? 'Kat Sakini';
    final unitDesc = item.matchedUnitDesc;
    final txn = item.transaction;

    bool sendMessage = true;
    final messageController = TextEditingController(
      text:
          'Sayın $residentName, $unitDesc nolu bağımsız bölümünüze ait ₺${txn.amount.toStringAsFixed(2)} tutarındaki aidat ödemeniz onaylanmış ve kayıtlara işlenmiştir. Teşekkür ederiz.',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final isDark = AppColors.isDark(dialogCtx);
            return Dialog(
              backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 520),
                padding: const EdgeInsets.all(24),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.accentGreen.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.verified_user_outlined, color: AppColors.accentGreen, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Ev Sahibi & Ödeme Eşleştirme Onayı',
                                  style: TextStyle(
                                    color: AppColors.textPrimary(dialogCtx),
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$unitDesc ($residentName) için ödeme onayı',
                                  style: TextStyle(
                                    color: AppColors.textSecondary(dialogCtx),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(dialogCtx, false),
                            icon: const Icon(Icons.close, size: 20),
                            color: AppColors.textSecondary(dialogCtx),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      // Host / Payment Card
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.surface(dialogCtx),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.border(dialogCtx)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.apartment, color: AppColors.accentCyan, size: 16),
                                    const SizedBox(width: 6),
                                    Text(
                                      unitDesc,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                    Text(
                                      ' • $residentName',
                                      style: TextStyle(color: AppColors.textSecondary(dialogCtx), fontSize: 12),
                                    ),
                                  ],
                                ),
                                Text(
                                  '₺${txn.amount.toStringAsFixed(2)}',
                                  style: const TextStyle(color: AppColors.accentGreen, fontSize: 15, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              txn.description,
                              style: TextStyle(color: AppColors.textSecondary(dialogCtx), fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),

                      // Optional Message Request Section
                      Row(
                        children: [
                          Checkbox(
                            value: sendMessage,
                            activeColor: AppColors.accentCyan,
                            onChanged: (val) {
                              setDialogState(() {
                                sendMessage = val ?? false;
                              });
                            },
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setDialogState(() {
                                  sendMessage = !sendMessage;
                                });
                              },
                              child: Text(
                                'Ev Sahibine Bilgilendirme Mesajı Gönder (Opsiyonel)',
                                style: TextStyle(
                                  color: AppColors.textPrimary(dialogCtx),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (sendMessage) ...[
                        const SizedBox(height: 6),
                        TextField(
                          controller: messageController,
                          maxLines: 3,
                          style: TextStyle(color: AppColors.textPrimary(dialogCtx), fontSize: 12),
                          decoration: InputDecoration(
                            hintText: 'Ev sahibine iletilecek mesaj metnini düzenleyebilirsiniz...',
                            filled: true,
                            fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: AppColors.border(dialogCtx)),
                            ),
                            contentPadding: const EdgeInsets.all(12),
                          ),
                        ),
                      ],

                      const SizedBox(height: 22),

                      // Actions
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(dialogCtx, false),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Text('Vazgeç'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => Navigator.pop(dialogCtx, true),
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text('Eşleştirmeyi Onayla'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.accentGreen,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (confirmed == true && mounted) {
      widget.controller.confirmReconciliation(
        [item.matchId],
        optionalHostMessage: sendMessage ? messageController.text.trim() : null,
      );
      setState(() {
        _selectedMatchIds.remove(item.matchId);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.reconciliationSuccessMessage ?? 'Banka işlemi başarıyla onaylandı!',
          ),
          backgroundColor: AppColors.accentGreen,
        ),
      );
    }
  }

  Future<void> _showBatchConfirmationDialog(BuildContext context) async {
    final selectedItems = widget.controller.reconciliationQueue
        .where((q) => _selectedMatchIds.contains(q.matchId))
        .toList();
    if (selectedItems.isEmpty) return;

    final totalAmount = selectedItems.fold<Decimal>(
      Decimal.zero,
      (sum, item) => sum + item.transaction.amount,
    );

    bool sendMessage = true;
    final messageController = TextEditingController(
      text:
          'Sayın Kat Sakini, aidat ödemeniz banka ekstresi ile eşleştirilmiş ve tahsilatınız muhasebeleştirilmiştir. Teşekkür ederiz.',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final isDark = AppColors.isDark(dialogCtx);
            return Dialog(
              backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 520),
                padding: const EdgeInsets.all(24),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.accentGreen.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.check_circle_outline, color: AppColors.accentGreen, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Eşleştirme ve Tahsilat Onayı',
                                  style: TextStyle(
                                    color: AppColors.textPrimary(dialogCtx),
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${selectedItems.length} daire için ödeme onayı ve opsiyonel bildirim',
                                  style: TextStyle(
                                    color: AppColors.textSecondary(dialogCtx),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(dialogCtx, false),
                            icon: const Icon(Icons.close, size: 20),
                            color: AppColors.textSecondary(dialogCtx),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      // Selected Items Summary
                      Container(
                        constraints: const BoxConstraints(maxHeight: 180),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.surface(dialogCtx),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.border(dialogCtx)),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: selectedItems.length,
                          separatorBuilder: (_, __) => Divider(color: AppColors.border(dialogCtx), height: 12),
                          itemBuilder: (context, i) {
                            final item = selectedItems[i];
                            return Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.apartment, size: 14, color: AppColors.accentCyan),
                                    const SizedBox(width: 6),
                                    Text(
                                      item.matchedUnitDesc,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                    ),
                                    if (item.matchedResidentName != null) ...[
                                      Text(
                                        ' • ${item.matchedResidentName}',
                                        style: TextStyle(color: AppColors.textSecondary(dialogCtx), fontSize: 11),
                                      ),
                                    ],
                                  ],
                                ),
                                Text(
                                  '₺${item.transaction.amount.toStringAsFixed(2)}',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppColors.accentGreen),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Total Row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Toplam Onaylanacak:', style: TextStyle(color: AppColors.textSecondary(dialogCtx), fontSize: 12, fontWeight: FontWeight.w600)),
                          Text('₺${totalAmount.toStringAsFixed(2)}', style: const TextStyle(color: AppColors.accentGreen, fontSize: 16, fontWeight: FontWeight.bold)),
                        ],
                      ),

                      const SizedBox(height: 18),

                      // Optional Message Request Section
                      Row(
                        children: [
                          Checkbox(
                            value: sendMessage,
                            activeColor: AppColors.accentCyan,
                            onChanged: (val) {
                              setDialogState(() {
                                sendMessage = val ?? false;
                              });
                            },
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setDialogState(() {
                                  sendMessage = !sendMessage;
                                });
                              },
                              child: Text(
                                'Ev Sahiplerine / Sakinlere Bilgilendirme Mesajı Gönder (Opsiyonel)',
                                style: TextStyle(
                                  color: AppColors.textPrimary(dialogCtx),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (sendMessage) ...[
                        const SizedBox(height: 6),
                        TextField(
                          controller: messageController,
                          maxLines: 3,
                          style: TextStyle(color: AppColors.textPrimary(dialogCtx), fontSize: 12),
                          decoration: InputDecoration(
                            hintText: 'Ev sahiplerine iletilecek mesaj metnini düzenleyebilirsiniz...',
                            filled: true,
                            fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: AppColors.border(dialogCtx)),
                            ),
                            contentPadding: const EdgeInsets.all(12),
                          ),
                        ),
                      ],

                      const SizedBox(height: 22),

                      // Actions
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(dialogCtx, false),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Text('Vazgeç'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => Navigator.pop(dialogCtx, true),
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text('Onayla ve Kaydet'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.accentGreen,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (confirmed == true && mounted) {
      widget.controller.confirmReconciliation(
        _selectedMatchIds.toList(),
        optionalHostMessage: sendMessage ? messageController.text.trim() : null,
      );
      setState(() {
        _selectedMatchIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.reconciliationSuccessMessage ?? 'Banka işlemleri başarıyla onaylandı!',
          ),
          backgroundColor: AppColors.accentGreen,
        ),
      );
    }
  }

  Widget _buildMetricCard({
    required String title,
    required int count,
    required Decimal amount,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$count İşlem',
            style: TextStyle(
              color: color,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '₺${amount.toStringAsFixed(2)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textSecondary(context),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterTab(String label, String filterKey) {
    final isSelected = _filterStatus == filterKey;
    return InkWell(
      onTap: () {
        setState(() {
          _filterStatus = filterKey;
        });
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accentCyan : AppColors.surface(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppColors.accentCyan : AppColors.border(context),
          ),
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
    );
  }

  void _showChangeBankAccountDialog(BuildContext context) {
    final isDark = AppColors.isDark(context);
    final currentAccount = widget.controller.siteBankAccount;
    SupportedBank selectedBank = currentAccount?.supportedBank ?? SupportedBank.kuveytTurk;
    final ibanController = TextEditingController(text: currentAccount?.iban ?? 'TR620020500009863791600001');
    final holderController = TextEditingController(text: currentAccount?.accountHolder ?? 'Begonya Sitesi Yönetimi');
    String? dialogError;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return Dialog(
              backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 480),
                padding: const EdgeInsets.all(24),
                child: SingleChildScrollView(
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
                            child: const Icon(Icons.account_balance, color: AppColors.accentCyan, size: 22),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Site Banka Hesabı Tanımla',
                                  style: TextStyle(
                                    color: AppColors.textPrimary(context),
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  'Banka seçimine göre ekstre formatı otomatik belirlenir',
                                  style: TextStyle(
                                    color: AppColors.textSecondary(context),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      // Bank Selector
                      Text(
                        'Banka Seçimi',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border(context)),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<SupportedBank>(
                            value: selectedBank,
                            isExpanded: true,
                            dropdownColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                            items: SupportedBank.values.map((bank) {
                              return DropdownMenuItem<SupportedBank>(
                                value: bank,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        bank.displayName,
                                        style: TextStyle(
                                          color: AppColors.textPrimary(context),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.accentCyan.withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        bank.statementFormat,
                                        style: const TextStyle(
                                          color: AppColors.accentCyan,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                            onChanged: (SupportedBank? newBank) {
                              if (newBank != null) {
                                setDialogState(() {
                                  selectedBank = newBank;
                                });
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      // Derived Format Banner
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.accentCyan.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.accentCyan.withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.auto_awesome, color: AppColors.accentCyan, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Bu banka için ekstre formatı otomatik olarak ${selectedBank.statementFormat} (${selectedBank.fileExtension}) olarak tanımlanacaktır.',
                                style: const TextStyle(
                                  color: AppColors.accentCyan,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      // IBAN
                      Text(
                        'IBAN Numarası',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: ibanController,
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          hintText: 'TR000000000000000000000000',
                          hintStyle: TextStyle(color: AppColors.textSecondary(context).withOpacity(0.5)),
                          filled: true,
                          fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: AppColors.border(context)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      // Account Holder
                      Text(
                        'Hesap Sahibi / Site Unvanı',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: holderController,
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Örn. Begonya Sitesi Yönetimi',
                          hintStyle: TextStyle(color: AppColors.textSecondary(context).withOpacity(0.5)),
                          filled: true,
                          fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: AppColors.border(context)),
                          ),
                        ),
                      ),
                      if (dialogError != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.accentRed.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.accentRed.withOpacity(0.3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline, color: AppColors.accentRed, size: 16),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  dialogError!,
                                  style: const TextStyle(color: AppColors.accentRed, fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(dialogCtx).pop(),
                            child: Text(
                              'Vazgeç',
                              style: TextStyle(color: AppColors.textSecondary(context)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: () {
                              final success = widget.controller.configureBankAccount(
                                bankCode: selectedBank.code,
                                iban: ibanController.text,
                                accountHolder: holderController.text,
                              );
                              if (success) {
                                Navigator.of(dialogCtx).pop();
                                setState(() {
                                  // Update active sample according to newly selected bank
                                  if (selectedBank.statementFormat == 'MT940') {
                                    _applyPreset('SWIFT MT940', BankStatementReconciliationPage.sampleSwiftMt940);
                                  } else if (selectedBank == SupportedBank.kuveytTurk) {
                                    _applyPreset('Kuveyt Türk (.xlsx)', BankStatementReconciliationPage.sampleKuveytTurkExcel);
                                  } else if (selectedBank == SupportedBank.isBankasi) {
                                    _applyPreset('İş Bankası CSV', BankStatementReconciliationPage.sampleIsBankCsv);
                                  } else {
                                    _applyPreset('Garanti BBVA', BankStatementReconciliationPage.sampleGarantiExcel);
                                  }
                                });
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Banka hesabı ${selectedBank.displayName} olarak güncellendi. Yeni ekstre formatı: ${selectedBank.statementFormat}',
                                    ),
                                    backgroundColor: AppColors.accentGreen,
                                  ),
                                );
                              } else {
                                setDialogState(() {
                                  dialogError = widget.controller.bankStatementError;
                                });
                              }
                            },
                            icon: const Icon(Icons.check, size: 16),
                            label: const Text('Kaydet & Formatı Uygula'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.accentCyan,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
