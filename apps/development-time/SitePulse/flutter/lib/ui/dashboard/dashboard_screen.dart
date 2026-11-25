import '../design_system/sp_page_header.dart';
import '../payments/finance_hub_page.dart';
import '../../testing/test_id.dart';
import 'dart:async';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import '../../domain/models/auth_models.dart';
import '../../domain/models/dues_models.dart';
import '../components/app_fullscreen_page.dart';
import '../components/dues_management_view.dart';
import '../components/hero_balance_card.dart';
import '../components/manager_cockpit_view.dart';
import '../components/announcement_composer_page.dart';
import '../components/payment_checkout_dialog.dart';
import '../components/profile_role_sheet.dart';
import '../components/resident_actions_row.dart';
import '../components/resident_capital_project_pages.dart';
import '../components/saas_admin_view.dart';
import '../components/unit_matching_criteria_card.dart';
import '../components/virtual_iban_card.dart';
import '../components/house_types_modal.dart';
import '../residents/owners_residents_module_page.dart';
import '../residents/block_units_create_page.dart';
import '../residents/resident_household_member_page.dart';
import '../residents/unit_directory_row.dart';
import '../theme/app_theme.dart';
import '../design_system/sp_skeleton.dart';
import '../design_system/sp_error_state.dart';
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
  bool _isLoadingCapitalProjectDetails = false;
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
  final TextEditingController _residentSearchController = TextEditingController();
  String _homeOwnerBlockFilter = 'ALL';
  String _homeOwnerOccupancyFilter = 'ALL';

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
    _residentSearchController.dispose();
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
                onAddResidentTap: _openAddResident,
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
        onCapitalProjectPressed: isOwner ? _openCapitalProjectDetails : null,
        isLoadingCapitalProjectDetails: _isLoadingCapitalProjectDetails,
        onPayPressed: () => _showPaymentDialog(dues),
        onDetailPressed: () => _showDuesDetailDialog(dues),
      ),
      if (widget.controller.isHomeResident) ...[
        const SizedBox(height: 12),
        TenantCapitalProjectsGuidance(projects: widget.controller.residentCapitalProjects),
      ],
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

    if (isLoading) {
      return testId('unit_directory_loading', const SpSkeletonList());
    }
    if (widget.controller.homeOwnersError != null) {
      return testId('unit_directory_error', SpErrorState(
        error: widget.controller.homeOwnersError,
        title: 'Daire dizini yüklenemedi',
        message: 'Daire bilgileri alınamadı. Site verileriniz değişmedi.',
        onRetry: () => widget.controller.fetchHomeOwners(),
      ));
    }

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
                onPressed: _openAddResident,
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
            testId(
              'btn_add_block',
              OutlinedButton.icon(
                key: const Key('btn_add_block'),
                onPressed: _openAddBlock,
                icon: const Icon(Icons.apartment, size: 15),
                label: const Text('Blok & Daire Ekle'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accentCyan,
                  side: const BorderSide(color: AppColors.accentCyan),
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
        testId(
          'resident_search_field',
          TextField(
            controller: _residentSearchController,
            key: const Key('resident_search_field'),
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
                  ? testId(
                      'resident_search_clear_btn',
                      IconButton(
                        key: const Key('resident_search_clear_btn'),
                        tooltip: 'Aramayı temizle',
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          _residentSearchController.clear();
                          setState(() {
                            _homeOwnerSearchQuery = '';
                          });
                        },
                      ),
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
          homeOwners.isEmpty
              ? testId(
                  'units_empty_state',
                  SpGuidanceCard(
                    key: const Key('units_empty_state'),
                    icon: Icons.home_work_outlined,
                    title: 'Henüz daire veya sakin bulunmuyor',
                    message: 'Site dizinini başlatmak için ilk sakin veya daireyi ekleyin.',
                    prominent: true,
                    action: testId(
                      'empty_state_add_resident_btn',
                      ElevatedButton.icon(
                        key: const Key('empty_state_add_resident_btn'),
                        onPressed: _openAddResident,
                        icon: const Icon(Icons.person_add_outlined, size: 16),
                        label: const Text('Yeni Sakin Ekle'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryFill,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  label: 'Henüz daire veya sakin bulunmuyor',
                )
              : testId(
                  'units_filtered_empty_state',
                  SpGuidanceCard(
                    key: const Key('units_filtered_empty_state'),
                    icon: Icons.person_search_outlined,
                    title: 'Aramaya uygun sakin bulunamadı',
                    message: 'Farklı bir arama terimi deneyebilir veya filtreyi temizleyebilirsiniz.',
                    action: testId(
                      'empty_state_reset_filters_btn',
                      TextButton(
                        key: const Key('empty_state_reset_filters_btn'),
                        onPressed: () {
                          _residentSearchController.clear();
                          setState(() {
                            _homeOwnerSearchQuery = '';
                            _homeOwnerBlockFilter = allBlocksFilter;
                            _homeOwnerOccupancyFilter = OccupancyFilter.all;
                          });
                        },
                        child: const Text('Filtreleri sıfırla'),
                      ),
                    ),
                  ),
                  label: 'Aramaya uygun sakin bulunamadı',
                )
        else
          ...filtered.map((ho) => UnitDirectoryRow(
                unit: ho,
                onActions: () => _openUnitInModule(ho, UnitWorkspaceMode.actions),
                onDetails: () => _openUnitInModule(ho, UnitWorkspaceMode.information),
              )),
      ],
    );
  }

  /// Unit actions run in the owners & residents module, whose pages choose or create a
  /// person card with `SpPersonField` (REQ-042); this tab only lists the units.
  void _openUnitInModule(HomeOwnerItem unit, UnitWorkspaceMode mode) {
    AppFullscreenPage.push(
      context: context,
      builder: (_) => OwnersResidentsModulePage(
        controller: widget.controller,
        initialUnitId: unit.unitId,
        initialMode: mode,
      ),
    );
  }

  void _openAddResident() {
    AppFullscreenPage.push(
      context: context,
      builder: (_) => OwnersResidentsModulePage(controller: widget.controller, openAddResident: true),
    );
  }

  /// Opens the block & units form; the manager builds site structure before
  /// registering anyone in it (#285).
  void _openAddBlock() {
    unawaited(showBlockUnitsCreatePage(context, widget.controller));
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
                      onPressed: () => showResidentHouseholdMemberPage(context, widget.controller),
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

  Future<void> _openCapitalProjectDetails(CapitalDuesSummary summary) async {
    if (_isLoadingCapitalProjectDetails) return;
    setState(() => _isLoadingCapitalProjectDetails = true);
    try {
      final details = await widget.controller.fetchResidentCapitalProjectDetails(summary.projectId);
      if (!mounted) return;
      if (details == null) {
        SpToast.error(context, 'Demirbaş proje detayları şu anda alınamıyor.');
        return;
      }
      await AppFullscreenPage.push<void>(
        context: context,
        builder: (_) => ResidentCapitalProjectDetailsPage(
          details: details,
          outstandingBalance: summary.outstandingBalance,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoadingCapitalProjectDetails = false);
    }
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
                  labelText: 'Açıklama',
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

  Future<void> _showManageHouseTypesDialog() async {
    await showManageHouseTypesFullscreen(context, widget.controller);
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
