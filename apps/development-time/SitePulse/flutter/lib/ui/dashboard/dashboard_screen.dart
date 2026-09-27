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
      _showApprovalSuccessDialog(widget.controller.approvalSuccessInfo!);
      widget.controller.clearApprovalSuccess();
    }

    // Check for provisioned SaaS site credentials
    if (widget.controller.provisionedCredentials != null) {
      _showSiteProvisionedDialog(widget.controller.provisionedCredentials!);
      widget.controller.clearProvisionedCredentials();
    }

    // Check for provisioned Home Owner credentials
    if (widget.controller.provisionedHomeOwner != null) {
      _showHomeOwnerProvisionedDialog(widget.controller.provisionedHomeOwner!);
      widget.controller.clearProvisionedHomeOwner();
    }

    // Check for unit invite info
    if (widget.controller.unitInviteInfo != null) {
      _showInviteDialog(widget.controller.unitInviteInfo!);
      widget.controller.clearUnitInviteInfo();
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
            const Text(
              'SitePulse',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, letterSpacing: -0.5),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.darkCard,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.darkBorder),
              ),
              child: Text(
                session.role.displayName,
                style: const TextStyle(fontSize: 10, color: AppColors.darkTextSecondary),
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
              color: AppColors.darkTextSecondary,
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
        decoration: const BoxDecoration(
          color: AppColors.darkSurface,
          border: Border(top: BorderSide(color: AppColors.darkBorder, width: 1)),
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
          selectedItemColor: AppColors.accentCyan,
          unselectedItemColor: AppColors.darkTextSecondary,
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
            const SizedBox(height: 16),
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
        );
    }
  }

  Widget _buildSecondaryTabContent(bool isHomeRole) {
    if (isHomeRole) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Dairem & Hane Bilgileri',
            style: TextStyle(color: AppColors.darkTextPrimary, fontSize: 18, fontWeight: FontWeight.bold),
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
      );
    }
  }

  Widget _buildDairemHouseholdCard() {
    final residents = widget.controller.unitResidents;
    final isOwner = widget.controller.userRole == UserRole.homeOwner;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.darkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.people_outline, color: AppColors.accentCyan, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Hane Sakinleri (A Blok D:14)',
                    style: TextStyle(
                      color: AppColors.darkTextPrimary,
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
                  color: AppColors.darkBackground,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.darkBorder),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.fullName,
                          style: const TextStyle(
                            color: AppColors.darkTextPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          r.relationship,
                          style: const TextStyle(color: AppColors.darkTextSecondary, fontSize: 11),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: r.isOwner
                            ? AppColors.accentCyan.withOpacity(0.15)
                            : AppColors.darkSurface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        r.isOwner ? 'Malik' : 'Sakin',
                        style: TextStyle(
                          color: r.isOwner ? AppColors.accentCyan : AppColors.darkTextSecondary,
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
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.credit_card, color: AppColors.accentCyan),
            SizedBox(width: 8),
            Text('Online Aidat Ödeme', style: TextStyle(color: AppColors.darkTextPrimary, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.darkBackground,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.darkBorder),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Dönem Borcu (Ana Para)', style: TextStyle(color: AppColors.darkTextSecondary, fontSize: 12)),
                      Text('₺${dues.anaPara.toStringAsFixed(2)}', style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 12)),
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
                  const Divider(color: AppColors.darkBorder, height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Toplam Tutar', style: TextStyle(color: AppColors.darkTextPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
                      Text('₺${dues.toplamTutar.toStringAsFixed(2)}', style: const TextStyle(color: AppColors.accentCyan, fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: cardNumberCtrl,
              style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Kart Numarası',
                labelStyle: const TextStyle(color: AppColors.darkTextSecondary),
                filled: true,
                fillColor: AppColors.darkBackground,
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
                    style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'SKT (AA/YY)',
                      labelStyle: const TextStyle(color: AppColors.darkTextSecondary),
                      filled: true,
                      fillColor: AppColors.darkBackground,
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
                    style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'CVV',
                      labelStyle: const TextStyle(color: AppColors.darkTextSecondary),
                      filled: true,
                      fillColor: AppColors.darkBackground,
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
            child: const Text('İptal', style: TextStyle(color: AppColors.darkTextSecondary)),
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
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Aidat Hesap Özeti', style: TextStyle(color: AppColors.darkTextPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Kat Mülkiyeti Kanunu (KMK) Madde 20 Uyarınca:', style: TextStyle(color: AppColors.darkTextSecondary, fontSize: 12)),
            const SizedBox(height: 8),
            Text('• Son Ödeme Tarihi: 15.09.2026', style: TextStyle(color: AppColors.darkTextPrimary)),
            Text('• Hesaplama Tarihi: 25.09.2026 (10 Gün Gecikme)', style: TextStyle(color: AppColors.accentRed)),
            Text('• Aylık Yasal Gecikme Oranı: %5', style: TextStyle(color: AppColors.darkTextPrimary)),
            Text('• Gecikme Tazminatı: (1400 * 0.05 / 30) * 10 = 23,33 TL', style: TextStyle(color: AppColors.accentRed, fontWeight: FontWeight.bold)),
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
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.receipt_long, color: AppColors.accentCyan),
            SizedBox(width: 8),
            Text('Ödeme Makbuzları', style: TextStyle(color: AppColors.darkTextPrimary, fontSize: 16)),
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
        color: AppColors.darkBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.darkBorder),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
              Text(meta, style: const TextStyle(color: AppColors.darkTextSecondary, fontSize: 10)),
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
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.share, color: AppColors.accentOrange),
            SizedBox(width: 8),
            Text('Hane Sakini Davet Linki', style: TextStyle(color: AppColors.darkTextPrimary, fontSize: 16)),
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
                color: AppColors.darkBackground,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.darkBorder),
              ),
              child: SelectableText(
                invite.inviteUrl,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 10),
            Text(invite.securityNotice, style: const TextStyle(color: AppColors.darkTextSecondary, fontSize: 11)),
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
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: AppColors.accentGreen),
            SizedBox(width: 8),
            Text('Başvuru Onaylandı!', style: TextStyle(color: AppColors.darkTextPrimary, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${info.fullName} (${info.flatDesc}) başvurusu onaylandı.', style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13)),
            const SizedBox(height: 12),
            const Text('Üretilen Geçici Sakin Şifresi:', style: TextStyle(color: AppColors.darkTextSecondary, fontSize: 11)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.darkBackground,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.accentGreen),
              ),
              child: SelectableText(
                info.temporaryPassword,
                style: const TextStyle(color: AppColors.accentGreen, fontSize: 15, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 8),
            Text('Şifre ve giriş linki ${info.email} adresine SMS ve e-posta olarak iletildi.', style: const TextStyle(color: AppColors.darkTextSecondary, fontSize: 11)),
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
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.apartment, color: AppColors.accentCyan),
            SizedBox(width: 8),
            Text('Yeni Site & Yönetici Hazır!', style: TextStyle(color: AppColors.darkTextPrimary, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${creds.siteName} başarıyla platforma kaydedildi.', style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13)),
            const SizedBox(height: 10),
            Text('Yönetici: ${creds.adminName} (${creds.adminEmail})', style: const TextStyle(color: AppColors.darkTextSecondary, fontSize: 12)),
            const SizedBox(height: 8),
            const Text('Geçici Yönetim Şifresi:', style: TextStyle(color: AppColors.darkTextSecondary, fontSize: 11)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.darkBackground,
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
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.person_add, color: AppColors.accentGreen),
            SizedBox(width: 8),
            Text('Sakin Kaydedildi!', style: TextStyle(color: AppColors.darkTextPrimary, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${creds.ownerName} (${creds.block} D:${creds.unitNo}) başarıyla eklendi.', style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13)),
            const SizedBox(height: 10),
            const Text('Üretilen Geçici Şifre:', style: TextStyle(color: AppColors.darkTextSecondary, fontSize: 11)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.darkBackground,
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
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Yeni Daire / Sakin Ekle', style: TextStyle(color: AppColors.darkTextPrimary, fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: blockCtrl,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Blok (örn: A Blok)', filled: true, fillColor: AppColors.darkBackground),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: unitCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Daire No', filled: true, fillColor: AppColors.darkBackground),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Ad Soyad', filled: true, fillColor: AppColors.darkBackground),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: const InputDecoration(labelText: 'E-posta', filled: true, fillColor: AppColors.darkBackground),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Telefon', filled: true, fillColor: AppColors.darkBackground),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: duesCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Aylık Aidat Tutarı (TL)', filled: true, fillColor: AppColors.darkBackground),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal', style: TextStyle(color: AppColors.darkTextSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty || unitCtrl.text.trim().isEmpty) return;
              widget.controller.registerHomeOwner(
                block: blockCtrl.text,
                unitNo: int.tryParse(unitCtrl.text) ?? 1,
                ownerName: nameCtrl.text,
                email: emailCtrl.text,
                phone: phoneCtrl.text,
                duesAmount: Decimal.tryParse(duesCtrl.text) ?? Decimal.parse('1400.00'),
              );
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentGreen, foregroundColor: const Color(0xFF0F172A)),
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
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Yeni Site / Kompleks Kaydet', style: TextStyle(color: AppColors.darkTextPrimary, fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Site / Proje Adı', filled: true, fillColor: AppColors.darkBackground),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: cityCtrl,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Şehir', filled: true, fillColor: AppColors.darkBackground),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: addressCtrl,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Adres', filled: true, fillColor: AppColors.darkBackground),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: adminNameCtrl,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Yönetici Ad Soyad', filled: true, fillColor: AppColors.darkBackground),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: adminEmailCtrl,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Yönetici E-posta', filled: true, fillColor: AppColors.darkBackground),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: adminPhoneCtrl,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Yönetici Telefon', filled: true, fillColor: AppColors.darkBackground),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal', style: TextStyle(color: AppColors.darkTextSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty || adminNameCtrl.text.trim().isEmpty) return;
              widget.controller.registerNewSite(
                name: nameCtrl.text,
                city: cityCtrl.text,
                address: addressCtrl.text,
                adminName: adminNameCtrl.text,
                adminEmail: adminEmailCtrl.text,
                adminPhone: adminPhoneCtrl.text,
              );
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentCyan, foregroundColor: Colors.white),
            child: const Text('Siteyi Kaydet & Yetkilendir'),
          ),
        ],
      ),
    );
  }
}
