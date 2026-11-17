import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'person_directory_api.dart';

/// Excel (.xlsx) support for the person import: reads the first worksheet into the
/// semicolon CSV text the import API takes, and builds the Excel template.
class PersonImportXlsx {
  const PersonImportXlsx._();

  static const templateFileName = 'kisi_sablonu.xlsx';
  static const templateMime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

  /// One example row, same as the CSV template.
  static const exampleRow = [
    'A Blok', '12', '3', 'Ayşe Yılmaz', 'ayse@ornek.com', '0532 123 45 67', '24', '1.250,00', 'evet', '', '', '',
  ];

  /// Whether [name] looks like an Excel workbook.
  static bool isXlsx(String name) => name.toLowerCase().endsWith('.xlsx');

  /// Converts the first worksheet to CSV text (`;` separated, quoted when needed).
  ///
  /// Throws [FormatException] when [bytes] is not a readable workbook.
  static String toCsv(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('Geçerli bir Excel (.xlsx) dosyası değil.');
    }
    final sheet = archive.findFile('xl/worksheets/sheet1.xml') ??
        archive.files.where((f) => f.isFile && f.name.startsWith('xl/worksheets/') && f.name.endsWith('.xml')).firstOrNull;
    if (sheet == null) throw const FormatException('Excel dosyasında sayfa bulunamadı.');

    final shared = <String>[];
    final sharedFile = archive.findFile('xl/sharedStrings.xml');
    if (sharedFile != null) {
      final xml = _text(sharedFile);
      for (final si in RegExp(r'<si>(.*?)</si>', dotAll: true).allMatches(xml)) {
        shared.add(RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true)
            .allMatches(si.group(1) ?? '')
            .map((m) => _unescape(m.group(1) ?? ''))
            .join());
      }
    }

    final rows = <List<String>>[];
    final rowRe = RegExp(r'<row\b[^>]*?(?:/>|>(.*?)</row>)', dotAll: true);
    final cellRe = RegExp(r'<c\b([^>]*?)(?:/>|>(.*?)</c>)', dotAll: true);
    for (final row in rowRe.allMatches(_text(sheet))) {
      final cells = <int, String>{};
      for (final c in cellRe.allMatches(row.group(1) ?? '')) {
        final attrs = c.group(1) ?? '';
        final body = c.group(2) ?? '';
        final ref = RegExp(r'\br="([A-Z]+)\d+"').firstMatch(attrs)?.group(1);
        if (ref == null) continue;
        final type = RegExp(r'\bt="(\w+)"').firstMatch(attrs)?.group(1);
        final raw = RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(body)?.group(1);
        String value;
        if (type == 's') {
          final i = int.tryParse(raw ?? '');
          value = i != null && i < shared.length ? shared[i] : '';
        } else if (type == 'inlineStr') {
          value = RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).allMatches(body).map((m) => _unescape(m.group(1) ?? '')).join();
        } else {
          value = _unescape(raw ?? '');
        }
        cells[_columnIndex(ref)] = value.trim();
      }
      if (cells.isEmpty) continue;
      final width = cells.keys.reduce((a, b) => a > b ? a : b) + 1;
      rows.add([for (var i = 0; i < width; i++) cells[i] ?? '']);
    }
    final width = rows.isEmpty ? 0 : rows.first.length;
    return rows
        .map((r) => [...r, for (var i = r.length; i < width; i++) ''].map(_csvCell).join(';'))
        .join('\n');
  }

  /// The template workbook: the import columns and one example row.
  static Uint8List buildTemplate() {
    final strings = <String>[];
    String row(int n, List<String> values) {
      final cells = StringBuffer();
      for (var i = 0; i < values.length; i++) {
        if (values[i].isEmpty) continue;
        strings.add(values[i]);
        cells.write('<c r="${_columnName(i)}$n" t="s"><v>${strings.length - 1}</v></c>');
      }
      return '<row r="$n">$cells</row>';
    }

    final sheetData = row(1, personImportColumns) + row(2, exampleRow);
    final sheetXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<cols><col min="1" max="12" width="20" customWidth="1"/></cols>'
        '<sheetData>$sheetData</sheetData></worksheet>';
    final sst = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'count="${strings.length}" uniqueCount="${strings.length}">'
        '${strings.map((s) => '<si><t>${const HtmlEscape().convert(s)}</t></si>').join()}</sst>';
    final archive = Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', _contentTypes))
      ..addFile(ArchiveFile.string('_rels/.rels', _rootRels))
      ..addFile(ArchiveFile.string('xl/workbook.xml', _workbook))
      ..addFile(ArchiveFile.string('xl/_rels/workbook.xml.rels', _workbookRels))
      ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', sheetXml))
      ..addFile(ArchiveFile.string('xl/sharedStrings.xml', sst));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static String _text(ArchiveFile f) => utf8.decode(f.content as List<int>, allowMalformed: true);

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  static String _csvCell(String v) =>
      v.contains(RegExp(r'[;"\n\r]')) ? '"${v.replaceAll('"', '""')}"' : v;

  static int _columnIndex(String ref) {
    var n = 0;
    for (final c in ref.codeUnits) {
      n = n * 26 + (c - 64);
    }
    return n - 1;
  }

  static String _columnName(int index) {
    var n = index + 1;
    var s = '';
    while (n > 0) {
      s = String.fromCharCode(65 + (n - 1) % 26) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  static const _contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
      '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
      '</Types>';
  static const _rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      '</Relationships>';
  static const _workbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets><sheet name="Kisiler" sheetId="1" r:id="rId1"/></sheets></workbook>';
  static const _workbookRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>'
      '</Relationships>';
}
