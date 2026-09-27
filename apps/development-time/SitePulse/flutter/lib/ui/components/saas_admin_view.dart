import 'package:flutter/material.dart';
import '../../domain/models/dues_models.dart';
import '../theme/app_theme.dart';
import '../dashboard/dashboard_controller.dart';

class SaasAdminView extends StatelessWidget {
  final DashboardController controller;
  final VoidCallback onAddSiteTap;
  final void Function(TenantSiteItem site)? onDeleteSiteTap;

  const SaasAdminView({
    super.key,
    required this.controller,
    required this.onAddSiteTap,
    this.onDeleteSiteTap,
  });

  @override
  Widget build(BuildContext context) {
    final sites = controller.saasSites;
    final totalUnits = sites.fold<int>(0, (sum, s) => sum + s.totalUnits);
    final isDark = AppColors.isDark(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. SaaS Global Metrics Header Card
        Container(
          decoration: BoxDecoration(
            color: isDark ? null : AppColors.lightSurface,
            gradient: isDark
                ? const LinearGradient(
                    colors: [Color(0xFF1E1B4B), Color(0xFF0F172A)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark ? AppColors.accentCyan.withOpacity(0.4) : AppColors.lightBorder,
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black.withOpacity(0.3) : Colors.black.withOpacity(0.04),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'SitePulse Multi-Tenant Platform',
                    style: TextStyle(
                      color: AppColors.accentCyan,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.accentCyan.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'SaaS SuperAdmin',
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
              Text(
                'Sistem Geneli Yönetilen Siteler',
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '${sites.length}',
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Aktif Site / Kompleks',
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildMetric(context, 'Toplam Bağımsız Bölüm', '$totalUnits Daire'),
                  _buildMetric(context, 'Platform Hacmi', '₺240.000 /ay', color: AppColors.accentGreen),
                  _buildMetric(context, 'Uptime', '%99.98', color: AppColors.accentCyan),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // 2. Siteler Listesi Header & "+ Yeni Site" Action
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Kayıtlı Siteler & Yöneticiler',
              style: TextStyle(
                color: AppColors.textPrimary(context),
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            ElevatedButton.icon(
              onPressed: onAddSiteTap,
              icon: const Icon(Icons.add_business, size: 16),
              label: const Text('Yeni Site Kaydet', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentCyan,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        ...sites.map((site) => _buildTenantSiteCard(context, site)),
      ],
    );
  }

  Widget _buildMetric(BuildContext context, String label, String value, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color ?? AppColors.textPrimary(context),
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildTenantSiteCard(BuildContext context, TenantSiteItem site) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.domain, color: AppColors.accentCyan, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        site.name,
                        style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${site.city} • ${site.totalUnits} Daire',
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      site.planType,
                      style: const TextStyle(
                        color: AppColors.accentGreen,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (onDeleteSiteTap != null) ...[
                    const SizedBox(width: 8),
                    if (!site.hasActions)
                      InkWell(
                        onTap: () => onDeleteSiteTap!(site),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.red.withOpacity(0.3)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.delete_outline, size: 13, color: Colors.redAccent),
                              SizedBox(width: 3),
                              Text('Sil', style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      )
                    else
                      Tooltip(
                        message: 'Bu siteye ait aktif daire veya işlem kaydı bulunduğundan silinemez.',
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.card(context),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.border(context)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.lock_outline, size: 11, color: AppColors.textSecondary(context)),
                              const SizedBox(width: 3),
                              Text('İşlemli', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 9)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
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
                    Text(
                      'Site Yöneticisi',
                      style: TextStyle(color: AppColors.textSecondary(context), fontSize: 10),
                    ),
                    Text(
                      site.adminName,
                      style: TextStyle(
                        color: AppColors.textPrimary(context),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Text(
                  '${site.adminPhone} • ${site.adminEmail}',
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
