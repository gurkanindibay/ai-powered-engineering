import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../domain/models/auth_models.dart';
import '../../domain/models/dues_models.dart';
import '../theme/app_theme.dart';
import '../dashboard/dashboard_controller.dart';

enum LoginTab {
  quickAll,
  homeOwner,
  siteManager,
  saasAdmin,
}

class LoginScreen extends StatefulWidget {
  final DashboardController controller;

  const LoginScreen({super.key, required this.controller});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  LoginTab _selectedTab = LoginTab.siteManager;
  SiteAdminActivePath _selectedAdminPath = SiteAdminActivePath.managerCockpit;
  bool _showManualLogin = true;
  bool _obscureHomeownerPassword = true;
  bool _obscureManagerPassword = true;
  bool _obscureGeneralPassword = true;

  bool get _shouldShowDemoPersonas => widget.controller.isTestMode;

  late final TextEditingController _emailController;
  late final TextEditingController _passwordController;

  late final TextEditingController _homeownerEmailController;
  late final TextEditingController _homeownerPasswordController;

  late final TextEditingController _managerEmailController;
  late final TextEditingController _managerPasswordController;

  late final TextEditingController _saasEmailController;
  late final TextEditingController _saasPasswordController;

  bool _isSubmitting = false;
  String? _localError;

  @override
  void initState() {
    super.initState();
    _showManualLogin = true;

    final pCred = widget.controller.provisionedCredentials;
    final pHo = widget.controller.provisionedHomeOwner;
    final isTest = widget.controller.isTestMode;

    if (isTest) {
      _selectedTab = LoginTab.quickAll;
    }

    _emailController = TextEditingController(
      text: pCred != null ? pCred.adminEmail : (isTest ? 'yonetici@begonya.com' : ''),
    );
    _passwordController = TextEditingController(text: isTest ? 'Password123' : '');

    _homeownerEmailController = TextEditingController(
      text: pHo != null ? pHo.email : (isTest ? 'ahmet.yilmaz@begonya.com' : ''),
    );
    _homeownerPasswordController = TextEditingController(text: isTest ? 'Password123' : '');

    _managerEmailController = TextEditingController(
      text: pCred != null ? pCred.adminEmail : (isTest ? 'yonetici@begonya.com' : ''),
    );
    _managerPasswordController = TextEditingController(text: isTest ? 'Password123' : '');

    _saasEmailController = TextEditingController(text: 'admin@sitepulse.io');
    _saasPasswordController = TextEditingController(text: isTest ? 'AdminPass2026!' : '');

    widget.controller.addListener(_onControllerUpdate);
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    setState(() {});
  }

  void _clearCacheAndForm() {
    setState(() {
      _localError = null;
    });
    widget.controller.clearAuthMessage();
    widget.controller.clearAllLoginCache();
    _managerEmailController.clear();
    _managerPasswordController.clear();
    _homeownerEmailController.clear();
    _homeownerPasswordController.clear();
    _emailController.clear();
    _passwordController.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Giriş önbelleği ve form alanları temizlendi.'),
        duration: Duration(seconds: 2),
      ),
    );
    setState(() {});
  }

  Future<void> _performPasswordLogin({
    required String email,
    required String password,
    UserRole? targetRole,
    SiteAdminActivePath? adminPath,
  }) async {
    final trimmedEmail = email.trim();
    final trimmedPass = password.trim();

    if (trimmedEmail.isEmpty || trimmedPass.isEmpty) {
      const msg = 'Lütfen e-posta ve şifrenizi eksiksiz giriniz.';
      setState(() {
        _localError = msg;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text(msg),
            ],
          ),
          backgroundColor: Color(0xFFD97706),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
      _localError = null;
    });

    try {
      final success = await widget.controller.loginWithPassword(
        trimmedEmail,
        trimmedPass,
        targetRole: targetRole,
        adminPath: adminPath,
      );

      if (!mounted) return;

      if (!success) {
        final errorMsg = widget.controller.authMessage ?? 'Giriş başarısız: E-posta veya şifre hatalı.';
        setState(() {
          _localError = errorMsg;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    errorMsg,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final errorMsg = 'Giriş işlemi sırasında hata oluştu: $e';
        setState(() {
          _localError = errorMsg;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMsg),
            backgroundColor: const Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Widget _buildErrorBanner(BuildContext context) {
    final message = _localError ?? (!widget.controller.isAuthenticated ? widget.controller.authMessage : null);
    if (message == null || message.trim().isEmpty) return const SizedBox.shrink();

    return Container(
      key: const Key('login_error_banner'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFEF4444).withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.6), width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Giriş Yapılamadı',
                  style: TextStyle(
                    color: Color(0xFFEF4444),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Kapat',
            icon: const Icon(Icons.close, size: 16, color: Color(0xFFEF4444)),
            onPressed: () {
              setState(() {
                _localError = null;
              });
              widget.controller.clearAuthMessage();
            },
            constraints: const BoxConstraints(),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdate);
    _emailController.dispose();
    _passwordController.dispose();
    _homeownerEmailController.dispose();
    _homeownerPasswordController.dispose();
    _managerEmailController.dispose();
    _managerPasswordController.dispose();
    _saasEmailController.dispose();
    _saasPasswordController.dispose();
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
                      'Kat Maliki, Site Yöneticisi veya Platform Admin giriş ekranını seçerek doğrudan portala erişebilirsiniz.',
                      style: TextStyle(
                        color: AppColors.textSecondary(context),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Segmented Tab Selector for Dedicated Login Screens
              _buildRoleTabBar(context),

              const SizedBox(height: 20),

              // Render corresponding screen view
              if (_selectedTab == LoginTab.quickAll)
                _buildQuickAllView(context)
              else if (_selectedTab == LoginTab.homeOwner)
                _buildDedicatedHomeOwnerView(context)
              else if (_selectedTab == LoginTab.siteManager)
                _buildDedicatedSiteManagerView(context)
              else
                _buildDedicatedSaasAdminView(context),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoleTabBar(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _buildRoleTabButton(
            tab: LoginTab.quickAll,
            label: 'Tümü & Hızlı Giriş',
            icon: Icons.bolt,
            color: AppColors.accentCyan,
          ),
          const SizedBox(width: 8),
          _buildRoleTabButton(
            tab: LoginTab.homeOwner,
            label: '🏠 Kat Maliki Girişi',
            icon: Icons.home,
            color: AppColors.accentGreen,
          ),
          const SizedBox(width: 8),
          _buildRoleTabButton(
            tab: LoginTab.siteManager,
            label: '🏢 Site Yöneticisi Girişi',
            icon: Icons.apartment,
            color: AppColors.accentCyan,
          ),
          const SizedBox(width: 8),
          _buildRoleTabButton(
            tab: LoginTab.saasAdmin,
            label: '🌐 SaaS Admin',
            icon: Icons.hub,
            color: AppColors.accentPurple,
          ),
        ],
      ),
    );
  }

  Widget _buildRoleTabButton({
    required LoginTab tab,
    required String label,
    required IconData icon,
    required Color color,
  }) {
    final isSelected = _selectedTab == tab;
    return InkWell(
      onTap: () {
        setState(() {
          _selectedTab = tab;
          _localError = null;
        });
        widget.controller.clearAuthMessage();
      },
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.18) : AppColors.surface(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? color : AppColors.border(context),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: isSelected ? color : AppColors.textSecondary(context)),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? color : AppColors.textPrimary(context),
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  // VIEW 1: DEDICATED HOMEOWNER LOGIN SCREEN (🏠 Kat Maliki & Sakin Portalı)
  // =========================================================================
  Widget _buildDedicatedHomeOwnerView(BuildContext context) {
    final pHo = widget.controller.provisionedHomeOwner;
    final homeOwners = widget.controller.homeOwners;
    final flats = widget.controller.flatsList;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Header
        _buildSectionHeader(
          icon: Icons.home,
          color: AppColors.accentGreen,
          title: 'Kat Maliki & Ev Sakini Girişi',
          subtitle: 'Dairenize ait aidat borçlarını görüntüleyin, FAST ve kredi kartı ile anında ödeme yapın.',
        ),
        const SizedBox(height: 16),

        // 1. Newly Provisioned HomeOwner Highlight Card (if any)
        if (pHo != null) ...[
          _buildNewlyCreatedHomeOwnerCard(pHo),
          const SizedBox(height: 16),
        ],

        // 2. Dynamic Homeowners List (if any registered in system)
        if (homeOwners.isNotEmpty) ...[
          _buildDynamicHomeOwnersList(homeOwners),
          const SizedBox(height: 16),
        ] else if (flats.isNotEmpty && pHo == null) ...[
          _buildDynamicFlatsList(flats),
          const SizedBox(height: 16),
        ],

        // 3. Dedicated Homeowner Email & Password Form
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.accentGreen.withOpacity(0.4), width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.lock_outline, color: AppColors.accentGreen, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'E-posta & Şifre ile Kat Maliki Girişi',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  TextButton.icon(
                    key: const Key('btn_clear_login_cache_homeowner'),
                    onPressed: _clearCacheAndForm,
                    icon: const Icon(Icons.cleaning_services_outlined, size: 13, color: AppColors.accentGreen),
                    label: const Text(
                      'Temizle',
                      style: TextStyle(fontSize: 11, color: AppColors.accentGreen),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _buildErrorBanner(context),
              TextField(
                controller: _homeownerEmailController,
                onChanged: (_) {
                  if (_localError != null || widget.controller.authMessage != null) {
                    setState(() => _localError = null);
                    widget.controller.clearAuthMessage();
                  }
                },
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Kat Maliki / Sakin E-posta',
                  hintText: 'ornek@email.com',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  prefixIcon: const Icon(Icons.email_outlined, size: 18),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _homeownerPasswordController,
                obscureText: _obscureHomeownerPassword,
                onChanged: (_) {
                  if (_localError != null || widget.controller.authMessage != null) {
                    setState(() => _localError = null);
                    widget.controller.clearAuthMessage();
                  }
                },
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Şifre',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  prefixIcon: const Icon(Icons.lock_outline, size: 18),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureHomeownerPassword ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _obscureHomeownerPassword = !_obscureHomeownerPassword),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isSubmitting
                      ? null
                      : () => _performPasswordLogin(
                            email: _homeownerEmailController.text,
                            password: _homeownerPasswordController.text,
                            targetRole: UserRole.homeOwner,
                          ),
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Icon(Icons.login, size: 18),
                  label: Text(
                    _isSubmitting ? 'Giriş Yapılıyor...' : 'Kat Maliki Olarak Giriş Yap',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
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

        const SizedBox(height: 16),

        // 4. Demo Home Owner & Resident Personas
        if (_shouldShowDemoPersonas) ...[
          Text(
            'Örnek Demo Sakinler:',
            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
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
          const SizedBox(height: 10),
          _buildPersonaCard(
            title: 'Ev Sakini (Aile / Kiracı)',
            subtitle: 'A Blok D:14 aidat görüntüleme ve kredi kartı ile ödeme (kısıtlı yetki)',
            name: 'Zeynep Yılmaz',
            email: 'zeynep.yilmaz@gmail.com',
            badgeText: 'A Blok D:14 (Kısıtlı)',
            badgeColor: AppColors.accentOrange,
            icon: Icons.person_outline,
            buttonText: 'Ev Sakini Olarak Gir',
            onLogin: () => widget.controller.loginAs(role: UserRole.homeResident),
          ),
        ],
      ],
    );
  }

  // =========================================================================
  // VIEW 2: DEDICATED SITE MANAGER LOGIN SCREEN (🏢 Site Yöneticisi Portalı)
  // =========================================================================
  Widget _buildDedicatedSiteManagerView(BuildContext context) {
    final pCred = widget.controller.provisionedCredentials;
    final sites = widget.controller.saasSites;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Header
        _buildSectionHeader(
          icon: Icons.apartment,
          color: AppColors.accentCyan,
          title: 'Site Yöneticisi Girişi',
          subtitle: 'Site genel tahsilatları, banka dekont mutabakatı ve sakin yönetim kokpiti.',
        ),
        const SizedBox(height: 16),

        // 1. Newly Created Site / Manager Highlight Card (if any)
        if (pCred != null) ...[
          _buildNewlyCreatedSiteCard(pCred),
          const SizedBox(height: 16),
        ],

        // 2. Dynamic Managed Sites List (if any registered in system)
        if (sites.isNotEmpty) ...[
          _buildDynamicSitesList(sites),
          const SizedBox(height: 16),
        ],

        // 3. Dedicated Site Manager Form with Dual Path Selector
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.accentCyan.withOpacity(0.5), width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.admin_panel_settings, color: AppColors.accentCyan, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Yönetici E-posta & Şifre ile Giriş',
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  TextButton.icon(
                    key: const Key('btn_clear_login_cache_manager'),
                    onPressed: _clearCacheAndForm,
                    icon: const Icon(Icons.cleaning_services_outlined, size: 13, color: AppColors.accentCyan),
                    label: const Text(
                      'Temizle',
                      style: TextStyle(fontSize: 11, color: AppColors.accentCyan),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _buildErrorBanner(context),
              TextField(
                controller: _managerEmailController,
                onChanged: (_) {
                  if (_localError != null || widget.controller.authMessage != null) {
                    setState(() => _localError = null);
                    widget.controller.clearAuthMessage();
                  }
                },
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Site Yöneticisi E-posta',
                  hintText: 'yonetici@sitepulse.internal',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  prefixIcon: const Icon(Icons.email_outlined, size: 18),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _managerPasswordController,
                obscureText: _obscureManagerPassword,
                onChanged: (_) {
                  if (_localError != null || widget.controller.authMessage != null) {
                    setState(() => _localError = null);
                    widget.controller.clearAuthMessage();
                  }
                },
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Şifre',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  prefixIcon: const Icon(Icons.lock_outline, size: 18),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureManagerPassword ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _obscureManagerPassword = !_obscureManagerPassword),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
              const SizedBox(height: 14),

              // Dual Path Selector: Manager Cockpit vs My Flat
              _buildAdminPathSelector(context),

              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isSubmitting
                      ? null
                      : () => _performPasswordLogin(
                            email: _managerEmailController.text,
                            password: _managerPasswordController.text,
                            targetRole: UserRole.siteManager,
                            adminPath: _selectedAdminPath,
                          ),
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Icon(Icons.login, size: 18),
                  label: Text(
                    _isSubmitting ? 'Giriş Yapılıyor...' : 'Site Yöneticisi Olarak Giriş Yap',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentCyan,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),
      ],
    );
  }

  // =========================================================================
  // VIEW 3: DEDICATED SAAS PLATFORM ADMIN VIEW (🌐 SaaS Platform Admin)
  // =========================================================================
  Widget _buildDedicatedSaasAdminView(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          icon: Icons.hub,
          color: AppColors.accentPurple,
          title: 'SaaS Platform Süper Yönetici',
          subtitle: 'Platform geneli çok kiracılı (multi-tenant) site kurulumu, lisans denetimi ve yetkilendirme.',
        ),
        const SizedBox(height: 16),

        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.accentPurple.withOpacity(0.5), width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.security, color: AppColors.accentPurple, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'SaaS Süper Yönetici Kimlik Doğrulama',
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _buildErrorBanner(context),
              TextField(
                controller: _saasEmailController,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Süper Yönetici E-posta',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  prefixIcon: const Icon(Icons.email_outlined, size: 18),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _saasPasswordController,
                obscureText: true,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Şifre',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  prefixIcon: const Icon(Icons.lock_outline, size: 18),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    widget.controller.loginAs(role: UserRole.saasAdmin);
                  },
                  icon: const Icon(Icons.admin_panel_settings, size: 18),
                  label: const Text('SaaS Paneline Gir', style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentPurple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // =========================================================================
  // VIEW 4: QUICK ALL VIEW (Default: All Demo Personas + Dynamic Quick Cards)
  // =========================================================================
  Widget _buildQuickAllView(BuildContext context) {
    final pHo = widget.controller.provisionedHomeOwner;
    final pCred = widget.controller.provisionedCredentials;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title for Personas (checked by existing widget tests)
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

        // Highlight newly provisioned homeowner if exists
        if (pHo != null) ...[
          _buildNewlyCreatedHomeOwnerCard(pHo),
          const SizedBox(height: 14),
        ],

        // Highlight newly provisioned site/manager if exists
        if (pCred != null) ...[
          _buildNewlyCreatedSiteCard(pCred),
          const SizedBox(height: 14),
        ],

        if (_shouldShowDemoPersonas) ...[
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

        // Manual Login Section Accordion
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Column(
            children: [
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
              if (_showManualLogin) ...[
                const Divider(height: 1),
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
                        obscureText: _obscureGeneralPassword,
                        style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Şifre',
                          labelStyle: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscureGeneralPassword ? Icons.visibility_off : Icons.visibility,
                              size: 18,
                            ),
                            onPressed: () => setState(() => _obscureGeneralPassword = !_obscureGeneralPassword),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildErrorBanner(context),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _isSubmitting
                              ? null
                              : () => _performPasswordLogin(
                                    email: _emailController.text,
                                    password: _passwordController.text,
                                  ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accentCyan,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          child: Text(
                            _isSubmitting ? 'Giriş Yapılıyor...' : 'Şifreyle Giriş Yap',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
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
      ],
    );
  }

  // =========================================================================
  // HELPER WIDGETS
  // =========================================================================

  Widget _buildSectionHeader({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNewlyCreatedHomeOwnerCard(ProvisionedHomeOwnerCredentials p) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.accentGreen.withOpacity(0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accentGreen, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.star, color: AppColors.accentGreen, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    'Yeni Eklenen Kat Maliki',
                    style: TextStyle(
                      color: AppColors.accentGreen,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accentGreen.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${p.block} D:${p.unitNo}',
                  style: const TextStyle(color: AppColors.accentGreen, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            p.ownerName,
            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 15, fontWeight: FontWeight.bold),
          ),
          Text(
            'E-posta: ${p.email} | Şifre: ${p.temporaryPassword}',
            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                _homeownerEmailController.text = p.email;
                _homeownerPasswordController.text = p.temporaryPassword;
                widget.controller.loginAsProvisionedHomeOwner();
              },
              icon: const Icon(Icons.check_circle_outline, size: 18),
              label: Text('${p.ownerName} Olarak Hemen Gir', style: const TextStyle(fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentGreen,
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

  Widget _buildNewlyCreatedSiteCard(ProvisionedSiteCredentials p) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.accentCyan.withOpacity(0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accentCyan, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.apartment, color: AppColors.accentCyan, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    'Yeni Oluşturulan Site Yöneticisi',
                    style: TextStyle(
                      color: AppColors.accentCyan,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accentCyan.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  p.siteName,
                  style: const TextStyle(color: AppColors.accentCyan, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            p.adminName,
            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 15, fontWeight: FontWeight.bold),
          ),
          Text(
            'E-posta: ${p.adminEmail} | Şifre: ${p.temporaryPassword}',
            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                _managerEmailController.text = p.adminEmail;
                _managerPasswordController.text = p.temporaryPassword;
                widget.controller.loginAsProvisionedSiteManager(adminPath: _selectedAdminPath);
              },
              icon: const Icon(Icons.check_circle_outline, size: 18),
              label: Text('${p.siteName} Yöneticisi Olarak Gir', style: const TextStyle(fontWeight: FontWeight.bold)),
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

  Widget _buildDynamicHomeOwnersList(List<HomeOwnerItem> homeOwners) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Kayıtlı Kat Malikleri (Hızlı Seçim):',
          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ...homeOwners.take(4).map((ho) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
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
                      '${ho.block} D:${ho.unitNo} - ${ho.ownerFullName}',
                      style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    Text(
                      ho.email,
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                    ),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  _homeownerEmailController.text = ho.email;
                  widget.controller.loginAsHomeOwner(ho);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentGreen.withOpacity(0.15),
                  foregroundColor: AppColors.accentGreen,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Giriş Yap', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ],
          ),
        )),
      ],
    );
  }

  Widget _buildDynamicFlatsList(List<FlatPaymentStatus> flats) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Kayıtlı Daireler (Hızlı Seçim):',
          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ...flats.take(4).map((f) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
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
                      '${f.block} D:${f.unitNo} - ${f.residentName}',
                      style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    Text(
                      'Aylık Aidat: ₺${f.amountDue}',
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                    ),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  widget.controller.attachActiveUnitForUser(email: f.residentName, unitId: f.id);
                  widget.controller.loginAs(role: UserRole.homeOwner);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentGreen.withOpacity(0.15),
                  foregroundColor: AppColors.accentGreen,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Giriş Yap', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ],
          ),
        )),
      ],
    );
  }

  Widget _buildDynamicSitesList(List<TenantSiteItem> sites) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Yönetilen Siteler (Hızlı Seçim):',
          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ...sites.take(4).map((site) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
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
                      site.name,
                      style: TextStyle(color: AppColors.textPrimary(context), fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    Text(
                      'Yönetici: ${site.adminName} (${site.adminEmail})',
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                    ),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _managerEmailController.text = site.adminEmail;
                    _localError = null;
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('${site.name} yöneticisi (${site.adminEmail}) seçildi. Lütfen şifrenizi giriniz.'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentCyan.withOpacity(0.15),
                  foregroundColor: AppColors.accentCyan,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Yönetici Seç', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ],
          ),
        )),
      ],
    );
  }

  Widget _buildAdminPathSelector(BuildContext context) {
    return Container(
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
                          'Site genel tahsilat, sakin onayları ve blok yönetimi',
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
          _buildAdminPathSelector(context),
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
