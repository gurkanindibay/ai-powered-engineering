import 'responsible_contact_selection.dart';
import '../../testing/test_id.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import '../../domain/models/dues_models.dart';
import '../../domain/models/unit_state.dart';
import '../../domain/models/person_ref.dart';
import '../components/app_fullscreen_page.dart';
import '../components/step_up_prompt.dart';
import '../../domain/models/household_relationship.dart';
import 'household_relationship_items.dart';
import '../../domain/validation/person_validators.dart';
import '../../domain/logging/app_logger.dart';
import '../components/house_types_modal.dart';
import '../dashboard/dashboard_controller.dart';
import '../theme/app_theme.dart';
import '../design_system/sp_skeleton.dart';

import '../design_system/money_formatter.dart';
import '../design_system/sp_feedback.dart';
import '../components/sp_dialog_pages.dart';
import '../components/sp_effective_date_field.dart';
import '../payments/resident_statement_page.dart';
import 'resident_directory.dart';
import 'sp_directory_scaffold.dart';
import 'unit_directory_row.dart';
import 'people_directory_page.dart';
import 'person_profile_page.dart';
import '../../domain/services/person_directory_api.dart';
import '../../domain/services/person_directory_repository.dart';
import 'sp_person_field.dart';
import '../../domain/repositories/person_repository.dart';
import 'person_profile_page.dart';
import '../design_system/sp_filter_chip.dart';
import '../design_system/sp_semantics.dart';
import '../design_system/sp_tone.dart';
import '../design_system/sp_guidance_card.dart';
import 'advance_exit_settlement_fields.dart';

part 'owners_residents_unit_card.dart';
part 'owners_residents_unit_workspace.dart';
part 'owners_residents_registration.dart';
part 'owners_residents_edit.dart';
part 'owners_residents_occupancy.dart';
/// Standalone Fullscreen Module for Comprehensive Owners & Residents Management.
///
/// Mandated by SitePulse UX Guidelines:
/// High-density detailed operations (dual ledger / dual tab residents vs owners,
/// co-residents management, active responsible designation, occupancy timeline history,
/// move-in/move-out workflows) are decoupled into this dedicated module.
class OwnersResidentsModulePage extends StatefulWidget {
  final DashboardController controller;
  final String? initialUnitId;
  final String? initialBlockFilter;
  final String? initialOccupancyFilter;

  /// Which workspace tab [initialUnitId] opens on.
  final UnitWorkspaceMode initialMode;

  /// Opens the registration page on top of the directory once it is shown.
  final bool openAddResident;
  final PersonRepository personRepository;

  const OwnersResidentsModulePage({
    super.key,
    required this.controller,
    this.initialUnitId,
    this.initialBlockFilter,
    this.initialOccupancyFilter,
    this.initialMode = UnitWorkspaceMode.actions,
    this.openAddResident = false,
    this.personRepository = const PersonDirectoryRepository(),
  });

  @override
  State<OwnersResidentsModulePage> createState() => _OwnersResidentsModulePageState();
}

class _OwnersResidentsModulePageState extends State<OwnersResidentsModulePage> with RestorationMixin {
  final RestorableTextEditingController _searchController = RestorableTextEditingController();
  final RestorableString _blockFilterState = RestorableString(allBlocksFilter);
  final RestorableString _occupancyFilterState = RestorableString(OccupancyFilter.all);
  final RestorableString _sortModeState = RestorableString('unit');
  StateSetter? _unitActionsSetState;
  String get _searchQuery => _searchController.value.text.trim();
  String get _blockFilter => _blockFilterState.value;
  String get _occupancyFilter => _occupancyFilterState.value;
  String get _sortMode => _sortModeState.value;
  final Map<String, int> _unitTabs = {}; // 0: Sakinler, 1: Kat Maliki
  final Map<String, FocusNode> _actionFocusNodes = {};
  final Map<String, FocusNode> _detailFocusNodes = {};

  FocusNode _getActionFocusNode(String id) =>
      _actionFocusNodes.putIfAbsent(id, () => FocusNode(debugLabel: 'unit_action_$id'));

  FocusNode _getDetailFocusNode(String id) =>
      _detailFocusNodes.putIfAbsent(id, () => FocusNode(debugLabel: 'unit_detail_$id'));

  @override
  void initState() {
    super.initState();
    if (widget.openAddResident) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openAddResident(context);
      });
    } else if (widget.initialUnitId != null && widget.initialUnitId!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final matches = widget.controller.homeOwners.where((h) => h.unitId == widget.initialUnitId);
        if (matches.isNotEmpty) {
          _openUnitWorkspace(matches.first, mode: widget.initialMode);
        }
      });
    }
  }

  @override
  String? get restorationId => 'owners_residents_directory';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_searchController, 'query');
    registerForRestoration(_blockFilterState, 'blockFilter');
    registerForRestoration(_occupancyFilterState, 'occupancyFilter');
    registerForRestoration(_sortModeState, 'sortMode');
    if (initialRestore) {
      _blockFilterState.value = widget.initialBlockFilter ?? allBlocksFilter;
      _occupancyFilterState.value = widget.initialOccupancyFilter ?? OccupancyFilter.all;
    }
  }

  @override
  void dispose() {
    for (final fn in _actionFocusNodes.values) {
      fn.dispose();
    }
    _actionFocusNodes.clear();
    for (final fn in _detailFocusNodes.values) {
      fn.dispose();
    }
    _detailFocusNodes.clear();
    unregisterFromRestoration(_searchController);
    unregisterFromRestoration(_blockFilterState);
    unregisterFromRestoration(_occupancyFilterState);
    unregisterFromRestoration(_sortModeState);
    _searchController.dispose();
    _blockFilterState.dispose();
    _occupancyFilterState.dispose();
    _sortModeState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final homeOwners = widget.controller.homeOwners;
        final availableBlocks = distinctBlocks(widget.controller.blocks);

        final hasInitialUnitFocus = widget.initialUnitId != null &&
            widget.initialUnitId!.isNotEmpty &&
            _searchQuery.isEmpty &&
            _blockFilter == allBlocksFilter &&
            _occupancyFilter == OccupancyFilter.all;
        final filtered = homeOwners.where((ho) {
          if (hasInitialUnitFocus && ho.unitId == widget.initialUnitId) return true;
          return matchesResidentFilters(
            ho,
            blockFilter: _blockFilter,
            occupancyFilter: _occupancyFilter,
            query: _searchQuery,
          );
        }).toList();
        filtered.sort((a, b) => compareUnitDirectoryItems(a, b, descending: _sortMode == 'reverse'));

        final stats = ResidentOccupancyStats.from(homeOwners);
        final isPhone = MediaQuery.sizeOf(context).width < 720;

        return AppFullscreenPage(
          title: isPhone ? 'Kat Malikleri & Sakinler' : 'Kat Malikleri & Sakinler Modülü',
          subtitle: isPhone ? null : '${widget.controller.userSession.siteName} • Yönetim ve Operasyon Portalı',
          icon: const Icon(Icons.people_alt, color: AppColors.accentCyan),
          actions: [
            testId('module_people_directory_btn', OutlinedButton.icon(
              key: const Key('module_people_directory_btn'),
              onPressed: () => AppFullscreenPage.push<void>(
                context: context,
                builder: (_) => PeopleDirectoryPage(
                  onOpenUnit: _openUnitById,
                  onGiveRole: _giveRole,
                  onChanged: _refreshPeople,
                ),
              ),
              icon: const Icon(Icons.badge_outlined, size: 14),
              label: const Text('Kişiler', style: TextStyle(fontSize: 12)),
            )),
            const SizedBox(width: AppSpacing.sm),
            if (isPhone)
              IconButton(
                onPressed: () => showManageHouseTypesFullscreen(context, widget.controller),
                icon: const Icon(Icons.home_work_outlined, size: 18, color: AppColors.accentPurple),
                tooltip: 'Konut Tipleri & Tarifeler',
              )
            else
              OutlinedButton.icon(
                onPressed: () => showManageHouseTypesFullscreen(context, widget.controller),
                icon: const Icon(Icons.home_work_outlined, size: 14),
                label: const Text('Konut Tipleri & Tarifeler', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accentPurple,
                  side: const BorderSide(color: AppColors.accentPurple),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                ),
              ),
          ],
          bottomBar: AppFullscreenPage.buildBottomBar(
            context: context,
            children: [
              testId('module_bottom_close_btn', OutlinedButton.icon(
                key: const Key('module_bottom_close_btn'),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('Ana Panele Dön'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary(context),
                  side: BorderSide(color: AppColors.border(context)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              )),
              testId('module_add_new_resident_btn', ElevatedButton.icon(
                key: const Key('module_add_new_resident_btn'),
                onPressed: () => _openAddResident(context),
                icon: const Icon(Icons.person_add_alt_1, size: 18),
                label: const Text('Yeni Sakin Ekle'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryFill,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              )),
            ],
          ),
          maxWidth: 1280,
          isScrollable: false,
          child: SpDirectoryScaffold<HomeOwnerItem>(
            restorationId: 'unit_directory_paging',
            resultKey: '$_searchQuery|$_blockFilter|$_occupancyFilter|$_sortMode',
            items: filtered,
            resultLabel: 'daire',
            header: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ResidentSummary(stats: stats, dense: true),
                const SizedBox(height: 16),
                testId('module_search_input', TextField(
                  key: const Key('module_search_input'),
                  controller: _searchController.value,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Sakin, malik, hane sakini, daire no veya telefon ara...',
                    hintStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            tooltip: 'Aramayı temizle',
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.value.clear();
                              setState(() {});
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: AppColors.surface(context),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: AppColors.border(context)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: AppColors.border(context)),
                    ),
                  ),
                )),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    _buildOccupancyFilterChip('Tümü (${stats.totalUnits})', OccupancyFilter.all),
                    const SizedBox(width: AppSpacing.sm),
                    _buildOccupancyFilterChip('${AppStrings.tenantOccupied} (${stats.tenantCount})', OccupancyFilter.tenant),
                    const SizedBox(width: AppSpacing.sm),
                    _buildOccupancyFilterChip('${AppStrings.ownerOccupied} (${stats.ownerCount})', OccupancyFilter.owner),
                    const SizedBox(width: AppSpacing.sm),
                    _buildOccupancyFilterChip('${AppStrings.vacantUnit} (${stats.vacantCount})', OccupancyFilter.vacant),
                  ]),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    _buildBlockFilterChip('Tüm Bloklar', allBlocksFilter),
                    ...availableBlocks.map((block) => _buildBlockFilterChip('$block Blok', block)),
                  ]),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: testId('module_unit_sort', DropdownButton<String>(
                    key: const Key('module_unit_sort'),
                    value: _sortMode,
                    isDense: true,
                    items: const [
                      DropdownMenuItem(value: 'unit', child: Text('Blok ve daire no')),
                      DropdownMenuItem(value: 'reverse', child: Text('Blok ve daire no (ters)')),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _sortModeState.value = value);
                    },
                  )),
                ),
              ],
            ),
            emptyState: homeOwners.isEmpty
                ? SpGuidanceCard(
                    icon: Icons.home_work_outlined,
                    title: 'Henüz daire yok',
                    message: 'Site dizinini başlatmak için ilk daireyi ekleyin.',
                    prominent: true,
                    action: ElevatedButton.icon(
                      onPressed: () => _openAddResident(context),
                      icon: const Icon(Icons.add_home_work_outlined),
                      label: const Text('İlk daireyi ekle'),
                    ),
                  )
                : SpGuidanceCard(
                    icon: Icons.person_search_outlined,
                    title: 'Daire bulunamadı',
                    message: 'Arama veya filtreleri temizleyerek tekrar deneyin.',
                    action: testId('module_unit_directory_reset', TextButton(
                      key: const Key('module_unit_directory_reset'),
                      onPressed: () {
                        _searchController.value.clear();
                        _blockFilterState.value = allBlocksFilter;
                        _occupancyFilterState.value = OccupancyFilter.all;
                        setState(() {});
                      },
                      child: const Text('Filtreleri sıfırla'),
                    )),
                  ),
            itemBuilder: (context, unit, index) => UnitDirectoryRow(
              unit: unit,
              actionsFocusNode: _getActionFocusNode(unit.unitId),
              detailsFocusNode: _getDetailFocusNode(unit.unitId),
              onActions: () => _openUnitActions(unit),
              onDetails: () => _openUnitDetails(unit),
            ),
          ),
        );
      },
    );
  }

  Widget _buildOccupancyFilterChip(String label, String code) {
    return SpFilterChip(
      label: label,
      selected: _occupancyFilter == code,
      onSelected: () => setState(() => _occupancyFilterState.value = _occupancyFilter == code ? OccupancyFilter.all : code),
      id: 'module_occupancy_filter_$code',
    );
  }

  Widget _buildBlockFilterChip(String label, String code) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: SpFilterChip(
        label: label,
        selected: _blockFilter == code,
        onSelected: () => setState(() => _blockFilterState.value = _blockFilter == code ? allBlocksFilter : code),
        tone: SpTone.accent,
        id: 'module_block_filter_$code',
      ),
    );
  }

  Future<void> _openUnitActions(HomeOwnerItem unit) async {
    final focusNode = _getActionFocusNode(unit.unitId);
    await _openUnitWorkspace(
      unit,
      mode: UnitWorkspaceMode.actions,
      returnFocusNode: focusNode,
    );
  }

  Future<void> _openUnitDetails(HomeOwnerItem unit) async {
    final focusNode = _getDetailFocusNode(unit.unitId);
    await _openUnitWorkspace(
      unit,
      mode: UnitWorkspaceMode.information,
      returnFocusNode: focusNode,
    );
  }

  /// Rebuilds the list after a change made by one of the part files (they may not call
  /// the protected `setState` directly).
  void _update(VoidCallback change) {
    setState(change);
    _unitActionsSetState?.call(() {});
  }

  @visibleForTesting
  Widget buildUnitCard(HomeOwnerItem ho) => _buildUnitCard(ho);
}
