import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/dues_models.dart';

/// Builds a parser-compatible, fictional Excel statement for a catalogued bank.
class BankStatementSampleGenerator {
  static Uint8List create(BankCatalogEntry bank) {
    if (!bank.supportsExcel) {
      throw ArgumentError.value(
        bank.statementFormat,
        'statementFormat',
        'Bank must support Excel',
      );
    }

    final strings = <String>[];
    int addString(String value) {
      strings.add(value);
      return strings.length - 1;
    }

    final rows = <String>[];
    void addRow(int number, Map<String, String> cells) {
      final xml = cells.entries.map((entry) {
        final index = addString(entry.value);
        return '<c r="${entry.key}$number" t="s"><v>$index</v></c>';
      }).join();
      rows.add('<row r="$number">$xml</row>');
    }

    addRow(1, {'A': '${bank.displayName} - Örnek Hesap Ekstresi'});
    addRow(3, {'A': 'Bilgilendirme', 'B': 'Tamamen kurgusal örnek veridir'});
    addRow(16, {'B': 'Tarih', 'C': 'Referans', 'D': 'Açıklama', 'E': 'Tutar'});
    addRow(17, {
      'B': '15.10.2026',
      'C': 'SAMPLE-${bank.code}-001',
      'D': 'ÖRNEK İŞLEM - Z BLOK D:999 - GERÇEK SAKİN VE HESAP DEĞİLDİR',
      'E': '0,01',
    });

    final sheetXml =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetData>${rows.join()}</sheetData></worksheet>';
    final sharedStringsXml =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'count="${strings.length}" uniqueCount="${strings.length}">'
        '${strings.map((value) => '<si><t>${_xmlEscape(value)}</t></si>').join()}'
        '</sst>';

    final archive = Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', _contentTypes))
      ..addFile(ArchiveFile.string('_rels/.rels', _rootRelationships))
      ..addFile(ArchiveFile.string('xl/workbook.xml', _workbook))
      ..addFile(
        ArchiveFile.string(
          'xl/_rels/workbook.xml.rels',
          _workbookRelationships,
        ),
      )
      ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', sheetXml))
      ..addFile(ArchiveFile.string('xl/sharedStrings.xml', sharedStringsXml));

    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static String fileName(BankCatalogEntry bank) =>
      '${_safeCode(bank.code)}_ornek_ekstre.xlsx';

  static String _safeCode(String code) =>
      code.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  static String _xmlEscape(String value) => const HtmlEscape().convert(value);

  static const String _contentTypes =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
</Types>''';

  static const String _rootRelationships =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''';

  static const String _workbook =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="Hesap Hareketleri" sheetId="1" r:id="rId1"/></sheets>
</workbook>''';

  static const String _workbookRelationships =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
</Relationships>''';
}
