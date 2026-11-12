import '../design_system/sp_page_header.dart';
import '../../testing/test_id.dart';
import 'package:flutter/material.dart';
import 'package:decimal/decimal.dart';
import '../../domain/models/dues_models.dart';
import '../theme/app_theme.dart';
import '../dashboard/dashboard_controller.dart';

import '../design_system/money_formatter.dart';
import '../payments/operating_budget_page.dart';
import '../payments/finance_hub_page.dart';
import '../design_system/sp_typography.dart';
import 'app_fullscreen_page.dart';
import '../design_system/sp_metric.dart';
import '../design_system/sp_tone.dart';
import '../../l10n/app_strings.dart';
import '../design_system/sp_guidance_card.dart';
class ManagerCockpitView extends StatelessWidget {
  final DashboardController controller;
  final VoidCallback onAddResidentTap;
  final VoidCallback? onInviteResidentsTap;
  final VoidCallback? onCreateAnnouncementTap;
  final VoidCallback? onManageHouseTypesTap;
  final VoidCallback? onManageHomeOwnersTap;
  final VoidCallback? onNavigateToDuesTab;

  const ManagerCockpitView({
    super.key,
    required this.controller,
    required this.onAddResidentTap,
    this.onInviteResidentsTap,
    this.onCreateAnnouncementTap,
    this.onManageHouseTypesTap,
    this.onManageHomeOwnersTap,
    this.onNavigateToDuesTab,
  });

  @override
  Widget build(BuildContext context) {
    final summary = controller.collectionSummary;
    final pendingList = controller.pendingRegistrations;
    final isDark = AppColors.isDark(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SpPageHeader(
          title: 'Yönetim Paneli',
          icon: Icons.apartment,
          subtitle:
              '${controller.userSession.siteName} • ${controller.currentManagedSite?.totalUnits ?? controller.flatsList.length} Daire',
          actions: [
            if (controller.managedSitesList.length > 1)
              PopupMenuButton<String>(
                tooltip: 'Site Değiştir',
                icon: const Icon(Icons.swap_horiz, color: AppColors.accentCyan),
                onSelected: (siteId) {
                  controller.changeManagedSite(siteId);
                },
                itemBuilder: (context) {
                  return controller.managedSitesList.map((site) {
                    return PopupMenuItem<String>(
                      value: site.id,
                      child: Row(
                        children: [
                          Icon(
                            Icons.apartment,
                            size: 16,
                            color: site.id == controller.currentManagedSite?.id
                                ? AppColors.accentCyan
                                : AppColors.textSecondary(context),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              site.name,
                              style: TextStyle(
                                fontWeight: site.id == controller.currentManagedSite?.id
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList();
                },
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        // 1. Tahsilat Özeti Card
        Container(
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
            gradient: isDark
                ? const LinearGradient(
                    colors: [Color(0xFF1E293B), AppColors.darkBackground],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
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
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  PopupMenuButton<String>(
                    tooltip: 'Dönem Seç',
                    onSelected: (month) {
                      controller.setSelectedDuesMonth(month);
                    },
                    itemBuilder: (context) => controller.availableDuesMonths.map((m) {
                      return PopupMenuItem<String>(
                        value: m,
                        child: Row(
                          children: [
                            if (m == controller.selectedDuesMonth)
                              const Icon(Icons.check, size: 16, color: AppColors.accentCyan)
                            else
                              const SizedBox(width: 16),
                            const SizedBox(width: 8),
                            Text(m),
                          ],
                        ),
                      );
                    }).toList(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(child: Text(
                            '${controller.selectedDuesMonth} Tahsilat Durumu',
 maxLines: 2,
 overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          )),
                          const SizedBox(width: 4),
                          const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.accentCyan),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: summary.totalExpected == Decimal.zero && summary.totalAdvanceBalance > Decimal.zero
                          ? AppColors.accentCyan.withOpacity(0.15)
                          : AppColors.accentGreen.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: testId('cockpit_collection_badge', Text(
                      summary.totalExpected == Decimal.zero
                          ? (summary.totalAdvanceBalance > Decimal.zero
                              ? '${formatTry(summary.totalAdvanceBalance)} Avans Mevcut'
                              : '₺0 Borç — Güncel')
                          : '%${summary.collectionPercentage} Tahsil Edildi',
                      style: TextStyle(
                        color: summary.totalExpected == Decimal.zero && summary.totalAdvanceBalance > Decimal.zero
                            ? AppColors.primaryText(context)
                            : AppColors.successText(context),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    )),
                  ),
                ]),
              const SizedBox(height: 10),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  testId('cockpit_collected_amount', Text(
                    formatTry(summary.totalCollected),
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  )),
                  const SizedBox(width: 8),
                  testId('cockpit_expected_amount', Text(
                    '/ ${formatTry(summary.totalExpected)}',
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 18,
                    ),
                  )),
                  if (summary.totalAdvanceBalance > Decimal.zero) ...[
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.accentCyan.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.accentCyan.withOpacity(0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.account_balance_wallet, size: 14, color: AppColors.accentCyan),
                          const SizedBox(width: 5),
                          Text(
                            '+${formatTry(summary.totalAdvanceBalance)} Avans',
                            style: TextStyle(
                              color: AppColors.primaryText(context),
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ]),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: summary.totalExpected == Decimal.zero ? 0.0 : summary.collectionPercentage / 100.0,
                  backgroundColor: AppColors.card(context),
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accentGreen),
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  SpMetricValue(label: AppStrings.totalUnits, value: '${summary.totalUnitsCount}'),
                  SpMetricValue(label: 'Ödeyen', value: '${summary.paidUnitsCount}', tone: SpTone.success),
                  SpMetricValue(label: 'Geciken', value: '${summary.overdueUnitsCount}', tone: SpTone.danger),
                  SpMetricValue(label: AppStrings.remainingDebt, value: formatTry(summary.totalOverdueAmount), tone: SpTone.warning),
                  if (summary.totalAdvanceBalance > Decimal.zero)
                    SpMetricValue(label: 'Toplam Avans', value: formatTry(summary.totalAdvanceBalance), tone: SpTone.info),
                ]),
              if (onNavigateToDuesTab != null) ...[
                const SizedBox(height: 14),
                testId('btn_open_unified_dues_center', InkWell(
                  key: const Key('btn_open_unified_dues_center'),
                  onTap: onNavigateToDuesTab,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.accentCyan.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.accentCyan.withOpacity(0.35)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.account_balance_wallet_outlined, size: 16, color: AppColors.accentCyan),
                        const SizedBox(width: 8),
                        Flexible(child: Text(
                          'Detaylı Daire Aidat & Kasa Yönetimi',
 maxLines: 2,
 overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.primaryText(context),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        )),
                        const SizedBox(width: 6),
                        const Icon(Icons.arrow_forward, size: 14, color: AppColors.accentCyan),
                      ],
                    ),
                  ),
                )),
              ],
            ],
          ),
        ),

        if (controller.unmatchedBankCount > 0 && onNavigateToDuesTab != null) ...[
          const SizedBox(height: 14),
          testId('dashboard_unmatched_bank_alert', InkWell(
            key: const Key('dashboard_unmatched_bank_alert'),
            onTap: onNavigateToDuesTab,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.accentOrange.withOpacity(0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.accentOrange.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accentOrange.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.sync_problem, color: AppColors.accentOrange, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${controller.unmatchedBankCount} Eşleşmeyen Banka Hareketi Var',
                          style: TextStyle(
                            color: AppColors.textPrimary(context),
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Banka ekstresinden gelen transferleri dairelerle eşleştirmek için dokunun.',
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.accentOrange),
                ],
              ),
            ),
          )),
        ],

        // İşletme projesi (KMK 37 as amended by Law 7579), SPEC-007 R5.
        const SizedBox(height: 14),
        testId('cockpit_operating_budget', InkWell(
          onTap: () => AppFullscreenPage.push(
            context: context,
            builder: (ctx) => OperatingBudgetPage(
              siteId: controller.currentManagedSite?.id,
              siteName: controller.currentManagedSite?.name ?? '',
            ),
          ),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Row(
              children: [
                const Icon(Icons.account_tree_outlined, color: AppColors.accentCyan),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('İşletme Projesi', style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.body, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text('Yıllık bütçe, genel kurul onayı, tebliğ ve itirazlar; aidat payları buradan gelir.',
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption)),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.textSecondary(context)),
              ],
            ),
          ),
        )),

        // SPEC-009: expenses, ledger, collections, requests, decisions, analytics, KVKK.
        const SizedBox(height: 14),
        testId('cockpit_finance_hub', InkWell(
          onTap: () => AppFullscreenPage.push(
            context: context,
            builder: (ctx) => FinanceHubPage(siteName: controller.currentManagedSite?.name ?? ''),
          ),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Row(
              children: [
                const Icon(Icons.account_balance_outlined, color: AppColors.accentCyan),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Finans Masası', style: TextStyle(color: AppColors.textPrimary(context), fontSize: SpFontSize.body, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text('Giderler, defter ve hesap raporu, takip dosyaları, talepler, karar defteri ve KVKK kaydı.',
                          style: TextStyle(color: AppColors.textSecondary(context), fontSize: SpFontSize.caption)),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.textSecondary(context)),
              ],
            ),
          ),
        )),

        const SizedBox(height: 20),

        // 2. Onay Bekleyen Sakin Başvuruları
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 8,
          spacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(
                  'Onay Bekleyen Başvurular',
 maxLines: 2,
 overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                )),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: pendingList.isNotEmpty ? AppColors.accentOrange : AppColors.border(context),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: testId('pending_count_badge', Text(
                    '${pendingList.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  )),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                  if (onInviteResidentsTap != null)
                    testId('btn_invite_resident_link', OutlinedButton.icon(
                      key: const Key('btn_invite_resident_link'),
                      onPressed: onInviteResidentsTap,
                      icon: const Icon(Icons.share_outlined, size: 16, color: AppColors.accentOrange),
                      label: const Text(
                        'Davet Linki',
                        style: TextStyle(color: AppColors.accentOrange, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    )),
                if (onCreateAnnouncementTap != null)
                  testId('btn_create_announcement', OutlinedButton.icon(
                    key: const Key('btn_create_announcement'),
                    onPressed: onCreateAnnouncementTap,
                    icon: const Icon(Icons.campaign_outlined, size: 16, color: AppColors.accentCyan),
                    label: const Text(
                      'Duyuru Yayınla',
                      style: TextStyle(color: AppColors.accentCyan, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  )),
                if (onManageHomeOwnersTap != null)
                  testId('btn_cockpit_manage_residents', TextButton.icon(
                    key: const Key('btn_cockpit_manage_residents'),
                    onPressed: onManageHomeOwnersTap,
                    icon: const Icon(Icons.people_alt_outlined, size: 16, color: AppColors.accentSky),
                    label: const Text(
                      'Sakin & Malik Listesi',
                      style: TextStyle(color: AppColors.accentSky, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  )),
                if (onManageHouseTypesTap != null)
                  testId('btn_cockpit_house_types', TextButton.icon(
                    onPressed: onManageHouseTypesTap,
                    icon: const Icon(Icons.home_work_outlined, size: 16, color: AppColors.accentPurple),
                    label: const Text(
                      'Konut Tipleri & Tarifeler',
                      style: TextStyle(color: AppColors.accentPurple, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  )),
                testId('btn_cockpit_add_resident', TextButton.icon(
                  onPressed: onAddResidentTap,
                  icon: const Icon(Icons.add, size: 16, color: AppColors.accentCyan),
                  label: Text(
                    'Manuel Sakin Ekle',
                    style: TextStyle(color: AppColors.primaryText(context), fontSize: 12),
                  ),
                )),
              ],
            ),
          ],
        ),

        const SizedBox(height: 8),

        if (pendingList.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Row(
              children: [
                const Icon(Icons.how_to_reg_outlined, color: AppColors.accentCyan, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Onay Bekleyen Başvuru Bulunmuyor',
                        style: TextStyle(color: AppColors.textPrimary(context), fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Kat malikleri davet bağlantısıyla başvurduğunda burada listelenir. Doğrudan sakin kaydetmek için "Manuel Sakin Ekle" butonunu kullanabilirsiniz.',
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        else
          ...pendingList.map((req) => _buildPendingRequestCard(context, req)),
        if (controller.currentManagedSite == null && controller.managedSitesList.isEmpty) ...[
          const SizedBox(height: 16),
          _buildNoSiteGuidance(context),
        ] else if (controller.availableDuesMonths.isEmpty) ...[
          const SizedBox(height: 16),
          _buildNoPeriodGuidance(context),
        ],
      ],
    );
  }

  Widget _buildNoSiteGuidance(BuildContext context) {
    return const SpGuidanceCard(
      icon: Icons.apartment_outlined,
      tone: SpTone.warning,
      title: AppStrings.noManagedSiteTitle,
      message: 'Sistemde henüz kayıtlı bir site bulunmuyor. Yönetici kokpitini kullanmak için lütfen yeni bir site tanımlayınız.',
    );
  }

  Widget _buildNoPeriodGuidance(BuildContext context) {
    return const SpGuidanceCard(
      icon: Icons.event_busy_outlined,
      tone: SpTone.info,
      tonedBorder: true,
      title: 'Aidat Takibi İçin Dönem Bulunmuyor',
      message: 'Sitenizde daire bazlı aidat borçlarını ve ödeme durumlarını takip edebilmek için öncelikle "Aidat Yönetimi" sekmesinden bir aidat dönemi oluşturmanız gerekmektedir.',
    );
  }

  Widget _buildPendingRequestCard(BuildContext context, RegistrationRequestItem req) {
    return testId('pending_card_${req.id}', Container(
      margin: const EdgeInsets.only(bottom: 10),
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
              Flexible(child: Text(
                '${req.block} D:${req.unitNo} • ${req.isResident ? 'Ev Sakini' : 'Kat Maliki'}',
                style: TextStyle(
                  color: AppColors.primaryText(context),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              )),
              Flexible(child: Text(
                req.timeAgoStr,
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
              )),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            req.fullName,
            style: TextStyle(
              color: AppColors.textPrimary(context),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${req.phone} • ${req.email}',
            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: testId('btn_approve_${req.id}', ElevatedButton.icon(
                  onPressed: () {
                    controller.approveRegistration(req.id);
                  },
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Onayla & Şifre Üret', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.successFill,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                )),
              ),
              const SizedBox(width: 8),
              testId('btn_reject_${req.id}', OutlinedButton(
                onPressed: () => controller.rejectRegistration(req.id),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accentRed,
                  side: const BorderSide(color: AppColors.accentRed),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Reddet', style: TextStyle(fontSize: 12)),
              )),
            ],
          ),
        ],
      ),
    ));
  }
}
