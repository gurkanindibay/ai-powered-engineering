import '../../testing/test_id.dart';
import 'package:flutter/material.dart';
import '../../domain/models/auth_models.dart';
import '../../l10n/app_strings.dart';
import '../../domain/models/dues_models.dart';
import '../dashboard/dashboard_controller.dart';
import '../theme/app_theme.dart';

import '../design_system/sp_feedback.dart';
import 'sp_dialog_pages.dart';
import '../design_system/sp_clipboard.dart';
/// Card component allowing homeowners to see their automated payment
/// matching criteria (Virtual IBAN, registered sender IBANs, payer names, and description format)
/// and modify them at will.
class UnitMatchingCriteriaCard extends StatefulWidget {
  final DashboardController controller;
  final bool compact;

  const UnitMatchingCriteriaCard({
    super.key,
    required this.controller,
    this.compact = false,
  });

  @override
  State<UnitMatchingCriteriaCard> createState() => _UnitMatchingCriteriaCardState();
}

class _UnitMatchingCriteriaCardState extends State<UnitMatchingCriteriaCard> {
  /// The unit's payer IBANs and names steer bank matching; only the owner and the
  /// manager may change them (person module S6, `UNIT_PAYMENT_PROFILE_MANAGE`).
  bool get _canEditPaymentProfile => widget.controller.userRole != UserRole.homeResident;

  void _showAddIbanDialog(BuildContext context) {
    final ibanController = TextEditingController(text: 'TR');
    final labelController = TextEditingController();
    final bankController = TextEditingController();

    showSpPage(
      context: context,
      builder: (dialogCtx) {
        final isDark = AppColors.isDark(dialogCtx);
        return SpDialogPage(
          backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 460),
            padding: const EdgeInsets.all(22),
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
                        child: const Icon(Icons.account_balance, color: AppColors.accentCyan, size: 20),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Yeni Gönderici IBAN Ekle',
                          style: TextStyle(
                            color: AppColors.textPrimary(dialogCtx),
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Kendi bankanızdan site genel IBAN\'ına yapacağınız transferlerde açıklama boş olsa bile bu IBAN sayesinde ödemeniz dairenizle eşleşir.',
                    style: TextStyle(color: AppColors.textSecondary(dialogCtx), fontSize: 12),
                  ),
                  const SizedBox(height: 16),

                  // IBAN Input
                  Text(
                    'Gönderici IBAN',
                    style: TextStyle(color: AppColors.textPrimary(dialogCtx), fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: ibanController,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: AppColors.textPrimary(dialogCtx),
                      fontWeight: FontWeight.bold,
                    ),
                    decoration: InputDecoration(
                      hintText: 'TR00 0000 0000 0000 0000 0000 00',
                      filled: true,
                      fillColor: isDark ? AppColors.lightTextPrimary : const Color(0xFFF8FAFC),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppColors.border(dialogCtx)),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Label Input
                  Text(
                    'Hesap Tanımı / Etiketi (Opsiyonel)',
                    style: TextStyle(color: AppColors.textPrimary(dialogCtx), fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: labelController,
                    style: TextStyle(fontSize: 13, color: AppColors.textPrimary(dialogCtx)),
                    decoration: InputDecoration(
                      hintText: 'Örn: İş Bankası Maaş Hesabım',
                      filled: true,
                      fillColor: isDark ? AppColors.lightTextPrimary : const Color(0xFFF8FAFC),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppColors.border(dialogCtx)),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Bank Name Input
                  Text(
                    'Banka Adı (Opsiyonel)',
                    style: TextStyle(color: AppColors.textPrimary(dialogCtx), fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: bankController,
                    style: TextStyle(fontSize: 13, color: AppColors.textPrimary(dialogCtx)),
                    decoration: InputDecoration(
                      hintText: 'Örn: Türkiye İş Bankası',
                      filled: true,
                      fillColor: isDark ? AppColors.lightTextPrimary : const Color(0xFFF8FAFC),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppColors.border(dialogCtx)),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 22),

                  // Actions
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(dialogCtx),
                          child: const Text(AppStrings.cancel),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            final rawIban = ibanController.text.trim();
                            if (rawIban.length < 15) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                appSnackBar(content: Text('Lütfen geçerli bir IBAN giriniz.')),
                              );
                              return;
                            }
                            widget.controller.addSenderIbanToUnit(
                              iban: rawIban,
                              label: labelController.text.trim().isNotEmpty ? labelController.text.trim() : null,
                              bankName: bankController.text.trim().isNotEmpty ? bankController.text.trim() : null,
                            );
                            Navigator.pop(dialogCtx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              appSnackBar(
                                content: Text('Gönderici IBAN başarıyla kaydedildi!'),
                                backgroundColor: AppColors.successFill,
                              ),
                            );
                          },
                          icon: const Icon(Icons.check, size: 16),
                          label: const Text(AppStrings.save),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryFill,
                            foregroundColor: Colors.black87,
                            textStyle: const TextStyle(fontWeight: FontWeight.bold),
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
  }

  void _showEditPayerNamesDialog(BuildContext context, List<String> currentNames) {
    final names = List<String>.from(currentNames);
    final nameController = TextEditingController();

    showSpPage(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final isDark = AppColors.isDark(ctx);
            return SpDialogPage(
              backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 460),
                padding: const EdgeInsets.all(22),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
                              const Icon(Icons.badge_outlined, color: AppColors.accentGreen, size: 22),
                              const SizedBox(width: 8),
                              Text(
                                'Kayıtlı Gönderen İsimleri',
                                style: TextStyle(
                                  color: AppColors.textPrimary(ctx),
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ])),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Bu isimlerden yapılan havale ve FAST transferleri otomatik olarak dairenizle eşleştirilir.',
                        style: TextStyle(color: AppColors.textSecondary(ctx), fontSize: 12),
                      ),
                      const SizedBox(height: 14),

                      // Existing Name Chips
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: names.map((name) {
                          return Chip(
                            backgroundColor: AppColors.accentGreen.withOpacity(0.12),
                            side: BorderSide(color: AppColors.accentGreen.withOpacity(0.3)),
                            label: Text(
                              name,
                              style: TextStyle(
                                color: AppColors.successText(context),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            deleteIcon: const Icon(Icons.close, size: 14, color: AppColors.accentGreen),
                            onDeleted: () {
                              setDialogState(() {
                                names.remove(name);
                              });
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),

                      // Add new name field
                      Row(
                        children: [
                          Expanded(
                            child: testId('payer_name_input', TextField(
                              controller: nameController,
                              style: TextStyle(fontSize: 13, color: AppColors.textPrimary(ctx)),
                              decoration: InputDecoration(
                                hintText: 'Ad Soyad (Örn: Fatma Yılmaz)',
                                filled: true,
                                fillColor: isDark ? AppColors.lightTextPrimary : const Color(0xFFF8FAFC),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: AppColors.border(ctx)),
                                ),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              ),
                            )),
                          ),
                          const SizedBox(width: 8),
                          testId('btn_add_payer_name', ElevatedButton(
                            onPressed: () {
                              final text = nameController.text.trim();
                              if (text.isNotEmpty && !names.contains(text)) {
                                setDialogState(() {
                                  names.add(text);
                                  nameController.clear();
                                });
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.successFill,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('Ekle'),
                          )),
                        ],
                      ),
                      const SizedBox(height: 22),

                      // Action Buttons
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text(AppStrings.cancel),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: testId('btn_save_payer_names', ElevatedButton.icon(
                              onPressed: () {
                                widget.controller.updateUnitPayerNames(names: names);
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  appSnackBar(
                                    content: Text('Gönderen isimleri başarıyla güncellendi!'),
                                    backgroundColor: AppColors.successFill,
                                  ),
                                );
                              },
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text(AppStrings.save),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.successFill,
                                foregroundColor: Colors.white,
                                textStyle: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                            )),
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

  void _confirmDeleteIban(BuildContext context, RegisteredSenderIban ibanItem) {
    showSpPage(
      context: context,
      builder: (dialogCtx) => SpAlertPage(
        backgroundColor: AppColors.surface(dialogCtx),
        title: const Text('IBAN Tanımını Kaldır'),
        content: Text(
          '${ibanItem.formattedIban} nolu IBAN tanımını kaldırmak istediğinize emin misiniz? Gelecekte bu hesaptan yapılacak açıklaması boş transferler otomatik eşleşmeyebilir.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text(AppStrings.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              widget.controller.deleteSenderIbanFromUnit(iban: ibanItem.senderIban);
              Navigator.pop(dialogCtx);
              ScaffoldMessenger.of(context).showSnackBar(
                appSnackBar(content: Text('Gönderici IBAN başarıyla kaldırıldı.')),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.dangerFill, foregroundColor: Colors.white),
            child: const Text('Kaldır'),
          ),
        ],
      ),
    );
  }

  /// Copies [text] exactly as shown (descriptions keep their spaces).
  Future<void> _copyToClipboard(BuildContext context, String text, String label) =>
      spCopyToClipboard(context, text, successMessage: '$label panoya kopyalandı!');

  @override
  Widget build(BuildContext context) {
    final criteria = widget.controller.matchingCriteria;
    final isDark = AppColors.isDark(context);

    if (criteria == null) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accentCyan.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.tune, color: AppColors.accentCyan, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ödeme Eşleşme Tercihlerim',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 14.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${criteria.block} Blok D:${criteria.unitNumber} • Otomatik Eşleşme Kriterleri',
                        style: TextStyle(
                          color: AppColors.textSecondary(context),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.accentGreen.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.accentGreen.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shield_outlined, color: AppColors.accentGreen, size: 12),
                    SizedBox(width: 4),
                    Text(
                      'Aktif',
                      style: TextStyle(color: AppColors.successText(context), fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 1. Dedicated Virtual IBAN (Priority 1)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? AppColors.lightTextPrimary : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.accentCyan.withOpacity(0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
                        const Icon(Icons.flash_on, color: AppColors.accentCyan, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          'Daireme Özel Sanal IBAN (1. Öncelik)',
                          style: TextStyle(
                            color: AppColors.textPrimary(context),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ])),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.accentCyan.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '%100 Güvenli',
                        style: TextStyle(color: AppColors.primaryText(context), fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        criteria.virtualIban ?? 'TR41 0020 5042 1399 1067 0000 14',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryText(context),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 16, color: AppColors.accentCyan),
                      tooltip: 'IBAN Kopyala',
                      onPressed: () => spCopyIban(
                        context,
                        criteria.virtualIban ?? 'TR41 0020 5042 1399 1067 0000 14',
                      ),
                    ),
                  ],
                ),
                Text(
                  'Bu IBAN\'a yapılan tüm ödemeler açıklama boş olsa bile doğrudan dairenizle eşleşir.',
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 2. Remembered Sender IBANs (Priority 2)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
                  const Icon(Icons.credit_card, size: 16, color: AppColors.accentOrange),
                  const SizedBox(width: 6),
                  Text(
                    'Kayıtlı Gönderici IBAN\'larım (${criteria.rememberedIbans.length})',
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ])),
              if (_canEditPaymentProfile) TextButton.icon(
                onPressed: () => _showAddIbanDialog(context),
                icon: const Icon(Icons.add, size: 14, color: AppColors.accentOrange),
                label: Text(
                  'Yeni IBAN Ekle',
                  style: TextStyle(fontSize: 12, color: AppColors.warningText(context), fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (criteria.rememberedIbans.isEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: AppColors.textSecondary(context)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Henüz kayıtlı gönderici IBAN\'ınız yok. Sık kullandığınız banka hesabınızı ekleyerek genel site IBAN\'ına yapılan ödemelerde otomatik eşleşme sağlayabilirsiniz.',
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                    ),
                  ),
                ],
              ),
            )
          else
            ...criteria.rememberedIbans.map((ibanItem) {
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isDark ? AppColors.lightTextPrimary : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.account_balance_wallet, size: 16, color: AppColors.accentOrange),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            ibanItem.formattedIban,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary(context),
                            ),
                          ),
                          if (ibanItem.label != null || ibanItem.bankName != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              [ibanItem.label, ibanItem.bankName].where((s) => s != null && s.isNotEmpty).join(' • '),
                              style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (_canEditPaymentProfile) IconButton(
                      icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.accentRed),
                      tooltip: 'IBAN\'ı Kaldır',
                      onPressed: () => _confirmDeleteIban(context, ibanItem),
                    ),
                  ],
                ),
              );
            }),
          const SizedBox(height: 12),

          // 3. Registered Payer Names & Description Rule
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
                  const Icon(Icons.person_pin_outlined, size: 16, color: AppColors.accentGreen),
                  const SizedBox(width: 6),
                  Text(
                    'Kayıtlı Gönderen Adı / Malik',
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ])),
              if (_canEditPaymentProfile) testId('btn_edit_payer_names', TextButton.icon(
                onPressed: () => _showEditPayerNamesDialog(context, criteria.registeredPayerNames),
                icon: const Icon(Icons.edit, size: 13, color: AppColors.accentGreen),
                label: Text(
                  'Düzenle',
                  style: TextStyle(fontSize: 12, color: AppColors.successText(context), fontWeight: FontWeight.bold),
                ),
              )),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: criteria.registeredPayerNames.map((name) {
              return Chip(
                backgroundColor: AppColors.accentGreen.withOpacity(0.08),
                side: BorderSide(color: AppColors.accentGreen.withOpacity(0.25)),
                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                label: Text(
                  name,
                  style: TextStyle(color: AppColors.successText(context), fontSize: 12, fontWeight: FontWeight.w600),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),

          // 4. Recommended Description Hint
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF131D2E) : const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue.withOpacity(0.25)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.blueAccent, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Genel Site IBAN\'ına Gönderim Açıklama Kuralı',
                        style: TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Farklı bir banka hesabından site genel IBAN\'ına transfer yaparken açıklamaya "${criteria.recommendedDescription}" yazmanız eşleşme için yeterlidir.',
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: () => _copyToClipboard(context, criteria.recommendedDescription, 'Açıklama Metni'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blueAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy, size: 12, color: Colors.blueAccent),
                        SizedBox(width: 4),
                        Text(
                          AppStrings.copy,
                          style: TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
