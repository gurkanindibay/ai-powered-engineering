part of 'owners_residents_module_page.dart';

/// Registering a unit's owner, tenant and co-residents, and choosing the responsible payer.
extension _Registration on _OwnersResidentsModulePageState {
  void _showSelectPrimaryResponsibleDialog(HomeOwnerItem ho) {
    showResponsibleContactSelection(context, widget.controller, ho);
  }

  void _openAddResident(BuildContext context) {
    _showAddResidentFullscreen();
  }

  void _showAddResidentFullscreen() {
    final availableBlocks = widget.controller.blocks;
    String selectedBlock = availableBlocks.isNotEmpty
        ? availableBlocks.first
        : 'A';
    final houseTypes = widget.controller.houseTypes;
    String? selectedHouseType = houseTypes.isNotEmpty
        ? houseTypes.first.typeName
        : null;

    PersonRef? ownerRef;
    PersonRef? tenantRef;
    PersonSummary? ownerPerson;
    PersonSummary? tenantPerson;
    final unitCtrl = TextEditingController();
    final landShareCtrl = TextEditingController();

    // Dynamic co-residents (Hane Sakinleri / Birlikte İkamet Eden Bireyler)
    final pendingResidents = <_PendingResidentEntry>[];

    String occupancyStatus =
        'OWNER_OCCUPIED'; // 'OWNER_OCCUPIED', 'TENANT_OCCUPIED', 'VACANT'
    String? formError;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          final currentBlocks = widget.controller.blocks.isNotEmpty
              ? widget.controller.blocks
              : ['A', 'B'];
          if (!currentBlocks.contains(selectedBlock)) {
            selectedBlock = currentBlocks.first;
          }
          final currentHouseTypes = widget.controller.houseTypes;
          if (selectedHouseType == null && currentHouseTypes.isNotEmpty) {
            selectedHouseType = currentHouseTypes.first.typeName;
          }
          final currentTariff = currentHouseTypes
              .cast<HouseTypeTariff?>()
              .firstWhere(
                (t) => t?.typeName == selectedHouseType,
                orElse: () => null,
              );

          return AppFullscreenPage(
            title: 'Yeni Daire / Sakin Tanımla',
            subtitle: 'Daire Bilgisi, Kat Maliki (Mülk Sahibi), Kullanım Durumu ve Hane Sakinlerini Belirleyin',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentCyan.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.person_add_alt_1_outlined,
                color: AppColors.accentCyan,
                size: 20,
              ),
            ),
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(AppStrings.cancel),
                ),
                testId(
                  'module_save_new_resident_btn',
                  ElevatedButton(
                    key: const Key('module_save_new_resident_btn'),
                    onPressed: () async {
                      setDlgState(() => formError = null);
                      final unitText = unitCtrl.text.trim();
                      final unitNo = int.tryParse(unitText);

                      if (ownerRef == null ||
                          unitText.isEmpty ||
                          unitNo == null ||
                          unitNo <= 0) {
                        setDlgState(() {
                          formError = 'Lütfen geçerli bir Daire No giriniz ve Kat Maliki kişisini seçiniz.';
                        });
                        return;
                      }

                      final landShareError = validateLandShare(
                        landShareCtrl.text,
                      );
                      if (landShareError != null) {
                        setDlgState(() => formError = landShareError);
                        return;
                      }

                      if (occupancyStatus == 'TENANT_OCCUPIED' &&
                          tenantRef == null) {
                        setDlgState(() {
                          formError = 'Daire kirada seçildiğinde lütfen Kiracı kişisini seçiniz.';
                        });
                        return;
                      }

                      // Check if unit is already registered in controller.homeOwners
                      final cleanBlock = selectedBlock
                          .replaceAll('Blok', '')
                          .trim();
                      final existingHo = widget.controller.homeOwners
                          .cast<HomeOwnerItem?>()
                          .firstWhere((h) {
                            if (h == null) return false;
                            final b1 = h.block
                                .toUpperCase()
                                .replaceAll('BLOK', '')
                                .replaceAll(RegExp(r'[^A-Z0-9]'), '');
                            final b2 = cleanBlock
                                .toUpperCase()
                                .replaceAll('BLOK', '')
                                .replaceAll(RegExp(r'[^A-Z0-9]'), '');
                            return h.unitNo == unitNo && b1 == b2;
                          }, orElse: () => null);

                      if (existingHo != null) {
                        final existingName =
                            existingHo.tenantFullName ??
                            existingHo.ownerFullName;
                        final confirmed = await AppFullscreenPage.pushConfirmation(
                          context: ctx,
                          title: 'Yeni Daire / Sakin Atama Onayı',
                          message:
                              '$selectedBlock Daire $unitNo için halihazırda kayıtlı sakin: "$existingName".\n\n'
                              'Yeni kayıt yapıldığında mevcut sakin geçmiş ikamet arşivine aktarılacak ve yeni sakin aktif yapılacaktır.\n\n'
                              'Bu işlemi onaylıyor musunuz?',
                          confirmLabel: 'Evet, Yeni Sakin Kaydet',
                          cancelLabel: AppStrings.cancel,
                          confirmColor: AppColors.accentCyan,
                          icon: Icons.swap_horiz_rounded,
                          iconColor: AppColors.accentCyan,
                        );
                        if (confirmed != true) return;
                      }

                      if (!ctx.mounted) return;

                      if (!ctx.mounted) return;

                      final isResident = occupancyStatus == 'OWNER_OCCUPIED';
                      final isTenantOccupied =
                          occupancyStatus == 'TENANT_OCCUPIED';

                      final members = pendingResidents
                          .where((r) => r.person != null)
                          .map(
                            (r) => RegistrationMember(
                              person: r.person!,
                              relationship: r.relationship,
                              fullName: r.summary?.fullName ?? '',
                              phone: r.summary?.phone ?? '',
                              email: r.summary?.email ?? '',
                            ),
                          )
                          .toList();
                      await widget.controller.registerHomeOwner(
                        block: selectedBlock,
                        unitNo: unitNo,
                        ownerRef: ownerRef,
                        ownerName: ownerPerson?.fullName ?? '',
                        phone: ownerPerson?.phone ?? '',
                        email: ownerPerson?.email ?? '',
                        tenantRef: isTenantOccupied ? tenantRef : null,
                        tenantFullName: isTenantOccupied
                            ? tenantPerson?.fullName
                            : null,
                        tenantPhone: isTenantOccupied
                            ? tenantPerson?.phone
                            : null,
                        tenantEmail: isTenantOccupied
                            ? tenantPerson?.email
                            : null,
                        members: members,
                        houseType: selectedHouseType,
                        duesAmount: currentTariff?.duesAmount,
                        isResident: isResident,
                        role: isTenantOccupied ? 'TENANT' : 'OWNER',
                        landShare: parseLandShare(landShareCtrl.text),
                      );

                      // The dialog stays open until the server has answered; a refusal is shown here.
                      final registrationError =
                          widget.controller.lastHomeOwnerError;
                      if (registrationError != null) {
                        if (ctx.mounted)
                          setDlgState(() => formError = registrationError);
                        return;
                      }
                      if (ctx.mounted) Navigator.pop(ctx);

                      if (mounted) {
                        final addedCoResidentsCount = members.length;
                        final coResidentMsg = addedCoResidentsCount > 0
                            ? ' ve $addedCoResidentsCount hane sakini'
                            : '';
                        ScaffoldMessenger.of(context).showSnackBar(
                          appSnackBar(
                            content: Text(
                              'Yeni daire ($selectedBlock Daire $unitNo)$coResidentMsg başarıyla eklendi.',
                            ),
                          ),
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
                  if (formError != null) ...[
                    // U11: a refused registration is announced, not only coloured red.
                    Semantics(
                      liveRegion: true,
                      label: 'Hata: ${formError!}',
                      child: ExcludeSemantics(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Colors.redAccent.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.error_outline,
                                color: AppColors.accentRed,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  formError!,
                                  style: TextStyle(
                                    color: AppColors.dangerText(context),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],

                  // 1. Daire (Bağımsız Bölüm) Bilgisi Card
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppColors.card(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border(context)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.apartment,
                              size: 16,
                              color: AppColors.accentCyan,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '1. Daire (Bağımsız Bölüm) Bilgisi',
                                style: TextStyle(
                                  color: AppColors.textPrimary(context),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (currentTariff != null) ...[
                              const SizedBox(width: 6),
                              Text(
                                '${formatTry(currentTariff.duesAmount)}/ay',
                                style: TextStyle(
                                  color: AppColors.successText(context),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              flex: 5,
                              child: testId(
                                'module_new_resident_block',
                                DropdownButtonFormField<String>(
                                  key: const Key('module_new_resident_block'),
                                  value: selectedBlock,
                                  dropdownColor: AppColors.card(context),
                                  isDense: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Blok Seçiniz',
                                    filled: true,
                                    border: OutlineInputBorder(),
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                  ),
                                  items: currentBlocks
                                      .map(
                                        (b) => DropdownMenuItem(
                                          value: b,
                                          child: Text(b),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (val) {
                                    if (val != null)
                                      setDlgState(() => selectedBlock = val);
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 4,
                              child: testId(
                                'module_new_resident_unit',
                                TextField(
                                  key: const Key('module_new_resident_unit'),
                                  controller: unitCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Daire No *',
                                    hintText: 'Örn: 14',
                                    filled: true,
                                    border: OutlineInputBorder(),
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (currentHouseTypes.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          testId(
                            'module_new_resident_house_type',
                            DropdownButtonFormField<String>(
                              key: const Key('module_new_resident_house_type'),
                              value: selectedHouseType,
                              isDense: true,
                              dropdownColor: AppColors.card(context),
                              decoration: const InputDecoration(
                                labelText: 'Konut Tipi & Tarife',
                                filled: true,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                              ),
                              items: currentHouseTypes.map((ht) {
                                return DropdownMenuItem<String>(
                                  value: ht.typeName,
                                  child: Text(
                                    '${ht.typeName} (${formatTry(ht.duesAmount)}/ay)',
                                  ),
                                );
                              }).toList(),
                              onChanged: (val) {
                                if (val != null)
                                  setDlgState(() => selectedHouseType = val);
                              },
                            ),
                          ),
                        ] else ...[
                          const SizedBox(height: 10),
                          SpGuidanceCard(
                            icon: Icons.home_work_outlined,
                            title: 'Konut tipi tanımlanmamış',
                            message: 'Eklemek veya düzenlemek için Konut Tipleri & Tarifeler ekranını açın.',
                            tone: SpTone.warning,
                            action: testId(
                              'module_add_house_type',
                              TextButton.icon(
                                key: const Key('module_add_house_type'),
                                onPressed: () async {
                                  await showManageHouseTypesFullscreen(
                                    context,
                                    widget.controller,
                                  );
                                  if (!context.mounted) return;
                                  setDlgState(() {
                                    final updatedTypes =
                                        widget.controller.houseTypes;
                                    if (updatedTypes.isNotEmpty) {
                                      selectedHouseType =
                                          updatedTypes.first.typeName;
                                    }
                                  });
                                },
                                icon: const Icon(Icons.add),
                                label: const Text('Konut Tipleri & Tarifeler'),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // 2. Kat Maliki (Mülk Sahibi) Bilgileri Card
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppColors.card(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border(context)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.vpn_key_outlined,
                              size: 16,
                              color: AppColors.accentCyan,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '2. Kat Maliki (Mülk Sahibi) Bilgileri',
                                style: TextStyle(
                                  color: AppColors.textPrimary(context),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.accentCyan.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: AppColors.accentCyan.withValues(
                                alpha: 0.25,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.info_outline,
                                size: 15,
                                color: AppColors.accentCyan,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Kat Maliki: Dairenin yasal tapu sahibidir. Demirbaş ve ana bina giderlerinin kanuni muhatabıdır.',
                                  style: TextStyle(
                                    color: AppColors.textPrimary(context),
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        SpPersonField(
                          repository: widget.personRepository,
                          roleContext: 'owner',
                          value: ownerRef,
                          onResolved: (person) => ownerPerson = person,
                          onChanged: (value) =>
                              setDlgState(() => ownerRef = value),
                          id: 'module_new_resident_name',
                        ),
                        const SizedBox(height: 10),
                        testId(
                          'module_new_resident_land_share',
                          TextField(
                            key: const Key('module_new_resident_land_share'),
                            controller: landShareCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Arsa Payı (pay sayısı)',
                              hintText: 'Örn: 24',
                              helperText: 'Ortak giderler bu paya göre bölünür. Boş bırakılırsa sitenin olağan payı kullanılır.',
                              helperMaxLines: 2,
                              filled: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 3. Dairenin Kullanım Durumu Card
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppColors.card(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.accentGreen.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.sync_alt_rounded,
                              size: 16,
                              color: AppColors.accentGreen,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '3. Dairenin Kullanım Durumu',
                                style: TextStyle(
                                  color: AppColors.textPrimary(context),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Dairede kat maliki mi oturuyor, kiracı mı var yoksa daire boş mu?',
                          style: TextStyle(
                            color: AppColors.textSecondary(context),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: testId(
                            'module_occupancy_status_selector',
                            SegmentedButton<String>(
                              key: const Key(
                                'module_occupancy_status_selector',
                              ),
                              segments: const [
                                ButtonSegment<String>(
                                  value: 'OWNER_OCCUPIED',
                                  label: Text('Malik Oturuyor'),
                                  icon: Icon(Icons.person, size: 16),
                                ),
                                ButtonSegment<String>(
                                  value: 'TENANT_OCCUPIED',
                                  label: Text('Daire Kirada'),
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
                              selected: {occupancyStatus},
                              onSelectionChanged: (newSel) {
                                setDlgState(
                                  () => occupancyStatus = newSel.first,
                                );
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),

                        if (occupancyStatus == 'OWNER_OCCUPIED') ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.accentGreen.withValues(
                                alpha: 0.12,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppColors.accentGreen.withValues(
                                  alpha: 0.35,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.check_circle_outline,
                                  size: 15,
                                  color: AppColors.accentGreen,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Malik Oturuyor: Kat maliki bu dairede bizzat ikamet etmektedir. İşletme ve demirbaş aidatlarının doğrudan muhatabıdır. Ayrıca kiracı tanımlanamaz.',
                                    style: TextStyle(
                                      color: AppColors.successText(context),
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ] else if (occupancyStatus == 'TENANT_OCCUPIED') ...[
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.surface(context),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppColors.accentGreen.withValues(
                                  alpha: 0.25,
                                ),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.key,
                                      size: 15,
                                      color: AppColors.accentGreen,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Kiracı Bilgileri (Fiilen İkamet Eden Sakin)',
                                      style: TextStyle(
                                        color: AppColors.textPrimary(context),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Aylık işletme aidatları kiracıya, demirbaş aidatları kat malikine yansıtılır.',
                                  style: TextStyle(
                                    color: AppColors.textSecondary(context),
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                SpPersonField(
                                  repository: widget.personRepository,
                                  roleContext: 'tenant',
                                  value: tenantRef,
                                  onResolved: (person) => tenantPerson = person,
                                  onChanged: (value) =>
                                      setDlgState(() => tenantRef = value),
                                  id: 'module_new_tenant_name',
                                ),
                              ],
                            ),
                          ),
                        ] else if (occupancyStatus == 'VACANT') ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.accentOrange.withValues(
                                alpha: 0.1,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppColors.accentOrange.withValues(
                                  alpha: 0.3,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.info_outline,
                                  size: 15,
                                  color: AppColors.accentOrange,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Boş Daire: Dairede şu anda ikamet eden yoktur. Daire boş statüsünde kaydedilir ve tüm aidat borçları kat malikine yansıtılır.',
                                    style: TextStyle(
                                      color: AppColors.textPrimary(context),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Dynamic Household Co-Residents Section (Hane Sakinleri / Birlikte İkamet Eden Bireyler)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppColors.card(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.accentCyan.withValues(alpha: 0.3),
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
                              color: AppColors.accentCyan,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '4. Hane Sakinleri (Birlikte İkamet Eden Bireyler)',
                                style: TextStyle(
                                  color: AppColors.textPrimary(context),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            testId(
                              'module_add_co_resident_btn',
                              OutlinedButton.icon(
                                key: const Key('module_add_co_resident_btn'),
                                icon: const Icon(
                                  Icons.person_add_alt_1,
                                  size: 14,
                                  color: AppColors.accentCyan,
                                ),
                                label: Text(
                                  '+ Hane Sakini Ekle',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryText(context),
                                  ),
                                ),
                                onPressed: () {
                                  setDlgState(() {
                                    pendingResidents.add(
                                      _PendingResidentEntry(),
                                    );
                                  });
                                },
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  minimumSize: const Size(0, 28),
                                  side: const BorderSide(
                                    color: AppColors.accentCyan,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Dairede birlikte ikamet eden diğer aile bireylerini (eş, çocuk, anne/baba vb.) ekleyebilirsiniz.',
                          style: TextStyle(
                            color: AppColors.textSecondary(context),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (pendingResidents.isEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 12,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surface(context),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppColors.border(context)
                                    .withOpacity(0.5),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  size: 16,
                                  color: AppColors.textSecondary(context),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Henüz eklenen hane sakini yok. Birlikte ikamet eden birey eklemek için "+ Hane Sakini Ekle" butonuna tıklayınız.',
                                    style: TextStyle(
                                      color: AppColors.textSecondary(context),
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          ...pendingResidents.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final res = entry.value;
                            return Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppColors.surface(context),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: AppColors.accentCyan.withOpacity(0.35),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.accentCyan
                                              .withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: Text(
                                          'Hane Sakini #${idx + 1}',
                                          style: TextStyle(
                                            color: AppColors.primaryText(
                                              context,
                                            ),
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          size: 18,
                                          color: AppColors.accentRed,
                                        ),
                                        tooltip: 'Hane Sakinini Kaldır',
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () {
                                          setDlgState(() {
                                            pendingResidents.removeAt(idx);
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  SpPersonField(
                                    repository: widget.personRepository,
                                    roleContext: 'member',
                                    value: res.person,
                                    onResolved: (person) =>
                                        res.summary = person,
                                    onChanged: (value) =>
                                        setDlgState(() => res.person = value),
                                    id: 'module_new_member_person_$idx',
                                  ),
                                  const SizedBox(height: 8),
                                  DropdownButtonFormField<String>(
                                    value: HouseholdRelationship.fromValue(
                                      res.relationship,
                                    ).code,
                                    isDense: true,
                                    dropdownColor: AppColors.card(context),
                                    style: TextStyle(
                                      color: AppColors.textPrimary(context),
                                      fontSize: 12,
                                    ),
                                    decoration: InputDecoration(
                                      labelText: 'Yakınlık',
                                      labelStyle: TextStyle(
                                        color: AppColors.textSecondary(context),
                                        fontSize: 12,
                                      ),
                                      filled: true,
                                      isDense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 8,
                                          ),
                                      border: const OutlineInputBorder(),
                                    ),
                                    items: householdRelationshipItems(),
                                    onChanged: (val) {
                                      if (val != null)
                                        setDlgState(
                                          () => res.relationship = val,
                                        );
                                    },
                                  ),
                                ],
                              ),
                            );
                          }),
                      ],
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
}

class _PendingResidentEntry {
  PersonRef? person;
  PersonSummary? summary;
  String relationship = 'SPOUSE';
}
