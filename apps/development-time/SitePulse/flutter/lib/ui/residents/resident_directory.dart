import 'package:flutter/material.dart';

import '../../domain/models/dues_models.dart';
import '../../l10n/app_strings.dart';
import '../design_system/sp_metric.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';

/// Occupancy filter codes shared by the dashboard directory and the
/// standalone owners & residents module.
abstract final class OccupancyFilter {
  static const all = 'ALL';
  static const tenant = 'TENANT';
  static const owner = 'OWNER';
  static const vacant = 'VACANT';
}

/// Block value meaning "no block filter".
const allBlocksFilter = 'ALL';

/// Canonical block code: `"A Blok"`, `"a-blok"` and `"A"` all become `"A"`.
String normalizeBlockCode(String block) =>
    block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();

/// Distinct non-empty block names, case-insensitively de-duplicated, in
/// their original order.
List<String> distinctBlocks(Iterable<String> blocks) {
  final seen = <String>{};
  final result = <String>[];
  for (final b in blocks) {
    final t = b.trim();
    if (t.isNotEmpty && seen.add(t.toLowerCase())) result.add(t);
  }
  return result;
}

/// Whether [ho] passes the block, occupancy and free-text filters.
///
/// Search covers owner, tenant, active responsible resident, household
/// members (name, phone, e-mail), unit number, phones, e-mails and block.
bool matchesResidentFilters(
  HomeOwnerItem ho, {
  String blockFilter = allBlocksFilter,
  String occupancyFilter = OccupancyFilter.all,
  String query = '',
}) {
  if (blockFilter != allBlocksFilter && normalizeBlockCode(ho.block) != normalizeBlockCode(blockFilter)) {
    return false;
  }
  switch (occupancyFilter) {
    case OccupancyFilter.tenant:
      if (!ho.isTenantOccupied) return false;
    case OccupancyFilter.owner:
      if (!ho.isOwnerOccupied) return false;
    case OccupancyFilter.vacant:
      if (!ho.isVacant) return false;
  }
  if (query.isEmpty) return true;

  final q = query.toLowerCase();
  bool has(String? value) => (value ?? '').toLowerCase().contains(q);
  return has(ho.ownerFullName) ||
      has(ho.tenantFullName) ||
      has(ho.activeResponsibleResidentName) ||
      ho.householdResidents.any((r) => has(r.fullName) || has(r.phone) || has(r.email)) ||
      ho.unitNo.toString().contains(q) ||
      has(ho.phone) ||
      has(ho.tenantPhone) ||
      has(ho.activeResponsiblePhone) ||
      has(ho.email) ||
      has(ho.tenantEmail) ||
      has(ho.block);
}

/// Occupancy counts for a list of units.
class ResidentOccupancyStats {
  final int totalUnits;
  final int tenantCount;
  final int ownerCount;
  final int vacantCount;
  final int totalCoResidents;

  const ResidentOccupancyStats({
    required this.totalUnits,
    required this.tenantCount,
    required this.ownerCount,
    required this.vacantCount,
    required this.totalCoResidents,
  });

  factory ResidentOccupancyStats.from(List<HomeOwnerItem> units) {
    return ResidentOccupancyStats(
      totalUnits: units.length,
      tenantCount: units.where((h) => h.isTenantOccupied).length,
      ownerCount: units.where((h) => h.isOwnerOccupied).length,
      vacantCount: units.where((h) => h.isVacant).length,
      totalCoResidents: units.fold<int>(0, (sum, h) => sum + h.householdResidents.length),
    );
  }

  /// Occupied share as a one-decimal percentage string (`"83.3"`), computed
  /// with integer counts only; `"0"` when there are no units.
  String get occupancyRate {
    if (totalUnits == 0) return '0';
    // Tenths of a percent, rounded half up, without floating point.
    final tenths = ((totalUnits - vacantCount) * 2000 + totalUnits) ~/ (2 * totalUnits);
    return '${tenths ~/ 10}.${tenths % 10}';
  }
}

/// "Sakin & Mülkiyet Durum Özeti" card: occupancy pill and five icon metrics.
///
/// [dense] is the compact variant embedded in the dashboard.
class ResidentSummary extends StatelessWidget {
  final ResidentOccupancyStats stats;
  final bool dense;

  const ResidentSummary({super.key, required this.stats, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget metric(String label, int value, IconData icon, SpTone tone) => Expanded(
          child: SpIconMetric(label: label, value: '$value', icon: icon, tone: tone, dense: dense),
        );
    return Container(
      padding: dense
          ? const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm)
          : const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(dense ? AppRadius.control + 2 : AppRadius.card - 2),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: Icon(Icons.analytics_outlined, size: dense ? 16 : 18, color: SpTone.info.accent(context)),
              ),
              SizedBox(width: dense ? 6 : AppSpacing.sm),
              Expanded(
                child: Text(
                  AppStrings.residentSummaryTitle,
                  style: text.labelMedium?.copyWith(
                    color: AppColors.textPrimary(context),
                    fontSize: dense ? 12 : 13,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Container(
                padding: dense
                    ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
                    : const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
                decoration: BoxDecoration(
                  color: SpTone.success.tint(context),
                  borderRadius: BorderRadius.circular(dense ? 6 : AppRadius.chip),
                ),
                child: Text(
                  'Doluluk: %${stats.occupancyRate}',
                  style: text.labelMedium?.copyWith(color: SpTone.success.foreground(context), fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          SizedBox(height: dense ? AppSpacing.sm : AppSpacing.md + 2),
          Row(
            children: [
              metric(AppStrings.totalUnits, stats.totalUnits, Icons.apartment, SpTone.info),
              metric(AppStrings.tenantOccupied, stats.tenantCount, Icons.key, SpTone.success),
              metric(AppStrings.ownerOccupied, stats.ownerCount, Icons.vpn_key, SpTone.accent),
              metric(AppStrings.vacantUnit, stats.vacantCount, Icons.door_back_door, SpTone.warning),
              metric(AppStrings.householdResidents, stats.totalCoResidents, Icons.family_restroom, SpTone.info),
            ],
          ),
        ],
      ),
    );
  }
}
