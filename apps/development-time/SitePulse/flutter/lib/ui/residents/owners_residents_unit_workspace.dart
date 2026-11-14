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
  void _openUnitWorkspace(HomeOwnerItem ho, {UnitWorkspaceMode mode = UnitWorkspaceMode.actions}) {
    AppFullscreenPage.push<void>(
      context: context,
      builder: (_) => _UnitWorkspacePage(
        controller: widget.controller,
        unitId: ho.unitId,
        initialMode: mode,
        actionsFor: _workspaceActionsFor,
      ),
    );
  }

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

  const _UnitWorkspacePage({
    required this.controller,
    required this.unitId,
    required this.initialMode,
    required this.actionsFor,
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

  Widget _identity(BuildContext context, HomeOwnerItem ho) {
    final occupant = ho.isTenantOccupied ? (ho.tenantFullName ?? '') : (ho.isOwnerOccupied ? ho.ownerFullName : '');
    Widget line(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: Text(label, style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
              ),
              Expanded(
                child: Text(
                  value.isEmpty ? '—' : value,
                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.bold),
                ),
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
          line('Sakin', occupant),
          line('Kat Maliki', ho.ownerFullName),
          line('Muhatap', ho.activeResponsibleResidentName),
        ],
      ),
    ));
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

  Widget _actionRow(BuildContext context, HomeOwnerItem ho, _WorkspaceAction a) {
    final id = 'workspace_action_${a.id}_${ho.unitId}';
    return Padding(
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
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(child: Text(label, style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12))),
              Text(
                value,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.bold),
              ),
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
          if (tenant.isNotEmpty) row('Kiracı', tenant),
          if (ho.isOwnerOccupied) row('Kat Maliki İkameti', ho.ownerFullName),
          for (final m in ho.householdResidents) row('Hane Üyesi', m.fullName),
          if (tenant.isEmpty && !ho.isOwnerOccupied && ho.householdResidents.isEmpty) empty('Kayıtlı sakin yok.'),
        ]),
        section('Kat Malikleri', [
          if (ho.ownerFullName.trim().isNotEmpty) row('Kat Maliki', ho.ownerFullName) else empty('Kayıtlı kat maliki yok.'),
        ]),
      ],
    ));
  }
}
