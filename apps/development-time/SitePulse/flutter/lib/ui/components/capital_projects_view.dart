import '../../testing/test_id.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import '../../domain/models/dues_models.dart';
import '../dashboard/dashboard_controller.dart';
import '../theme/app_theme.dart';
import '../design_system/sp_semantics.dart';
import 'app_fullscreen_page.dart';

import '../design_system/money_formatter.dart';
import '../design_system/sp_feedback.dart';
class CapitalProjectsView extends StatefulWidget {
  final DashboardController controller;

  const CapitalProjectsView({
    super.key,
    required this.controller,
  });

  @override
  State<CapitalProjectsView> createState() => _CapitalProjectsViewState();
}

class _CapitalProjectsViewState extends State<CapitalProjectsView> {
  int _activeSubTab = 0; // 0: Taksit Planı & Tahakkuk, 1: Kat Malikleri Payları, 2: Müteahhit Hakedişleri

  @override
  void initState() {
    super.initState();
    if (widget.controller.capitalProjects.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.controller.capitalProjects.isEmpty) {
          widget.controller.fetchCapitalProjects();
        }
      });
    }
  }

  void _openProjectWizard() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CapitalProjectWizardPage(controller: widget.controller),
      ),
    );
  }

  void _openDisbursementModal(String projectId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RecordDisbursementModal(
        controller: widget.controller,
        projectId: projectId,
      ),
    );
  }

  Future<void> _handleAccrueInstallment(String projectId, int installmentNumber, Decimal budget) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card(ctx),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentCyan.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.gavel_rounded, color: AppColors.accentCyan, size: 22),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Taksit Tahakkuk Onayı',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${formatTry(budget)} tutarındaki $installmentNumber. taksit tüm bağımsız bölümlere borç olarak tahakkuk ettirilecektir.',
              style: TextStyle(color: AppColors.textPrimary(ctx), fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.accentOrange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.accentOrange.withOpacity(0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, color: AppColors.accentOrange, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'KMK Madde 20/b uyarınca demirbaş borçları münhasıran Kat Maliklerine (Ev Sahipleri) yansıtılır. Kiracılar muaftır. Arsa payı dağılımında kuruş sapması garantilenir.',
                      style: TextStyle(
                        color: AppColors.warningText(context),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.cancel, style: TextStyle(color: AppColors.textSecondary(ctx))),
          ),
          testId('btn_confirm_accrual_dialog', ElevatedButton(
            key: const Key('btn_confirm_accrual_dialog'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryFill,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Tahakkuk Ettir'),
          )),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final res = await widget.controller.accrueCapitalInstallment(projectId, installmentNumber);
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          appSnackBar(
            content: Text(res['message']?.toString() ?? 'Taksit başarıyla tahakkuk ettirildi.'),
            backgroundColor: AppColors.successFill,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final projects = widget.controller.capitalProjects;
        final activeProj = widget.controller.activeCapitalProject;
        final installments = widget.controller.capitalInstallments;
        final disbursements = widget.controller.capitalDisbursements;
        final shares = widget.controller.unitCapitalShares;

        // Cumulative Totals across all active projects
        Decimal totalBudgetSum = Decimal.zero;
        Decimal totalCollectedSum = Decimal.zero;
        Decimal totalDisbursedSum = Decimal.zero;
        Decimal totalReserveFund = Decimal.zero;

        for (final p in projects) {
          totalBudgetSum += p.totalBudget;
          totalCollectedSum += p.collectedAmount;
          totalDisbursedSum += p.disbursedAmount;
        }
        totalReserveFund = totalCollectedSum - totalDisbursedSum;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Legal Directive & Statutory Notice Banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.accentCyan.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accentCyan.withOpacity(0.25)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.verified_user_rounded, color: AppColors.accentCyan, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '634 Sayılı Kat Mülkiyeti Kanunu (KMK 20/b) Standardı: Demirbaş ve yenileme giderleri yasal olarak doğrudan kat maliklerine borçlandırılır; bağımsız hesap havuzunda toplanır.',
                      style: TextStyle(
                        color: AppColors.textPrimary(context),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // 2. Reserve Fund Treasury Metrics KPI Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.card(context),
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
                                color: AppColors.accentCyan.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.account_balance, color: AppColors.accentCyan, size: 18),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                'Demirbaş & Yatırım Rezerv Fonu',
                                style: TextStyle(
                                  color: AppColors.textPrimary(context),
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      testId('btn_open_capital_project_wizard', ElevatedButton.icon(
                        key: const Key('btn_open_capital_project_wizard'),
                        onPressed: _openProjectWizard,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryFill,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          elevation: 0,
                        ),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text(
                          'Yeni Proje Başlat',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      )),
                    ],
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth > 650;
                      if (isWide) {
                        return Row(
                          children: [
                            Expanded(
                              child: _buildMetricTile(
                                context,
                                'Toplam Bütçe',
                                formatTry(totalBudgetSum),
                                Icons.calculate_outlined,
                                AppColors.textPrimary(context),
                                metricId: 'budget',
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _buildMetricTile(
                                context,
                                'Tahsil Edilen',
                                formatTry(totalCollectedSum),
                                Icons.arrow_downward_rounded,
                                AppColors.accentGreen,
                                metricId: 'collected',
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _buildMetricTile(
                                context,
                                'Hakediş Ödemeleri',
                                formatTry(totalDisbursedSum),
                                Icons.arrow_upward_rounded,
                                AppColors.accentOrange,
                                metricId: 'disbursed',
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _buildMetricTile(
                                context,
                                'Kalan Rezerv Fon',
                                formatTry(totalReserveFund),
                                Icons.shield_outlined,
                                AppColors.accentCyan,
                                metricId: 'reserve',
                                isHighlight: true,
                              ),
                            ),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _buildMetricTile(
                                  context,
                                  'Toplam Bütçe',
                                  formatTry(totalBudgetSum),
                                  Icons.calculate_outlined,
                                  AppColors.textPrimary(context),
                                  metricId: 'budget',
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildMetricTile(
                                  context,
                                  'Tahsil Edilen',
                                  formatTry(totalCollectedSum),
                                  Icons.arrow_downward_rounded,
                                  AppColors.accentGreen,
                                  metricId: 'collected',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: _buildMetricTile(
                                  context,
                                  'Hakediş Ödemeleri',
                                  formatTry(totalDisbursedSum),
                                  Icons.arrow_upward_rounded,
                                  AppColors.accentOrange,
                                  metricId: 'disbursed',
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildMetricTile(
                                  context,
                                  'Kalan Rezerv Fon',
                                  formatTry(totalReserveFund),
                                  Icons.shield_outlined,
                                  AppColors.accentCyan,
                                  metricId: 'reserve',
                                  isHighlight: true,
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 3. Projects Selector Strip
            if (projects.isNotEmpty) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: projects.map((proj) {
                    final isSelected = activeProj?.id == proj.id;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: testId('project_tab_${proj.id}', InkWell(
                        key: Key('project_tab_${proj.id}'),
                        onTap: () => widget.controller.selectCapitalProject(proj),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.accentCyan.withOpacity(0.15)
                                : AppColors.card(context),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected ? AppColors.accentCyan : AppColors.border(context),
                              width: isSelected ? 1.5 : 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _getCategoryIcon(proj.category),
                                size: 16,
                                color: isSelected ? AppColors.accentCyan : AppColors.textSecondary(context),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                proj.title,
                                style: TextStyle(
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  color: isSelected ? AppColors.primaryText(context) : AppColors.textPrimary(context),
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? AppColors.accentCyan.withOpacity(0.2)
                                      : Colors.grey.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '%${proj.collectionProgressPercentage.toStringAsFixed(0)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: isSelected ? AppColors.primaryText(context) : AppColors.textSecondary(context),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // 4. Selected Project Details & Subtabs
            if (activeProj != null) ...[
              Container(
                decoration: BoxDecoration(
                  color: AppColors.card(context),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Project Title & Meta Header
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: AppColors.accentCyan.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(_getCategoryIcon(activeProj.category), color: AppColors.accentCyan, size: 24),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      activeProj.title,
                                      style: TextStyle(
                                        color: AppColors.textPrimary(context),
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: AppColors.accentCyan.withOpacity(0.15),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            activeProj.categoryLabel,
                                            style: TextStyle(
                                              color: AppColors.primaryText(context),
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          'Dağıtım: ${activeProj.allocationBasisLabel}',
                                          style: TextStyle(
                                            color: AppColors.textSecondary(context),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    'Bütçe: ${formatTry(activeProj.totalBudget)}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                      color: AppColors.textPrimary(context),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${activeProj.installmentsCount} Taksit',
                                    style: TextStyle(
                                      color: AppColors.textSecondary(context),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          if (activeProj.description != null && activeProj.description!.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              activeProj.description!,
                              style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                            ),
                          ],
                          const SizedBox(height: 14),

                          // Progress Bar
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Flexible(child: Text(
                                'Tahsilat İlerlemesi',
                                style: TextStyle(
                                  color: AppColors.textSecondary(context),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              )),
                              Flexible(child: Text(
                                '${formatTry(activeProj.collectedAmount)} / ${formatTry(activeProj.totalBudget)} (%${activeProj.collectionProgressPercentage.toStringAsFixed(1)})',
                                style: TextStyle(
                                  color: AppColors.primaryText(context),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              )),
                            ],
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: (activeProj.collectionProgressPercentage / 100.0).clamp(0.0, 1.0),
                              backgroundColor: Colors.grey.withOpacity(0.15),
                              valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accentCyan),
                              minHeight: 8,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Divider(height: 1),

                    // Sub-tabs switcher (Taksit Planı / Kat Malikleri / Müteahhit Hakedişleri)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      color: AppColors.isDark(context) ? Colors.black12 : Colors.grey.shade50,
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildSubTabButton(0, 'Taksit Planı (${installments.length})'),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _buildSubTabButton(1, 'Kat Malikleri (${shares.length})'),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _buildSubTabButton(2, 'Hakedişler (${disbursements.length})'),
                          ),
                        ],
                      ),
                    ),

                    const Divider(height: 1),

                    // Sub-tab content
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: _buildSubTabContent(activeProj, installments, shares, disbursements),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    children: [
                      const Icon(Icons.apartment_outlined, size: 48, color: Colors.grey),
                      const SizedBox(height: 12),
                      Text(
                        'Henüz tanımlanmış bir demirbaş projesi bulunmuyor.',
                        style: TextStyle(color: AppColors.textSecondary(context), fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      testId('btn_open_first_capital_project', ElevatedButton.icon(
                        key: const Key('btn_open_first_capital_project'),
                        onPressed: _openProjectWizard,
                        icon: const Icon(Icons.add),
                        label: const Text('İlk Demirbaş Projesini Başlat'),
                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryFill),
                      )),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildMetricTile(
    BuildContext context,
    String label,
    String value,
    IconData icon,
    Color color, {
    bool isHighlight = false,
    String? metricId,
  }) {
    return testId('capital_metric_${metricId ?? "unnamed"}', Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isHighlight
            ? AppColors.accentCyan.withOpacity(0.12)
            : (AppColors.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.grey.shade100),
        borderRadius: BorderRadius.circular(12),
        border: isHighlight ? Border.all(color: AppColors.accentCyan.withOpacity(0.3)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: isHighlight ? AppColors.accentCyan : AppColors.textSecondary(context)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isHighlight ? AppColors.primaryText(context) : AppColors.textSecondary(context),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isHighlight ? AppColors.primaryText(context) : color,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    ));
  }

  Widget _buildSubTabButton(int index, String label) {
    final isSelected = _activeSubTab == index;
    return testId('subtab_button_$index', selectableSemantics(selected: isSelected, child: InkWell(
      key: Key('subtab_button_$index'),
      onTap: () => setState(() => _activeSubTab = index),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accentCyan : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? Colors.white : AppColors.textSecondary(context),
          ),
        ),
      ),
    )));
  }

  Widget _buildSubTabContent(
    CapitalProjectItem proj,
    List<CapitalProjectInstallmentItem> installments,
    List<UnitCapitalShareItem> shares,
    List<CapitalContractorDisbursementItem> disbursements,
  ) {
    if (_activeSubTab == 0) {
      // 0: Taksit Planı & Tahakkuk
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: Text(
                'Taksitlendirme Planı (${installments.length} Taksit)',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: AppColors.textPrimary(context),
                ),
              )),
              Flexible(child: Text(
                'Toplam: ${formatTry(proj.totalBudget)}',
                style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.primaryText(context), fontSize: 13),
              )),
            ],
          ),
          const SizedBox(height: 12),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: installments.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, idx) {
              final inst = installments[idx];
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.isDark(context) ? Colors.white.withOpacity(0.03) : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: inst.isAccrued
                            ? AppColors.accentGreen.withOpacity(0.15)
                            : AppColors.accentOrange.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        inst.isAccrued ? Icons.check_circle_outline : Icons.schedule,
                        color: inst.isAccrued ? AppColors.accentGreen : AppColors.accentOrange,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${inst.installmentNumber}. Taksit (%${inst.percentage.toStringAsFixed(0)})',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: AppColors.textPrimary(context),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Son Ödeme: ${inst.dueDate.year}-${inst.dueDate.month.toString().padLeft(2, '0')}-${inst.dueDate.day.toString().padLeft(2, '0')}',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          formatTry(inst.installmentBudget),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: AppColors.textPrimary(context),
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (inst.isAccrued)
                          testId('installment_accrued_${inst.installmentNumber}', Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.accentGreen.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Tahakkuk Etti',
                              style: TextStyle(color: AppColors.successText(context), fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ))
                        else
                          testId('btn_accrue_installment_${inst.installmentNumber}', ElevatedButton(
                            key: Key('btn_accrue_installment_${inst.installmentNumber}'),
                            onPressed: () => _handleAccrueInstallment(proj.id, inst.installmentNumber, inst.installmentBudget),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryFill,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              elevation: 0,
                            ),
                            child: const Text('Tahakkuk Ettir', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          )),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      );
    } else if (_activeSubTab == 1) {
      // 1: Kat Malikleri Payları
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'Kat Malikleri Demirbaş Dağılım Tablosu',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: AppColors.textPrimary(context),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.accentCyan.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Yalnızca Ev Sahipleri Borçlandırılır (KMK 20)',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.primaryText(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: shares.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, idx) {
              final share = shares[idx];
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.isDark(context) ? Colors.white.withOpacity(0.02) : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.accentCyan.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${share.block}-${share.unitNumber}',
                        style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.primaryText(context), fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            share.ownerName,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: AppColors.textPrimary(context),
                            ),
                          ),
                          const SizedBox(height: 2),
                          testId('unit_share_${share.block}_${share.unitNumber}', Text(
                            'Arsa Payı: ${share.landShare}/1000 • Toplam Pay: ${formatTry(share.totalProjectShare)}',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                          )),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'Ödenen: ${formatTry(share.totalPaid)}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: AppColors.successText(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          share.isSettled ? 'Tamamı Ödendi' : 'Kalan: ${formatTry(share.remainingDebt)}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: share.isSettled ? AppColors.successText(context) : AppColors.warningText(context),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      );
    } else {
      // 2: Müteahhit Hakedişleri
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'Müteahhit / Tedarikçi Hakediş Ödemeleri',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: AppColors.textPrimary(context),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              testId('btn_record_disbursement', ElevatedButton.icon(
                key: const Key('btn_record_disbursement'),
                onPressed: () => _openDisbursementModal(proj.id),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.warningFill,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
                icon: const Icon(Icons.add, size: 14),
                label: const Text('Hakediş Kaydet', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              )),
            ],
          ),
          const SizedBox(height: 12),
          if (disbursements.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Bu proje için henüz kaydedilmiş bir hakediş ödemesi yok.',
                  style: TextStyle(color: AppColors.textSecondary(context), fontSize: 13),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: disbursements.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, idx) {
                final d = disbursements[idx];
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.isDark(context) ? Colors.white.withOpacity(0.02) : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border(context)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.accentOrange.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.receipt_long, color: AppColors.accentOrange, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              d.milestoneName,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: AppColors.textPrimary(context),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Alıcı: ${d.recipientName} • Fatura: ${d.invoiceNumber ?? 'Belirtilmedi'}',
                              style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            formatTry(d.amount),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: AppColors.warningText(context),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${d.disbursementDate.year}-${d.disbursementDate.month.toString().padLeft(2, '0')}-${d.disbursementDate.day.toString().padLeft(2, '0')}',
                            style: TextStyle(color: AppColors.textSecondary(context), fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      );
    }
  }

  IconData _getCategoryIcon(String cat) {
    switch (cat) {
      case 'ELEVATOR':
        return Icons.elevator;
      case 'ROOF_FACADE':
        return Icons.roofing;
      case 'BOILER_HEATING':
        return Icons.local_fire_department;
      case 'SECURITY_SYSTEM':
        return Icons.videocam;
      case 'LANDSCAPING':
        return Icons.park;
      case 'GENERATOR':
        return Icons.bolt;
      default:
        return Icons.build;
    }
  }
}

// ---------------------------------------------------------------------------
// Capital Project Wizard Page (Papara-Style Fullscreen Flow)
// ---------------------------------------------------------------------------

class CapitalProjectWizardPage extends StatefulWidget {
  final DashboardController controller;

  const CapitalProjectWizardPage({
    super.key,
    required this.controller,
  });

  @override
  State<CapitalProjectWizardPage> createState() => _CapitalProjectWizardPageState();
}

class _CapitalProjectWizardPageState extends State<CapitalProjectWizardPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descController = TextEditingController();
  final _budgetController = TextEditingController();
  final _contractorNameController = TextEditingController();
  final _contractorTaxController = TextEditingController();
  final _contractorIbanController = TextEditingController();

  String _selectedCategory = 'ELEVATOR';
  String _allocationBasis = 'BY_LAND_SHARE';
  int _installmentsCount = 4;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _budgetController.dispose();
    _contractorNameController.dispose();
    _contractorTaxController.dispose();
    _contractorIbanController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final budgetVal = Decimal.tryParse(_budgetController.text.trim());
    if (budgetVal == null || budgetVal <= Decimal.zero) {
      ScaffoldMessenger.of(context).showSnackBar(
        appSnackBar(content: Text('Lütfen geçerli bir bütçe tutarı giriniz.')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    // Calculate installment items
    final installmentList = <Map<String, dynamic>>[];
    final perInstBudget = (budgetVal / Decimal.fromInt(_installmentsCount)).toDecimal(scaleOnInfinitePrecision: 2);
    final pct = (Decimal.fromInt(100) / Decimal.fromInt(_installmentsCount)).toDecimal(scaleOnInfinitePrecision: 2);

    Decimal accumulatedBudget = Decimal.zero;
    Decimal accumulatedPct = Decimal.zero;

    for (int i = 1; i <= _installmentsCount; i++) {
      final dueDate = DateTime.now().add(Duration(days: 30 * (i - 1)));
      final isLast = (i == _installmentsCount);
      final currentBudget = isLast ? (budgetVal - accumulatedBudget) : perInstBudget;
      final currentPct = isLast ? (Decimal.fromInt(100) - accumulatedPct) : pct;

      accumulatedBudget += currentBudget;
      accumulatedPct += currentPct;

      installmentList.add({
        'installment_number': i,
        'total_installments': _installmentsCount,
        'due_date': dueDate.toIso8601String().substring(0, 10),
        'installment_budget': currentBudget.toString(),
        'percentage': currentPct.toString(),
      });
    }

    final created = await widget.controller.createCapitalProject(
      title: _titleController.text.trim(),
      category: _selectedCategory,
      description: _descController.text.trim().isNotEmpty ? _descController.text.trim() : null,
      totalBudget: budgetVal,
      allocationBasis: _allocationBasis,
      contractorName: _contractorNameController.text.trim().isNotEmpty ? _contractorNameController.text.trim() : null,
      contractorTaxNo: _contractorTaxController.text.trim().isNotEmpty ? _contractorTaxController.text.trim() : null,
      contractorIban: _contractorIbanController.text.trim().isNotEmpty ? _contractorIbanController.text.trim() : null,
      contractAmount: budgetVal,
      installments: installmentList,
    );

    setState(() => _isSubmitting = false);

    if (created != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        appSnackBar(
          content: Text('${created.title} projesi başarıyla oluşturuldu.'),
          backgroundColor: AppColors.successFill,
        ),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppFullscreenPage(
      title: 'Yeni Demirbaş Projesi',
      subtitle: 'KMK 20/b Uyumlu Demirbaş ve Yatırım Planı Tanımlayın',
      icon: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.accentCyan.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.handyman_rounded, color: AppColors.accentCyan, size: 20),
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Proje Başlığı
            Text('Proje Başlığı *', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary(context))),
            const SizedBox(height: 6),
            testId('input_capital_project_title', TextFormField(
              key: const Key('input_capital_project_title'),
              controller: _titleController,
              decoration: InputDecoration(
                hintText: 'Örn: Asansör Revizyonu ve Yeşil Etiketleme',
                filled: true,
                fillColor: AppColors.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.grey.shade100,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Başlık zorunludur' : null,
            )),
            const SizedBox(height: 16),

            // Kategori
            Text('Demirbaş Kategorisi', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary(context))),
            const SizedBox(height: 6),
            testId('dropdown_capital_project_category', DropdownButtonFormField<String>(
              key: const Key('dropdown_capital_project_category'),
              value: _selectedCategory,
              decoration: InputDecoration(
                filled: true,
                fillColor: AppColors.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.grey.shade100,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
              items: const [
                DropdownMenuItem(value: 'ELEVATOR', child: Text('Asansör & Revizyon')),
                DropdownMenuItem(value: 'ROOF_FACADE', child: Text('Çatı & Dış Cephe Yalıtımı')),
                DropdownMenuItem(value: 'BOILER_HEATING', child: Text('Merkezi Kazan & Isıtma')),
                DropdownMenuItem(value: 'SECURITY_SYSTEM', child: Text('Kamera & Güvenlik')),
                DropdownMenuItem(value: 'LANDSCAPING', child: Text('Çevre Düzeni & Peyzaj')),
                DropdownMenuItem(value: 'GENERATOR', child: Text('Jeneratör & Enerji')),
                DropdownMenuItem(value: 'OTHER', child: Text('Diğer Demirbaş')),
              ],
              onChanged: (val) {
                if (val != null) setState(() => _selectedCategory = val);
              },
            )),
            const SizedBox(height: 16),

            // Toplam Bütçe
            Text('Toplam Proje Bütçesi (₺) *', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary(context))),
            const SizedBox(height: 6),
            testId('input_capital_project_budget', TextFormField(
              key: const Key('input_capital_project_budget'),
              controller: _budgetController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                hintText: 'Örn: 120000.00',
                filled: true,
                fillColor: AppColors.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.grey.shade100,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Bütçe zorunludur';
                if (Decimal.tryParse(v.trim()) == null) return 'Geçerli bir tutar girin';
                return null;
              },
            )),
            const SizedBox(height: 16),

            // Paylaşım Esası
            Text('Paylaşım Esası (KMK Standartları)', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary(context))),
            const SizedBox(height: 6),
            testId('radio_allocation_by_land_share', RadioListTile<String>(
              title: const Text('Arsa Payı Oranında (KMK Madde 20/b - Yasal Standart)'),
              subtitle: const Text('Her bağımsız bölüm tapudaki arsa payı nispetinde borçlandırılır.'),
              value: 'BY_LAND_SHARE',
              groupValue: _allocationBasis,
              activeColor: AppColors.accentCyan,
              onChanged: (v) => setState(() => _allocationBasis = v!),
            )),
            testId('radio_allocation_equal', RadioListTile<String>(
              title: const Text('Bağımsız Bölüm Başına Eşit'),
              subtitle: const Text('Bütçe tüm dairelere eşit olarak bölünür.'),
              value: 'EQUAL_PER_UNIT',
              groupValue: _allocationBasis,
              activeColor: AppColors.accentCyan,
              onChanged: (v) => setState(() => _allocationBasis = v!),
            )),
            const SizedBox(height: 16),

            // Taksit Sayısı
            Text('Taksit Sayısı', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary(context))),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [1, 2, 3, 4, 6, 12].map((cnt) {
                  final isSelected = _installmentsCount == cnt;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: testId('chip_installments_$cnt', InkWell(
                      onTap: () => setState(() => _installmentsCount = cnt),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected ? AppColors.accentCyan : Colors.grey.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$cnt Taksit',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isSelected ? Colors.white : AppColors.textPrimary(context),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    )),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),

            // Müteahhit Bilgileri
            Text('Yüklenici / Müteahhit Bilgileri (Opsiyonel)', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary(context))),
            const SizedBox(height: 8),
            TextFormField(
              controller: _contractorNameController,
              decoration: InputDecoration(
                labelText: 'Müteahhit Firma Unvanı',
                filled: true,
                fillColor: AppColors.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.grey.shade100,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _contractorIbanController,
              decoration: InputDecoration(
                labelText: 'Müteahhit IBAN',
                filled: true,
                fillColor: AppColors.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.grey.shade100,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 16),

            // Açıklama
            Text('Açıklama / Karar Defteri Maddesi', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary(context))),
            const SizedBox(height: 6),
            TextFormField(
              controller: _descController,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'Örn: 2026/04 sayılı Olağanüstü Genel Kurul Kararı gereğince başlatılmıştır.',
                filled: true,
                fillColor: AppColors.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.grey.shade100,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 24),

            // Submit Button
            SizedBox(
              width: double.infinity,
              height: 48,
              child: testId('btn_submit_capital_project', ElevatedButton(
                key: const Key('btn_submit_capital_project'),
                onPressed: _isSubmitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryFill,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: _isSubmitting
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        'Demirbaş Projesini ve Taksit Planını Başlat',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
              )),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Record Contractor Disbursement Modal
// ---------------------------------------------------------------------------

class RecordDisbursementModal extends StatefulWidget {
  final DashboardController controller;
  final String projectId;

  const RecordDisbursementModal({
    super.key,
    required this.controller,
    required this.projectId,
  });

  @override
  State<RecordDisbursementModal> createState() => _RecordDisbursementModalState();
}

class _RecordDisbursementModalState extends State<RecordDisbursementModal> {
  final _formKey = GlobalKey<FormState>();
  final _milestoneController = TextEditingController();
  final _amountController = TextEditingController();
  final _recipientController = TextEditingController();
  final _ibanController = TextEditingController();
  final _invoiceController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final p = widget.controller.activeCapitalProject;
    if (p?.contractorName != null) _recipientController.text = p!.contractorName!;
    if (p?.contractorIban != null) _ibanController.text = p!.contractorIban!;
  }

  @override
  void dispose() {
    _milestoneController.dispose();
    _amountController.dispose();
    _recipientController.dispose();
    _ibanController.dispose();
    _invoiceController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final amt = Decimal.tryParse(_amountController.text.trim());
    if (amt == null || amt <= Decimal.zero) {
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text('Geçerli bir tutar girin.')));
      return;
    }

    setState(() => _isSubmitting = true);

    final res = await widget.controller.recordCapitalDisbursement(
      widget.projectId,
      milestoneName: _milestoneController.text.trim(),
      amount: amt,
      recipientName: _recipientController.text.trim(),
      recipientIban: _ibanController.text.trim(),
      invoiceNumber: _invoiceController.text.trim().isNotEmpty ? _invoiceController.text.trim() : null,
    );

    setState(() => _isSubmitting = false);

    if (res != null && mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        appSnackBar(
          content: Text('${formatTry(amt)} hakediş ödemesi başarıyla kaydedildi.'),
          backgroundColor: AppColors.successFill,
        ),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Müteahhit Hakediş / İlerleme Ödemesi',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary(context),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  testId('btn_close_disbursement_modal', IconButton(
                    key: const Key('btn_close_disbursement_modal'),
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  )),
                ],
              ),
              const SizedBox(height: 12),
              testId('input_disbursement_milestone', TextFormField(
                key: const Key('input_disbursement_milestone'),
                controller: _milestoneController,
                decoration: InputDecoration(
                  labelText: 'Aşama / Hakediş Tanımı *',
                  hintText: 'Örn: 1. Hakediş - Malzeme Temini ve Montaj',
                  filled: true,
                  fillColor: AppColors.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.grey.shade100,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Aşama tanımı zorunludur' : null,
              )),
              const SizedBox(height: 10),
              testId('input_disbursement_amount', TextFormField(
                key: const Key('input_disbursement_amount'),
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Ödeme Tutarı (₺) *',
                  filled: true,
                  fillColor: AppColors.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.grey.shade100,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
                validator: (v) => (v == null || Decimal.tryParse(v.trim()) == null) ? 'Geçerli tutar girin' : null,
              )),
              const SizedBox(height: 10),
              testId('input_disbursement_recipient', TextFormField(
                key: const Key('input_disbursement_recipient'),
                controller: _recipientController,
                decoration: InputDecoration(
                  labelText: 'Alıcı Firma / Kişi *',
                  filled: true,
                  fillColor: AppColors.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.grey.shade100,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Alıcı zorunludur' : null,
              )),
              const SizedBox(height: 10),
              testId('input_disbursement_iban', TextFormField(
                key: const Key('input_disbursement_iban'),
                controller: _ibanController,
                decoration: InputDecoration(
                  labelText: 'Alıcı IBAN *',
                  hintText: 'TR..',
                  filled: true,
                  fillColor: AppColors.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.grey.shade100,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'IBAN zorunludur' : null,
              )),
              const SizedBox(height: 10),
              TextFormField(
                controller: _invoiceController,
                decoration: InputDecoration(
                  labelText: 'Fatura No (Opsiyonel)',
                  filled: true,
                  fillColor: AppColors.isDark(context) ? Colors.white.withOpacity(0.04) : Colors.grey.shade100,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: testId('btn_submit_disbursement', ElevatedButton(
                  key: const Key('btn_submit_disbursement'),
                  onPressed: _isSubmitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.warningFill,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isSubmitting
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Hakediş Ödemesini Kaydet', style: TextStyle(fontWeight: FontWeight.bold)),
                )),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
