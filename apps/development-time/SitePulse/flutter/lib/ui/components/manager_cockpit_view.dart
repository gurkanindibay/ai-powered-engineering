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

  const ManagerCockpitView({
    super.key,
    required this.controller,
    required this.onAddResidentTap,
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
                  Text(
                    '${controller.selectedDuesMonth} Tahsilat Durumu',
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      summary.totalExpected == Decimal.zero
                          ? '₺0 Borç — Güncel'
                          : '%${summary.collectionPercentage} Tahsil Edildi',
                      style: const TextStyle(
                        color: AppColors.accentGreen,
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
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: InkWell(
                  onTap: () => controller.resetAllDemoData(),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.refresh, size: 12, color: AppColors.accentRed),
                        SizedBox(width: 4),
                        Text(
                          'Verileri Sıfırla (₺0 Borç)',
                          style: TextStyle(color: AppColors.accentRed, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
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
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
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

        const SizedBox(height: 8),

        if (pendingList.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Center(
              child: Text(
                'Onay bekleyen başvuru bulunmuyor.',
                style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
              ),
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

        ...flats.map((flat) => _buildFlatStatusCard(context, flat)),
      ],
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
                    '${flat.block}${flat.unitNo}',
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
                    '${flat.block} Blok D:${flat.unitNo}',
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
                '₺${flat.amountDue.toStringAsFixed(2)}',
                style: TextStyle(
                  color: AppColors.textPrimary(context),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                flat.isPaid
                    ? (flat.amountDue == Decimal.zero ? 'Borç Yok' : 'Ödendi (${flat.paidDateStr ?? 'Tamam'})')
                    : '${flat.daysOverdue} Gün Gecikme',
                style: TextStyle(
                  color: flat.isPaid ? AppColors.accentGreen : AppColors.accentRed,
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
