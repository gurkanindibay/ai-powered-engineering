part of 'owners_residents_module_page.dart';

/// Which of the two workspace modes is showing.
enum UnitWorkspaceMode { actions, information }

/// One row of the workspace action list.
class _WorkspaceAction {
  final String id;
  final String group;
  final String label;
  final String hint;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _WorkspaceAction({
    required this.id,
    required this.group,
    required this.label,
    required this.hint,
    required this.icon,
    required this.color,
    required this.onTap,
  });
}

/// The actions legal for [ho], in catalog order. Occupancy actions follow the unit's
/// allowed commands; the remaining rows depend on the people on record.
List<_WorkspaceAction> _workspaceActions(
  HomeOwnerItem ho, {
  required void Function(HomeOwnerItem ho) selectContact,
  required void Function(HomeOwnerItem ho) addMember,
  required void Function(HomeOwnerItem ho) editResidents,
  required void Function(HomeOwnerItem ho) editOwner,
  required void Function(HomeOwnerItem ho, OccupancyCommand command) moveIn,
  required void Function(HomeOwnerItem ho, OccupancyCommand command) ownerMoveIn,
  required void Function(HomeOwnerItem ho) moveOut,
  required void Function(HomeOwnerItem ho) transfer,
  required void Function(HomeOwnerItem ho) history,
  required void Function(HomeOwnerItem ho) iban,
  required void Function(HomeOwnerItem ho) delete,
}) {
  const people = 'Kişiler';
  const residence = 'İkamet';
  const ownership = 'Mülkiyet';
  const unit = 'Daire';
  const other = 'Diğer';
  final hasOwner = ho.ownerFullName.trim().isNotEmpty;
  final hasOccupant = ho.isTenantOccupied || ho.isOwnerOccupied;

  _WorkspaceAction row(
    String id,
    String group,
    String label,
    String hint,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) =>
      _WorkspaceAction(id: id, group: group, label: label, hint: hint, icon: icon, color: color, onTap: onTap);

  return [
    if (hasOwner || hasOccupant)
      row('select_contact', people, 'Sorumluyu Seç', 'Birincil muhatabı belirle', Icons.star_outline,
          AppColors.accentCyan, () => selectContact(ho)),
    if (hasOccupant)
      row('add_member', people, 'Hane Üyesi Ekle', 'Birlikte yaşayan kişiyi kaydet', Icons.family_restroom,
          AppColors.accentPurple, () => addMember(ho)),
    if (hasOccupant)
      row('edit_residents', people, 'Sakinleri Düzenle', 'Sakin bilgilerini güncelle', Icons.people_alt_outlined,
          AppColors.accentGreen, () => editResidents(ho)),
    if (hasOwner)
      row('edit_owner', people, 'Kat Maliki Bilgileri', 'Kat maliki bilgilerini güncelle', Icons.vpn_key_outlined,
          AppColors.accentCyan, () => editOwner(ho)),
    if (ho.allows(OccupancyCommand.tenantMoveIn))
      row('tenant_move_in', residence, OccupancyCommand.tenantMoveIn.label, 'Kiracıyı daireye yerleştir',
          Icons.key, AppColors.accentGreen, () => moveIn(ho, OccupancyCommand.tenantMoveIn)),
    if (ho.allows(OccupancyCommand.replaceTenant))
      row('replace_tenant', residence, OccupancyCommand.replaceTenant.label, 'Yeni kiracıyla devam et',
          Icons.swap_horiz, AppColors.accentGreen, () => moveIn(ho, OccupancyCommand.replaceTenant)),
    if (ho.allows(OccupancyCommand.ownerRentsOut))
      row('owner_rents_out', residence, OccupancyCommand.ownerRentsOut.label, 'Daireyi bir kiracıya ver',
          Icons.key, AppColors.accentGreen, () => moveIn(ho, OccupancyCommand.ownerRentsOut)),
    if (ho.allows(OccupancyCommand.ownerMoveIn))
      row('owner_move_in', residence, OccupancyCommand.ownerMoveIn.label, 'Kat maliki daireye taşınsın',
          Icons.home_outlined, AppColors.accentCyan, () => ownerMoveIn(ho, OccupancyCommand.ownerMoveIn)),
    if (ho.allows(OccupancyCommand.ownerTakesBack))
      row('owner_takes_back', residence, OccupancyCommand.ownerTakesBack.label, 'Kiracı çıkar, kat maliki taşınır',
          Icons.home_outlined, AppColors.accentCyan, () => ownerMoveIn(ho, OccupancyCommand.ownerTakesBack)),
    if (ho.allows(OccupancyCommand.moveOut))
      row('move_out', residence, OccupancyCommand.moveOut.label, 'Mevcut sakini daireden çıkar',
          Icons.logout, AppColors.accentOrange, () => moveOut(ho)),
    if (ho.allows(OccupancyCommand.titleTransfer))
      row('transfer_ownership', ownership, OccupancyCommand.titleTransfer.label, 'Mülkiyeti yeni kişiye devret',
          Icons.swap_calls, AppColors.accentPurple, () => transfer(ho)),
    row('history', unit, 'Daire Tarihçesi', 'Geçmiş ikamet ve mülkiyet kayıtları', Icons.history,
        AppColors.accentCyan, () => history(ho)),
    row('iban', unit, 'Sanal IBAN', 'Aidat ödemeleri için hesap bilgisi', Icons.account_balance,
        AppColors.accentPurple, () => iban(ho)),
    row('delete', other, AppStrings.delete, 'Daireyi sil', Icons.delete_outline, AppColors.accentRed,
        () => delete(ho)),
  ];
}

/// Opens the unit workspace for one unit.
extension _UnitWorkspace on _OwnersResidentsModulePageState {
  Future<void> _openUnitWorkspace(
    HomeOwnerItem ho, {
    UnitWorkspaceMode mode = UnitWorkspaceMode.actions,
    FocusNode? returnFocusNode,
  }) async {
    final prevUnitId = ho.unitId;
    await AppFullscreenPage.push<void>(
      context: context,
      builder: (_) => _UnitWorkspacePage(
        controller: widget.controller,
        unitId: ho.unitId,
        initialMode: mode,
        actionsFor: _workspaceActionsFor,
        onOpenPerson: _openPerson,
      ),
    );
    if (!mounted) return;
    _update(() {});
    final updatedMatches = widget.controller.homeOwners.where((h) => h.unitId == prevUnitId);
    if (updatedMatches.isNotEmpty) {
      final updated = updatedMatches.first;
      if (!matchesResidentFilters(
        updated,
        blockFilter: _blockFilter,
        occupancyFilter: _occupancyFilter,
        query: _searchQuery,
      )) {
        SpToast.info(
          context,
          '${updated.block} ${updated.unitNo} güncellendi ve mevcut filtrenin dışına çıktı.',
        );
      }
    }
    returnFocusNode?.requestFocus();
  }

  /// Person card -> unit: opens the workspace of [unitId] from the card's unit rows.
  Future<void> _openUnitById(String unitId) async {
    final matches = widget.controller.homeOwners.where((h) => h.unitId == unitId);
    if (matches.isEmpty) {
      if (mounted) SpToast.info(context, 'Daire bu listede bulunamadı.');
      return;
    }
    await _openUnitWorkspace(matches.first);
  }

  /// Unit -> person card. The card edits reload the unit list, so every open unit
  /// workspace shows the new name at once.
  Future<void> _openPerson(int personId) async {
    await AppFullscreenPage.push<void>(
      context: context,
      builder: (_) => PersonProfilePage(
        personId: personId,
        onOpenUnit: _openUnitById,
        onGiveRole: _giveRole,
        onChanged: _refreshPeople,
      ),
    );
  }

  Future<void> _refreshPeople(PersonSummary person) async {
    widget.controller.applyPersonUpdate(
      person.personId,
      fullName: person.fullName,
      phone: person.phone,
      email: person.email,
    );
    await widget.controller.fetchHomeOwners();
  }

  /// Person-first action: the person is fixed, the manager picks the unit, then the
  /// unit workspace offers the role actions legal for that unit.
  Future<void> _giveRole(PersonSummary person, String role) async {
    final units = widget.controller.homeOwners;
    final picked = await showSpSelection<HomeOwnerItem>(
      context: context,
      title: '${person.fullName} için daire seçin',
      options: units,
      labelOf: (h) => h.unitNo > 0 ? '${h.block} • Daire ${h.unitNo}' : '${h.block} • Daire Atanmadı',
      idOf: (h) => 'person_role_unit_${h.unitId}',
    );
    if (picked == null || !mounted) return;
    SpToast.info(context, '${person.fullName}: daire işlemlerinden ${_roleHint(role)} seçin.');
    await _openUnitWorkspace(picked);
  }

  String _roleHint(String role) => switch (role) {
        'TENANT' => '"Kiracı yerleştir"i',
        'OWNER' => '"Mülkiyet devri"ni',
        _ => '"Hane üyesi ekle"yi',
      };

  List<_WorkspaceAction> _workspaceActionsFor(HomeOwnerItem ho) => _workspaceActions(
        ho,
        selectContact: _showSelectPrimaryResponsibleDialog,
        addMember: _openAddHouseholdMember,
        editResidents: (unit) => _openEditHomeOwner(unit, initialTab: 0),
        editOwner: (unit) => _openEditHomeOwner(unit, initialTab: 1),
        moveIn: (unit, command) => _openMoveIn(unit, command: command),
        ownerMoveIn: (unit, command) => _openOwnerMoveIn(unit, command: command),
        moveOut: _openMoveOut,
        transfer: _openTransferOwnership,
        history: _openUnitHistory,
        iban: _openIbanDetails,
        delete: _openDeleteUnit,
      );
}

/// Actions and information for one unit. Reads the unit from the controller so it follows
/// changes made by the action pages it opens.
class _UnitWorkspacePage extends StatefulWidget {
  final DashboardController controller;
  final String unitId;
  final UnitWorkspaceMode initialMode;
  final List<_WorkspaceAction> Function(HomeOwnerItem ho) actionsFor;
  final Future<void> Function(int personId) onOpenPerson;

  const _UnitWorkspacePage({
    required this.controller,
    required this.unitId,
    required this.initialMode,
    required this.actionsFor,
    required this.onOpenPerson,
  });

  @override
  State<_UnitWorkspacePage> createState() => _UnitWorkspacePageState();
}

class _UnitWorkspacePageState extends State<_UnitWorkspacePage> {
  late UnitWorkspaceMode _mode = widget.initialMode;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final matches = widget.controller.homeOwners.where((h) => h.unitId == widget.unitId);
        if (matches.isEmpty) {
          return AppFullscreenPage(
            title: 'Daire',
            maxWidth: 720,
            bottomBar: _returnBar(context),
            child: testId('workspace_unit_missing', const Text('Daire bulunamadı.', key: Key('workspace_unit_missing'))),
          );
        }
        final ho = matches.first;
        return AppFullscreenPage(
          title: ho.unitNo > 0 ? '${ho.block} • Daire ${ho.unitNo}' : '${ho.block} • Daire Atanmadı',
          subtitle: 'Kat ${ho.floor} • Arsa Payı: ${ho.landShare}',
          icon: const Icon(Icons.door_front_door_outlined, color: AppColors.accentCyan),
          maxWidth: 720,
          bottomBar: _returnBar(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _identity(context, ho),
              const SizedBox(height: 12),
              _modeSwitch(context, ho.unitId),
              const SizedBox(height: 12),
              if (_mode == UnitWorkspaceMode.actions) _actionList(context, ho) else _information(context, ho),
              // Reserved so the return bar never covers the last row, even at large text.
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Widget _returnBar(BuildContext context) => AppFullscreenPage.buildBottomBar(
        context: context,
        children: [
          testId(
            'workspace_return_btn',
            OutlinedButton(
              key: const Key('workspace_return_btn'),
              onPressed: () => Navigator.of(context).maybePop(),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              child: const Text('Listeye Dön'),
            ),
          ),
        ],
      );

  int _cardTab = 0;

  Widget _identity(BuildContext context, HomeOwnerItem ho) {
    final occupant = ho.isTenantOccupied ? (ho.tenantFullName ?? '') : (ho.isOwnerOccupied ? ho.ownerFullName : '');
    Widget line(String label, String value, {String slot = '', int? personId}) => Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: Text(label, style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
              ),
              Expanded(
                child: _personLink(context, value.isEmpty ? '—' : value, value.isEmpty ? null : personId,
                    TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.bold), slot),
              ),
            ],
          ),
        );
    return testId('workspace_identity', Container(
      key: const Key('workspace_identity'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line('Sakin', occupant, slot: 'occupant', personId: ho.isTenantOccupied ? ho.tenantPersonId : ho.ownerPersonId),
          line('Kat Maliki', ho.ownerFullName, slot: 'owner', personId: ho.ownerPersonId),
          line('Muhatap', ho.activeResponsibleResidentName),
          const SizedBox(height: 8),
          _dualTabSwitcher(context, ho),
        ],
      ),
    ));
  }

  /// A person's name; a link to the person card when the server gave a card id.
  Widget _personLink(BuildContext context, String name, int? personId, TextStyle style, String slot) {
    if (personId == null) return Text(name, style: style);
    return testId(
      'workspace_person_${slot}_$personId',
      InkWell(
        key: Key('workspace_person_${slot}_$personId'),
        onTap: () => widget.onOpenPerson(personId),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            name,
            style: style.copyWith(decoration: TextDecoration.underline, color: AppColors.accentCyan),
          ),
        ),
      ),
      label: '$name kişi kartını aç',
    );
  }

  Widget _dualTabSwitcher(BuildContext context, HomeOwnerItem ho) {
    final editResidentsAction = widget.actionsFor(ho).where((a) => a.id == 'edit_residents');
    final editOwnerAction = widget.actionsFor(ho).where((a) => a.id == 'edit_owner');

    return Container(
      decoration: BoxDecoration(
        color: AppColors.background(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border(context).withOpacity(0.6)),
      ),
      padding: const EdgeInsets.all(3),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: selectableSemantics(
                  selected: _cardTab == 0,
                  child: testId(
                    'module_tab_residents_${ho.unitId}',
                    InkWell(
                      key: Key('module_tab_residents_${ho.unitId}'),
                      onTap: () => setState(() => _cardTab = 0),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                        decoration: BoxDecoration(
                          color: _cardTab == 0 ? AppColors.card(context) : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: _cardTab == 0 ? Border.all(color: AppColors.accentGreen.withOpacity(0.5)) : null,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.people_alt_outlined, size: 14, color: _cardTab == 0 ? AppColors.accentGreen : AppColors.textSecondary(context)),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                ho.isTenantOccupied
                                    ? 'Sakinler (${ho.tenantFullName ?? 'Kiracı'})'
                                    : (ho.isVacant ? 'Sakinler (Boş)' : 'Sakinler (${ho.ownerFullName})'),
                                style: TextStyle(
                                  color: _cardTab == 0 ? AppColors.successText(context) : AppColors.textSecondary(context),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: selectableSemantics(
                  selected: _cardTab == 1,
                  child: testId(
                    'module_tab_owner_${ho.unitId}',
                    InkWell(
                      key: Key('module_tab_owner_${ho.unitId}'),
                      onTap: () => setState(() => _cardTab = 1),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                        decoration: BoxDecoration(
                          color: _cardTab == 1 ? AppColors.card(context) : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: _cardTab == 1 ? Border.all(color: AppColors.accentCyan.withOpacity(0.5)) : null,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.vpn_key_outlined, size: 14, color: _cardTab == 1 ? AppColors.accentCyan : AppColors.textSecondary(context)),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Kat Maliki (${ho.ownerFullName.isNotEmpty ? ho.ownerFullName : 'Ev Sahibi'})',
                                style: TextStyle(
                                  color: _cardTab == 1 ? AppColors.primaryText(context) : AppColors.textSecondary(context),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_cardTab == 0) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ho.isTenantOccupied
                            ? 'Birincil Kiracı'
                            : (ho.isVacant ? 'Boş Daire' : 'Malik Mukim'),
                        style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        ho.isTenantOccupied
                            ? (ho.tenantFullName ?? 'Kiracı')
                            : ho.ownerFullName,
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (editResidentsAction.isNotEmpty)
                  testId(
                    'module_edit_residents_${ho.unitId}',
                    OutlinedButton.icon(
                      key: Key('module_edit_residents_${ho.unitId}'),
                      onPressed: editResidentsAction.first.onTap,
                      icon: const Icon(Icons.edit_outlined, size: 11),
                      label: const Text('Düzenle', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentGreen,
                        side: const BorderSide(color: AppColors.accentGreen),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        minimumSize: const Size(0, 24),
                      ),
                    ),
                  ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Kat Maliki (Mülk Sahibi)',
                        style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        ho.ownerFullName.isNotEmpty ? ho.ownerFullName : 'Bilinmeyen Malik',
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (editOwnerAction.isNotEmpty)
                  testId(
                    'module_edit_owner_${ho.unitId}',
                    OutlinedButton.icon(
                      key: Key('module_edit_owner_${ho.unitId}'),
                      onPressed: editOwnerAction.first.onTap,
                      icon: const Icon(Icons.edit_outlined, size: 11),
                      label: const Text('Düzenle', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentCyan,
                        side: const BorderSide(color: AppColors.accentCyan),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        minimumSize: const Size(0, 24),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _modeSwitch(BuildContext context, String unitId) {
    Widget tab(UnitWorkspaceMode mode, String id, String label) {
      final selected = _mode == mode;
      return Expanded(
        child: selectableSemantics(
          selected: selected,
          child: testId(
            id,
            InkWell(
              key: Key(id),
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _mode = mode),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? AppColors.card(context) : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: selected ? Border.all(color: AppColors.accentCyan.withOpacity(0.5)) : null,
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: selected ? AppColors.primaryText(context) : AppColors.textSecondary(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.background(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context).withOpacity(0.6)),
      ),
      child: Row(
        children: [
          tab(UnitWorkspaceMode.actions, 'workspace_mode_actions_$unitId', 'İşlemler'),
          tab(UnitWorkspaceMode.information, 'workspace_mode_info_$unitId', 'Daire Bilgileri'),
        ],
      ),
    );
  }

  Widget _actionList(BuildContext context, HomeOwnerItem ho) {
    final actions = widget.actionsFor(ho);
    final groups = <String>[];
    for (final a in actions) {
      if (!groups.contains(a.group)) groups.add(a.group);
    }
    return testId('workspace_actions', Column(
      key: const Key('workspace_actions'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final group in groups) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text(
              group,
              style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
          for (final a in actions.where((x) => x.group == group)) _actionRow(context, ho, a),
        ],
      ],
    ));
  }

  static String? _legacyKeyFor(String actionId, String unitId) {
    switch (actionId) {
      case 'select_contact':
        return 'module_set_responsible_$unitId';
      case 'add_member':
        return 'module_add_resident_to_$unitId';
      case 'tenant_move_in':
        return 'module_move_in_$unitId';
      case 'replace_tenant':
        return 'module_quick_move_in_$unitId';
      case 'owner_move_in':
        return 'module_owner_move_in_$unitId';
      case 'owner_rents_out':
        return 'module_add_tenant_$unitId';
      case 'owner_takes_back':
        return 'module_owner_takes_back_$unitId';
      case 'move_out':
        return 'module_move_out_$unitId';
      case 'transfer_ownership':
        return 'module_transfer_ownership_$unitId';
      case 'history':
        return 'module_history_ho_$unitId';
      case 'iban':
        return 'module_iban_ho_$unitId';
      case 'delete':
        return 'module_delete_ho_$unitId';
      default:
        return null;
    }
  }

  Widget _actionRow(BuildContext context, HomeOwnerItem ho, _WorkspaceAction a) {
    final id = 'workspace_action_${a.id}_${ho.unitId}';
    final legacyKey = _legacyKeyFor(a.id, ho.unitId);
    final rowWidget = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: testId(
        id,
        InkWell(
          key: Key(id),
          borderRadius: BorderRadius.circular(12),
          onTap: a.onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 72),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: a.color.withOpacity(0.4)),
            ),
            child: Row(
              children: [
                Icon(a.icon, size: 22, color: a.color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        a.label,
                        style: TextStyle(color: AppColors.textPrimary(context), fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(a.hint, style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: AppColors.textSecondary(context)),
              ],
            ),
          ),
        ),
      ),
    );

    if (legacyKey != null) {
      return KeyedSubtree(
        key: Key(legacyKey),
        child: rowWidget,
      );
    }
    return rowWidget;
  }

  Widget _information(BuildContext context, HomeOwnerItem ho) {
    Widget section(String title, List<Widget> children) => Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              ...children,
            ],
          ),
        );
    Widget row(String label, String value, {String slot = '', int? personId}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(child: Text(label, style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12))),
              _personLink(context, value, personId,
                  TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.bold), slot),
            ],
          ),
        );
    Widget empty(String text) =>
        Text(text, style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12));
    final tenant = ho.tenantFullName ?? '';
    return testId('workspace_information', Column(
      key: const Key('workspace_information'),
      children: [
        section('Genel Bakış', [
          row('Aylık Aidat', formatTry(ho.monthlyDues)),
          if (ho.houseType != null && ho.houseType!.isNotEmpty) row('Daire Tipi', ho.houseType!),
        ]),
        // Operating and capital ledgers stay separate.
        section('Cari Hesaplar', [
          row('İşletme Aidat Bakiyesi', formatTry(ho.operationalDuesBalance)),
          row('Demirbaş Bakiyesi', formatTry(ho.capitalDuesBalance)),
          row('Avans Bakiyesi', formatTry(ho.advanceBalance)),
        ]),
        section('Sakinler', [
          if (tenant.isNotEmpty) row('Kiracı', tenant, slot: 'info_tenant', personId: ho.tenantPersonId),
          if (ho.isOwnerOccupied) row('Kat Maliki İkameti', ho.ownerFullName, slot: 'info_owner_occupant', personId: ho.ownerPersonId),
          for (final m in ho.householdResidents) row('Hane Üyesi', m.fullName, slot: 'info_member', personId: m.personId),
          if (tenant.isEmpty && !ho.isOwnerOccupied && ho.householdResidents.isEmpty) empty('Kayıtlı sakin yok.'),
        ]),
        section('Kat Malikleri', [
          if (ho.ownerFullName.trim().isNotEmpty) row('Kat Maliki', ho.ownerFullName, slot: 'info_owner', personId: ho.ownerPersonId) else empty('Kayıtlı kat maliki yok.'),
        ]),
      ],
    ));
  }
}
