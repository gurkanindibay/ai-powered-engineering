import '../../testing/test_id.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import '../../domain/models/dues_models.dart';
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
import 'resident_directory.dart';
import '../design_system/sp_filter_chip.dart';
import '../design_system/sp_tone.dart';

part 'owners_residents_unit_card.dart';
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

  const OwnersResidentsModulePage({
    super.key,
    required this.controller,
    this.initialUnitId,
    this.initialBlockFilter,
    this.initialOccupancyFilter,
  });

  @override
  State<OwnersResidentsModulePage> createState() => _OwnersResidentsModulePageState();
}

class _OwnersResidentsModulePageState extends State<OwnersResidentsModulePage> {
  late String _searchQuery;
  late String _blockFilter;
  late String _occupancyFilter;
  final Map<String, int> _unitTabs = {}; // 0: Sakinler, 1: Kat Maliki

  @override
  void initState() {
    super.initState();
    _searchQuery = '';
    _blockFilter = widget.initialBlockFilter ?? 'ALL';
    _occupancyFilter = widget.initialOccupancyFilter ?? 'ALL';
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

        final stats = ResidentOccupancyStats.from(homeOwners);

        return AppFullscreenPage(
          title: 'Kat Malikleri & Sakinler Modülü',
          subtitle: '${widget.controller.userSession.siteName} • Yönetim ve Operasyon Portalı',
          icon: const Icon(Icons.people_alt, color: AppColors.accentCyan),
          actions: [
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // KPI Metric Cards
              ResidentSummary(stats: stats),

              const SizedBox(height: 16),

              // Search Input
              testId('module_search_input', TextField(
                key: const Key('module_search_input'),
                onChanged: (val) {
                  setState(() {
                    _searchQuery = val.trim();
                  });
                },
                decoration: InputDecoration(
                  hintText: 'Sakin, malik, hane sakini, daire no veya telefon ara...',
                  hintStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          tooltip: 'Aramayı temizle',
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => setState(() => _searchQuery = ''),
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

              // Occupancy Status Filters
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildOccupancyFilterChip('Tümü (${stats.totalUnits})', OccupancyFilter.all),
                    const SizedBox(width: AppSpacing.sm),
                    _buildOccupancyFilterChip('${AppStrings.tenantOccupied} (${stats.tenantCount})', OccupancyFilter.tenant),
                    const SizedBox(width: AppSpacing.sm),
                    _buildOccupancyFilterChip('${AppStrings.ownerOccupied} (${stats.ownerCount})', OccupancyFilter.owner),
                    const SizedBox(width: AppSpacing.sm),
                    _buildOccupancyFilterChip('${AppStrings.vacantUnit} (${stats.vacantCount})', OccupancyFilter.vacant),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // Block Filters
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildBlockFilterChip('Tüm Bloklar', allBlocksFilter),
                    ...availableBlocks.map((b) => _buildBlockFilterChip('$b Blok', b)),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // List of Units
              if (filtered.isEmpty)
                Container(
                  padding: const EdgeInsets.all(32),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: AppColors.surface(context),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border(context)),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.person_search_outlined, size: 44, color: AppColors.textSecondary(context)),
                      const SizedBox(height: 12),
                      Text(
                        'Arama kriterlerine uygun bağımsız bölüm bulunamadı.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textPrimary(context), fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Filtreleri sıfırlayarak tüm daireleri görüntüleyebilirsiniz.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                      ),
                    ],
                  ),
                )
              else
                ...filtered.map((ho) => _buildUnitCard(ho)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOccupancyFilterChip(String label, String code) {
    return SpFilterChip(
      label: label,
      selected: _occupancyFilter == code,
      onSelected: () => setState(() => _occupancyFilter = code),
      id: 'module_occupancy_filter_$code',
    );
  }

  Widget _buildBlockFilterChip(String label, String code) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: SpFilterChip(
        label: label,
        selected: _blockFilter == code,
        onSelected: () => setState(() => _blockFilter = code),
        tone: SpTone.accent,
        id: 'module_block_filter_$code',
      ),
    );
  }

  /// Rebuilds the list after a change made by one of the part files (they may not call
  /// the protected `setState` directly).
  void _update(VoidCallback change) => setState(change);
}
