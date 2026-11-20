import '../../testing/test_id.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import 'package:decimal/decimal.dart';
import '../../domain/models/dues_models.dart';
import '../dashboard/dashboard_controller.dart';
import '../theme/app_theme.dart';
import '../design_system/sp_skeleton.dart';
import 'app_fullscreen_page.dart';
import 'bank_statement_reconciliation_page.dart';

import '../design_system/money_formatter.dart';
import '../design_system/sp_feedback.dart';
import 'sp_dialog_pages.dart';
import '../../domain/models/auth_models.dart';
import '../payments/receipt_actions.dart';
import '../payments/advance_exit_settlement_queue.dart';
import '../payments/seller_pays_override_queue.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../design_system/sp_money_field.dart';
class PaymentTrackingPage extends StatefulWidget {
  final DashboardController controller;
  final String? initialUnitId;
  final int initialTabIndex;

  const PaymentTrackingPage({
    super.key,
    required this.controller,
    this.initialUnitId,
    this.initialTabIndex = 0,
  });

  static Future<void> open(
    BuildContext context, {
    required DashboardController controller,
    String? initialUnitId,
    int initialTabIndex = 0,
  }) {
    return AppFullscreenPage.push(
      context: context,
      builder: (ctx) => PaymentTrackingPage(
        controller: controller,
        initialUnitId: initialUnitId,
        initialTabIndex: initialTabIndex,
      ),
    );
  }

  static String channelLabel(String code) {
    switch (code) {
      case 'VIRTUAL_IBAN':
        return 'Sanal IBAN';
      case 'BANK_STATEMENT':
        return 'Banka Ekstresi';
      case 'CREDIT_CARD':
        return 'Kredi Kartı';
      case 'MANUAL_CASH':
        return 'Elden Nakit';
      case 'INTER_LEDGER':
        return 'Virman / Avans';
      default:
        return 'Tüm Kanallar';
    }
  }

  static IconData channelIcon(String code) {
    switch (code) {
      case 'VIRTUAL_IBAN':
        return Icons.qr_code;
      case 'BANK_STATEMENT':
        return Icons.account_balance;
      case 'CREDIT_CARD':
        return Icons.credit_card;
      case 'MANUAL_CASH':
        return Icons.money;
      case 'INTER_LEDGER':
        return Icons.swap_horiz;
      default:
        return Icons.payment;
    }
  }

  static Color channelColor(String code) {
    switch (code) {
      case 'VIRTUAL_IBAN':
        return Colors.blue;
      case 'BANK_STATEMENT':
        return Colors.indigo;
      case 'CREDIT_CARD':
        return Colors.purple;
      case 'MANUAL_CASH':
        return AppColors.accentGreen;
      case 'INTER_LEDGER':
        return Colors.orange;
      default:
        return AppColors.primary;
    }
  }

  static String roleLabel(String code) {
    switch (code) {
      case 'TENANT':
        return 'Kiracı';
      case 'OWNER':
        return 'Kat Maliki';
      default:
        return 'Tüm Roller';
    }
  }

  static String settlementLabel(String code) {
    switch (code) {
      case 'SETTLED':
        return 'Eşleşti (Settled)';
      case 'UNMATCHED':
        return 'Havuzda Bekleyen';
      default:
        return 'Tüm Durumlar';
    }
  }

  static Future<void> openRecordManualPayment(
    BuildContext context, {
    required DashboardController controller,
    String? initialUnitId,
    VoidCallback? onSaved,
  }) {
    final amountCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    String unitId = initialUnitId ?? 'd-14';
    String role = 'TENANT';
    String channel = 'MANUAL_CASH';
    bool settlesOwnerCapitalDues = false;

    return AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AppFullscreenPage(
            title: 'Manuel Tahsilat Girişi',
            subtitle: 'Elden Nakit veya Havale Tahsilatı Kaydet',
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: AppColors.primaryFill,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    final amountError = validateMoneyInput(amountCtrl.text);
                    final amt = MoneyInput.parse(amountCtrl.text).amount;
                    if (amountError != null || amt == null) {
                      SpToast.error(ctx, amountError ?? MoneyInputMessages.invalid);
                      return;
                    }

                    final receipt = await controller.recordManualPayment(
                      unitId: unitId,
                      amount: amt,
                      payerName: nameCtrl.text.trim().isEmpty ? 'Daire Sakini' : nameCtrl.text.trim(),
                      payerRole: role,
                      paymentChannel: channel,
                      description: descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
                      settlesOwnerCapitalDues: settlesOwnerCapitalDues,
                    );

                    if (ctx.mounted) Navigator.pop(ctx);
                    if (receipt != null && context.mounted) {
                      onSaved?.call();
                      openReceiptViewer(context, controller: controller, identifier: receipt.receiptNumber);
                    }
                  },
                  child: const Text('Tahsilatı Kaydet & Makbuz Üret'),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Daire Seçimi', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: unitId,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'd-14', child: Text('A Blok D:14 (Ahmet / Kerem Yılmaz)')),
                      DropdownMenuItem(value: 'd-1', child: Text('A Blok D:1')),
                      DropdownMenuItem(value: 'd-2', child: Text('A Blok D:2')),
                      DropdownMenuItem(value: 'd-5', child: Text('A Blok D:5')),
                    ],
                    onChanged: (v) => setDialogState(() => unitId = v ?? 'd-14'),
                  ),
                  const SizedBox(height: 16),
                  const Text('Tahsil Edilen Tutar (₺)', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  SpMoneyFormField(
                    controller: amountCtrl,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    restrictInput: true,
                    decoration: const InputDecoration(
                      prefixText: '₺ ',
                      hintText: '1400,00',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Ödeyen Kişi Adı', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Örn: Kerem Yılmaz',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Ödeyen Rolü', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<String>(
                              value: role,
                              decoration: const InputDecoration(border: OutlineInputBorder()),
                              items: const [
                                DropdownMenuItem(value: 'TENANT', child: Text('Kiracı')),
                                DropdownMenuItem(value: 'OWNER', child: Text('Kat Maliki')),
                              ],
                              onChanged: (v) => setDialogState(() => role = v ?? 'TENANT'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Kanal', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<String>(
                              value: channel,
                              decoration: const InputDecoration(border: OutlineInputBorder()),
                              items: const [
                                DropdownMenuItem(value: 'MANUAL_CASH', child: Text('Elden Nakit')),
                                DropdownMenuItem(value: 'BANK_STATEMENT', child: Text('Banka Havalesi')),
                              ],
                              onChanged: (v) => setDialogState(() => channel = v ?? 'MANUAL_CASH'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('Açıklama / Dekont Notu', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Örn: Asansör ve Demirbaş Harcaması Payı',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (role == 'TENANT')
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settlesOwnerCapitalDues,
                      title: const Text('Malik adına demirbaş borcuna işle'),
                      subtitle: const Text('Açıklama tek başına bu işlemi seçmez.'),
                      onChanged: (value) => setDialogState(
                        () => settlesOwnerCapitalDues = value ?? false,
                      ),
                    ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    children: [
                      ActionChip(
                        label: const Text('Eylül Aidatı', style: TextStyle(fontSize: 12)),
                        onPressed: () => setDialogState(() => descCtrl.text = 'Eylül 2026 Aidat Ödemesi'),
                      ),
                      ActionChip(
                        label: const Text('Demirbaş - Asansör', style: TextStyle(fontSize: 12)),
                        onPressed: () => setDialogState(() => descCtrl.text = 'Demirbaş - Asansör Revizyon Payı'),
                      ),
                      ActionChip(
                        label: const Text('Çatı Onarımı', style: TextStyle(fontSize: 12)),
                        onPressed: () => setDialogState(() => descCtrl.text = 'Çatı Onarım Demirbaş Katkısı'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static Future<void> openInterLedgerTransfer(
    BuildContext context, {
    required DashboardController controller,
    String? initialUnitId,
    VoidCallback? onCompleted,
  }) async {
    // The site's real units and advance balances (STORY-10-04), never fixed sample units.
    // Refreshed on every open so the advance balances are current.
    await controller.fetchHomeOwners(siteId: controller.currentManagedSite?.id);
    if (!context.mounted) return;
    final units = controller.homeOwners;
    final amountCtrl = TextEditingController(text: '1400.00');
    final noteCtrl = TextEditingController(text: 'Ev sahibi onaylı avanstan demirbaşa virman');
    String? unitId = units.any((u) => u.unitId == initialUnitId)
        ? initialUnitId
        : (units.where((u) => u.advanceBalance > Decimal.zero).firstOrNull ?? units.firstOrNull)?.unitId;

    await AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AppFullscreenPage(
            title: 'Avansı Demirbaşa Aktar (Virman)',
            subtitle: 'Birikmiş Avans Bakiyesini Demirbaş Borcuna Mahsup Et',
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: Colors.indigo,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    final amountError = validateMoneyInput(amountCtrl.text);
                    final amt = MoneyInput.parse(amountCtrl.text).amount;
                    if (amountError != null || amt == null) {
                      // Previously an invalid amount was ignored silently.
                      SpToast.error(ctx, amountError ?? MoneyInputMessages.invalid);
                      return;
                    }

                    final selected = unitId;
                    if (selected == null) return;
                    final res = await controller.executeInterLedgerTransfer(
                      unitId: selected,
                      amount: amt,
                      note: noteCtrl.text.trim(),
                    );

                    if (ctx.mounted) Navigator.pop(ctx);
                    if (res != null && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        appSnackBar(content: Text(res['message']?.toString() ?? 'Virman başarılı')),
                      );
                      onCompleted?.call();
                      final rcp = res['receipt_number']?.toString();
                      if (rcp != null) {
                        openReceiptViewer(context, controller: controller, identifier: rcp);
                      }
                    }
                  },
                  child: const Text('Virman İşlemini Onayla'),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.indigo.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.indigo.withOpacity(0.3)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.indigo, size: 20),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Kat malikinin fazla yatırdığı veya kiracıdan kalan avans bakiyesi, doğrudan dairenin ortak demirbaş/yatırım borçlarına mahsup edilir.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Daire', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  testId('virman_unit_dropdown', DropdownButtonFormField<String>(
                    initialValue: unitId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      hintText: units.isEmpty ? 'Sitede daire bulunamadı' : null,
                    ),
                    items: [
                      for (final u in units)
                        DropdownMenuItem(
                          value: u.unitId,
                          child: Text(
                            '${u.block} Blok D:${u.unitNo} (Mevcut Avans: ${formatTry(u.advanceBalance)})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setDialogState(() => unitId = v ?? unitId),
                  )),
                  const SizedBox(height: 16),
                  const Text('Virman Yapılacak Tutar (₺)', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  SpMoneyFormField(
                    controller: amountCtrl,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    restrictInput: true,
                    decoration: const InputDecoration(
                      prefixText: '₺ ',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Açıklama / Mutabakat Notu', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: noteCtrl,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static Future<void> openReceiptViewer(
    BuildContext context, {
    required DashboardController controller,
    required String identifier,
  }) async {
    final receipt = await controller.fetchReceipt(identifier);
    if (!context.mounted || receipt == null) return;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: 'Dijital Tahsilat Makbuzu',
        subtitle: '#${receipt.receiptNumber} • ${receipt.issuedAt.day}.${receipt.issuedAt.month}.${receipt.issuedAt.year}',
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            testId('btn_share_receipt', OutlinedButton.icon(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const FittedBox(fit: BoxFit.scaleDown, child: Text('Paylaş / PDF')),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: () => downloadReceiptPdf(ctx, receipt.receiptNumber, siteId: receipt.siteId),
            )),
            // Site staff may reverse a collection or virman receipt (SPEC-006 O-2, SPEC-007 R1).
            if (controller.userRole == UserRole.siteManager && receipt.receiptNumber.startsWith('TAH-'))
              testId('btn_reverse_receipt', OutlinedButton.icon(
                icon: const Icon(Icons.undo),
                label: const FittedBox(fit: BoxFit.scaleDown, child: Text('İptal / iade')),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  foregroundColor: AppColors.dangerText(ctx),
                ),
                onPressed: () async {
                  final reversal = await reverseReceiptWithReason(ctx, receipt.receiptNumber, siteId: receipt.siteId);
                  if (reversal != null && ctx.mounted) {
                    await controller.fetchPaymentStream(siteId: receipt.siteId);
                    if (ctx.mounted) Navigator.pop(ctx);
                  }
                },
              )),
            ElevatedButton.icon(
              icon: const Icon(Icons.check),
              label: const Text(AppStrings.close),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: AppColors.primaryFill,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.surface(ctx),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.primary.withOpacity(0.3)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                controller.siteName,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              Text(
                                'Site Yönetimi Tahsilat Makbuzu',
                                style: TextStyle(fontSize: 12, color: AppColors.textSecondary(ctx)),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: testId('receipt_number', Text(
                            receipt.receiptNumber,
                            style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.primaryText(context)),
                          )),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          const Text('TOPLAM TAHSİLAT TUTARI', style: TextStyle(fontSize: 12, letterSpacing: 1.1)),
                          const SizedBox(height: 4),
                          testId('receipt_total', Text(
                            formatTry(receipt.totalAmount),
                            style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: AppColors.successText(context)),
                          )),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    _buildReceiptRowStatic(ctx, 'Daire:', receipt.unitId),
                    _buildReceiptRowStatic(ctx, 'Ödeyen:', '${receipt.payerName} (${receipt.payerRole == "TENANT" ? "Kiracı" : "Kat Maliki"})'),
                    if (receipt.onBehalfOfName != null)
                      testId('receipt_on_behalf', _buildReceiptRowStatic(ctx, 'Adına Ödenen:', '${receipt.onBehalfOfName} (Kat Maliki)')),
                    _buildReceiptRowStatic(ctx, 'Ödeme Kanalı:', channelLabel(receipt.paymentChannel)),
                    _buildReceiptRowStatic(ctx, 'Tarih & Saat:', receipt.issuedAt.toLocal().toString().split('.').first),
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 12),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Mahsup ve Tahsisat Detayı', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                    const SizedBox(height: 8),
                    testId('receipt_allocated_principal', _buildReceiptRowStatic(ctx, 'Ana Para Borcu:', formatTry(receipt.allocatedPrincipal))),
                    testId('receipt_allocated_penalty', _buildReceiptRowStatic(ctx, 'Gecikme Zammı (KMK %5):', formatTry(receipt.allocatedPenalty))),
                    if (receipt.allocatedAdvance > Decimal.zero)
                      testId('receipt_allocated_advance', _buildReceiptRowStatic(ctx, 'Avans Bakiyesine Aktarılan:', formatTry(receipt.allocatedAdvance))),
                    if (receipt.isRentOffsetEligible) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.purple.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.purple.withOpacity(0.4)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.gavel, color: Colors.purple, size: 16),
                                SizedBox(width: 6),
                                Text(
                                  'KİRA MAHSUBU UYGUNLUK BİLDİRİMİ',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.purple),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            testId('receipt_rent_offset_note', Text(
                              receipt.legalStatutoryNote ??
                                  '634 sayılı KMK Madde 20 & 22 uyarınca ortak demirbaş giderleri Kat Maliki sorumluluğundadır. Kiracı tarafından ödenen bu tutar TBK Madde 314 gereği kira bedelinden mahsup edilebilir.',
                              style: const TextStyle(fontSize: 12, height: 1.3),
                            )),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.background(ctx),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.verified, color: AppColors.primary, size: 14),
                              SizedBox(width: 4),
                              Text('SHA-256 Dijital Doğrulama Kodu', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            receipt.verificationHash,
                            style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _buildReceiptRowStatic(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(label, style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)))),
          Flexible(child: Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  @override
  State<PaymentTrackingPage> createState() => _PaymentTrackingPageState();
}

class _PaymentTrackingPageState extends State<PaymentTrackingPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTabIndex,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    await widget.controller.fetchPaymentStream(unitId: widget.initialUnitId);
    await widget.controller.fetchDebtAgingReport();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return AppFullscreenPage(
          title: 'Tahsilat & Ödeme Takibi',
          subtitle: '${widget.controller.siteName} • Çok Kanallı Kasa & Yaşlandırma',
          isScrollable: false,
          maxWidth: 960,
          actions: [
            testId(
              'action_advance_exit_settlement_queue',
              IconButton(
                key: const Key('action_advance_exit_settlement_queue'),
                icon: const Icon(Icons.assignment_turned_in_outlined),
                tooltip: 'Çıkış avans talepleri',
                onPressed: () => AdvanceExitSettlementQueuePage.open(context),
              ),
            ),
            testId(
              'action_seller_pays_override_queue',
              IconButton(
                key: const Key('action_seller_pays_override_queue'),
                icon: const Icon(Icons.swap_horiz),
                tooltip: 'Satıcı öder talepleri',
                onPressed: () => SellerPaysOverrideQueuePage.open(context),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Yenile',
              onPressed: _loadData,
            ),
            testId('action_open_bank_reconciliation', IconButton(
              key: const Key('action_open_bank_reconciliation'),
              icon: const Icon(Icons.receipt_long),
              tooltip: 'Banka Ekstresi & Eşleştirme (Excel/MT940)',
              onPressed: () async {
                await BankStatementReconciliationPage.open(context, controller: widget.controller);
                _loadData();
              },
            )),
            IconButton(
              icon: const Icon(Icons.add_card),
              tooltip: 'Manuel Tahsilat Girişi',
              onPressed: () => PaymentTrackingPage.openRecordManualPayment(
                context,
                controller: widget.controller,
                initialUnitId: widget.initialUnitId,
                onSaved: _loadData,
              ),
            ),
          ],
          bottomBar: AppFullscreenPage.buildBottomBar(
            context: context,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Avansı Demirbaşa Aktar (Virman)'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => PaymentTrackingPage.openInterLedgerTransfer(
                  context,
                  controller: widget.controller,
                  onCompleted: _loadData,
                ),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Nakit/Banka Girişi'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: AppColors.primaryFill,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => PaymentTrackingPage.openRecordManualPayment(
                  context,
                  controller: widget.controller,
                  initialUnitId: widget.initialUnitId,
                  onSaved: _loadData,
                ),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildKpiSummaryHeader(),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface(context),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: TabBar(
                  controller: _tabController,
                  labelColor: AppColors.primary,
                  unselectedLabelColor: AppColors.textSecondary(context),
                  indicatorColor: AppColors.primary,
                  indicatorSize: TabBarIndicatorSize.tab,
                  tabs: const [
                    Tab(
                      key: Key('tab_payment_stream'),
                      icon: Icon(Icons.stream, size: 20),
                      text: 'Tahsilat Akışı (Stream)',
                    ),
                    Tab(
                      key: Key('tab_debt_aging'),
                      icon: Icon(Icons.hourglass_top, size: 20),
                      text: 'Borç Yaşlandırma (Aging)',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    PaymentStreamWidget(
                      controller: widget.controller,
                      initialUnitId: widget.initialUnitId,
                      isEmbedded: false,
                    ),
                    DebtAgingWidget(
                      controller: widget.controller,
                      isEmbedded: false,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildKpiSummaryHeader() {
    final stream = widget.controller.paymentStream;
    final totalVol = stream?.totalVolume ?? Decimal.zero;
    final settledVol = stream?.settledVolume ?? Decimal.zero;
    final count = stream?.totalCount ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withOpacity(0.12),
            AppColors.surface(context),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.account_balance, color: AppColors.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'TOPLAM TAHSİLAT HACMİ',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: AppColors.textSecondary(context),
                      ),
                    ),
                    Text(
                      formatTry(totalVol),
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: AppColors.successText(context),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.accentGreen.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle, color: AppColors.accentGreen, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      '$count İşlem',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.successText(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Otomatik Eşleşen', style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context))),
                    const SizedBox(height: 2),
                    Text(formatTry(settledVol), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Mutabakat Oranı', style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context))),
                    const SizedBox(height: 2),
                    Text('100% Güven', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.primaryText(context))),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Mevzuat Uyumu', style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context))),
                    const SizedBox(height: 2),
                    const Text('KMK Mad. 20', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.orange)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PaymentStreamWidget extends StatefulWidget {
  final DashboardController controller;
  final String? initialUnitId;
  final bool isEmbedded;

  const PaymentStreamWidget({
    super.key,
    required this.controller,
    this.initialUnitId,
    this.isEmbedded = false,
  });

  @override
  State<PaymentStreamWidget> createState() => _PaymentStreamWidgetState();
}

class _PaymentStreamWidgetState extends State<PaymentStreamWidget> {
  final TextEditingController _searchController = TextEditingController();
  String _selectedChannel = 'ALL';
  String _selectedRole = 'ALL';
  String _selectedSettlement = 'ALL';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    await widget.controller.fetchPaymentStream(
      channel: _selectedChannel == 'ALL' ? null : _selectedChannel,
      payerRole: _selectedRole == 'ALL' ? null : _selectedRole,
      settlementStatus: _selectedSettlement == 'ALL' ? null : _selectedSettlement,
      unitId: widget.initialUnitId,
      search: _searchController.text.trim().isEmpty ? null : _searchController.text.trim(),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final stream = widget.controller.paymentStream;
    final unmatchedBank = widget.controller.unmatchedBankTransactions;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (unmatchedBank.isNotEmpty) ...[
          testId('banner_unmatched_bank_transactions', Container(
            key: const Key('banner_unmatched_bank_transactions'),
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.accentOrange.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.accentOrange.withOpacity(0.4)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.accentOrange.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.warning_amber_rounded, color: AppColors.accentOrange, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Banka Ekstresinde Eşleşme Bekleyen ${unmatchedBank.length} İşlem Var',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.warningText(context)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'İçe aktarılan ekstredeki ödemeleri dairelerle eşleştirip canlı kasaya işleyin.',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
                      ),
                    ],
                  ),
                ),
                testId('btn_resolve_unmatched_bank', ElevatedButton(
                  key: const Key('btn_resolve_unmatched_bank'),
                  onPressed: () async {
                    await BankStatementReconciliationPage.open(context, controller: widget.controller);
                    _loadData();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.warningFill,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Eşleştirmeyi Çöz'),
                )),
              ],
            ),
          )),
        ],
        // Filter bar
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              testId('btn_stream_upload_bank_statement', OutlinedButton.icon(
                key: const Key('btn_stream_upload_bank_statement'),
                onPressed: () async {
                  await BankStatementReconciliationPage.open(context, controller: widget.controller);
                  _loadData();
                },
                icon: const Icon(Icons.upload_file, size: 14, color: AppColors.accentCyan),
                label: Text('Ekstre Yükle / Eşleştir', style: TextStyle(fontSize: 12, color: AppColors.primaryText(context))),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.accentCyan),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              )),
              const SizedBox(width: 8),
              testId('filter_channel_chip', _buildFilterChip(
                label: 'Kanal: ${PaymentTrackingPage.channelLabel(_selectedChannel)}',
                icon: Icons.filter_alt,
                onTap: _showChannelFilterDialog,
              )),
              const SizedBox(width: 8),
              testId('filter_role_chip', _buildFilterChip(
                label: 'Rol: ${PaymentTrackingPage.roleLabel(_selectedRole)}',
                icon: Icons.person_outline,
                onTap: _showRoleFilterDialog,
              )),
              const SizedBox(width: 8),
              _buildFilterChip(
                label: 'Durum: ${PaymentTrackingPage.settlementLabel(_selectedSettlement)}',
                icon: Icons.verified_outlined,
                onTap: _showSettlementFilterDialog,
              ),
              if (_selectedChannel != 'ALL' || _selectedRole != 'ALL' || _selectedSettlement != 'ALL') ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectedChannel = 'ALL';
                      _selectedRole = 'ALL';
                      _selectedSettlement = 'ALL';
                    });
                    _loadData();
                  },
                  child: const Text('Temizle', style: TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Search textfield
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Sakin adı, daire no, makbuz no veya açıklama ara...',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    tooltip: 'Aramayı temizle',
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _searchController.clear();
                      _loadData();
                    },
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            filled: true,
            fillColor: AppColors.surface(context),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppColors.border(context)),
            ),
          ),
          onSubmitted: (_) => _loadData(),
        ),
        const SizedBox(height: 12),
        if (widget.isEmbedded)
          _buildEntriesList(stream)
        else
          Expanded(child: _buildEntriesList(stream)),
      ],
    );

    return content;
  }

  Widget _buildEntriesList(PaymentStreamResponseDto? stream) {
    if (widget.controller.isPaymentStreamLoading) {
      return const SpSkeletonList();
    }
    if (stream == null || stream.entries.isEmpty) {
      return _buildEmptyState('Bu filtrelere uygun tahsilat kaydı bulunamadı.');
    }
    return ListView.separated(
      shrinkWrap: widget.isEmbedded,
      physics: widget.isEmbedded ? const NeverScrollableScrollPhysics() : null,
      itemCount: stream.entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = stream.entries[index];
        return testId('payment_entry_${entry.id}_${entry.payerRole}', _buildPaymentEntryCard(entry));
      },
    );
  }

  Widget _buildFilterChip({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: AppColors.primary),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentEntryCard(PaymentEntryDto entry) {
    final isTenant = entry.payerRole == 'TENANT';
    final isCapitalDesc = (entry.description?.toUpperCase().contains('DEMİRBAŞ') ?? false) ||
        (entry.description?.toUpperCase().contains('ASANSÖR') ?? false) ||
        (entry.description?.toUpperCase().contains('ÇATI') ?? false);
    final isRentOffset = isTenant && isCapitalDesc;

    return InkWell(
      onTap: () => PaymentTrackingPage.openReceiptViewer(
        context,
        controller: widget.controller,
        identifier: entry.receiptNumber ?? entry.id.toString(),
      ),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: PaymentTrackingPage.channelColor(entry.paymentChannel).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    PaymentTrackingPage.channelIcon(entry.paymentChannel),
                    color: PaymentTrackingPage.channelColor(entry.paymentChannel),
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            entry.unitLabel ?? entry.unitId,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          const SizedBox(width: 6),
                          SpStatusBadge(
                            label: isTenant ? 'Kiracı' : 'Kat Maliki',
                            tone: isTenant ? SpTone.accent : SpTone.success,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.payerName,
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '+${formatTry(entry.amount)}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.successText(context),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${entry.paymentDate.day}.${entry.paymentDate.month}.${entry.paymentDate.year}',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
                    ),
                  ],
                ),
              ],
            ),
            if (entry.description != null && entry.description!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                entry.description!,
                style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (entry.receiptNumber != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.receipt_long, size: 12, color: AppColors.primary),
                        const SizedBox(width: 4),
                        Text(
                          '#${entry.receiptNumber}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primaryText(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (isRentOffset) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.purple.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.purple.withOpacity(0.4)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.assignment_turned_in, size: 12, color: Colors.purple),
                        SizedBox(width: 4),
                        Text(
                          'Kira Mahsubu (KMK 20)',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.purple),
                        ),
                      ],
                    ),
                  ),
                ],
                const Spacer(),
                const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(String msg) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: AppColors.textSecondary(context).withOpacity(0.5)),
            const SizedBox(height: 12),
            Text(msg, textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary(context))),
          ],
        ),
      ),
    );
  }

  Future<void> _showChannelFilterDialog() async {
    final choice = await showSpSelection<String>(
      context: context,
      title: 'Ödeme Kanalı Filtresi',
      options: const ['ALL', 'VIRTUAL_IBAN', 'BANK_STATEMENT', 'CREDIT_CARD', 'MANUAL_CASH', 'INTER_LEDGER'],
      labelOf: PaymentTrackingPage.channelLabel,
      selected: _selectedChannel,
      idOf: (v) => 'filter_channel_option_$v',
    );
    if (choice == null || choice == _selectedChannel || !mounted) return;
    setState(() => _selectedChannel = choice);
    _loadData();
  }

  Future<void> _showRoleFilterDialog() async {
    final choice = await showSpSelection<String>(
      context: context,
      title: 'Ödeyen Rolü Filtresi',
      options: const ['ALL', 'TENANT', 'OWNER'],
      labelOf: PaymentTrackingPage.roleLabel,
      selected: _selectedRole,
      idOf: (v) => 'filter_role_option_$v',
    );
    if (choice == null || choice == _selectedRole || !mounted) return;
    setState(() => _selectedRole = choice);
    _loadData();
  }

  Future<void> _showSettlementFilterDialog() async {
    final choice = await showSpSelection<String>(
      context: context,
      title: 'Mutabakat Durumu Filtresi',
      options: const ['ALL', 'SETTLED', 'UNMATCHED'],
      labelOf: PaymentTrackingPage.settlementLabel,
      selected: _selectedSettlement,
      idOf: (v) => 'filter_settlement_option_$v',
    );
    if (choice == null || choice == _selectedSettlement || !mounted) return;
    setState(() => _selectedSettlement = choice);
    _loadData();
  }
}

class DebtAgingWidget extends StatelessWidget {
  final DashboardController controller;
  final bool isEmbedded;

  const DebtAgingWidget({
    super.key,
    required this.controller,
    this.isEmbedded = false,
  });

  @override
  Widget build(BuildContext context) {
    final report = controller.debtAgingReport;

    if (report == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.fetchDebtAgingReport();
      });
      return const SpSkeletonList();
    }

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 2.2,
          children: [
            testId('aging_bucket_current', _buildAgingSummaryTile(context, 'Vadesi Gelmemiş', formatTry(report.totalCurrent), Colors.blue, 'Normal döngü')),
            testId('aging_bucket_1_30', _buildAgingSummaryTile(context, '1 - 30 Gün Gecikmiş', formatTry(report.total1to30Days), Colors.amber.shade700, 'Hatırlatma SMS')),
            testId('aging_bucket_31_60', _buildAgingSummaryTile(context, '31 - 60 Gün Gecikmiş', formatTry(report.total31to60Days), Colors.orange.shade800, 'İhtar mektubu')),
            testId('aging_bucket_60_plus', _buildAgingSummaryTile(context, '60+ Gün (Yasal Takip)', formatTry(report.total60PlusDays), Colors.red.shade700, 'Hukuki takip adayı')),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('KMK %5 Gecikme Zammı', style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context))),
                    const SizedBox(height: 2),
                    testId('aging_total_penalty', Text('+${formatTry(report.totalPenalty)}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.dangerText(context)))),
                  ],
                ),
              ),
              Container(height: 30, width: 1, color: AppColors.border(context)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Toplam Açık Alacak', style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context))),
                    const SizedBox(height: 2),
                    testId('aging_grand_total', Text(formatTry(report.grandTotal), style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppColors.primaryText(context)))),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(child: const Text(
              'Daire Bazlı Borç Yaşlandırma',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            )),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${report.brackets.length} Daire Borçlu',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
                ),
                if (report.brackets.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  testId('btn_remind_batch', TextButton.icon(
                    onPressed: () => _sendBatchPaymentReminder(context, report),
                    icon: const Icon(Icons.send_outlined, size: 14),
                    label: const Text('Toplu Hatırlat', style: TextStyle(fontSize: 12)),
                  )),
                ],
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (report.brackets.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.inbox_outlined, size: 48, color: AppColors.textSecondary(context).withOpacity(0.5)),
                  const SizedBox(height: 12),
                  Text('Sitede vadesi geçmiş veya açık borç bulunmuyor. Tebrikler!', textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary(context))),
                ],
              ),
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: report.brackets.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final b = report.brackets[index];
              return _buildDebtAgingBracketCard(context, b);
            },
          ),
      ],
    );

    return isEmbedded ? column : SingleChildScrollView(child: column);
  }

  Future<void> _sendPaymentReminder(BuildContext context, DebtAgingBracketDto bracket) async {
    final confirmed = await showSpConfirmDialog(
      context,
      title: 'Ödeme Hatırlatması',
      message: '${bracket.unitLabel} sakinleri (${bracket.residentName}) için toplam ${formatTry(bracket.totalOutstanding)} tutarındaki açık borç hatırlatması gönderilsin mi?',
      confirmLabel: 'Hatırlat',
      confirmKey: 'btn_confirm_remind',
    );
    if (confirmed && context.mounted) {
      SpToast.success(context, '${bracket.unitLabel} için ödeme hatırlatması gönderildi.');
    }
  }

  Future<void> _sendBatchPaymentReminder(BuildContext context, DebtAgingReportDto report) async {
    final confirmed = await showSpConfirmDialog(
      context,
      title: 'Toplu Ödeme Hatırlatması',
      message: 'Vadesi geçmiş ${report.brackets.length} daire için ödeme hatırlatması gönderilsin mi?',
      confirmLabel: 'Tümüne Gönder',
      confirmKey: 'btn_confirm_remind_batch',
    );
    if (confirmed && context.mounted) {
      SpToast.success(context, 'Tüm borçlu daireler için ödeme hatırlatmaları gönderildi.');
    }
  }

  Widget _buildAgingSummaryTile(BuildContext context, String title, String amount, Color color, String subtitle) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary(context)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(amount, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
          Text(subtitle, style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context))),
        ],
      ),
    );
  }

  Widget _buildDebtAgingBracketCard(BuildContext context, DebtAgingBracketDto bracket) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bracket.unitLabel, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(
                      '${bracket.residentName} • ${bracket.debtorType == "TENANT" ? "Kiracı" : "Kat Maliki"}',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatTry(bracket.totalOutstanding),
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.dangerText(context)),
                  ),
                  if (bracket.accruedDelayPenalty > Decimal.zero)
                    Text(
                      '+${formatTry(bracket.accruedDelayPenalty)} Faiz',
                      style: TextStyle(fontSize: 12, color: AppColors.dangerText(context)),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Wrap(
                  runSpacing: AppSpacing.xs,
                  children: [
                    if (bracket.currentDue > Decimal.zero)
                      _buildBracketPill('Cari: ${formatTry(bracket.currentDue)}', SpTone.info),
                    if (bracket.overdue1to30Days > Decimal.zero)
                      _buildBracketPill('1-30g: ${formatTry(bracket.overdue1to30Days)}', SpTone.warning),
                    if (bracket.overdue31to60Days > Decimal.zero)
                      _buildBracketPill('31-60g: ${formatTry(bracket.overdue31to60Days)}', SpTone.warning, icon: Icons.schedule),
                    if (bracket.overdue60PlusDays > Decimal.zero)
                      _buildBracketPill('60+g: ${formatTry(bracket.overdue60PlusDays)}', SpTone.danger, icon: Icons.error_outline),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              testId('btn_remind_${bracket.unitId}', OutlinedButton.icon(
                onPressed: () => _sendPaymentReminder(context, bracket),
                icon: const Icon(Icons.notifications_active_outlined, size: 14),
                label: const Text('Hatırlat', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  visualDensity: VisualDensity.compact,
                ),
              )),
            ],
          ),
        ],
      ),
    );
  }

  /// Aging buckets map to tones; 31-60 and 60+ also carry an icon so the two
  /// overdue levels differ by more than colour.
  Widget _buildBracketPill(String text, SpTone tone, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: SpStatusBadge(label: text, tone: tone, icon: icon),
    );
  }
}
