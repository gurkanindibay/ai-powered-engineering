import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../domain/models/auth_models.dart';
import '../../domain/models/dues_models.dart';
import '../components/hero_balance_card.dart';
import '../components/manager_cockpit_view.dart';
import '../components/profile_role_sheet.dart';
import '../components/resident_actions_row.dart';
import '../components/saas_admin_view.dart';
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

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerUpdate);
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
                color: AppColors.accentCyan.withOpacity(0.15),
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: _buildCurrentTabContent(isHomeRole),
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          border: Border(top: BorderSide(color: AppColors.border(context), width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: _selectedTabIndex,
          onTap: (index) {
            if (index == 2) {
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
        ),
      ),
    );
  }

  Widget _buildCurrentTabContent(bool isHomeRole) {
    if (_selectedTabIndex == 1) {
      return _buildSecondaryTabContent(isHomeRole);
    }

    // Tab 0: Main Screen according to Role
    switch (widget.controller.userRole) {
      case UserRole.homeOwner:
      case UserRole.homeResident:
        final dues = widget.controller.primaryDues;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (dues != null)
              HeroBalanceCard(
                dues: dues,
                siteName: widget.controller.activeDaire.siteAdi,
                unitName: '${widget.controller.activeDaire.blok} Blok D:${widget.controller.activeDaire.daireNo}',
                isOffline: widget.controller.isOffline,
                onPayPressed: () => _showPaymentDialog(dues),
                onDetailPressed: () => _showDuesDetailDialog(dues),
              ),
            const SizedBox(height: 16),
            ResidentActionsRow(
              isOwner: widget.controller.userRole == UserRole.homeOwner,
              onPayTap: () {
                if (dues != null) _showPaymentDialog(dues);
              },
              onIbanTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Sanal IBAN bilgisi aşağıda yer almaktadır.'),
                    backgroundColor: AppColors.accentCyan,
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              onReceiptsTap: _showReceiptsDialog,
              onInviteTap: () {
                widget.controller.generateUnitInviteLink();
              },
            ),
            const SizedBox(height: 18),
            _buildHesapHareketleriSection(),
            const SizedBox(height: 18),
            VirtualIbanCard(
              unitDesc: '${widget.controller.activeDaire.blok} Blok D:${widget.controller.activeDaire.daireNo}',
            ),
            const SizedBox(height: 16),
            _buildDairemHouseholdCard(),
          ],
        );
      case UserRole.siteManager:
        return ManagerCockpitView(
          controller: widget.controller,
          onAddResidentTap: _showAddResidentDialog,
        );
      case UserRole.saasAdmin:
        return SaasAdminView(
          controller: widget.controller,
          onAddSiteTap: _showAddSiteDialog,
          onDeleteSiteTap: _confirmDeleteSite,
        );
    }
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
            unitDesc: '${widget.controller.activeDaire.blok} Blok D:${widget.controller.activeDaire.daireNo}',
          ),
        ],
      );
    } else if (widget.controller.userRole == UserRole.siteManager) {
      return ManagerCockpitView(
        controller: widget.controller,
        onAddResidentTap: _showAddResidentDialog,
      );
    } else {
      return SaasAdminView(
        controller: widget.controller,
        onAddSiteTap: _showAddSiteDialog,
        onDeleteSiteTap: _confirmDeleteSite,
      );
    }
  }

  Widget _buildHesapHareketleriSection() {
    final transactions = [
      {
        'title': 'Eylül 2026 Aidatı',
        'subtitle': 'Sanal IBAN ile FAST',
        'amount': '₺1.423,33',
        'date': 'Bugün 14:15',
        'isCredit': false,
        'icon': Icons.apartment,
        'color': const Color(0xFFEF4444),
      },
      {
        'title': 'Ağustos 2026 Aidatı',
        'subtitle': 'Kredi Kartı ile Ödendi',
        'amount': '₺1.400,00',
        'date': '15.08.2026 10:20',
        'isCredit': true,
        'icon': Icons.check_circle_outline,
        'color': const Color(0xFF10B981),
      },
      {
        'title': 'Demirbaş Katılım Payı',
        'subtitle': 'Yönetim Hesabına Transfer',
        'amount': '₺500,00',
        'date': '02.08.2026 16:45',
        'isCredit': true,
        'icon': Icons.build_circle_outlined,
        'color': const Color(0xFF10B981),
      },
    ];

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
          child: Column(
            children: transactions.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;
              final color = item['color'] as Color;

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            item['icon'] as IconData,
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
                                item['title'] as String,
                                style: TextStyle(
                                  color: AppColors.textPrimary(context),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item['subtitle'] as String,
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
                              item['amount'] as String,
                              style: TextStyle(
                                color: (item['isCredit'] as bool)
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFFEF4444),
                                fontSize: 13.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item['date'] as String,
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
    final isOwner = widget.controller.userRole == UserRole.homeOwner;

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
                    'Hane Sakinleri (A Blok D:14)',
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
                            ? AppColors.accentCyan.withOpacity(0.15)
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ProfileRoleSheet(controller: widget.controller),
    );
  }

  void _showPaymentDialog(AidatBorcu dues) {
    final cardNumberCtrl = TextEditingController(text: '5428 •••• •••• 9012');
    final expiryCtrl = TextEditingController(text: '12/28');
    final cvvCtrl = TextEditingController(text: '884');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.credit_card, color: AppColors.accentCyan),
            const SizedBox(width: 8),
            Text('Online Aidat Ödeme', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.card(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Dönem Borcu (Ana Para)', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                      Text('₺${dues.anaPara.toStringAsFixed(2)}', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('KMK %5 Kanuni Gecikme', style: TextStyle(color: AppColors.accentRed, fontSize: 12)),
                      Text('+₺${dues.gecikmeTazminati.toStringAsFixed(2)}', style: const TextStyle(color: AppColors.accentRed, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Divider(color: AppColors.border(context), height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Toplam Tutar', style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold, fontSize: 14)),
                      Text('₺${dues.toplamTutar.toStringAsFixed(2)}', style: const TextStyle(color: AppColors.accentCyan, fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: cardNumberCtrl,
              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Kart Numarası',
                labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                filled: true,
                fillColor: AppColors.card(context),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: expiryCtrl,
                    style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'SKT (AA/YY)',
                      labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                      filled: true,
                      fillColor: AppColors.card(context),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: cvvCtrl,
                    obscureText: true,
                    style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'CVV',
                      labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                      filled: true,
                      fillColor: AppColors.card(context),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('İptal', style: TextStyle(color: AppColors.textSecondary(context))),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('₺${dues.toplamTutar.toStringAsFixed(2)} tutarındaki ödeme başarıyla alındı! Makbuz üretildi.'),
                  backgroundColor: AppColors.accentGreen,
                  duration: const Duration(seconds: 4),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentCyan,
              foregroundColor: Colors.white,
            ),
            child: Text('3D Secure ile ₺${dues.toplamTutar.toStringAsFixed(2)} Öde'),
          ),
        ],
      ),
    );
  }

  void _showDuesDetailDialog(AidatBorcu dues) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Aidat Hesap Özeti', style: TextStyle(color: AppColors.textPrimary(context))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Kat Mülkiyeti Kanunu (KMK) Madde 20 Uyarınca:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
            const SizedBox(height: 8),
            Text('• Son Ödeme Tarihi: 15.09.2026', style: TextStyle(color: AppColors.textPrimary(context))),
            const Text('• Hesaplama Tarihi: 25.09.2026 (10 Gün Gecikme)', style: TextStyle(color: AppColors.accentRed)),
            Text('• Aylık Yasal Gecikme Oranı: %5', style: TextStyle(color: AppColors.textPrimary(context))),
            const Text('• Gecikme Tazminatı: (1400 * 0.05 / 30) * 10 = 23,33 TL', style: TextStyle(color: AppColors.accentRed, fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Kapat'),
          ),
        ],
      ),
    );
  }

  void _showReceiptsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.receipt_long, color: AppColors.accentCyan),
            const SizedBox(width: 8),
            Text('Ödeme Makbuzları', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildReceiptItem('Ağustos 2026 Aidatı', '₺1.400,00', '14.08.2026 • FAST Onaylı'),
            const SizedBox(height: 8),
            _buildReceiptItem('Temmuz 2026 Aidatı', '₺1.400,00', '12.07.2026 • Kredi Kartı'),
            const SizedBox(height: 8),
            _buildReceiptItem('Haziran 2026 Aidatı', '₺1.400,00', '15.06.2026 • FAST Onaylı'),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptItem(String title, String amount, String meta) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: AppColors.textPrimary(context), fontSize: 12, fontWeight: FontWeight.w600)),
              Text(meta, style: TextStyle(color: AppColors.textSecondary(context), fontSize: 10)),
            ],
          ),
          Text(amount, style: const TextStyle(color: AppColors.accentGreen, fontSize: 13, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  void _showInviteDialog(UnitInviteInfo invite) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.share, color: AppColors.accentOrange),
            const SizedBox(width: 8),
            Text('Hane Sakini Davet Linki', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Kapsam: ${invite.unitLabel} • ${invite.expiresAtStr}', style: const TextStyle(color: AppColors.accentCyan, fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.card(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border(context)),
              ),
              child: SelectableText(
                invite.inviteUrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 10),
            Text(invite.securityNotice, style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: invite.inviteUrl));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Davet linki kopyalandı!'), backgroundColor: AppColors.accentGreen),
              );
            },
            child: const Text('Linki Kopyala', style: TextStyle(color: AppColors.accentCyan)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Kapat'),
          ),
        ],
      ),
    );
  }

  void _showApprovalSuccessDialog(ApprovalSuccessInfo info) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.check_circle, color: AppColors.accentGreen),
            const SizedBox(width: 8),
            Text('Başvuru Onaylandı!', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${info.fullName} (${info.flatDesc}) başvurusu onaylandı.', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13)),
            const SizedBox(height: 12),
            Text('Üretilen Geçici Sakin Şifresi:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.card(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.accentGreen),
              ),
              child: SelectableText(
                info.temporaryPassword,
                style: const TextStyle(color: AppColors.accentGreen, fontSize: 15, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 8),
            Text('Şifre ve giriş linki ${info.email} adresine SMS ve e-posta olarak iletildi.', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11)),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }

  void _showSiteProvisionedDialog(ProvisionedSiteCredentials creds) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.apartment, color: AppColors.accentCyan),
            const SizedBox(width: 8),
            Text('Yeni Site & Yönetici Hazır!', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${creds.siteName} başarıyla platforma kaydedildi.', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13)),
            const SizedBox(height: 10),
            Text('Yönetici: ${creds.adminName} (${creds.adminEmail})', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
            const SizedBox(height: 8),
            Text('Geçici Yönetim Şifresi:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.card(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.accentCyan),
              ),
              child: SelectableText(
                creds.temporaryPassword,
                style: const TextStyle(color: AppColors.accentCyan, fontSize: 15, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }

  void _showHomeOwnerProvisionedDialog(ProvisionedHomeOwnerCredentials creds) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.person_add, color: AppColors.accentGreen),
            const SizedBox(width: 8),
            Text('Sakin Kaydedildi!', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${creds.ownerName} (${creds.block} D:${creds.unitNo}) başarıyla eklendi.', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13)),
            const SizedBox(height: 10),
            Text('Üretilen Geçici Şifre:', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.card(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.accentGreen),
              ),
              child: SelectableText(
                creds.temporaryPassword,
                style: const TextStyle(color: AppColors.accentGreen, fontSize: 15, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }

  void _showAddResidentDialog() {
    final blockCtrl = TextEditingController(text: 'B Blok');
    final unitCtrl = TextEditingController(text: '20');
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final duesCtrl = TextEditingController(text: '1400.00');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Yeni Daire / Sakin Ekle', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: blockCtrl,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Blok (örn: A Blok)',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 8),
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
              const SizedBox(height: 8),
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
              const SizedBox(height: 8),
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'E-posta',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Telefon',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.card(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 8),
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
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('İptal', style: TextStyle(color: AppColors.textSecondary(context))),
          ),
          ElevatedButton(
            onPressed: () {
              final ownerName = nameCtrl.text.trim();
              final unitText = unitCtrl.text.trim();
              if (ownerName.isEmpty || unitText.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Lütfen Sakin Ad Soyad ve Daire No alanlarını doldurunuz.'),
                    backgroundColor: Colors.redAccent,
                  ),
                );
                return;
              }
              Navigator.pop(ctx);
              widget.controller.registerHomeOwner(
                block: blockCtrl.text.trim(),
                unitNo: int.tryParse(unitText) ?? 1,
                ownerName: ownerName,
                email: emailCtrl.text.trim(),
                phone: phoneCtrl.text.trim(),
                duesAmount: Decimal.tryParse(duesCtrl.text.trim()) ?? Decimal.parse('1400.00'),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentGreen, foregroundColor: Colors.white),
            child: const Text('Kaydet & Şifre Üret'),
          ),
        ],
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

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Yeni Site / Kompleks Kaydet', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              const SizedBox(height: 8),
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
              const SizedBox(height: 8),
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
              const SizedBox(height: 8),
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
              const SizedBox(height: 8),
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
              const SizedBox(height: 8),
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('İptal', style: TextStyle(color: AppColors.textSecondary(context))),
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
              Navigator.pop(ctx);
              widget.controller.registerNewSite(
                name: siteName,
                city: cityCtrl.text.trim().isEmpty ? 'İstanbul' : cityCtrl.text.trim(),
                address: addressCtrl.text.trim(),
                adminName: adminName,
                adminEmail: adminEmailCtrl.text.trim().isEmpty ? 'yonetici@sitepulse.internal' : adminEmailCtrl.text.trim(),
                adminPhone: adminPhoneCtrl.text.trim().isEmpty ? '+90 532 000 00 00' : adminPhoneCtrl.text.trim(),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentCyan, foregroundColor: Colors.white),
            child: const Text('Siteyi Kaydet & Yetkilendir'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteSite(TenantSiteItem site) {
    if (site.hasActions) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface(context),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
              const SizedBox(width: 8),
              Text('Site Silinemez', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16)),
            ],
          ),
          content: Text(
            '${site.name} sitesine ait aktif daireler (${site.totalUnits}) veya finansal tahsilat hareketleri bulunmaktadır. KMK mevzuatı ve veri bütünlüğü gereği işlem kaydı bulunan siteler silinemez.',
            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentCyan, foregroundColor: Colors.white),
              child: const Text('Anladım'),
            ),
          ],
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.delete_forever, color: Colors.redAccent),
            const SizedBox(width: 8),
            Text('Siteyi Sil', style: TextStyle(color: AppColors.textPrimary(context), fontSize: 16)),
          ],
        ),
        content: Text(
          '${site.name} sitesini platformdan tamamen silmek istediğinize emin misiniz?\n\nBu sitede henüz herhangi bir daire veya finansal hareket bulunmamaktadır. Bu işlem geri alınamaz.',
          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Vazgeç', style: TextStyle(color: AppColors.textSecondary(context))),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.controller.deleteSite(site.id);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${site.name} başarıyla silindi.'),
                  backgroundColor: AppColors.accentGreen,
                  duration: const Duration(seconds: 3),
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            child: const Text('Evet, Sil'),
          ),
        ],
      ),
    );
  }
}
