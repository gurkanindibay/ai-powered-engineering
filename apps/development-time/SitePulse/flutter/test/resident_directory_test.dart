import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/ui/residents/resident_directory.dart';

HomeOwnerItem _unit({
  required String id,
  required String block,
  required int number,
  String? tenant,
  String phone = '',
}) => HomeOwnerItem(
  unitId: id,
  siteId: 'site-1',
  block: block,
  unitNo: number,
  floor: 1,
  ownerFullName: 'Owner $number',
  email: '',
  phone: phone,
  landShare: '1/10',
  monthlyDues: Decimal.zero,
  isResident: false,
  mustChangePassword: false,
  createdAt: DateTime(2026),
  occupancyStatus: tenant == null ? 'OWNER_OCCUPIED' : 'TENANT_OCCUPIED',
  tenantFullName: tenant,
);

void main() {
  // covers: SC-12-02-05
  test('when unit rows are sorted then numeric unit order and Turkish search are preserved', () {
    final units = [
      _unit(id: 'a-10', block: 'A Blok', number: 10),
      _unit(
        id: 'a-2',
        block: 'A Blok',
        number: 2,
        tenant: 'Ayşe Yılmaz',
        phone: '0533 444 55 66',
      ),
      _unit(id: 'b-1', block: 'B Blok', number: 1),
    ]..sort(compareUnitDirectoryItems);

    expect(units.map((unit) => unit.unitId), ['a-2', 'a-10', 'b-1']);
    expect(matchesResidentFilters(units.first, query: 'AYSE YILMAZ'), isTrue);
    expect(matchesResidentFilters(units.first, query: '5334445566'), isTrue);
  });

  test('when a unit filter is active then only matching occupancy remains', () {
    final tenant = _unit(
      id: 'tenant',
      block: 'A',
      number: 1,
      tenant: 'Resident',
    );
    final owner = _unit(id: 'owner', block: 'A', number: 2);

    expect(
      matchesResidentFilters(tenant, occupancyFilter: OccupancyFilter.tenant),
      isTrue,
    );
    expect(
      matchesResidentFilters(owner, occupancyFilter: OccupancyFilter.tenant),
      isFalse,
    );
  });
}
