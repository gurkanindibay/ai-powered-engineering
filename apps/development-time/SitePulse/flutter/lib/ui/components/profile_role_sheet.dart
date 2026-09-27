import 'package:flutter/material.dart';
import '../../domain/models/auth_models.dart';
import '../theme/app_theme.dart';
import '../dashboard/dashboard_controller.dart';
import 'app_fullscreen_page.dart';

class ProfileRoleSheet extends StatefulWidget {
  final DashboardController controller;

  const ProfileRoleSheet({
    super.key,
    required this.controller,
  });

  @override
  State<ProfileRoleSheet> createState() => _ProfileRoleSheetState();
}

class _ProfileRoleSheetState extends State<ProfileRoleSheet> {
  final _emailController = TextEditingController(text: 'ahmet.yilmaz@gmail.com');
  final _passwordController = TextEditingController(text: '••••••••');
  bool _showLoginForm = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.controller.userSession;

    return AppFullscreenPage(
      title: 'Profil & Rol Yönetimi',
      subtitle: '${session.fullName} • ${session.role.displayName}',
      leading: IconButton(
        icon: Icon(
          Icons.arrow_back_ios_new_rounded,
          color: AppColors.textPrimary(context),
          size: 20,
        ),
        tooltip: 'Geri Dön',
        onPressed: () => Navigator.pop(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

            // Profile Header
            Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: AppColors.primary,
                  child: Text(
                    session.fullName.substring(0, 1),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
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
                          Flexible(
                            child: Text(
                              session.fullName,
                              style: TextStyle(
                                color: AppColors.textPrimary(context),
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.accentCyan.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              session.role.displayName,
                              style: const TextStyle(
                                color: AppColors.accentCyan,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${session.email} • ${session.unitName}',
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

            const SizedBox(height: 20),
            Divider(color: AppColors.border(context)),
            const SizedBox(height: 12),

            // Role Switcher Chips
            Text(
              'Rol Simülasyonu (Hızlı Değiştir)',
              style: TextStyle(
                color: AppColors.textSecondary(context),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: UserRole.values.map((role) {
                final isSelected = session.role == role;
                return ChoiceChip(
                  label: Text(role.displayName),
                  selected: isSelected,
                  onSelected: (_) {
                    widget.controller.switchSessionRole(role);
                    Navigator.pop(context);
                  },
                  selectedColor: AppColors.accentCyan,
                  backgroundColor: AppColors.card(context),
                  labelStyle: TextStyle(
                    color: isSelected ? Colors.white : AppColors.textPrimary(context),
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 18),
            Divider(color: AppColors.border(context)),
            const SizedBox(height: 12),

            // Multi-Auth Section
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Kimlik Doğrulama (Multi-Auth)',
                  style: TextStyle(
                    color: AppColors.textSecondary(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _showLoginForm = !_showLoginForm;
                    });
                  },
                  child: Text(
                    _showLoginForm ? 'Gizle' : 'Şifre ile Giriş Yap',
                    style: const TextStyle(color: AppColors.accentCyan, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Google SSO Button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  widget.controller.loginWithGoogle();
                  Navigator.pop(context);
                },
                icon: Icon(Icons.g_mobiledata, size: 24, color: AppColors.textPrimary(context)),
                label: Text(
                  'Google Hesabı ile Giriş Yap',
                  style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: AppColors.border(context)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),

            if (_showLoginForm) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _emailController,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'E-posta',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.background(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: true,
                style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Şifre',
                  labelStyle: TextStyle(color: AppColors.textSecondary(context)),
                  filled: true,
                  fillColor: AppColors.background(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    widget.controller.loginWithPassword(
                      _emailController.text,
                      _passwordController.text,
                    );
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentCyan,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Şifreyle Giriş Yap', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],

            const SizedBox(height: 20),
            Divider(color: AppColors.border(context)),
            const SizedBox(height: 12),

            // Tenant Isolation & Permission Scopes
            Text(
              'Aktif Yetki & İzolasyon Kapsamı',
              style: TextStyle(
                color: AppColors.textSecondary(context),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            ...session.permissions.map((perm) {
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.background(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: perm.isGranted
                        ? AppColors.accentGreen.withOpacity(0.3)
                        : AppColors.border(context),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      perm.isGranted ? Icons.check_circle : Icons.block,
                      color: perm.isGranted ? AppColors.accentGreen : AppColors.accentRed,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            perm.title,
                            style: TextStyle(
                              color: perm.isGranted
                                  ? AppColors.textPrimary(context)
                                  : AppColors.textSecondary(context),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            perm.isolationNote,
                            style: TextStyle(
                              color: AppColors.textSecondary(context),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  widget.controller.logout();
                },
                icon: const Icon(Icons.logout_rounded, color: AppColors.accentRed, size: 18),
                label: const Text(
                  'Çıkış Yap & Giriş Ekranına Dön',
                  style: TextStyle(color: AppColors.accentRed, fontWeight: FontWeight.bold),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: AppColors.accentRed.withOpacity(0.4)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      );
    }
  }
