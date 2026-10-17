import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../domain/models/auth_models.dart';
import '../theme/app_theme.dart';
import '../dashboard/dashboard_controller.dart';

class LoginScreen extends StatefulWidget {
  final DashboardController controller;

  const LoginScreen({super.key, required this.controller});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  SiteAdminActivePath _selectedAdminPath = SiteAdminActivePath.managerCockpit;
  bool _showManualLogin = false;

  bool get _shouldShowDemoPersonas => !kReleaseMode || widget.controller.isTestMode;

  late final TextEditingController _emailController;
  late final TextEditingController _passwordController;

  @override
  void initState() {
    super.initState();
    _showManualLogin = !_shouldShowDemoPersonas;
    _emailController = TextEditingController(
      text: _shouldShowDemoPersonas ? 'mehmet.demir@begonya.com' : '',
    );
    _passwordController = TextEditingController(
      text: _shouldShowDemoPersonas ? 'Password123' : '',
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.controller.isDarkMode;

    return Scaffold(
      backgroundColor: isDark ? AppColors.darkBackground : AppColors.lightBackground,
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
                'Giriş & Rol Seçimi',
                style: TextStyle(fontSize: 10, color: AppColors.textSecondary(context), fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Tema Değiştir',
            icon: Icon(
              isDark ? Icons.light_mode : Icons.dark_mode,
              color: AppColors.textSecondary(context),
              size: 20,
            ),
            onPressed: () => widget.controller.toggleTheme(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Hero Welcome Banner
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: isDark
                      ? const LinearGradient(
                          colors: [Color(0xFF1E1B4B), Color(0xFF0F172A)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        )
                      : null,
                  color: isDark ? null : AppColors.lightSurface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark ? AppColors.accentCyan.withOpacity(0.4) : AppColors.lightBorder,
                    width: 1.5,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.accentCyan.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _shouldShowDemoPersonas ? 'AI-Powered Engineering Demo' : 'SitePulse Portal',
                            style: const TextStyle(
                              color: AppColors.accentCyan,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Hoş Geldiniz!',
                      style: TextStyle(
                        color: AppColors.textPrimary(context),
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _shouldShowDemoPersonas
                          ? 'Test etmek istediğiniz kullanıcı rolünü seçerek doğrudan ilgili deneyim akışına (flow) giriş yapabilirsiniz.'
                          : 'Site yönetim ve sakin portalına erişmek için lütfen kayıtlı e-posta adresiniz veya Google hesabınızla giriş yapınız.',
                      style: TextStyle(
                        color: AppColors.textSecondary(context),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),

              if (_shouldShowDemoPersonas) ...[
                const SizedBox(height: 24),

                // Title for Personas
                Row(
                  children: [
                    const Icon(Icons.badge_outlined, color: AppColors.accentCyan, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Test Kullanıcıları ile Hızlı Giriş',
                      style: TextStyle(
                        color: AppColors.textPrimary(context),
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // 1. SaaS Platform Admin Card
                _buildPersonaCard(
                  title: 'SaaS Platform Admin',
                  subtitle: 'Platform geneli tüm siteleri yönetme, yeni site açılışı ve geçici şifre yenileme',
                  name: 'SaaS Süper Yönetici',
                  email: 'admin@sitepulse.io',
                  badgeText: 'Platform Geneli',
                  badgeColor: AppColors.accentPurple,
                  icon: Icons.hub,
                  buttonText: 'SaaS Paneline Gir',
                  onLogin: () => widget.controller.loginAs(role: UserRole.saasAdmin),
                ),

                const SizedBox(height: 14),

                // 2. Site Manager Card with Path Selector
                _buildSiteManagerCard(),

                const SizedBox(height: 14),

                // 3. Home Owner Card
                _buildPersonaCard(
                  title: 'Kat Maliki (Ev Sahibi)',
                  subtitle: 'A Blok D:14 aidat ödemesi, sanal IBAN ile FAST, hane davet linki üretme',
                  name: 'Ahmet Yılmaz',
                  email: 'ahmet.yilmaz@begonya.com',
                  badgeText: 'A Blok D:14',
                  badgeColor: AppColors.accentGreen,
                  icon: Icons.home,
                  buttonText: 'Kat Maliki Olarak Gir',
                  onLogin: () => widget.controller.loginAs(role: UserRole.homeOwner),
                ),

                const SizedBox(height: 14),

                // 4. Home Resident Card
                _buildPersonaCard(
                  title: 'Ev Sakini (Aile / Kiracı)',
                  subtitle: 'A Blok D:14 aidat görüntüleme ve kredi kartı ile ödeme (yönetim ve davet yetkileri kısıtlı)',
                  name: 'Zeynep Yılmaz',
                  email: 'zeynep.yilmaz@gmail.com',
                  badgeText: 'A Blok D:14 (Kısıtlı)',
                  badgeColor: AppColors.accentOrange,
                  icon: Icons.person_outline,
                  buttonText: 'Ev Sakini Olarak Gir',
                  onLogin: () => widget.controller.loginAs(role: UserRole.homeResident),
                ),
              ],

              const SizedBox(height: 24),

              // Manual Login Section
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface(context),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Column(
                  children: [
                    if (_shouldShowDemoPersonas)
                      InkWell(
                        onTap: () {
                          setState(() {
                            _showManualLogin = !_showManualLogin;
                          });
                        },
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.lock_open_rounded, size: 18, color: AppColors.accentCyan),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Standart Giriş (E-posta / Google)',
                                    style: TextStyle(
                                      color: AppColors.textPrimary(context),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              Icon(
                                _showManualLogin ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                color: AppColors.textSecondary(context),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_showManualLogin || !_shouldShowDemoPersonas) ...[
                      if (_shouldShowDemoPersonas) const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            TextField(
                              controller: _emailController,
                              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                              decoration: InputDecoration(
                                labelText: 'E-posta Adresi',
                                labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _passwordController,
                              obscureText: true,
                              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                              decoration: InputDecoration(
                                labelText: 'Şifre',
                                labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              ),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: () {
                                  widget.controller.loginWithPassword(
                                    _emailController.text,
                                    _passwordController.text,
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.accentCyan,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                child: const Text('Şifreyle Giriş Yap', style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: () => widget.controller.loginWithGoogle(),
                                icon: const Icon(Icons.g_mobiledata, size: 22),
                                label: const Text('Google ile Giriş Yap'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 11),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPersonaCard({
    required String title,
    required String subtitle,
    required String name,
    required String email,
    required String badgeText,
    required Color badgeColor,
    required IconData icon,
    required String buttonText,
    required VoidCallback onLogin,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
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
              Expanded(
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, color: badgeColor, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            name,
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11, height: 1.3),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onLogin,
              style: ElevatedButton.styleFrom(
                backgroundColor: badgeColor.withOpacity(0.15),
                foregroundColor: badgeColor,
                elevation: 0,
                side: BorderSide(color: badgeColor.withOpacity(0.4)),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(
                buttonText,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSiteManagerCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.accentCyan.withOpacity(0.6),
          width: 1.5,
        ),
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
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.accentCyan.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.admin_panel_settings, color: AppColors.accentCyan, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Site Yöneticisi',
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'Mehmet Demir (mehmet.demir@begonya.com)',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accentCyan.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.accentCyan.withValues(alpha: 0.4)),
                ),
                child: const Text(
                  'Yönetici & Maliki',
                  style: TextStyle(
                    color: AppColors.accentCyan,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.card(context),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.alt_route, size: 14, color: AppColors.accentCyan),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Giriş Yolu Seçimi (Yönetici aynı zamanda kat malikidir):',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Option A: Manager Cockpit
                InkWell(
                  onTap: () {
                    setState(() {
                      _selectedAdminPath = SiteAdminActivePath.managerCockpit;
                    });
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _selectedAdminPath == SiteAdminActivePath.managerCockpit
                          ? AppColors.accentCyan.withOpacity(0.12)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _selectedAdminPath == SiteAdminActivePath.managerCockpit
                            ? AppColors.accentCyan
                            : AppColors.border(context),
                      ),
                    ),
                    child: Row(
                      children: [
                        Radio<SiteAdminActivePath>(
                          value: SiteAdminActivePath.managerCockpit,
                          groupValue: _selectedAdminPath,
                          activeColor: AppColors.accentCyan,
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedAdminPath = val);
                          },
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '🏢 Site Yönetim Paneli',
                                style: TextStyle(
                                  color: AppColors.textPrimary(context),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                'Begonya Sitesi genel tahsilat, sakin onayları ve blok yönetimi',
                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 6),

                // Option B: My Flat (House Owner)
                InkWell(
                  onTap: () {
                    setState(() {
                      _selectedAdminPath = SiteAdminActivePath.myFlatOwner;
                    });
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _selectedAdminPath == SiteAdminActivePath.myFlatOwner
                          ? AppColors.accentCyan.withOpacity(0.12)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _selectedAdminPath == SiteAdminActivePath.myFlatOwner
                            ? AppColors.accentCyan
                            : AppColors.border(context),
                      ),
                    ),
                    child: Row(
                      children: [
                        Radio<SiteAdminActivePath>(
                          value: SiteAdminActivePath.myFlatOwner,
                          groupValue: _selectedAdminPath,
                          activeColor: AppColors.accentCyan,
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedAdminPath = val);
                          },
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '🏠 Kendi Dairem (Kat Maliki)',
                                style: TextStyle(
                                  color: AppColors.textPrimary(context),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                'B Blok D:1 yönetici dairesi aidat ödemesi, sanal IBAN ve hane yönetimi',
                                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                widget.controller.loginAs(
                  role: UserRole.siteManager,
                  adminPath: _selectedAdminPath,
                );
              },
              icon: Icon(
                _selectedAdminPath == SiteAdminActivePath.managerCockpit
                    ? Icons.apartment
                    : Icons.home,
                size: 16,
              ),
              label: Text(
                _selectedAdminPath == SiteAdminActivePath.managerCockpit
                    ? 'Yönetici Paneli ile Başla'
                    : 'Kendi Dairem ile Başla (B Blok D:1)',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentCyan,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
