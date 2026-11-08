import '../../testing/test_id.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import '../../domain/models/dues_models.dart';
import '../theme/app_theme.dart';
import '../dashboard/dashboard_controller.dart';
import 'package:decimal/decimal.dart';
import '../design_system/money_formatter.dart';
import '../design_system/sp_metric.dart';
import '../design_system/sp_tone.dart';

class SaasAdminView extends StatelessWidget {
  final DashboardController controller;
  final VoidCallback onAddSiteTap;
  final void Function(TenantSiteItem site)? onEditSiteTap;
  final void Function(TenantSiteItem site)? onDeleteSiteTap;
  final void Function(TenantSiteItem site)? onResetPasswordTap;

  const SaasAdminView({
    super.key,
    required this.controller,
    required this.onAddSiteTap,
    this.onEditSiteTap,
    this.onDeleteSiteTap,
    this.onResetPasswordTap,
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
                    colors: [Color(0xFF1E1B4B), AppColors.lightTextPrimary],
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
                  Flexible(child: Text(
                    'SitePulse Multi-Tenant Platform',
                    style: TextStyle(
                      color: AppColors.primaryText(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  )),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.accentCyan.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'SaaS SuperAdmin',
                      style: TextStyle(
                        color: AppColors.primaryText(context),
                        fontSize: 12,
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
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 8,
                runSpacing: 8,
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
                ]),
              const SizedBox(height: 16),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  SpMetricValue(label: 'Toplam Bağımsız Bölüm', value: '$totalUnits Daire'),
                  SpMetricValue(label: 'Platform Hacmi', value: '${formatTry(Decimal.fromInt(240000))} /ay', tone: SpTone.success),
                  const SpMetricValue(label: 'Uptime', value: '%99.98', tone: SpTone.info),
                ]),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // 2. Siteler Listesi Header & "+ Yeni Site" Action
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(child: Text(
              'Kayıtlı Siteler & Yöneticiler',
              style: TextStyle(
                color: AppColors.textPrimary(context),
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            )),
            Flexible(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
                IconButton(
                  tooltip: 'Siteleri Yenile',
                  icon: Icon(Icons.refresh, size: 20, color: AppColors.accentCyan),
                  onPressed: () => controller.fetchSaasSites(),
                ),
                const SizedBox(width: 6),
                testId('btn_open_add_site', ElevatedButton.icon(
                  onPressed: onAddSiteTap,
                  icon: const Icon(Icons.add_business, size: 16),
                  label: const Text('Yeni Site Kaydet', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryFill,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                )),
              ])),
          ],
        ),

        const SizedBox(height: 12),

        if (sites.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
            decoration: BoxDecoration(
              color: AppColors.card(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.domain_disabled, size: 44, color: AppColors.textSecondary(context)),
                  const SizedBox(height: 12),
                  Text(
                    'Kayıtlı Site Bulunamadı',
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Sisteme yeni bir site eklemek için "Yeni Site Kaydet" butonuna tıklayınız.',
                    style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          )
        else
          ...sites.map((site) => _buildTenantSiteCard(context, site)),
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
              Expanded(
                child: Row(
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
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          testId('site_card_name_${site.id}', Text(
                            site.name,
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          )),
                          Text(
                            '${site.city} • ${site.totalUnits} Daire',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
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
                  color: AppColors.accentGreen.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  site.planType,
                  style: TextStyle(
                    color: AppColors.successText(context),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
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
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Site Yöneticisi',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            site.adminName,
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '${site.adminPhone} • ${site.adminEmail}',
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    if (onEditSiteTap != null) ...[
                      testId('btn_edit_site_${site.id}', InkWell(
                        key: Key('btn_edit_site_${site.id}'),
                        onTap: () => onEditSiteTap!(site),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: AppColors.accentGreen.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.accentGreen.withOpacity(0.4)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.edit_outlined, size: 13, color: AppColors.accentGreen),
                              SizedBox(width: 4),
                              Text(
                                'Düzenle',
                                style: TextStyle(
                                  color: AppColors.successText(context),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )),
                      const SizedBox(width: 8),
                    ],
                    if (onResetPasswordTap != null)
                      testId('btn_reset_admin_password_${site.id}', InkWell(
                        onTap: () => onResetPasswordTap!(site),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: AppColors.accentCyan.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.accentCyan.withOpacity(0.4)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.key, size: 13, color: AppColors.accentCyan),
                              SizedBox(width: 4),
                              Text(
                                'Şifre Yenile',
                                style: TextStyle(
                                  color: AppColors.primaryText(context),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )),
                    if (onDeleteSiteTap != null) ...[
                      const SizedBox(width: 8),
                      if (!site.hasActions)
                        testId('btn_delete_site_${site.id}', InkWell(
                          onTap: () => onDeleteSiteTap!(site),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.red.withOpacity(0.3)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.delete_outline, size: 13, color: AppColors.accentRed),
                                SizedBox(width: 4),
                                Text(AppStrings.delete, style: TextStyle(color: AppColors.dangerText(context), fontSize: 12, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        ))
                      else
                        testId('site_delete_locked_${site.id}', Tooltip(
                          message: 'Bu siteye ait aktif daire veya işlem kaydı bulunduğundan silinemez.',
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(
                              color: AppColors.surface(context),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.border(context)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.lock_outline, size: 12, color: AppColors.textSecondary(context)),
                                const SizedBox(width: 4),
                                Text('İşlemli', style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12)),
                              ],
                            ),
                          ),
                        )),
                    ],
                  ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
