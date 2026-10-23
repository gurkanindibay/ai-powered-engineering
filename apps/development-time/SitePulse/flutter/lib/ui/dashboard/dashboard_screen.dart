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
        final matchUnit = ho.unitNo.toString().contains(q);
        final matchPhone = ho.phone.toLowerCase().contains(q);
        final matchEmail = ho.email.toLowerCase().contains(q);
        final matchBlock = ho.block.toLowerCase().contains(q);
        return matchName || matchUnit || matchPhone || matchEmail || matchBlock;
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
    final badgeLabel = cleanBlock.isNotEmpty ? '$cleanBlock${ho.unitNo}' : '${ho.unitNo}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(16),
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
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    badgeLabel,
                    style: const TextStyle(
                      color: AppColors.accentCyan,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
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
                            ho.ownerFullName,
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: (ho.isResident ? AppColors.accentGreen : AppColors.accentOrange).withOpacity(0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            ho.isResident ? 'Sakin' : 'Malik',
                            style: TextStyle(
                              color: ho.isResident ? AppColors.accentGreen : AppColors.accentOrange,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${ho.block} D:${ho.unitNo} • Kat ${ho.floor}${ho.houseType != null && ho.houseType!.isNotEmpty ? ' • ${ho.houseType}' : ''}',
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                    ),
                  ],
                ),
              ),
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
                    'Aidat',
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 10),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.phone_outlined, size: 13, color: AppColors.textSecondary(context)),
                        const SizedBox(width: 4),
                        Text(
                          ho.phone.isNotEmpty ? ho.phone : 'Telefon girilmemiş',
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.email_outlined, size: 13, color: AppColors.textSecondary(context)),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            ho.email.isNotEmpty ? ho.email : 'E-posta girilmemiş',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _showEditHomeOwnerDialog(ho),
                icon: const Icon(Icons.edit_outlined, size: 14),
                label: const Text('Düzenle', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accentCyan,
                  side: const BorderSide(color: AppColors.accentCyan),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showEditHomeOwnerDialog(HomeOwnerItem resident) {
    final nameCtrl = TextEditingController(text: resident.ownerFullName);
    final emailCtrl = TextEditingController(text: resident.email);
    final phoneCtrl = TextEditingController(text: resident.phone);
    final duesCtrl = TextEditingController(text: resident.monthlyDues.toStringAsFixed(2));
    final landShareCtrl = TextEditingController(text: resident.landShare);

    final houseTypes = widget.controller.houseTypes;
    String? selectedHouseType = resident.houseType;
    if (selectedHouseType == null && houseTypes.isNotEmpty) {
      selectedHouseType = houseTypes.first.typeName;
    }
    bool isResident = resident.isResident;

    String? nameError;
    String? emailError;
    String? phoneError;
    String? generalError;
    bool isSaving = false;

    AppFullscreenPage.push(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AppFullscreenPage(
            title: 'Sakin Bilgilerini Düzenle',
            subtitle: '${resident.block} Daire ${resident.unitNo}',
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
                          final name = nameCtrl.text.trim();
                          final email = emailCtrl.text.trim();
                          final phone = phoneCtrl.text.trim();

                          bool hasError = false;
                          String? newNameErr;
                          String? newEmailErr;
                          String? newPhoneErr;

                          if (name.isEmpty) {
                            newNameErr = 'Ad Soyad zorunludur.';
                            hasError = true;
                          }

                          if (email.isEmpty) {
                            newEmailErr = 'E-posta zorunludur.';
                            hasError = true;
                          } else {
                            final emailRegex = RegExp(r'^[\w\.-]+@[\w\.-]+\.\w{2,}$');
                            if (!emailRegex.hasMatch(email)) {
                              newEmailErr = 'Geçerli bir e-posta adresi giriniz (ör. ad@site.com).';
                              hasError = true;
                            }
                          }

                          if (phone.isEmpty) {
                            newPhoneErr = 'Telefon numarası zorunludur.';
                            hasError = true;
                          } else {
                            final digitsOnly = phone.replaceAll(RegExp(r'\D'), '');
                            if (digitsOnly.length < 10 || digitsOnly.length > 11) {
                              newPhoneErr = 'Geçerli bir telefon numarası giriniz (10-11 hane).';
                              hasError = true;
                            }
                          }

                          if (hasError) {
                            setDialogState(() {
                              nameError = newNameErr;
                              emailError = newEmailErr;
                              phoneError = newPhoneErr;
                            });
                            return;
                          }

                          setDialogState(() {
                            isSaving = true;
                            generalError = null;
                          });

                          final dues = Decimal.tryParse(duesCtrl.text.replaceAll(',', '.')) ?? resident.monthlyDues;
                          final success = await widget.controller.updateHomeOwner(
                            unitId: resident.unitId,
                            fullName: name,
                            email: email,
                            phone: phone,
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
                              'Kat: ${resident.floor} • Arsa Payı: ${resident.landShare}',
                              style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Full Name
                  Text('Ad Soyad *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      hintText: 'Örn: Murat Demir',
                      errorText: nameError,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),

                  const SizedBox(height: 14),

                  // Phone
                  Text('Telefon Numarası *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      hintText: 'Örn: 0555 123 4567',
                      errorText: phoneError,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),

                  const SizedBox(height: 14),

                  // Email
                  Text('E-posta Adresi *', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      hintText: 'Örn: murat@example.com',
                      errorText: emailError,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),

                  const SizedBox(height: 14),

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

                  // Monthly Dues
                  Text('Aylık Aidat Tutarı (₺)', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: duesCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      hintText: '1000.00',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),

                  const SizedBox(height: 14),

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

    // Default to first house type if available (e.g. 2+1 or 3+1)
    final houseTypes = widget.controller.houseTypes;
    String? selectedHouseType = houseTypes.isNotEmpty ? houseTypes.first.typeName : null;
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
            subtitle: 'Siteye bağımsız bölüm ve malik kaydı (Konut tipine göre aidat)',
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentGreen.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.person_add_alt_1, color: AppColors.accentGreen, size: 20),
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

                    Navigator.pop(ctx);
                    widget.controller.registerHomeOwner(
                      block: selectedBlock!,
                      unitNo: parsedUnit,
                      ownerName: ownerName,
                      email: emailText,
                      phone: phoneText,
                      houseType: selectedHouseType,
                      duesAmount: currentTariff?.duesAmount ?? Decimal.zero,
                    );
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
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: const Key('add_resident_block_dropdown'),
                        value: currentBlocks.contains(selectedBlock) ? selectedBlock : (currentBlocks.isNotEmpty ? currentBlocks.first : null),
                        dropdownColor: AppColors.card(context),
                        style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Blok Seçiniz',
                          labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                          filled: true,
                          fillColor: AppColors.card(context),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          prefixIcon: const Icon(Icons.apartment, size: 20, color: AppColors.accentCyan),
                        ),
                        items: currentBlocks.map((b) {
                          return DropdownMenuItem<String>(
                            value: b,
                            child: Text(b, style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.w600)),
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
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Yeni Blok Tanımla',
                      icon: const Icon(Icons.add_circle, color: AppColors.accentCyan),
                      onPressed: () {
                        final newBlockCtrl = TextEditingController();
                        showDialog(
                          context: context,
                          builder: (dCtx) => AlertDialog(
                            backgroundColor: AppColors.card(context),
                            title: Text('Yeni Blok Tanımla', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16)),
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
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: unitCtrl,
                  keyboardType: TextInputType.number,
                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Daire No',
                    labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                    filled: true,
                    fillColor: AppColors.card(context),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Ad Soyad',
                    labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                    filled: true,
                    fillColor: AppColors.card(context),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'E-posta (Doğrulama zorunlu)',
                    errorText: emailError,
                    labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                    filled: true,
                    fillColor: AppColors.card(context),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Telefon (Doğrulama zorunlu)',
                    errorText: phoneError,
                    labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                    filled: true,
                    fillColor: AppColors.card(context),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
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
                          Row(
                            children: [
                              const Icon(Icons.home_work_outlined, size: 18, color: AppColors.accentCyan),
                              const SizedBox(width: 6),
                              Text(
                                'Konut Tipi (Daire Tipi)',
                                style: TextStyle(
                                  color: AppColors.textPrimary(context),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          TextButton(
                            onPressed: () async {
                              await _showManageHouseTypesDialog();
                              setDialogState(() {});
                            },
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(50, 24),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text(
                              '+ Tarifeleri Yönet',
                              style: TextStyle(color: AppColors.accentPurple, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        value: currentHouseTypes.any((t) => t.typeName == selectedHouseType)
                            ? selectedHouseType
                            : (currentHouseTypes.isNotEmpty ? currentHouseTypes.first.typeName : null),
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
                                    color: AppColors.textPrimary(context),
                                  ),
                                ),
                                Text(
                                  '₺${ht.duesAmount} / ay',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
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
                        decoration: InputDecoration(
                          hintText: 'Konut tipi seçiniz',
                          hintStyle: TextStyle(color: AppColors.textSecondary(context)),
                          filled: true,
                          fillColor: AppColors.surface(context),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.accentCyan.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.accentCyan.withValues(alpha: 0.2)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline, size: 16, color: AppColors.accentCyan),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                currentTariff != null
                                    ? 'Aylık Aidat: ₺${currentTariff.duesAmount} (${currentTariff.typeName} tarifesine göre otomatik tahakkuk edilir).'
                                    : 'Aylık aidat, seçtiğiniz konut tipinin tarifesine göre sisteme otomatik işlenir.',
                                style: TextStyle(
                                  color: AppColors.textPrimary(context),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
