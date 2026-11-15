part of 'owners_residents_module_page.dart';

/// Editing an owner, a tenant and household members.
extension _OwnerEdits on _OwnersResidentsModulePageState {
  void _openEditHomeOwner(HomeOwnerItem ho, {int initialTab = 0}) {
    int? ownerPersonId;
    int? tenantPersonId;
    // Identity lives on the person card; resolve the active owner/tenant ids for the card links.
    final identityLoaded = widget.controller.fetchOccupancyHistory(ho.unitId);

    String occupancyMode = ho.isTenantOccupied
        ? 'TENANT'
        : (ho.isVacant ? 'VACANT' : 'OWNER');

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          identityLoaded.then((history) {
            final active = history.where((h) => h.isActive);
            final owner = active
                .where((h) => h.debtorRole == DebtorType.owner)
                .firstOrNull;
            final tenant = active
                .where((h) => h.debtorRole == DebtorType.tenant)
                .firstOrNull;
            if (owner?.personId != ownerPersonId ||
                tenant?.personId != tenantPersonId) {
              ownerPersonId = owner?.personId;
              tenantPersonId = tenant?.personId;
              if (context.mounted) setDlgState(() {});
            }
          });
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
                testId(
                  'module_save_edit_resident_btn',
                  ElevatedButton(
                    key: const Key('module_save_edit_resident_btn'),
                    onPressed: () async {
                      try {
                        final messenger = ScaffoldMessenger.of(this.context);
                        Future<bool> save() =>
                            widget.controller.updateHomeOwner(
                              unitId: ho.unitId,
                              removeTenant: occupancyMode == 'TENANT'
                                  ? null
                                  : true,
                              isResident: occupancyMode == 'OWNER',
                            );

                        var success = await save();
                        // A login email change is an identity change: the server asks for the
                        // manager's password first, then the same edit is retried once.
                        if (!success &&
                            widget.controller.homeOwnerUpdateNeedsStepUp &&
                            ctx.mounted) {
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
                            appSnackBar(
                              content: Text(
                                pending.isEmpty
                                    ? 'Sakin bilgileri başarıyla güncellendi.'
                                    : 'Bilgiler kaydedildi. E-posta değişikliği, ${pending.join(', ')} adresinden onaylanınca geçerli olur.',
                              ),
                            ),
                          );
                        } else if (!success &&
                            ctx.mounted &&
                            widget.controller.lastHomeOwnerError != null) {
                          messenger.showSnackBar(
                            appSnackBar(
                              content: Text(
                                widget.controller.lastHomeOwnerError!,
                              ),
                            ),
                          );
                        }
                      } catch (e) {
                        AppLogger.warn(
                          'Home owner edit failed',
                          tag: 'Residents',
                          error: e,
                        );
                      }
                    },
                    child: const Text(AppStrings.save),
                  ),
                ),
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
                      border: Border.all(
                        color: AppColors.accentCyan.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'İkamet Durumu / Sakin Tipi (Kat Maliki / Kiracı)',
                          style: TextStyle(
                            color: AppColors.textPrimary(ctx),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: testId(
                            'module_edit_occupancy_role_selector',
                            SegmentedButton<String>(
                              key: const Key(
                                'module_edit_occupancy_role_selector',
                              ),
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
                                  icon: Icon(
                                    Icons.meeting_room_outlined,
                                    size: 16,
                                  ),
                                ),
                              ],
                              selected: {occupancyMode},
                              onSelectionChanged: (newSelection) {
                                setDlgState(
                                  () => occupancyMode = newSelection.first,
                                );
                              },
                            ),
                          ),
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
                              const Icon(
                                Icons.key,
                                size: 16,
                                color: AppColors.accentCyan,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Kiracı Bilgileri (Fiilen İkamet Eden)',
                                  style: TextStyle(
                                    color: AppColors.textPrimary(ctx),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _identityLink(
                            ctx,
                            'module_edit_tenant_person_card',
                            ho.tenantFullName ?? '',
                            ho.tenantPhone,
                            ho.tenantEmail,
                            tenantPersonId,
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
                            const Icon(
                              Icons.vpn_key_outlined,
                              size: 16,
                              color: AppColors.accentGreen,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Kat Maliki (Ev Sahibi / Mülk Sahibi) Bilgileri',
                                style: TextStyle(
                                  color: AppColors.textPrimary(ctx),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _identityLink(
                          ctx,
                          'module_edit_owner_person_card',
                          ho.ownerFullName,
                          ho.phone,
                          ho.email,
                          ownerPersonId,
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
                          border: Border.all(
                            color: AppColors.accentPurple.withOpacity(0.35),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.family_restroom,
                                  size: 16,
                                  color: AppColors.accentPurple,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Hane Sakinleri / Birlikte Yaşayanlar (${currentHo.householdResidents.length})',
                                    style: TextStyle(
                                      color: AppColors.textPrimary(ctx),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                testId(
                                  'module_edit_dialog_add_household_member',
                                  ElevatedButton.icon(
                                    key: const Key(
                                      'module_edit_dialog_add_household_member',
                                    ),
                                    onPressed: () {
                                      _openAddHouseholdMember(currentHo);
                                      setDlgState(() {});
                                    },
                                    icon: const Icon(
                                      Icons.person_add_alt,
                                      size: 12,
                                    ),
                                    label: const Text(
                                      '+ Hane Sakini Ekle',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.accentPurple,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      minimumSize: const Size(0, 28),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            if (currentHo.householdResidents.isNotEmpty) ...[
                              ...currentHo.householdResidents.map(
                                (m) => Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.background(ctx),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: AppColors.border(ctx)
                                          .withOpacity(0.5),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.person_outline,
                                        size: 14,
                                        color: AppColors.accentPurple,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              m.fullName,
                                              style: TextStyle(
                                                color: AppColors.textPrimary(
                                                  ctx,
                                                ),
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            Text(
                                              '${HouseholdRelationship.labelFor(m.relationship)}${m.phone.isNotEmpty ? ' • ${m.phone}' : ''}',
                                              style: TextStyle(
                                                color: AppColors.textSecondary(
                                                  ctx,
                                                ),
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          size: 14,
                                          color: AppColors.accentCyan,
                                        ),
                                        tooltip: 'Düzenle',
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () {
                                          _openEditHouseholdMember(
                                            currentHo,
                                            m,
                                          );
                                          setDlgState(() {});
                                        },
                                      ),
                                      const SizedBox(width: 6),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.close,
                                          size: 14,
                                          color: AppColors.accentRed,
                                        ),
                                        tooltip: AppStrings.delete,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () {
                                          _confirmDeleteHouseholdMember(
                                            currentHo,
                                            m,
                                          );
                                          setDlgState(() {});
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ] else ...[
                              Text(
                                'Bu daireye kayıtlı ek hane sakini bulunmuyor. Yeni hane sakini eklemek için yukarıdaki butonu kullanabilirsiniz.',
                                style: TextStyle(
                                  color: AppColors.textSecondary(ctx),
                                  fontSize: 12,
                                  fontStyle: FontStyle.italic,
                                ),
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
    PersonRef? person;
    final relationCtrl = TextEditingController(
      text: HouseholdRelationship.spouse.code,
    );
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
                OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(AppStrings.cancel),
                ),
                testId(
                  'module_save_household_btn',
                  ElevatedButton(
                    key: const Key('module_save_household_btn'),
                    onPressed: () async {
                      if (person == null) return;
                      final success = await widget.controller
                          .addHouseholdMember(
                            unitId: ho.unitId,
                            block: ho.block,
                            unitNo: ho.unitNo,
                            fullName: '',
                            relationship: relationCtrl.text.trim(),
                            phone: '',
                            email: '',
                            person: person,
                          );
                      if (setAsPrimary && success) {
                        widget.controller.setPrimaryResponsibleResident(
                          unitId: ho.unitId,
                          residentName: '',
                          role: 'RESIDENT',
                          personId: person?.personId,
                        );
                      }
                      if (success && ctx.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          appSnackBar(
                            content: Text('Hane sakini başarıyla eklendi.'),
                          ),
                        );
                      }
                    },
                    child: const Text('Ekle'),
                  ),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  SpPersonField(
                    repository: widget.personRepository,
                    roleContext: 'household',
                    unitId: ho.unitId,
                    value: person,
                    onChanged: (value) => setDlgState(() => person = value),
                    id: 'module_member_name_input',
                  ),
                  const SizedBox(height: 12),
                  testId(
                    'module_member_relation_input',
                    DropdownButtonFormField<String>(
                      key: const Key('module_member_relation_input'),
                      initialValue: relationCtrl.text,
                      items: householdRelationshipItems(),
                      onChanged: (code) => relationCtrl.text =
                          code ?? HouseholdRelationship.other.code,
                      decoration: const InputDecoration(
                        labelText: 'Yakınlık Derecesi',
                        filled: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const SizedBox(height: 12),
                  Material(
                    color: Colors.transparent,
                    child: testId(
                      'module_member_set_primary_switch',
                      SwitchListTile(
                        key: const Key('module_member_set_primary_switch'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text(
                          'Bu kişiyi dairenin aktif sorumlusu yap',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: const Text(
                          'Bildirimler ve birincil muhataplık bu kişiye yönlendirilir',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: setAsPrimary,
                        activeThumbColor: AppColors.accentPurple,
                        onChanged: (val) {
                          setDlgState(() => setAsPrimary = val);
                        },
                      ),
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

  /// Read-only identity summary that routes edits through the person card.
  Widget _identityLink(
    BuildContext ctx,
    String id,
    String name,
    String? phone,
    String? email,
    int? personId,
  ) {
    final contact = [
      if (phone != null && phone.isNotEmpty) phone,
      if (email != null && email.isNotEmpty) email,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name.isEmpty ? '—' : name,
          style: TextStyle(
            color: AppColors.textPrimary(ctx),
            fontWeight: FontWeight.w600,
          ),
        ),
        if (contact.isNotEmpty)
          Text(
            contact,
            style: TextStyle(color: AppColors.textSecondary(ctx), fontSize: 12),
          ),
        const SizedBox(height: 6),
        testId(
          id,
          OutlinedButton.icon(
            key: Key(id),
            onPressed: personId == null
                ? null
                : () => Navigator.of(ctx).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PersonProfilePage(personId: personId),
                    ),
                  ),
            icon: const Icon(Icons.badge_outlined, size: 16),
            label: const Text('Kişi kartını aç'),
          ),
        ),
      ],
    );
  }

  void _openEditHouseholdMember(HomeOwnerItem ho, UnitResidentMember member) {
    final relationCtrl = TextEditingController(
      text: HouseholdRelationship.fromValue(member.relationship).code,
    );

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: 'Hane Sakinini Düzenle',
        subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(AppStrings.cancel),
            ),
            ElevatedButton(
              onPressed: () async {
                final success = await widget.controller.updateHouseholdMember(
                  unitId: ho.unitId,
                  residentId: member.id,
                  fullName: member.fullName,
                  relationship: relationCtrl.text.trim(),
                  phone: member.phone,
                  email: member.email,
                );
                if (success && ctx.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    appSnackBar(
                      content: Text('Hane sakini bilgileri güncellendi.'),
                    ),
                  );
                }
              },
              child: const Text(AppStrings.save),
            ),
          ],
        ),
        child: Column(
          children: [
            _identityLink(
              ctx,
              'module_edit_member_person_card',
              member.fullName,
              member.phone,
              member.email,
              member.personId,
            ),
            const SizedBox(height: 12),
            testId(
              'module_edit_member_relation_input',
              DropdownButtonFormField<String>(
                key: const Key('module_edit_member_relation_input'),
                initialValue: relationCtrl.text,
                items: householdRelationshipItems(),
                onChanged: (code) => relationCtrl.text =
                    code ?? HouseholdRelationship.other.code,
                decoration: const InputDecoration(
                  labelText: 'Yakınlık Derecesi',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteHouseholdMember(
    HomeOwnerItem ho,
    UnitResidentMember member,
  ) async {
    final confirmed = await AppFullscreenPage.pushConfirmation(
      context: context,
      title: 'Hane Sakinini Sil',
      message:
          '${member.fullName} isimli sakin kaydını silmek istediğinize emin misiniz?',
      confirmLabel: 'Evet, Sil',
    );
    if (confirmed == true) {
      await widget.controller.deleteHouseholdMember(
        unitId: ho.unitId,
        residentId: member.id,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          appSnackBar(content: Text('${member.fullName} kaydı silindi.')),
        );
      }
    }
  }
}
