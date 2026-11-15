import 'package:flutter/material.dart';

import '../../domain/models/dues_models.dart';
import '../components/sp_dialog_pages.dart';
import '../dashboard/dashboard_controller.dart';
import '../design_system/sp_feedback.dart';

class _ResponsibleChoice {
  final String name;
  final String role;
  final String phone;
  final String email;
  final String? memberId;
  final int? personId;

  const _ResponsibleChoice(
    this.name,
    this.role,
    this.phone,
    this.email, {
    this.memberId,
    this.personId,
  });

  String get label => switch (role) {
    'OWNER' => '$name • Kat Maliki',
    'TENANT' => '$name • Kiracı',
    _ => '$name • Hane Sakini',
  };
}

/// Both resident screens save the same designation and await the server result.
Future<void> showResponsibleContactSelection(
  BuildContext context,
  DashboardController controller,
  HomeOwnerItem unit,
) async {
  // Person cards identify the contact; the active occupancy rows carry the owner and tenant ids.
  final history = await controller.fetchOccupancyHistory(unit.unitId);
  if (!context.mounted) return;
  int? activePersonId(DebtorType role) => history
      .where((h) => h.isActive && h.debtorRole == role && h.personId > 0)
      .map((h) => h.personId)
      .firstOrNull;
  final choices = [
    _ResponsibleChoice(
      unit.ownerFullName,
      'OWNER',
      unit.phone,
      unit.email,
      personId: activePersonId(DebtorType.owner),
    ),
    if (unit.isTenantOccupied && unit.tenantFullName?.isNotEmpty == true)
      _ResponsibleChoice(
        unit.tenantFullName!,
        'TENANT',
        unit.tenantPhone ?? '',
        unit.tenantEmail ?? '',
        personId: activePersonId(DebtorType.tenant),
      ),
    for (final member in unit.householdResidents)
      _ResponsibleChoice(
        member.fullName,
        'RESIDENT',
        member.phone,
        member.email,
        memberId: member.id,
        personId: member.personId,
      ),
  ];
  final role =
      unit.primaryResponsibleRole ??
      (unit.isTenantOccupied ? 'TENANT' : 'OWNER');
  final selected = choices
      .where(
        (choice) =>
            choice.role == role &&
            (role != 'RESIDENT' ||
                (unit.primaryResponsibleMemberId != null
                    ? choice.memberId == unit.primaryResponsibleMemberId
                    : choice.name == unit.primaryResponsibleName)),
      )
      .firstOrNull;
  final choice = await showSpSelection<_ResponsibleChoice>(
    context: context,
    title: 'Aktif Sorumlu Sakini Belirle',
    options: choices,
    selected: selected,
    labelOf: (choice) => choice.label,
    idOf: (choice) =>
        'responsible_contact_${choice.role}_${choice.memberId ?? unit.unitId}',
  );
  if (choice == null || !context.mounted) return;
  if (identical(choice, selected)) {
    SpToast.info(context, '${choice.name} zaten aktif sorumlu.');
    return;
  }
  final saved = await controller.setPrimaryResponsibleResident(
    unitId: unit.unitId,
    siteId: unit.siteId,
    residentName: choice.name,
    role: choice.role,
    phone: choice.phone,
    email: choice.email,
    memberId: choice.memberId,
    personId: choice.personId,
  );
  if (!context.mounted) return;
  if (saved) {
    SpToast.success(context, '${choice.name} aktif sorumlu olarak belirlendi.');
  } else {
    SpToast.error(
      context,
      'Sorumlu kişi kaydedilemedi. Lütfen tekrar deneyin.',
    );
  }
}
