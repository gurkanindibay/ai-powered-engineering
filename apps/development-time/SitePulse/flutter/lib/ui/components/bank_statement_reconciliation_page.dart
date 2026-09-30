import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../domain/models/dues_models.dart';
import '../dashboard/dashboard_controller.dart';
import '../theme/app_theme.dart';
import 'app_fullscreen_page.dart';

class BankStatementReconciliationPage extends StatefulWidget {
  final DashboardController controller;

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

  static const String sampleGarantiExcel =
      'HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33';

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

  @override
  void initState() {
    super.initState();
    _textController.text = sampleGarantiExcel;
    // Auto-parse default sample on open so manager sees instant match
    widget.controller.parseBankStatement(sampleGarantiExcel);
    _selectAllPending();
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
    widget.controller.parseBankStatement(content);
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
                : () {
                    widget.controller.confirmReconciliation(_selectedMatchIds.toList());
                    setState(() {
                      _selectedMatchIds.clear();
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          widget.controller.reconciliationSuccessMessage ??
                              'Banka işlemleri başarıyla onaylandı!',
                        ),
                        backgroundColor: AppColors.accentGreen,
                      ),
                    );
                  },
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

          const SizedBox(height: 18),

          // 2. Preset Selectors
          Text(
            'Örnek Banka Ekstre Formatları',
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
                _buildPresetChip('Garanti BBVA', sampleGarantiExcel),
                const SizedBox(width: 8),
                _buildPresetChip('İş Bankası CSV', sampleIsBankCsv),
                const SizedBox(width: 8),
                _buildPresetChip('SWIFT MT940', sampleSwiftMt940),
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
                widget.controller.parseBankStatement(_textController.text);
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

          const SizedBox(height: 24),

          // 4. Reconciliation Queue Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    'Eşleşen İşlemler',
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
                      color: queue.isNotEmpty ? AppColors.accentCyan : AppColors.border(context),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${queue.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              if (queue.isNotEmpty)
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_selectedMatchIds.length == queue.length) {
                        _selectedMatchIds.clear();
                      } else {
                        _selectAllPending();
                      }
                    });
                  },
                  child: Text(
                    _selectedMatchIds.length == queue.length ? 'Seçimi Kaldır' : 'Tümünü Seç',
                    style: const TextStyle(fontSize: 12, color: AppColors.accentCyan),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 8),

          // 5. Results List
          if (queue.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.surface(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Center(
                child: Text(
                  'Ayrıştırılmış işlem bulunmuyor. Yukarıdaki formatlardan birini seçerek "Ayrıştır & Eşleştir" butonuna basınız.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                ),
              ),
            )
          else
            ...queue.map((item) => _buildQueueItemCard(context, item)),

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

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isApproved
              ? AppColors.accentGreen
              : (isSelected ? AppColors.accentCyan : AppColors.border(context)),
          width: isApproved || isSelected ? 1.5 : 1.0,
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
                      color: item.confidenceScore == 100
                          ? AppColors.accentGreen.withOpacity(0.15)
                          : AppColors.accentOrange.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '%${item.confidenceScore} Güven',
                      style: TextStyle(
                        color: item.confidenceScore == 100 ? AppColors.accentGreen : AppColors.accentOrange,
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
                          : AppColors.accentOrange.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      item.status,
                      style: TextStyle(
                        color: isApproved ? AppColors.accentGreen : AppColors.accentOrange,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              if (!isApproved)
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
              else
                const Icon(Icons.check_circle, color: AppColors.accentGreen, size: 22),
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
                        const Icon(Icons.apartment, size: 14, color: AppColors.accentCyan),
                        const SizedBox(width: 4),
                        Text(
                          item.matchedUnitDesc,
                          style: const TextStyle(
                            color: AppColors.accentCyan,
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
                        style: const TextStyle(color: AppColors.accentGreen, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '₺${item.transaction.amount.toStringAsFixed(2)}',
                style: TextStyle(
                  color: AppColors.textPrimary(context),
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
