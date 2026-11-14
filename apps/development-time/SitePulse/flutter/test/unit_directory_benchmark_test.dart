import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/ui/residents/resident_directory.dart';

HomeOwnerItem _unit(int number) => HomeOwnerItem(
  unitId: 'unit-$number',
  siteId: 'site-1',
  block: 'A Blok',
  unitNo: number,
  floor: number % 8,
  ownerFullName: 'Owner $number',
  email: '',
  phone: '+90 555 000 ${number.toString().padLeft(4, '0')}',
  landShare: '1/10000',
  monthlyDues: Decimal.zero,
  isResident: false,
  mustChangePassword: false,
  createdAt: DateTime(2026),
  occupancyStatus: 'TENANT_OCCUPIED',
  tenantFullName: 'Resident $number',
);

void main() {
  test('benchmark local directory search and sort at 1k and 10k units', () {
    for (final count in [1000, 10000]) {
      final units = List<HomeOwnerItem>.generate(count, _unit);
      final timings = <int>[];
      var result = <HomeOwnerItem>[];

      for (var sample = 0; sample < 6; sample++) {
        final stopwatch = Stopwatch()..start();
        result = units
            .where((unit) => matchesResidentFilters(unit, query: 'resident'))
            .toList()
          ..sort(compareUnitDirectoryItems);
        stopwatch.stop();
        if (sample > 0) timings.add(stopwatch.elapsedMicroseconds);
      }

      timings.sort();
      final medianMicroseconds = timings[timings.length ~/ 2];
      // ignore: avoid_print
      print('UNIT_DIRECTORY_BENCHMARK units=$count median_us=$medianMicroseconds');
      expect(result, hasLength(count));
    }
  });
}
