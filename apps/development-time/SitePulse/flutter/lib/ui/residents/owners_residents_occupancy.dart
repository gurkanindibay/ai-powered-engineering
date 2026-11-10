part of 'owners_residents_module_page.dart';

/// Move-in, move-out, ownership transfer, unit history, IBAN details and archiving.
extension _OccupancyActions on _OwnersResidentsModulePageState {
  void _openMoveOut(HomeOwnerItem ho) {
    final notesCtrl = TextEditingController();
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
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
                final success = await widget.controller.moveOutResident(ho.unitId, notes: notesCtrl.text.trim());
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
            TextField(
              controller: notesCtrl,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Tahliye Notları / Anahtar Teslim Durumu'),
            ),
          ],
        ),
      ),
    );
  }

  void _openMoveIn(HomeOwnerItem ho) {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    String selectedRole = 'TENANT'; // 'TENANT' or 'OWNER'
    PersonSummary? chosen; // U7: an existing person of the site

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          return AppFullscreenPage(
            title: 'Yeni Sakin / Giriş (Move-In)',
            subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppStrings.cancel)),
                testId('module_confirm_move_in_btn', ElevatedButton(
                  key: const Key('module_confirm_move_in_btn'),
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    final messenger = ScaffoldMessenger.of(this.context);
                    final problem = name.isEmpty
                        ? 'Ad soyad gerekli.'
                        : (chosen == null ? validatePersonEmail(emailCtrl.text) : null);
                    if (problem != null) {
                      messenger.showSnackBar(spSnackBar(kind: ToastKind.warning, content: Text(problem)));
                      return;
                    }
                    final success = await widget.controller.moveInResident(
                      ho.unitId,
                      role: selectedRole,
                      fullName: name,
                      phone: phoneCtrl.text.trim(),
                      email: emailCtrl.text.trim(),
                      personId: chosen?.personId,
                    );
                    if (!success && ctx.mounted) {
                      messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: const Text('Giriş kaydedilemedi. Bilgileri kontrol edip tekrar deneyin.')));
                    }
                    if (success && ctx.mounted) {
                      Navigator.pop(ctx);
                      final roleLabel = selectedRole == 'OWNER' ? 'Kat Maliki' : 'Kiracı';
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        appSnackBar(content: Text('Yeni $roleLabel girişi başarıyla yapıldı.')),
                      );
                    }
                  },
                  child: const Text('Girişi Tamamla'),
                )),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'İkamet Edecek Kişinin Rolü (Kat Maliki / Kiracı)',
                    style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: testId('module_move_in_role_selector', SegmentedButton<String>(
                      key: const Key('module_move_in_role_selector'),
                      segments: const [
                        ButtonSegment<String>(
                          value: 'TENANT',
                          label: Text('Kiracı Girişi'),
                          icon: Icon(Icons.key, size: 16),
                        ),
                        ButtonSegment<String>(
                          value: 'OWNER',
                          label: Text('Kat Maliki Girişi'),
                          icon: Icon(Icons.home_outlined, size: 16),
                        ),
                      ],
                      selected: {selectedRole},
                      onSelectionChanged: (newSelection) {
                        setDlgState(() => selectedRole = newSelection.first);
                      },
                    )),
                  ),
                  const SizedBox(height: 16),
                  testId('module_move_in_pick_existing_btn', OutlinedButton.icon(
                    key: const Key('module_move_in_pick_existing_btn'),
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(this.context);
                      try {
                        final page = await const PersonDirectoryApi().directory(pageSize: 100);
                        if (!ctx.mounted) return;
                        final picked = await showSpSelection<PersonSummary>(
                          context: ctx,
                          title: 'Mevcut kişiyi seçin',
                          options: page.items,
                          labelOf: (p) => [p.fullName, if (p.email.isNotEmpty) p.email].join(' • '),
                          idOf: (p) => 'move_in_person_${p.personId}',
                        );
                        if (picked == null) return;
                        setDlgState(() {
                          chosen = picked;
                          nameCtrl.text = picked.fullName;
                          phoneCtrl.text = picked.phone;
                          emailCtrl.text = picked.email;
                        });
                      } catch (_) {
                        messenger.showSnackBar(spSnackBar(kind: ToastKind.error, content: const Text('Kişi listesi yüklenemedi.')));
                      }
                    },
                    icon: const Icon(Icons.person_search_outlined, size: 16),
                    label: Text(chosen == null ? 'Mevcut kişilerden seç' : 'Seçili: ${chosen!.fullName} (değiştir)'),
                  )),
                  if (chosen != null)
                    TextButton(
                      onPressed: () => setDlgState(() {
                        chosen = null;
                        nameCtrl.clear();
                        phoneCtrl.clear();
                        emailCtrl.clear();
                      }),
                      child: const Text('Yeni kişi gir'),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameCtrl,
                    readOnly: chosen != null,
                    decoration: InputDecoration(
                      labelText: selectedRole == 'OWNER' ? 'Kat Maliki Ad Soyad *' : 'Kiracı Ad Soyad *',
                      filled: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: phoneCtrl,
                    readOnly: chosen != null,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Telefon', filled: true, border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: emailCtrl,
                    readOnly: chosen != null,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'E-posta', filled: true, border: OutlineInputBorder()),
                  ),
                ],
              ),
            ),
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
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: item.isActive ? AppColors.accentGreen.withOpacity(0.15) : AppColors.border(context),
                              child: Icon(item.isActive ? Icons.person : Icons.person_outline, color: item.isActive ? AppColors.accentGreen : AppColors.textSecondary(context)),
                            ),
                            title: Text(item.personName, style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text('${item.role} • ${item.startDate} / ${item.endDate ?? "Devam Ediyor"}\n${item.notes ?? ""}'),
                            isThreeLine: item.notes != null && item.notes!.isNotEmpty,
                          );
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
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    bool isSubmitting = false;

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
                          final newName = nameCtrl.text.trim();
                          if (newName.isEmpty) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              appSnackBar(content: Text('Lütfen yeni malikin adını ve soyadını giriniz.')),
                            );
                            return;
                          }
                          setDlgState(() => isSubmitting = true);
                          try {
                            final messenger = ScaffoldMessenger.of(this.context);
                            final res = await widget.controller.transferUnitOwnership(
                              unitId: ho.unitId,
                              newOwnerName: newName,
                              newOwnerPhone: phoneCtrl.text.trim(),
                              newOwnerEmail: emailCtrl.text.trim(),
                              notes: notesCtrl.text.trim(),
                            );
                            if (res != null && ctx.mounted) {
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
                  testId('module_transfer_new_owner_name_input', TextField(
                    key: const Key('module_transfer_new_owner_name_input'),
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Yeni Kat Maliki Adı Soyadı *',
                      prefixIcon: Icon(Icons.person, size: 18),
                      border: OutlineInputBorder(),
                    ),
                  )),
                  const SizedBox(height: 12),
                  testId('module_transfer_new_owner_phone_input', TextField(
                    key: const Key('module_transfer_new_owner_phone_input'),
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Yeni Kat Maliki Telefon',
                      prefixIcon: Icon(Icons.phone, size: 18),
                      border: OutlineInputBorder(),
                    ),
                  )),
                  const SizedBox(height: 12),
                  testId('module_transfer_new_owner_email_input', TextField(
                    key: const Key('module_transfer_new_owner_email_input'),
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Yeni Kat Maliki E-Posta',
                      prefixIcon: Icon(Icons.email, size: 18),
                      border: OutlineInputBorder(),
                    ),
                  )),
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
