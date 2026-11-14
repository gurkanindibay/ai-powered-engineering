import '../components/sp_effective_date_field.dart';
import '../residents/responsible_contact_selection.dart';
import '../design_system/sp_page_header.dart';
import '../payments/finance_hub_page.dart';
import '../../testing/test_id.dart';
import 'dart:async';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../components/step_up_prompt.dart';
import '../../l10n/app_strings.dart';
import '../../domain/models/auth_models.dart';
import '../../domain/models/dues_models.dart';
import '../../domain/models/unit_state.dart';
import '../components/app_fullscreen_page.dart';
import '../components/dues_management_view.dart';
import '../components/hero_balance_card.dart';
import '../components/manager_cockpit_view.dart';
import '../components/announcement_composer_page.dart';
import '../components/payment_checkout_dialog.dart';
import '../components/profile_role_sheet.dart';
import '../components/resident_actions_row.dart';
import '../components/saas_admin_view.dart';
import '../components/unit_matching_criteria_card.dart';
import '../components/virtual_iban_card.dart';
import '../components/house_types_modal.dart';
import '../residents/owners_residents_module_page.dart';
import '../theme/app_theme.dart';
import '../design_system/sp_skeleton.dart';
import 'dashboard_controller.dart';

import '../design_system/money_formatter.dart';
import '../design_system/sp_feedback.dart';
import '../components/sp_dialog_pages.dart';
import '../payments/resident_statement_page.dart';
import '../design_system/sp_typography.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_tone.dart';
import '../residents/resident_directory.dart';
import '../design_system/sp_filter_chip.dart';
import '../design_system/sp_clipboard.dart';
import '../residents/activation_status.dart';
import '../../domain/models/household_relationship.dart';
import '../residents/household_relationship_items.dart';
import '../../domain/validation/person_validators.dart';
class DashboardScreen extends StatefulWidget {
  final DashboardController controller;

  /// Tab shown when the screen is driven by the app router (URL per tab).
  /// When null the screen keeps its own tab state (widget tests, embedding).
  final int? selectedTab;
  final ValueChanged<int>? onTabSelected;

  const DashboardScreen({
    super.key,
    required this.controller,
    this.selectedTab,
    this.onTabSelected,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _localTabIndex = 0;
  Object? _lastSessionShape;

  int get _selectedTabIndex => widget.selectedTab ?? _localTabIndex;

  void _selectTab(int index) {
    if (widget.onTabSelected != null) {
      widget.onTabSelected!(index);
    } else {
      setState(() => _localTabIndex = index);
    }
  }
  String _homeOwnerSearchQuery = '';
  String _homeOwnerBlockFilter = 'ALL';
  String _homeOwnerOccupancyFilter = 'ALL';
  final Map<String, int> _unitCardTabs = {};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerUpdate);
    if (widget.controller.userRole == UserRole.saasAdmin) {
      widget.controller.fetchSaasSites();
    } else {
      widget.controller.fetchResidentDashboard();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (widget.controller.userRole == UserRole.saasAdmin) {
          widget.controller.fetchSaasSites();
        } else {
          widget.controller.fetchHomeOwners();
        }
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdate);
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    // Changing the manager path changes the tab set; go back to Home explicitly
    // instead of keeping an index that now means a different tab.
    final shape = (widget.controller.userRole, widget.controller.siteAdminPath);
    if (_lastSessionShape != null && _lastSessionShape != shape && widget.onTabSelected == null) {
      _localTabIndex = 0;
    }
    _lastSessionShape = shape;
    setState(() {});

    // Check for auth message
    if (widget.controller.authMessage != null) {
      final message = widget.controller.authMessage!;
      SpToast.show(context, message, inferToastKind(message: message));
      widget.controller.clearAuthMessage();
    }

    // Check for approval success info
    if (widget.controller.approvalSuccessInfo != null) {
      final info = widget.controller.approvalSuccessInfo!;
      widget.controller.clearApprovalSuccess();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showApprovalSuccessDialog(info);
      });
    }

    // Check for provisioned SaaS site credentials
    if (widget.controller.provisionedCredentials != null) {
      final creds = widget.controller.provisionedCredentials!;
      widget.controller.clearProvisionedCredentials();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showSiteProvisionedDialog(creds);
      });
    }

    // Check for provisioned Home Owner credentials
    if (widget.controller.provisionedHomeOwner != null) {
      final homeOwner = widget.controller.provisionedHomeOwner!;
      widget.controller.clearProvisionedHomeOwner();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showHomeOwnerProvisionedDialog(homeOwner);
      });
    }

    // Check for unit invite info
    if (widget.controller.unitInviteInfo != null) {
      final invite = widget.controller.unitInviteInfo!;
      widget.controller.clearUnitInviteInfo();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showInviteDialog(invite);
      });
    }
  }

  /// Navigation destinations for the current role. Profile is not a tab: it
  /// lives behind the avatar in the app bar.
  List<_NavDestination> _destinations(bool isHomeRole) {
    final session = widget.controller.userSession;
    final isManagerCockpit = widget.controller.userRole == UserRole.siteManager &&
        widget.controller.siteAdminPath == SiteAdminActivePath.managerCockpit;
    final unmatched = widget.controller.unmatchedBankCount;
    return [
      const _NavDestination(
        id: 'nav_home',
        icon: Icons.home_outlined,
        activeIcon: Icons.home_rounded,
        label: 'Ana Sayfa',
      ),
      if (isManagerCockpit && session.hasPermission('LEDGER_MANAGE_ALL'))
        _NavDestination(
          id: 'nav_dues',
          icon: Icons.payments_outlined,
          activeIcon: Icons.payments_rounded,
          label: 'Aidat Yönetimi',
          badgeCount: unmatched,
          badgeSemantics: unmatched > 0 ? '$unmatched eşleşmemiş banka hareketi' : null,
        ),
      _NavDestination(
        id: isHomeRole || !isManagerCockpit && session.role == UserRole.siteManager
            ? 'nav_my_flat'
            : (session.role == UserRole.saasAdmin ? 'nav_sites' : 'nav_residents'),
        icon: isHomeRole || session.role == UserRole.siteManager && !isManagerCockpit
            ? Icons.door_front_door_outlined
            : (session.role == UserRole.siteManager ? Icons.group_outlined : Icons.domain_outlined),
        activeIcon: isHomeRole || session.role == UserRole.siteManager && !isManagerCockpit
            ? Icons.door_front_door_rounded
            : (session.role == UserRole.siteManager ? Icons.group_rounded : Icons.domain_rounded),
        label: isHomeRole || session.role == UserRole.siteManager && !isManagerCockpit
            ? 'Dairem'
            : (session.role == UserRole.saasAdmin ? 'Siteler' : 'Sakinler & Malikler'),
      ),
    ];
  }

  Widget _navIcon(_NavDestination d, {required bool active}) {
    final icon = Icon(active ? d.activeIcon : d.icon);
    final withBadge = d.badgeCount > 0
        ? Badge(
            label: Text('${d.badgeCount}'),
            backgroundColor: AppColors.warningFill,
            textColor: AppColors.onFill,
            child: icon,
          )
        : icon;
    // A bar shows either the active or the inactive icon, so each tab has one id node.
    return testId(d.id, withBadge);
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final session = widget.controller.userSession;
    final initial = session.fullName.trim().isEmpty ? '?' : session.fullName.trim().substring(0, 1).toUpperCase();
    return AppBar(
      titleSpacing: AppSpacing.lg,
      title: Row(
        children: [
          ExcludeSemantics(
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.accentCyan.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.domain_rounded, color: AppColors.accentCyan, size: 20),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            'SitePulse',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              letterSpacing: -0.5,
              color: AppColors.textPrimary(context),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.card(context),
                borderRadius: BorderRadius.circular(AppRadius.chip),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Text(
                session.role.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context), fontWeight: FontWeight.w500),
              ),
            ),
          ),
          if (session.role == UserRole.siteManager && session.siteName.isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Tooltip(
                message: session.siteName,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.accentCyan.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                    border: Border.all(color: AppColors.accentCyan.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const ExcludeSemantics(child: Icon(Icons.apartment, size: 14, color: AppColors.accentCyan)),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          session.siteName,
                          style: TextStyle(fontSize: 12, color: AppColors.primaryText(context), fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: testId('btn_open_profile', IconButton(
            tooltip: 'Profil, tema ve çıkış',
            onPressed: () => _openProfileSheet(context),
            icon: CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.primaryFill,
              child: Text(
                initial,
                style: const TextStyle(color: AppColors.onFill, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
          )),
        ),
      ],
    );
  }

  /// Page-level offline state (inline banner, not a snackbar).
  Widget _buildOfflineBanner() {
    return testId('offline_banner', Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.accentOrange.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: AppColors.accentOrange.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_off_rounded, color: AppColors.warningText(context), size: 20),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                'Çevrimdışısınız. Gösterilen bilgiler son eşitlemeden (${widget.controller.lastSyncTime}); '
                'bağlantı gelince yenilenecek.',
                style: TextStyle(fontSize: 14, color: AppColors.textPrimary(context)),
              ),
            ),
          ],
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.controller.userSession;
    final isHomeRole = session.role == UserRole.homeOwner || session.role == UserRole.homeResident;
    final destinations = _destinations(isHomeRole);
    final safeIndex = _selectedTabIndex >= destinations.length ? 0 : _selectedTabIndex;
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.expanded;

    final content = RefreshIndicator(
      onRefresh: () async {
        if (widget.controller.userRole == UserRole.saasAdmin) {
          await widget.controller.fetchSaasSites();
        } else {
          await widget.controller.fetchResidentDashboard();
          await widget.controller.fetchHomeOwners();
        }
      },
      color: AppColors.accentCyan,
      child: SingleChildScrollView(
        // Resets scroll position per tab; not an automation target. testid-lint: ignore
        key: ValueKey('tab_scroll_$safeIndex'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.symmetric(
          horizontal: wide ? AppSpacing.xl : AppSpacing.screenGutter,
          vertical: AppSpacing.md,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppBreakpoints.maxContentWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.controller.isOffline) _buildOfflineBanner(),
                if (widget.controller.userRole == UserRole.siteManager)
                  _buildSiteManagerPathSwitcher(),
                _buildCurrentTabContent(isHomeRole),
              ],
            ),
          ),
        ),
      ),
    );

    return Scaffold(
      appBar: _buildAppBar(context),
      body: SafeArea(
        child: wide
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: safeIndex,
                    onDestinationSelected: _selectTab,
                    labelType: NavigationRailLabelType.all,
                    minWidth: 88,
                    indicatorColor: AppColors.accentCyan.withValues(alpha: 0.18),
                    destinations: [
                      for (final d in destinations)
                        NavigationRailDestination(
                          icon: _navIcon(d, active: false),
                          selectedIcon: _navIcon(d, active: true),
                          label: Text(d.label),
                        ),
                    ],
                  ),
                  VerticalDivider(width: 1, thickness: 1, color: AppColors.border(context)),
                  Expanded(child: content),
                ],
              )
            : content,
      ),
      bottomNavigationBar: wide
          ? null
          : Container(
              decoration: BoxDecoration(
                color: AppColors.surface(context),
                border: Border(top: BorderSide(color: AppColors.border(context), width: 1)),
              ),
              child: BottomNavigationBar(
                currentIndex: safeIndex,
                onTap: _selectTab,
                backgroundColor: Colors.transparent,
                selectedItemColor: AppColors.isDark(context) ? AppColors.primaryTextDark : AppColors.lightTextPrimary,
                unselectedItemColor: AppColors.textSecondary(context),
                selectedFontSize: 12,
                unselectedFontSize: 12,
                selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
                type: BottomNavigationBarType.fixed,
                elevation: 0,
                items: [
                  for (final d in destinations)
                    BottomNavigationBarItem(
                      icon: _navIcon(d, active: false),
                      activeIcon: _navIcon(d, active: true),
                      label: d.label,
                      tooltip: d.badgeSemantics ?? d.label,
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildSiteManagerPathSwitcher() {
    final currentPath = widget.controller.siteAdminPath;
    final siteName = widget.controller.userSession.siteName;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        children: [
          Expanded(
            child: testId('role_path_manager_cockpit', _PathSegment(
              selected: currentPath == SiteAdminActivePath.managerCockpit,
              icon: Icons.apartment_rounded,
              label: '$siteName Yönetimi',
              semanticsLabel: 'Site yönetimi: $siteName',
              onTap: () => widget.controller.setSiteAdminPath(SiteAdminActivePath.managerCockpit),
            )),
          ),
          Expanded(
            child: testId('role_path_my_flat', _PathSegment(
              selected: currentPath == SiteAdminActivePath.myFlatOwner,
              icon: Icons.door_front_door_rounded,
              label: 'Kendi Dairem (Kat Maliki)',
              semanticsLabel: 'Kendi dairem, kat maliki görünümü',
              onTap: () => widget.controller.setSiteAdminPath(SiteAdminActivePath.myFlatOwner),
            )),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentTabContent(bool isHomeRole) {
    final isManagerCockpit = widget.controller.userRole == UserRole.siteManager &&
        widget.controller.siteAdminPath == SiteAdminActivePath.managerCockpit;

    if (isManagerCockpit) {
      if (_selectedTabIndex == 1) {
        return DuesManagementView(controller: widget.controller);
      } else if (_selectedTabIndex == 2) {
        return _buildSecondaryTabContent(isHomeRole);
      }
    } else {
      if (_selectedTabIndex == 1) {
        return _buildSecondaryTabContent(isHomeRole);
      }
    }

    // Tab 0: Main Screen according to Role
    switch (widget.controller.userRole) {
      case UserRole.homeOwner:
      case UserRole.homeResident:
        return _buildResidentHome(isOwner: widget.controller.userRole == UserRole.homeOwner);
      case UserRole.siteManager:
        final currentPath = widget.controller.siteAdminPath;
        if (currentPath == SiteAdminActivePath.myFlatOwner) {
          // A manager viewing their own flat sees exactly the owner's home.
          return _buildResidentHome(isOwner: true);
        } else {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ManagerCockpitView(
                controller: widget.controller,
                onAddResidentTap: _showAddResidentDialog,
                onInviteResidentsTap: widget.controller.generateSiteInviteLink,
                onCreateAnnouncementTap: _showCreateAnnouncementPage,
                onManageHouseTypesTap: _showManageHouseTypesDialog,
                onManageHomeOwnersTap: () => _selectTab(2),
                onNavigateToDuesTab: () => _selectTab(1),
              ),
            ],
          );
        }
      case UserRole.auditor:
        return const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SpPageHeader(title: 'Finans Masası', icon: Icons.account_balance_outlined),
            SizedBox(height: AppSpacing.lg),
            FinanceHubView(readOnly: true),
          ],
        );
      case UserRole.saasAdmin:
        return SaasAdminView(
          controller: widget.controller,
          onAddSiteTap: _showAddSiteDialog,
          onEditSiteTap: _showEditSiteDialog,
          onDeleteSiteTap: _confirmDeleteSite,
          onResetPasswordTap: _confirmResetAdminPassword,
        );
    }
  }

  /// Resident / owner home: balance and how to pay first, then activity and household.
  /// Wide screens (>= 840 dp) use two columns so the page is not one stretched phone column.
  Widget _buildResidentHome({required bool isOwner}) {
    final hasNoUnit = widget.controller.activeUnit.id.isEmpty;
    if (hasNoUnit) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SpPageHeader(
            title: isOwner ? 'Dairem' : 'Sakin Paneli',
            icon: Icons.home_outlined,
            subtitle: widget.controller.userSession.siteName,
          ),
          const SizedBox(height: AppSpacing.lg),
          _buildNoHomeownerGuidanceCard(),
          const SizedBox(height: 18),
          _buildAccountActivitySection(),
        ],
      );
    }
    final dues = widget.controller.primaryDues;
    final unit = widget.controller.activeUnit;
    final primary = <Widget>[
      HeroBalanceCard(
        dues: dues,
        siteName: unit.siteName,
        unitName: '${unit.block} Blok D:${unit.unitNo}',
        isOffline: widget.controller.isOffline,
        advancePayment: unit.advancePayment,
        virtualIban: unit.virtualIban,
        capitalDues: isOwner ? widget.controller.capitalDues : const [],
        onPayPressed: () => _showPaymentDialog(dues),
        onDetailPressed: () => _showDuesDetailDialog(dues),
      ),
      const SizedBox(height: 16),
      ResidentActionsRow(
        isOwner: isOwner,
        onReceiptsTap: _showReceiptsDialog,
        onInviteTap: widget.controller.generateUnitInviteLink,
        onRequestsTap: _showIssueReportDialog,
        onAnnouncementsTap: _showAnnouncementsDialog,
      ),
    ];
    final secondary = <Widget>[
      _buildStatementEntryCard(unit.id, '${unit.siteName} • ${unit.block} Blok D:${unit.unitNo}'),
      const SizedBox(height: 16),
      _buildAccountActivitySection(),
      const SizedBox(height: 16),
      _buildMyUnitHouseholdCard(),
      const SizedBox(height: 16),
      UnitMatchingCriteriaCard(controller: widget.controller),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= AppBreakpoints.expanded) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SpPageHeader(
                title: isOwner ? 'Dairem' : 'Sakin Paneli',
                icon: Icons.home_outlined,
                subtitle: widget.controller.userSession.siteName,
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: primary)),
                  const SizedBox(width: AppSpacing.xl),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: secondary)),
                ],
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SpPageHeader(
              title: isOwner ? 'Dairem' : 'Sakin Paneli',
              icon: Icons.home_outlined,
              subtitle: widget.controller.userSession.siteName,
            ),
            const SizedBox(height: AppSpacing.lg),
            ...primary,
            const SizedBox(height: 18),
            ...secondary,
          ],
        );
      },
    );
  }

  Widget _buildNoHomeownerGuidanceCard() {
    return const SpGuidanceCard(
      icon: Icons.home_work_outlined,
      tone: SpTone.warning,
      prominent: true,
      tonedBorder: true,
      title: 'Tanımlı Daireniz Bulunmuyor',
      message: 'SitePulse hesabınıza henüz bir daire kaydı atanmamıştır. Site yöneticinizden WhatsApp/SMS davet bağlantısı alarak veya bina yönetiminizle iletişime geçerek dairenizi tanımlatabilirsiniz.',
      tip: 'Daireniz tanımlandığında adınıza tahakkuk eden aidatlar, Sanal IBAN ve hesap hareketleriniz burada listelenir.',
    );
  }

  Widget _buildSecondaryTabContent(bool isHomeRole) {
    if (isHomeRole) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SpPageHeader(title: 'Dairem & Hane Bilgileri', icon: Icons.home_outlined),
          const SizedBox(height: AppSpacing.lg),
          _buildMyUnitHouseholdCard(),
          const SizedBox(height: 16),
          VirtualIbanCard(
            iban: widget.controller.activeUnit.virtualIban ?? 'TR64 0020 5000 0986 3791 6000 14',
            unitDesc: '${widget.controller.activeUnit.block} Blok D:${widget.controller.activeUnit.unitNo}',
          ),
          const SizedBox(height: 16),
          UnitMatchingCriteriaCard(controller: widget.controller),
        ],
      );
    } else if (widget.controller.userRole == UserRole.siteManager) {
      final currentPath = widget.controller.siteAdminPath;
      if (currentPath == SiteAdminActivePath.myFlatOwner) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SpPageHeader(title: 'Dairem & Hane Bilgileri', icon: Icons.home_outlined),
            const SizedBox(height: AppSpacing.lg),
            _buildMyUnitHouseholdCard(),
            const SizedBox(height: 16),
            VirtualIbanCard(
              iban: widget.controller.activeUnit.virtualIban ?? 'TR91 0020 5000 0986 3791 6000 01',
              unitDesc: '${widget.controller.activeUnit.block} Blok D:${widget.controller.activeUnit.unitNo}',
            ),
            const SizedBox(height: 16),
            UnitMatchingCriteriaCard(controller: widget.controller),
          ],
        );
      } else {
        return _buildHomeOwnersManagementView();
      }
    } else {
      return SaasAdminView(
        controller: widget.controller,
        onAddSiteTap: _showAddSiteDialog,
        onEditSiteTap: _showEditSiteDialog,
        onDeleteSiteTap: _confirmDeleteSite,
        onResetPasswordTap: _confirmResetAdminPassword,
      );
    }
  }

  Widget _buildHomeOwnersManagementView() {
    final homeOwners = widget.controller.homeOwners;
    final isLoading = widget.controller.isLoadingHomeOwners;

    final availableBlocks = distinctBlocks(widget.controller.blocks);
    final stats = ResidentOccupancyStats.from(homeOwners);

    final filtered = homeOwners
        .where((ho) => matchesResidentFilters(
              ho,
              blockFilter: _homeOwnerBlockFilter,
              occupancyFilter: _homeOwnerOccupancyFilter,
              query: _homeOwnerSearchQuery,
            ))
        .toList();

    final totalCount = widget.controller.collectionSummary.totalUnitsCount > 0
        ? widget.controller.collectionSummary.totalUnitsCount
        : homeOwners.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [

        SpPageHeader(
          title: 'Kat Malikleri & Sakinler Yönetimi',
          icon: Icons.people_alt_outlined,
          subtitle:
              '${widget.controller.userSession.siteName} • Toplam $totalCount bağımsız bölüm (${homeOwners.length} kayıtlı)',
          actions: [
            testId(
              'add_resident_btn',
              ElevatedButton.icon(
                key: const Key('add_resident_btn'),
                onPressed: _showAddResidentDialog,
                icon: const Icon(Icons.person_add_outlined, size: 15),
                label: const Text('Yeni Sakin Ekle', style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryFill,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: const Size(0, 30),
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _showManageHouseTypesDialog,
              icon: const Icon(Icons.home_work_outlined, size: 15),
              label: const Text('Konut Tipleri & Tarifeler', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accentPurple,
                side: const BorderSide(color: AppColors.accentPurple),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: const Size(0, 30),
              ),
            ),
            testId(
              'open_owners_residents_module',
              OutlinedButton.icon(
                key: const Key('open_owners_residents_module'),
                onPressed: () {
                  AppFullscreenPage.push(
                    context: context,
                    builder: (_) => OwnersResidentsModulePage(controller: widget.controller),
                  );
                },
                icon: const Icon(Icons.fullscreen, size: 16),
                label: const Text('Tam Ekran Modu', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accentCyan,
                  side: const BorderSide(color: AppColors.accentCyan),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: const Size(0, 30),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),

        // Live KPI Metrics Bar
        ResidentSummary(stats: stats, dense: true),

        const SizedBox(height: 8),

        // Search & Filter
        TextField(
          onChanged: (val) {
            setState(() {
              _homeOwnerSearchQuery = val.trim();
            });
          },
          decoration: InputDecoration(
            hintText: 'İsim, daire no, telefon veya e-posta ile ara...',
            hintStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: _homeOwnerSearchQuery.isNotEmpty
                ? IconButton(
                    tooltip: 'Aramayı temizle',
                    icon: const Icon(Icons.clear, size: 16),
                    onPressed: () {
                      setState(() {
                        _homeOwnerSearchQuery = '';
                      });
                    },
                  )
                : null,
            filled: true,
            fillColor: AppColors.surface(context),
            contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.border(context)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.border(context)),
            ),
          ),
        ),

        const SizedBox(height: 6),

        // Occupancy status and Block filter chips in one scrollable row
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildOccupancyFilterChip('Tümü (${stats.totalUnits})', OccupancyFilter.all),
              const SizedBox(width: 6),
              _buildOccupancyFilterChip('${AppStrings.tenantOccupied} (${stats.tenantCount})', OccupancyFilter.tenant),
              const SizedBox(width: 6),
              _buildOccupancyFilterChip('${AppStrings.ownerOccupied} (${stats.ownerCount})', OccupancyFilter.owner),
              const SizedBox(width: 6),
              _buildOccupancyFilterChip('${AppStrings.vacantUnit} (${stats.vacantCount})', OccupancyFilter.vacant),
              const SizedBox(width: 8),
              Container(width: 1, height: 16, color: AppColors.border(context)),
              const SizedBox(width: 8),
              _buildBlockFilterChip('Tümü', allBlocksFilter),
              ...availableBlocks.map((b) => _buildBlockFilterChip(b, b)),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // List of residents
        if (isLoading)
          const SpSkeletonList()
        else if (filtered.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Column(
              children: [
                Icon(Icons.person_off_outlined, size: 40, color: AppColors.textSecondary(context)),
                const SizedBox(height: 8),
                Text(
                  _homeOwnerSearchQuery.isNotEmpty ? 'Aramaya Uygun Sakin Bulunamadı' : 'Kayıtlı Kat Maliki veya Sakin Yok',
                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  _homeOwnerSearchQuery.isNotEmpty
                      ? 'Farklı bir arama terimi deneyebilir veya filtreyi temizleyebilirsiniz.'
                      : '"Yeni Sakin Ekle" butonu ile daireye sakin ekleyebilirsiniz.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                ),
              ],
            ),
          )
        else
          ...filtered.map((ho) => _buildHomeOwnerCard(ho)),
      ],
    );
  }

  Widget _buildOccupancyFilterChip(String label, String code) {
    return SpFilterChip(
      label: label,
      selected: _homeOwnerOccupancyFilter == code,
      onSelected: () => setState(() => _homeOwnerOccupancyFilter = code),
      id: 'directory_occupancy_filter_$code',
    );
  }

  Widget _buildBlockFilterChip(String label, String code) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: SpFilterChip(
        label: label,
        selected: _homeOwnerBlockFilter == code,
        onSelected: () => setState(() => _homeOwnerBlockFilter = code),
        id: 'directory_block_filter_$code',
      ),
    );
  }

  Widget _buildHomeOwnerCard(HomeOwnerItem ho) {
    final cleanBlock = ho.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();
    final badgeLabel = ho.unitNo > 0
        ? (cleanBlock.isNotEmpty ? '$cleanBlock${ho.unitNo}' : '${ho.unitNo}')
        : (cleanBlock.isNotEmpty ? cleanBlock : 'KS');

    final isTenant = ho.occupancyStatus == 'TENANT_OCCUPIED' || (ho.tenantFullName != null && ho.tenantFullName!.isNotEmpty);
    final isVacant = ho.occupancyStatus == 'VACANT';

    final activeResidentName = isTenant
        ? (ho.tenantFullName ?? 'Kiracı')
        : (isVacant ? 'Boş Daire' : ho.ownerFullName);

    final statusLabel = isTenant
        ? 'Kiracılı Daire'
        : (isVacant ? 'Boş Daire' : 'Kat Maliki İkameti');

    final statusColor = isTenant
        ? AppColors.accentGreen
        : (isVacant ? AppColors.accentOrange : AppColors.accentCyan);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
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
          // -------------------------------------------------------------
          // 1. UNIT (BAĞIMSIZ BÖLÜM) HEADER - PRIMARY VISUAL FOCUS
          // -------------------------------------------------------------
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.card(context),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              border: Border(bottom: BorderSide(color: AppColors.border(context).withOpacity(0.6))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Unit Badge / Door Avatar
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: statusColor.withOpacity(0.3)),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.door_front_door_outlined, size: 15, color: statusColor),
                      const SizedBox(height: 1),
                      Text(
                        badgeLabel,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Unit Title and Specs
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                              ho.unitNo > 0
                                  ? '${ho.block} • Daire ${ho.unitNo}'
                                  : '${ho.block} • Daire Atanmadı',
                              style: TextStyle(
                                color: AppColors.textPrimary(context),
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                          ),
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
                // Monthly Dues summary
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
                      'Aidat (İşletme)',
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
                    ],
                  ],
                ),
              ],
              ),
              const SizedBox(height: AppSpacing.sm),
              testId('unit_actions_${ho.unitId}', TextButton.icon(
                key: Key('unit_actions_${ho.unitId}'),
                onPressed: () => _showUnitActions(ho),
                icon: const Icon(Icons.more_horiz),
                label: const Text('Daire İşlemleri'),
              )),
              ],
            ),
          ),

          // -------------------------------------------------------------
          // 2. PEOPLE UNDER THE UNIT (İKAMET & KİŞİ BİLGİLERİ HİYERARŞİSİ)
          // -------------------------------------------------------------
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ACTIVE RESPONSIBLE RESIDENT SPOTLIGHT (BİRİNCİL MUHATAP)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
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
                        'Muhatap: ${ho.activeResponsibleResidentName}',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 14,
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
                              Flexible(child: Text(
                                ho.activeResponsibleEmail.isNotEmpty ? ho.activeResponsibleEmail : 'E-posta Yok',
                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                              )),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                Builder(
                  builder: (context) {
                    final cardTab = _unitCardTabs[ho.unitId] ?? 0;

                    if (isTenant) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      // Dual Tabs for Rented Unit: Sakinler (Kiracı & Hane) vs Kat Maliki (Ev Sahibi)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: AppColors.background(context),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border(context).withOpacity(0.6)),
                        ),
                        padding: const EdgeInsets.all(3),
                        child: Row(
                          children: [
                            Expanded(
                              child: testId('tab_residents_${ho.unitId}', InkWell(
                                key: Key('tab_residents_${ho.unitId}'),
                                onTap: () => setState(() => _unitCardTabs[ho.unitId] = 0),
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
                                          'Sakinler (${ho.tenantFullName ?? 'Kiracı'})',
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
                              child: testId('tab_owner_${ho.unitId}', InkWell(
                                key: Key('tab_owner_${ho.unitId}'),
                                onTap: () => setState(() => _unitCardTabs[ho.unitId] = 1),
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

                      if (cardTab == 0) ...[
                        // SAKİNLER TAB: Kiracı (Primary Tenant)
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
                                  const Icon(Icons.key, size: 15, color: AppColors.accentGreen),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Fiilen İkamet Eden Kiracı (Birincil Muhatap)',
                                      style: TextStyle(
                                        color: AppColors.successText(context),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: AppColors.accentGreen.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'Kiracı',
                                      style: TextStyle(
                                        color: AppColors.successText(context),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),

                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          activeResidentName,
                                          style: TextStyle(
                                            color: AppColors.textPrimary(context),
                                            fontSize: 14,
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
                                                  ho.tenantPhone != null && ho.tenantPhone!.isNotEmpty ? ho.tenantPhone! : (ho.phone.isNotEmpty ? ho.phone : 'Telefon Yok'),
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
                                                  ho.tenantEmail != null && ho.tenantEmail!.isNotEmpty ? ho.tenantEmail! : (ho.email.isNotEmpty ? ho.email : 'E-posta Yok'),
                                                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  testId('edit_residents_${ho.unitId}', OutlinedButton.icon(
                                    key: Key('edit_residents_${ho.unitId}'),
                                    onPressed: () => _showEditHomeOwnerDialog(ho, initialTab: 0),
                                    icon: const Icon(Icons.edit_outlined, size: 12),
                                    label: const Text('Düzenle', style: TextStyle(fontSize: 12)),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.accentGreen,
                                      side: const BorderSide(color: AppColors.accentGreen),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      minimumSize: const Size(0, 28),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  )),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),

                        // HANE SAKİNLERİ (CO-RESIDENTS) CONTAINER
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
                                      style: TextStyle(
                                        color: AppColors.textPrimary(context),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  testId('add_resident_to_${ho.unitId}', TextButton.icon(
                                    key: Key('add_resident_to_${ho.unitId}'),
                                    onPressed: () => _showAddHouseholdMemberDialog(ho),
                                    icon: const Icon(Icons.person_add_alt_1, size: 14, color: AppColors.accentPurple),
                                    label: const Text('+ Hane Sakini Ekle', style: TextStyle(color: AppColors.accentPurple, fontSize: 12, fontWeight: FontWeight.bold)),
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
                                          '${m.fullName} • ${HouseholdRelationship.labelFor(m.relationship)}${m.phone.isNotEmpty ? ' • ${m.phone}' : ''}',
                                          style: TextStyle(
                                            color: AppColors.textSecondary(context),
                                            fontSize: 12,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      testId('edit_member_${m.id.isNotEmpty ? m.id : m.fullName}', IconButton(
                                        key: Key('edit_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                        icon: const Icon(Icons.edit_outlined, size: 14, color: AppColors.accentCyan),
                                        tooltip: '${m.fullName} bilgilerini düzenle',
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () => _showEditHouseholdMemberDialog(ho, m),
                                      )),
                                      const SizedBox(width: 6),
                                      testId('delete_member_${m.id.isNotEmpty ? m.id : m.fullName}', IconButton(
                                        key: Key('delete_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                        icon: const Icon(Icons.close, size: 14, color: AppColors.accentRed),
                                        tooltip: '${m.fullName} kaydını sil',
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
                        // KAT MALİKİ (EV SAHİBİ) TAB
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
                                  const Icon(Icons.vpn_key_outlined, size: 15, color: AppColors.accentCyan),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Kat Maliki (Daire Mülk Sahibi)',
                                      style: TextStyle(
                                        color: AppColors.primaryText(context),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: AppColors.accentCyan.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'Ev Sahibi',
                                      style: TextStyle(
                                        color: AppColors.primaryText(context),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),

                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          ho.ownerFullName.isNotEmpty ? ho.ownerFullName : 'Bilinmeyen Malik',
                                          style: TextStyle(
                                            color: AppColors.textPrimary(context),
                                            fontSize: 14,
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
                                                  ho.phone.isNotEmpty ? ho.phone : 'Telefon Yok',
                                                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                                ),
                                              ],
                                            ),
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.email_outlined, size: 12, color: AppColors.textSecondary(context)),
                                                const SizedBox(width: 4),
                                                Flexible(child: Text(
                                                  ho.email.isNotEmpty ? ho.email : 'E-posta Yok',
                                                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                                )),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  testId('edit_owner_${ho.unitId}', OutlinedButton.icon(
                                    key: Key('edit_owner_${ho.unitId}'),
                                    onPressed: () => _showEditHomeOwnerDialog(ho, initialTab: 1),
                                    icon: const Icon(Icons.edit_outlined, size: 12),
                                    label: const Text('Kat Malikini Düzenle', style: TextStyle(fontSize: 12)),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.accentCyan,
                                      side: const BorderSide(color: AppColors.accentCyan),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      minimumSize: const Size(0, 28),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  )),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  );
                }

                // NON-TENANT CASE (OWNER-OCCUPIED OR VACANT)
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // SECTION A: FİİLEN İKAMET EDEN SAKİN (BİRİNCİL MUHATAP)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.card(context),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: statusColor.withOpacity(0.35)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                isVacant ? Icons.hotel_class_outlined : Icons.home,
                                size: 15,
                                color: statusColor,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  isVacant ? 'İkamet Durumu' : 'Fiilen İkamet Eden Kat Maliki (Birincil Muhatap)',
                                  style: TextStyle(
                                    color: statusColor,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: statusColor.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  isVacant ? 'Boş' : 'Malik (Mukim)',
                                  style: TextStyle(
                                    color: statusColor,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),

                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      activeResidentName,
                                      style: TextStyle(
                                        color: AppColors.textPrimary(context),
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (!isVacant) ...[
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
                                                ho.phone.isNotEmpty ? ho.phone : 'Telefon Yok',
                                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                              ),
                                            ],
                                          ),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.email_outlined, size: 12, color: AppColors.textSecondary(context)),
                                              const SizedBox(width: 4),
                                              Flexible(child: Text(
                                                ho.email.isNotEmpty ? ho.email : 'E-posta Yok',
                                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                              )),
                                            ],
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        children: [
                                          testId('edit_residents_${ho.unitId}', OutlinedButton.icon(
                                            key: Key('edit_residents_${ho.unitId}'),
                                            onPressed: () => _showEditHomeOwnerDialog(ho, initialTab: 0),
                                            icon: const Icon(Icons.edit_outlined, size: 12),
                                            label: const Text('Düzenle', style: TextStyle(fontSize: 12)),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: AppColors.accentCyan,
                                              side: const BorderSide(color: AppColors.accentCyan),
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                              minimumSize: const Size(0, 28),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                            ),
                                          )),
                                        ],
                                      ),
                                    ] else ...[
                                      const SizedBox(height: 10),
                                      testId('move_in_btn_${ho.unitId}', ElevatedButton.icon(
                                        key: Key('move_in_btn_${ho.unitId}'),
                                        onPressed: () => _showMoveInDialog(ho),
                                        icon: const Icon(Icons.person_add_alt, size: 13),
                                        label: const Text('Kiracı Girişi (Move-In)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: AppColors.successFill,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                          minimumSize: const Size(0, 28),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        ),
                                      )),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // SECTION B: KAT MALİKİ (MÜLK SAHİBİ) - When vacant
                    if (isVacant) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.background(context),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border(context).withOpacity(0.6)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.vpn_key_outlined, size: 14, color: AppColors.accentCyan),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        'Kat Maliki (Mülk Sahibi): ',
                                        style: TextStyle(
                                          color: AppColors.textSecondary(context),
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Flexible(
                                        child: Text(
                                          ho.ownerFullName.isNotEmpty ? ho.ownerFullName : 'Bilinmeyen Malik',
                                          style: TextStyle(
                                            color: AppColors.textPrimary(context),
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (ho.phone.isNotEmpty || ho.email.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      '${ho.phone.isNotEmpty ? ho.phone : ''}${ho.phone.isNotEmpty && ho.email.isNotEmpty ? ' • ' : ''}${ho.email.isNotEmpty ? ho.email : ''}',
                                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // SECTION C: HANE SAKİNLERİ / BİRLİKTE YAŞAYANLAR
                    if (!isVacant || ho.householdResidents.isNotEmpty) ...[
                      const SizedBox(height: 8),
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
                                  style: TextStyle(
                                    color: AppColors.textPrimary(context),
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              testId('add_resident_to_${ho.unitId}', TextButton.icon(
                                key: Key('add_resident_to_${ho.unitId}'),
                                onPressed: () => _showAddHouseholdMemberDialog(ho),
                                icon: const Icon(Icons.add, size: 14, color: AppColors.accentPurple),
                                label: const Text('+ Sakin Ekle', style: TextStyle(color: AppColors.accentPurple, fontSize: 12, fontWeight: FontWeight.bold)),
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
                                      '${m.fullName} • ${HouseholdRelationship.labelFor(m.relationship)}${m.phone.isNotEmpty ? ' • ${m.phone}' : ''}',
                                      style: TextStyle(
                                        color: AppColors.textSecondary(context),
                                        fontSize: 12,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  testId('edit_member_${m.id.isNotEmpty ? m.id : m.fullName}', IconButton(
                                    key: Key('edit_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                    icon: const Icon(Icons.edit_outlined, size: 14, color: AppColors.accentCyan),
                                    tooltip: '${m.fullName} bilgilerini düzenle',
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    onPressed: () => _showEditHouseholdMemberDialog(ho, m),
                                  )),
                                  const SizedBox(width: 6),
                                  testId('delete_member_${m.id.isNotEmpty ? m.id : m.fullName}', IconButton(
                                    key: Key('delete_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                    icon: const Icon(Icons.close, size: 14, color: AppColors.accentRed),
                                    tooltip: '${m.fullName} kaydını sil',
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    onPressed: () => _confirmDeleteHouseholdMember(ho, m),
                                  )),
                                ],
                              ),
                            )),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              );
              },
            ),

          ],
        ),
      ),
    ],
  ),
);
  }

  Future<void> _showUnitActions(HomeOwnerItem unit) async {
    final actions = <String, String>{
      'edit': 'Daire ve malik bilgilerini düzenle',
      // STORY-08-07: only the commands legal for the unit's state.
      if (unit.allows(OccupancyCommand.tenantMoveIn) ||
          unit.allows(OccupancyCommand.replaceTenant) ||
          unit.allows(OccupancyCommand.ownerRentsOut))
        'move_in': unit.isTenantOccupied
            ? 'Kiracı değişikliği'
            : (unit.isVacant ? 'Kiracı girişi' : 'Daireyi kiraya ver'),
      if (unit.allows(OccupancyCommand.ownerMoveIn)) 'owner_move_in': 'Kat maliki taşınsın',
      if (unit.allows(OccupancyCommand.ownerTakesBack)) 'owner_takes_back': 'Kat maliki daireyi geri alsın',
      if (unit.allows(OccupancyCommand.moveOut)) 'move_out': 'Sakin ayrılışı',
      'history': 'Daire tarihçesi',
      'statement': 'Hesap ekstresi',
      'iban': 'Sanal IBAN',
      'transfer': 'Mülk devri',
      'delete': 'Daire kaydını sil',
    };
    final ids = <String, String>{
      'edit': 'edit_unit_${unit.unitId}',
      'move_in': 'move_in_ho_${unit.unitId}',
      'move_out': 'move_out_ho_${unit.unitId}',
      'owner_move_in': 'owner_move_in_ho_${unit.unitId}',
      'owner_takes_back': 'owner_takes_back_ho_${unit.unitId}',
      'history': 'history_ho_${unit.unitId}',
      'statement': 'btn_statement_${unit.unitId}',
      'iban': 'module_iban_ho_${unit.unitId}',
      'transfer': 'transfer_ownership_${unit.unitId}',
      'delete': 'delete_ho_${unit.unitId}',
    };
    final action = await showSpSelection<String>(
      context: context,
      title: '${unit.block} • Daire ${unit.unitNo} İşlemleri',
      options: actions.keys.toList(),
      labelOf: (value) => actions[value]!,
      idOf: (value) => ids[value]!,
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'edit':
        _showEditHomeOwnerDialog(unit, initialTab: 2);
      case 'move_in':
        _showMoveInDialog(unit);
      case 'move_out':
        _showMoveOutDialog(unit);
      case 'owner_move_in':
        _confirmOwnerMoveIn(unit, OccupancyCommand.ownerMoveIn);
      case 'owner_takes_back':
        _confirmOwnerMoveIn(unit, OccupancyCommand.ownerTakesBack);
      case 'history':
        _showUnitOccupancyHistoryDialog(unit);
      case 'statement':
        AppFullscreenPage.push(
          context: context,
          builder: (_) => ResidentStatementPage(unitId: unit.unitId, subtitle: '${unit.block} Blok D:${unit.unitNo}'),
        );
      case 'iban':
        _showVirtualIbanDetailsDialog(unit);
      case 'transfer':
        _showTransferOwnershipDialog(unit);
      case 'delete':
        _confirmDeleteHomeOwner(unit);
    }
  }

  void _showUnitOccupancyHistoryDialog(HomeOwnerItem resident) {
    final historyFuture = widget.controller.fetchOccupancyHistory(resident.unitId);
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => FutureBuilder<List<OccupancyHistoryItem>>(
        future: historyFuture,
        builder: (context, snapshot) {
          final items = snapshot.data ?? [];
          final isLoading = snapshot.connectionState == ConnectionState.waiting;

          return AppFullscreenPage(
            title: 'Daire Sakin & İkamet Tarihçesi',
            subtitle: '${resident.block} Daire ${resident.unitNo} • Tarihsel Hareket Kayıtları',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentCyan.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.history_edu, color: AppColors.accentCyan, size: 20),
            ),
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary(context),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(AppStrings.close),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isLoading)
                  const SpSkeletonList()
                else if (items.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.surface(context),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.border(context)),
                    ),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.person_off_outlined, size: 40, color: AppColors.textSecondary(context)),
                          const SizedBox(height: 8),
                          Text(
                            'Henüz Kayıtlı Sakin Değişikliği Yok',
                            style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Mevcut sakin: ${resident.ownerFullName}',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ...items.map((h) => testId('history_item_${h.id}', Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surface(context),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: h.isActive ? AppColors.accentGreen : AppColors.border(context),
                        width: h.isActive ? 1.5 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              h.role.toUpperCase() == 'TENANT' ? Icons.key_outlined : Icons.home_outlined,
                              size: 18,
                              color: h.role.toUpperCase() == 'TENANT' ? AppColors.accentGreen : AppColors.accentCyan,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                h.personName,
                                style: TextStyle(
                                  color: AppColors.textPrimary(context),
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: (h.isActive ? AppColors.accentGreen : AppColors.textSecondary(context)).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                h.isActive ? 'Aktif' : 'Ayrıldı',
                                style: TextStyle(
                                  color: h.isActive ? AppColors.successText(context) : AppColors.textSecondary(context),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${h.role.toUpperCase() == 'TENANT' ? 'Kiracı (Tenant)' : 'Kat Maliki (Owner)'} • Giriş: ${h.startDate}${h.endDate != null ? ' • Çıkış: ${h.endDate}' : ''}',
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                        ),
                        if (h.exitBalance > Decimal.zero) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Kapanış Bakiyesi: ${formatTry(h.exitBalance)} Borç',
                            style: TextStyle(color: AppColors.dangerText(context), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                        if (h.notes != null && h.notes!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Not: ${h.notes}',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontStyle: FontStyle.italic),
                          ),
                        ],
                      ],
                    ),
                  ))),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showMoveOutDialog(HomeOwnerItem resident) {
    final notesCtrl = TextEditingController();
    var effectiveDate = DateTime.now();
    bool isSaving = false;
    String? errorMsg;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AppFullscreenPage(
            title: 'Sakin Ayrılışı (Move-Out / Tahliye)',
            subtitle: '${resident.block} Daire ${resident.unitNo} • ${resident.tenantFullName ?? resident.ownerFullName}',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentOrange.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.logout, color: AppColors.accentOrange, size: 20),
            ),
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(
                  onPressed: isSaving ? null : () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary(context),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(AppStrings.cancel),
                ),
                testId('btn_confirm_move_out', FilledButton.icon(
                  onPressed: isSaving ? null : () async {
                    setDialogState(() {
                      isSaving = true;
                      errorMsg = null;
                    });
                    try {
                      final messenger = ScaffoldMessenger.of(this.context);
                      final ok = await widget.controller.moveOutResident(
                        resident.unitId,
                        notes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                        effectiveDate: effectiveDate,
                      );
                      if (ok && ctx.mounted) {
                        Navigator.pop(ctx);
                        messenger.showSnackBar(
                          appSnackBar(
                            content: Text('Sakin ayrılışı kaydedildi. Daire boş durumuna getirildi.'),
                            backgroundColor: AppColors.successFill,
                          ),
                        );
                      } else if (ctx.mounted) {
                        setDialogState(() {
                          isSaving = false;
                          errorMsg = 'İşlem gerçekleştirilemedi.';
                        });
                      }
                    } catch (e) {
                      if (ctx.mounted) {
                        setDialogState(() {
                          isSaving = false;
                          errorMsg = 'Beklenmeyen bir hata oluştu: $e';
                        });
                      }
                    } finally {
                      if (ctx.mounted && isSaving) {
                        setDialogState(() => isSaving = false);
                      }
                    }
                  },
                  icon: isSaving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.check, size: 16),
                  label: const Text('Tahliyeyi Onayla'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.warningFill,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.accentOrange.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.accentOrange.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sakin Ayrılış Bilgilendirmesi',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.warningText(context)),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Bu işlem sakinin oturumunu kapatır ve daireyi "BOŞ" statüsüne alır. Sakine ait geçmiş ödemeler ve borç kayıtları tarihçede korunur, silinmez.',
                        style: TextStyle(fontSize: 12, color: AppColors.textPrimary(context)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                testId('move_out_effective_date', SpEffectiveDateField(
                  key: const Key('move_out_effective_date'),
                  value: effectiveDate,
                  onChanged: (d) => setDialogState(() => effectiveDate = d),
                )),
                const SizedBox(height: 16),
                TextField(
                  controller: notesCtrl,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'Ayrılış Notu / Açıklama (Opsiyonel)',
                    hintText: 'Örn: Kira sözleşmesi bitti, anahtar teslim alındı.',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                if (errorMsg != null) ...[
                  const SizedBox(height: 8),
                  Text(errorMsg!, style: TextStyle(color: AppColors.dangerText(context), fontSize: 12)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// T3 / C3: the owner on record moves in; the confirmation names the owner
  /// and asks for no person data (STORY-08-06).
  Future<void> _confirmOwnerMoveIn(HomeOwnerItem unit, OccupancyCommand command) async {
    final takesBack = command == OccupancyCommand.ownerTakesBack;
    final confirmed = await showSpConfirmDialog(
      context,
      title: takesBack ? 'Kat Maliki Daireyi Geri Alsın' : 'Kat Maliki Taşınsın',
      message: takesBack
          ? 'Kiracı ${unit.tenantFullName ?? ''} tahliye edilir ve ${unit.ownerFullName} daireye taşınır. Kat maliki değişmez.'
          : '${unit.ownerFullName} daireye taşınır. Kat maliki değişmez; yeni bir malik yalnızca tapu devri ile kaydedilir.',
      confirmLabel: 'Onayla',
      confirmKey: 'btn_confirm_owner_move_in',
    );
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await widget.controller.applyOccupancyTransition(unit.unitId, command: command);
    if (!mounted) return;
    messenger.showSnackBar(result.ok
        ? appSnackBar(content: Text('${unit.ownerFullName} daireye taşındı.'))
        : spSnackBar(kind: ToastKind.error, content: Text(result.message ?? 'Kat maliki girişi kaydedilemedi.')));
  }

  void _showMoveInDialog(HomeOwnerItem resident) {
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    // STORY-08-06: this form is for a tenant only; the command follows the state.
    final command = resident.isTenantOccupied
        ? OccupancyCommand.replaceTenant
        : (resident.isOwnerOccupied ? OccupancyCommand.ownerRentsOut : OccupancyCommand.tenantMoveIn);
    bool isSaving = false;
    String? errorMsg;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AppFullscreenPage(
            title: 'Yeni Sakin / Giriş (Move-In)',
            subtitle: '${resident.block} Daire ${resident.unitNo}',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentGreen.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.person_add_alt_1, color: AppColors.accentGreen, size: 20),
            ),
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(
                  onPressed: isSaving ? null : () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary(context),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(AppStrings.cancel),
                ),
                testId('btn_confirm_move_in', FilledButton.icon(
                  onPressed: isSaving ? null : () async {
                    if (nameCtrl.text.trim().isEmpty || emailCtrl.text.trim().isEmpty) {
                      setDialogState(() {
                        errorMsg = 'Ad Soyad ve E-posta alanları zorunludur.';
                      });
                      return;
                    }
                    setDialogState(() {
                      isSaving = true;
                      errorMsg = null;
                    });
                    try {
                      final messenger = ScaffoldMessenger.of(this.context);
                      final result = await widget.controller.applyOccupancyTransition(
                        resident.unitId,
                        command: command,
                        fullName: nameCtrl.text.trim(),
                        email: emailCtrl.text.trim(),
                        phone: phoneCtrl.text.trim().isNotEmpty ? phoneCtrl.text.trim() : null,
                        notes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                      );
                      if (result.ok && ctx.mounted) {
                        Navigator.pop(ctx);
                        messenger.showSnackBar(
                          appSnackBar(
                            content: Text('Yeni sakin başarıyla eklendi ve oturum başlatıldı.'),
                            backgroundColor: AppColors.successFill,
                          ),
                        );
                      } else if (ctx.mounted) {
                        setDialogState(() {
                          isSaving = false;
                          errorMsg = result.message ?? 'Kayıt işlemi başarısız oldu.';
                        });
                      }
                    } catch (e) {
                      if (ctx.mounted) {
                        setDialogState(() {
                          isSaving = false;
                          errorMsg = 'Beklenmeyen bir hata oluştu: $e';
                        });
                      }
                    } finally {
                      if (ctx.mounted && isSaving) {
                        setDialogState(() => isSaving = false);
                      }
                    }
                  },
                  icon: isSaving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.save, size: 16),
                  label: const Text('Kaydet & Girişi Başlat'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.successFill,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  command == OccupancyCommand.replaceTenant
                      ? 'Mevcut kiracı aynı gün tahliye edilir ve çıkış bakiyesi kaydedilir.'
                      : 'Kat maliki ${resident.ownerFullName} olarak kalır; kiracı yalnızca daireye taşınır.',
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                ),
                const SizedBox(height: 16),
                testId('move_in_name_field', TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: 'Sakin Adı Soyadı *',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )),
                const SizedBox(height: 12),
                testId('move_in_email_field', TextField(
                  controller: emailCtrl,
                  decoration: InputDecoration(
                    labelText: 'E-posta Adresi *',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )),
                const SizedBox(height: 12),
                testId('move_in_phone_field', TextField(
                  controller: phoneCtrl,
                  decoration: InputDecoration(
                    labelText: 'Telefon Numarası',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )),
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Not / Sözleşme Detayı (Opsiyonel)',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                if (errorMsg != null) ...[
                  const SizedBox(height: 8),
                  Text(errorMsg!, style: TextStyle(color: AppColors.dangerText(context), fontSize: 12)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _showEditHouseholdMemberDialog(HomeOwnerItem ho, UnitResidentMember member) {
    final nameCtrl = TextEditingController(text: member.fullName);
    final phoneCtrl = TextEditingController(text: member.phone);
    final emailCtrl = TextEditingController(text: member.email);
    String selectedRelationship = HouseholdRelationship.fromValue(member.relationship).code;
    bool isSaving = false;
    String? nameError;
    String? generalError;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AppFullscreenPage(
            title: 'Hane Sakinini Düzenle',
            subtitle: '${ho.block} Daire ${ho.unitNo} • ${member.fullName}',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentPurple.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.family_restroom, color: AppColors.accentPurple, size: 20),
            ),
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(
                  onPressed: isSaving ? null : () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary(context),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(AppStrings.cancel),
                ),
                ElevatedButton(
                  onPressed: isSaving
                      ? null
                      : () async {
                          final name = nameCtrl.text.trim();
                          if (name.isEmpty) {
                            setDialogState(() {
                              nameError = 'Ad Soyad zorunludur.';
                            });
                            return;
                          }
                          setDialogState(() {
                            isSaving = true;
                            generalError = null;
                            nameError = null;
                          });

                          try {
                            final messenger = ScaffoldMessenger.of(this.context);
                            final ok = await widget.controller.updateHouseholdMember(
                              unitId: ho.unitId,
                              residentId: member.id.isNotEmpty ? member.id : member.fullName,
                              fullName: name,
                              phone: phoneCtrl.text.trim(),
                              email: emailCtrl.text.trim(),
                              relationship: selectedRelationship,
                            );

                            if (ok && ctx.mounted) {
                              Navigator.pop(ctx);
                              messenger.showSnackBar(
                                appSnackBar(
                                  content: Text('Hane sakini başarıyla güncellendi.'),
                                  backgroundColor: AppColors.successFill,
                                ),
                              );
                            } else if (ctx.mounted) {
                              setDialogState(() {
                                isSaving = false;
                                generalError = 'Güncelleme sırasında bir hata oluştu.';
                              });
                            }
                          } catch (e) {
                            if (ctx.mounted) {
                              setDialogState(() {
                                isSaving = false;
                                generalError = 'Beklenmeyen hata: $e';
                              });
                            }
                          } finally {
                            if (ctx.mounted && isSaving) {
                              setDialogState(() => isSaving = false);
                            }
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentPurple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: isSaving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text(AppStrings.save, style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (generalError != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.accentRed.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.accentRed),
                      ),
                      child: Text(generalError!, style: TextStyle(color: AppColors.dangerText(context), fontSize: 13)),
                    ),
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.card(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border(context)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.apartment, color: AppColors.accentCyan, size: 24),
                        const SizedBox(width: 10),
                        Text(
                          '${ho.block} Blok • Daire ${ho.unitNo}',
                          style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  Text('Ad Soyad *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      hintText: 'Örn: Ahmet Yılmaz',
                      errorText: nameError,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('Yakınlık Derecesi / Rol', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: selectedRelationship,
                    items: householdRelationshipItems(),
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => selectedRelationship = val);
                      }
                    },
                    decoration: InputDecoration(
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('Telefon Numarası', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      hintText: 'Örn: 0532 123 45 67',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('E-posta Adresi', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      hintText: 'Örn: sakin@example.com',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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

  void _confirmDeleteHouseholdMember(HomeOwnerItem ho, UnitResidentMember member) {
    AppFullscreenPage.pushConfirmation(
      context: context,
      title: 'Hane Sakinini Sil',
      message: '${member.fullName} (${HouseholdRelationship.labelFor(member.relationship)}) adlı hane sakini kaydını ${ho.block} Blok Daire ${ho.unitNo} listesinden silmek istediğinize emin misiniz?',
      confirmLabel: 'Evet, Sil',
      cancelLabel: AppStrings.cancel,
      confirmColor: AppColors.accentRed,
      icon: Icons.person_remove_outlined,
      iconColor: AppColors.accentRed,
    ).then((confirmed) async {
      if (confirmed == true && mounted) {
        final success = await widget.controller.deleteHouseholdMember(
          unitId: ho.unitId,
          residentId: member.id.isNotEmpty ? member.id : member.fullName,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            appSnackBar(
              content: Text(success ? 'Hane sakini başarıyla silindi.' : 'Hane sakini silinirken bir hata oluştu.'),
              backgroundColor: success ? AppColors.accentGreen : AppColors.accentRed,
            ),
          );
        }
      }
    });
  }

  void _showAddHouseholdMemberDialog([HomeOwnerItem? ho]) {
    final effectiveBlock = ho?.block ?? (widget.controller.activeUnit.block.isNotEmpty ? widget.controller.activeUnit.block : 'A');
    final effectiveUnitNo = ho?.unitNo ?? (widget.controller.activeUnit.unitNo > 0 ? widget.controller.activeUnit.unitNo : 1);
    final effectiveUnitId = ho?.unitId ?? (widget.controller.activeUnit.id.isNotEmpty ? widget.controller.activeUnit.id : 'd-$effectiveUnitNo');

    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    String selectedRelationship = HouseholdRelationship.spouse.code;
    bool isSaving = false;
    String? nameError;
    String? generalError;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AppFullscreenPage(
            title: 'Yeni Hane Sakini Ekle',
            subtitle: '$effectiveBlock Blok Daire $effectiveUnitNo • Birlikte Yaşayan Kişi',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentPurple.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.person_add_alt_1_outlined, color: AppColors.accentPurple, size: 20),
            ),
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                OutlinedButton(
                  onPressed: isSaving ? null : () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary(context),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(AppStrings.cancel),
                ),
                testId('household_save_button', ElevatedButton(
                  key: const Key('household_save_button'),
                  onPressed: isSaving
                      ? null
                      : () async {
                          final name = nameCtrl.text.trim();
                          if (name.isEmpty) {
                            setDialogState(() {
                              nameError = 'Ad Soyad zorunludur.';
                            });
                            return;
                          }
                          setDialogState(() {
                            isSaving = true;
                            generalError = null;
                            nameError = null;
                          });

                          try {
                            final messenger = ScaffoldMessenger.of(this.context);
                            final ok = await widget.controller.addHouseholdMember(
                              unitId: effectiveUnitId,
                              block: effectiveBlock,
                              unitNo: effectiveUnitNo,
                              fullName: name,
                              phone: phoneCtrl.text.trim(),
                              email: emailCtrl.text.trim().isNotEmpty
                                  ? emailCtrl.text.trim()
                                  : 'sakin.$effectiveUnitNo@example.com',
                              relationship: selectedRelationship,
                            );

                            if (ok && ctx.mounted) {
                              Navigator.pop(ctx);
                              messenger.showSnackBar(
                                appSnackBar(
                                  content: Text('Hane sakini başarıyla eklendi.'),
                                  backgroundColor: AppColors.successFill,
                                ),
                              );
                            } else if (ctx.mounted) {
                              setDialogState(() {
                                isSaving = false;
                                generalError = 'Kayıt sırasında bir hata oluştu.';
                              });
                            }
                          } catch (e) {
                            if (ctx.mounted) {
                              setDialogState(() {
                                isSaving = false;
                                generalError = 'Beklenmeyen hata: $e';
                              });
                            }
                          } finally {
                            if (ctx.mounted && isSaving) {
                              setDialogState(() => isSaving = false);
                            }
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentPurple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: isSaving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text(AppStrings.save, style: TextStyle(fontWeight: FontWeight.bold)),
                )),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (generalError != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.accentRed.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.accentRed),
                      ),
                      child: Text(generalError!, style: TextStyle(color: AppColors.dangerText(context), fontSize: 13)),
                    ),
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.card(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border(context)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.apartment, color: AppColors.accentCyan, size: 24),
                        const SizedBox(width: 10),
                        Text(
                          '$effectiveBlock Blok • Daire $effectiveUnitNo',
                          style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  Text('Ad Soyad *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                  const SizedBox(height: 6),
                  testId('household_name_field', TextField(
                    key: const Key('household_name_field'),
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      hintText: 'Örn: Ahmet Yılmaz',
                      errorText: nameError,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  )),
                  const SizedBox(height: 14),
                  Text('Yakınlık Derecesi / Rol', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: selectedRelationship,
                    items: householdRelationshipItems(),
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => selectedRelationship = val);
                      }
                    },
                    decoration: InputDecoration(
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('Telefon Numarası', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                  const SizedBox(height: 6),
                  testId('household_phone_field', TextField(
                    key: const Key('household_phone_field'),
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      hintText: 'Örn: 0532 123 45 67',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  )),
                  const SizedBox(height: 14),
                  Text('E-posta Adresi', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                  const SizedBox(height: 6),
                  testId('household_email_field', TextField(
                    key: const Key('household_email_field'),
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      hintText: 'Örn: sakin@example.com',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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

  void _showDeleteTenantOrOwnerOptions(HomeOwnerItem resident, {BuildContext? parentCtx}) {
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: 'Sakin / Daire Silme Seçenekleri',
        subtitle: '${resident.block} Daire ${resident.unitNo} • Kiracılı Daire',
        icon: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.accentRed.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.delete_sweep, color: AppColors.accentRed, size: 20),
        ),
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary(context),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(AppStrings.cancel),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Bu dairede fiilen ikamet eden bir kiracı (${resident.tenantFullName ?? 'Kiracı'}) bulunmaktadır. Lütfen gerçekleştirmek istediğiniz işlemi seçiniz:',
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 20),

              // Option 1: Remove Tenant only
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.card(context),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.accentOrange.withOpacity(0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.accentOrange.withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.person_remove, color: AppColors.accentOrange, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Sadece Kiracıyı Çıkar / Sil',
                                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 14, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Kiracı: ${resident.tenantFullName ?? 'Bilinmiyor'}',
                                style: TextStyle(color: AppColors.warningText(context), fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Kiracının ikamet kaydını sonlandırır ve daireyi "Boş" duruma getirir. Kat maliki (${resident.ownerFullName}) ve daire kaydı korunur.',
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: testId('remove_tenant_only_button', ElevatedButton.icon(
                        key: const Key('remove_tenant_only_button'),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          final success = await widget.controller.updateHomeOwner(
                            unitId: resident.unitId,
                            removeTenant: true,
                          );
                          if (mounted) {
                            if (success) {
                              if (parentCtx != null && parentCtx.mounted) {
                                Navigator.pop(parentCtx);
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                appSnackBar(
                                  content: Text('Kiracı daireden başarıyla çıkarıldı. Daire boş duruma getirildi.'),
                                  backgroundColor: AppColors.successFill,
                                ),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                appSnackBar(
                                  content: Text('Kiracı çıkarılırken bir hata oluştu.'),
                                  backgroundColor: AppColors.dangerFill,
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.logout, size: 16),
                        label: const Text('Kiracıyı Daireden Çıkar'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.warningFill,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      )),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Option 2: Delete entire flat and homeowner
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.card(context),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.accentRed.withOpacity(0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.accentRed.withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.delete_forever, color: AppColors.accentRed, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Tüm Daireyi ve Kat Malikini Sil',
                                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 14, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Malik: ${resident.ownerFullName}',
                                style: TextStyle(color: AppColors.dangerText(context), fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Daireyi, kat malikini, kiracıyı ve bağlı tüm aidat ve tahakkuk kayıtlarını sistemden tamamen siler. Bu işlem geri alınamaz.',
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: testId('delete_entire_home_owner_button', OutlinedButton.icon(
                        key: const Key('delete_entire_home_owner_button'),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          final success = await widget.controller.deleteHomeOwner(unitId: resident.unitId);
                          if (mounted) {
                            if (success) {
                              if (parentCtx != null && parentCtx.mounted) {
                                Navigator.pop(parentCtx);
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                appSnackBar(
                                  content: Text('Kat maliki ve daire başarıyla silindi.'),
                                  backgroundColor: AppColors.successFill,
                                ),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                appSnackBar(
                                  content: Text('Silme işlemi sırasında bir hata oluştu.'),
                                  backgroundColor: AppColors.dangerFill,
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.delete_forever, size: 16, color: AppColors.accentRed),
                        label: Text('Daireyi ve Kat Malikini Tamamen Sil', style: TextStyle(color: AppColors.dangerText(context), fontWeight: FontWeight.bold)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.accentRed),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      )),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDeleteHomeOwner(HomeOwnerItem resident, {BuildContext? parentCtx}) {
    final isTenant = resident.occupancyStatus == 'TENANT_OCCUPIED' || (resident.tenantFullName != null && resident.tenantFullName!.isNotEmpty);

    if (isTenant) {
      _showDeleteTenantOrOwnerOptions(resident, parentCtx: parentCtx);
      return;
    }

    AppFullscreenPage.pushConfirmation(
      context: context,
      title: 'Kat Malikini Sil',
      message: '${resident.ownerFullName} (${resident.block} Blok Daire ${resident.unitNo}) kaydını ve bağlı tüm aidat ve tahakkuk kayıtlarını silmek istediğinize emin misiniz?\n\nBu işlem geri alınamaz.',
      confirmLabel: 'Evet, Sil',
      cancelLabel: AppStrings.cancel,
      confirmColor: AppColors.accentRed,
      icon: Icons.delete_forever,
      iconColor: AppColors.accentRed,
    ).then((confirmed) async {
      if (confirmed == true && mounted) {
        final success = await widget.controller.deleteHomeOwner(unitId: resident.unitId);
        if (mounted) {
          if (success) {
            if (parentCtx != null && parentCtx.mounted) {
              Navigator.pop(parentCtx);
            }
            ScaffoldMessenger.of(context).showSnackBar(
              appSnackBar(
                content: Text('Kat maliki başarıyla silindi.'),
                backgroundColor: AppColors.successFill,
                duration: Duration(seconds: 3),
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              appSnackBar(
                content: Text(widget.controller.lastDeleteHomeOwnerError ?? 'Kat maliki silinirken bir hata oluştu.'),
                backgroundColor: AppColors.dangerFill,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        }
      }
    });
  }

  void _confirmRemoveTenantFromEdit(HomeOwnerItem resident, BuildContext editCtx) {
    AppFullscreenPage.pushConfirmation(
      context: context,
      title: 'Kiracıyı Daireden Çıkar',
      message: '${resident.tenantFullName ?? 'Kiracı'} adlı sakinin ${resident.block} Blok Daire ${resident.unitNo} kaydından çıkarılmasını ve dairenin boş durumuna getirilmesini onaylıyor musunuz?',
      confirmLabel: 'Evet, Çıkar',
      cancelLabel: AppStrings.cancel,
      confirmColor: AppColors.accentOrange,
      icon: Icons.logout,
      iconColor: AppColors.accentOrange,
    ).then((confirmed) async {
      if (confirmed == true && mounted) {
        final success = await widget.controller.updateHomeOwner(
          unitId: resident.unitId,
          removeTenant: true,
        );
        if (mounted) {
          if (success) {
            if (editCtx.mounted) {
              Navigator.pop(editCtx);
            }
            ScaffoldMessenger.of(context).showSnackBar(
              appSnackBar(
                content: Text('Kiracı başarıyla çıkarıldı. Daire boş duruma getirildi.'),
                backgroundColor: AppColors.successFill,
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              appSnackBar(
                content: Text('Kiracı çıkarılırken bir hata oluştu.'),
                backgroundColor: AppColors.dangerFill,
              ),
            );
          }
        }
      }
    });
  }

  void _showEditHomeOwnerDialog(HomeOwnerItem resident, {int initialTab = 2}) {
    final isTenant = resident.occupancyStatus == 'TENANT_OCCUPIED' || (resident.tenantFullName != null && resident.tenantFullName!.isNotEmpty);
    int activeDialogTab = isTenant ? initialTab : 1; // 0: Sakinler, 1: Kat Maliki, 2: Tümü

    final ownerNameCtrl = TextEditingController(text: resident.ownerFullName);
    final ownerEmailCtrl = TextEditingController(text: resident.email);
    final ownerPhoneCtrl = TextEditingController(text: resident.phone);

    final tenantNameCtrl = TextEditingController(text: resident.tenantFullName ?? '');
    final tenantEmailCtrl = TextEditingController(text: resident.tenantEmail ?? '');
    final tenantPhoneCtrl = TextEditingController(text: resident.tenantPhone ?? '');

    final landShareCtrl = TextEditingController(text: resident.landShare);

    final houseTypes = widget.controller.houseTypes;
    String? selectedHouseType = resident.houseType;
    if (selectedHouseType == null && houseTypes.isNotEmpty) {
      selectedHouseType = houseTypes.first.typeName;
    }
    final initialTariff = houseTypes.where((ht) => ht.typeName == selectedHouseType).firstOrNull;
    final initialDues = initialTariff?.duesAmount ?? resident.monthlyDues;
    final duesCtrl = TextEditingController(text: initialDues.toStringAsFixed(2));
    bool isResident = resident.isResident;

    String? ownerNameError;
    String? ownerEmailError;
    String? ownerPhoneError;
    String? tenantNameError;
    String? tenantEmailError;
    String? tenantPhoneError;
    String? generalError;
    bool isSaving = false;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final currentHouseTypes = widget.controller.houseTypes;
          return AppFullscreenPage(
            title: 'Sakin Bilgilerini Düzenle',
            subtitle: '${resident.block} Daire ${resident.unitNo} • ${isTenant ? 'Kiracılı Daire' : 'Malik İkameti'}',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentCyan.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.edit_note, color: AppColors.accentCyan, size: 20),
            ),
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                testId('edit_ho_delete_button', OutlinedButton.icon(
                  key: const Key('edit_ho_delete_button'),
                  onPressed: isSaving ? null : () => _confirmDeleteHomeOwner(resident, parentCtx: ctx),
                  icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.accentRed),
                  label: Text(AppStrings.delete, style: TextStyle(color: AppColors.dangerText(context), fontWeight: FontWeight.bold)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.accentRed),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )),
                OutlinedButton(
                  onPressed: isSaving ? null : () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary(context),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(AppStrings.cancel),
                ),
                ElevatedButton(
                  onPressed: isSaving
                      ? null
                      : () async {
                          final oName = ownerNameCtrl.text.trim();
                          final oEmail = ownerEmailCtrl.text.trim();
                          final oPhone = ownerPhoneCtrl.text.trim();
                          final tName = tenantNameCtrl.text.trim();
                          final tEmail = tenantEmailCtrl.text.trim();
                          final tPhone = tenantPhoneCtrl.text.trim();

                          bool hasError = false;
                          String? newOwnerNameErr;
                          String? newOwnerEmailErr;
                          String? newOwnerPhoneErr;
                          String? newTenantNameErr;
                          String? newTenantEmailErr;
                          String? newTenantPhoneErr;

                          final validateTenant = isTenant && (activeDialogTab == 0 || activeDialogTab == 2);
                          final validateOwner = (!isTenant) || (activeDialogTab == 1 || activeDialogTab == 2);

                          if (validateTenant) {
                            if (tName.isEmpty) {
                              newTenantNameErr = 'Kiracı Ad Soyad zorunludur.';
                              hasError = true;
                            }
                            if (tEmail.isEmpty) {
                              newTenantEmailErr = 'Kiracı e-posta zorunludur.';
                              hasError = true;
                            } else if (validatePersonEmail(tEmail) != null) {
                              newTenantEmailErr = 'Geçerli bir e-posta adresi giriniz.';
                              hasError = true;
                            }
                            if (tPhone.isEmpty) {
                              newTenantPhoneErr = 'Kiracı telefon numarası zorunludur.';
                              hasError = true;
                            } else if (validateTrMobile(tPhone) != null) {
                              newTenantPhoneErr = 'Geçerli bir cep telefonu girin (ör. 0532 123 45 67).';
                              hasError = true;
                            }
                          }

                          if (validateOwner) {
                            if (oName.isEmpty) {
                              newOwnerNameErr = isTenant ? 'Ev Sahibi Ad Soyad zorunludur.' : 'Ad Soyad zorunludur.';
                              hasError = true;
                            }
                            if (oEmail.isEmpty) {
                              newOwnerEmailErr = isTenant ? 'Ev Sahibi e-posta zorunludur.' : 'E-posta zorunludur.';
                              hasError = true;
                            } else if (validatePersonEmail(oEmail) != null) {
                              newOwnerEmailErr = 'Geçerli bir e-posta adresi giriniz.';
                              hasError = true;
                            }
                            if (oPhone.isEmpty) {
                              newOwnerPhoneErr = isTenant ? 'Ev Sahibi telefon numarası zorunludur.' : 'Telefon numarası zorunludur.';
                              hasError = true;
                            } else if (validateTrMobile(oPhone) != null) {
                              newOwnerPhoneErr = 'Geçerli bir cep telefonu girin (ör. 0532 123 45 67).';
                              hasError = true;
                            }
                          }

                          if (hasError) {
                            setDialogState(() {
                              ownerNameError = newOwnerNameErr;
                              ownerEmailError = newOwnerEmailErr;
                              ownerPhoneError = newOwnerPhoneErr;
                              tenantNameError = newTenantNameErr;
                              tenantEmailError = newTenantEmailErr;
                              tenantPhoneError = newTenantPhoneErr;
                            });
                            return;
                          }

                          setDialogState(() {
                            isSaving = true;
                            generalError = null;
                          });

                          try {
                            final messenger = ScaffoldMessenger.of(this.context);
                            final selectedTariff = widget.controller.houseTypes
                                .where((ht) => ht.typeName == selectedHouseType)
                                .firstOrNull;
                            final dues = selectedTariff?.duesAmount ?? (MoneyFormatter.tryParse(duesCtrl.text) ?? resident.monthlyDues);
                            final success = await widget.controller.updateHomeOwner(
                              unitId: resident.unitId,
                              fullName: oName.isNotEmpty ? oName : resident.ownerFullName,
                              email: oEmail.isNotEmpty ? oEmail : resident.email,
                              phone: oPhone.isNotEmpty ? oPhone : resident.phone,
                              tenantFullName: isTenant ? (tName.isNotEmpty ? tName : resident.tenantFullName) : null,
                              tenantEmail: isTenant ? (tEmail.isNotEmpty ? tEmail : resident.tenantEmail) : null,
                              tenantPhone: isTenant ? (tPhone.isNotEmpty ? tPhone : resident.tenantPhone) : null,
                              houseType: selectedHouseType,
                              monthlyDues: dues,
                              landShare: landShareCtrl.text.trim().isNotEmpty ? landShareCtrl.text.trim() : resident.landShare,
                              isResident: isResident,
                            );

                            if (success && ctx.mounted) {
                              Navigator.pop(ctx);
                              messenger.showSnackBar(
                                appSnackBar(
                                  content: Text('Sakin bilgileri başarıyla güncellendi.'),
                                  backgroundColor: AppColors.successFill,
                                ),
                              );
                            } else if (ctx.mounted) {
                              setDialogState(() {
                                isSaving = false;
                                generalError = 'Güncelleme sırasında hata oluştu. Lütfen tekrar deneyiniz.';
                              });
                            }
                          } catch (e) {
                            if (ctx.mounted) {
                              setDialogState(() {
                                isSaving = false;
                                generalError = 'Beklenmeyen hata: $e';
                              });
                            }
                          } finally {
                            if (ctx.mounted && isSaving) {
                              setDialogState(() => isSaving = false);
                            }
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryFill,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Text(AppStrings.save, style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (generalError != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.accentRed.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.accentRed),
                      ),
                      child: Text(
                        generalError!,
                        style: TextStyle(color: AppColors.dangerText(context), fontSize: 13),
                      ),
                    ),

                  // Daire Bilgisi Readonly Card
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.card(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border(context)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.apartment, color: AppColors.accentCyan, size: 28),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${resident.block} Blok • Daire ${resident.unitNo}',
                              style: TextStyle(
                                color: AppColors.textPrimary(context),
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Kat: ${resident.floor} • Arsa Payı: ${resident.landShare} • ${isTenant ? 'Kiracılı Daire' : (resident.occupancyStatus == 'VACANT' ? 'Boş Daire' : 'Malik İkameti')}',
                              style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  if (isTenant) ...[
                    // Tab Bar in Dialog: [ 👥 Sakinler ] | [ 🔑 Kat Maliki ] | [ 📋 Tümü ]
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: AppColors.background(context),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.border(context).withOpacity(0.6)),
                      ),
                      padding: const EdgeInsets.all(3),
                      child: Row(
                        children: [
                          Expanded(
                            child: testId('dialog_tab_residents', InkWell(
                              key: const Key('dialog_tab_residents'),
                              onTap: () => setDialogState(() => activeDialogTab = 0),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: activeDialogTab == 0 ? AppColors.card(context) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  border: activeDialogTab == 0 ? Border.all(color: AppColors.accentGreen.withOpacity(0.5)) : null,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.people_alt_outlined, size: 14, color: activeDialogTab == 0 ? AppColors.accentGreen : AppColors.textSecondary(context)),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Sakinler',
                                      style: TextStyle(
                                        color: activeDialogTab == 0 ? AppColors.successText(context) : AppColors.textSecondary(context),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: testId('dialog_tab_owner', InkWell(
                              key: const Key('dialog_tab_owner'),
                              onTap: () => setDialogState(() => activeDialogTab = 1),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: activeDialogTab == 1 ? AppColors.card(context) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  border: activeDialogTab == 1 ? Border.all(color: AppColors.accentCyan.withOpacity(0.5)) : null,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.vpn_key_outlined, size: 14, color: activeDialogTab == 1 ? AppColors.accentCyan : AppColors.textSecondary(context)),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Kat Maliki',
                                      style: TextStyle(
                                        color: activeDialogTab == 1 ? AppColors.primaryText(context) : AppColors.textSecondary(context),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: testId('dialog_tab_all', InkWell(
                              key: const Key('dialog_tab_all'),
                              onTap: () => setDialogState(() => activeDialogTab = 2),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: activeDialogTab == 2 ? AppColors.card(context) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  border: activeDialogTab == 2 ? Border.all(color: AppColors.accentPurple.withOpacity(0.5)) : null,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.format_list_bulleted, size: 14, color: activeDialogTab == 2 ? AppColors.accentPurple : AppColors.textSecondary(context)),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Tümü',
                                      style: TextStyle(
                                        color: activeDialogTab == 2 ? AppColors.accentPurple : AppColors.textSecondary(context),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
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

                    if (activeDialogTab == 0 || activeDialogTab == 2) ...[
                      // Kiracı Section
                      Container(
                        margin: const EdgeInsets.only(bottom: 18),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.card(context),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.accentGreen.withOpacity(0.35)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: AppColors.accentGreen.withOpacity(0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.person, color: AppColors.accentGreen, size: 16),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Kiracı (Fiilen İkamet Eden Sakin)',
                                    style: TextStyle(
                                      color: AppColors.textPrimary(context),
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppColors.accentGreen.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    'Kiracı',
                                    style: TextStyle(
                                      color: AppColors.successText(context),
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text('Kiracı Ad Soyad *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                            const SizedBox(height: 6),
                            testId('tenant_name_field', TextField(
                              key: const Key('tenant_name_field'),
                              controller: tenantNameCtrl,
                              decoration: InputDecoration(
                                hintText: 'Örn: Canan Can',
                                errorText: tenantNameError,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            )),
                            const SizedBox(height: 12),
                            Text('Kiracı Telefon Numarası *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                            const SizedBox(height: 6),
                            testId('tenant_phone_field', TextField(
                              key: const Key('tenant_phone_field'),
                              controller: tenantPhoneCtrl,
                              keyboardType: TextInputType.phone,
                              decoration: InputDecoration(
                                hintText: 'Örn: 0533 111 22 33',
                                errorText: tenantPhoneError,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            )),
                            const SizedBox(height: 12),
                            Text('Kiracı E-posta Adresi *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                            const SizedBox(height: 6),
                            testId('tenant_email_field', TextField(
                              key: const Key('tenant_email_field'),
                              controller: tenantEmailCtrl,
                              keyboardType: TextInputType.emailAddress,
                              decoration: InputDecoration(
                                hintText: 'Örn: canan@example.com',
                                errorText: tenantEmailError,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            )),
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: isSaving ? null : () => _confirmRemoveTenantFromEdit(resident, ctx),
                                icon: const Icon(Icons.logout, size: 14, color: AppColors.accentOrange),
                                label: Text(
                                  'Kiracıyı Daireden Çıkar (Move-Out)',
                                  style: TextStyle(color: AppColors.warningText(context), fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Hane Sakinleri / Birlikte Yaşayanlar (Co-residents) in Edit Dialog
                      Builder(
                        builder: (context) {
                          final currentHo = widget.controller.homeOwners.firstWhere(
                            (h) => h.unitId == resident.unitId,
                            orElse: () => resident,
                          );
                          return Container(
                            margin: const EdgeInsets.only(bottom: 18),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: AppColors.card(context),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: AppColors.accentPurple.withOpacity(0.35)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: AppColors.accentPurple.withOpacity(0.12),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.family_restroom, color: AppColors.accentPurple, size: 16),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Hane Sakinleri / Birlikte Yaşayanlar (${currentHo.householdResidents.length})',
                                        style: TextStyle(
                                          color: AppColors.textPrimary(context),
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    testId('dialog_add_household_member', ElevatedButton.icon(
                                      key: const Key('dialog_add_household_member'),
                                      onPressed: () {
                                        _showAddHouseholdMemberDialog(currentHo);
                                        setDialogState(() {});
                                      },
                                      icon: const Icon(Icons.person_add_alt, size: 14),
                                      label: const Text('+ Hane Sakini Ekle', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.accentPurple,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        minimumSize: const Size(0, 32),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                    )),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                if (currentHo.householdResidents.isNotEmpty) ...[
                                  ...currentHo.householdResidents.map((m) => Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: AppColors.background(context),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: AppColors.border(context).withOpacity(0.5)),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.person_outline, size: 16, color: AppColors.accentPurple),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                m.fullName,
                                                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.bold),
                                              ),
                                              Text(
                                                '${HouseholdRelationship.labelFor(m.relationship)}${m.phone.isNotEmpty ? ' • ${m.phone}' : ''}${m.email.isNotEmpty ? ' • ${m.email}' : ''}',
                                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                              ),
                                            ],
                                          ),
                                        ),
                                        testId('dialog_edit_member_${m.id.isNotEmpty ? m.id : m.fullName}', IconButton(
                                          key: Key('dialog_edit_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                          icon: const Icon(Icons.edit_outlined, size: 16, color: AppColors.accentCyan),
                                          tooltip: 'Düzenle',
                                          onPressed: () {
                                            _showEditHouseholdMemberDialog(currentHo, m);
                                            setDialogState(() {});
                                          },
                                        )),
                                        testId('dialog_delete_member_${m.id.isNotEmpty ? m.id : m.fullName}', IconButton(
                                          key: Key('dialog_delete_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                          icon: const Icon(Icons.close, size: 16, color: AppColors.accentRed),
                                          tooltip: AppStrings.delete,
                                          onPressed: () {
                                            _confirmDeleteHouseholdMember(currentHo, m);
                                            setDialogState(() {});
                                          },
                                        )),
                                      ],
                                    ),
                                  )),
                                ] else ...[
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: AppColors.background(context),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      'Bu daireye kayıtlı ek hane sakini bulunmuyor. Yeni hane sakini eklemek için yukarıdaki butonu kullanabilirsiniz.',
                                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontStyle: FontStyle.italic),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ],

                    if (activeDialogTab == 1 || activeDialogTab == 2) ...[
                      // Kat Maliki (Ev Sahibi) Section
                      Container(
                        margin: const EdgeInsets.only(bottom: 18),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.card(context),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.accentCyan.withOpacity(0.35)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: AppColors.accentCyan.withOpacity(0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.vpn_key, color: AppColors.accentCyan, size: 16),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Kat Maliki (Ev Sahibi) Bilgileri',
                                    style: TextStyle(
                                      color: AppColors.textPrimary(context),
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppColors.accentCyan.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    'Ev Sahibi',
                                    style: TextStyle(
                                      color: AppColors.primaryText(context),
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text('Ev Sahibi Ad Soyad *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                            const SizedBox(height: 6),
                            testId('owner_name_field', TextField(
                              key: const Key('owner_name_field'),
                              controller: ownerNameCtrl,
                              decoration: InputDecoration(
                                hintText: 'Örn: Murat Demir',
                                errorText: ownerNameError,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            )),
                            const SizedBox(height: 12),
                            Text('Ev Sahibi Telefon Numarası *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                            const SizedBox(height: 6),
                            testId('owner_phone_field', TextField(
                              key: const Key('owner_phone_field'),
                              controller: ownerPhoneCtrl,
                              keyboardType: TextInputType.phone,
                              decoration: InputDecoration(
                                hintText: 'Örn: 0555 123 4567',
                                errorText: ownerPhoneError,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            )),
                            const SizedBox(height: 12),
                            Text('Ev Sahibi E-posta Adresi *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                            const SizedBox(height: 6),
                            testId('owner_email_field', TextField(
                              key: const Key('owner_email_field'),
                              controller: ownerEmailCtrl,
                              keyboardType: TextInputType.emailAddress,
                              decoration: InputDecoration(
                                hintText: 'Örn: murat@example.com',
                                errorText: ownerEmailError,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            )),
                          ],
                        ),
                      ),
                    ],
                  ] else ...[
                    // Kat Maliki (Non-tenant case)
                    Text('Ad Soyad *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: ownerNameCtrl,
                      decoration: InputDecoration(
                        hintText: 'Örn: Murat Demir',
                        errorText: ownerNameError,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),

                    const SizedBox(height: 14),

                    Text('Telefon Numarası *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: ownerPhoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        hintText: 'Örn: 0555 123 4567',
                        errorText: ownerPhoneError,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),

                    const SizedBox(height: 14),

                    Text('E-posta Adresi *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: ownerEmailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        hintText: 'Örn: murat@example.com',
                        errorText: ownerEmailError,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Hane Sakinleri / Birlikte Yaşayanlar (Co-residents) for Owner-Occupied Unit
                    Builder(
                      builder: (context) {
                        final currentHo = widget.controller.homeOwners.firstWhere(
                          (h) => h.unitId == resident.unitId,
                          orElse: () => resident,
                        );
                        return Container(
                          margin: const EdgeInsets.only(bottom: 18),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppColors.card(context),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: AppColors.accentPurple.withOpacity(0.35)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: AppColors.accentPurple.withOpacity(0.12),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.family_restroom, color: AppColors.accentPurple, size: 16),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Hane Sakinleri / Birlikte Yaşayanlar (${currentHo.householdResidents.length})',
                                      style: TextStyle(
                                        color: AppColors.textPrimary(context),
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  testId('dialog_add_household_member', ElevatedButton.icon(
                                    key: const Key('dialog_add_household_member'),
                                    onPressed: () {
                                      _showAddHouseholdMemberDialog(currentHo);
                                      setDialogState(() {});
                                    },
                                    icon: const Icon(Icons.person_add_alt, size: 14),
                                    label: const Text('+ Hane Sakini Ekle', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.accentPurple,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      minimumSize: const Size(0, 32),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  )),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (currentHo.householdResidents.isNotEmpty) ...[
                                ...currentHo.householdResidents.map((m) => Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: AppColors.background(context),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: AppColors.border(context).withOpacity(0.5)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.person_outline, size: 16, color: AppColors.accentPurple),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              m.fullName,
                                              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.bold),
                                            ),
                                            Text(
                                              '${HouseholdRelationship.labelFor(m.relationship)}${m.phone.isNotEmpty ? ' • ${m.phone}' : ''}${m.email.isNotEmpty ? ' • ${m.email}' : ''}',
                                              style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      ),
                                      testId('dialog_edit_member_${m.id.isNotEmpty ? m.id : m.fullName}', IconButton(
                                        key: Key('dialog_edit_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                        icon: const Icon(Icons.edit_outlined, size: 16, color: AppColors.accentCyan),
                                        tooltip: 'Düzenle',
                                        onPressed: () {
                                          _showEditHouseholdMemberDialog(currentHo, m);
                                          setDialogState(() {});
                                        },
                                      )),
                                      testId('dialog_delete_member_${m.id.isNotEmpty ? m.id : m.fullName}', IconButton(
                                        key: Key('dialog_delete_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                        icon: const Icon(Icons.close, size: 16, color: AppColors.accentRed),
                                        tooltip: AppStrings.delete,
                                        onPressed: () {
                                          _confirmDeleteHouseholdMember(currentHo, m);
                                          setDialogState(() {});
                                        },
                                      )),
                                    ],
                                  ),
                                )),
                              ] else ...[
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: AppColors.background(context),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'Bu daireye kayıtlı ek hane sakini bulunmuyor. Yeni hane sakini eklemek için yukarıdaki butonu kullanabilirsiniz.',
                                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontStyle: FontStyle.italic),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),

                    // Quick option to assign/move-in a tenant for this unit
                    Container(
                      margin: const EdgeInsets.only(bottom: 18),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.accentGreen.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.accentGreen.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.key, color: AppColors.accentGreen, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isTenant ? 'Yeni Kiracı Girişi (Move-In)' : 'Kiracı Tanımla (Move-In)',
                                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  isTenant
                                      ? 'Mevcut kiracıyı arşivleyip yeni bir kiracı için oturum başlatır.'
                                      : 'Daire kiraya verildiğinde veya yeni kiracı taşındığında oturum başlatır.',
                                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          testId('dialog_move_in_btn', ElevatedButton.icon(
                            key: const Key('dialog_move_in_btn'),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _showMoveInDialog(resident);
                            },
                            icon: const Icon(Icons.key, size: 14),
                            label: Text(
                              isTenant ? 'Kiracı Girişini Başlat' : 'Kiracı Girişini Başlat',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.successFill,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              minimumSize: const Size(0, 32),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                          )),
                        ],
                      ),
                    ),
                  ],

                  // House Type
                  if (currentHouseTypes.isNotEmpty) ...[
                    Text('Konut Tipi (Daire Tipi)', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: currentHouseTypes.any((ht) => ht.typeName == selectedHouseType)
                          ? selectedHouseType
                          : null,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                      hint: const Text('Konut Tipi Seçiniz'),
                      items: currentHouseTypes.map((ht) {
                        return DropdownMenuItem<String>(
                          value: ht.typeName,
                          child: Text('${ht.typeName} (${formatTry(ht.duesAmount)})'),
                        );
                      }).toList(),
                      onChanged: (val) {
                        setDialogState(() {
                          selectedHouseType = val;
                          final match = currentHouseTypes.firstWhere((ht) => ht.typeName == val);
                          duesCtrl.text = match.duesAmount.toStringAsFixed(2);
                        });
                      },
                    ),
                    const SizedBox(height: 14),
                  ] else ...[
                    SpGuidanceCard(
                      icon: Icons.home_work_outlined,
                      title: 'Konut tipi tanımlanmamış',
                      message: 'Eklemek veya düzenlemek için Konut Tipleri & Tarifeler ekranını açın.',
                      tone: SpTone.warning,
                      action: testId('edit_resident_add_house_type', OutlinedButton.icon(
                        key: const Key('edit_resident_add_house_type'),
                        onPressed: () async {
                          await _showManageHouseTypesDialog();
                          if (!context.mounted) return;
                          setDialogState(() {
                            final updatedTypes = widget.controller.houseTypes;
                            if (updatedTypes.isNotEmpty) {
                              selectedHouseType = updatedTypes.first.typeName;
                              duesCtrl.text = updatedTypes.first.duesAmount.toStringAsFixed(2);
                            }
                          });
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('Konut Tipleri & Tarifeler'),
                      )),
                    ),
                    const SizedBox(height: 14),
                  ],

                  // Monthly Dues (Non-editable, strictly governed by House Type tariff)
                  Row(
                    children: [
                      Text('Aylık Aidat Tutarı', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.accentCyan.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.lock, size: 10, color: AppColors.accentCyan),
                            SizedBox(width: 4),
                            Text(
                              'Konut tipine bağlı',
                              style: TextStyle(
                                color: AppColors.primaryText(context),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surface(context),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border(context)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.currency_lira, size: 18, color: AppColors.accentCyan),
                        const SizedBox(width: 8),
                        Text(
                          MoneyFormatter.tryParse(duesCtrl.text) == null
                              ? duesCtrl.text
                              : formatTry(MoneyFormatter.tryParse(duesCtrl.text)!),
                          style: TextStyle(
                            color: AppColors.textPrimary(context),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        if (selectedHouseType != null)
                          Text(
                            '$selectedHouseType Tarifesi',
                            style: TextStyle(
                              color: AppColors.textSecondary(context),
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Ödenecek aidat tutarı seçilen konut tipinin tarifesine göre sisteme otomatik işlenir.',
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  ),

                  const SizedBox(height: 14),

                  if (!isTenant) ...[
                    // Resident / Owner Switch
                    SwitchListTile(
                      title: const Text('Bu dairede fiilen ikamet ediyor mu? (Kat Sakini)'),
                      subtitle: Text(
                        isResident ? 'Evet (Kat Sakini)' : 'Hayır (Sadece Kat Maliki)',
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                      ),
                      value: isResident,
                      activeThumbColor: AppColors.accentCyan,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (val) {
                        setDialogState(() {
                          isResident = val;
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Entry to the account statement (aging, penalty, receipts as PDF), SPEC-007 R2.
  Widget _buildStatementEntryCard(String unitId, String subtitle) {
    return testId('resident_statement_entry', MergeSemantics(child: Semantics(button: true, child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => AppFullscreenPage.push(
        context: context,
        builder: (ctx) => ResidentStatementPage(unitId: unitId, subtitle: subtitle),
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Row(
          children: [
            const Icon(Icons.account_balance_wallet_outlined, color: AppColors.accentCyan),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Hesap Ekstresi', style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('Borç yaşlandırma, gecikme tazminatı ve makbuz PDF\'leri',
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: AppColors.textSecondary(context)),
          ],
        ),
      ),
    ))));
  }

  Widget _buildAccountActivitySection() {
    final transactions = widget.controller.accountTransactions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(child: Text(
              'HESAP HAREKETLERİ →',
              style: TextStyle(
                color: AppColors.textSecondary(context),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            )),
            InkWell(
              onTap: _showReceiptsDialog,
              child: Text(
                'Tümü',
                style: TextStyle(
                  color: AppColors.textSecondary(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.border(context), width: 1),
          ),
          child: transactions.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(Icons.history_toggle_off, color: AppColors.textSecondary(context), size: 36),
                        const SizedBox(height: 8),
                        Text(
                          'Henüz bir hesap hareketi bulunmuyor',
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Yapılan aidat tahakkukları veya banka transferleri burada listelenir.',
                          style: TextStyle(color: AppColors.textSecondary(context).withValues(alpha: 0.8), fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: transactions.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;
              final color = item.isCredit ? AppColors.accentGreen : AppColors.accentRed;
              final icon = item.isCredit
                  ? (item.title.contains('FAST') ? Icons.flash_on : Icons.check_circle_outline)
                  : Icons.apartment;

              return Column(
                children: [
                  testId('ledger_row_$index', InkWell(
                    onTap: item.isCredit ? () => _showSingleReceiptDetailDialog(item) : null,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              icon,
                              color: color,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.title,
                                  style: TextStyle(
                                    color: AppColors.textPrimary(context),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  item.subtitle,
                                  style: TextStyle(
                                    color: AppColors.textSecondary(context),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                item.amountStr,
                                style: TextStyle(
                                  color: color,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.date,
                                style: TextStyle(
                                  color: AppColors.textSecondary(context),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  )),
                  if (index < transactions.length - 1)
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: 14,
                      endIndent: 14,
                      color: AppColors.border(context),
                    ),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildMyUnitHouseholdCard() {
    final residents = widget.controller.unitResidents;
    final isHomeUser = widget.controller.userRole == UserRole.homeOwner ||
        widget.controller.userRole == UserRole.homeResident ||
        (widget.controller.userRole == UserRole.siteManager &&
            widget.controller.siteAdminPath == SiteAdminActivePath.myFlatOwner);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.people_outline, color: AppColors.accentCyan, size: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Hane Sakinleri (${widget.controller.activeUnit.block} Blok D:${widget.controller.activeUnit.unitNo})',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              if (isHomeUser)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    testId('btn_manual_add_resident', ElevatedButton.icon(
                      key: const Key('btn_manual_add_resident'),
                      onPressed: () => _showAddHouseholdMemberDialog(),
                      icon: const Icon(Icons.person_add_alt_1, size: 13, color: Colors.white),
                      label: const Text(
                        'Sakin Ekle',
                        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryFill,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    )),
                    const SizedBox(width: 6),
                    testId('btn_invite_resident_link', OutlinedButton.icon(
                      key: const Key('btn_invite_resident_link'),
                      onPressed: () => widget.controller.generateUnitInviteLink(),
                      icon: const Icon(Icons.share, size: 13, color: AppColors.accentOrange),
                      label: Text(
                        'Davet Linki',
                        style: TextStyle(color: AppColors.warningText(context), fontSize: 12),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.accentOrange),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    )),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (residents.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              alignment: Alignment.center,
              child: Column(
                children: [
                  Icon(Icons.group_outlined, size: 36, color: AppColors.textSecondary(context).withValues(alpha: 0.5)),
                  const SizedBox(height: 8),
                  Text(
                    'Henüz kayıtlı hane sakini bulunmuyor.',
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Yukarıdaki "Sakin Ekle" veya "Davet Linki" butonlarını kullanarak hane sakinlerinizi ekleyebilirsiniz.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textSecondary(context).withValues(alpha: 0.8), fontSize: 12),
                  ),
                ],
              ),
            ),
          ...residents.map((r) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.card(context),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.fullName,
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            HouseholdRelationship.labelFor(r.relationship),
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                          ),
                          if (r.phone.isNotEmpty || r.email.isNotEmpty)
                            Text(
                              [if (r.phone.isNotEmpty) r.phone, if (r.email.isNotEmpty) r.email].join(' • '),
                              style: TextStyle(color: AppColors.textSecondary(context).withValues(alpha: 0.7), fontSize: 12),
                            ),
                        ],
                      ),
                    ),
                    Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: r.isOwner
                                ? AppColors.accentCyan.withValues(alpha: 0.15)
                                : AppColors.card(context),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            r.isOwner ? 'Malik' : 'Sakin',
                            style: TextStyle(
                              color: r.isOwner ? AppColors.primaryText(context) : AppColors.textSecondary(context),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (!r.isOwner && isHomeUser) ...[
                          const SizedBox(width: 4),
                          testId('btn_delete_resident_${r.id}', IconButton(
                            key: Key('btn_delete_resident_${r.id}'),
                            icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.accentRed),
                            tooltip: 'Sakini Sil',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => _confirmDeleteHouseholdResident(r),
                          )),
                        ],
                      ])),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  void _confirmDeleteHouseholdResident(UnitResidentMember member) {
    showSpPage(
      context: context,
      builder: (ctx) => SpAlertPage(
        backgroundColor: AppColors.surface(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Hane Sakinini Sil', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        content: Text('${member.fullName} kişisini hane sakinlerinden kaldırmak istediğinize emin misiniz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(AppStrings.cancel),
          ),
          testId('btn_confirm_delete_resident', ElevatedButton(
            key: const Key('btn_confirm_delete_resident'),
            onPressed: () async {
              Navigator.pop(ctx);
              final success = await widget.controller.deleteHouseholdMember(residentId: member.id);
              if (success && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  appSnackBar(
                    content: Text('Hane sakini başarıyla kaldırıldı.'),
                    backgroundColor: AppColors.successFill,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.dangerFill),
            child: const Text(AppStrings.delete, style: TextStyle(color: Colors.white)),
          )),
        ],
      ),
    );
  }

  void _openProfileSheet(BuildContext context) {
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => ProfileRoleSheet(controller: widget.controller),
    );
  }

  void _showPaymentDialog(DuesLiability dues, {CheckoutPaymentMethod initialMethod = CheckoutPaymentMethod.card}) {
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => PaymentCheckoutDialog(
        dues: dues,
        siteName: widget.controller.activeUnit.siteName,
        unitDesc: '${widget.controller.activeUnit.block} Blok D:${widget.controller.activeUnit.unitNo}',
        virtualIban: widget.controller.userRole == UserRole.siteManager &&
                widget.controller.siteAdminPath == SiteAdminActivePath.myFlatOwner
            ? 'TR12 0006 2000 0000 0000 0001'
            : 'TR12 0006 2000 0000 0000 0014',
        initialMethod: initialMethod,
        unitId: widget.controller.activeUnit.id,
        onCardPaymentCaptured: (intent) {
          // The provider's capture already issued the receipt; reload the balances.
          widget.controller.fetchResidentDashboard();
          final paidAmount = intent.amount;
          final snackMsg = paidAmount > dues.totalAmount && dues.totalAmount > Decimal.zero
              ? '${formatTry(paidAmount)} tutarındaki kart ödemeniz alındı! Borcunuz kapatıldı, ${formatTry((paidAmount - dues.totalAmount))} avans bakiyenize aktarıldı.'
              : (paidAmount < dues.totalAmount
                  ? '${formatTry(paidAmount)} tutarındaki kısmi ödemeniz alındı. Kalan borç: ${formatTry((dues.totalAmount - paidAmount))}'
                  : (dues.totalAmount <= Decimal.zero
                      ? '${formatTry(paidAmount)} tutarı avans bakiyenize başarıyla aktarıldı.'
                      : '${formatTry(paidAmount)} tutarındaki kart ödemeniz başarıyla alındı! Borcunuz kapatıldı.'));
          ScaffoldMessenger.of(context).showSnackBar(
            appSnackBar(
              content: Text(snackMsg),
              backgroundColor: AppColors.successFill,
              duration: const Duration(seconds: 4),
            ),
          );
        },
      ),
    );
  }

  void _showDuesDetailDialog(DuesLiability dues) {
    final advPayment = widget.controller.activeUnit.advancePayment ?? Decimal.zero;
    final totalDebt = dues.totalAmount;
    final hasDebt = totalDebt > Decimal.zero;
    final duesList = widget.controller.duesList;

    if (!hasDebt) {
      AppFullscreenPage.push(
        context: context,
        builder: (ctx) => AppFullscreenPage(
          title: 'Hesap & Bakiye Özeti',
          subtitle: '${widget.controller.activeUnit.siteName} • ${widget.controller.activeUnit.block} Blok D:${widget.controller.activeUnit.unitNo}',
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.accentGreen.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.account_balance_wallet_outlined, color: AppColors.accentGreen, size: 20),
          ),
          bottomBar: AppFullscreenPage.buildBottomBar(
            context: ctx,
            children: [
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.successFill,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(AppStrings.close, style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Borç Durum Banner
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.accentGreen.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.accentGreen.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.accentGreen.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check_circle_outline, color: AppColors.accentGreen, size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Borç Durumu: Güncel',
                            style: TextStyle(
                              color: AppColors.successText(context),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Dairenize ait vadesi geçmiş veya bekleyen herhangi bir aidat borcu bulunmamaktadır.',
                            style: TextStyle(
                              color: AppColors.textSecondary(context),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 2. Avans Bakiye Kartı
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: AppColors.surface(context),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(child: Text(
                          'Mevcut Avans Bakiyesi (Alacak)',
                          style: TextStyle(
                            color: AppColors.textSecondary(context),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        )),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.accentGreen.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Kullanıma Hazır',
                            style: TextStyle(color: AppColors.successText(context), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '+${formatTry(advPayment)}',
                      style: TextStyle(
                        color: AppColors.successText(context),
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.card(context),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.border(context)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.info_outline, size: 18, color: AppColors.accentCyan),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Avans bakiyeniz, gelecek aylarda yeni aidatlar tahakkuk ettiğinde (ör. ay başında) otomatik olarak borçtan mahsup edilir. Herhangi bir ek işlem yapmanıza gerek kalmaz.',
                              style: TextStyle(
                                color: AppColors.textPrimary(context),
                                fontSize: 12,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 3. Dönemsel Aidat Durumu
              Text(
                'DÖNEMSEL AİDAT DURUMU',
                style: TextStyle(
                  color: AppColors.textSecondary(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface(context),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Column(
                  children: duesList.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final d = entry.value;
                    final isPaid = d.status == DebtStatus.paid || d.totalAmount <= Decimal.zero;

                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    d.period,
                                    style: TextStyle(
                                      color: AppColors.textPrimary(context),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    isPaid ? 'Ödendi • Borç Bulunmuyor' : 'Vadesi: ${d.dueDate.day}.${d.dueDate.month}.${d.dueDate.year}',
                                    style: TextStyle(
                                      color: AppColors.textSecondary(context),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
                                  Text(
                                    formatTry(d.principalAmount),
                                    style: TextStyle(
                                      color: AppColors.textPrimary(context),
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: isPaid
                                          ? AppColors.accentGreen.withValues(alpha: 0.15)
                                          : AppColors.accentRed.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      isPaid ? 'Ödendi' : 'Bekliyor',
                                      style: TextStyle(
                                        color: isPaid ? AppColors.successText(context) : AppColors.dangerText(context),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ])),
                            ],
                          ),
                        ),
                        if (idx < duesList.length - 1)
                          Divider(
                            height: 1,
                            thickness: 1,
                            indent: 14,
                            endIndent: 14,
                            color: AppColors.border(context),
                          ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      AppFullscreenPage.push(
        context: context,
        builder: (ctx) => AppFullscreenPage(
          title: 'Aidat Borç Detayı',
          subtitle: '${dues.period} • KMK Madde 20 Yasal Gecikme Cetveli',
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.accentCyan.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.calculate_outlined, color: AppColors.accentCyan, size: 20),
          ),
          bottomBar: AppFullscreenPage.buildBottomBar(
            context: ctx,
            children: [
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryFill,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(AppStrings.close, style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.card(context),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Kat Mülkiyeti Kanunu (KMK) Madde 20 Uyarınca:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    Text('• Dönem: ${dues.period}', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13)),
                    const SizedBox(height: 8),
                    Text('• Ana Para Aidat: ${formatTry(dues.principalAmount)}', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text('• Son Ödeme Tarihi: ${dues.dueDate.day.toString().padLeft(2, '0')}.${dues.dueDate.month.toString().padLeft(2, '0')}.${dues.dueDate.year}', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13)),
                    if (dues.delayPenalty > Decimal.zero) ...[
                      const SizedBox(height: 8),
                      testId('penalty_days', Text('• Gecikme Durumu: ${dues.daysOverdue} Gün Gecikme', style: TextStyle(color: AppColors.dangerText(context), fontSize: 13, fontWeight: FontWeight.w500))),
                      const SizedBox(height: 8),
                      Text('• Aylık Yasal Gecikme Oranı: %5 (KMK Madde 20/c)', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13)),
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.accentRed.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.accentRed.withValues(alpha: 0.2)),
                        ),
                        child: testId('penalty_formula', Text(
                          '• Gecikme Tazminatı: (${formatTry(dues.principalAmount)} × %5 / 30) * ${dues.daysOverdue} = ${formatTry(dues.delayPenalty)}',
                          style: TextStyle(color: AppColors.dangerText(context), fontWeight: FontWeight.bold, fontSize: 12.5),
                        )),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Divider(color: AppColors.border(context)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(child: const Text('Ödenecek Toplam Tutar:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                        Flexible(child: Text(formatTry(dues.totalAmount), style: TextStyle(color: AppColors.dangerText(context), fontWeight: FontWeight.bold, fontSize: 16))),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  void _showReceiptsDialog() {
    final creditTransactions = widget.controller.accountTransactions
        .where((t) => t.isCredit)
        .toList();

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: 'Ödeme Makbuzları & Dekontlar',
        subtitle: '${widget.controller.activeUnit.siteName} • ${widget.controller.activeUnit.block} Blok D:${widget.controller.activeUnit.unitNo}',
        icon: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.accentCyan.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.receipt_long, color: AppColors.accentCyan, size: 20),
        ),
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryFill,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(AppStrings.close, style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        child: creditTransactions.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Column(
                    children: [
                      Icon(Icons.receipt_outlined, size: 48, color: AppColors.textSecondary(context)),
                      const SizedBox(height: 12),
                      Text(
                        'Henüz onaylanmış bir ödeme dekontu bulunmuyor.',
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                      ),
                    ],
                  ),
                ),
              )
            : Column(
                children: creditTransactions.map((tx) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildReceiptItem(tx),
                  );
                }).toList(),
              ),
      ),
    );
  }

  Widget _buildReceiptItem(AccountTransactionItem tx) {
    return InkWell(
      onTap: () => _showSingleReceiptDetailDialog(tx),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.card(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.receipt_outlined, size: 18, color: AppColors.accentGreen),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tx.title,
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${tx.date} • ${tx.subtitle}',
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  tx.amountStr,
                  style: TextStyle(
                    color: AppColors.successText(context),
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Görüntüle',
                      style: TextStyle(
                        color: AppColors.primaryText(context),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 2),
                    const Icon(Icons.chevron_right, size: 12, color: AppColors.accentCyan),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showSingleReceiptDetailDialog(AccountTransactionItem tx) {
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: 'Ödeme Dekontu Detayı',
        subtitle: 'Resmi Dijital Tahsilat Belgesi',
        icon: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.accentGreen.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.verified, color: AppColors.accentGreen, size: 20),
        ),
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryFill,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(AppStrings.close, style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(child: Text(
                    'TAHSİLAT MAKBUZU',
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  )),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'ONAYLANDI',
                      style: TextStyle(color: AppColors.successText(context), fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Center(
                child: Column(
                  children: [
                    testId('home_receipt_amount', Text(
                      tx.amountStr,
                      style: TextStyle(
                        color: AppColors.successText(context),
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    )),
                    const SizedBox(height: 4),
                    Text(
                      tx.title,
                      style: TextStyle(
                        color: AppColors.textPrimary(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Divider(color: AppColors.border(context)),
              const SizedBox(height: 12),
              testId('home_receipt_number', _buildReceiptRow('İşlem / Makbuz No:', tx.receiptNumber ?? tx.id)),
              const SizedBox(height: 8),
              _buildReceiptRow('İşlem Tarihi:', tx.date),
              const SizedBox(height: 8),
              _buildReceiptRow('Site & Daire:', '${widget.controller.activeUnit.siteName.isNotEmpty ? widget.controller.activeUnit.siteName : widget.controller.siteName} • ${widget.controller.activeUnit.block} Blok D:${widget.controller.activeUnit.unitNo}'),
              const SizedBox(height: 8),
              _buildReceiptRow('Ödeyen:', widget.controller.activeUnit.ownerName.isNotEmpty ? widget.controller.activeUnit.ownerName : (widget.controller.isTestMode ? 'Ahmet Yılmaz' : 'Daire Sakini')),
              const SizedBox(height: 8),
              _buildReceiptRow('Açıklama:', tx.subtitle),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.background(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.security, size: 16, color: AppColors.accentGreen),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Bu makbuz SitePulse elektronik aidat yönetim sistemi tarafından doğrulanmıştır.',
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReceiptRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(child: Text(
          label,
          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
        )),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  void _showIssueReportDialog() {
    String selectedCategory = 'Asansör';
    final descCtrl = TextEditingController();

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AppFullscreenPage(
          title: 'Yönetime Talep & Arıza',
          subtitle: 'Teknik ve idari bildirim formu',
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.accentCyan.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.build_circle_outlined, color: AppColors.accentCyan, size: 20),
          ),
          bottomBar: AppFullscreenPage.buildBottomBar(
            context: ctx,
            children: [
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: AppColors.border(context)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(AppStrings.cancel, style: TextStyle(color: AppColors.textSecondary(context), fontWeight: FontWeight.w600)),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    appSnackBar(
                      content: Text('Talebiniz #TLP-842 numarasıyla site yönetimine iletildi.'),
                      backgroundColor: AppColors.successFill,
                      duration: Duration(seconds: 3),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryFill,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Talebi Gönder', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Arıza veya Talep Kategorisi',
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ['Asansör', 'Tesisat / Su', 'Aydınlatma', 'Otopark', 'Diğer'].map((cat) {
                  final isSelected = selectedCategory == cat;
                  return ChoiceChip(
                    label: Text(cat, style: TextStyle(fontSize: 12, color: isSelected ? Colors.white : AppColors.textPrimary(context))),
                    selected: isSelected,
                    selectedColor: AppColors.accentCyan,
                    backgroundColor: AppColors.card(context),
                    side: BorderSide(color: isSelected ? AppColors.accentCyan : AppColors.border(context)),
                    onSelected: (_) => setDlgState(() => selectedCategory = cat),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              Text(
                'Açıklama',
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descCtrl,
                maxLines: 4,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Sorunun yerini ve detayını kısaca yazın...',
                  hintStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.card(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: AppColors.accentCyan),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Acil teknik durumlar için site görevlisini (Dahili: 101) doğrudan arayabilirsiniz.',
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAnnouncementsDialog() {
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: 'Site Duyuruları',
        subtitle: 'Yönetim kurulu güncel bilgilendirmeleri',
        icon: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.accentGreen.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.campaign_outlined, color: AppColors.accentGreen, size: 20),
        ),
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryFill,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(AppStrings.close, style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        child: Column(
          children: [
          testId('site_announcement', _buildAnnouncementItem(
              tag: 'Site Duyurusu',
              tagColor: AppColors.accentCyan,
              title: widget.controller.announcementTitle,
              date: 'Güncel',
              desc: widget.controller.announcementContent,
            )),
          ],
        ),
      ),
    );
  }

  void _showCreateAnnouncementPage() {
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AnnouncementComposerPage(
        onSubmit: widget.controller.createAnnouncement,
      ),
    );
  }

  Widget _buildAnnouncementItem({
    required String tag,
    required Color tagColor,
    required String title,
    required String date,
    required String desc,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: tagColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: tagColor.withValues(alpha: 0.4)),
                ),
                child: Text(
                  tag,
                  style: TextStyle(color: tagColor, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  date,
                  textAlign: TextAlign.end,
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          testId('site_announcement_title', Text(
            title,
            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.bold),
          )),
          const SizedBox(height: 6),
          testId('site_announcement_body', Text(
            desc,
            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, height: 1.35),
          )),
        ],
      ),
    );
  }

  void _showInviteDialog(UnitInviteInfo invite) {
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: invite.title,
        subtitle: 'Kapsam: ${invite.unitLabel} • ${invite.expiresAtStr}',
        icon: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.accentOrange.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.share, color: AppColors.accentOrange, size: 20),
        ),
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            testId('btn_copy_invite_link', OutlinedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                // Invitation URLs are copied verbatim (no IBAN normalisation).
                await spCopyToClipboard(context, invite.inviteUrl, successMessage: 'Davet linki kopyalandı!');
              },
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: BorderSide(color: AppColors.border(context)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text('Linki Kopyala', style: TextStyle(color: AppColors.primaryText(context), fontWeight: FontWeight.w600)),
            )),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.card(context),
                foregroundColor: AppColors.textPrimary(context),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(AppStrings.close, style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.card(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: testId('invite_link_text', SelectableText(
                invite.inviteUrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontFamily: 'monospace'),
              ), label: invite.inviteUrl),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.card(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.shield_outlined, size: 18, color: AppColors.accentOrange),
                  const SizedBox(width: 10),
                  Expanded(
                    child: testId('invite_security_notice', Text(
                      invite.securityNotice,
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, height: 1.4),
                    )),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showApprovalSuccessDialog(ApprovalSuccessInfo info) {
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: 'Başvuru Onaylandı!',
        subtitle: '${info.fullName} (${info.flatDesc})',
        icon: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.accentGreen.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.check_circle, color: AppColors.accentGreen, size: 20),
        ),
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            testId('btn_close_approval_dialog', ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.successFill,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(AppStrings.ok, style: TextStyle(fontWeight: FontWeight.bold)),
            )),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Kullanıcının başvurusu onaylandı ve sisteme dahil edildi.', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 14)),
            const SizedBox(height: 16),
            Text('Üretilen Geçici Sakin Şifresi:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.card(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accentGreen),
              ),
              child: testId('approval_credentials_password', SelectableText(
                info.temporaryPassword,
                style: TextStyle(color: AppColors.successText(context), fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ), label: info.temporaryPassword),
            ),
            const SizedBox(height: 14),
            Text('Şifre ve giriş linki ${info.email} adresine SMS ve e-posta olarak iletildi.', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, height: 1.4)),
          ],
        ),
      ),
    );
  }

  void _showSiteProvisionedDialog(ProvisionedSiteCredentials creds) {
    final title = creds.isRenewal ? 'Geçici Yönetim Şifresi Yenilendi!' : 'Yeni Site & Yönetici Hazır!';
    final subtitle = creds.isRenewal
        ? '${creds.siteName} yöneticisi için yeni bir geçici şifre üretildi. Yönetici ilk girişte şifresini değiştirmek zorundadır.'
        : '${creds.siteName} başarıyla platforma kaydedildi.';
    final icon = creds.isRenewal ? Icons.key : Icons.apartment;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: title,
        subtitle: subtitle,
        icon: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.accentCyan.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: AppColors.accentCyan, size: 20),
        ),
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            testId('btn_close_site_credentials', ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                widget.controller.fetchSaasSites();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryFill,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(AppStrings.ok, style: TextStyle(fontWeight: FontWeight.bold)),
            )),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Yönetici: ${creds.adminName} (${creds.adminEmail})', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13)),
            const SizedBox(height: 16),
            Text('Geçici Yönetim Şifresi:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.card(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accentCyan),
              ),
              child: testId('site_credentials_password', SelectableText(
                creds.temporaryPassword,
                style: TextStyle(color: AppColors.primaryText(context), fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ), label: creds.temporaryPassword),
            ),
          ],
        ),
      ),
    );
  }

  void _showHomeOwnerProvisionedDialog(ProvisionedHomeOwnerCredentials creds) {
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: 'Sakin Kaydedildi!',
        subtitle: '${creds.ownerName} (${creds.block} D:${creds.unitNo}) başarıyla eklendi.',
        icon: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.accentGreen.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.person_add, color: AppColors.accentGreen, size: 20),
        ),
        bottomBar: AppFullscreenPage.buildBottomBar(
          context: ctx,
          children: [
            testId('btn_close_resident_provisioned', ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.successFill,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(AppStrings.ok, style: TextStyle(fontWeight: FontWeight.bold)),
            )),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            testId('resident_activation_status', SpGuidanceCard(
              icon: creds.activationStatus == 'SENT' ? Icons.mark_email_read_outlined : Icons.report_gmailerrorred_outlined,
              title: creds.activationStatus == 'SENT' ? 'Etkinleştirme bağlantısı gönderildi' : 'Etkinleştirme bekliyor',
              message: activationStatusMessage(creds.activationStatus, creds.email),
              tone: creds.activationStatus == 'SENT' ? SpTone.success : SpTone.warning,
              tonedBorder: true,
            ), label: activationStatusMessage(creds.activationStatus, creds.email)),
            for (final warning in creds.warnings) ...[
              const SizedBox(height: AppSpacing.md),
              testId('resident_warning_${warning.toLowerCase()}', SpGuidanceCard(
                icon: Icons.info_outline,
                title: 'Kontrol edin',
                message: registrationWarningMessage(warning),
                tone: SpTone.warning,
              )),
            ],
          ],
        ),
      ),
    );
  }

  void _showAddResidentDialog() {
    final availableBlocks = widget.controller.blocks;
    String? selectedBlock = availableBlocks.isNotEmpty ? availableBlocks.first : 'A Blok';
    final unitCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final landShareCtrl = TextEditingController();
    final ownerNameCtrl = TextEditingController();
    final ownerEmailCtrl = TextEditingController();
    final ownerPhoneCtrl = TextEditingController();

    // Tenant controllers when role == 'OWNER' and owner does not reside (isResidentOwner == false && rented)
    final tenantNameCtrl = TextEditingController();
    final tenantEmailCtrl = TextEditingController();
    final tenantPhoneCtrl = TextEditingController();

    // Dynamic co-residents (Hane Sakinleri)
    final pendingResidents = <_PendingResidentEntry>[];

    // Default to first house type if available (e.g. 2+1 or 3+1)
    final houseTypes = widget.controller.houseTypes;
    String? selectedHouseType = houseTypes.isNotEmpty ? houseTypes.first.typeName : null;
    String selectedRole = 'OWNER';
    bool isResidentOwner = true;
    String ownerNotResidentOccupancy = 'VACANT'; // 'VACANT' or 'TENANT'
    String selectedRelationship = HouseholdRelationship.spouse.code;
    bool showSecondaryOwner = true;
    String? emailError;
    String? phoneError;
    String? generalError;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final rawBlocks = widget.controller.blocks;
          final seenBlocks = <String>{};
          final currentBlocks = <String>[];
          for (final b in rawBlocks) {
            final trimmed = b.trim();
            if (trimmed.isNotEmpty && seenBlocks.add(trimmed.toLowerCase())) {
              currentBlocks.add(trimmed);
            }
          }
          if (currentBlocks.isEmpty) {
            currentBlocks.addAll(['A Blok', 'B Blok']);
          }

          if (selectedBlock == null || !currentBlocks.any((b) => b.toLowerCase() == selectedBlock!.toLowerCase())) {
            selectedBlock = currentBlocks.first;
          } else {
            selectedBlock = currentBlocks.firstWhere((b) => b.toLowerCase() == selectedBlock!.toLowerCase());
          }

          final currentHouseTypes = widget.controller.houseTypes;
          // Ensure selectedHouseType is valid
          if (selectedHouseType == null && currentHouseTypes.isNotEmpty) {
            selectedHouseType = currentHouseTypes.first.typeName;
          }
          final currentTariff = currentHouseTypes.cast<HouseTypeTariff?>().firstWhere(
            (t) => t?.typeName == selectedHouseType,
            orElse: () => null,
          );

          return AppFullscreenPage(
            title: 'Yeni Daire / Sakin Ekle',
            subtitle: 'Önce daire (bağımsız bölüm) tanımlanır, ardından ikamet eden sakin ve kişiler belirlenir.',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentGreen.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.domain_add_outlined, color: AppColors.accentGreen, size: 20),
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
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: BorderSide(color: AppColors.border(context)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(AppStrings.cancel, style: TextStyle(color: AppColors.textSecondary(context), fontWeight: FontWeight.w600)),
                ),
                testId('btn_save_new_resident', ElevatedButton(
                  onPressed: () async {
                    setDialogState(() {
                      emailError = null;
                      phoneError = null;
                      generalError = null;
                    });

                    final ownerName = nameCtrl.text.trim();
                    final unitText = unitCtrl.text.trim();
                    final emailText = emailCtrl.text.trim();
                    final phoneText = phoneCtrl.text.trim();

                    if (ownerName.isEmpty || unitText.isEmpty) {
                      setDialogState(() {
                        generalError = 'Lütfen Sakin Ad Soyad ve Daire No alanlarını doldurunuz.';
                      });
                      return;
                    }

                    final parsedUnit = int.tryParse(unitText);
                    if (parsedUnit == null || parsedUnit <= 0) {
                      setDialogState(() {
                        generalError = 'Lütfen geçerli bir Daire No giriniz.';
                      });
                      return;
                    }

                    if (selectedBlock == null || selectedBlock!.trim().isEmpty) {
                      setDialogState(() {
                        generalError = 'Lütfen bir blok seçiniz.';
                      });
                      return;
                    }

                    if (selectedHouseType == null || selectedHouseType!.isEmpty) {
                      setDialogState(() {
                        generalError = 'Lütfen daire için bir Konut Tipi (örn: 2+1, 3+1) seçiniz.';
                      });
                      return;
                    }

                    // U2: the server's rules, checked next to each field before sending.
                    final emailProblem = validatePersonEmail(emailText);
                    final phoneProblem = validateTrMobile(phoneText);
                    final landShareProblem = validateLandShare(landShareCtrl.text);
                    final tenantContactsProblem = selectedRole == 'OWNER' && !isResidentOwner &&
                            ownerNotResidentOccupancy == 'TENANT'
                        ? validatePersonEmail(tenantEmailCtrl.text, required: false) ??
                            validateTrMobile(tenantPhoneCtrl.text, required: false)
                        : null;
                    if (emailProblem != null || phoneProblem != null || landShareProblem != null || tenantContactsProblem != null) {
                      setDialogState(() {
                        emailError = emailProblem;
                        phoneError = phoneProblem;
                        generalError = landShareProblem ?? tenantContactsProblem;
                      });
                      return;
                    }

                    // Check if unit already has an occupant:
                    // If adding a new OWNER or TENANT (not RESIDENT), confirm moving/archiving the older occupant!
                    if (selectedRole != 'RESIDENT') {
                      final cleanB = selectedBlock!.replaceAll('Blok', '').trim();
                      final existing = widget.controller.homeOwners.cast<HomeOwnerItem?>().firstWhere(
                        (h) {
                          if (h == null) return false;
                          final b1 = h.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
                          final b2 = cleanB.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
                          return h.unitNo == parsedUnit && b1 == b2;
                        },
                        orElse: () => null,
                      );

                      if (existing != null) {
                        final existingName = existing.tenantFullName ?? existing.ownerFullName;
                        final roleLabel = selectedRole == 'OWNER' ? 'Kat Maliki' : 'Kiracı';
                        final confirmed = await AppFullscreenPage.pushConfirmation(
                          context: ctx,
                          title: 'Yeni $roleLabel Atama Onayı',
                          message: '${selectedBlock!} Daire $parsedUnit için halihazırda kayıtlı sakin: "$existingName".\n\n'
                                   'Yeni $roleLabel atandığında mevcut sakin tahliye edilmiş olarak geçmişe arşivlenecek ve yeni $roleLabel aktif sakin olarak sisteme işlenecektir.\n\n'
                                   'Bu işlemi onaylıyor musunuz?',
                          confirmLabel: 'Evet, Yeni $roleLabel Ata',
                          cancelLabel: AppStrings.cancel,
                          confirmColor: AppColors.accentCyan,
                          icon: Icons.swap_horiz_rounded,
                          iconColor: AppColors.accentCyan,
                        );

                        if (confirmed != true) {
                          return;
                        }
                      }
                    }

                    if (!ctx.mounted) return;
                    final landShare = parseLandShare(landShareCtrl.text);

                    if (selectedRole == 'TENANT') {
                      final hasSecondaryOwner = ownerNameCtrl.text.trim().isNotEmpty;
                      await widget.controller.registerHomeOwner(
                        block: selectedBlock!,
                        unitNo: parsedUnit,
                        ownerName: hasSecondaryOwner ? ownerNameCtrl.text.trim() : ownerName,
                        email: hasSecondaryOwner ? (ownerEmailCtrl.text.trim().isNotEmpty ? ownerEmailCtrl.text.trim() : emailText) : emailText,
                        phone: hasSecondaryOwner ? (ownerPhoneCtrl.text.trim().isNotEmpty ? ownerPhoneCtrl.text.trim() : phoneText) : phoneText,
                        tenantFullName: ownerName,
                        tenantEmail: emailText,
                        tenantPhone: phoneText,
                        houseType: selectedHouseType,
                        duesAmount: currentTariff?.duesAmount,
                        landShare: landShare,
                        isResident: false,
                        role: selectedRole,
                      );
                    } else if (selectedRole == 'RESIDENT') {
                      await widget.controller.registerHomeOwner(
                        block: selectedBlock!,
                        unitNo: parsedUnit,
                        ownerName: ownerName,
                        email: emailText,
                        phone: phoneText,
                        houseType: selectedHouseType,
                        duesAmount: currentTariff?.duesAmount,
                        landShare: landShare,
                        isResident: true,
                        role: selectedRole,
                        relationship: selectedRelationship,
                      );
                    } else {
                      // OWNER
                      final isRented = !isResidentOwner && ownerNotResidentOccupancy == 'TENANT';
                      await widget.controller.registerHomeOwner(
                        block: selectedBlock!,
                        unitNo: parsedUnit,
                        ownerName: ownerName,
                        email: emailText,
                        phone: phoneText,
                        tenantFullName: isRented && tenantNameCtrl.text.trim().isNotEmpty ? tenantNameCtrl.text.trim() : null,
                        tenantEmail: isRented && tenantEmailCtrl.text.trim().isNotEmpty ? tenantEmailCtrl.text.trim() : null,
                        tenantPhone: isRented && tenantPhoneCtrl.text.trim().isNotEmpty ? tenantPhoneCtrl.text.trim() : null,
                        houseType: selectedHouseType,
                        duesAmount: currentTariff?.duesAmount,
                        landShare: landShare,
                        isResident: isResidentOwner,
                        role: isRented ? 'TENANT' : selectedRole,
                      );
                    }

                    // The page stays open until the server has answered; a refusal is shown here.
                    final registrationError = widget.controller.lastHomeOwnerError;
                    if (registrationError != null) {
                      if (ctx.mounted) setDialogState(() => generalError = registrationError);
                      return;
                    }
                    if (ctx.mounted) Navigator.pop(ctx);

                    // Save any pending household co-residents
                    if (pendingResidents.isNotEmpty) {
                      final cleanB = selectedBlock!.replaceAll('Blok', '').trim();
                      final registeredHo = widget.controller.homeOwners.cast<HomeOwnerItem?>().firstWhere(
                        (h) {
                          if (h == null) return false;
                          final b1 = h.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
                          final b2 = cleanB.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
                          return h.unitNo == parsedUnit && b1 == b2;
                        },
                        orElse: () => null,
                      );
                      final targetUnitId = registeredHo?.unitId ?? '$parsedUnit';

                      for (final res in pendingResidents) {
                        final resName = res.nameCtrl.text.trim();
                        if (resName.isNotEmpty) {
                          await widget.controller.addHouseholdMember(
                            unitId: targetUnitId,
                            block: selectedBlock!,
                            unitNo: parsedUnit,
                            fullName: resName,
                            // No invented contact details for household members.
                            phone: res.phoneCtrl.text.trim(),
                            email: res.emailCtrl.text.trim(),
                            relationship: res.relationship,
                          );
                        }
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.successFill,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Kaydet & Şifre Üret', style: TextStyle(fontWeight: FontWeight.bold)),
                )),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (generalError != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, color: AppColors.accentRed, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              generalError!,
                              style: TextStyle(color: AppColors.dangerText(context), fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // =========================================================
                  // SECTION 1: DAİRE (BAĞIMSIZ BÖLÜM) BİLGİLERİ (DEFINED ONCE)
                  // =========================================================
                  // =========================================================
                  // SECTION 1: DAİRE (BAĞIMSIZ BÖLÜM) BİLGİLERİ (DEFINED ONCE)
                  // =========================================================
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    margin: const EdgeInsets.only(bottom: 8),
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
                            const Icon(Icons.apartment, size: 16, color: AppColors.accentCyan),
                            const SizedBox(width: 6),
                            Text(
                              '1. Daire (Bağımsız Bölüm) Bilgisi',
                              style: TextStyle(
                                color: AppColors.textPrimary(context),
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            const Spacer(),
                            if (currentTariff != null)
                              Text(
                                '${formatTry(currentTariff.duesAmount)}/ay',
                                style: TextStyle(
                                  color: AppColors.successText(context),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),

                        // Blok Seçimi & Daire No (unitCtrl MUST be the 1st TextField at index 0)
                        Row(
                          children: [
                            Expanded(
                              flex: 5,
                              child: testId('add_resident_block_dropdown', DropdownButtonFormField<String>(
                                key: const Key('add_resident_block_dropdown'),
                                value: currentBlocks.contains(selectedBlock) ? selectedBlock : (currentBlocks.isNotEmpty ? currentBlocks.first : null),
                                dropdownColor: AppColors.card(context),
                                isDense: true,
                                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                                decoration: InputDecoration(
                                  labelText: 'Blok Seçiniz',
                                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                  filled: true,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  fillColor: AppColors.surface(context),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                items: currentBlocks.map((b) {
                                  return DropdownMenuItem<String>(
                                    value: b,
                                    child: Text(b, style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.w600, fontSize: 12)),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setDialogState(() {
                                      selectedBlock = val;
                                    });
                                  }
                                },
                              )),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip: 'Yeni Blok Tanımla',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              icon: const Icon(Icons.add_circle, color: AppColors.accentCyan, size: 20),
                              onPressed: () {
                                final newBlockCtrl = TextEditingController();
                                showSpPage(
                                  context: context,
                                  builder: (dCtx) => SpAlertPage(
                                    backgroundColor: AppColors.card(context),
                                    title: Text('Yeni Blok Tanımla', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 15)),
                                    content: TextField(
                                      controller: newBlockCtrl,
                                      style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                                      decoration: InputDecoration(
                                        labelText: 'Blok Adı (örn: C Blok)',
                                        labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                                        border: const OutlineInputBorder(),
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(dCtx),
                                        child: const Text(AppStrings.cancel),
                                      ),
                                      ElevatedButton(
                                        onPressed: () async {
                                          final nb = newBlockCtrl.text.trim();
                                          if (nb.isNotEmpty) {
                                            Navigator.pop(dCtx);
                                            await widget.controller.saveBlock(blockName: nb);
                                            setDialogState(() {
                                              selectedBlock = nb;
                                            });
                                          }
                                        },
                                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryFill),
                                        child: const Text('Ekle', style: TextStyle(color: Colors.white)),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                            const SizedBox(width: 8),

                            // Daire No (MUST BE TextField at index 0 in the dialog for test compatibility)
                            Expanded(
                              flex: 4,
                              child: testId('add_resident_unit_field', TextField(
                                controller: unitCtrl,
                                keyboardType: TextInputType.number,
                                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                                decoration: InputDecoration(
                                  labelText: 'Daire No',
                                  hintText: 'Örn: 14',
                                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                  filled: true,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  fillColor: AppColors.surface(context),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              )),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),

                        // Konut Tipi & Tarife Seçimi
                        Row(
                          children: [
                            Expanded(
                              child: currentHouseTypes.isEmpty
                                  ? Text(
                                      'Konut tipi yok. Eklemek için:',
                                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                    )
                                  : DropdownButtonFormField<String>(
                                value: currentHouseTypes.any((t) => t.typeName == selectedHouseType)
                                    ? selectedHouseType
                                    : (currentHouseTypes.isNotEmpty ? currentHouseTypes.first.typeName : null),
                                isDense: true,
                                dropdownColor: AppColors.card(context),
                                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                                decoration: InputDecoration(
                                  labelText: 'Konut Tipi (Daire Tipi)',
                                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                  filled: true,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  fillColor: AppColors.surface(context),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                items: currentHouseTypes.map((ht) {
                                  return DropdownMenuItem<String>(
                                    value: ht.typeName,
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          ht.typeName,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 12,
                                            color: AppColors.textPrimary(context),
                                          ),
                                        ),
                                        Text(
                                          '${formatTry(ht.duesAmount)} / ay',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                            color: AppColors.successText(context),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  setDialogState(() {
                                    selectedHouseType = val;
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: () async {
                                await _showManageHouseTypesDialog();
                                setDialogState(() {});
                              },
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                minimumSize: const Size(40, 24),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text(
                                'Konut Tipleri & Tarifeler',
                                style: TextStyle(color: AppColors.accentPurple, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // =========================================================
                  // SECTION 2: İKAMET EDEN SAKİN & KİŞİ BİLGİLERİ (PEOPLE BELOW UNIT)
                  // =========================================================
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                            const Icon(Icons.person_pin_outlined, size: 16, color: AppColors.accentGreen),
                            const SizedBox(width: 6),
                            Text(
                              '2. İkamet Eden Sakin & Kişi Tanımları',
                              style: TextStyle(
                                color: AppColors.textPrimary(context),
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),

                        // Role Selector
                        SizedBox(
                          width: double.infinity,
                          child: testId('add_resident_role_selector', SegmentedButton<String>(
                            key: const Key('add_resident_role_selector'),
                            segments: const [
                              ButtonSegment<String>(
                                value: 'OWNER',
                                label: Text('Kat Maliki'),
                                icon: Icon(Icons.vpn_key_outlined, size: 16),
                              ),
                              ButtonSegment<String>(
                                value: 'TENANT',
                                label: Text('Kiracı'),
                                icon: Icon(Icons.key, size: 16),
                              ),
                              ButtonSegment<String>(
                                value: 'RESIDENT',
                                label: Text('Ev Sakini'),
                                icon: Icon(Icons.family_restroom, size: 16),
                              ),
                            ],
                            selected: {selectedRole},
                            onSelectionChanged: (newSelection) {
                              setDialogState(() {
                                selectedRole = newSelection.first;
                                if (selectedRole == 'TENANT') {
                                  showSecondaryOwner = true;
                                }
                              });
                            },
                          )),
                        ),
                        const SizedBox(height: 12),

                        // Role Specific Information Banner & Controls
                        if (selectedRole == 'OWNER') ...[
                          Material(
                            color: Colors.transparent,
                            child: testId('add_resident_is_resident_switch', SwitchListTile(
                              key: const Key('add_resident_is_resident_switch'),
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title: Text(
                                'Dairede kendisi ikamet ediyor mu?',
                                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                isResidentOwner
                                    ? 'Malik oturuyor (Fiilen ikamet eden sakin ve işletme aidatı sorumlusu)'
                                    : 'Evde oturmuyor (Yalnızca mülk sahibi / demirbaş sorumlusu)',
                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                              ),
                              value: isResidentOwner,
                              activeThumbColor: AppColors.accentGreen,
                              onChanged: (val) {
                                setDialogState(() {
                                  isResidentOwner = val;
                                });
                              },
                            )),
                          ),
                          if (isResidentOwner) ...[
                            const SizedBox(height: 6),
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
                                      'Malik Oturuyor: Kat maliki bu dairede bizzat ikamet etmektedir. Bu daire için ayrıca kiracı tanımlanamaz.',
                                      style: TextStyle(color: AppColors.successText(context), fontSize: 12, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ] else ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppColors.accentOrange.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: AppColors.accentOrange.withValues(alpha: 0.3)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.info_outline, size: 15, color: AppColors.accentOrange),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          'Kat maliki evde oturmuyor. Dairenin güncel kullanım durumunu seçiniz:',
                                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    width: double.infinity,
                                    child: SegmentedButton<String>(
                                      segments: const [
                                        ButtonSegment<String>(
                                          value: 'VACANT',
                                          label: Text('Boş Daire'),
                                          icon: Icon(Icons.meeting_room_outlined, size: 15),
                                        ),
                                        ButtonSegment<String>(
                                          value: 'TENANT',
                                          label: Text('Kiracılı Daire (Kiracı Tanımla)'),
                                          icon: Icon(Icons.key, size: 15),
                                        ),
                                      ],
                                      selected: {ownerNotResidentOccupancy},
                                      onSelectionChanged: (newSel) {
                                        setDialogState(() => ownerNotResidentOccupancy = newSel.first);
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ] else if (selectedRole == 'TENANT') ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.accentGreen.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.accentGreen.withValues(alpha: 0.2)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.key, size: 16, color: AppColors.accentGreen),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Kiracı (Fiilen İkamet Eden Sakin — Birincil Muhatap): İşletme aidatı borçları ve bildirimler doğrudan kiracıya yönlendirilir.',
                                    style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.w500),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ] else if (selectedRole == 'RESIDENT') ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.accentPurple.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.accentPurple.withValues(alpha: 0.2)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.family_restroom, size: 16, color: AppColors.accentPurple),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Hane Sakini: Dairede ikamet eden aile üyesi veya birey. Hane sakini olarak eklenir, ayrı daire borçlandırması yapılmaz.',
                                    style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),

                        // Person Fields (MUST maintain order: nameCtrl = 1, emailCtrl = 2, phoneCtrl = 3)
                        testId('add_resident_name_field', TextField(
                          controller: nameCtrl,
                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                          decoration: InputDecoration(
                            labelText: selectedRole == 'TENANT'
                                ? 'Kiracı Ad Soyad (Fiilen İkamet Eden Sakin)'
                                : (selectedRole == 'RESIDENT'
                                    ? 'Hane Sakini Ad Soyad'
                                    : 'Ad Soyad'),
                            helperText: selectedRole == 'OWNER'
                                ? (isResidentOwner
                                    ? 'Kat Maliki (Fiilen İkamet Eden Sakin)'
                                    : 'Kat Maliki (Ev Sahibi / Mülk Sahibi)')
                                : null,
                            labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                            filled: true,
                            fillColor: AppColors.surface(context),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        )),
                        const SizedBox(height: 12),
                        testId('add_resident_email_field', TextField(
                          controller: emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                          decoration: InputDecoration(
                            labelText: selectedRole == 'TENANT'
                                ? 'Kiracı E-posta (Doğrulama zorunlu)'
                                : 'E-posta (Doğrulama zorunlu)',
                            errorText: emailError,
                            labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                            filled: true,
                            fillColor: AppColors.surface(context),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        )),
                        const SizedBox(height: 12),
                        testId('add_resident_phone_field', TextField(
                          controller: phoneCtrl,
                          keyboardType: TextInputType.phone,
                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                          decoration: InputDecoration(
                            labelText: selectedRole == 'TENANT'
                                ? 'Kiracı Telefon (Doğrulama zorunlu)'
                                : 'Telefon (Doğrulama zorunlu)',
                            errorText: phoneError,
                            labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                            filled: true,
                            fillColor: AppColors.surface(context),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        )),
                        if (selectedRole != 'RESIDENT') ...[
                          const SizedBox(height: 12),
                          testId('add_resident_land_share_field', TextField(
                            controller: landShareCtrl,
                            keyboardType: TextInputType.number,
                            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                            decoration: InputDecoration(
                              labelText: 'Arsa Payı (pay sayısı)',
                              hintText: 'Örn: 24',
                              helperText: 'Ortak giderler bu paya göre bölünür. Boşsa sitenin olağan payı kullanılır.',
                              helperMaxLines: 2,
                              labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                              filled: true,
                              fillColor: AppColors.surface(context),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          )),
                        ],

                        // Extra option for Ev Sakini: Relationship selector
                        if (selectedRole == 'RESIDENT') ...[
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            value: selectedRelationship,
                            items: householdRelationshipItems(),
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() => selectedRelationship = val);
                              }
                            },
                            decoration: InputDecoration(
                              labelText: 'Yakınlık Derecesi / Rol',
                              filled: true,
                              fillColor: AppColors.surface(context),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ],

                        // Extra optional section for Kiracı: Secondary Kat Maliki details
                        if (selectedRole == 'TENANT') ...[
                          const SizedBox(height: 14),
                          InkWell(
                            onTap: () {
                              setDialogState(() {
                                showSecondaryOwner = !showSecondaryOwner;
                              });
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Icon(
                                    showSecondaryOwner ? Icons.arrow_drop_down : Icons.arrow_right,
                                    color: AppColors.accentCyan,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      'Kat Maliki (Ev Sahibi / Mülk Sahibi) Bilgileri (Opsiyonel)',
                                      style: TextStyle(
                                        color: AppColors.primaryText(context),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (showSecondaryOwner) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppColors.surface(context),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: AppColors.border(context).withOpacity(0.6)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  TextField(
                                    controller: ownerNameCtrl,
                                    decoration: InputDecoration(
                                      labelText: 'Ev Sahibi Ad Soyad',
                                      hintText: 'Örn: Ahmet Yılmaz',
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: ownerPhoneCtrl,
                                    keyboardType: TextInputType.phone,
                                    decoration: InputDecoration(
                                      labelText: 'Ev Sahibi Telefon',
                                      hintText: 'Örn: 0532 000 00 00',
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: ownerEmailCtrl,
                                    keyboardType: TextInputType.emailAddress,
                                    decoration: InputDecoration(
                                      labelText: 'Ev Sahibi E-posta',
                                      hintText: 'Örn: evsahibi@example.com',
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ] else if (selectedRole == 'OWNER' && !isResidentOwner && ownerNotResidentOccupancy == 'TENANT') ...[
                          // When OWNER is not resident and flat is rented to tenant
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.surface(context),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppColors.accentGreen.withOpacity(0.4)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.key, size: 16, color: AppColors.accentGreen),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'Kiracı Bilgileri (Fiilen İkamet Eden Sakin)',
                                        style: TextStyle(
                                          color: AppColors.textPrimary(context),
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: tenantNameCtrl,
                                  decoration: InputDecoration(
                                    labelText: 'Kiracı Ad Soyad *',
                                    hintText: 'Örn: Canan Kaya',
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: tenantPhoneCtrl,
                                  keyboardType: TextInputType.phone,
                                  decoration: InputDecoration(
                                    labelText: 'Kiracı Telefon',
                                    hintText: 'Örn: 0533 000 00 00',
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: tenantEmailCtrl,
                                  keyboardType: TextInputType.emailAddress,
                                  decoration: InputDecoration(
                                    labelText: 'Kiracı E-posta',
                                    hintText: 'Örn: kiraci@example.com',
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // =========================================================
                  // SECTION 3: HANE SAKİNLERİ (BİRLİKTE İKAMET EDEN BİREYLER)
                  // =========================================================
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppColors.card(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.accentCyan.withOpacity(0.3)),
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
                                '3. Hane Sakinleri (Birlikte İkamet Eden Bireyler)',
                                style: TextStyle(
                                  color: AppColors.textPrimary(context),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            testId('add_co_resident_btn', OutlinedButton.icon(
                              key: const Key('add_co_resident_btn'),
                              icon: const Icon(Icons.person_add_alt_1, size: 14, color: AppColors.accentCyan),
                              label: Text('+ Hane Sakini Ekle', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.primaryText(context))),
                              onPressed: () {
                                setDialogState(() {
                                  pendingResidents.add(_PendingResidentEntry());
                                });
                              },
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: const Size(0, 28),
                                side: const BorderSide(color: AppColors.accentCyan),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            )),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Dairede birlikte ikamet eden diğer aile bireylerini (eş, çocuk, anne/baba vb.) ekleyebilirsiniz.',
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        if (pendingResidents.isEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
                            decoration: BoxDecoration(
                              color: AppColors.surface(context),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.border(context).withOpacity(0.5)),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.info_outline, size: 15, color: AppColors.textSecondary(context)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Henüz hane sakini eklenmedi. Birlikte yaşayan aile bireylerini eklemek için "+ Hane Sakini Ekle" butonuna tıklayınız.',
                                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
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
                                          style: TextStyle(color: AppColors.primaryText(context), fontSize: 12, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                      const Spacer(),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.accentRed),
                                        tooltip: 'Hane Sakinini Kaldır',
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () {
                                          setDialogState(() {
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
                                            labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
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
                                          value: HouseholdRelationship.fromValue(res.relationship).code,
                                          isDense: true,
                                          dropdownColor: AppColors.card(context),
                                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                                          decoration: InputDecoration(
                                            labelText: 'Yakınlık',
                                            labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                            filled: true,
                                            isDense: true,
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            border: const OutlineInputBorder(),
                                          ),
                                          items: householdRelationshipItems(),
                                          onChanged: (val) {
                                            if (val != null) setDialogState(() => res.relationship = val);
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
                                            labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
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
                                            labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
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

  Future<void> _showManageHouseTypesDialog() async {
    await showManageHouseTypesFullscreen(context, widget.controller);
  }

  void _showSelectPrimaryResponsibleDialog(HomeOwnerItem ho) {
    showResponsibleContactSelection(context, widget.controller, ho);
  }

  void _showTransferOwnershipDialog(HomeOwnerItem ho) {
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
                            // Ownership transfer is a sensitive action: the server asks for a
                            // recent password check, then the same request is retried once.
                            final res = await runWithStepUp(
                              ctx,
                              reason: 'Mülk malikini değiştiriyorsunuz. Devam etmek için kendi şifrenizi doğrulayın.',
                              action: () => widget.controller.transferUnitOwnership(
                                unitId: ho.unitId,
                                newOwnerName: newName,
                                newOwnerPhone: phoneCtrl.text.trim(),
                                newOwnerEmail: emailCtrl.text.trim(),
                                notes: notesCtrl.text.trim(),
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

  void _showVirtualIbanDetailsDialog(HomeOwnerItem ho) {
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

  void _showAddSiteDialog() {
    final nameCtrl = TextEditingController();
    final cityCtrl = TextEditingController(text: 'İstanbul');
    final addressCtrl = TextEditingController();
    final adminNameCtrl = TextEditingController();
    final adminEmailCtrl = TextEditingController();
    final adminPhoneCtrl = TextEditingController();
    final blocksCtrl = TextEditingController(text: 'A Blok, B Blok');
    bool isSaving = false;
    String? localError;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AppFullscreenPage(
          title: 'Yeni Site / Kompleks Kaydet',
          subtitle: 'SaaS tenant kurulumu ve yetkili atama',
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.accentCyan.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.apartment, color: AppColors.accentCyan, size: 20),
          ),
          bottomBar: AppFullscreenPage.buildBottomBar(
            context: ctx,
            children: [
              OutlinedButton(
                onPressed: isSaving ? null : () => Navigator.pop(ctx),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: AppColors.border(context)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(AppStrings.cancel, style: TextStyle(color: AppColors.textSecondary(context), fontWeight: FontWeight.w600)),
              ),
              testId('btn_save_new_site', ElevatedButton(
                key: const Key('btn_save_new_site'),
                onPressed: isSaving
                    ? null
                    : () async {
                        final siteName = nameCtrl.text.trim();
                        final adminName = adminNameCtrl.text.trim();
                        final adminEmail = adminEmailCtrl.text.trim();

                        if (siteName.isEmpty || adminName.isEmpty) {
                          setDialogState(() {
                            localError = 'Lütfen Site Adı ve Yönetici Ad Soyad alanlarını doldurunuz.';
                          });
                          return;
                        }

                        if (adminEmail.isNotEmpty && !adminEmail.contains('@')) {
                          setDialogState(() {
                            localError = 'Lütfen geçerli bir yönetici e-posta adresi giriniz.';
                          });
                          return;
                        }

                        final cleanSiteTag = siteName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
                        final effectiveAdminEmail = adminEmail.isNotEmpty
                            ? adminEmail
                            : (widget.controller.isTestMode
                                ? 'yonetici@sitepulse.internal'
                                : 'yonetici.${cleanSiteTag.isNotEmpty ? cleanSiteTag : "site"}@sitepulse.internal');

                        setDialogState(() {
                          isSaving = true;
                          localError = null;
                        });

                        final rawBlocks = blocksCtrl.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
                        final blocks = rawBlocks.isNotEmpty ? rawBlocks : ['A Blok', 'B Blok'];

                        bool isClosed = false;
                        try {
                          final success = await widget.controller.registerNewSite(
                            name: siteName,
                            city: cityCtrl.text.trim().isEmpty ? 'İstanbul' : cityCtrl.text.trim(),
                            address: addressCtrl.text.trim(),
                            adminName: adminName,
                            adminEmail: effectiveAdminEmail,
                            adminPhone: adminPhoneCtrl.text.trim().isEmpty ? '+90 532 000 00 00' : adminPhoneCtrl.text.trim(),
                            blocks: blocks,
                          );

                          if (success) {
                            if (ctx.mounted) {
                              isClosed = true;
                              Navigator.pop(ctx);
                            }
                            widget.controller.fetchSaasSites();
                          } else {
                            setDialogState(() {
                              isSaving = false;
                              localError = widget.controller.lastSiteRegistrationError ?? 'Site kaydedilemedi. Lütfen bilgileri kontrol ediniz.';
                            });
                          }
                        } catch (e) {
                          setDialogState(() {
                            isSaving = false;
                            localError = 'Bir hata oluştu: $e';
                          });
                        } finally {
                          if (!isClosed && ctx.mounted) {
                            setDialogState(() {
                              isSaving = false;
                            });
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryFill,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Siteyi Kaydet & Yetkilendir', style: TextStyle(fontWeight: FontWeight.bold)),
              )),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (localError != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.accentRed),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: AppColors.accentRed, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          localError!,
                          style: TextStyle(color: AppColors.dangerText(context), fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              testId('add_site_name_field', TextField(
                controller: nameCtrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Site / Proje Adı',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
              const SizedBox(height: 12),
              testId('add_site_city_field', TextField(
                controller: cityCtrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Şehir',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
              const SizedBox(height: 12),
              testId('add_site_address_field', TextField(
                controller: addressCtrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Adres',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
              const SizedBox(height: 12),
              testId('add_site_blocks_field', TextField(
                key: const Key('add_site_blocks_field'),
                controller: blocksCtrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Bloklar (Virgülle ayırarak giriniz: A Blok, B Blok)',
                  helperText: 'Sitede yer alan blokları belirleyin. Sakin eklerken bu bloklar seçilecektir.',
                  helperStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  prefixIcon: const Icon(Icons.domain, size: 20, color: AppColors.accentCyan),
                ),
              )),
              const SizedBox(height: 12),
              testId('add_site_admin_name_field', TextField(
                controller: adminNameCtrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Yönetici Ad Soyad',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
              const SizedBox(height: 12),
              testId('add_site_admin_email_field', TextField(
                controller: adminEmailCtrl,
                keyboardType: TextInputType.emailAddress,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Yönetici E-posta',
                  helperText: 'Yöneticinin sisteme giriş yapacağı benzersiz e-posta adresi.',
                  helperStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
              const SizedBox(height: 12),
              testId('add_site_admin_phone_field', TextField(
                controller: adminPhoneCtrl,
                keyboardType: TextInputType.phone,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Yönetici Telefon',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
            ],
          ),
        ),
      ),
    );
  }

  void _showEditSiteDialog(TenantSiteItem site) {
    final nameCtrl = TextEditingController(text: site.name);
    final cityCtrl = TextEditingController(text: site.city);
    final addressCtrl = TextEditingController(text: site.address);
    final adminNameCtrl = TextEditingController(text: site.adminName);
    final adminEmailCtrl = TextEditingController(text: site.adminEmail);
    final adminPhoneCtrl = TextEditingController(text: site.adminPhone);
    final blocksCtrl = TextEditingController(text: site.blocks.join(', '));
    String selectedStatus = site.status;
    String selectedPlanType = site.planType;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AppFullscreenPage(
          title: '${site.name} Bilgilerini Düzenle',
          subtitle: 'Site yapılandırması, yönetici iletişim ve blok ayarları',
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.accentGreen.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.edit_note, color: AppColors.accentGreen, size: 20),
          ),
          bottomBar: AppFullscreenPage.buildBottomBar(
            context: ctx,
            children: [
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: AppColors.border(context)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(AppStrings.cancel, style: TextStyle(color: AppColors.textSecondary(context), fontWeight: FontWeight.w600)),
              ),
              testId('btn_save_site_edit', ElevatedButton(
                key: const Key('btn_save_site_edit'),
                onPressed: () async {
                  final siteName = nameCtrl.text.trim();
                  final adminName = adminNameCtrl.text.trim();
                  if (siteName.isEmpty || adminName.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      appSnackBar(
                        content: Text('Lütfen Site Adı ve Yönetici Ad Soyad alanlarını doldurunuz.'),
                        backgroundColor: AppColors.dangerFill,
                      ),
                    );
                    return;
                  }
                  final rawBlocks = blocksCtrl.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
                  final blocks = rawBlocks.isNotEmpty ? rawBlocks : site.blocks;
                  Navigator.pop(ctx);
                  await widget.controller.updateSite(
                    siteId: site.id,
                    name: siteName,
                    city: cityCtrl.text.trim().isEmpty ? site.city : cityCtrl.text.trim(),
                    address: addressCtrl.text.trim(),
                    adminName: adminName,
                    adminEmail: adminEmailCtrl.text.trim(),
                    adminPhone: adminPhoneCtrl.text.trim(),
                    status: selectedStatus,
                    planType: selectedPlanType,
                    blocks: blocks,
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.successFill,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Değişiklikleri Kaydet', style: TextStyle(fontWeight: FontWeight.bold)),
              )),
            ],
          ),
          child: Column(
            children: [
              testId('edit_site_name_field', TextField(
                key: const Key('edit_site_name_field'),
                controller: nameCtrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Site / Proje Adı',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: ['ACTIVE', 'TRIAL', 'SUSPENDED'].contains(selectedStatus) ? selectedStatus : 'ACTIVE',
                      items: const [
                        DropdownMenuItem(value: 'ACTIVE', child: Text('ACTIVE (Aktif)')),
                        DropdownMenuItem(value: 'TRIAL', child: Text('TRIAL (Deneme)')),
                        DropdownMenuItem(value: 'SUSPENDED', child: Text('SUSPENDED (Askıda)')),
                      ],
                      onChanged: (val) {
                        if (val != null) setDialogState(() => selectedStatus = val);
                      },
                      decoration: InputDecoration(
                        labelText: 'Durum',
                        labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                        filled: true,
                        fillColor: AppColors.card(context),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      dropdownColor: AppColors.card(context),
                      style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: ['ENTERPRISE', 'PRO', 'STARTER', 'COMMUNITY'].contains(selectedPlanType) ? selectedPlanType : 'ENTERPRISE',
                      items: const [
                        DropdownMenuItem(value: 'ENTERPRISE', child: Text('ENTERPRISE')),
                        DropdownMenuItem(value: 'PRO', child: Text('PRO')),
                        DropdownMenuItem(value: 'STARTER', child: Text('STARTER')),
                        DropdownMenuItem(value: 'COMMUNITY', child: Text('COMMUNITY')),
                      ],
                      onChanged: (val) {
                        if (val != null) setDialogState(() => selectedPlanType = val);
                      },
                      decoration: InputDecoration(
                        labelText: 'Paket / Plan',
                        labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                        filled: true,
                        fillColor: AppColors.card(context),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      dropdownColor: AppColors.card(context),
                      style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              testId('edit_site_city_field', TextField(
                key: const Key('edit_site_city_field'),
                controller: cityCtrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Şehir',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
              const SizedBox(height: 12),
              testId('edit_site_address_field', TextField(
                key: const Key('edit_site_address_field'),
                controller: addressCtrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Adres',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
              const SizedBox(height: 12),
              testId('edit_site_blocks_field', TextField(
                key: const Key('edit_site_blocks_field'),
                controller: blocksCtrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Bloklar (Virgülle ayırarak giriniz: A Blok, B Blok)',
                  helperText: 'Sitede yer alan blokları belirleyin.',
                  helperStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  prefixIcon: const Icon(Icons.domain, size: 20, color: AppColors.accentGreen),
                ),
              )),
              const SizedBox(height: 12),
              testId('edit_site_admin_name_field', TextField(
                key: const Key('edit_site_admin_name_field'),
                controller: adminNameCtrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Yönetici Ad Soyad',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
              const SizedBox(height: 12),
              testId('edit_site_admin_email_field', TextField(
                key: const Key('edit_site_admin_email_field'),
                controller: adminEmailCtrl,
                keyboardType: TextInputType.emailAddress,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Yönetici E-posta',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
              const SizedBox(height: 12),
              testId('edit_site_admin_phone_field', TextField(
                key: const Key('edit_site_admin_phone_field'),
                controller: adminPhoneCtrl,
                keyboardType: TextInputType.phone,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Yönetici Telefon',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDeleteSite(TenantSiteItem site) {
    if (site.hasActions) {
      AppFullscreenPage.push(
        context: context,
        builder: (ctx) => AppFullscreenPage(
          title: 'Site Silinemez',
          subtitle: 'KMK mevzuatı ve veri bütünlüğü uyarısı',
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orangeAccent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 20),
          ),
          bottomBar: AppFullscreenPage.buildBottomBar(
            context: ctx,
            children: [
              testId('btn_ack_delete_blocked', ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryFill,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Anladım', style: TextStyle(fontWeight: FontWeight.bold)),
              )),
            ],
          ),
          child: Text(
            '${site.name} sitesine ait aktif daireler (${site.totalUnits}) veya finansal tahsilat hareketleri bulunmaktadır. KMK mevzuatı ve veri bütünlüğü gereği işlem kaydı bulunan siteler silinemez.',
            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13, height: 1.5),
          ),
        ),
      );
      return;
    }

    AppFullscreenPage.pushConfirmation(
      context: context,
      title: 'Siteyi Sil',
      message: '${site.name} sitesini platformdan tamamen silmek istediğinize emin misiniz?\n\nBu sitede henüz herhangi bir daire veya finansal hareket bulunmamaktadır. Bu işlem geri alınamaz.',
      confirmLabel: 'Evet, Sil',
      cancelLabel: AppStrings.cancel,
      confirmColor: AppColors.accentRed,
      icon: Icons.delete_forever,
      iconColor: AppColors.accentRed,
    ).then((confirmed) {
      if (confirmed == true && mounted) {
        widget.controller.deleteSite(site.id);
      }
    });
  }

  void _confirmResetAdminPassword(TenantSiteItem site) {
    AppFullscreenPage.pushConfirmation(
      context: context,
      title: 'Geçici Şifre Yenile',
      message: '${site.name} yöneticisi ${site.adminName} (${site.adminEmail}) için yeni bir geçici yönetim şifresi üretilecektir.\n\nMevcut şifre geçersiz kılınır ve yönetici sisteme girdiğinde yeni şifre belirlemeye yönlendirilir.\n\nOnaylıyor musunuz?',
      confirmLabel: 'Şifreyi Yenile',
      cancelLabel: AppStrings.cancel,
      confirmColor: AppColors.accentCyan,
      icon: Icons.lock_reset,
      iconColor: AppColors.accentCyan,
    ).then((confirmed) {
      if (confirmed == true && mounted) {
        widget.controller.resetSiteManagerPassword(site.id);
      }
    });
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
    this.relationship = 'SPOUSE',
  })  : nameCtrl = TextEditingController(text: name ?? ''),
        phoneCtrl = TextEditingController(text: phone ?? ''),
        emailCtrl = TextEditingController(text: email ?? '');

  void dispose() {
    nameCtrl.dispose();
    phoneCtrl.dispose();
    emailCtrl.dispose();
  }
}

/// One navigation destination (bottom bar on phones, rail on wide screens).
class _NavDestination {
  final String id;
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final int badgeCount;
  final String? badgeSemantics;

  const _NavDestination({
    required this.id,
    required this.icon,
    required this.activeIcon,
    required this.label,
    this.badgeCount = 0,
    this.badgeSemantics,
  });
}

/// One half of the manager's "site management / my flat" switch.
///
/// Announces itself as a selectable button with its selected state, keeps a
/// 48 dp target, and ellipsizes long site names (full name in the tooltip).
class _PathSegment extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String label;
  final String semanticsLabel;
  final VoidCallback onTap;

  const _PathSegment({
    required this.selected,
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? AppColors.onFill : AppColors.textSecondary(context);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: selected ? null : onTap,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: selected ? null : onTap,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 150),
            constraints: const BoxConstraints(minHeight: kMinTouchTarget),
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm, horizontal: AppSpacing.sm),
            decoration: BoxDecoration(
              color: selected ? AppColors.primaryFill : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: foreground),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
