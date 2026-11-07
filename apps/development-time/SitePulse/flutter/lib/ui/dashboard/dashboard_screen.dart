import '../../testing/test_id.dart';
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
import '../components/house_types_modal.dart';
import '../residents/owners_residents_module_page.dart';
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
          testId('btn_header_toggle_theme', IconButton(
            tooltip: 'Tema Değiştir',
            icon: Icon(
              widget.controller.isDarkMode ? Icons.light_mode : Icons.dark_mode,
              color: AppColors.textSecondary(context),
              size: 20,
            ),
            onPressed: () {
              widget.controller.toggleTheme();
            },
          ), label: widget.controller.isDarkMode ? 'theme:dark' : 'theme:light'),
          testId('btn_header_logout', IconButton(
            tooltip: 'Çıkış Yap / Rol Değiştir',
            icon: const Icon(
              Icons.logout_rounded,
              color: AppColors.accentRed,
              size: 20,
            ),
            onPressed: () {
              widget.controller.logout();
            },
          )),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: testId('btn_open_profile', InkWell(
              onTap: () => _openProfileSheet(context),
              borderRadius: BorderRadius.circular(20),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.primary,
                child: Text(
                  (session.fullName.trim().isEmpty ? '?' : session.fullName.trim().substring(0, 1).toUpperCase()),
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
            )),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
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
            key: ValueKey('tab_scroll_$_selectedTabIndex'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (session.mustChangePassword) _buildMustChangePasswordBanner(),
                _buildCurrentTabContent(isHomeRole),
              ],
            ),
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
                  icon: Icon(isHomeRole ? Icons.home_outlined : (session.role == UserRole.siteManager ? Icons.people_alt_outlined : Icons.apartment_outlined)),
                  activeIcon: Icon(isHomeRole ? Icons.home : (session.role == UserRole.siteManager ? Icons.people_alt : Icons.apartment)),
                  label: isHomeRole ? 'Dairem' : (session.role == UserRole.saasAdmin ? 'Siteler' : 'Sakinler & Malikler'),
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
            child: testId('role_path_manager_cockpit', InkWell(
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
            )),
          ),
          Expanded(
            child: testId('role_path_my_flat', InkWell(
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
                onNavigateToDuesTab: () {
                  setState(() {
                    _selectedTabIndex = 1;
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
          onEditSiteTap: _showEditSiteDialog,
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
        onEditSiteTap: _showEditSiteDialog,
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

    final totalUnits = homeOwners.length;
    final tenantCount = homeOwners.where((h) => h.isTenantOccupied).length;
    final ownerCount = homeOwners.where((h) => h.isOwnerOccupied).length;
    final vacantCount = homeOwners.where((h) => h.isVacant).length;
    final totalCoResidents = homeOwners.fold<int>(0, (sum, h) => sum + h.householdResidents.length);
    final occupancyRate = totalUnits > 0 ? (((totalUnits - vacantCount) / totalUnits) * 100).toStringAsFixed(1) : '0';

    final filtered = homeOwners.where((ho) {
      if (_homeOwnerBlockFilter != 'ALL') {
        final b1 = ho.block.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();
        final b2 = _homeOwnerBlockFilter.toUpperCase().replaceAll('BLOK', '').replaceAll(RegExp(r'[^A-Z0-9]'), '').trim();
        if (b1 != b2) return false;
      }
      if (_homeOwnerOccupancyFilter == 'TENANT') {
        if (!ho.isTenantOccupied) return false;
      } else if (_homeOwnerOccupancyFilter == 'OWNER') {
        if (!ho.isOwnerOccupied) return false;
      } else if (_homeOwnerOccupancyFilter == 'VACANT') {
        if (!ho.isVacant) return false;
      }
      if (_homeOwnerSearchQuery.isNotEmpty) {
        final q = _homeOwnerSearchQuery.toLowerCase();
        final matchName = ho.ownerFullName.toLowerCase().contains(q);
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
        final matchEmail = ho.email.toLowerCase().contains(q) || (ho.tenantEmail ?? '').toLowerCase().contains(q);
        final matchBlock = ho.block.toLowerCase().contains(q);
        return matchName || matchTenant || matchResponsible || matchResidents || matchUnit || matchPhone || matchEmail || matchBlock;
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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.accentCyan.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.people_alt_outlined, color: AppColors.accentCyan, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Kat Malikleri & Sakinler Yönetimi',
                          style: TextStyle(
                            color: AppColors.textPrimary(context),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${widget.controller.userSession.siteName} • Toplam $totalCount bağımsız bölüm (${homeOwners.length} kayıtlı)',
                          style: TextStyle(
                            color: AppColors.textSecondary(context),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  testId('open_owners_residents_module', OutlinedButton.icon(
                    key: const Key('open_owners_residents_module'),
                    onPressed: () {
                      AppFullscreenPage.push(
                        context: context,
                        builder: (_) => OwnersResidentsModulePage(controller: widget.controller),
                      );
                    },
                    icon: const Icon(Icons.fullscreen, size: 16),
                    label: const Text('Tam Ekran Modu', style: TextStyle(fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.accentCyan,
                      side: const BorderSide(color: AppColors.accentCyan),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: const Size(0, 30),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  )),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  testId('add_resident_btn', ElevatedButton.icon(
                    key: const Key('add_resident_btn'),
                    onPressed: _showAddResidentDialog,
                    icon: const Icon(Icons.person_add_outlined, size: 15),
                    label: const Text('Yeni Sakin Ekle', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentCyan,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      minimumSize: const Size(0, 30),
                    ),
                  )),
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
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // Live KPI Metrics Bar
        _buildKpiMetrics(
          totalUnits: totalUnits,
          occupancyRate: occupancyRate,
          tenantCount: tenantCount,
          ownerCount: ownerCount,
          vacantCount: vacantCount,
          totalCoResidents: totalCoResidents,
        ),

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
              _buildOccupancyFilterChip('Tümü ($totalUnits)', 'ALL'),
              const SizedBox(width: 6),
              _buildOccupancyFilterChip('👥 Kiracılı ($tenantCount)', 'TENANT'),
              const SizedBox(width: 6),
              _buildOccupancyFilterChip('🔑 Malik Mukim ($ownerCount)', 'OWNER'),
              const SizedBox(width: 6),
              _buildOccupancyFilterChip('🚪 Boş Daire ($vacantCount)', 'VACANT'),
              const SizedBox(width: 8),
              Container(width: 1, height: 16, color: AppColors.border(context)),
              const SizedBox(width: 8),
              _buildBlockFilterChip('Tümü', 'ALL'),
              ...availableBlocks.map((b) => _buildBlockFilterChip(b, b)),
            ],
          ),
        ),

        const SizedBox(height: 8),

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

  Widget _buildKpiMetrics({
    required int totalUnits,
    required String occupancyRate,
    required int tenantCount,
    required int ownerCount,
    required int vacantCount,
    required int totalCoResidents,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.analytics_outlined, size: 16, color: AppColors.accentCyan),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Sakin & Mülkiyet Durum Özeti',
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.accentGreen.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Doluluk: %$occupancyRate',
                  style: const TextStyle(
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
        Icon(icon, size: 15, color: color),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: AppColors.textPrimary(context),
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary(context),
            fontSize: 9,
          ),
        ),
      ],
    );
  }

  Widget _buildOccupancyFilterChip(String label, String code) {
    final isSelected = _homeOwnerOccupancyFilter == code;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) {
        setState(() {
          _homeOwnerOccupancyFilter = code;
        });
      },
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
                testId('history_ho_${ho.unitId}', IconButton(
                  key: Key('history_ho_${ho.unitId}'),
                  icon: const Icon(Icons.history, size: 18, color: AppColors.accentCyan),
                  tooltip: 'Daire İkamet & Sakin Tarihçesi',
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
                  onPressed: () => _showUnitOccupancyHistoryDialog(ho),
                )),
                const SizedBox(width: 4),
                if (!isVacant)
                  testId('move_out_ho_${ho.unitId}', IconButton(
                    key: Key('move_out_ho_${ho.unitId}'),
                    icon: const Icon(Icons.logout_outlined, size: 18, color: AppColors.accentOrange),
                    tooltip: 'Sakin Ayrılışı (Move-Out)',
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    onPressed: () => _showMoveOutDialog(ho),
                  ))
                else
                  testId('move_in_ho_${ho.unitId}', IconButton(
                    key: Key('move_in_ho_${ho.unitId}'),
                    icon: const Icon(Icons.person_add_alt, size: 18, color: AppColors.accentGreen),
                    tooltip: 'Yeni Sakin / Giriş (Move-In)',
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    onPressed: () => _showMoveInDialog(ho),
                  )),
                const SizedBox(width: 4),
                testId('delete_ho_${ho.unitId}', IconButton(
                  key: Key('delete_ho_${ho.unitId}'),
                  icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.accentRed),
                  tooltip: 'Kat Malikini Sil',
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
                  onPressed: () => _confirmDeleteHomeOwner(ho),
                )),
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
                              style: const TextStyle(
                                color: AppColors.accentCyan,
                                fontSize: 11,
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
                            label: const Text('Sorumluyu Seç', style: TextStyle(fontSize: 11, color: AppColors.accentCyan, fontWeight: FontWeight.bold)),
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
                                  const Expanded(
                                    child: Text(
                                      'Fiilen İkamet Eden Kiracı (Birincil Muhatap)',
                                      style: TextStyle(
                                        color: AppColors.accentGreen,
                                        fontSize: 11,
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
                                  testId('edit_residents_${ho.unitId}', OutlinedButton.icon(
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
                                  )),
                                  testId('move_out_resident_${ho.unitId}', OutlinedButton.icon(
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
                                  Text(
                                    'Hane Sakinleri / Birlikte Yaşayanlar (${ho.householdResidents.length})',
                                    style: TextStyle(
                                      color: AppColors.textPrimary(context),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const Spacer(),
                                  testId('add_resident_to_${ho.unitId}', TextButton.icon(
                                    key: Key('add_resident_to_${ho.unitId}'),
                                    onPressed: () => _showAddHouseholdMemberDialog(ho),
                                    icon: const Icon(Icons.person_add_alt_1, size: 14, color: AppColors.accentPurple),
                                    label: const Text('+ Hane Sakini Ekle', style: TextStyle(color: AppColors.accentPurple, fontSize: 11, fontWeight: FontWeight.bold)),
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
                                          style: TextStyle(
                                            color: AppColors.textSecondary(context),
                                            fontSize: 11,
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
                                  const Expanded(
                                    child: Text(
                                      'Kat Maliki (Daire Mülk Sahibi)',
                                      style: TextStyle(
                                        color: AppColors.accentCyan,
                                        fontSize: 11,
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
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  testId('edit_owner_${ho.unitId}', OutlinedButton.icon(
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
                                  )),
                                  testId('module_transfer_ownership_${ho.unitId}', OutlinedButton.icon(
                                    key: Key('module_transfer_ownership_${ho.unitId}'),
                                    onPressed: () => _showTransferOwnershipDialog(ho),
                                    icon: const Icon(Icons.real_estate_agent, size: 12),
                                    label: const Text('Mülk Devri (Satış)', style: TextStyle(fontSize: 11)),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.teal,
                                      side: const BorderSide(color: Colors.teal),
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
                                    fontSize: 11,
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
                                      const SizedBox(height: 10),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        children: [
                                          testId('edit_residents_${ho.unitId}', OutlinedButton.icon(
                                            key: Key('edit_residents_${ho.unitId}'),
                                            onPressed: () => _showEditHomeOwnerDialog(ho, initialTab: 0),
                                            icon: const Icon(Icons.edit_outlined, size: 12),
                                            label: const Text('Sakinleri Düzenle', style: TextStyle(fontSize: 11)),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: AppColors.accentCyan,
                                              side: const BorderSide(color: AppColors.accentCyan),
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                              minimumSize: const Size(0, 28),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                            ),
                                          )),
                                          testId('add_resident_member_to_${ho.unitId}', OutlinedButton.icon(
                                            key: Key('add_resident_member_to_${ho.unitId}'),
                                            onPressed: () => _showAddHouseholdMemberDialog(ho),
                                            icon: const Icon(Icons.person_add_alt_1, size: 12),
                                            label: const Text('+ Hane Sakini Ekle', style: TextStyle(fontSize: 11)),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: AppColors.accentPurple,
                                              side: const BorderSide(color: AppColors.accentPurple),
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                              minimumSize: const Size(0, 28),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                            ),
                                          )),
                                          testId('move_in_resident_to_${ho.unitId}', OutlinedButton.icon(
                                            key: Key('move_in_resident_to_${ho.unitId}'),
                                            onPressed: () => _showMoveInDialog(ho),
                                            icon: const Icon(Icons.key, size: 12),
                                            label: Text(
                                              isTenant ? 'Yeni Kiracı Girişi (Move-In)' : 'Kiracı Tanımla (Move-In)',
                                              style: const TextStyle(fontSize: 11),
                                            ),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: AppColors.accentGreen,
                                              side: const BorderSide(color: AppColors.accentGreen),
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                              minimumSize: const Size(0, 28),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                            ),
                                          )),
                                          testId('move_out_resident_${ho.unitId}', OutlinedButton.icon(
                                            key: Key('move_out_resident_${ho.unitId}'),
                                            onPressed: () => _showMoveOutDialog(ho),
                                            icon: const Icon(Icons.logout, size: 12),
                                            label: const Text('Sakin Ayrılışı (Move-Out)', style: TextStyle(fontSize: 11)),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: AppColors.accentOrange,
                                              side: const BorderSide(color: AppColors.accentOrange),
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
                                        label: const Text('Yeni Sakin / Kiracı Girişi (Move-In)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: AppColors.accentGreen,
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
                                    fontSize: 11,
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
                                label: const Text('+ Sakin Ekle', style: TextStyle(color: AppColors.accentPurple, fontSize: 11, fontWeight: FontWeight.bold)),
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
                                      style: TextStyle(
                                        color: AppColors.textSecondary(context),
                                        fontSize: 11,
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

            const SizedBox(height: 12),

            // UNIT QUICK ACTIONS ROW
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                testId('quick_add_resident_${ho.unitId}', OutlinedButton.icon(
                  key: Key('quick_add_resident_${ho.unitId}'),
                  onPressed: () => _showAddHouseholdMemberDialog(ho),
                  icon: const Icon(Icons.family_restroom, size: 13, color: AppColors.accentPurple),
                  label: const Text('+ Hane Sakini Ekle', style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accentPurple,
                    side: const BorderSide(color: AppColors.accentPurple),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 30),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                )),
                testId('quick_move_in_${ho.unitId}', OutlinedButton.icon(
                  key: Key('quick_move_in_${ho.unitId}'),
                  onPressed: () => _showMoveInDialog(ho),
                  icon: const Icon(Icons.key, size: 13, color: AppColors.accentGreen),
                  label: Text(
                    ho.isVacant
                        ? 'Yeni Kiracı / Sakin Girişi'
                        : isTenant
                            ? 'Yeni Kiracı Girişi (Move-In)'
                            : 'Kiracı Tanımla (Move-In)',
                    style: const TextStyle(fontSize: 11),
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
                  onPressed: () => _showUnitOccupancyHistoryDialog(ho),
                  icon: const Icon(Icons.history, size: 13, color: AppColors.accentCyan),
                  label: const Text('Daire Tarihçesi', style: TextStyle(fontSize: 11)),
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
                  onPressed: () => _showVirtualIbanDetailsDialog(ho),
                  icon: const Icon(Icons.account_balance, size: 13, color: AppColors.accentPurple),
                  label: const Text('Sanal IBAN', style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accentPurple,
                    side: const BorderSide(color: AppColors.accentPurple),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 30),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                )),
                testId('transfer_ownership_${ho.unitId}', OutlinedButton.icon(
                  key: Key('transfer_ownership_${ho.unitId}'),
                  onPressed: () => _showTransferOwnershipDialog(ho),
                  icon: const Icon(Icons.real_estate_agent, size: 13, color: Colors.teal),
                  label: const Text('Mülk Devri', style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.teal,
                    side: const BorderSide(color: Colors.teal),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 30),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                )),
                testId('module_delete_ho_${ho.unitId}', OutlinedButton.icon(
                  key: Key('module_delete_ho_${ho.unitId}'),
                  onPressed: () => _confirmDeleteHomeOwner(ho),
                  icon: const Icon(Icons.delete_outline, size: 13, color: AppColors.accentRed),
                  label: const Text('Sil', style: TextStyle(fontSize: 11)),
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
                      );
                      if (ok && ctx.mounted) {
                        Navigator.pop(ctx);
                        messenger.showSnackBar(
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
                    backgroundColor: AppColors.accentOrange,
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
                        messenger.showSnackBar(
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
                    backgroundColor: AppColors.accentGreen,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )),
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

  void _showAddHouseholdMemberDialog([HomeOwnerItem? ho]) {
    final effectiveBlock = ho?.block ?? (widget.controller.activeUnit.blok.isNotEmpty ? widget.controller.activeUnit.blok : 'A');
    final effectiveUnitNo = ho?.unitNo ?? (widget.controller.activeUnit.daireNo > 0 ? widget.controller.activeUnit.daireNo : 1);
    final effectiveUnitId = ho?.unitId ?? (widget.controller.activeUnit.id.isNotEmpty ? widget.controller.activeUnit.id : 'd-$effectiveUnitNo');

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
                  child: const Text('Vazgeç'),
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
                      : const Text('Kaydet', style: TextStyle(fontWeight: FontWeight.bold)),
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
                testId('edit_ho_delete_button', OutlinedButton.icon(
                  key: const Key('edit_ho_delete_button'),
                  onPressed: isSaving ? null : () => _confirmDeleteHomeOwner(resident, parentCtx: ctx),
                  icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.accentRed),
                  label: const Text('Sil', style: TextStyle(color: AppColors.accentRed, fontWeight: FontWeight.bold)),
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

                          try {
                            final messenger = ScaffoldMessenger.of(this.context);
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
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text('Sakin bilgileri başarıyla güncellendi.'),
                                  backgroundColor: AppColors.accentGreen,
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
                                        color: activeDialogTab == 0 ? AppColors.accentGreen : AppColors.textSecondary(context),
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
                                        color: activeDialogTab == 1 ? AppColors.accentCyan : AppColors.textSecondary(context),
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
                                                '${m.relationship}${m.phone.isNotEmpty ? ' • ${m.phone}' : ''}${m.email.isNotEmpty ? ' • ${m.email}' : ''}',
                                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                                          tooltip: 'Sil',
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
                                              '${m.relationship}${m.phone.isNotEmpty ? ' • ${m.phone}' : ''}${m.email.isNotEmpty ? ' • ${m.email}' : ''}',
                                              style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                                        tooltip: 'Sil',
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
                                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.accentGreen,
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

  Widget _buildDairemHouseholdCard() {
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.people_outline, color: AppColors.accentCyan, size: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Hane Sakinleri (${widget.controller.activeUnit.blok} Blok D:${widget.controller.activeUnit.daireNo})',
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
              ),
              if (isHomeUser)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    testId('btn_manual_add_resident', ElevatedButton.icon(
                      key: const Key('btn_manual_add_resident'),
                      onPressed: () => _showAddHouseholdMemberDialog(),
                      icon: const Icon(Icons.person_add_alt_1, size: 13, color: Colors.white),
                      label: const Text(
                        'Sakin Ekle',
                        style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
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
                      label: const Text(
                        'Davet Linki',
                        style: TextStyle(color: AppColors.accentOrange, fontSize: 11),
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
                    style: TextStyle(color: AppColors.textSecondary(context).withValues(alpha: 0.8), fontSize: 11),
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
                            r.relationship,
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                          ),
                          if (r.phone.isNotEmpty || r.email.isNotEmpty)
                            Text(
                              [if (r.phone.isNotEmpty) r.phone, if (r.email.isNotEmpty) r.email].join(' • '),
                              style: TextStyle(color: AppColors.textSecondary(context).withValues(alpha: 0.7), fontSize: 10),
                            ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
                      ],
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  void _confirmDeleteHouseholdResident(UnitResidentMember member) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Hane Sakinini Sil', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        content: Text('${member.fullName} kişisini hane sakinlerinden kaldırmak istediğinize emin misiniz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Vazgeç'),
          ),
          testId('btn_confirm_delete_resident', ElevatedButton(
            key: const Key('btn_confirm_delete_resident'),
            onPressed: () async {
              Navigator.pop(ctx);
              final success = await widget.controller.deleteHouseholdMember(residentId: member.id);
              if (success && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Hane sakini başarıyla kaldırıldı.'),
                    backgroundColor: AppColors.accentGreen,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentRed),
            child: const Text('Sil', style: TextStyle(color: Colors.white)),
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
                      testId('penalty_days', Text('• Gecikme Durumu: ${dues.gecikenGunSayisi} Gün Gecikme', style: const TextStyle(color: AppColors.accentRed, fontSize: 13, fontWeight: FontWeight.w500))),
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
                          '• Gecikme Tazminatı: (${dues.anaPara.toStringAsFixed(0)} * 0.05 / 30) * ${dues.gecikenGunSayisi} = ₺${dues.gecikmeTazminati.toStringAsFixed(2)}',
                          style: const TextStyle(color: AppColors.accentRed, fontWeight: FontWeight.bold, fontSize: 12.5),
                        )),
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
                    testId('home_receipt_amount', Text(
                      tx.amountStr,
                      style: const TextStyle(
                        color: AppColors.accentGreen,
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
              testId('home_receipt_number', _buildReceiptRow('İşlem / Makbuz No:', tx.id)),
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
            testId('btn_copy_invite_link', OutlinedButton(
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
            )),
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
                backgroundColor: AppColors.accentGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Tamam', style: TextStyle(fontWeight: FontWeight.bold)),
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
                style: const TextStyle(color: AppColors.accentGreen, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
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
                backgroundColor: AppColors.accentCyan,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Tamam', style: TextStyle(fontWeight: FontWeight.bold)),
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
                style: const TextStyle(color: AppColors.accentCyan, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
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
                backgroundColor: AppColors.accentGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Tamam', style: TextStyle(fontWeight: FontWeight.bold)),
            )),
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

    // Tenant controllers when role == 'OWNER' and owner does not reside (isResidentOwner == false && rented)
    final tenantNameCtrl = TextEditingController();
    final tenantEmailCtrl = TextEditingController();
    final tenantPhoneCtrl = TextEditingController();

    // Dynamic co-residents (Hane Sakinleri)
    final pendingResidents = <_PendingResidentEntry>[];

    // Default to first house type if available (e.g. 2+1 or 3+1)
    final houseTypes = widget.controller.houseTypes;
    String? selectedHouseType = houseTypes.isNotEmpty ? houseTypes.first.typeName : '2+1';
    String selectedRole = 'OWNER';
    bool isResidentOwner = true;
    String ownerNotResidentOccupancy = 'VACANT'; // 'VACANT' or 'TENANT'
    String selectedRelationship = 'Eşi';
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
                  child: Text('İptal', style: TextStyle(color: AppColors.textSecondary(context), fontWeight: FontWeight.w600)),
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
                        duesAmount: currentTariff?.duesAmount ?? Decimal.zero,
                        isResident: isResidentOwner,
                        role: isRented ? 'TENANT' : selectedRole,
                      );
                    }

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
                            phone: res.phoneCtrl.text.trim().isNotEmpty ? res.phoneCtrl.text.trim() : phoneText,
                            email: res.emailCtrl.text.trim().isNotEmpty ? res.emailCtrl.text.trim() : 'sakin_$parsedUnit@example.com',
                            relationship: res.relationship,
                          );
                        }
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentGreen,
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
                              child: testId('add_resident_block_dropdown', DropdownButtonFormField<String>(
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
                              child: testId('add_resident_unit_field', TextField(
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
                              )),
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
                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                                      '✓ Malik Oturuyor: Kat maliki bu dairede bizzat ikamet etmektedir. Bu daire için ayrıca kiracı tanımlanamaz.',
                                      style: TextStyle(color: AppColors.accentGreen, fontSize: 11, fontWeight: FontWeight.bold),
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
                                          style: TextStyle(color: AppColors.textPrimary(context), fontSize: 11, fontWeight: FontWeight.w600),
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
                              label: const Text('+ Hane Sakini Ekle', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.accentCyan)),
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
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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

  Future<void> _showManageHouseTypesDialog() async {
    await showManageHouseTypesFullscreen(context, widget.controller);
  }

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
                  child: const Text('Vazgeç'),
                ),
                testId('module_confirm_transfer_ownership_btn', ElevatedButton(
                  key: const Key('module_confirm_transfer_ownership_btn'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          final newName = nameCtrl.text.trim();
                          if (newName.isEmpty) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(content: Text('Lütfen yeni malikin adını ve soyadını giriniz.')),
                            );
                            return;
                          }
                          setDlgState(() => isSubmitting = true);
                          try {
                            final messenger = ScaffoldMessenger.of(this.context);
                            final res = await widget.controller.transferUnitOwnership(
                              unitId: ho.unitId,
                              newOwnerName: newName,
                              newOwnerPhone: phoneCtrl.text.trim(),
                              newOwnerEmail: emailCtrl.text.trim(),
                              notes: notesCtrl.text.trim(),
                            );
                            if (res != null && ctx.mounted) {
                              Navigator.pop(ctx);
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(res['message']?.toString() ?? 'Mülk tapu devri başarıyla tamamlandı.'),
                                  backgroundColor: Colors.teal,
                                ),
                              );
                            }
                          } catch (e) {
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(content: Text('Hata: $e'), backgroundColor: Colors.redAccent),
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
                            const Icon(Icons.info_outline, color: Colors.teal, size: 20),
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
                          style: TextStyle(color: AppColors.textSecondary(ctx), fontSize: 11, height: 1.4),
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
                child: Text('İptal', style: TextStyle(color: AppColors.textSecondary(context), fontWeight: FontWeight.w600)),
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
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('$siteName sitesi başarıyla veritabanına kaydedildi.'),
                                  backgroundColor: AppColors.accentGreen,
                                ),
                              );
                            }
                          } else {
                            setDialogState(() {
                              isSaving = false;
                              localError = widget.controller.authMessage ?? 'Site kaydedilemedi. Lütfen bilgileri kontrol ediniz.';
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
                  backgroundColor: AppColors.accentCyan,
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
                    border: Border.all(color: Colors.redAccent),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          localError!,
                          style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600),
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
                  helperStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                  helperStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                child: Text('İptal', style: TextStyle(color: AppColors.textSecondary(context), fontWeight: FontWeight.w600)),
              ),
              testId('btn_save_site_edit', ElevatedButton(
                key: const Key('btn_save_site_edit'),
                onPressed: () async {
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
                  backgroundColor: AppColors.accentGreen,
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
                  helperStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
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
                  backgroundColor: AppColors.accentCyan,
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

  Widget _buildMustChangePasswordBanner() {
    return testId('banner_must_change_password', Container(
      key: const Key('banner_must_change_password'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFD97706).withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD97706).withOpacity(0.8), width: 1.5),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Geçici Şifre İle Giriş Yapıldı',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFD97706), fontSize: 13),
                ),
                Text(
                  'Hesap güvenliğiniz için lütfen yeni bir kalıcı şifre belirleyiniz.',
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          testId('btn_open_change_password', ElevatedButton(
            key: const Key('btn_open_change_password'),
            onPressed: _showChangePasswordDialog,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD97706),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Şifre Değiştir', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
          )),
        ],
      ),
    ));
  }

  void _showChangePasswordDialog() {
    final currentPassCtrl = TextEditingController();
    final newPassCtrl = TextEditingController();
    final confirmPassCtrl = TextEditingController();
    bool isSubmitting = false;
    String? localError;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AppFullscreenPage(
          title: 'Şifre Değiştir',
          subtitle: '${widget.controller.userSession.fullName} (${widget.controller.userSession.email})',
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.accentCyan.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.password, color: AppColors.accentCyan, size: 20),
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
              testId('btn_submit_change_password', ElevatedButton(
                onPressed: isSubmitting
                    ? null
                    : () async {
                        final cur = currentPassCtrl.text.trim();
                        final n1 = newPassCtrl.text.trim();
                        final n2 = confirmPassCtrl.text.trim();
                        if (cur.isEmpty || n1.isEmpty || n2.isEmpty) {
                          setDialogState(() => localError = 'Lütfen tüm alanları eksiksiz doldurunuz.');
                          return;
                        }
                        if (n1 != n2) {
                          setDialogState(() => localError = 'Yeni şifreler birbiriyle uyuşmuyor.');
                          return;
                        }
                        if (n1.length < 10) {
                          setDialogState(() => localError = 'Yeni şifre en az 10 karakter olmalıdır.');
                          return;
                        }
                        setDialogState(() {
                          isSubmitting = true;
                          localError = null;
                        });
                        try {
                          final messenger = ScaffoldMessenger.of(this.context);
                          final ok = await widget.controller.changePassword(
                            email: widget.controller.userSession.email,
                            currentPassword: cur,
                            newPassword: n1,
                          );
                          if (ok && ctx.mounted) {
                            Navigator.pop(ctx);
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('Şifreniz başarıyla güncellendi.'),
                                backgroundColor: Colors.green,
                              ),
                            );
                            if (mounted) setState(() {});
                          } else if (ctx.mounted) {
                            setDialogState(() {
                              isSubmitting = false;
                              localError = widget.controller.authMessage ?? 'Şifre güncellenemedi.';
                            });
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            setDialogState(() {
                              isSubmitting = false;
                              localError = 'Beklenmeyen hata: $e';
                            });
                          }
                        } finally {
                          if (ctx.mounted && isSubmitting) {
                            setDialogState(() => isSubmitting = false);
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentCyan,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(isSubmitting ? 'Kaydediliyor...' : 'Şifreyi Güncelle', style: const TextStyle(fontWeight: FontWeight.bold)),
              )),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (localError != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.redAccent),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.redAccent, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(localError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ],
              Text('E-posta:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.card(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Text(
                  widget.controller.userSession.email,
                  style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
              const SizedBox(height: 14),
              testId('change_password_current', TextField(
                controller: currentPassCtrl,
                obscureText: true,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Mevcut (veya Geçici) Şifre',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
              const SizedBox(height: 12),
              testId('change_password_new', TextField(
                controller: newPassCtrl,
                obscureText: true,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Yeni Kalıcı Şifre (En az 6 karakter)',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              )),
              const SizedBox(height: 12),
              testId('change_password_confirm', TextField(
                controller: confirmPassCtrl,
                obscureText: true,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Yeni Şifre Tekrar',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
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
    this.relationship = 'Eşi',
  })  : nameCtrl = TextEditingController(text: name ?? ''),
        phoneCtrl = TextEditingController(text: phone ?? ''),
        emailCtrl = TextEditingController(text: email ?? '');

  void dispose() {
    nameCtrl.dispose();
    phoneCtrl.dispose();
    emailCtrl.dispose();
  }
}

