import 'dart:async';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../domain/models/auth_models.dart';
import '../../domain/models/dues_models.dart';
import '../components/app_fullscreen_page.dart';
import '../components/dues_management_view.dart';
import '../components/hero_balance_card.dart';
import '../components/manager_cockpit_view.dart';
import '../components/payment_checkout_dialog.dart';
import '../components/profile_role_sheet.dart';
import '../components/resident_actions_row.dart';
import '../components/saas_admin_view.dart';
import '../components/unit_matching_criteria_card.dart';
import '../components/virtual_iban_card.dart';
import '../theme/app_theme.dart';
import 'dashboard_controller.dart';

class DashboardScreen extends StatefulWidget {
  final DashboardController controller;

  const DashboardScreen({
    super.key,
    required this.controller,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedTabIndex = 0;
  String _homeOwnerSearchQuery = '';
  String _homeOwnerBlockFilter = 'ALL';
  final Map<String, int> _unitCardTabs = {};
  Timer? _liveSyncTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerUpdate);
    widget.controller.fetchResidentDashboard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.controller.fetchHomeOwners();
      }
    });
    _liveSyncTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) {
        widget.controller.fetchResidentDashboard();
      }
    });
  }

  @override
  void dispose() {
    _liveSyncTimer?.cancel();
    widget.controller.removeListener(_onControllerUpdate);
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    setState(() {});

    // Check for auth message
    if (widget.controller.authMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.controller.authMessage!),
          backgroundColor: AppColors.accentCyan,
          duration: const Duration(seconds: 3),
        ),
      );
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

  @override
  Widget build(BuildContext context) {
    final session = widget.controller.userSession;
    final isHomeRole = session.role == UserRole.homeOwner || session.role == UserRole.homeResident;

    return Scaffold(
      backgroundColor: widget.controller.isDarkMode ? AppColors.darkBackground : AppColors.lightBackground,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.accentCyan.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.flash_on, color: AppColors.accentCyan, size: 20),
            ),
            const SizedBox(width: 8),
            Text(
              'SitePulse',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                letterSpacing: -0.5,
                color: AppColors.textPrimary(context),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.card(context),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Text(
                session.role.displayName,
                style: TextStyle(fontSize: 10, color: AppColors.textSecondary(context), fontWeight: FontWeight.w500),
              ),
            ),
            if (session.role == UserRole.siteManager && session.siteName.isNotEmpty) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.accentCyan.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.accentCyan.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.apartment, size: 12, color: AppColors.accentCyan),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          session.siteName,
                          style: const TextStyle(fontSize: 11, color: AppColors.accentCyan, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            tooltip: widget.controller.isOffline ? 'Çevrimiçi Yap' : 'Çevrimdışı Simüle Et',
            icon: Icon(
              widget.controller.isOffline ? Icons.wifi_off : Icons.wifi,
              color: widget.controller.isOffline ? AppColors.accentOrange : AppColors.accentGreen,
              size: 20,
            ),
            onPressed: () {
              widget.controller.toggleOfflineMode(!widget.controller.isOffline);
            },
          ),
          IconButton(
            tooltip: 'Tema Değiştir',
            icon: Icon(
              widget.controller.isDarkMode ? Icons.light_mode : Icons.dark_mode,
              color: AppColors.textSecondary(context),
              size: 20,
            ),
            onPressed: () {
              widget.controller.toggleTheme();
            },
          ),
          IconButton(
            tooltip: 'Çıkış Yap / Rol Değiştir',
            icon: const Icon(
              Icons.logout_rounded,
              color: AppColors.accentRed,
              size: 20,
            ),
            onPressed: () {
              widget.controller.logout();
            },
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: InkWell(
              onTap: () => _openProfileSheet(context),
              borderRadius: BorderRadius.circular(20),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.primary,
                child: Text(
                  session.fullName.substring(0, 1),
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => widget.controller.fetchResidentDashboard(),
          color: AppColors.accentCyan,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: _buildCurrentTabContent(isHomeRole),
          ),
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          border: Border(top: BorderSide(color: AppColors.border(context), width: 1)),
        ),
        child: Builder(
          builder: (context) {
            final isManagerCockpit = widget.controller.userRole == UserRole.siteManager &&
                widget.controller.siteAdminPath == SiteAdminActivePath.managerCockpit;
            final maxIndex = isManagerCockpit ? 2 : 1;
            final safeIndex = _selectedTabIndex > maxIndex ? 0 : _selectedTabIndex;

            return BottomNavigationBar(
              currentIndex: safeIndex,
              onTap: (index) {
                final profileIndex = isManagerCockpit ? 3 : 2;
                if (index == profileIndex) {
                  _openProfileSheet(context);
                } else {
                  setState(() {
                    _selectedTabIndex = index;
                  });
                }
              },
              backgroundColor: Colors.transparent,
              selectedItemColor: AppColors.isDark(context) ? AppColors.accentCyan : AppColors.lightTextPrimary,
              unselectedItemColor: AppColors.textSecondary(context),
              selectedFontSize: 11,
              unselectedFontSize: 11,
              type: BottomNavigationBarType.fixed,
              elevation: 0,
              items: [
                const BottomNavigationBarItem(
                  icon: Icon(Icons.dashboard_outlined),
                  activeIcon: Icon(Icons.dashboard),
                  label: 'Ana Sayfa',
                ),
                if (isManagerCockpit)
                  BottomNavigationBarItem(
                    icon: Badge(
                      isLabelVisible: widget.controller.unmatchedBankCount > 0,
                      label: Text('${widget.controller.unmatchedBankCount}'),
                      backgroundColor: AppColors.accentOrange,
                      child: const Icon(Icons.payments_outlined),
                    ),
                    activeIcon: Badge(
                      isLabelVisible: widget.controller.unmatchedBankCount > 0,
                      label: Text('${widget.controller.unmatchedBankCount}'),
                      backgroundColor: AppColors.accentOrange,
                      child: const Icon(Icons.payments),
                    ),
                    label: 'Aidat Yönetimi',
                  ),
                BottomNavigationBarItem(
                  icon: Icon(isHomeRole ? Icons.home_outlined : Icons.apartment_outlined),
                  activeIcon: Icon(isHomeRole ? Icons.home : Icons.apartment),
                  label: isHomeRole ? 'Dairem' : (session.role == UserRole.saasAdmin ? 'Siteler' : 'Yönetim'),
                ),
                const BottomNavigationBarItem(
                  icon: Icon(Icons.person_outline),
                  activeIcon: Icon(Icons.person),
                  label: 'Profil & Yetki',
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSiteManagerPathSwitcher() {
    final currentPath = widget.controller.siteAdminPath;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () {
                if (currentPath != SiteAdminActivePath.managerCockpit) {
                  widget.controller.setSiteAdminPath(SiteAdminActivePath.managerCockpit);
                }
              },
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
                decoration: BoxDecoration(
                  color: currentPath == SiteAdminActivePath.managerCockpit
                      ? AppColors.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.apartment,
                      size: 16,
                      color: currentPath == SiteAdminActivePath.managerCockpit
                          ? Colors.white
                          : AppColors.textSecondary(context),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${widget.controller.userSession.siteName} Yönetimi',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: currentPath == SiteAdminActivePath.managerCockpit
                            ? Colors.white
                            : AppColors.textSecondary(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () {
                if (currentPath != SiteAdminActivePath.myFlatOwner) {
                  widget.controller.setSiteAdminPath(SiteAdminActivePath.myFlatOwner);
                }
              },
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
                decoration: BoxDecoration(
                  color: currentPath == SiteAdminActivePath.myFlatOwner
                      ? AppColors.accentCyan
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.home,
                      size: 16,
                      color: currentPath == SiteAdminActivePath.myFlatOwner
                          ? Colors.black87
                          : AppColors.textSecondary(context),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Kendi Dairem (Kat Maliki)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: currentPath == SiteAdminActivePath.myFlatOwner
                            ? Colors.black87
                            : AppColors.textSecondary(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
        final hasNoUnit = widget.controller.activeUnit.id.isEmpty;
        if (hasNoUnit) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildNoHomeownerGuidanceCard(),
              const SizedBox(height: 18),
              _buildHesapHareketleriSection(),
            ],
          );
        }
        final dues = widget.controller.primaryDues;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HeroBalanceCard(
              dues: dues,
              siteName: widget.controller.activeUnit.siteAdi,
              unitName: '${widget.controller.activeUnit.blok} Blok D:${widget.controller.activeUnit.daireNo}',
              isOffline: widget.controller.isOffline,
              advancePayment: widget.controller.activeUnit.advancePayment,
              virtualIban: widget.controller.activeUnit.virtualIban,
              onPayPressed: () => _showPaymentDialog(dues),
              onDetailPressed: () => _showDuesDetailDialog(dues),
            ),
            const SizedBox(height: 16),
            ResidentActionsRow(
              isOwner: widget.controller.userRole == UserRole.homeOwner,
              onReceiptsTap: _showReceiptsDialog,
              onInviteTap: () {
                widget.controller.generateUnitInviteLink();
              },
              onRequestsTap: _showIssueReportDialog,
              onAnnouncementsTap: _showAnnouncementsDialog,
            ),
            const SizedBox(height: 18),
            _buildHesapHareketleriSection(),
            const SizedBox(height: 16),
            _buildDairemHouseholdCard(),
            const SizedBox(height: 16),
            UnitMatchingCriteriaCard(controller: widget.controller),
          ],
        );
      case UserRole.siteManager:
        final currentPath = widget.controller.siteAdminPath;
        if (currentPath == SiteAdminActivePath.myFlatOwner) {
          final hasNoUnit = widget.controller.activeUnit.id.isEmpty;
          if (hasNoUnit) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSiteManagerPathSwitcher(),
                _buildNoHomeownerGuidanceCard(),
                const SizedBox(height: 18),
                _buildHesapHareketleriSection(),
              ],
            );
          }
          final dues = widget.controller.primaryDues;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSiteManagerPathSwitcher(),
              HeroBalanceCard(
                dues: dues,
                siteName: widget.controller.activeUnit.siteAdi,
                unitName: '${widget.controller.activeUnit.blok} Blok D:${widget.controller.activeUnit.daireNo}',
                isOffline: widget.controller.isOffline,
                advancePayment: widget.controller.activeUnit.advancePayment,
                virtualIban: widget.controller.activeUnit.virtualIban,
                onPayPressed: () => _showPaymentDialog(dues),
                onDetailPressed: () => _showDuesDetailDialog(dues),
              ),
              const SizedBox(height: 16),
              ResidentActionsRow(
                isOwner: true,
                onReceiptsTap: _showReceiptsDialog,
                onInviteTap: () {
                  widget.controller.generateUnitInviteLink();
                },
                onRequestsTap: _showIssueReportDialog,
                onAnnouncementsTap: _showAnnouncementsDialog,
              ),
              const SizedBox(height: 18),
              _buildHesapHareketleriSection(),
              const SizedBox(height: 16),
              _buildDairemHouseholdCard(),
              const SizedBox(height: 16),
              UnitMatchingCriteriaCard(controller: widget.controller),
            ],
          );
        } else {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSiteManagerPathSwitcher(),
              ManagerCockpitView(
                controller: widget.controller,
                onAddResidentTap: _showAddResidentDialog,
                onManageHouseTypesTap: _showManageHouseTypesDialog,
                onManageHomeOwnersTap: () {
                  setState(() {
                    _selectedTabIndex = 2;
                  });
                },
              ),
            ],
          );
        }
      case UserRole.saasAdmin:
        return SaasAdminView(
          controller: widget.controller,
          onAddSiteTap: _showAddSiteDialog,
          onDeleteSiteTap: _confirmDeleteSite,
          onResetPasswordTap: _confirmResetAdminPassword,
        );
    }
  }

  Widget _buildNoHomeownerGuidanceCard() {
    final isDark = AppColors.isDark(context);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.accentOrange.withOpacity(0.35)),
      ),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.accentOrange.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.home_work_outlined, size: 30, color: AppColors.accentOrange),
          ),
          const SizedBox(height: 14),
          Text(
            'Tanımlı Daireniz Bulunmuyor',
            style: TextStyle(
              color: AppColors.textPrimary(context),
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'SitePulse hesabınıza henüz bir daire kaydı atanmamıştır. Site yöneticinizden WhatsApp/SMS davet bağlantısı alarak veya bina yönetiminizle iletişime geçerek dairenizi tanımlatabilirsiniz.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary(context),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('💡', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Daireniz tanımlandığında adınıza tahakkuk eden aidatlar, Sanal IBAN ve hesap hareketleriniz burada listelenir.',
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSecondaryTabContent(bool isHomeRole) {
    if (isHomeRole) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Dairem & Hane Bilgileri',
            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _buildDairemHouseholdCard(),
          const SizedBox(height: 16),
          VirtualIbanCard(
            iban: widget.controller.activeUnit.virtualIban ?? 'TR64 0020 5000 0986 3791 6000 14',
            unitDesc: '${widget.controller.activeUnit.blok} Blok D:${widget.controller.activeUnit.daireNo}',
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
            _buildSiteManagerPathSwitcher(),
            Text(
              'Dairem & Hane Bilgileri',
              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _buildDairemHouseholdCard(),
            const SizedBox(height: 16),
            VirtualIbanCard(
              iban: widget.controller.activeUnit.virtualIban ?? 'TR91 0020 5000 0986 3791 6000 01',
              unitDesc: '${widget.controller.activeUnit.blok} Blok D:${widget.controller.activeUnit.daireNo}',
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
        onDeleteSiteTap: _confirmDeleteSite,
        onResetPasswordTap: _confirmResetAdminPassword,
      );
    }
  }

  Widget _buildHomeOwnersManagementView() {
    final isDark = AppColors.isDark(context);
    final homeOwners = widget.controller.homeOwners;
    final isLoading = widget.controller.isLoadingHomeOwners;

    final rawBlocks = widget.controller.blocks;
    final seenB = <String>{};
    final availableBlocks = <String>[];
    for (final b in rawBlocks) {
      final t = b.trim();
      if (t.isNotEmpty && seenB.add(t.toLowerCase())) {
        availableBlocks.add(t);
      }
    }

    final filtered = homeOwners.where((ho) {
      if (_homeOwnerBlockFilter != 'ALL') {
        final b1 = ho.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();
        final b2 = _homeOwnerBlockFilter.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();
        if (b1 != b2) return false;
      }
      if (_homeOwnerSearchQuery.isNotEmpty) {
        final q = _homeOwnerSearchQuery.toLowerCase();
        final matchName = ho.ownerFullName.toLowerCase().contains(q);
        final matchTenant = (ho.tenantFullName ?? '').toLowerCase().contains(q);
        final matchResidents = ho.householdResidents.any((r) =>
            r.fullName.toLowerCase().contains(q) ||
            r.phone.toLowerCase().contains(q) ||
            r.email.toLowerCase().contains(q));
        final matchUnit = ho.unitNo.toString().contains(q);
        final matchPhone = ho.phone.toLowerCase().contains(q) || (ho.tenantPhone ?? '').toLowerCase().contains(q);
        final matchEmail = ho.email.toLowerCase().contains(q) || (ho.tenantEmail ?? '').toLowerCase().contains(q);
        final matchBlock = ho.block.toLowerCase().contains(q);
        return matchName || matchTenant || matchResidents || matchUnit || matchPhone || matchEmail || matchBlock;
      }
      return true;
    }).toList();

    final totalCount = widget.controller.collectionSummary.totalUnitsCount > 0
        ? widget.controller.collectionSummary.totalUnitsCount
        : homeOwners.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSiteManagerPathSwitcher(),

        // Header Card
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.accentCyan.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.people_alt_outlined, color: AppColors.accentCyan, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Kat Malikleri & Sakinler Yönetimi',
                          style: TextStyle(
                            color: AppColors.textPrimary(context),
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${widget.controller.userSession.siteName} • Toplam $totalCount bağımsız bölüm (${homeOwners.length} kayıtlı)',
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
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    key: const Key('add_resident_btn'),
                    onPressed: _showAddResidentDialog,
                    icon: const Icon(Icons.person_add_outlined, size: 16),
                    label: const Text('Yeni Sakin Ekle'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentCyan,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _showManageHouseTypesDialog,
                    icon: const Icon(Icons.home_work_outlined, size: 16),
                    label: const Text('Konut Tipleri & Tarifeler'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.accentPurple,
                      side: const BorderSide(color: AppColors.accentPurple),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Search & Filter
        TextField(
          onChanged: (val) {
            setState(() {
              _homeOwnerSearchQuery = val.trim();
            });
          },
          decoration: InputDecoration(
            hintText: 'İsim, daire no, telefon veya e-posta ile ara...',
            hintStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _homeOwnerSearchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      setState(() {
                        _homeOwnerSearchQuery = '';
                      });
                    },
                  )
                : null,
            filled: true,
            fillColor: AppColors.surface(context),
            contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppColors.border(context)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppColors.border(context)),
            ),
          ),
        ),

        const SizedBox(height: 10),

        // Block filter chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildBlockFilterChip('Tümü', 'ALL'),
              ...availableBlocks.map((b) => _buildBlockFilterChip(b, b)),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // List of residents
        if (isLoading)
          const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
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

  Widget _buildBlockFilterChip(String label, String code) {
    final isSelected = _homeOwnerBlockFilter == code;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (_) {
          setState(() {
            _homeOwnerBlockFilter = code;
          });
        },
        selectedColor: AppColors.accentCyan.withOpacity(0.2),
        checkmarkColor: AppColors.accentCyan,
        labelStyle: TextStyle(
          color: isSelected ? AppColors.accentCyan : AppColors.textSecondary(context),
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
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
            child: Row(
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
                          fontSize: 11,
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
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              ho.unitNo > 0
                                  ? '${ho.block} • Daire ${ho.unitNo}'
                                  : '${ho.block} • Daire Atanmadı',
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
                // Monthly Dues summary
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
                      'Aidat (İşletme)',
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 10),
                    ),
                    if (ho.capitalDuesBalance > Decimal.zero) ...[
                      const SizedBox(height: 1),
                      Text(
                        '₺${ho.capitalDuesBalance.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: AppColors.accentOrange,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(width: 10),
                // Unit-Level Action Buttons inside Header
                IconButton(
                  key: Key('history_ho_${ho.unitId}'),
                  icon: const Icon(Icons.history, size: 18, color: AppColors.accentCyan),
                  tooltip: 'Daire İkamet & Sakin Tarihçesi',
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
                  onPressed: () => _showUnitOccupancyHistoryDialog(ho),
                ),
                const SizedBox(width: 4),
                if (!isVacant)
                  IconButton(
                    key: Key('move_out_ho_${ho.unitId}'),
                    icon: const Icon(Icons.logout_outlined, size: 18, color: AppColors.accentOrange),
                    tooltip: 'Sakin Ayrılışı (Move-Out)',
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    onPressed: () => _showMoveOutDialog(ho),
                  )
                else
                  IconButton(
                    key: Key('move_in_ho_${ho.unitId}'),
                    icon: const Icon(Icons.person_add_alt, size: 18, color: AppColors.accentGreen),
                    tooltip: 'Yeni Sakin / Giriş (Move-In)',
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    onPressed: () => _showMoveInDialog(ho),
                  ),
                const SizedBox(width: 4),
                IconButton(
                  key: Key('delete_ho_${ho.unitId}'),
                  icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.accentRed),
                  tooltip: 'Kat Malikini Sil',
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
                  onPressed: () => _confirmDeleteHomeOwner(ho),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  onPressed: () => _showEditHomeOwnerDialog(ho),
                  icon: const Icon(Icons.edit_outlined, size: 13),
                  label: const Text('Düzenle', style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accentCyan,
                    side: const BorderSide(color: AppColors.accentCyan),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: const Size(0, 30),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),

          // -------------------------------------------------------------
          // 2. PEOPLE UNDER THE UNIT (İKAMET & KİŞİ BİLGİLERİ HİYERARŞİSİ)
          // -------------------------------------------------------------
          Padding(
            padding: const EdgeInsets.all(14),
            child: Builder(
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
                              child: InkWell(
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
                                  const Text(
                                    'Fiilen İkamet Eden Kiracı (Birincil Muhatap)',
                                    style: TextStyle(
                                      color: AppColors.accentGreen,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const Spacer(),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: AppColors.accentGreen.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'Kiracı',
                                      style: TextStyle(
                                        color: AppColors.accentGreen,
                                        fontSize: 10,
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
                                                  ho.tenantEmail != null && ho.tenantEmail!.isNotEmpty ? ho.tenantEmail! : (ho.email.isNotEmpty ? ho.email : 'E-posta Yok'),
                                                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                                  OutlinedButton.icon(
                                    key: Key('edit_residents_${ho.unitId}'),
                                    onPressed: () => _showEditHomeOwnerDialog(ho, initialTab: 0),
                                    icon: const Icon(Icons.edit_outlined, size: 12),
                                    label: const Text('Sakinleri Düzenle', style: TextStyle(fontSize: 11)),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.accentGreen,
                                      side: const BorderSide(color: AppColors.accentGreen),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      minimumSize: const Size(0, 28),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    key: Key('move_out_resident_${ho.unitId}'),
                                    onPressed: () => _showMoveOutDialog(ho),
                                    icon: const Icon(Icons.logout, size: 12),
                                    label: const Text('Tahliye (Move-Out)', style: TextStyle(fontSize: 11)),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.accentOrange,
                                      side: const BorderSide(color: AppColors.accentOrange),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      minimumSize: const Size(0, 28),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
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
                                  Text(
                                    'Hane Sakinleri / Birlikte Yaşayanlar (${ho.householdResidents.length})',
                                    style: TextStyle(
                                      color: AppColors.textPrimary(context),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const Spacer(),
                                  TextButton.icon(
                                    key: Key('add_resident_to_${ho.unitId}'),
                                    onPressed: () => _showAddHouseholdMemberDialog(ho),
                                    icon: const Icon(Icons.add, size: 14, color: AppColors.accentPurple),
                                    label: const Text('+ Sakin Ekle', style: TextStyle(color: AppColors.accentPurple, fontSize: 11, fontWeight: FontWeight.bold)),
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
                                          style: TextStyle(
                                            color: AppColors.textSecondary(context),
                                            fontSize: 11,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      IconButton(
                                        key: Key('edit_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                        icon: const Icon(Icons.edit_outlined, size: 14, color: AppColors.accentCyan),
                                        tooltip: '${m.fullName} bilgilerini düzenle',
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () => _showEditHouseholdMemberDialog(ho, m),
                                      ),
                                      const SizedBox(width: 6),
                                      IconButton(
                                        key: Key('delete_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                        icon: const Icon(Icons.close, size: 14, color: AppColors.accentRed),
                                        tooltip: '${m.fullName} kaydını sil',
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
                                  const Text(
                                    'Kat Maliki (Daire Mülk Sahibi)',
                                    style: TextStyle(
                                      color: AppColors.accentCyan,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const Spacer(),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: AppColors.accentCyan.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'Ev Sahibi',
                                      style: TextStyle(
                                        color: AppColors.accentCyan,
                                        fontSize: 10,
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
                                                  ho.email.isNotEmpty ? ho.email : 'E-posta Yok',
                                                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                              OutlinedButton.icon(
                                key: Key('edit_owner_${ho.unitId}'),
                                onPressed: () => _showEditHomeOwnerDialog(ho, initialTab: 1),
                                icon: const Icon(Icons.edit_outlined, size: 12),
                                label: const Text('Kat Malikini Düzenle', style: TextStyle(fontSize: 11)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.accentCyan,
                                  side: const BorderSide(color: AppColors.accentCyan),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  minimumSize: const Size(0, 28),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
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
                              Text(
                                isVacant ? 'İkamet Durumu' : 'Fiilen İkamet Eden Kat Maliki (Birincil Muhatap)',
                                style: TextStyle(
                                  color: statusColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Spacer(),
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
                                    fontSize: 10,
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
                                                ho.email.isNotEmpty ? ho.email : 'E-posta Yok',
                                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
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
                                          fontSize: 11,
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
                                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 10),
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
                    if (ho.householdResidents.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                                Text(
                                  'Hane Sakinleri / Birlikte Yaşayanlar (${ho.householdResidents.length})',
                                  style: TextStyle(
                                    color: AppColors.textPrimary(context),
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
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
                                      style: TextStyle(
                                        color: AppColors.textSecondary(context),
                                        fontSize: 11,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  IconButton(
                                    key: Key('edit_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                    icon: const Icon(Icons.edit_outlined, size: 14, color: AppColors.accentCyan),
                                    tooltip: '${m.fullName} bilgilerini düzenle',
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    onPressed: () => _showEditHouseholdMemberDialog(ho, m),
                                  ),
                                  const SizedBox(width: 6),
                                  IconButton(
                                    key: Key('delete_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                    icon: const Icon(Icons.close, size: 14, color: AppColors.accentRed),
                                    tooltip: '${m.fullName} kaydını sil',
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    onPressed: () => _confirmDeleteHouseholdMember(ho, m),
                                  ),
                                ],
                              ),
                            )),
                          ],
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
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
                  child: const Text('Kapat'),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isLoading)
                  const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
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
                  ...items.map((h) => Container(
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
                                  color: h.isActive ? AppColors.accentGreen : AppColors.textSecondary(context),
                                  fontSize: 11,
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
                            'Kapanış Bakiyesi: ₺${h.exitBalance.toStringAsFixed(2)} Borç',
                            style: const TextStyle(color: AppColors.accentRed, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                        if (h.notes != null && h.notes!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Not: ${h.notes}',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11, fontStyle: FontStyle.italic),
                          ),
                        ],
                      ],
                    ),
                  )),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showMoveOutDialog(HomeOwnerItem resident) {
    final notesCtrl = TextEditingController();
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
                  child: const Text('Vazgeç'),
                ),
                FilledButton.icon(
                  onPressed: isSaving ? null : () async {
                    setDialogState(() {
                      isSaving = true;
                      errorMsg = null;
                    });
                    final ok = await widget.controller.moveOutResident(
                      resident.unitId,
                      notes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                    );
                    if (ok && ctx.mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Sakin ayrılışı kaydedildi. Daire boş durumuna getirildi.'),
                          backgroundColor: AppColors.accentGreen,
                        ),
                      );
                    } else if (ctx.mounted) {
                      setDialogState(() {
                        isSaving = false;
                        errorMsg = 'İşlem gerçekleştirilemedi.';
                      });
                    }
                  },
                  icon: isSaving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.check, size: 16),
                  label: const Text('Tahliyeyi Onayla'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accentOrange,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
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
                      const Text(
                        'Sakin Ayrılış Bilgilendirmesi',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.accentOrange),
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
                  Text(errorMsg!, style: const TextStyle(color: AppColors.accentRed, fontSize: 12)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _showMoveInDialog(HomeOwnerItem resident) {
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    String selectedRole = 'TENANT';
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
                  child: const Text('Vazgeç'),
                ),
                FilledButton.icon(
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
                    final ok = await widget.controller.moveInResident(
                      resident.unitId,
                      role: selectedRole,
                      fullName: nameCtrl.text.trim(),
                      email: emailCtrl.text.trim(),
                      phone: phoneCtrl.text.trim().isNotEmpty ? phoneCtrl.text.trim() : null,
                      notes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                    );
                    if (ok && ctx.mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Yeni sakin başarıyla eklendi ve oturum başlatıldı.'),
                          backgroundColor: AppColors.accentGreen,
                        ),
                      );
                    } else if (ctx.mounted) {
                      setDialogState(() {
                        isSaving = false;
                        errorMsg = 'Kayıt işlemi başarısız oldu.';
                      });
                    }
                  },
                  icon: isSaving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.save, size: 16),
                  label: const Text('Kaydet & Girişi Başlat'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accentGreen,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'TENANT', label: Text('Kiracı (Tenant)'), icon: Icon(Icons.key)),
                    ButtonSegment(value: 'OWNER', label: Text('Kat Maliki (Owner)'), icon: Icon(Icons.home)),
                  ],
                  selected: {selectedRole},
                  onSelectionChanged: (val) {
                    setDialogState(() {
                      selectedRole = val.first;
                    });
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: 'Sakin Adı Soyadı *',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: emailCtrl,
                  decoration: InputDecoration(
                    labelText: 'E-posta Adresi *',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  decoration: InputDecoration(
                    labelText: 'Telefon Numarası',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
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
                  Text(errorMsg!, style: const TextStyle(color: AppColors.accentRed, fontSize: 12)),
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
    String selectedRelationship = member.relationship.isNotEmpty ? member.relationship : 'Eşi';
    final relationships = ['Eşi', 'Çocuğu', 'Anne/Baba', 'Kardeşi', 'Akrabası', 'Ev Arkadaşı', 'Diğer'];
    if (!relationships.contains(selectedRelationship)) {
      relationships.add(selectedRelationship);
    }
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
                  child: const Text('Vazgeç'),
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
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Hane sakini başarıyla güncellendi.'),
                                backgroundColor: AppColors.accentGreen,
                              ),
                            );
                          } else if (ctx.mounted) {
                            setDialogState(() {
                              isSaving = false;
                              generalError = 'Güncelleme sırasında bir hata oluştu.';
                            });
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
                      : const Text('Kaydet', style: TextStyle(fontWeight: FontWeight.bold)),
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
                      child: Text(generalError!, style: const TextStyle(color: AppColors.accentRed, fontSize: 13)),
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
                    items: relationships.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
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
      message: '${member.fullName} (${member.relationship}) adlı hane sakini kaydını ${ho.block} Blok Daire ${ho.unitNo} listesinden silmek istediğinize emin misiniz?',
      confirmLabel: 'Evet, Sil',
      cancelLabel: 'Vazgeç',
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
            SnackBar(
              content: Text(success ? 'Hane sakini başarıyla silindi.' : 'Hane sakini silinirken bir hata oluştu.'),
              backgroundColor: success ? AppColors.accentGreen : AppColors.accentRed,
            ),
          );
        }
      }
    });
  }

  void _showAddHouseholdMemberDialog(HomeOwnerItem ho) {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    String selectedRelationship = 'Eşi';
    final relationships = ['Eşi', 'Çocuğu', 'Anne/Baba', 'Kardeşi', 'Akrabası', 'Ev Arkadaşı', 'Diğer'];
    bool isSaving = false;
    String? nameError;
    String? generalError;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AppFullscreenPage(
            title: 'Yeni Hane Sakini Ekle',
            subtitle: '${ho.block} Daire ${ho.unitNo} • Birlikte Yaşayan Kişi',
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
                  child: const Text('Vazgeç'),
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

                          final ok = await widget.controller.addHouseholdMember(
                            unitId: ho.unitId,
                            block: ho.block,
                            unitNo: ho.unitNo,
                            fullName: name,
                            phone: phoneCtrl.text.trim(),
                            email: emailCtrl.text.trim().isNotEmpty
                                ? emailCtrl.text.trim()
                                : 'sakin.${DateTime.now().millisecondsSinceEpoch}@example.com',
                            relationship: selectedRelationship,
                          );

                          if (ok && ctx.mounted) {
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Hane sakini başarıyla eklendi.'),
                                backgroundColor: AppColors.accentGreen,
                              ),
                            );
                          } else if (ctx.mounted) {
                            setDialogState(() {
                              isSaving = false;
                              generalError = 'Kayıt sırasında bir hata oluştu.';
                            });
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
                      : const Text('Kaydet', style: TextStyle(fontWeight: FontWeight.bold)),
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
                      child: Text(generalError!, style: const TextStyle(color: AppColors.accentRed, fontSize: 13)),
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
                    key: const Key('household_name_field'),
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
                    items: relationships.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
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
                    key: const Key('household_phone_field'),
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
                    key: const Key('household_email_field'),
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
              child: const Text('Vazgeç'),
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
                                style: const TextStyle(color: AppColors.accentOrange, fontSize: 12, fontWeight: FontWeight.w600),
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
                      child: ElevatedButton.icon(
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
                                const SnackBar(
                                  content: Text('Kiracı daireden başarıyla çıkarıldı. Daire boş duruma getirildi.'),
                                  backgroundColor: AppColors.accentGreen,
                                ),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Kiracı çıkarılırken bir hata oluştu.'),
                                  backgroundColor: AppColors.accentRed,
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.logout, size: 16),
                        label: const Text('Kiracıyı Daireden Çıkar'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accentOrange,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
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
                                style: const TextStyle(color: AppColors.accentRed, fontSize: 12, fontWeight: FontWeight.w600),
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
                      child: OutlinedButton.icon(
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
                                const SnackBar(
                                  content: Text('Kat maliki ve daire başarıyla silindi.'),
                                  backgroundColor: AppColors.accentGreen,
                                ),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Silme işlemi sırasında bir hata oluştu.'),
                                  backgroundColor: AppColors.accentRed,
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.delete_forever, size: 16, color: AppColors.accentRed),
                        label: const Text('Daireyi ve Kat Malikini Tamamen Sil', style: TextStyle(color: AppColors.accentRed, fontWeight: FontWeight.bold)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.accentRed),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
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
      cancelLabel: 'Vazgeç',
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
              const SnackBar(
                content: Text('Kat maliki başarıyla silindi.'),
                backgroundColor: AppColors.accentGreen,
                duration: Duration(seconds: 3),
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Kat maliki silinirken bir hata oluştu.'),
                backgroundColor: AppColors.accentRed,
                duration: Duration(seconds: 3),
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
      cancelLabel: 'Vazgeç',
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
              const SnackBar(
                content: Text('Kiracı başarıyla çıkarıldı. Daire boş duruma getirildi.'),
                backgroundColor: AppColors.accentGreen,
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Kiracı çıkarılırken bir hata oluştu.'),
                backgroundColor: AppColors.accentRed,
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

    bool isValidPhone(String phone) {
      if (phone.isEmpty) return false;
      final digits = phone.replaceAll(RegExp(r'\D'), '');
      return digits.length >= 10 && digits.length <= 13;
    }

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
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
                OutlinedButton.icon(
                  key: const Key('edit_ho_delete_button'),
                  onPressed: isSaving ? null : () => _confirmDeleteHomeOwner(resident, parentCtx: ctx),
                  icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.accentRed),
                  label: const Text('Sil', style: TextStyle(color: AppColors.accentRed, fontWeight: FontWeight.bold)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.accentRed),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                OutlinedButton(
                  onPressed: isSaving ? null : () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary(context),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('İptal'),
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

                          final emailRegex = RegExp(r'^[\w\.-]+@[\w\.-]+\.\w{2,}$');
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
                            } else if (!emailRegex.hasMatch(tEmail)) {
                              newTenantEmailErr = 'Geçerli bir e-posta adresi giriniz.';
                              hasError = true;
                            }
                            if (tPhone.isEmpty) {
                              newTenantPhoneErr = 'Kiracı telefon numarası zorunludur.';
                              hasError = true;
                            } else if (!isValidPhone(tPhone)) {
                              newTenantPhoneErr = 'Geçerli bir telefon numarası giriniz (10-12 hane).';
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
                            } else if (!emailRegex.hasMatch(oEmail)) {
                              newOwnerEmailErr = 'Geçerli bir e-posta adresi giriniz.';
                              hasError = true;
                            }
                            if (oPhone.isEmpty) {
                              newOwnerPhoneErr = isTenant ? 'Ev Sahibi telefon numarası zorunludur.' : 'Telefon numarası zorunludur.';
                              hasError = true;
                            } else if (!isValidPhone(oPhone)) {
                              newOwnerPhoneErr = 'Geçerli bir telefon numarası giriniz (10-12 hane).';
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

                          final selectedTariff = houseTypes.where((ht) => ht.typeName == selectedHouseType).firstOrNull;
                          final dues = selectedTariff?.duesAmount ?? (Decimal.tryParse(duesCtrl.text.replaceAll(',', '.')) ?? resident.monthlyDues);
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
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Sakin bilgileri başarıyla güncellendi.'),
                                backgroundColor: AppColors.accentGreen,
                              ),
                            );
                          } else {
                            setDialogState(() {
                              isSaving = false;
                              generalError = 'Güncelleme sırasında hata oluştu. Lütfen tekrar deneyiniz.';
                            });
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentCyan,
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
                      : const Text('Kaydet', style: TextStyle(fontWeight: FontWeight.bold)),
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
                        style: const TextStyle(color: AppColors.accentRed, fontSize: 13),
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
                            child: InkWell(
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
                                        color: activeDialogTab == 0 ? AppColors.accentGreen : AppColors.textSecondary(context),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
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
                                        color: activeDialogTab == 1 ? AppColors.accentCyan : AppColors.textSecondary(context),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
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
                            ),
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
                                  child: const Text(
                                    'Kiracı',
                                    style: TextStyle(
                                      color: AppColors.accentGreen,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text('Kiracı Ad Soyad *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                            const SizedBox(height: 6),
                            TextField(
                              key: const Key('tenant_name_field'),
                              controller: tenantNameCtrl,
                              decoration: InputDecoration(
                                hintText: 'Örn: Canan Can',
                                errorText: tenantNameError,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text('Kiracı Telefon Numarası *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                            const SizedBox(height: 6),
                            TextField(
                              key: const Key('tenant_phone_field'),
                              controller: tenantPhoneCtrl,
                              keyboardType: TextInputType.phone,
                              decoration: InputDecoration(
                                hintText: 'Örn: 0533 111 22 33',
                                errorText: tenantPhoneError,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text('Kiracı E-posta Adresi *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                            const SizedBox(height: 6),
                            TextField(
                              key: const Key('tenant_email_field'),
                              controller: tenantEmailCtrl,
                              keyboardType: TextInputType.emailAddress,
                              decoration: InputDecoration(
                                hintText: 'Örn: canan@example.com',
                                errorText: tenantEmailError,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: isSaving ? null : () => _confirmRemoveTenantFromEdit(resident, ctx),
                                icon: const Icon(Icons.logout, size: 14, color: AppColors.accentOrange),
                                label: const Text(
                                  'Kiracıyı Daireden Çıkar (Move-Out)',
                                  style: TextStyle(color: AppColors.accentOrange, fontSize: 12, fontWeight: FontWeight.bold),
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
                                    ElevatedButton.icon(
                                      key: const Key('dialog_add_household_member'),
                                      onPressed: () {
                                        _showAddHouseholdMemberDialog(currentHo);
                                        setDialogState(() {});
                                      },
                                      icon: const Icon(Icons.person_add_alt, size: 14),
                                      label: const Text('Yeni Sakin Ekle', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.accentPurple,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        minimumSize: const Size(0, 32),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                    ),
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
                                                '${m.relationship}${m.phone.isNotEmpty ? ' • ${m.phone}' : ''}${m.email.isNotEmpty ? ' • ${m.email}' : ''}',
                                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          key: Key('dialog_edit_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                          icon: const Icon(Icons.edit_outlined, size: 16, color: AppColors.accentCyan),
                                          tooltip: 'Düzenle',
                                          onPressed: () {
                                            _showEditHouseholdMemberDialog(currentHo, m);
                                            setDialogState(() {});
                                          },
                                        ),
                                        IconButton(
                                          key: Key('dialog_delete_member_${m.id.isNotEmpty ? m.id : m.fullName}'),
                                          icon: const Icon(Icons.close, size: 16, color: AppColors.accentRed),
                                          tooltip: 'Sil',
                                          onPressed: () {
                                            _confirmDeleteHouseholdMember(currentHo, m);
                                            setDialogState(() {});
                                          },
                                        ),
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
                                  child: const Text(
                                    'Ev Sahibi',
                                    style: TextStyle(
                                      color: AppColors.accentCyan,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text('Ev Sahibi Ad Soyad *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                            const SizedBox(height: 6),
                            TextField(
                              key: const Key('owner_name_field'),
                              controller: ownerNameCtrl,
                              decoration: InputDecoration(
                                hintText: 'Örn: Murat Demir',
                                errorText: ownerNameError,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text('Ev Sahibi Telefon Numarası *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                            const SizedBox(height: 6),
                            TextField(
                              key: const Key('owner_phone_field'),
                              controller: ownerPhoneCtrl,
                              keyboardType: TextInputType.phone,
                              decoration: InputDecoration(
                                hintText: 'Örn: 0555 123 4567',
                                errorText: ownerPhoneError,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text('Ev Sahibi E-posta Adresi *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                            const SizedBox(height: 6),
                            TextField(
                              key: const Key('owner_email_field'),
                              controller: ownerEmailCtrl,
                              keyboardType: TextInputType.emailAddress,
                              decoration: InputDecoration(
                                hintText: 'Örn: murat@example.com',
                                errorText: ownerEmailError,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            ),
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
                  ],

                  // House Type
                  if (houseTypes.isNotEmpty) ...[
                    Text('Konut Tipi (Daire Tipi)', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: houseTypes.any((ht) => ht.typeName == selectedHouseType)
                          ? selectedHouseType
                          : null,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                      hint: const Text('Konut Tipi Seçiniz'),
                      items: houseTypes.map((ht) {
                        return DropdownMenuItem<String>(
                          value: ht.typeName,
                          child: Text('${ht.typeName} (₺${ht.duesAmount.toStringAsFixed(2)})'),
                        );
                      }).toList(),
                      onChanged: (val) {
                        setDialogState(() {
                          selectedHouseType = val;
                          final match = houseTypes.firstWhere((ht) => ht.typeName == val);
                          duesCtrl.text = match.duesAmount.toStringAsFixed(2);
                        });
                      },
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
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.lock, size: 10, color: AppColors.accentCyan),
                            SizedBox(width: 4),
                            Text(
                              'Konut tipine bağlı',
                              style: TextStyle(
                                color: AppColors.accentCyan,
                                fontSize: 10,
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
                          '₺${duesCtrl.text}',
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
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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

  Widget _buildHesapHareketleriSection() {
    final transactions = widget.controller.accountTransactions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'HESAP HAREKETLERİ →',
              style: TextStyle(
                color: AppColors.textSecondary(context),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
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
                          style: TextStyle(color: AppColors.textSecondary(context).withValues(alpha: 0.8), fontSize: 11),
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
              final color = item.isCredit ? const Color(0xFF10B981) : const Color(0xFFEF4444);
              final icon = item.isCredit
                  ? (item.title.contains('FAST') ? Icons.flash_on : Icons.check_circle_outline)
                  : Icons.apartment;

              return Column(
                children: [
                  InkWell(
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
                                    fontSize: 11,
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
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
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

  Widget _buildDairemHouseholdCard() {
    final residents = widget.controller.unitResidents;
    final isOwner = widget.controller.userRole == UserRole.homeOwner ||
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.people_outline, color: AppColors.accentCyan, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Hane Sakinleri (${widget.controller.activeUnit.blok} Blok D:${widget.controller.activeUnit.daireNo})',
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              if (isOwner)
                TextButton.icon(
                  onPressed: () => widget.controller.generateUnitInviteLink(),
                  icon: const Icon(Icons.share, size: 14, color: AppColors.accentOrange),
                  label: const Text(
                    'Davet Linki',
                    style: TextStyle(color: AppColors.accentOrange, fontSize: 11),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
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
                    Column(
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
                          r.relationship,
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                        ),
                      ],
                    ),
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
                          color: r.isOwner ? AppColors.accentCyan : AppColors.textSecondary(context),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
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

  void _showPaymentDialog(AidatBorcu dues, {CheckoutPaymentMethod initialMethod = CheckoutPaymentMethod.card}) {
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => PaymentCheckoutDialog(
        dues: dues,
        siteName: widget.controller.activeUnit.siteAdi,
        unitDesc: '${widget.controller.activeUnit.blok} Blok D:${widget.controller.activeUnit.daireNo}',
        virtualIban: widget.controller.userRole == UserRole.siteManager &&
                widget.controller.siteAdminPath == SiteAdminActivePath.myFlatOwner
            ? 'TR12 0006 2000 0000 0000 0001'
            : 'TR12 0006 2000 0000 0000 0014',
        initialMethod: initialMethod,
        onPaymentSuccess: (paidAmount) {
          widget.controller.recordHomeownerPayment(
            block: widget.controller.activeUnit.block,
            unitNo: widget.controller.activeUnit.unitNo,
            amount: paidAmount,
            paymentMethod: 'CREDIT_CARD',
            note: '${dues.donem} Aidat Kart Ödemesi',
          );
          final snackMsg = paidAmount > dues.toplamTutar && dues.toplamTutar > Decimal.zero
              ? '₺${paidAmount.toStringAsFixed(2)} tutarındaki kart ödemeniz alındı! Borcunuz kapatıldı, ₺${(paidAmount - dues.toplamTutar).toStringAsFixed(2)} avans bakiyenize aktarıldı.'
              : (paidAmount < dues.toplamTutar
                  ? '₺${paidAmount.toStringAsFixed(2)} tutarındaki kısmi ödemeniz alındı. Kalan borç: ₺${(dues.toplamTutar - paidAmount).toStringAsFixed(2)}'
                  : (dues.toplamTutar <= Decimal.zero
                      ? '₺${paidAmount.toStringAsFixed(2)} tutarı avans bakiyenize başarıyla aktarıldı.'
                      : '₺${paidAmount.toStringAsFixed(2)} tutarındaki kart ödemeniz başarıyla alındı! Borcunuz kapatıldı.'));

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(snackMsg),
              backgroundColor: AppColors.accentGreen,
              duration: const Duration(seconds: 4),
            ),
          );
        },
      ),
    );
  }

  void _showDuesDetailDialog(AidatBorcu dues) {
    final advPayment = widget.controller.activeUnit.advancePayment ?? Decimal.zero;
    final totalDebt = dues.toplamTutar;
    final hasDebt = totalDebt > Decimal.zero;
    final duesList = widget.controller.duesList;

    if (!hasDebt) {
      AppFullscreenPage.push(
        context: context,
        builder: (ctx) => AppFullscreenPage(
          title: 'Hesap & Bakiye Özeti',
          subtitle: '${widget.controller.activeUnit.siteAdi} • ${widget.controller.activeUnit.blok} Blok D:${widget.controller.activeUnit.daireNo}',
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
                  backgroundColor: AppColors.accentGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Kapat', style: TextStyle(fontWeight: FontWeight.bold)),
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
                          const Text(
                            'Borç Durumu: Güncel',
                            style: TextStyle(
                              color: AppColors.accentGreen,
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
                        Text(
                          'Mevcut Avans Bakiyesi (Alacak)',
                          style: TextStyle(
                            color: AppColors.textSecondary(context),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.accentGreen.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Kullanıma Hazır',
                            style: TextStyle(color: AppColors.accentGreen, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '+₺${advPayment.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: AppColors.accentGreen,
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
                                fontSize: 11.5,
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
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                              Row(
                                children: [
                                  Text(
                                    '₺${d.principalAmount.toStringAsFixed(2)}',
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
                                        color: isPaid ? AppColors.accentGreen : AppColors.accentRed,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
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
          subtitle: '${dues.donem} • KMK Madde 20 Yasal Gecikme Cetveli',
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
                  backgroundColor: AppColors.accentCyan,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Kapat', style: TextStyle(fontWeight: FontWeight.bold)),
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
                    Text('• Dönem: ${dues.donem}', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13)),
                    const SizedBox(height: 8),
                    Text('• Ana Para Aidat: ₺${dues.anaPara.toStringAsFixed(2)}', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text('• Son Ödeme Tarihi: ${dues.sonOdemeTarihi.day.toString().padLeft(2, '0')}.${dues.sonOdemeTarihi.month.toString().padLeft(2, '0')}.${dues.sonOdemeTarihi.year}', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13)),
                    if (dues.gecikmeTazminati > Decimal.zero) ...[
                      const SizedBox(height: 8),
                      Text('• Gecikme Durumu: ${dues.gecikenGunSayisi} Gün Gecikme', style: const TextStyle(color: AppColors.accentRed, fontSize: 13, fontWeight: FontWeight.w500)),
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
                        child: Text(
                          '• Gecikme Tazminatı: (${dues.anaPara.toStringAsFixed(0)} * 0.05 / 30) * ${dues.gecikenGunSayisi} = ₺${dues.gecikmeTazminati.toStringAsFixed(2)}',
                          style: const TextStyle(color: AppColors.accentRed, fontWeight: FontWeight.bold, fontSize: 12.5),
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Divider(color: AppColors.border(context)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Ödenecek Toplam Tutar:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        Text('₺${dues.toplamTutar.toStringAsFixed(2)}', style: const TextStyle(color: AppColors.accentRed, fontWeight: FontWeight.bold, fontSize: 16)),
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
        subtitle: '${widget.controller.activeUnit.siteAdi} • ${widget.controller.activeUnit.blok} Blok D:${widget.controller.activeUnit.daireNo}',
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
                backgroundColor: AppColors.accentCyan,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Kapat', style: TextStyle(fontWeight: FontWeight.bold)),
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
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                  style: const TextStyle(
                    color: AppColors.accentGreen,
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Görüntüle',
                      style: TextStyle(
                        color: AppColors.accentCyan,
                        fontSize: 10.5,
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
                backgroundColor: AppColors.accentCyan,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Kapat', style: TextStyle(fontWeight: FontWeight.bold)),
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
                  Text(
                    'TAHSİLAT MAKBUZU',
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'ONAYLANDI',
                      style: TextStyle(color: AppColors.accentGreen, fontSize: 10.5, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Center(
                child: Column(
                  children: [
                    Text(
                      tx.amountStr,
                      style: const TextStyle(
                        color: AppColors.accentGreen,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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
              _buildReceiptRow('İşlem / Makbuz No:', tx.id),
              const SizedBox(height: 8),
              _buildReceiptRow('İşlem Tarihi:', tx.date),
              const SizedBox(height: 8),
              _buildReceiptRow('Site & Daire:', '${widget.controller.activeUnit.siteAdi.isNotEmpty ? widget.controller.activeUnit.siteAdi : widget.controller.siteName} • ${widget.controller.activeUnit.blok} Blok D:${widget.controller.activeUnit.daireNo}'),
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
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 10.5),
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
        Text(
          label,
          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
        ),
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
                child: Text('Vazgeç', style: TextStyle(color: AppColors.textSecondary(context), fontWeight: FontWeight.w600)),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Talebiniz #TLP-842 numarasıyla site yönetimine iletildi.'),
                      backgroundColor: AppColors.accentGreen,
                      duration: Duration(seconds: 3),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentCyan,
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
                backgroundColor: AppColors.accentCyan,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Kapat', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        child: Column(
          children: [
            _buildAnnouncementItem(
              tag: 'Planlı Bakım',
              tagColor: AppColors.accentOrange,
              title: 'A ve B Blok Asansör Periyodik Muayenesi',
              date: '28 Eylül 2026 • 10:00 - 14:00',
              desc: 'TMMOB akredite muayene kuruluşu tarafından yıllık periyodik kontroller yapılacaktır. Bakım esnasında asansörler kısa süreli servis dışı kalacaktır.',
            ),
            const SizedBox(height: 12),
            _buildAnnouncementItem(
              tag: 'Genel Kurul',
              tagColor: AppColors.accentCyan,
              title: 'Olağan Kat Malikleri Genel Kurul Toplantısı',
              date: '15 Ekim 2026 • 19:30',
              desc: '${widget.controller.siteName.isNotEmpty ? widget.controller.siteName : 'Site'} 2026-2027 dönemi tahmini işletme bütçesi, aidat artış oranı ve yönetim kurulu seçimi toplantı salonunda gerçekleştirilecektir.',
            ),
            const SizedBox(height: 12),
            _buildAnnouncementItem(
              tag: 'Bilgilendirme',
              tagColor: AppColors.accentGreen,
              title: 'Merkezi Isıtma & Boyler Kazanı Kış Bakımı Tamamlandı',
              date: '24 Eylül 2026',
              desc: 'Kazan dairesi brülör ve sirkülasyon pompaları kış sezonuna hazır hale getirilmiştir.',
            ),
          ],
        ),
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
                  style: TextStyle(color: tagColor, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  date,
                  textAlign: TextAlign.end,
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            desc,
            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, height: 1.35),
          ),
        ],
      ),
    );
  }

  void _showInviteDialog(UnitInviteInfo invite) {
    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
        title: 'Hane Sakini Davet Linki',
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
            OutlinedButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: invite.inviteUrl));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Davet linki kopyalandı!'), backgroundColor: AppColors.accentGreen),
                );
              },
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: BorderSide(color: AppColors.border(context)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Linki Kopyala', style: TextStyle(color: AppColors.accentCyan, fontWeight: FontWeight.w600)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.card(context),
                foregroundColor: AppColors.textPrimary(context),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Kapat', style: TextStyle(fontWeight: FontWeight.bold)),
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
              child: SelectableText(
                invite.inviteUrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontFamily: 'monospace'),
              ),
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
                    child: Text(
                      invite.securityNotice,
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, height: 1.4),
                    ),
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
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Tamam', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
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
              child: SelectableText(
                info.temporaryPassword,
                style: const TextStyle(color: AppColors.accentGreen, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
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
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentCyan,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Tamam', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
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
              child: SelectableText(
                creds.temporaryPassword,
                style: const TextStyle(color: AppColors.accentCyan, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
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
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Tamam', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Üretilen Geçici Şifre:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.card(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accentGreen),
              ),
              child: SelectableText(
                creds.temporaryPassword,
                style: const TextStyle(color: AppColors.accentGreen, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ),
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
    final ownerNameCtrl = TextEditingController();
    final ownerEmailCtrl = TextEditingController();
    final ownerPhoneCtrl = TextEditingController();

    // Default to first house type if available (e.g. 2+1 or 3+1)
    final houseTypes = widget.controller.houseTypes;
    String? selectedHouseType = houseTypes.isNotEmpty ? houseTypes.first.typeName : null;
    String selectedRole = 'OWNER';
    bool isResidentOwner = true;
    String selectedRelationship = 'Eşi';
    bool showSecondaryOwner = false;
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
                  onPressed: () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: BorderSide(color: AppColors.border(context)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text('İptal', style: TextStyle(color: AppColors.textSecondary(context), fontWeight: FontWeight.w600)),
                ),
                ElevatedButton(
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

                    // Email validation
                    final emailRegex = RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');
                    if (emailText.isEmpty || !emailRegex.hasMatch(emailText)) {
                      setDialogState(() {
                        emailError = 'Geçerli bir e-posta adresi giriniz (örn: sakin@site.com)';
                      });
                      return;
                    }

                    // Phone validation
                    final cleanPhone = phoneText.replaceAll(RegExp(r'[\s\-\(\)]'), '');
                    final phoneRegex = RegExp(r'^\+?[0-9]{10,13}$');
                    if (cleanPhone.isEmpty || !phoneRegex.hasMatch(cleanPhone)) {
                      setDialogState(() {
                        phoneError = 'Geçerli bir telefon numarası giriniz (örn: 0555 123 45 67)';
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
                          cancelLabel: 'Vazgeç',
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
                    Navigator.pop(ctx);

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
                        duesAmount: currentTariff?.duesAmount ?? Decimal.zero,
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
                        duesAmount: currentTariff?.duesAmount ?? Decimal.zero,
                        isResident: true,
                        role: selectedRole,
                        relationship: selectedRelationship,
                      );
                    } else {
                      // OWNER
                      await widget.controller.registerHomeOwner(
                        block: selectedBlock!,
                        unitNo: parsedUnit,
                        ownerName: ownerName,
                        email: emailText,
                        phone: phoneText,
                        houseType: selectedHouseType,
                        duesAmount: currentTariff?.duesAmount ?? Decimal.zero,
                        isResident: isResidentOwner,
                        role: selectedRole,
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Kaydet & Şifre Üret', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
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
                          const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              generalError!,
                              style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600),
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
                                '₺${currentTariff.duesAmount}/ay',
                                style: const TextStyle(
                                  color: AppColors.accentGreen,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
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
                              child: DropdownButtonFormField<String>(
                                key: const Key('add_resident_block_dropdown'),
                                value: currentBlocks.contains(selectedBlock) ? selectedBlock : (currentBlocks.isNotEmpty ? currentBlocks.first : null),
                                dropdownColor: AppColors.card(context),
                                isDense: true,
                                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                                decoration: InputDecoration(
                                  labelText: 'Blok Seçiniz',
                                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip: 'Yeni Blok Tanımla',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              icon: const Icon(Icons.add_circle, color: AppColors.accentCyan, size: 20),
                              onPressed: () {
                                final newBlockCtrl = TextEditingController();
                                showDialog(
                                  context: context,
                                  builder: (dCtx) => AlertDialog(
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
                                        child: const Text('İptal'),
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
                                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentCyan),
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
                              child: TextField(
                                controller: unitCtrl,
                                keyboardType: TextInputType.number,
                                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                                decoration: InputDecoration(
                                  labelText: 'Daire No',
                                  hintText: 'Örn: 14',
                                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                                  filled: true,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  fillColor: AppColors.surface(context),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),

                        // Konut Tipi & Tarife Seçimi
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: currentHouseTypes.any((t) => t.typeName == selectedHouseType)
                                    ? selectedHouseType
                                    : (currentHouseTypes.isNotEmpty ? currentHouseTypes.first.typeName : null),
                                isDense: true,
                                dropdownColor: AppColors.card(context),
                                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12),
                                decoration: InputDecoration(
                                  labelText: 'Konut Tipi (Daire Tipi)',
                                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                                          '₺${ht.duesAmount} / ay',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 11,
                                            color: AppColors.accentGreen,
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
                                '+ Tarifeler',
                                style: TextStyle(color: AppColors.accentPurple, fontSize: 11, fontWeight: FontWeight.bold),
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
                          child: SegmentedButton<String>(
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
                              });
                            },
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Role Specific Information Banner & Controls
                        if (selectedRole == 'OWNER') ...[
                          Material(
                            color: Colors.transparent,
                            child: SwitchListTile(
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
                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                              ),
                              value: isResidentOwner,
                              activeThumbColor: AppColors.accentGreen,
                              onChanged: (val) {
                                setDialogState(() {
                                  isResidentOwner = val;
                                });
                              },
                            ),
                          ),
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
                                    style: TextStyle(color: AppColors.textPrimary(context), fontSize: 11, fontWeight: FontWeight.w500),
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
                                    style: TextStyle(color: AppColors.textPrimary(context), fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),

                        // Person Fields (MUST maintain order: nameCtrl = 1, emailCtrl = 2, phoneCtrl = 3)
                        TextField(
                          controller: nameCtrl,
                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                          decoration: InputDecoration(
                            labelText: selectedRole == 'TENANT'
                                ? 'Kiracı Ad Soyad (Fiilen İkamet Eden Sakin)'
                                : (selectedRole == 'RESIDENT' ? 'Hane Sakini Ad Soyad' : 'Ad Soyad'),
                            labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                            filled: true,
                            fillColor: AppColors.surface(context),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
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
                        ),
                        const SizedBox(height: 12),
                        TextField(
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
                        ),

                        // Extra option for Ev Sakini: Relationship selector
                        if (selectedRole == 'RESIDENT') ...[
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            value: selectedRelationship,
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
                                        color: AppColors.accentCyan,
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
                        ],
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
    await AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final houseTypes = widget.controller.houseTypes;

          return AppFullscreenPage(
            title: 'Konut Tipleri & Aidat Tarifeleri',
            subtitle: '${widget.controller.userSession.siteName} için daire tipi bazlı aidat tutarları',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentPurple.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.home_work_outlined, color: AppColors.accentPurple, size: 20),
            ),
            actions: [
              IconButton(
                tooltip: 'Yeni Konut Tipi Ekle',
                icon: const Icon(Icons.add_circle, color: AppColors.accentPurple, size: 26),
                onPressed: () => _showEditHouseTypeDialog(null, setDialogState),
              ),
            ],
            bottomBar: AppFullscreenPage.buildBottomBar(
              context: ctx,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _showEditHouseTypeDialog(null, setDialogState),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Yeni Konut Tipi Ekle', style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentPurple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
            child: houseTypes.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.home_work_outlined, size: 48, color: AppColors.textSecondary(context)),
                          const SizedBox(height: 12),
                          Text(
                            'Tanımlı Konut Tipi Yok',
                            style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Yeni Konut Tipi Ekle butonuyla 1+1, 2+1, 3+1 gibi tipler ve aylık aidatlarını belirleyebilirsiniz.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: houseTypes.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final item = houseTypes[index];
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.card(context),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.border(context)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppColors.accentPurple.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                item.typeName,
                                style: const TextStyle(
                                  color: AppColors.accentPurple,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        'Aylık Aidat: ',
                                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                                      ),
                                      Text(
                                        '₺${item.duesAmount}',
                                        style: const TextStyle(
                                          color: AppColors.accentGreen,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (item.description != null && item.description!.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      item.description!,
                                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              tooltip: 'Düzenle',
                              onPressed: () => _showEditHouseTypeDialog(item, setDialogState),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                              tooltip: 'Sil',
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (c) => AlertDialog(
                                    title: const Text('Tarifeyi Sil'),
                                    content: Text('${item.typeName} tarifesini silmek istediğinize emin misiniz?'),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
                                      TextButton(
                                        onPressed: () => Navigator.pop(c, true),
                                        child: const Text('Sil', style: TextStyle(color: Colors.redAccent)),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  await widget.controller.deleteHouseType(item.id);
                                  setDialogState(() {});
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          );
        },
      ),
    );
  }

  void _showEditHouseTypeDialog(HouseTypeTariff? item, StateSetter parentSetState) {
    final typeNameCtrl = TextEditingController(text: item?.typeName ?? '');
    final duesCtrl = TextEditingController(text: item != null ? item.duesAmount.toString() : '');
    final descCtrl = TextEditingController(text: item?.description ?? '');
    String? errorText;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AppFullscreenPage(
            title: item == null ? 'Yeni Konut Tipi Tanımla' : 'Konut Tipini Düzenle',
            subtitle: 'Daire tipi ve aylık aidat bedeli',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentPurple.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.edit_note, color: AppColors.accentPurple, size: 20),
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
                  child: Text('İptal', style: TextStyle(color: AppColors.textSecondary(context), fontWeight: FontWeight.w600)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final typeName = typeNameCtrl.text.trim();
                    final duesText = duesCtrl.text.trim();
                    final parsedDues = Decimal.tryParse(duesText);

                    if (typeName.isEmpty) {
                      setDialogState(() {
                        errorText = 'Lütfen Konut Tipi adını giriniz (örn: 2+1, 3+1).';
                      });
                      return;
                    }

                    if (parsedDues == null || parsedDues <= Decimal.zero) {
                      setDialogState(() {
                        errorText = 'Lütfen geçerli bir aylık aidat tutarı giriniz.';
                      });
                      return;
                    }

                    final success = await widget.controller.saveHouseType(
                      typeName: typeName,
                      duesAmount: parsedDues,
                      description: descCtrl.text.trim().isNotEmpty ? descCtrl.text.trim() : null,
                    );

                    if (success) {
                      Navigator.pop(ctx);
                      parentSetState(() {});
                    } else {
                      setDialogState(() {
                        errorText = 'Tarife kaydedilemedi. Lütfen tekrar deneyiniz.';
                      });
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentPurple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Kaydet', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            child: Column(
              children: [
                if (errorText != null) ...[
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
                        const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            errorText!,
                            style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                TextField(
                  controller: typeNameCtrl,
                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Konut Tipi (örn: 1+1, 2+1, 3+1, Dublex)',
                    labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                    filled: true,
                    fillColor: AppColors.card(context),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: duesCtrl,
                  keyboardType: TextInputType.number,
                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Aylık Aidat Tutarı (TL)',
                    labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                    filled: true,
                    fillColor: AppColors.card(context),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descCtrl,
                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Açıklama (Opsiyonel)',
                    labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                    filled: true,
                    fillColor: AppColors.card(context),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          );
        },
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

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => AppFullscreenPage(
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
              onPressed: () => Navigator.pop(ctx),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: BorderSide(color: AppColors.border(context)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text('İptal', style: TextStyle(color: AppColors.textSecondary(context), fontWeight: FontWeight.w600)),
            ),
            ElevatedButton(
              onPressed: () {
                final siteName = nameCtrl.text.trim();
                final adminName = adminNameCtrl.text.trim();
                if (siteName.isEmpty || adminName.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Lütfen Site Adı ve Yönetici Ad Soyad alanlarını doldurunuz.'),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                  return;
                }
                final rawBlocks = blocksCtrl.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
                final blocks = rawBlocks.isNotEmpty ? rawBlocks : ['A Blok', 'B Blok'];
                Navigator.pop(ctx);
                widget.controller.registerNewSite(
                  name: siteName,
                  city: cityCtrl.text.trim().isEmpty ? 'İstanbul' : cityCtrl.text.trim(),
                  address: addressCtrl.text.trim(),
                  adminName: adminName,
                  adminEmail: adminEmailCtrl.text.trim().isEmpty ? 'yonetici@sitepulse.internal' : adminEmailCtrl.text.trim(),
                  adminPhone: adminPhoneCtrl.text.trim().isEmpty ? '+90 532 000 00 00' : adminPhoneCtrl.text.trim(),
                  blocks: blocks,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentCyan,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Siteyi Kaydet & Yetkilendir', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        child: Column(
          children: [
            TextField(
              controller: nameCtrl,
              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Site / Proje Adı',
                labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                filled: true,
                fillColor: AppColors.card(context),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: cityCtrl,
              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Şehir',
                labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                filled: true,
                fillColor: AppColors.card(context),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: addressCtrl,
              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Adres',
                labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                filled: true,
                fillColor: AppColors.card(context),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('add_site_blocks_field'),
              controller: blocksCtrl,
              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Bloklar (Virgülle ayırarak giriniz: A Blok, B Blok)',
                helperText: 'Sitede yer alan blokları belirleyin. Sakin eklerken bu bloklar seçilecektir.',
                helperStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                filled: true,
                fillColor: AppColors.card(context),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                prefixIcon: const Icon(Icons.domain, size: 20, color: AppColors.accentCyan),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: adminNameCtrl,
              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Yönetici Ad Soyad',
                labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                filled: true,
                fillColor: AppColors.card(context),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
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
            ),
            const SizedBox(height: 12),
            TextField(
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
            ),
          ],
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
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentCyan,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Anladım', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
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
      cancelLabel: 'Vazgeç',
      confirmColor: Colors.redAccent,
      icon: Icons.delete_forever,
      iconColor: Colors.redAccent,
    ).then((confirmed) {
      if (confirmed == true && mounted) {
        widget.controller.deleteSite(site.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${site.name} başarıyla silindi.'),
            backgroundColor: AppColors.accentGreen,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });
  }

  void _confirmResetAdminPassword(TenantSiteItem site) {
    AppFullscreenPage.pushConfirmation(
      context: context,
      title: 'Geçici Şifre Yenile',
      message: '${site.name} yöneticisi ${site.adminName} (${site.adminEmail}) için yeni bir geçici yönetim şifresi üretilecektir.\n\nMevcut şifre geçersiz kılınır ve yönetici sisteme girdiğinde yeni şifre belirlemeye yönlendirilir.\n\nOnaylıyor musunuz?',
      confirmLabel: 'Şifreyi Yenile',
      cancelLabel: 'Vazgeç',
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
