import 'package:flutter/material.dart';
import 'package:decimal/decimal.dart';
import '../../domain/models/dues_models.dart';
import '../theme/app_theme.dart';
import '../dashboard/dashboard_controller.dart';
import 'app_fullscreen_page.dart';
import 'bank_statement_reconciliation_page.dart';

class ManagerCockpitView extends StatelessWidget {
  final DashboardController controller;
  final VoidCallback onAddResidentTap;
  final VoidCallback? onManageHouseTypesTap;
  final VoidCallback? onManageHomeOwnersTap;

  const ManagerCockpitView({
    super.key,
    required this.controller,
    required this.onAddResidentTap,
    this.onManageHouseTypesTap,
    this.onManageHomeOwnersTap,
  });

  @override
  Widget build(BuildContext context) {
    final summary = controller.collectionSummary;
    final pendingList = controller.pendingRegistrations;
    final flats = controller.currentMonthFlats;
    final isDark = AppColors.isDark(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 0. Managed Site Banner & Multi-Site Switcher
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.accentCyan.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.apartment,
                  color: AppColors.accentCyan,
                  size: 24,
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
                            controller.userSession.siteName,
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.accentCyan.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${controller.currentManagedSite?.totalUnits ?? controller.flatsList.length} Daire',
                            style: const TextStyle(
                              color: AppColors.accentCyan,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      controller.currentManagedSite?.address.isNotEmpty == true
                          ? controller.currentManagedSite!.address
                          : 'Yönetilen Site',
                      style: TextStyle(
                        color: AppColors.textSecondary(context),
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (controller.managedSitesList.length > 1) ...[
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
            ],
          ),
        ),
        // 1. Tahsilat Özeti Card
        Container(
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
            gradient: isDark
                ? const LinearGradient(
                    colors: [Color(0xFF1E293B), Color(0xFF121317)],
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                          Text(
                            '${controller.selectedDuesMonth} Tahsilat Durumu',
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
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
                    child: Text(
                      summary.totalExpected == Decimal.zero
                          ? (summary.totalAdvanceBalance > Decimal.zero
                              ? '₺${summary.totalAdvanceBalance.toStringAsFixed(0)} Avans Mevcut'
                              : '₺0 Borç — Güncel')
                          : '%${summary.collectionPercentage} Tahsil Edildi',
                      style: TextStyle(
                        color: summary.totalExpected == Decimal.zero && summary.totalAdvanceBalance > Decimal.zero
                            ? AppColors.accentCyan
                            : AppColors.accentGreen,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '₺${summary.totalCollected.toStringAsFixed(0)}',
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '/ ₺${summary.totalExpected.toStringAsFixed(0)}',
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 18,
                    ),
                  ),
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
                            '+₺${summary.totalAdvanceBalance.toStringAsFixed(0)} Avans',
                            style: const TextStyle(
                              color: AppColors.accentCyan,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildMetricTile(context, 'Toplam Daire', '${summary.totalUnitsCount}'),
                  _buildMetricTile(context, 'Ödeyen', '${summary.paidUnitsCount}', color: AppColors.accentGreen),
                  _buildMetricTile(context, 'Geciken', '${summary.overdueUnitsCount}', color: AppColors.accentRed),
                  _buildMetricTile(context, 'Kalan Borç', '₺${summary.totalOverdueAmount.toStringAsFixed(0)}', color: AppColors.accentOrange),
                  if (summary.totalAdvanceBalance > Decimal.zero)
                    _buildMetricTile(context, 'Toplam Avans', '₺${summary.totalAdvanceBalance.toStringAsFixed(0)}', color: AppColors.accentCyan),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Bank Statement Ingestion & Automated Reconciliation Action Card (STORY-07-02)
        InkWell(
          onTap: () {
            AppFullscreenPage.push(
              context: context,
              builder: (_) => BankStatementReconciliationPage(controller: controller),
            );
          },
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: AppColors.accentCyan.withOpacity(0.5),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accentCyan.withOpacity(0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.accentCyan.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.account_balance, color: AppColors.accentCyan, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Banka Ekstresi & Eşleştirme',
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.accentGreen.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'Zero-Approval',
                              style: TextStyle(
                                color: AppColors.accentGreen,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Excel, CSV veya MT940 ekstrelerini yapıştırın, aidatları otomatik eşleyin.',
                        style: TextStyle(
                          color: AppColors.textSecondary(context),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.accentCyan),
              ],
            ),
          ),
        ),

        const SizedBox(height: 24),

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
                Text(
                  'Onay Bekleyen Başvurular',
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: pendingList.isNotEmpty ? AppColors.accentOrange : AppColors.border(context),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${pendingList.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (onManageHomeOwnersTap != null)
                  TextButton.icon(
                    onPressed: onManageHomeOwnersTap,
                    icon: const Icon(Icons.people_alt_outlined, size: 16, color: AppColors.accentSky),
                    label: const Text(
                      'Sakinler & Malikler',
                      style: TextStyle(color: AppColors.accentSky, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                if (onManageHouseTypesTap != null)
                  TextButton.icon(
                    onPressed: onManageHouseTypesTap,
                    icon: const Icon(Icons.home_work_outlined, size: 16, color: AppColors.accentPurple),
                    label: const Text(
                      'Konut Tipleri & Tarifeler',
                      style: TextStyle(color: AppColors.accentPurple, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                TextButton.icon(
                  onPressed: onAddResidentTap,
                  icon: const Icon(Icons.add, size: 16, color: AppColors.accentCyan),
                  label: const Text(
                    'Manuel Sakin Ekle',
                    style: TextStyle(color: AppColors.accentCyan, fontSize: 12),
                  ),
                ),
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
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        else
          ...pendingList.map((req) => _buildPendingRequestCard(context, req)),

        const SizedBox(height: 24),

        // 3. Daire Aidat Takibi
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Daire Aidat Takibi',
              style: TextStyle(
                color: AppColors.textPrimary(context),
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            Row(
              children: [
                _buildFilterChip(context, 'Tümü', 'ALL'),
                const SizedBox(width: 6),
                _buildFilterChip(context, 'Geciken', 'OVERDUE'),
                const SizedBox(width: 6),
                _buildFilterChip(context, 'Ödeyen', 'PAID'),
              ],
            ),
          ],
        ),

        const SizedBox(height: 12),

        if (flats.isEmpty)
          _buildZeroDataFlatsGuidance(context)
        else
          ...flats.map((flat) => _buildFlatStatusCard(context, flat)),
      ],
    );
  }

  Widget _buildZeroDataFlatsGuidance(BuildContext context) {
    final hasNoPeriods = controller.availableDuesMonths.isEmpty;
    final hasNoFlats = controller.flatsList.isEmpty;
    final hasNoSite = controller.currentManagedSite == null && controller.managedSitesList.isEmpty;

    if (hasNoSite) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Column(
          children: [
            const Icon(Icons.apartment_outlined, size: 36, color: AppColors.accentOrange),
            const SizedBox(height: 8),
            Text(
              'Yönetilen Site Bulunmuyor',
              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Sistemde henüz kayıtlı bir site bulunmuyor. Yönetici kokpitini kullanmak için lütfen yeni bir site tanımlayınız.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
            ),
          ],
        ),
      );
    }

    if (hasNoPeriods) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.accentCyan.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            const Icon(Icons.event_busy_outlined, size: 36, color: AppColors.accentCyan),
            const SizedBox(height: 8),
            Text(
              'Aidat Takibi İçin Dönem Bulunmuyor',
              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Sitenizde daire bazlı aidat borçlarını ve ödeme durumlarını takip edebilmek için öncelikle "Aidat Yönetimi" sekmesinden bir aidat dönemi oluşturmanız gerekmektedir.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
            ),
          ],
        ),
      );
    }

    if (hasNoFlats) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.accentOrange.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            const Icon(Icons.people_outline, size: 36, color: AppColors.accentOrange),
            const SizedBox(height: 8),
            Text(
              'Kayıtlı Kat Maliki / Daire Yok',
              style: TextStyle(color: AppColors.textPrimary(context), fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Bu sitede henüz kayıtlı kat maliki veya daire bulunmuyor. "Manuel Sakin Ekle" butonu ile daire ve kat maliki ekleyebilirsiniz.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (onManageHouseTypesTap != null)
                  OutlinedButton.icon(
                    onPressed: onManageHouseTypesTap,
                    icon: const Icon(Icons.home_work_outlined, size: 16, color: AppColors.accentPurple),
                    label: const Text('Konut Tipleri & Tarifeler'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.accentPurple,
                      side: const BorderSide(color: AppColors.accentPurple),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ElevatedButton.icon(
                  onPressed: onAddResidentTap,
                  icon: const Icon(Icons.person_add_alt_1, size: 16),
                  label: const Text('Manuel Sakin Ekle'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentCyan,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        children: [
          Icon(Icons.filter_list_off, size: 36, color: AppColors.textSecondary(context)),
          const SizedBox(height: 8),
          Text(
            'Filtreye Uygun Daire Yok',
            style: TextStyle(color: AppColors.textPrimary(context), fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'Seçtiğiniz filtre (${controller.flatFilter}) kriterine uygun daire bulunmuyor.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => controller.setFlatFilter('ALL'),
            child: const Text('Tüm Daireleri Göster', style: TextStyle(color: AppColors.accentCyan)),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricTile(BuildContext context, String label, String value, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: AppColors.textSecondary(context), fontSize: 10),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color ?? AppColors.textPrimary(context),
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildFilterChip(BuildContext context, String label, String code) {
    final isSelected = controller.flatFilter == code;
    return InkWell(
      onTap: () => controller.setFlatFilter(code),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accentCyan : AppColors.surface(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.accentCyan : AppColors.border(context),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : AppColors.textSecondary(context),
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildPendingRequestCard(BuildContext context, RegistrationRequestItem req) {
    return Container(
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
              Text(
                '${req.block} D:${req.unitNo} • ${req.isResident ? 'Ev Sakini' : 'Kat Maliki'}',
                style: const TextStyle(
                  color: AppColors.accentCyan,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                req.timeAgoStr,
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 11),
              ),
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
                child: ElevatedButton.icon(
                  onPressed: () {
                    controller.approveRegistration(req.id);
                  },
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Onayla & Şifre Üret', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => controller.rejectRegistration(req.id),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accentRed,
                  side: const BorderSide(color: AppColors.accentRed),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Reddet', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFlatStatusCard(BuildContext context, FlatPaymentStatus flat) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: flat.isPaid
                      ? AppColors.accentGreen.withOpacity(0.15)
                      : AppColors.accentRed.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    flat.shortLabel,
                    style: TextStyle(
                      color: flat.isPaid ? AppColors.accentGreen : AppColors.accentRed,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    flat.residentName,
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    flat.houseType != null && flat.houseType!.isNotEmpty
                        ? '${flat.flatDesc} • ${flat.houseType}'
                        : flat.flatDesc,
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                flat.hasAdvanceBalance && flat.amountDue == Decimal.zero
                    ? '+₺${flat.advanceBalance.toStringAsFixed(2)}'
                    : '₺${flat.amountDue.toStringAsFixed(2)}',
                style: TextStyle(
                  color: flat.hasAdvanceBalance && flat.amountDue == Decimal.zero
                      ? AppColors.accentGreen
                      : AppColors.textPrimary(context),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                flat.hasAdvanceBalance
                    ? (flat.isPaid && flat.amountDue > Decimal.zero
                        ? 'Ödendi (+₺${flat.advanceBalance.toStringAsFixed(2)} Avans)'
                        : '+₺${flat.advanceBalance.toStringAsFixed(2)} Avans Bakiyesi')
                    : (flat.isPaid
                        ? (flat.amountDue == Decimal.zero ? 'Borç Yok' : 'Ödendi (${flat.paidDateStr ?? 'Tamam'})')
                        : '${flat.daysOverdue} Gün Gecikme'),
                style: TextStyle(
                  color: flat.isPaid || flat.hasAdvanceBalance ? AppColors.accentGreen : AppColors.accentRed,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
