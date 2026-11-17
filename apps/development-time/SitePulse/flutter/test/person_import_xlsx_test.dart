@Tags(['residents'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/services/person_directory_api.dart';
import 'package:sitepulse/domain/services/person_import_xlsx.dart';

void main() {
  // covers: SC-12-09-01
  test('the Excel template reads back as the import columns plus one example row', () {
    final csv = PersonImportXlsx.toCsv(PersonImportXlsx.buildTemplate());
    final lines = csv.split('\n');
    expect(lines, hasLength(2));
    expect(lines.first.split(';'), personImportColumns);
    expect(lines[1], startsWith('A Blok;12;3;Ayşe Yılmaz;ayse@ornek.com;'));
    expect(lines[1].split(';'), hasLength(12));
  });

  // covers: SC-12-09-02
  test('a file that is not a workbook is rejected', () {
    expect(() => PersonImportXlsx.toCsv(PersonImportXlsx.buildTemplate().sublist(0, 10)), throwsFormatException);
  });

  test('only .xlsx names are treated as Excel', () {
    expect(PersonImportXlsx.isXlsx('Kisiler.XLSX'), isTrue);
    expect(PersonImportXlsx.isXlsx('kisiler.csv'), isFalse);
  });
}
