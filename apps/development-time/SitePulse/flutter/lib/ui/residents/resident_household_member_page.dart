import 'package:flutter/material.dart';

import '../../domain/models/household_relationship.dart';
import '../../l10n/app_strings.dart';
import '../../testing/test_id.dart';
import '../components/app_fullscreen_page.dart';
import '../dashboard/dashboard_controller.dart';
import '../design_system/sp_feedback.dart';
import '../theme/app_theme.dart';
import 'household_relationship_items.dart';

/// Resident self-service: a home owner or resident adds a person who lives in their own unit.
///
/// This is the one page outside [SpPersonForm] that takes a person's name, phone and email as
/// text (REQ-042 exemption, guarded by `flutter_reuse_inventory.py` rule `person-inputs`):
/// residents have no access to the site person directory, so they cannot use the shared
/// person picker. Managers add household members from the unit workspace with `SpPersonField`.
void showResidentHouseholdMemberPage(BuildContext hostContext, DashboardController controller) {
  final effectiveBlock = controller.activeUnit.block.isNotEmpty ? controller.activeUnit.block : 'A';
  final effectiveUnitNo = controller.activeUnit.unitNo > 0 ? controller.activeUnit.unitNo : 1;
  final effectiveUnitId = controller.activeUnit.id.isNotEmpty ? controller.activeUnit.id : 'd-$effectiveUnitNo';

  final nameCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  final emailCtrl = TextEditingController();
  String selectedRelationship = HouseholdRelationship.spouse.code;
  bool isSaving = false;
  String? nameError;
  String? generalError;

  AppFullscreenPage.push(
    context: hostContext,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDialogState) {
        return AppFullscreenPage(
          title: 'Yeni Hane Sakini Ekle',
          subtitle: '$effectiveBlock Blok Daire $effectiveUnitNo • Birlikte Yaşayan Kişi',
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.accentPurple.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.person_add_alt_1_outlined, color: AppColors.accentPurple, size: 20),
          ),
          bottomBar: AppFullscreenPage.buildBottomBar(
            context: ctx,
            children: [
              OutlinedButton(
                onPressed: isSaving ? null : () => Navigator.pop(ctx),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textSecondary(context),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(AppStrings.cancel),
              ),
              testId('household_save_button', ElevatedButton(
                key: const Key('household_save_button'),
                onPressed: isSaving
                    ? null
                    : () async {
                        final name = nameCtrl.text.trim();
                        if (name.isEmpty) {
                          setDialogState(() {
                            nameError = 'Ad Soyad zorunludur.';
                          });
                          return;
                        }
                        setDialogState(() {
                          isSaving = true;
                          generalError = null;
                          nameError = null;
                        });

                        try {
                          final messenger = ScaffoldMessenger.of(hostContext);
                          final ok = await controller.addHouseholdMember(
                            unitId: effectiveUnitId,
                            block: effectiveBlock,
                            unitNo: effectiveUnitNo,
                            fullName: name,
                            phone: phoneCtrl.text.trim(),
                            email: emailCtrl.text.trim().isNotEmpty
                                ? emailCtrl.text.trim()
                                : 'sakin.$effectiveUnitNo@example.com',
                            relationship: selectedRelationship,
                          );

                          if (ok && ctx.mounted) {
                            Navigator.pop(ctx);
                            messenger.showSnackBar(
                              appSnackBar(
                                content: Text('Hane sakini başarıyla eklendi.'),
                                backgroundColor: AppColors.successFill,
                              ),
                            );
                          } else if (ctx.mounted) {
                            setDialogState(() {
                              isSaving = false;
                              generalError = 'Kayıt sırasında bir hata oluştu.';
                            });
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            setDialogState(() {
                              isSaving = false;
                              generalError = 'Beklenmeyen hata: $e';
                            });
                          }
                        } finally {
                          if (ctx.mounted && isSaving) {
                            setDialogState(() => isSaving = false);
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentPurple,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: isSaving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text(AppStrings.save, style: TextStyle(fontWeight: FontWeight.bold)),
              )),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (generalError != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.accentRed.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.accentRed),
                    ),
                    child: Text(generalError!, style: TextStyle(color: AppColors.dangerText(context), fontSize: 13)),
                  ),
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.card(context),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border(context)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.apartment, color: AppColors.accentCyan, size: 24),
                      const SizedBox(width: 10),
                      Text(
                        '$effectiveBlock Blok • Daire $effectiveUnitNo',
                        style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                ),
                Text('Ad Soyad *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                const SizedBox(height: 6),
                testId('household_name_field', TextField(
                  key: const Key('household_name_field'),
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    hintText: 'Örn: Ahmet Yılmaz',
                    errorText: nameError,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                )),
                const SizedBox(height: 14),
                Text('Yakınlık Derecesi / Rol', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: selectedRelationship,
                  items: householdRelationshipItems(),
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() => selectedRelationship = val);
                    }
                  },
                  decoration: InputDecoration(
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 14),
                Text('Telefon Numarası', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                const SizedBox(height: 6),
                testId('household_phone_field', TextField(
                  key: const Key('household_phone_field'),
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    hintText: 'Örn: 0532 123 45 67',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                )),
                const SizedBox(height: 14),
                Text('E-posta Adresi', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                const SizedBox(height: 6),
                testId('household_email_field', TextField(
                  key: const Key('household_email_field'),
                  controller: emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    hintText: 'Örn: sakin@example.com',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                )),
              ],
            ),
          ),
        );
      },
    ),
  );
}

