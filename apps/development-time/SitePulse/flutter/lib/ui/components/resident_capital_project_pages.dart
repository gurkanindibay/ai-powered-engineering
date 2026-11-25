import '../../testing/test_id.dart';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../domain/models/dues_models.dart';
import '../dashboard/dashboard_controller.dart';
import '../design_system/money_formatter.dart';
import '../design_system/sp_guidance_card.dart';
import '../design_system/sp_metric.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';
import 'app_fullscreen_page.dart';

class TenantCapitalProjectsGuidance extends StatelessWidget {
  final List<CapitalProjectItem> projects;

  const TenantCapitalProjectsGuidance({super.key, required this.projects});

  static const guidance =
      'Demirbaş giderleri yasal olarak ev sahibinize aittir. Ödemeniz halinde kiradan düşebilirsiniz.';

  @override
  Widget build(BuildContext context) {
    if (projects.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        testId(
          'tenant_capital_projects',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Demirbaş Projeleri',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: AppColors.textPrimary(context),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              for (final project in projects)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: testId(
                    'tenant_capital_project_${project.id}',
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surface(context),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border(context)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              project.title,
                              style: TextStyle(
                                color: AppColors.textPrimary(context),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const SpStatusBadge(
                            label: 'Kat Maliki Sorumluluğunda',
                            tone: SpTone.info,
                            icon: Icons.home_work_outlined,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        testId(
          'tenant_capital_guidance',
          const SpGuidanceCard(
            icon: Icons.gavel_outlined,
            title: 'Demirbaş giderleri hakkında',
            message: guidance,
            tone: SpTone.info,
            tonedBorder: true,
          ),
        ),
      ],
    );
  }
}

class ResidentCapitalProjectDetailsPage extends StatelessWidget {
  final ResidentCapitalProjectDetails details;
  final Decimal outstandingBalance;

  const ResidentCapitalProjectDetailsPage({
    super.key,
    required this.details,
    required this.outstandingBalance,
  });

  @override
  Widget build(BuildContext context) {
    final project = details.project;
    return AppFullscreenPage(
      title: project.title,
      leading: testId(
        'resident_capital_project_back',
        IconButton(
          key: const Key('resident_capital_project_back'),
          tooltip: 'Geri',
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          testId(
            'resident_capital_project_breakdown',
            Text(
              'Proje Detayları',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppColors.textPrimary(context),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              SpMetricValue(
                label: 'Proje Bütçesi',
                value: formatTry(project.totalBudget),
                tone: SpTone.accent,
              ),
              SpMetricValue(
                label: 'Dairenizin Kalan Borcu',
                value: formatTry(outstandingBalance),
                tone: SpTone.warning,
              ),
            ],
          ),
          if (project.description?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 16),
            Text(
              project.description!,
              style: TextStyle(color: AppColors.textSecondary(context)),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            'Yüklenici Bilgileri',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: AppColors.textPrimary(context),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          testId(
            'resident_capital_project_contractor',
            Text(
              project.contractorName?.trim().isNotEmpty == true
                  ? project.contractorName!
                  : 'Yüklenici bilgisi eklenmemiş.',
              style: TextStyle(color: AppColors.textPrimary(context)),
            ),
          ),
          if (project.contractorTaxNo?.trim().isNotEmpty == true)
            Text(
              'Vergi No: ${project.contractorTaxNo}',
              style: TextStyle(color: AppColors.textSecondary(context)),
            ),
          if (project.contractAmount != null)
            Text(
              'Sözleşme Tutarı: ${formatTry(project.contractAmount!)}',
              style: TextStyle(color: AppColors.textSecondary(context)),
            ),
          const SizedBox(height: 20),
          Text(
            'Taksit Takvimi',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: AppColors.textPrimary(context),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          testId(
            'resident_capital_project_installments',
            Column(
              children: [
                for (final installment in details.installments)
                  ListTile(
                    key: Key(
                      'resident_capital_installment_${installment.installmentNumber}',
                    ),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      installment.isAccrued
                          ? Icons.check_circle_outline
                          : Icons.schedule,
                      color: installment.isAccrued
                          ? SpTone.success.accent(context)
                          : SpTone.warning.accent(context),
                    ),
                    title: Text('${installment.installmentNumber}. Taksit'),
                    subtitle: Text(
                      'Son ödeme: ${installment.dueDate.year}-'
                      '${installment.dueDate.month.toString().padLeft(2, '0')}-'
                      '${installment.dueDate.day.toString().padLeft(2, '0')}',
                    ),
                    trailing: Text(formatTry(installment.installmentBudget)),
                  ),
                if (details.installments.isEmpty)
                  const Text('Henüz taksit takvimi tanımlanmamış.'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
