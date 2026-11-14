import 'package:flutter/material.dart';

import '../../domain/models/dues_models.dart';
import '../../testing/test_id.dart';
import '../design_system/sp_status_badge.dart';
import '../design_system/sp_tone.dart';
import '../theme/app_theme.dart';

/// Compact, responsive summary row for a unit directory entry.
class UnitDirectoryRow extends StatelessWidget {
  final HomeOwnerItem unit;
  final VoidCallback onActions;
  final VoidCallback onDetails;
  final FocusNode? actionsFocusNode;
  final FocusNode? detailsFocusNode;

  const UnitDirectoryRow({
    super.key,
    required this.unit,
    required this.onActions,
    required this.onDetails,
    this.actionsFocusNode,
    this.detailsFocusNode,
  });

  String get _unitLabel => '${unit.block.trim()} ${unit.unitNo}'.trim();

  String get _statusLabel => unit.isTenantOccupied
      ? 'Kiracılı'
      : unit.isVacant
      ? 'Boş'
      : 'Malik mukim';

  SpTone get _statusTone => unit.isTenantOccupied
      ? SpTone.info
      : unit.isVacant
      ? SpTone.warning
      : SpTone.success;

  String get _residentLabel => unit.isTenantOccupied
      ? unit.tenantFullName ?? 'Kiracı bilgisi yok'
      : unit.isVacant
      ? 'Sakin kaydı yok'
      : unit.ownerFullName;

  String get _contactPhone => unit.isTenantOccupied ? unit.tenantPhone ?? '' : unit.phone;

  String get _responsibleLine => _contactPhone.isEmpty
      ? 'Sorumlu: ${unit.activeResponsibleResidentName}'
      : 'Sorumlu: ${unit.activeResponsibleResidentName} • $_contactPhone';

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 720
              ? _wideRow(context)
              : _narrowRow(context),
        ),
      ),
    );
  }

  Widget _wideRow(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 150,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _unitLabel,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                '${unit.floor}. kat${unit.houseType == null ? '' : ' • ${unit.houseType}'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        SpStatusBadge(label: _statusLabel, tone: _statusTone),
        const SizedBox(width: AppSpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _residentLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                _responsibleLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        _actions(context),
      ],
    );
  }

  Widget _narrowRow(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              _unitLabel,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              '${unit.floor}. kat',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            SpStatusBadge(label: _statusLabel, tone: _statusTone),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          _residentLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        Text(
          _responsibleLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpacing.xs),
        Align(alignment: Alignment.centerRight, child: _actions(context)),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.xs,
      children: [
        testId(
          'module_workspace_actions_${unit.unitId}',
          KeyedSubtree(
            key: Key('module_workspace_actions_${unit.unitId}'),
            child: testId(
              'module_unit_actions_${unit.unitId}',
              OutlinedButton.icon(
                key: Key('module_unit_actions_${unit.unitId}'),
                focusNode: actionsFocusNode,
                onPressed: onActions,
                icon: const Icon(Icons.bolt_outlined, size: 16),
                label: const Text('İşlemler'),
              ),
              label: '$_unitLabel işlemlerini aç',
            ),
          ),
          label: '$_unitLabel işlemlerini aç',
        ),
        testId(
          'module_workspace_info_${unit.unitId}',
          KeyedSubtree(
            key: Key('module_workspace_info_${unit.unitId}'),
            child: testId(
              'module_unit_details_${unit.unitId}',
              TextButton.icon(
                key: Key('module_unit_details_${unit.unitId}'),
                focusNode: detailsFocusNode,
                onPressed: onDetails,
                icon: const Icon(Icons.info_outline, size: 16),
                label: const Text('Detay'),
              ),
              label: '$_unitLabel detaylarını aç',
            ),
          ),
          label: '$_unitLabel detaylarını aç',
        ),
      ],
    );
  }
}
