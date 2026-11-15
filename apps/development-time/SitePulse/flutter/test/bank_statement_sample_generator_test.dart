@Tags(['finance'])
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/domain/services/bank_file_parser.dart';
import 'package:sitepulse/domain/services/bank_statement_sample_generator.dart';

void main() {
  const excelBanks = [
    BankCatalogEntry(
      code: 'KUVEYT_TURK',
      displayName: 'Kuveyt Türk Katılım Bankası',
      statementFormat: 'EXCEL',
    ),
    BankCatalogEntry(
      code: 'YAPI_KREDI',
      displayName: 'Yapı Kredi Bankası',
      statementFormat: 'EXCEL',
    ),
  ];

  for (final bank in excelBanks) {
    test(
      'generates a parser-compatible fictional workbook for ${bank.code}',
      () {
        final bytes = BankStatementSampleGenerator.create(bank);

        expect(bytes, isA<Uint8List>());
        expect(BankStatementSampleGenerator.fileName(bank), endsWith('.xlsx'));
        final rows = BankFileParser.parseBytes(
          fileName: BankStatementSampleGenerator.fileName(bank),
          bytes: bytes,
        );

        expect(rows, hasLength(1));
        expect(rows.single.rawId, 'SAMPLE-${bank.code}-001');
        expect(rows.single.description, contains('Z BLOK D:999'));
        expect(rows.single.amount.toString(), '0.01');
        expect(rows.single.isIncoming, isTrue);
      },
    );
  }

  test('rejects a bank that does not use Excel statements', () {
    const csvBank = BankCatalogEntry(
      code: 'AKBANK',
      displayName: 'Akbank',
      statementFormat: 'CSV',
    );

    expect(
      () => BankStatementSampleGenerator.create(csvBank),
      throwsArgumentError,
    );
  });
}
