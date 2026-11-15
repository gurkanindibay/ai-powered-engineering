part of 'owners_residents_module_page.dart';

/// Move-in, move-out, ownership transfer, unit history, IBAN details and archiving.
extension _OccupancyActions on _OwnersResidentsModulePageState {
  void _openMoveOut(HomeOwnerItem ho) {
    final notesCtrl = TextEditingController();
    var effectiveDate = DateTime.now();
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setMoveOutState) => AppFullscreenPage(
        title: 'Sakin Ayrılışı (Move-Out / Tahliye)',
        subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppStrings.cancel)),
            testId('module_confirm_move_out_btn', ElevatedButton(
              key: const Key('module_confirm_move_out_btn'),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.warningFill, foregroundColor: Colors.white),
              onPressed: () async {
                final success = await widget.controller.moveOutResident(ho.unitId, notes: notesCtrl.text.trim(), effectiveDate: effectiveDate);
                if (success && ctx.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    appSnackBar(content: Text('Sakin tahliye işlemi kaydedildi.')),
                  );
                }
              },
              child: const Text('Tahliyeyi Onayla'),
            )),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ayrılan Sakin: ${ho.activeResponsibleResidentName}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 12),
            testId('module_move_out_effective_date', SpEffectiveDateField(
              key: const Key('module_move_out_effective_date'),
              value: effectiveDate,
              onChanged: (d) => setMoveOutState(() => effectiveDate = d),
            )),
            const SizedBox(height: 12),
            TextField(
              controller: notesCtrl,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Tahliye Notları / Anahtar Teslim Durumu'),
            ),
          ],
        ),
      )),
    );
  }

  /// The tenant form for T2 (vacant unit), C1 (replace the tenant) and C2 (the
  /// owner rents the unit out). An owner never moves in through this form:
  /// that is [_openOwnerMoveIn], which takes no person data (STORY-08-06).
  void _openMoveIn(HomeOwnerItem ho, {OccupancyCommand command = OccupancyCommand.tenantMoveIn}) {
    PersonRef? person;
    bool isSaving = false;

    final title = switch (command) {
      OccupancyCommand.replaceTenant => 'Kiracı Değişikliği',
      OccupancyCommand.ownerRentsOut => 'Daireyi Kiraya Ver',
      _ => 'Kiracı Girişi (Move-In)',
    };
    final settlementNote = switch (command) {
      OccupancyCommand.replaceTenant =>
        'Mevcut kiracı ${ho.tenantFullName ?? ''} aynı gün tahliye edilir ve çıkış bakiyesi kaydedilir.',
      OccupancyCommand.ownerRentsOut =>
        'Kat maliki ${ho.ownerFullName} daireden ayrılır; tapu sahibi değişmez.',
      _ => 'Kat maliki ${ho.ownerFullName} olarak kalır; kiracı yalnızca daireye taşınır.',
    };

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          return AppFullscreenPage(
            title: title,
            subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(onPressed: isSaving ? null : () => Navigator.pop(ctx), child: const Text(AppStrings.cancel)),
                testId('module_confirm_move_in_btn', ElevatedButton(
                  key: const Key('module_confirm_move_in_btn'),
                  onPressed: isSaving
                      ? null
                      : () async {
                          final messenger = ScaffoldMessenger.of(this.context);
                          if (person == null) {
                            messenger.showSnackBar(spSnackBar(kind: ToastKind.warning, content: const Text('İşlem için bir kişi seçin veya oluşturun.')));
                            return;
                          }
                          setDlgState(() => isSaving = true);
                          final result = await widget.controller.applyOccupancyTransition(
                            ho.unitId,
                            command: command,
                            person: person,
                          );
                          if (!ctx.mounted) return;
                          setDlgState(() => isSaving = false);
                          if (!result.ok) {
                            messenger.showSnackBar(spSnackBar(
                              kind: ToastKind.error,
                              content: Text(result.message ?? 'Giriş kaydedilemedi. Bilgileri kontrol edip tekrar deneyin.'),
                            ));
                            return;
                          }
                          Navigator.pop(ctx);
                          messenger.showSnackBar(appSnackBar(content: const Text('Kiracı girişi başarıyla yapıldı.')));
                        },
                  child: const Text('Girişi Tamamla'),
                )),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(settlementNote, style: TextStyle(color: AppColors.textSecondary(ctx), fontSize: 12)),
                  const SizedBox(height: 16),
                  SpPersonField(
                    repository: widget.personRepository,
                    roleContext: 'tenant',
                    unitId: ho.unitId,
                    value: person,
                    onChanged: (value) => setDlgState(() => person = value),
                    id: 'module_move_in_pick_existing_btn',
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// T3 owner move-in or C3 owner takes the unit back: a confirmation naming
  /// the owner on record, with no person fields. With several owners the
  /// manager picks one of them (decision A1).
  void _openOwnerMoveIn(HomeOwnerItem ho, {OccupancyCommand command = OccupancyCommand.ownerMoveIn}) {
    final stateFuture = widget.controller.fetchOccupancyState(ho.unitId);
    int? selectedOwner;
    bool isSaving = false;
    final takesBack = command == OccupancyCommand.ownerTakesBack;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => FutureBuilder<UnitOccupancyState?>(
        future: stateFuture,
        builder: (context, snapshot) {
          final state = snapshot.data ?? UnitOccupancyState.fromHomeOwner(ho);
          final owners = state.owners;
          final loading = snapshot.connectionState == ConnectionState.waiting;
          return StatefulBuilder(
            builder: (context, setDlgState) {
              final ownerId = selectedOwner ?? (owners.length == 1 ? owners.first.personId : null);
              final ownerName = owners.where((o) => o.personId == ownerId).map((o) => o.fullName).firstOrNull;
              final canConfirm = !loading && !isSaving && (owners.length == 1 || ownerId != null);
              return AppFullscreenPage(
                title: takesBack ? 'Kat Maliki Daireyi Geri Alsın' : 'Kat Maliki Taşınsın',
                subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
                bottomBar: AppFullscreenPage.buildBottomBar(
                  context: ctx,
                  children: [
                    OutlinedButton(onPressed: isSaving ? null : () => Navigator.pop(ctx), child: const Text(AppStrings.cancel)),
                    testId('module_confirm_owner_move_in_btn', ElevatedButton(
                      key: const Key('module_confirm_owner_move_in_btn'),
                      onPressed: !canConfirm
                          ? null
                          : () async {
                              final messenger = ScaffoldMessenger.of(this.context);
                              setDlgState(() => isSaving = true);
                              final result = await widget.controller.applyOccupancyTransition(
                                ho.unitId,
                                command: command,
                                ownerPersonId: owners.length > 1 ? ownerId : null,
                              );
                              if (!ctx.mounted) return;
                              setDlgState(() => isSaving = false);
                              if (!result.ok) {
                                messenger.showSnackBar(spSnackBar(
                                  kind: ToastKind.error,
                                  content: Text(result.message ?? 'Kat maliki girişi kaydedilemedi.'),
                                ));
                                return;
                              }
                              Navigator.pop(ctx);
                              messenger.showSnackBar(appSnackBar(content: Text('${ownerName ?? 'Kat maliki'} daireye taşındı.')));
                            },
                      child: const Text('Onayla'),
                    )),
                  ],
                ),
                child: loading
                    ? const SpSkeletonList()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (takesBack)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                'Kiracı ${ho.tenantFullName ?? ''} aynı gün tahliye edilir ve çıkış bakiyesi kaydedilir.',
                                style: TextStyle(color: AppColors.textSecondary(ctx), fontSize: 12),
                              ),
                            ),
                          if (owners.isEmpty)
                            Text(
                              'Bu dairenin kayıtlı kat maliki yok. Önce kat malikini kaydedin.',
                              style: TextStyle(color: AppColors.dangerText(ctx), fontSize: 13),
                            )
                          else if (owners.length == 1)
                            testId('module_owner_move_in_owner_name', Text(
                              '${owners.first.fullName} daireye taşınacak. Kat maliki değişmez; yeni bir malik yalnızca tapu devri ile kaydedilir.',
                              style: TextStyle(color: AppColors.textPrimary(ctx), fontSize: 14, fontWeight: FontWeight.bold),
                            ))
                          else ...[
                            Text(
                              'Daireye taşınacak kat malikini seçin. Kat maliki değişmez.',
                              style: TextStyle(color: AppColors.textPrimary(ctx), fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            for (final owner in owners)
                              testId('module_owner_move_in_option_${owner.personId}', RadioListTile<int>(
                                value: owner.personId,
                                groupValue: ownerId,
                                onChanged: (v) => setDlgState(() => selectedOwner = v),
                                title: Text(owner.fullName),
                                subtitle: Text('Hisse: %${owner.sharePercentage}'),
                              )),
                          ],
                        ],
                      ),
              );
            },
          );
        },
      ),
    );
  }

  void _openUnitHistory(HomeOwnerItem ho) {
    final historyFuture = widget.controller.fetchOccupancyHistory(ho.unitId);

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => FutureBuilder<List<OccupancyHistoryItem>>(
        future: historyFuture,
        builder: (context, snapshot) {
          final historyList = snapshot.data ?? [];
          final isLoading = snapshot.connectionState == ConnectionState.waiting;

          return AppFullscreenPage(
            title: 'Daire Sakin & İkamet Tarihçesi',
            subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(AppStrings.close),
                ),
              ],
            ),
            child: isLoading
                ? const SpSkeletonList()
                : (historyList.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('Bu daire için kayıtlı geçmiş ikamet bulunmuyor.'),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: historyList.length,
                        separatorBuilder: (_, __) => const Divider(height: 24),
                        itemBuilder: (c, idx) {
                          final item = historyList[idx];
                          final lines = [
                            '${item.role.toUpperCase() == 'TENANT' ? 'Kiracı' : 'Kat Maliki'} • Giriş: ${item.startDate}'
                                '${item.endDate != null ? ' • Çıkış: ${item.endDate}' : ' • Devam Ediyor'}',
                            if (item.exitBalance > Decimal.zero) 'Kapanış Bakiyesi: ${formatTry(item.exitBalance)} Borç',
                            if (item.notes != null && item.notes!.isNotEmpty) 'Not: ${item.notes}',
                          ];
                          return testId('history_item_${item.id}', ListTile(
                            leading: CircleAvatar(
                              backgroundColor: item.isActive ? AppColors.accentGreen.withOpacity(0.15) : AppColors.border(context),
                              child: Icon(item.isActive ? Icons.person : Icons.person_outline, color: item.isActive ? AppColors.accentGreen : AppColors.textSecondary(context)),
                            ),
                            title: Text(item.personName, style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text(lines.join('\n')),
                            isThreeLine: lines.length > 1,
                          ));
                        },
                      )),
          );
        },
      ),
    );
  }

  void _openIbanDetails(HomeOwnerItem ho) {
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: 'Sanal IBAN & Banka Eşleşme',
        subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(AppStrings.close),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface(ctx),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.accentCyan.withOpacity(0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Daireye Özel Tahsisli Sanal IBAN', style: TextStyle(color: AppColors.primaryText(context), fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 8),
                  Text(
                    widget.controller.activeUnit.virtualIban ?? 'TR91 0020 5000 0986 3791 6000 01',
                    style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text('Bu IBAN numarasına gönderilen tüm FAST/Havale ödemeleri %100 doğrulukla doğrudan bu dairenin aidat borcuna mahsup edilir.', style: TextStyle(color: AppColors.textSecondary(ctx), fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openTransferOwnership(HomeOwnerItem ho) {
    PersonRef? newOwner;
    final notesCtrl = TextEditingController();
    bool isSubmitting = false;
    bool newOwnerMovesIn = false;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          return AppFullscreenPage(
            title: 'Mülk Tapu Devri & Satış İşlemi',
            subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(
                  onPressed: isSubmitting ? null : () => Navigator.pop(ctx),
                  child: const Text(AppStrings.cancel),
                ),
                testId('module_confirm_transfer_ownership_btn', ElevatedButton(
                  key: const Key('module_confirm_transfer_ownership_btn'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.successFill,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          if (newOwner == null) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              appSnackBar(content: const Text('Yeni kat malikini seçin veya oluşturun.')),
                            );
                            return;
                          }
                          setDlgState(() => isSubmitting = true);
                          try {
                            final messenger = ScaffoldMessenger.of(this.context);
                            final selected = newOwner!;
                            final details = selected.personId == null
                                ? null
                                : await widget.personRepository.getById(selected.personId!);
                            if (details == null) {
                              if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(appSnackBar(content: const Text('Kişi kartı yüklenemedi.')));
                              return;
                            }
                            // Ownership transfer is a sensitive action: the server asks for a
                            // recent password check, then the same request is retried once.
                            final res = await runWithStepUp(
                              ctx,
                              reason: 'Mülk malikini değiştiriyorsunuz. Devam etmek için kendi şifrenizi doğrulayın.',
                              action: () => widget.controller.transferUnitOwnership(
                                unitId: ho.unitId,
                                newOwnerName: details.fullName,
                                newOwnerPhone: details.phone,
                                newOwnerEmail: details.email,
                                newOwner: selected,
                                notes: notesCtrl.text.trim(),
                                newOwnerMovesIn: ho.isOwnerOccupied && newOwnerMovesIn,
                              ),
                            );
                            if (res != null && res['success'] == false && ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                appSnackBar(
                                  content: Text(res['needs_step_up'] == true
                                      ? 'Şifre doğrulaması gerekli. Devir yapılmadı.'
                                      : 'Hata: ${res['message']}'),
                                  backgroundColor: AppColors.dangerFill,
                                ),
                              );
                            } else if (res != null && ctx.mounted) {
                              Navigator.pop(ctx);
                              messenger.showSnackBar(
                                appSnackBar(
                                  content: Text(res['message']?.toString() ?? 'Mülk tapu devri başarıyla tamamlandı.'),
                                  backgroundColor: AppColors.successFill,
                                ),
                              );
                            }
                          } catch (e) {
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                appSnackBar(content: Text('Hata: $e'), backgroundColor: AppColors.dangerFill),
                              );
                            }
                          } finally {
                            if (ctx.mounted) {
                              setDlgState(() => isSubmitting = false);
                            }
                          }
                        },
                  child: isSubmitting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Tapu Devrini Onayla'),
                )),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.teal.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.teal.withOpacity(0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.info_outline, color: AppColors.accentGreen, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'KMK Uyarınca Mülk Devir Esasları',
                                style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '• Mevcut Kat Maliki: ${ho.ownerFullName.isNotEmpty ? ho.ownerFullName : "Bilinmiyor"}\n'
                          '• Devir anına kadar olan tüm ödenmemiş borçlar ve avanslar eski malik hesabında dondurulur ve arşivlenir.\n'
                          '• Yeni kat maliki tapu tescil tarihi itibarıyla tahakkuk edecek aidat ve demirbaşlardan sorumlu olur.\n'
                          '${ho.isTenantOccupied ? "• Dairedeki aktif kiracının (${ho.tenantFullName ?? 'Kiracı'}) sözleşmesi ve sorumluluğu aynen devam eder." : "• Daire mülk sahibi kullanımında görünmektedir."}',
                          style: TextStyle(color: AppColors.textSecondary(ctx), fontSize: 12, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Yeni Kat Maliki Bilgileri',
                    style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 12),
                  SpPersonField(
                    repository: widget.personRepository,
                    roleContext: 'owner',
                    unitId: ho.unitId,
                    value: newOwner,
                    onChanged: (value) => setDlgState(() => newOwner = value),
                    id: 'module_transfer_new_owner_name_input',
                  ),
                  const SizedBox(height: 12),
                  testId('module_transfer_notes_input', TextField(
                    key: const Key('module_transfer_notes_input'),
                    controller: notesCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Tapu Devir Notları / Noter Satış Bilgisi',
                      prefixIcon: Icon(Icons.note_alt_outlined, size: 18),
                      border: OutlineInputBorder(),
                    ),
                  )),
                  const SizedBox(height: 12),
                  // STORY-08-09: what happens to the occupancy at transfer.
                  if (ho.isOwnerOccupied)
                    testId('module_transfer_new_owner_moves_in', CheckboxListTile(
                      key: const Key('module_transfer_new_owner_moves_in'),
                      value: newOwnerMovesIn,
                      onChanged: (v) => setDlgState(() => newOwnerMovesIn = v ?? false),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Yeni kat maliki daireye taşınıyor'),
                      subtitle: const Text('İşaretlenmezse eski malik ayrılır ve daire boş kalır.'),
                    ))
                  else
                    Text(
                      ho.isTenantOccupied
                          ? 'Kiracılık devam eder; kira sözleşmesi tapu devrinden etkilenmez.'
                          : 'Daire boş kalır; yeni kat maliki daha sonra "Kat Maliki Taşınsın" ile taşınabilir.',
                      style: TextStyle(color: AppColors.textSecondary(ctx), fontSize: 12),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openDeleteUnit(HomeOwnerItem ho) async {
    final confirmed = await AppFullscreenPage.pushConfirmation(
      context: context,
      title: 'Kat Malikini Sil',
      message: '${ho.ownerFullName} isimli kat malikini silmek istediğinize emin misiniz?',
      confirmLabel: 'Evet, Sil',
    );
    if (confirmed == true) {
      final success = await widget.controller.deleteHomeOwner(unitId: ho.unitId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          appSnackBar(
            content: Text(success
                ? 'Kat maliki başarıyla silindi.'
                : (widget.controller.lastDeleteHomeOwnerError ?? 'Kat maliki silinirken bir hata oluştu.')),
            backgroundColor: success ? AppColors.successFill : AppColors.dangerFill,
          ),
        );
      }
    }
  }
}
