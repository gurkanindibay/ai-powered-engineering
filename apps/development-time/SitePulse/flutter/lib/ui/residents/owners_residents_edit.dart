part of 'owners_residents_module_page.dart';

/// Editing an owner, a tenant and household members.
extension _OwnerEdits on _OwnersResidentsModulePageState {
  void _openEditHomeOwner(HomeOwnerItem ho, {int initialTab = 0}) {
    final tenantNameCtrl = TextEditingController(text: ho.tenantFullName ?? '');
    final tenantPhoneCtrl = TextEditingController(text: ho.tenantPhone ?? '');
    final tenantEmailCtrl = TextEditingController(text: ho.tenantEmail ?? '');

    final ownerNameCtrl = TextEditingController(text: ho.ownerFullName);
    final ownerPhoneCtrl = TextEditingController(text: ho.phone);
    final ownerEmailCtrl = TextEditingController(text: ho.email);

    String occupancyMode = ho.isTenantOccupied ? 'TENANT' : (ho.isVacant ? 'VACANT' : 'OWNER');

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          return AppFullscreenPage(
            title: 'Sakin Bilgilerini Düzenle',
            subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(AppStrings.cancel),
                ),
                testId('module_save_edit_resident_btn', ElevatedButton(
                  key: const Key('module_save_edit_resident_btn'),
                  onPressed: () async {
                    try {
                      final messenger = ScaffoldMessenger.of(this.context);
                      Future<bool> save() {
                        if (occupancyMode == 'TENANT') {
                          return widget.controller.updateHomeOwner(
                            unitId: ho.unitId,
                            fullName: ownerNameCtrl.text.trim(),
                            phone: ownerPhoneCtrl.text.trim(),
                            email: ownerEmailCtrl.text.trim(),
                            tenantFullName: tenantNameCtrl.text.trim().isNotEmpty ? tenantNameCtrl.text.trim() : null,
                            tenantPhone: tenantPhoneCtrl.text.trim().isNotEmpty ? tenantPhoneCtrl.text.trim() : null,
                            tenantEmail: tenantEmailCtrl.text.trim().isNotEmpty ? tenantEmailCtrl.text.trim() : null,
                            isResident: false,
                          );
                        }
                        return widget.controller.updateHomeOwner(
                          unitId: ho.unitId,
                          fullName: ownerNameCtrl.text.trim(),
                          phone: ownerPhoneCtrl.text.trim(),
                          email: ownerEmailCtrl.text.trim(),
                          removeTenant: true,
                          isResident: occupancyMode == 'OWNER',
                        );
                      }

                      var success = await save();
                      // A login email change is an identity change: the server asks for the
                      // manager's password first, then the same edit is retried once.
                      if (!success && widget.controller.homeOwnerUpdateNeedsStepUp && ctx.mounted) {
                        final verified = await showStepUpPrompt(
                          ctx,
                          reason: 'Bir sakinin giriş e-postasını değiştiriyorsunuz. Devam etmek için kendi şifrenizi doğrulayın.',
                        );
                        if (verified) success = await save();
                      }

                      if (success && ctx.mounted) {
                        Navigator.pop(ctx);
                        final pending = widget.controller.pendingEmailChanges;
                        messenger.showSnackBar(
                          appSnackBar(content: Text(pending.isEmpty
                              ? 'Sakin bilgileri başarıyla güncellendi.'
                              : 'Bilgiler kaydedildi. E-posta değişikliği, ${pending.join(', ')} adresinden onaylanınca geçerli olur.')),
                        );
                      } else if (!success && ctx.mounted && widget.controller.lastHomeOwnerError != null) {
                        messenger.showSnackBar(
                          appSnackBar(content: Text(widget.controller.lastHomeOwnerError!)),
                        );
                      }
                    } catch (e) {
                      AppLogger.warn('Home owner edit failed', tag: 'Residents', error: e);
                    }
                  },
                  child: const Text(AppStrings.save),
                )),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // İkamet Durumu / Sakin Tipi Seçici
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: AppColors.card(ctx),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.accentCyan.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'İkamet Durumu / Sakin Tipi (Kat Maliki / Kiracı)',
                          style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: testId('module_edit_occupancy_role_selector', SegmentedButton<String>(
                            key: const Key('module_edit_occupancy_role_selector'),
                            segments: const [
                              ButtonSegment<String>(
                                value: 'OWNER',
                                label: Text('Malik Oturuyor'),
                                icon: Icon(Icons.home_outlined, size: 16),
                              ),
                              ButtonSegment<String>(
                                value: 'TENANT',
                                label: Text('Kiracı Oturuyor'),
                                icon: Icon(Icons.key, size: 16),
                              ),
                              ButtonSegment<String>(
                                value: 'VACANT',
                                label: Text('Boş Daire'),
                                icon: Icon(Icons.meeting_room_outlined, size: 16),
                              ),
                            ],
                            selected: {occupancyMode},
                            onSelectionChanged: (newSelection) {
                              setDlgState(() => occupancyMode = newSelection.first);
                            },
                          )),
                        ),
                      ],
                    ),
                  ),

                  if (occupancyMode == 'TENANT') ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: AppColors.card(ctx),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border(ctx)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.key, size: 16, color: AppColors.accentCyan),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Kiracı Bilgileri (Fiilen İkamet Eden)',
                                  style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.bold, fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: tenantNameCtrl,
                            decoration: const InputDecoration(labelText: 'Kiracı Ad Soyad', filled: true, border: OutlineInputBorder()),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: tenantPhoneCtrl,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(labelText: 'Kiracı Telefon', filled: true, border: OutlineInputBorder()),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: tenantEmailCtrl,
                            keyboardType: TextInputType.emailAddress,
                            decoration: const InputDecoration(labelText: 'Kiracı E-posta', filled: true, border: OutlineInputBorder()),
                          ),
                        ],
                      ),
                    ),
                  ],

                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: AppColors.card(ctx),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border(ctx)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.vpn_key_outlined, size: 16, color: AppColors.accentGreen),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Kat Maliki (Ev Sahibi / Mülk Sahibi) Bilgileri',
                                style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.bold, fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: ownerNameCtrl,
                          decoration: const InputDecoration(labelText: 'Kat Maliki Ad Soyad', filled: true, border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: ownerPhoneCtrl,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Kat Maliki Telefon', filled: true, border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: ownerEmailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'Kat Maliki E-posta', filled: true, border: OutlineInputBorder()),
                        ),
                      ],
                    ),
                  ),

                  // Hane Sakinleri / Birlikte Yaşayanlar (Co-residents)
                  Builder(
                    builder: (context) {
                      final currentHo = widget.controller.homeOwners.firstWhere(
                        (h) => h.unitId == ho.unitId,
                        orElse: () => ho,
                      );
                      return Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: AppColors.card(ctx),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.accentPurple.withOpacity(0.35)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.family_restroom, size: 16, color: AppColors.accentPurple),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Hane Sakinleri / Birlikte Yaşayanlar (${currentHo.householdResidents.length})',
                                    style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.bold, fontSize: 13),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                testId('module_edit_dialog_add_household_member', ElevatedButton.icon(
                                  key: const Key('module_edit_dialog_add_household_member'),
                                  onPressed: () {
                                    _openAddHouseholdMember(currentHo);
                                    setDlgState(() {});
                                  },
                                  icon: const Icon(Icons.person_add_alt, size: 12),
                                  label: const Text('+ Hane Sakini Ekle', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.accentPurple,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    minimumSize: const Size(0, 28),
                                  ),
                                )),
                              ],
                            ),
                            const SizedBox(height: 10),
                            if (currentHo.householdResidents.isNotEmpty) ...[
                              ...currentHo.householdResidents.map((m) => Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: AppColors.background(ctx),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppColors.border(ctx).withOpacity(0.5)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.person_outline, size: 14, color: AppColors.accentPurple),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            m.fullName,
                                            style: TextStyle(color: AppColors.textPrimary(ctx), fontSize: 12, fontWeight: FontWeight.bold),
                                          ),
                                          Text(
                                            '${HouseholdRelationship.labelFor(m.relationship)}${m.phone.isNotEmpty ? ' • ${m.phone}' : ''}',
                                            style: TextStyle(color: AppColors.textSecondary(ctx), fontSize: 12),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.edit_outlined, size: 14, color: AppColors.accentCyan),
                                      tooltip: 'Düzenle',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () {
                                        _openEditHouseholdMember(currentHo, m);
                                        setDlgState(() {});
                                      },
                                    ),
                                    const SizedBox(width: 6),
                                    IconButton(
                                      icon: const Icon(Icons.close, size: 14, color: AppColors.accentRed),
                                      tooltip: AppStrings.delete,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () {
                                        _confirmDeleteHouseholdMember(currentHo, m);
                                        setDlgState(() {});
                                      },
                                    ),
                                  ],
                                ),
                              )),
                            ] else ...[
                              Text(
                                'Bu daireye kayıtlı ek hane sakini bulunmuyor. Yeni hane sakini eklemek için yukarıdaki butonu kullanabilirsiniz.',
                                style: TextStyle(color: AppColors.textSecondary(ctx), fontSize: 12, fontStyle: FontStyle.italic),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openAddHouseholdMember(HomeOwnerItem ho) {
    final nameCtrl = TextEditingController();
    final relationCtrl = TextEditingController(text: HouseholdRelationship.spouse.code);
    final phoneCtrl = TextEditingController();
    bool setAsPrimary = false;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          return AppFullscreenPage(
            title: 'Hane Sakini Ekle',
            subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppStrings.cancel)),
                testId('module_save_household_btn', ElevatedButton(
                  key: const Key('module_save_household_btn'),
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    final success = await widget.controller.addHouseholdMember(
                      unitId: ho.unitId,
                      block: ho.block,
                      unitNo: ho.unitNo,
                      fullName: name,
                      relationship: relationCtrl.text.trim(),
                      phone: phoneCtrl.text.trim(),
                      email: phoneCtrl.text.trim().isNotEmpty ? '${phoneCtrl.text.trim()}@sakin.local' : 'sakin_${ho.unitNo}@example.com',
                    );
                    if (setAsPrimary && success) {
                      widget.controller.setPrimaryResponsibleResident(
                        unitId: ho.unitId,
                        residentName: name,
                        role: 'RESIDENT',
                        phone: phoneCtrl.text.trim(),
                      );
                    }
                    if (success && ctx.mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        appSnackBar(content: Text('Hane sakini başarıyla eklendi.')),
                      );
                    }
                  },
                  child: const Text('Ekle'),
                )),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  testId('module_member_name_input', TextField(
                    key: const Key('module_member_name_input'),
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Ad Soyad *', filled: true, border: OutlineInputBorder()),
                  )),
                  const SizedBox(height: 12),
                  testId('module_member_relation_input', DropdownButtonFormField<String>(
                    key: const Key('module_member_relation_input'),
                    initialValue: relationCtrl.text,
                    items: householdRelationshipItems(),
                    onChanged: (code) => relationCtrl.text = code ?? HouseholdRelationship.other.code,
                    decoration: const InputDecoration(labelText: 'Yakınlık Derecesi', filled: true, border: OutlineInputBorder()),
                  )),
                  const SizedBox(height: 12),
                  testId('module_member_phone_input', TextField(
                    key: const Key('module_member_phone_input'),
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Telefon', filled: true, border: OutlineInputBorder()),
                  )),
                  const SizedBox(height: 12),
                  Material(
                    color: Colors.transparent,
                    child: testId('module_member_set_primary_switch', SwitchListTile(
                      key: const Key('module_member_set_primary_switch'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Bu kişiyi dairenin aktif sorumlusu yap', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      subtitle: const Text('Bildirimler ve birincil muhataplık bu kişiye yönlendirilir', style: TextStyle(fontSize: 12)),
                      value: setAsPrimary,
                      activeThumbColor: AppColors.accentPurple,
                      onChanged: (val) {
                        setDlgState(() => setAsPrimary = val);
                      },
                    )),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openEditHouseholdMember(HomeOwnerItem ho, UnitResidentMember member) {
    final nameCtrl = TextEditingController(text: member.fullName);
    final relationCtrl = TextEditingController(text: HouseholdRelationship.fromValue(member.relationship).code);
    final phoneCtrl = TextEditingController(text: member.phone);

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: 'Hane Sakinini Düzenle',
        subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppStrings.cancel)),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final success = await widget.controller.updateHouseholdMember(
                  unitId: ho.unitId,
                  residentId: member.id,
                  fullName: name,
                  relationship: relationCtrl.text.trim(),
                  phone: phoneCtrl.text.trim(),
                  email: member.email.isNotEmpty ? member.email : 'sakin@example.com',
                );
                if (success && ctx.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    appSnackBar(content: Text('Hane sakini bilgileri güncellendi.')),
                  );
                }
              },
              child: const Text(AppStrings.save),
            ),
          ],
        ),
        child: Column(
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Ad Soyad')),
            const SizedBox(height: 12),
            testId('module_edit_member_relation_input', DropdownButtonFormField<String>(
              key: const Key('module_edit_member_relation_input'),
              initialValue: relationCtrl.text,
              items: householdRelationshipItems(),
              onChanged: (code) => relationCtrl.text = code ?? HouseholdRelationship.other.code,
              decoration: const InputDecoration(labelText: 'Yakınlık Derecesi'),
            )),
            const SizedBox(height: 12),
            TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Telefon')),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteHouseholdMember(HomeOwnerItem ho, UnitResidentMember member) async {
    final confirmed = await AppFullscreenPage.pushConfirmation(
      context: context,
      title: 'Hane Sakinini Sil',
      message: '${member.fullName} isimli sakin kaydını silmek istediğinize emin misiniz?',
      confirmLabel: 'Evet, Sil',
    );
    if (confirmed == true) {
      await widget.controller.deleteHouseholdMember(unitId: ho.unitId, residentId: member.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          appSnackBar(content: Text('${member.fullName} kaydı silindi.')),
        );
      }
    }
  }
}
