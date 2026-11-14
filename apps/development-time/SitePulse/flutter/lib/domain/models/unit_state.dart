/// Unit ownership and occupancy state model (EPIC-08 §3).
///
/// Mirrors `backend/src/domain/unit_state.rs`: the screens offer only the
/// commands that are legal for a unit's state (STORY-08-07), and the server
/// remains the authority that accepts or rejects each one.
library;

import 'package:decimal/decimal.dart';

import '../formatting/json_decimal.dart';
import 'dues_models.dart';

/// A guarded occupancy command; [code] is the API value.
enum OccupancyCommand {
  tenantMoveIn('TENANT_MOVE_IN', 'Kiracı Girişi'),
  ownerMoveIn('OWNER_MOVE_IN', 'Kat Maliki Taşınsın'),
  moveOut('MOVE_OUT', 'Tahliye'),
  replaceTenant('REPLACE_TENANT', 'Kiracı Değişikliği'),
  ownerRentsOut('OWNER_RENTS_OUT', 'Daireyi Kiraya Ver'),
  ownerTakesBack('OWNER_TAKES_BACK', 'Kat Maliki Geri Alsın'),
  titleTransfer('TITLE_TRANSFER', 'Mülk Devri');

  final String code;
  final String label;
  const OccupancyCommand(this.code, this.label);

  static OccupancyCommand? fromCode(String? code) {
    for (final command in values) {
      if (command.code == code) return command;
    }
    return null;
  }

  /// The command opens a tenant session, so it needs the incoming tenant.
  bool get needsTenant => this == tenantMoveIn || this == replaceTenant || this == ownerRentsOut;

  /// The command opens an owner session for an owner on record.
  bool get opensOwnerSession => this == ownerMoveIn || this == ownerTakesBack;
}

/// The occupancy commands legal for a unit (§3.3). [hasOwner] is whether the
/// unit has an owner on record; a unit without one only takes an owner
/// registration, or lets a legacy tenant move out.
List<OccupancyCommand> allowedOccupancyCommands({
  required OccupancyStatus occupancy,
  required bool hasOwner,
}) {
  if (!hasOwner) {
    return occupancy == OccupancyStatus.tenantOccupied ? const [OccupancyCommand.moveOut] : const [];
  }
  switch (occupancy) {
    case OccupancyStatus.vacant:
      return const [OccupancyCommand.tenantMoveIn, OccupancyCommand.ownerMoveIn, OccupancyCommand.titleTransfer];
    case OccupancyStatus.ownerOccupied:
      return const [OccupancyCommand.moveOut, OccupancyCommand.ownerRentsOut, OccupancyCommand.titleTransfer];
    case OccupancyStatus.tenantOccupied:
      return const [
        OccupancyCommand.moveOut,
        OccupancyCommand.replaceTenant,
        OccupancyCommand.ownerTakesBack,
        OccupancyCommand.titleTransfer,
      ];
  }
}

extension HomeOwnerItemCommands on HomeOwnerItem {
  /// The effective occupancy, counting a recorded tenant as tenant-occupied.
  OccupancyStatus get effectiveOccupancy => isTenantOccupied ? OccupancyStatus.tenantOccupied : occupancy;

  List<OccupancyCommand> get allowedCommands =>
      allowedOccupancyCommands(occupancy: effectiveOccupancy, hasOwner: ownerFullName.trim().isNotEmpty);

  bool allows(OccupancyCommand command) => allowedCommands.contains(command);
}

/// An owner on record of a unit.
class UnitOwnerOnRecord {
  final int personId;
  final String fullName;
  final Decimal sharePercentage;

  const UnitOwnerOnRecord({required this.personId, required this.fullName, required this.sharePercentage});

  factory UnitOwnerOnRecord.fromJson(Map<String, dynamic> json) => UnitOwnerOnRecord(
        personId: (json['person_id'] as num?)?.toInt() ?? 0,
        fullName: json['full_name']?.toString() ?? '',
        sharePercentage: readDecimal(json, 'share_percentage', fallback: Decimal.fromInt(100)),
      );
}

/// A unit's state as the server reports it (`GET .../occupancy-state`).
class UnitOccupancyState {
  final String ownership;
  final OccupancyStatus occupancy;
  final List<UnitOwnerOnRecord> owners;
  final String? occupantName;
  final List<OccupancyCommand> allowedCommands;

  const UnitOccupancyState({
    required this.ownership,
    required this.occupancy,
    required this.owners,
    required this.allowedCommands,
    this.occupantName,
  });

  factory UnitOccupancyState.fromJson(Map<String, dynamic> json) {
    final occupant = json['occupant'];
    return UnitOccupancyState(
      ownership: json['ownership']?.toString() ?? 'UNOWNED',
      occupancy: OccupancyStatus.fromCode(json['occupancy']?.toString()),
      owners: (json['owners'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(UnitOwnerOnRecord.fromJson)
          .toList(),
      occupantName: occupant is Map<String, dynamic> ? occupant['full_name']?.toString() : null,
      allowedCommands: (json['allowed_commands'] as List<dynamic>? ?? const [])
          .map((c) => OccupancyCommand.fromCode(c?.toString()))
          .whereType<OccupancyCommand>()
          .toList(),
    );
  }

  /// The state a home-owner row implies, for demonstration storage.
  factory UnitOccupancyState.fromHomeOwner(HomeOwnerItem ho) => UnitOccupancyState(
        ownership: ho.ownerFullName.trim().isEmpty ? 'UNOWNED' : 'OWNED',
        occupancy: ho.effectiveOccupancy,
        owners: [
          if (ho.ownerFullName.trim().isNotEmpty)
            UnitOwnerOnRecord(personId: 0, fullName: ho.ownerFullName, sharePercentage: Decimal.fromInt(100)),
        ],
        occupantName: ho.isVacant ? null : ho.activeResponsibleResidentName,
        allowedCommands: ho.allowedCommands,
      );
}

/// The result of a transition request: success, or the server's reason.
class OccupancyTransitionResult {
  final bool ok;
  final String? message;

  const OccupancyTransitionResult.success()
      : ok = true,
        message = null;
  const OccupancyTransitionResult.failure(this.message) : ok = false;
}
