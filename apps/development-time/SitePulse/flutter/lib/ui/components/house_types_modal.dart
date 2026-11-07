import '../../testing/test_id.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import '../../domain/models/dues_models.dart';
import '../dashboard/dashboard_controller.dart';
import '../theme/app_theme.dart';
import 'app_fullscreen_page.dart';

import '../design_system/money_formatter.dart';
Future<void> showManageHouseTypesFullscreen(BuildContext context, DashboardController controller) async {
  await AppFullscreenPage.push(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDialogState) {
        final houseTypes = controller.houseTypes;

        return AppFullscreenPage(
          title: 'Konut Tipleri & Aidat Tarifeleri',
          subtitle: '${controller.userSession.siteName} için daire tipi bazlı aidat tutarları',
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.accentPurple.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.home_work_outlined, color: AppColors.accentPurple, size: 20),
          ),
          actions: [
            IconButton(
              tooltip: 'Yeni Konut Tipi Ekle',
              icon: const Icon(Icons.add_circle, color: AppColors.accentPurple, size: 26),
              onPressed: () => _showEditHouseTypeDialog(context, controller, null, setDialogState),
            ),
          ],
          bottomBar: AppFullscreenPage.buildBottomBar(
            context: ctx,
            children: [
              ElevatedButton.icon(
                onPressed: () => _showEditHouseTypeDialog(context, controller, null, setDialogState),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Yeni Konut Tipi Ekle', style: TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentPurple,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
          child: houseTypes.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.home_work_outlined, size: 48, color: AppColors.textSecondary(context)),
                        const SizedBox(height: 12),
                        Text(
                          'Tanımlı Konut Tipi Yok',
                          style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Yeni Konut Tipi Ekle butonuyla 1+1, 2+1, 3+1 gibi tipler ve aylık aidatlarını belirleyebilirsiniz.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: houseTypes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = houseTypes[index];
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.card(context),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.border(context)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.accentPurple.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              item.typeName,
                              style: const TextStyle(
                                color: AppColors.accentPurple,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      'Aylık Aidat: ',
                                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                                    ),
                                    Text(
                                      formatTry(item.duesAmount),
                                      style: TextStyle(
                                        color: AppColors.successText(context),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ],
                                ),
                                if (item.description != null && item.description!.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    item.description!,
                                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          testId('btn_edit_house_type_${item.typeName}', IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 20, color: AppColors.accentPurple),
                            onPressed: () => _showEditHouseTypeDialog(context, controller, item, setDialogState),
                          )),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20, color: AppColors.accentRed),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  title: const Text('Tarifeyi Sil'),
                                  content: Text('${item.typeName} tarifesini silmek istediğinize emin misiniz?'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text(AppStrings.cancel)),
                                    TextButton(
                                      onPressed: () => Navigator.pop(c, true),
                                      child: Text(AppStrings.delete, style: TextStyle(color: AppColors.dangerText(context))),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await controller.deleteHouseType(item.id);
                                setDialogState(() {});
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
        );
      },
    ),
  );
}

void _showEditHouseTypeDialog(BuildContext context, DashboardController controller, HouseTypeTariff? item, StateSetter parentSetState) {
  final typeNameCtrl = TextEditingController(text: item?.typeName ?? '');
  final duesCtrl = TextEditingController(text: item != null ? item.duesAmount.toString() : '');
  final descCtrl = TextEditingController(text: item?.description ?? '');
  String? errorText;

  AppFullscreenPage.push(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDialogState) {
        return AppFullscreenPage(
          title: item == null ? 'Yeni Konut Tipi Tanımla' : 'Konut Tipini Düzenle',
          subtitle: 'Daire tipi ve aylık aidat bedeli',
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.accentPurple.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.edit_note, color: AppColors.accentPurple, size: 20),
          ),
          bottomBar: AppFullscreenPage.buildBottomBar(
            context: ctx,
            children: [
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: AppColors.border(context)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('İptal', style: TextStyle(color: AppColors.textSecondary(context), fontWeight: FontWeight.w600)),
              ),
              testId('btn_save_house_type', ElevatedButton(
                onPressed: () async {
                  final typeName = typeNameCtrl.text.trim();
                  final duesText = duesCtrl.text.trim();
                  final parsedDues = Decimal.tryParse(duesText);

                  if (typeName.isEmpty) {
                    setDialogState(() {
                      errorText = 'Lütfen Konut Tipi adını giriniz (örn: 2+1, 3+1).';
                    });
                    return;
                  }

                  if (parsedDues == null || parsedDues <= Decimal.zero) {
                    setDialogState(() {
                      errorText = 'Lütfen geçerli bir aylık aidat tutarı giriniz.';
                    });
                    return;
                  }

                  final success = await controller.saveHouseType(
                    typeName: typeName,
                    duesAmount: parsedDues,
                    description: descCtrl.text.trim().isNotEmpty ? descCtrl.text.trim() : null,
                  );

                  if (success) {
                    parentSetState(() {});
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                    }
                  } else {
                    setDialogState(() {
                      errorText = 'Konut tipi kaydedilemedi. Lütfen tekrar deneyiniz.';
                    });
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentPurple,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(AppStrings.save, style: TextStyle(fontWeight: FontWeight.bold)),
              )),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (errorText != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.accentRed.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.accentRed.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: AppColors.accentRed, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: testId('house_type_error', Text(errorText!, style: TextStyle(color: AppColors.dangerText(context), fontSize: 13))),
                        ),
                      ],
                    ),
                  ),
                testId('house_type_name_field', TextField(
                  controller: typeNameCtrl,
                  decoration: InputDecoration(
                    labelText: 'Konut Tipi Adı (örn: 1+1, 2+1, 3+1, Dubleks)',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )),
                const SizedBox(height: 16),
                testId('house_type_amount_field', TextField(
                  controller: duesCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Aylık Aidat Tutarı (₺)',
                    prefixText: '₺ ',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )),
                const SizedBox(height: 16),
                TextField(
                  controller: descCtrl,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Açıklama (Opsiyonel)',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
