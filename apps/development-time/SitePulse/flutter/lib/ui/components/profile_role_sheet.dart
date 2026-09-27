import 'package:flutter/material.dart';
import '../../domain/models/auth_models.dart';
import '../theme/app_theme.dart';
import '../dashboard/dashboard_controller.dart';

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

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        top: 16,
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.darkBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),

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
                              style: const TextStyle(
                                color: AppColors.darkTextPrimary,
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
                        style: const TextStyle(
                          color: AppColors.darkTextSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),
            const Divider(color: AppColors.darkBorder),
            const SizedBox(height: 12),

            // Role Switcher Chips
            const Text(
              'Rol Simülasyonu (Hızlı Değiştir)',
              style: TextStyle(
                color: AppColors.darkTextSecondary,
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
                  backgroundColor: AppColors.darkCard,
                  labelStyle: TextStyle(
                    color: isSelected ? const Color(0xFF0F172A) : AppColors.darkTextPrimary,
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 18),
            const Divider(color: AppColors.darkBorder),
            const SizedBox(height: 12),

            // Multi-Auth Section
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Kimlik Doğrulama (Multi-Auth)',
                  style: TextStyle(
                    color: AppColors.darkTextSecondary,
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
                icon: const Icon(Icons.g_mobiledata, size: 24, color: Colors.white),
                label: const Text(
                  'Google Hesabı ile Giriş Yap',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.darkBorder),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),

            if (_showLoginForm) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _emailController,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'E-posta',
                  labelStyle: const TextStyle(color: AppColors.darkTextSecondary),
                  filled: true,
                  fillColor: AppColors.darkBackground,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: true,
                style: const TextStyle(color: AppColors.darkTextPrimary, fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Şifre',
                  labelStyle: const TextStyle(color: AppColors.darkTextSecondary),
                  filled: true,
                  fillColor: AppColors.darkBackground,
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
                    foregroundColor: const Color(0xFF0F172A),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Şifreyle Giriş Yap', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],

            const SizedBox(height: 20),
            const Divider(color: AppColors.darkBorder),
            const SizedBox(height: 12),

            // Tenant Isolation & Permission Scopes
            const Text(
              'Aktif Yetki & İzolasyon Kapsamı',
              style: TextStyle(
                color: AppColors.darkTextSecondary,
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
                  color: AppColors.darkBackground,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: perm.isGranted
                        ? AppColors.accentGreen.withOpacity(0.3)
                        : AppColors.darkBorder,
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
                                  ? AppColors.darkTextPrimary
                                  : AppColors.darkTextSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            perm.isolationNote,
                            style: const TextStyle(
                              color: AppColors.darkTextSecondary,
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
          ],
        ),
      ),
    );
  }
}
