// EPIC-08 §3.3: the screens offer only the commands legal for a unit's state.
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/domain/models/unit_state.dart';

void main() {
  group('allowedOccupancyCommands', () {
    test('a vacant owned unit takes a tenant or the owner on record', () {
      expect(allowedOccupancyCommands(occupancy: OccupancyStatus.vacant, hasOwner: true), [
        OccupancyCommand.tenantMoveIn,
        OccupancyCommand.ownerMoveIn,
        OccupancyCommand.titleTransfer,
      ]);
    });

    test('an owner-occupied unit can be vacated or rented out, not moved into', () {
      final commands = allowedOccupancyCommands(occupancy: OccupancyStatus.ownerOccupied, hasOwner: true);
      expect(commands, [OccupancyCommand.moveOut, OccupancyCommand.ownerRentsOut, OccupancyCommand.titleTransfer]);
      expect(commands, isNot(contains(OccupancyCommand.tenantMoveIn)));
      expect(commands, isNot(contains(OccupancyCommand.ownerMoveIn)));
    });

    test('a tenant-occupied unit offers the compound moves', () {
      expect(allowedOccupancyCommands(occupancy: OccupancyStatus.tenantOccupied, hasOwner: true), [
        OccupancyCommand.moveOut,
        OccupancyCommand.replaceTenant,
        OccupancyCommand.ownerTakesBack,
        OccupancyCommand.titleTransfer,
      ]);
    });

    test('a unit without an owner on record takes no move-in (decision A2)', () {
      expect(allowedOccupancyCommands(occupancy: OccupancyStatus.vacant, hasOwner: false), isEmpty);
      expect(allowedOccupancyCommands(occupancy: OccupancyStatus.tenantOccupied, hasOwner: false), [OccupancyCommand.moveOut]);
    });
  });

  test('UnitOccupancyState reads the server response', () {
    final state = UnitOccupancyState.fromJson({
      'unit_id': 14,
      'ownership': 'OWNED',
      'occupancy': 'VACANT',
      'owners': [
        {'person_id': 4, 'full_name': 'Ahmet Yılmaz', 'share_percentage': '50.00'},
        {'person_id': 5, 'full_name': 'Ayşe Yılmaz', 'share_percentage': '50.00'},
      ],
      'occupant': null,
      'allowed_commands': ['TENANT_MOVE_IN', 'OWNER_MOVE_IN', 'TITLE_TRANSFER', 'UNKNOWN'],
    });
    expect(state.occupancy, OccupancyStatus.vacant);
    expect(state.owners.map((o) => o.fullName), ['Ahmet Yılmaz', 'Ayşe Yılmaz']);
    expect(state.owners.first.sharePercentage.toString(), '50');
    expect(state.allowedCommands, [OccupancyCommand.tenantMoveIn, OccupancyCommand.ownerMoveIn, OccupancyCommand.titleTransfer]);
  });
}
