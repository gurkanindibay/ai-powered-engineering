import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../domain/models/dues_models.dart';
import '../components/app_fullscreen_page.dart';
import '../dashboard/dashboard_controller.dart';
import '../theme/app_theme.dart';

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
        final rawBlocks = widget.controller.blocks;
        final seenB = <String>{};
        final availableBlocks = <String>[];
        for (final b in rawBlocks) {
          final t = b.trim();
          if (t.isNotEmpty && seenB.add(t.toLowerCase())) {
            availableBlocks.add(t);
          }
        }

        // Filter calculation
        final filtered = homeOwners.where((ho) {
          if (widget.initialUnitId != null && widget.initialUnitId!.isNotEmpty && _searchQuery.isEmpty && _blockFilter == 'ALL' && _occupancyFilter == 'ALL') {
            if (ho.unitId == widget.initialUnitId) return true;
          }

          if (_blockFilter != 'ALL') {
            final b1 = ho.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();
            final b2 = _blockFilter.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();
            if (b1 != b2) return false;
          }

          if (_occupancyFilter == 'TENANT') {
            if (!ho.isTenantOccupied) return false;
          } else if (_occupancyFilter == 'OWNER') {
            if (!ho.isOwnerOccupied) return false;
          } else if (_occupancyFilter == 'VACANT') {
            if (!ho.isVacant) return false;
          }

          if (_searchQuery.isNotEmpty) {
            final q = _searchQuery.toLowerCase();
            final matchOwner = ho.ownerFullName.toLowerCase().contains(q);
            final matchTenant = (ho.tenantFullName ?? '').toLowerCase().contains(q);
            final matchResponsible = ho.activeResponsibleResidentName.toLowerCase().contains(q);
            final matchResidents = ho.householdResidents.any((r) =>
                r.fullName.toLowerCase().contains(q) ||
                r.phone.toLowerCase().contains(q) ||
                r.email.toLowerCase().contains(q));
            final matchUnit = ho.unitNo.toString().contains(q);
            final matchPhone = ho.phone.toLowerCase().contains(q) ||
                (ho.tenantPhone ?? '').toLowerCase().contains(q) ||
                ho.activeResponsiblePhone.toLowerCase().contains(q);
            final matchBlock = ho.block.toLowerCase().contains(q);
            return matchOwner || matchTenant || matchResponsible || matchResidents || matchUnit || matchPhone || matchBlock;
          }
          return true;
        }).toList();

        final totalUnits = homeOwners.length;
        final tenantCount = homeOwners.where((h) => h.isTenantOccupied).length;
        final ownerCount = homeOwners.where((h) => h.isOwnerOccupied).length;
        final vacantCount = homeOwners.where((h) => h.isVacant).length;
        final totalCoResidents = homeOwners.fold<int>(0, (sum, h) => sum + h.householdResidents.length);
        final occupancyRate = totalUnits > 0 ? (((totalUnits - vacantCount) / totalUnits) * 100).toStringAsFixed(1) : '0';

        return AppFullscreenPage(
          title: 'Kat Malikleri & Sakinler Modülü',
          subtitle: '${widget.controller.userSession.siteName} • Yönetim ve Operasyon Portalı',
          icon: const Icon(Icons.people_alt, color: AppColors.accentCyan),
          bottomBar: AppFullscreenPage.buildBottomBar(
            context: context,
            children: [
              OutlinedButton.icon(
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
              ),
              ElevatedButton.icon(
                key: const Key('module_add_new_resident_btn'),
                onPressed: () => _openAddResident(context),
                icon: const Icon(Icons.person_add_alt_1, size: 18),
                label: const Text('Yeni Sakin Ekle'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentCyan,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // KPI Metric Cards
              _buildKpiMetrics(
                totalUnits: totalUnits,
                occupancyRate: occupancyRate,
                tenantCount: tenantCount,
                ownerCount: ownerCount,
                vacantCount: vacantCount,
                totalCoResidents: totalCoResidents,
              ),

              const SizedBox(height: 16),

              // Search Input
              TextField(
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
              ),

              const SizedBox(height: 12),

              // Occupancy Status Filters
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildOccupancyFilterChip('Tümü ($totalUnits)', 'ALL'),
                    const SizedBox(width: 8),
                    _buildOccupancyFilterChip('👥 Kiracılı ($tenantCount)', 'TENANT'),
                    const SizedBox(width: 8),
                    _buildOccupancyFilterChip('🔑 Malik Mukim ($ownerCount)', 'OWNER'),
                    const SizedBox(width: 8),
                    _buildOccupancyFilterChip('🚪 Boş Daire ($vacantCount)', 'VACANT'),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // Block Filters
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildBlockFilterChip('Tüm Bloklar', 'ALL'),
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

  Widget _buildKpiMetrics({
    required int totalUnits,
    required String occupancyRate,
    required int tenantCount,
    required int ownerCount,
    required int vacantCount,
    required int totalCoResidents,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.analytics_outlined, size: 18, color: AppColors.accentCyan),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sakin & Mülkiyet Durum Özeti',
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accentGreen.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Doluluk: %$occupancyRate',
                  style: const TextStyle(
                    color: AppColors.accentGreen,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _buildMetricItem('Toplam Daire', '$totalUnits', Icons.apartment, AppColors.accentCyan)),
              Expanded(child: _buildMetricItem('Kiracılı', '$tenantCount', Icons.key, AppColors.accentGreen)),
              Expanded(child: _buildMetricItem('Malik Mukim', '$ownerCount', Icons.vpn_key, AppColors.accentPurple)),
              Expanded(child: _buildMetricItem('Boş Daire', '$vacantCount', Icons.door_back_door, AppColors.accentOrange)),
              Expanded(child: _buildMetricItem('Hane Sakini', '$totalCoResidents', Icons.family_restroom, AppColors.accentCyan)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricItem(String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: AppColors.textPrimary(context),
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary(context),
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _buildOccupancyFilterChip(String label, String code) {
    final isSelected = _occupancyFilter == code;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => setState(() => _occupancyFilter = code),
      selectedColor: AppColors.accentCyan.withOpacity(0.2),
      checkmarkColor: AppColors.accentCyan,
      labelStyle: TextStyle(
        color: isSelected ? AppColors.accentCyan : AppColors.textSecondary(context),
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
    );
  }

  Widget _buildBlockFilterChip(String label, String code) {
    final isSelected = _blockFilter == code;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (_) => setState(() => _blockFilter = code),
        selectedColor: AppColors.accentPurple.withOpacity(0.2),
        checkmarkColor: AppColors.accentPurple,
        labelStyle: TextStyle(
          color: isSelected ? AppColors.accentPurple : AppColors.textSecondary(context),
          fontSize: 11,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

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
                              fontSize: 10,
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
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Kat ${ho.floor}${ho.houseType != null && ho.houseType!.isNotEmpty ? ' • ${ho.houseType}' : ''} • Arsa Payı: ${ho.landShare}',
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                      ),
                    ],
                  ),
                ),
                // Monthly Dues
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '₺${ho.monthlyDues.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: AppColors.textPrimary(context),
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Aylık Aidat',
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 10),
                    ),
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
                              style: const TextStyle(
                                color: AppColors.accentCyan,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          TextButton.icon(
                            key: Key('module_set_responsible_${ho.unitId}'),
                            onPressed: () => _showSelectPrimaryResponsibleDialog(ho),
                            icon: const Icon(Icons.swap_horiz, size: 14, color: AppColors.accentCyan),
                            label: const Text('Sorumluyu Seç', style: TextStyle(fontSize: 11, color: AppColors.accentCyan, fontWeight: FontWeight.bold)),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              minimumSize: const Size(0, 24),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
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
                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                        child: InkWell(
                          key: Key('module_tab_residents_${ho.unitId}'),
                          onTap: () => setState(() => _unitTabs[ho.unitId] = 0),
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
                                      color: cardTab == 0 ? AppColors.accentGreen : AppColors.textSecondary(context),
                                      fontSize: 11,
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
                      const SizedBox(width: 4),
                      Expanded(
                        child: InkWell(
                          key: Key('module_tab_owner_${ho.unitId}'),
                          onTap: () => setState(() => _unitTabs[ho.unitId] = 1),
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
                                      color: cardTab == 1 ? AppColors.accentCyan : AppColors.textSecondary(context),
                                      fontSize: 11,
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
                              const Expanded(
                                child: Text(
                                  'Birincil Kiracı',
                                  style: TextStyle(color: AppColors.accentGreen, fontSize: 11, fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              OutlinedButton.icon(
                                key: Key('module_edit_residents_${ho.unitId}'),
                                onPressed: () => _openEditHomeOwner(ho, initialTab: 0),
                                icon: const Icon(Icons.edit_outlined, size: 11),
                                label: const Text('Düzenle', style: TextStyle(fontSize: 10)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.accentGreen,
                                  side: const BorderSide(color: AppColors.accentGreen),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  minimumSize: const Size(0, 24),
                                ),
                              ),
                              const SizedBox(width: 4),
                              OutlinedButton.icon(
                                key: Key('module_move_out_${ho.unitId}'),
                                onPressed: () => _openMoveOut(ho),
                                icon: const Icon(Icons.logout, size: 11),
                                label: const Text('Tahliye', style: TextStyle(fontSize: 10)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.accentOrange,
                                  side: const BorderSide(color: AppColors.accentOrange),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  minimumSize: const Size(0, 24),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            ho.tenantFullName ?? 'Kiracı',
                            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${ho.tenantPhone ?? ho.phone} • ${ho.tenantEmail ?? ho.email}',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 11),
                            ),
                          ),
                          ElevatedButton.icon(
                            key: Key('module_move_in_${ho.unitId}'),
                            onPressed: () => _openMoveIn(ho),
                            icon: const Icon(Icons.person_add_alt, size: 12),
                            label: const Text('Yeni Sakin Girişi', style: TextStyle(fontSize: 11)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.accentGreen,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              minimumSize: const Size(0, 28),
                            ),
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
                                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 11, fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            TextButton.icon(
                              key: Key('module_add_resident_to_${ho.unitId}'),
                              onPressed: () => _openAddHouseholdMember(ho),
                              icon: const Icon(Icons.add, size: 14, color: AppColors.accentPurple),
                              label: const Text('+ Hane Sakini', style: TextStyle(color: AppColors.accentPurple, fontSize: 11, fontWeight: FontWeight.bold)),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                minimumSize: const Size(0, 24),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
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
                                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    IconButton(
                                      key: Key('module_edit_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                      icon: const Icon(Icons.edit_outlined, size: 14, color: AppColors.accentCyan),
                                      tooltip: '${m.fullName} düzenle',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => _openEditHouseholdMember(ho, m),
                                    ),
                                    const SizedBox(width: 6),
                                    IconButton(
                                      key: Key('module_delete_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                      icon: const Icon(Icons.close, size: 14, color: AppColors.accentRed),
                                      tooltip: '${m.fullName} sil',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => _confirmDeleteHouseholdMember(ho, m),
                                    ),
                                  ],
                                ),
                              )),
                        ] else ...[
                          const SizedBox(height: 4),
                          Text(
                            'Henüz kayıtlı ek hane sakini bulunmuyor.',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11, fontStyle: FontStyle.italic),
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
                            const Expanded(
                              child: Text(
                                'Kat Maliki (Mülk Sahibi)',
                                style: TextStyle(color: AppColors.accentCyan, fontSize: 11, fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            OutlinedButton.icon(
                              key: Key('module_edit_owner_${ho.unitId}'),
                              onPressed: () => _openEditHomeOwner(ho, initialTab: 1),
                              icon: const Icon(Icons.edit_outlined, size: 11),
                              label: const Text('Düzenle', style: TextStyle(fontSize: 10)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.accentCyan,
                                side: const BorderSide(color: AppColors.accentCyan),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                minimumSize: const Size(0, 24),
                              ),
                            ),
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
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Arsa Payı Oranı: ${ho.landShare}',
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                    OutlinedButton.icon(
                      key: Key('module_history_ho_${ho.unitId}'),
                      onPressed: () => _openUnitHistory(ho),
                      icon: const Icon(Icons.history, size: 13, color: AppColors.accentCyan),
                      label: const Text('Daire Tarihçesi', style: TextStyle(fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentCyan,
                        side: const BorderSide(color: AppColors.accentCyan),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: const Size(0, 30),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                    OutlinedButton.icon(
                      key: Key('module_iban_ho_${ho.unitId}'),
                      onPressed: () => _openIbanDetails(ho),
                      icon: const Icon(Icons.account_balance, size: 13, color: AppColors.accentPurple),
                      label: const Text('Sanal IBAN', style: TextStyle(fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentPurple,
                        side: const BorderSide(color: AppColors.accentPurple),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: const Size(0, 30),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                    OutlinedButton.icon(
                      key: Key('module_delete_ho_${ho.unitId}'),
                      onPressed: () => _openDeleteUnit(ho),
                      icon: const Icon(Icons.delete_outline, size: 13, color: AppColors.accentRed),
                      label: const Text('Sil', style: TextStyle(fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentRed,
                        side: const BorderSide(color: AppColors.accentRed),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: const Size(0, 30),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
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

  void _showSelectPrimaryResponsibleDialog(HomeOwnerItem ho) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.star, color: AppColors.accentCyan, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Aktif Sorumlu Sakini Belirle',
                      style: TextStyle(
                        color: AppColors.textPrimary(ctx),
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Bu bağımsız bölüm için bildirim, aidat ve iletişimlerde birincil sorumlu olacak kişiyi seçin.',
                  style: TextStyle(color: AppColors.textSecondary(ctx), fontSize: 12),
                ),
                const SizedBox(height: 16),

                // Option 1: Kat Maliki
                ListTile(
                  leading: const Icon(Icons.vpn_key_outlined, color: AppColors.accentCyan),
                  title: Text(ho.ownerFullName.isNotEmpty ? ho.ownerFullName : 'Kat Maliki'),
                  subtitle: Text('Kat Maliki (Mülk Sahibi) • ${ho.phone}'),
                  trailing: (ho.primaryResponsibleRole == 'OWNER' || (!ho.isTenantOccupied && ho.primaryResponsibleRole == null))
                      ? const Icon(Icons.check_circle, color: AppColors.accentGreen)
                      : null,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  tileColor: AppColors.card(ctx),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.controller.setPrimaryResponsibleResident(
                      unitId: ho.unitId,
                      residentName: ho.ownerFullName,
                      role: 'OWNER',
                      phone: ho.phone,
                      email: ho.email,
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${ho.ownerFullName} aktif sorumlu olarak belirlendi.')),
                    );
                  },
                ),

                // Option 2: Kiracı (if present)
                if (ho.isTenantOccupied && ho.tenantFullName != null && ho.tenantFullName!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ListTile(
                    leading: const Icon(Icons.key, color: AppColors.accentGreen),
                    title: Text(ho.tenantFullName!),
                    subtitle: Text('Kiracı (Fiilen İkamet Eden) • ${ho.tenantPhone ?? ho.phone}'),
                    trailing: (ho.primaryResponsibleRole == 'TENANT' || (ho.isTenantOccupied && ho.primaryResponsibleRole == null))
                        ? const Icon(Icons.check_circle, color: AppColors.accentGreen)
                        : null,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    tileColor: AppColors.card(ctx),
                    onTap: () {
                      Navigator.pop(ctx);
                      widget.controller.setPrimaryResponsibleResident(
                        unitId: ho.unitId,
                        residentName: ho.tenantFullName!,
                        role: 'TENANT',
                        phone: ho.tenantPhone ?? ho.phone,
                        email: ho.tenantEmail ?? ho.email,
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${ho.tenantFullName} aktif sorumlu olarak belirlendi.')),
                      );
                    },
                  ),
                ],

                // Option 3: Household Co-Residents
                if (ho.householdResidents.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ...ho.householdResidents.map((m) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          leading: const Icon(Icons.family_restroom, color: AppColors.accentPurple),
                          title: Text(m.fullName),
                          subtitle: Text('${m.relationship} • ${m.phone}'),
                          trailing: ho.primaryResponsibleName == m.fullName
                              ? const Icon(Icons.check_circle, color: AppColors.accentGreen)
                              : null,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          tileColor: AppColors.card(ctx),
                          onTap: () {
                            Navigator.pop(ctx);
                            widget.controller.setPrimaryResponsibleResident(
                              unitId: ho.unitId,
                              residentName: m.fullName,
                              role: 'RESIDENT',
                              phone: m.phone,
                              email: m.email,
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('${m.fullName} aktif sorumlu olarak belirlendi.')),
                            );
                          },
                        ),
                      )),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _openAddResident(BuildContext context) {
    _showAddResidentFullscreen();
  }

  void _showAddResidentFullscreen() {
    final availableBlocks = widget.controller.blocks;
    String selectedBlock = availableBlocks.isNotEmpty ? availableBlocks.first : 'A';
    final houseTypes = widget.controller.houseTypes;
    String? selectedHouseType = houseTypes.isNotEmpty ? houseTypes.first.typeName : null;

    final ownerNameCtrl = TextEditingController();
    final ownerPhoneCtrl = TextEditingController();
    final ownerEmailCtrl = TextEditingController();
    final unitCtrl = TextEditingController();

    // Tenant controllers when occupancyStatus == 'TENANT_OCCUPIED'
    final tenantNameCtrl = TextEditingController();
    final tenantPhoneCtrl = TextEditingController();
    final tenantEmailCtrl = TextEditingController();

    // Dynamic co-residents (Hane Sakinleri / Birlikte İkamet Eden Bireyler)
    final pendingResidents = <_PendingResidentEntry>[];

    String occupancyStatus = 'OWNER_OCCUPIED'; // 'OWNER_OCCUPIED', 'TENANT_OCCUPIED', 'VACANT'
    String? formError;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          final currentBlocks = widget.controller.blocks.isNotEmpty ? widget.controller.blocks : ['A', 'B'];
          if (!currentBlocks.contains(selectedBlock)) {
            selectedBlock = currentBlocks.first;
          }
          final currentHouseTypes = widget.controller.houseTypes;
          if (selectedHouseType == null && currentHouseTypes.isNotEmpty) {
            selectedHouseType = currentHouseTypes.first.typeName;
          }
          final currentTariff = currentHouseTypes.cast<HouseTypeTariff?>().firstWhere(
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
              child: const Icon(Icons.person_add_alt_1_outlined, color: AppColors.accentCyan, size: 20),
            ),
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(
                  onPressed: () {
                    for (final r in pendingResidents) {
                      r.dispose();
                    }
                    Navigator.pop(ctx);
                  },
                  child: const Text('Vazgeç'),
                ),
                ElevatedButton(
                  key: const Key('module_save_new_resident_btn'),
                  onPressed: () async {
                    setDlgState(() => formError = null);
                    final ownerName = ownerNameCtrl.text.trim();
                    final unitText = unitCtrl.text.trim();
                    final unitNo = int.tryParse(unitText);

                    if (ownerName.isEmpty || unitText.isEmpty || unitNo == null || unitNo <= 0) {
                      setDlgState(() {
                        formError = 'Lütfen geçerli bir Daire No ve Kat Maliki Ad Soyad giriniz.';
                      });
                      return;
                    }

                    if (occupancyStatus == 'TENANT_OCCUPIED' && tenantNameCtrl.text.trim().isEmpty) {
                      setDlgState(() {
                        formError = 'Daire kirada seçildiğinde lütfen Kiracı Ad Soyad bilgisini giriniz.';
                      });
                      return;
                    }

                    // Check if unit is already registered in controller.homeOwners
                    final cleanBlock = selectedBlock.replaceAll('Blok', '').trim();
                    final existingHo = widget.controller.homeOwners.cast<HomeOwnerItem?>().firstWhere(
                      (h) {
                        if (h == null) return false;
                        final b1 = h.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
                        final b2 = cleanBlock.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
                        return h.unitNo == unitNo && b1 == b2;
                      },
                      orElse: () => null,
                    );

                    if (existingHo != null) {
                      final existingName = existingHo.tenantFullName ?? existingHo.ownerFullName;
                      final confirmed = await AppFullscreenPage.pushConfirmation(
                        context: ctx,
                        title: 'Yeni Daire / Sakin Atama Onayı',
                        message: '$selectedBlock Daire $unitNo için halihazırda kayıtlı sakin: "$existingName".\n\n'
                            'Yeni kayıt yapıldığında mevcut sakin geçmiş ikamet arşivine aktarılacak ve yeni sakin aktif yapılacaktır.\n\n'
                            'Bu işlemi onaylıyor musunuz?',
                        confirmLabel: 'Evet, Yeni Sakin Kaydet',
                        cancelLabel: 'Vazgeç',
                        confirmColor: AppColors.accentCyan,
                        icon: Icons.swap_horiz_rounded,
                        iconColor: AppColors.accentCyan,
                      );
                      if (confirmed != true) return;
                    }

                    if (!ctx.mounted) return;
                    Navigator.pop(ctx);

                    final isResident = occupancyStatus == 'OWNER_OCCUPIED';
                    final isTenantOccupied = occupancyStatus == 'TENANT_OCCUPIED';

                    await widget.controller.registerHomeOwner(
                      block: selectedBlock,
                      unitNo: unitNo,
                      ownerName: ownerName,
                      phone: ownerPhoneCtrl.text.trim().isNotEmpty ? ownerPhoneCtrl.text.trim() : '05550000000',
                      email: ownerEmailCtrl.text.trim().isNotEmpty
                          ? ownerEmailCtrl.text.trim()
                          : 'evsahibi${DateTime.now().millisecondsSinceEpoch}@example.com',
                      tenantFullName: isTenantOccupied ? tenantNameCtrl.text.trim() : null,
                      tenantPhone: isTenantOccupied && tenantPhoneCtrl.text.trim().isNotEmpty ? tenantPhoneCtrl.text.trim() : null,
                      tenantEmail: isTenantOccupied && tenantEmailCtrl.text.trim().isNotEmpty ? tenantEmailCtrl.text.trim() : null,
                      houseType: selectedHouseType,
                      duesAmount: currentTariff?.duesAmount ?? Decimal.parse('1400.00'),
                      isResident: isResident,
                      role: isTenantOccupied ? 'TENANT' : 'OWNER',
                    );

                    // Save any pending household co-residents
                    if (pendingResidents.isNotEmpty) {
                      final registeredHo = widget.controller.homeOwners.cast<HomeOwnerItem?>().firstWhere(
                        (h) {
                          if (h == null) return false;
                          final b1 = h.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
                          final b2 = cleanBlock.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
                          return h.unitNo == unitNo && b1 == b2;
                        },
                        orElse: () => null,
                      );
                      final targetUnitId = registeredHo?.unitId ?? 'unit-$unitNo';

                      for (final res in pendingResidents) {
                        final resName = res.nameCtrl.text.trim();
                        if (resName.isNotEmpty) {
                          await widget.controller.addHouseholdMember(
                            unitId: targetUnitId,
                            block: selectedBlock,
                            unitNo: unitNo,
                            fullName: resName,
                            phone: res.phoneCtrl.text.trim().isNotEmpty
                                ? res.phoneCtrl.text.trim()
                                : (ownerPhoneCtrl.text.trim().isNotEmpty ? ownerPhoneCtrl.text.trim() : '05550000000'),
                            email: res.emailCtrl.text.trim().isNotEmpty
                                ? res.emailCtrl.text.trim()
                                : 'sakin_${DateTime.now().millisecondsSinceEpoch}@example.com',
                            relationship: res.relationship,
                          );
                        }
                      }
                    }

                    if (mounted) {
                      final addedCoResidentsCount = pendingResidents.where((r) => r.nameCtrl.text.trim().isNotEmpty).length;
                      final coResidentMsg = addedCoResidentsCount > 0 ? ' ve $addedCoResidentsCount hane sakini' : '';
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Yeni daire ($selectedBlock Daire $unitNo - $ownerName)$coResidentMsg başarıyla eklendi.')),
                      );
                    }
                  },
                  child: const Text('Kaydet'),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (formError != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              formError!,
                              style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
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
                            const Icon(Icons.apartment, size: 16, color: AppColors.accentCyan),
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
                                '₺${currentTariff.duesAmount}/ay',
                                style: const TextStyle(
                                  color: AppColors.accentGreen,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
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
                              child: DropdownButtonFormField<String>(
                                key: const Key('module_new_resident_block'),
                                value: selectedBlock,
                                dropdownColor: AppColors.card(context),
                                isDense: true,
                                decoration: const InputDecoration(
                                  labelText: 'Blok Seçiniz',
                                  filled: true,
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                ),
                                items: currentBlocks.map((b) => DropdownMenuItem(value: b, child: Text(b))).toList(),
                                onChanged: (val) {
                                  if (val != null) setDlgState(() => selectedBlock = val);
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 4,
                              child: TextField(
                                key: const Key('module_new_resident_unit'),
                                controller: unitCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Daire No *',
                                  hintText: 'Örn: 14',
                                  filled: true,
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (currentHouseTypes.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          DropdownButtonFormField<String>(
                            key: const Key('module_new_resident_house_type'),
                            value: selectedHouseType,
                            isDense: true,
                            dropdownColor: AppColors.card(context),
                            decoration: const InputDecoration(
                              labelText: 'Konut Tipi & Tarife',
                              filled: true,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            ),
                            items: currentHouseTypes.map((ht) {
                              return DropdownMenuItem<String>(
                                value: ht.typeName,
                                child: Text('${ht.typeName} (₺${ht.duesAmount}/ay)'),
                              );
                            }).toList(),
                            onChanged: (val) {
                              if (val != null) setDlgState(() => selectedHouseType = val);
                            },
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
                            const Icon(Icons.vpn_key_outlined, size: 16, color: AppColors.accentCyan),
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
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppColors.accentCyan.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.accentCyan.withValues(alpha: 0.25)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.info_outline, size: 15, color: AppColors.accentCyan),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Kat Maliki: Dairenin yasal tapu sahibidir. Demirbaş ve ana bina giderlerinin kanuni muhatabıdır.',
                                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          key: const Key('module_new_resident_name'),
                          controller: ownerNameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Kat Maliki Ad Soyad *',
                            hintText: 'Örn: Selim Evsahibi',
                            filled: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          key: const Key('module_new_resident_phone'),
                          controller: ownerPhoneCtrl,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            labelText: 'Kat Maliki Telefon',
                            hintText: 'Örn: 0532 123 45 67',
                            filled: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          key: const Key('module_new_resident_email'),
                          controller: ownerEmailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            labelText: 'Kat Maliki E-posta',
                            hintText: 'Örn: evsahibi@example.com',
                            filled: true,
                            border: OutlineInputBorder(),
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
                      border: Border.all(color: AppColors.accentGreen.withValues(alpha: 0.35)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.sync_alt_rounded, size: 16, color: AppColors.accentGreen),
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
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<String>(
                            key: const Key('module_occupancy_status_selector'),
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
                                icon: Icon(Icons.meeting_room_outlined, size: 16),
                              ),
                            ],
                            selected: {occupancyStatus},
                            onSelectionChanged: (newSel) {
                              setDlgState(() => occupancyStatus = newSel.first);
                            },
                          ),
                        ),
                        const SizedBox(height: 10),

                        if (occupancyStatus == 'OWNER_OCCUPIED') ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.accentGreen.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.accentGreen.withValues(alpha: 0.35)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.check_circle_outline, size: 15, color: AppColors.accentGreen),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '✓ Malik Oturuyor: Kat maliki bu dairede bizzat ikamet etmektedir. İşletme ve demirbaş aidatlarının doğrudan muhatabıdır. Ayrıca kiracı tanımlanamaz.',
                                    style: TextStyle(color: AppColors.accentGreen, fontSize: 11, fontWeight: FontWeight.bold),
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
                              border: Border.all(color: AppColors.accentGreen.withValues(alpha: 0.25)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.key, size: 15, color: AppColors.accentGreen),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Kiracı Bilgileri (Fiilen İkamet Eden Sakin)',
                                      style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Aylık işletme aidatları kiracıya, demirbaş aidatları kat malikine yansıtılır.',
                                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  key: const Key('module_new_tenant_name'),
                                  controller: tenantNameCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Kiracı Ad Soyad *',
                                    hintText: 'Örn: Canan Kaya',
                                    filled: true,
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  key: const Key('module_new_tenant_phone'),
                                  controller: tenantPhoneCtrl,
                                  keyboardType: TextInputType.phone,
                                  decoration: const InputDecoration(
                                    labelText: 'Kiracı Telefon',
                                    hintText: 'Örn: 0533 111 22 33',
                                    filled: true,
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  key: const Key('module_new_tenant_email'),
                                  controller: tenantEmailCtrl,
                                  keyboardType: TextInputType.emailAddress,
                                  decoration: const InputDecoration(
                                    labelText: 'Kiracı E-posta',
                                    hintText: 'Örn: kiraci@example.com',
                                    filled: true,
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ] else if (occupancyStatus == 'VACANT') ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.accentOrange.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.accentOrange.withValues(alpha: 0.3)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.info_outline, size: 15, color: AppColors.accentOrange),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Boş Daire: Dairede şu anda ikamet eden yoktur. Daire boş statüsünde kaydedilir ve tüm aidat borçları kat malikine yansıtılır.',
                                    style: TextStyle(color: AppColors.textPrimary(context), fontSize: 11, fontWeight: FontWeight.w600),
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
                      border: Border.all(color: AppColors.accentCyan.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.family_restroom, size: 16, color: AppColors.accentCyan),
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
                            OutlinedButton.icon(
                              key: const Key('module_add_co_resident_btn'),
                              icon: const Icon(Icons.person_add_alt_1, size: 14, color: AppColors.accentCyan),
                              label: const Text('+ Hane Sakini Ekle', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.accentCyan)),
                              onPressed: () {
                                setDlgState(() {
                                  pendingResidents.add(_PendingResidentEntry());
                                });
                              },
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: const Size(0, 28),
                                side: const BorderSide(color: AppColors.accentCyan),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Dairede birlikte ikamet eden diğer aile bireylerini (eş, çocuk, anne/baba vb.) ekleyebilirsiniz.',
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                        ),
                        const SizedBox(height: 10),
                        if (pendingResidents.isEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                            decoration: BoxDecoration(
                              color: AppColors.surface(context),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.border(context).withOpacity(0.5)),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.info_outline, size: 16, color: AppColors.textSecondary(context)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Henüz eklenen hane sakini yok. Birlikte ikamet eden birey eklemek için "+ Hane Sakini Ekle" butonuna tıklayınız.',
                                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                                border: Border.all(color: AppColors.accentCyan.withOpacity(0.35)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: AppColors.accentCyan.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          'Hane Sakini #${idx + 1}',
                                          style: const TextStyle(color: AppColors.accentCyan, fontSize: 10, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                      const Spacer(),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
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
                                  Row(
                                    children: [
                                      Expanded(
                                        flex: 6,
                                        child: TextField(
                                          controller: res.nameCtrl,
                                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                                          decoration: InputDecoration(
                                            labelText: 'Ad Soyad *',
                                            labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                                            hintText: 'Örn: Zeynep Yılmaz',
                                            filled: true,
                                            isDense: true,
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            border: const OutlineInputBorder(),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        flex: 4,
                                        child: DropdownButtonFormField<String>(
                                          value: res.relationship,
                                          isDense: true,
                                          dropdownColor: AppColors.card(context),
                                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                                          decoration: InputDecoration(
                                            labelText: 'Yakınlık',
                                            labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                                            filled: true,
                                            isDense: true,
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            border: const OutlineInputBorder(),
                                          ),
                                          items: const [
                                            DropdownMenuItem(value: 'Eşi', child: Text('Eşi')),
                                            DropdownMenuItem(value: 'Çocuğu', child: Text('Çocuğu')),
                                            DropdownMenuItem(value: 'Anne/Baba', child: Text('Anne/Baba')),
                                            DropdownMenuItem(value: 'Kardeşi', child: Text('Kardeşi')),
                                            DropdownMenuItem(value: 'Akrabası', child: Text('Akrabası')),
                                            DropdownMenuItem(value: 'Ev Arkadaşı', child: Text('Ev Arkadaşı')),
                                            DropdownMenuItem(value: 'Diğer', child: Text('Diğer')),
                                          ],
                                          onChanged: (val) {
                                            if (val != null) setDlgState(() => res.relationship = val);
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: res.phoneCtrl,
                                          keyboardType: TextInputType.phone,
                                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                                          decoration: InputDecoration(
                                            labelText: 'Telefon (Opsiyonel)',
                                            labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                                            hintText: 'Örn: 0532 ...',
                                            filled: true,
                                            isDense: true,
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            border: const OutlineInputBorder(),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: TextField(
                                          controller: res.emailCtrl,
                                          keyboardType: TextInputType.emailAddress,
                                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                                          decoration: InputDecoration(
                                            labelText: 'E-posta (Opsiyonel)',
                                            labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                                            hintText: 'Örn: sakin@...',
                                            filled: true,
                                            isDense: true,
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            border: const OutlineInputBorder(),
                                          ),
                                        ),
                                      ),
                                    ],
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

  void _openEditHomeOwner(HomeOwnerItem ho, {int initialTab = 0}) {
    final tenantNameCtrl = TextEditingController(text: ho.tenantFullName ?? '');
    final tenantPhoneCtrl = TextEditingController(text: ho.tenantPhone ?? '');
    final tenantEmailCtrl = TextEditingController(text: ho.tenantEmail ?? '');

    final ownerNameCtrl = TextEditingController(text: ho.ownerFullName);
    final ownerPhoneCtrl = TextEditingController(text: ho.phone);
    final ownerEmailCtrl = TextEditingController(text: ho.email);

    String occupancyMode = ho.isTenantOccupied ? 'TENANT' : (ho.isVacant ? 'VACANT' : 'OWNER');

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          return AppFullscreenPage(
            title: 'Sakin Bilgilerini Düzenle',
            subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Vazgeç'),
                ),
                ElevatedButton(
                  key: const Key('module_save_edit_resident_btn'),
                  onPressed: () async {
                    bool success = false;
                    if (occupancyMode == 'TENANT') {
                      success = await widget.controller.updateHomeOwner(
                        unitId: ho.unitId,
                        fullName: ownerNameCtrl.text.trim(),
                        phone: ownerPhoneCtrl.text.trim(),
                        email: ownerEmailCtrl.text.trim(),
                        tenantFullName: tenantNameCtrl.text.trim().isNotEmpty ? tenantNameCtrl.text.trim() : null,
                        tenantPhone: tenantPhoneCtrl.text.trim().isNotEmpty ? tenantPhoneCtrl.text.trim() : null,
                        tenantEmail: tenantEmailCtrl.text.trim().isNotEmpty ? tenantEmailCtrl.text.trim() : null,
                        isResident: false,
                      );
                    } else if (occupancyMode == 'OWNER') {
                      success = await widget.controller.updateHomeOwner(
                        unitId: ho.unitId,
                        fullName: ownerNameCtrl.text.trim(),
                        phone: ownerPhoneCtrl.text.trim(),
                        email: ownerEmailCtrl.text.trim(),
                        removeTenant: true,
                        isResident: true,
                      );
                    } else {
                      // VACANT
                      success = await widget.controller.updateHomeOwner(
                        unitId: ho.unitId,
                        fullName: ownerNameCtrl.text.trim(),
                        phone: ownerPhoneCtrl.text.trim(),
                        email: ownerEmailCtrl.text.trim(),
                        removeTenant: true,
                        isResident: false,
                      );
                    }

                    if (success && ctx.mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        const SnackBar(content: Text('Sakin bilgileri başarıyla güncellendi.')),
                      );
                    }
                  },
                  child: const Text('Kaydet'),
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
                      border: Border.all(color: AppColors.accentCyan.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'İkamet Durumu / Sakin Tipi (Kat Maliki / Kiracı)',
                          style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<String>(
                            key: const Key('module_edit_occupancy_role_selector'),
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
                                icon: Icon(Icons.meeting_room_outlined, size: 16),
                              ),
                            ],
                            selected: {occupancyMode},
                            onSelectionChanged: (newSelection) {
                              setDlgState(() => occupancyMode = newSelection.first);
                            },
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
                              const Icon(Icons.key, size: 16, color: AppColors.accentCyan),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Kiracı Bilgileri (Fiilen İkamet Eden)',
                                  style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.bold, fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: tenantNameCtrl,
                            decoration: const InputDecoration(labelText: 'Kiracı Ad Soyad', filled: true, border: OutlineInputBorder()),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: tenantPhoneCtrl,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(labelText: 'Kiracı Telefon', filled: true, border: OutlineInputBorder()),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: tenantEmailCtrl,
                            keyboardType: TextInputType.emailAddress,
                            decoration: const InputDecoration(labelText: 'Kiracı E-posta', filled: true, border: OutlineInputBorder()),
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
                            const Icon(Icons.vpn_key_outlined, size: 16, color: AppColors.accentGreen),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Kat Maliki (Ev Sahibi / Mülk Sahibi) Bilgileri',
                                style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.bold, fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: ownerNameCtrl,
                          decoration: const InputDecoration(labelText: 'Kat Maliki Ad Soyad', filled: true, border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: ownerPhoneCtrl,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Kat Maliki Telefon', filled: true, border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: ownerEmailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'Kat Maliki E-posta', filled: true, border: OutlineInputBorder()),
                        ),
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

  void _openAddHouseholdMember(HomeOwnerItem ho) {
    final nameCtrl = TextEditingController();
    final relationCtrl = TextEditingController(text: 'Eşi');
    final phoneCtrl = TextEditingController();
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
                OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
                ElevatedButton(
                  key: const Key('module_save_household_btn'),
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    final success = await widget.controller.addHouseholdMember(
                      unitId: ho.unitId,
                      block: ho.block,
                      unitNo: ho.unitNo,
                      fullName: name,
                      relationship: relationCtrl.text.trim(),
                      phone: phoneCtrl.text.trim(),
                      email: 'sakin${DateTime.now().millisecondsSinceEpoch}@example.com',
                    );
                    if (setAsPrimary && success) {
                      widget.controller.setPrimaryResponsibleResident(
                        unitId: ho.unitId,
                        residentName: name,
                        role: 'RESIDENT',
                        phone: phoneCtrl.text.trim(),
                      );
                    }
                    if (success && ctx.mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        const SnackBar(content: Text('Hane sakini başarıyla eklendi.')),
                      );
                    }
                  },
                  child: const Text('Ekle'),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  TextField(
                    key: const Key('module_member_name_input'),
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Ad Soyad *', filled: true, border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('module_member_relation_input'),
                    controller: relationCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Yakınlık Derecesi (Eşi, Çocuğu, vb.)',
                      filled: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('module_member_phone_input'),
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Telefon', filled: true, border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  Material(
                    color: Colors.transparent,
                    child: SwitchListTile(
                      key: const Key('module_member_set_primary_switch'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Bu kişiyi dairenin aktif sorumlusu yap', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      subtitle: const Text('Bildirimler ve birincil muhataplık bu kişiye yönlendirilir', style: TextStyle(fontSize: 11)),
                      value: setAsPrimary,
                      activeThumbColor: AppColors.accentPurple,
                      onChanged: (val) {
                        setDlgState(() => setAsPrimary = val);
                      },
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

  void _openEditHouseholdMember(HomeOwnerItem ho, UnitResidentMember member) {
    final nameCtrl = TextEditingController(text: member.fullName);
    final relationCtrl = TextEditingController(text: member.relationship);
    final phoneCtrl = TextEditingController(text: member.phone);

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: 'Hane Sakinini Düzenle',
        subtitle: '${ho.block} Blok Daire ${ho.unitNo}',
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final success = await widget.controller.updateHouseholdMember(
                  unitId: ho.unitId,
                  residentId: member.id,
                  fullName: name,
                  relationship: relationCtrl.text.trim(),
                  phone: phoneCtrl.text.trim(),
                  email: member.email.isNotEmpty ? member.email : 'sakin@example.com',
                );
                if (success && ctx.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(content: Text('Hane sakini bilgileri güncellendi.')),
                  );
                }
              },
              child: const Text('Kaydet'),
            ),
          ],
        ),
        child: Column(
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Ad Soyad')),
            const SizedBox(height: 12),
            TextField(controller: relationCtrl, decoration: const InputDecoration(labelText: 'Yakınlık Derecesi')),
            const SizedBox(height: 12),
            TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Telefon')),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteHouseholdMember(HomeOwnerItem ho, UnitResidentMember member) async {
    final confirmed = await AppFullscreenPage.pushConfirmation(
      context: context,
      title: 'Hane Sakinini Sil',
      message: '${member.fullName} isimli sakin kaydını silmek istediğinize emin misiniz?',
      confirmLabel: 'Evet, Sil',
    );
    if (confirmed == true) {
      await widget.controller.deleteHouseholdMember(unitId: ho.unitId, residentId: member.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${member.fullName} kaydı silindi.')),
        );
      }
    }
  }

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
            OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
            ElevatedButton(
              key: const Key('module_confirm_move_out_btn'),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentOrange, foregroundColor: Colors.white),
              onPressed: () async {
                final success = await widget.controller.moveOutResident(ho.unitId, notes: notesCtrl.text.trim());
                if (success && ctx.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(content: Text('Sakin tahliye işlemi kaydedildi.')),
                  );
                }
              },
              child: const Text('Tahliyeyi Onayla'),
            ),
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
                OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
                ElevatedButton(
                  key: const Key('module_confirm_move_in_btn'),
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    final success = await widget.controller.moveInResident(
                      ho.unitId,
                      role: selectedRole,
                      fullName: name,
                      phone: phoneCtrl.text.trim(),
                      email: emailCtrl.text.trim(),
                    );
                    if (success && ctx.mounted) {
                      Navigator.pop(ctx);
                      final roleLabel = selectedRole == 'OWNER' ? 'Kat Maliki' : 'Kiracı';
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(content: Text('Yeni $roleLabel girişi başarıyla yapıldı.')),
                      );
                    }
                  },
                  child: const Text('Girişi Tamamla'),
                ),
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
                    child: SegmentedButton<String>(
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
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: selectedRole == 'OWNER' ? 'Kat Maliki Ad Soyad *' : 'Kiracı Ad Soyad *',
                      filled: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Telefon', filled: true, border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: emailCtrl,
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
                  child: const Text('Kapat'),
                ),
              ],
            ),
            child: isLoading
                ? const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
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
              child: const Text('Kapat'),
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
                  const Text('Daireye Özel Tahsisli Sanal IBAN', style: TextStyle(color: AppColors.accentCyan, fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 8),
                  Text(
                    widget.controller.activeUnit.virtualIban ?? 'TR91 0020 5000 0986 3791 6000 01',
                    style: TextStyle(color: AppColors.textPrimary(ctx), fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text('Bu IBAN numarasına gönderilen tüm FAST/Havale ödemeleri %100 doğrulukla doğrudan bu dairenin aidat borcuna mahsup edilir.', style: TextStyle(color: AppColors.textSecondary(ctx), fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
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
      await widget.controller.deleteHomeOwner(unitId: ho.unitId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kat maliki başarıyla silindi.')),
        );
      }
    }
  }
}

class _PendingResidentEntry {
  final TextEditingController nameCtrl;
  final TextEditingController phoneCtrl;
  final TextEditingController emailCtrl;
  String relationship;

  _PendingResidentEntry({
    String? name,
    String? phone,
    String? email,
  })  : nameCtrl = TextEditingController(text: name ?? ''),
        phoneCtrl = TextEditingController(text: phone ?? ''),
        emailCtrl = TextEditingController(text: email ?? ''),
        relationship = 'Eşi';

  void dispose() {
    nameCtrl.dispose();
    phoneCtrl.dispose();
    emailCtrl.dispose();
  }
}

