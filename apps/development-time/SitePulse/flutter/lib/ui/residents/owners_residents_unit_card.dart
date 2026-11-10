part of 'owners_residents_module_page.dart';

/// One unit's card: owner, tenant, household, balances and actions.
extension _UnitCard on _OwnersResidentsModulePageState {
  Widget _buildUnitCard(HomeOwnerItem ho) {
    final cleanBlock = ho.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();
    final badgeLabel = ho.unitNo > 0
        ? (cleanBlock.isNotEmpty ? '$cleanBlock${ho.unitNo}' : '${ho.unitNo}')
        : (cleanBlock.isNotEmpty ? cleanBlock : 'KS');

    final isTenant = ho.isTenantOccupied;
    final isVacant = ho.isVacant;

    final statusLabel = isTenant
        ? 'Kiracılı Daire'
        : (isVacant ? 'Boş Daire' : 'Kat Maliki İkameti');

    final statusColor = isTenant
        ? AppColors.accentGreen
        : (isVacant ? AppColors.accentOrange : AppColors.accentCyan);

    final cardTab = _unitTabs[ho.unitId] ?? 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. UNIT HEADER
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.card(context),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              border: Border(bottom: BorderSide(color: AppColors.border(context).withOpacity(0.6))),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: statusColor.withOpacity(0.3)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.door_front_door_outlined, size: 14, color: statusColor),
                      const SizedBox(height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2.0),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            badgeLabel,
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              ho.unitNo > 0 ? '${ho.block} • Daire ${ho.unitNo}' : '${ho.block} • Daire Atanmadı',
                              style: TextStyle(
                                color: AppColors.textPrimary(context),
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusColor.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              statusLabel,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Kat ${ho.floor}${ho.houseType != null && ho.houseType!.isNotEmpty ? ' • ${ho.houseType}' : ''} • Arsa Payı: ${ho.landShare}',
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                // Monthly Dues
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatTry(ho.monthlyDues),
                      style: TextStyle(
                        color: AppColors.textPrimary(context),
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Aylık Aidat',
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                    ),
                    if (ho.capitalDuesBalance > Decimal.zero) ...[
                      const SizedBox(height: 1),
                      Text(
                        formatTry(ho.capitalDuesBalance),
                        style: TextStyle(
                          color: AppColors.warningText(context),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Demirbaş',
                        style: TextStyle(color: AppColors.warningText(context), fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 2. ACTIVE RESPONSIBLE RESIDENT SPOTLIGHT (BİRİNCİL MUHATAP)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.accentCyan.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.accentCyan.withOpacity(0.35)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.star, size: 15, color: AppColors.accentCyan),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              ho.activeResponsibleRoleLabel,
                              style: TextStyle(
                                color: AppColors.primaryText(context),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          testId('module_set_responsible_${ho.unitId}', TextButton.icon(
                            key: Key('module_set_responsible_${ho.unitId}'),
                            onPressed: () => _showSelectPrimaryResponsibleDialog(ho),
                            icon: const Icon(Icons.swap_horiz, size: 14, color: AppColors.accentCyan),
                            label: Text('Sorumluyu Seç', style: TextStyle(fontSize: 12, color: AppColors.primaryText(context), fontWeight: FontWeight.bold)),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              minimumSize: const Size(0, 24),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          )),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        ho.activeResponsibleResidentName,
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.phone_outlined, size: 12, color: AppColors.textSecondary(context)),
                              const SizedBox(width: 4),
                              Text(
                                ho.activeResponsiblePhone.isNotEmpty ? ho.activeResponsiblePhone : 'Telefon Yok',
                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                              ),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.email_outlined, size: 12, color: AppColors.textSecondary(context)),
                              const SizedBox(width: 4),
                              Text(
                                ho.activeResponsibleEmail.isNotEmpty ? ho.activeResponsibleEmail : 'E-posta Yok',
                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // 3. DUAL TAB SWITCHER (Sakinler vs Kat Maliki)
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.background(context),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border(context).withOpacity(0.6)),
                  ),
                  padding: const EdgeInsets.all(3),
                  child: Row(
                    children: [
                      Expanded(
                        child: testId('module_tab_residents_${ho.unitId}', InkWell(
                          key: Key('module_tab_residents_${ho.unitId}'),
                          onTap: () => _update(() => _unitTabs[ho.unitId] = 0),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                            decoration: BoxDecoration(
                              color: cardTab == 0 ? AppColors.card(context) : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              border: cardTab == 0 ? Border.all(color: AppColors.accentGreen.withOpacity(0.5)) : null,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.people_alt_outlined, size: 14, color: cardTab == 0 ? AppColors.accentGreen : AppColors.textSecondary(context)),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    isTenant ? 'Sakinler (${ho.tenantFullName ?? 'Kiracı'})' : (isVacant ? 'Sakinler (Boş)' : 'Sakinler (${ho.ownerFullName})'),
                                    style: TextStyle(
                                      color: cardTab == 0 ? AppColors.successText(context) : AppColors.textSecondary(context),
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: testId('module_tab_owner_${ho.unitId}', InkWell(
                          key: Key('module_tab_owner_${ho.unitId}'),
                          onTap: () => _update(() => _unitTabs[ho.unitId] = 1),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                            decoration: BoxDecoration(
                              color: cardTab == 1 ? AppColors.card(context) : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              border: cardTab == 1 ? Border.all(color: AppColors.accentCyan.withOpacity(0.5)) : null,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.vpn_key_outlined, size: 14, color: cardTab == 1 ? AppColors.accentCyan : AppColors.textSecondary(context)),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    'Kat Maliki (${ho.ownerFullName.isNotEmpty ? ho.ownerFullName : 'Ev Sahibi'})',
                                    style: TextStyle(
                                      color: cardTab == 1 ? AppColors.primaryText(context) : AppColors.textSecondary(context),
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // 4. TAB CONTENTS
                if (cardTab == 0) ...[
                  // Sakinler Tab
                  if (isTenant) ...[
                    // Primary Tenant
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.card(context),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.accentGreen.withOpacity(0.35)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.key, size: 14, color: AppColors.accentGreen),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Birincil Kiracı',
                                  style: TextStyle(color: AppColors.successText(context), fontSize: 12, fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              testId('module_edit_residents_${ho.unitId}', OutlinedButton.icon(
                                key: Key('module_edit_residents_${ho.unitId}'),
                                onPressed: () => _openEditHomeOwner(ho, initialTab: 0),
                                icon: const Icon(Icons.edit_outlined, size: 11),
                                label: const Text('Düzenle', style: TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.accentGreen,
                                  side: const BorderSide(color: AppColors.accentGreen),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  minimumSize: const Size(0, 24),
                                ),
                              )),
                              const SizedBox(width: 4),
                              testId('module_move_out_${ho.unitId}', OutlinedButton.icon(
                                key: Key('module_move_out_${ho.unitId}'),
                                onPressed: () => _openMoveOut(ho),
                                icon: const Icon(Icons.logout, size: 11),
                                label: const Text('Tahliye', style: TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.accentOrange,
                                  side: const BorderSide(color: AppColors.accentOrange),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  minimumSize: const Size(0, 24),
                                ),
                              )),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            ho.tenantFullName ?? 'Kiracı',
                            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${ho.tenantPhone ?? ho.phone} • ${ho.tenantEmail ?? ho.email}',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ] else if (isVacant) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.accentOrange.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.accentOrange.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, color: AppColors.accentOrange, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Bu daire şu anda boştur. Yeni sakin veya kiracı girişi yapabilirsiniz.',
                              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                            ),
                          ),
                          testId('module_move_in_${ho.unitId}', ElevatedButton.icon(
                            key: Key('module_move_in_${ho.unitId}'),
                            onPressed: () => _openMoveIn(ho),
                            icon: const Icon(Icons.person_add_alt, size: 12),
                            label: const Text('Yeni Kiracı / Sakin Girişi', style: TextStyle(fontSize: 12)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.successFill,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              minimumSize: const Size(0, 28),
                            ),
                          )),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ] else ...[
                    // Kat Maliki (Mukim - Fiilen İkamet Eden Kat Maliki)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.card(context),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.accentCyan.withOpacity(0.35)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.home, size: 14, color: AppColors.accentCyan),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Fiilen İkamet Eden Kat Maliki (Birincil Muhatap)',
                                  style: TextStyle(color: AppColors.primaryText(context), fontSize: 12, fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              testId('module_edit_owner_res_${ho.unitId}', OutlinedButton.icon(
                                key: Key('module_edit_owner_res_${ho.unitId}'),
                                onPressed: () => _openEditHomeOwner(ho, initialTab: 0),
                                icon: const Icon(Icons.edit_outlined, size: 11),
                                label: const Text('Düzenle', style: TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.accentCyan,
                                  side: const BorderSide(color: AppColors.accentCyan),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  minimumSize: const Size(0, 24),
                                ),
                              )),
                              const SizedBox(width: 4),
                              testId('module_add_tenant_${ho.unitId}', OutlinedButton.icon(
                                key: Key('module_add_tenant_${ho.unitId}'),
                                onPressed: () => _openMoveIn(ho),
                                icon: const Icon(Icons.person_add_alt, size: 11),
                                label: const Text('Kiracı Girişi', style: TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.accentGreen,
                                  side: const BorderSide(color: AppColors.accentGreen),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  minimumSize: const Size(0, 24),
                                ),
                              )),
                              const SizedBox(width: 4),
                              testId('module_move_out_owner_${ho.unitId}', OutlinedButton.icon(
                                key: Key('module_move_out_owner_${ho.unitId}'),
                                onPressed: () => _openMoveOut(ho),
                                icon: const Icon(Icons.logout, size: 11),
                                label: const Text('Tahliye', style: TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.accentOrange,
                                  side: const BorderSide(color: AppColors.accentOrange),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  minimumSize: const Size(0, 24),
                                ),
                              )),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            ho.ownerFullName.isNotEmpty ? ho.ownerFullName : 'Kat Maliki',
                            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${ho.phone.isNotEmpty ? ho.phone : 'Telefon Yok'} • ${ho.email.isNotEmpty ? ho.email : 'E-posta Yok'}',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Household Co-Residents
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.background(context),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border(context).withOpacity(0.6)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.family_restroom, size: 14, color: AppColors.accentPurple),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Hane Sakinleri / Birlikte Yaşayanlar (${ho.householdResidents.length})',
                                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            testId('module_add_resident_to_${ho.unitId}', TextButton.icon(
                              key: Key('module_add_resident_to_${ho.unitId}'),
                              onPressed: () => _openAddHouseholdMember(ho),
                              icon: const Icon(Icons.add, size: 14, color: AppColors.accentPurple),
                              label: const Text('+ Hane Sakini', style: TextStyle(color: AppColors.accentPurple, fontSize: 12, fontWeight: FontWeight.bold)),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                minimumSize: const Size(0, 24),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            )),
                          ],
                        ),
                        if (ho.householdResidents.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          ...ho.householdResidents.map((m) => Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: const BoxDecoration(
                                        color: AppColors.accentPurple,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '${m.fullName} • ${m.relationship}${m.phone.isNotEmpty ? ' • ${m.phone}' : ''}',
                                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    testId('module_edit_member_${m.id.isNotEmpty ? m.id : m.fullName}', IconButton(
                                      key: Key('module_edit_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                      icon: const Icon(Icons.edit_outlined, size: 14, color: AppColors.accentCyan),
                                      tooltip: '${m.fullName} düzenle',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => _openEditHouseholdMember(ho, m),
                                    )),
                                    const SizedBox(width: 6),
                                    testId('module_delete_member_${m.id.isNotEmpty ? m.id : m.fullName}', IconButton(
                                      key: Key('module_delete_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                      icon: const Icon(Icons.close, size: 14, color: AppColors.accentRed),
                                      tooltip: '${m.fullName} sil',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => _confirmDeleteHouseholdMember(ho, m),
                                    )),
                                  ],
                                ),
                              )),
                        ] else ...[
                          const SizedBox(height: 4),
                          Text(
                            'Henüz kayıtlı ek hane sakini bulunmuyor.',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontStyle: FontStyle.italic),
                          ),
                        ],
                      ],
                    ),
                  ),
                ] else ...[
                  // Kat Maliki Tab
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.card(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.accentCyan.withOpacity(0.35)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.vpn_key_outlined, size: 14, color: AppColors.accentCyan),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Kat Maliki (Mülk Sahibi)',
                                style: TextStyle(color: AppColors.primaryText(context), fontSize: 12, fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            testId('module_edit_owner_${ho.unitId}', OutlinedButton.icon(
                              key: Key('module_edit_owner_${ho.unitId}'),
                              onPressed: () => _openEditHomeOwner(ho, initialTab: 1),
                              icon: const Icon(Icons.edit_outlined, size: 11),
                              label: const Text('Düzenle', style: TextStyle(fontSize: 12)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.accentCyan,
                                side: const BorderSide(color: AppColors.accentCyan),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                minimumSize: const Size(0, 24),
                              ),
                            )),
                            const SizedBox(width: 4),
                            testId('module_transfer_ownership_${ho.unitId}', OutlinedButton.icon(
                              key: Key('module_transfer_ownership_${ho.unitId}'),
                              onPressed: () => _openTransferOwnership(ho),
                              icon: const Icon(Icons.real_estate_agent, size: 11),
                              label: const Text('Mülk Devri (Satış)', style: TextStyle(fontSize: 12)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.accentGreen,
                                side: const BorderSide(color: AppColors.accentGreen),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                minimumSize: const Size(0, 24),
                              ),
                            )),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          ho.ownerFullName.isNotEmpty ? ho.ownerFullName : 'Bilinmeyen Malik',
                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${ho.phone.isNotEmpty ? ho.phone : 'Telefon Yok'} • ${ho.email.isNotEmpty ? ho.email : 'E-posta Yok'}',
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Arsa Payı Oranı: ${ho.landShare}',
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 12),

                // 5. UNIT QUICK ACTIONS ROW
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    testId('module_quick_add_resident_${ho.unitId}', OutlinedButton.icon(
                      key: Key('module_quick_add_resident_${ho.unitId}'),
                      onPressed: () => _openAddHouseholdMember(ho),
                      icon: const Icon(Icons.family_restroom, size: 13, color: AppColors.accentPurple),
                      label: const Text('+ Hane Sakini Ekle', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentPurple,
                        side: const BorderSide(color: AppColors.accentPurple),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: const Size(0, 30),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    )),
                    testId('module_quick_move_in_${ho.unitId}', OutlinedButton.icon(
                      key: Key('module_quick_move_in_${ho.unitId}'),
                      onPressed: () => _openMoveIn(ho),
                      icon: const Icon(Icons.key, size: 13, color: AppColors.accentGreen),
                      label: Text(
                        ho.isVacant
                            ? 'Yeni Kiracı / Sakin Girişi'
                            : ho.isTenantOccupied
                                ? 'Yeni Kiracı Girişi (Move-In)'
                                : 'Kiracı Tanımla (Move-In)',
                        style: const TextStyle(fontSize: 12),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentGreen,
                        side: const BorderSide(color: AppColors.accentGreen),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: const Size(0, 30),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    )),
                    testId('module_history_ho_${ho.unitId}', OutlinedButton.icon(
                      key: Key('module_history_ho_${ho.unitId}'),
                      onPressed: () => _openUnitHistory(ho),
                      icon: const Icon(Icons.history, size: 13, color: AppColors.accentCyan),
                      label: const Text('Daire Tarihçesi', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentCyan,
                        side: const BorderSide(color: AppColors.accentCyan),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: const Size(0, 30),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    )),
                    testId('module_iban_ho_${ho.unitId}', OutlinedButton.icon(
                      key: Key('module_iban_ho_${ho.unitId}'),
                      onPressed: () => _openIbanDetails(ho),
                      icon: const Icon(Icons.account_balance, size: 13, color: AppColors.accentPurple),
                      label: const Text('Sanal IBAN', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentPurple,
                        side: const BorderSide(color: AppColors.accentPurple),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: const Size(0, 30),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    )),
                    testId('module_delete_ho_${ho.unitId}', OutlinedButton.icon(
                      key: Key('module_delete_ho_${ho.unitId}'),
                      onPressed: () => _openDeleteUnit(ho),
                      icon: const Icon(Icons.delete_outline, size: 13, color: AppColors.accentRed),
                      label: const Text(AppStrings.delete, style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentRed,
                        side: const BorderSide(color: AppColors.accentRed),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: const Size(0, 30),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    )),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // DIALOG WORKFLOWS & ACTIONS
}
