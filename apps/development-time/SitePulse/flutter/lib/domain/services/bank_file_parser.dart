import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:decimal/decimal.dart';

import '../formatting/money_formatter.dart';

class ParsedBankRow {
  final String rawId;
  final DateTime date;
  final Decimal amount;
  final String description;
  final String? senderName;
  final String? paymentNote;
  final bool isIncoming;

  ParsedBankRow({
    required this.rawId,
    required this.date,
    required this.amount,
    required this.description,
    this.senderName,
    this.paymentNote,
    this.isIncoming = true,
  });
}

class BankFileParser {
  /// Parses raw bytes of .xlsx, .xls, or text/csv bank statements.
  static List<ParsedBankRow> parseBytes({
    required String fileName,
    required Uint8List bytes,
  }) {
    final lowerName = fileName.toLowerCase();
    if (lowerName.endsWith('.xlsx')) {
      return parseXlsxBytes(bytes);
    } else {
      // Plain text, CSV, or exported XLS text
      final text = utf8.decode(bytes, allowMalformed: true);
      return parseText(text);
    }
  }

  /// Parses OpenXML XLSX binary (e.g. Kuveyt Türk hesap-ekstresi.xlsx)
  static List<ParsedBankRow> parseXlsxBytes(Uint8List bytes) {
    final List<ParsedBankRow> results = [];
    try {
      final archive = ZipDecoder().decodeBytes(bytes);

      // 1. Shared Strings
      final sharedStrings = <String>[];
      final sharedFile = archive.findFile('xl/sharedStrings.xml');
      if (sharedFile != null) {
        final xmlStr = utf8.decode(sharedFile.content as List<int>, allowMalformed: true);
        final siReg = RegExp(r'<si>(.*?)</si>', dotAll: true);
        final tReg = RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true);
        for (final siMatch in siReg.allMatches(xmlStr)) {
          final block = siMatch.group(1) ?? '';
          final textParts = tReg.allMatches(block).map((m) => m.group(1) ?? '').join();
          sharedStrings.add(textParts);
        }
      }

      // 2. Worksheet sheet1.xml
      final sheetFile = archive.findFile('xl/worksheets/sheet1.xml');
      if (sheetFile == null) return results;

      final sheetXml = utf8.decode(sheetFile.content as List<int>, allowMalformed: true);
      final rowReg = RegExp(r'<row\s+r="(\d+)"[^>]*>(.*?)</row>', dotAll: true);
      final cReg = RegExp(r'<c\s+([^>]+)>(.*?)</c>', dotAll: true);

      for (final rowMatch in rowReg.allMatches(sheetXml)) {
        final rowNum = int.parse(rowMatch.group(1)!);
        if (rowNum < 17) continue; // Skip account headers

        final rowContent = rowMatch.group(2) ?? '';
        final cellMap = <String, String>{};

        for (final cMatch in cReg.allMatches(rowContent)) {
          final attrs = cMatch.group(1)!;
          final body = cMatch.group(2) ?? '';

          final colMatch = RegExp(r'r="([A-Z]+)\d+"').firstMatch(attrs);
          if (colMatch == null) continue;
          final col = colMatch.group(1)!;

          final isShared = attrs.contains('t="s"');
          final vMatch = RegExp(r'<v>(.*?)</v>').firstMatch(body);
          final rawVal = vMatch?.group(1) ?? '';

          String finalVal = rawVal;
          if (isShared && int.tryParse(rawVal) != null) {
            final idx = int.parse(rawVal);
            if (idx < sharedStrings.length) {
              finalVal = sharedStrings[idx];
            }
          }
          cellMap[col] = finalVal.trim();
        }

        // Kuveyt Turk specific columns:
        // Col B: Date (Excel serial like 46216)
        // Col C: Reference Code (e.g. A07MY)
        // Col D: Description
        // Col E: Amount
        final dateVal = cellMap['B'] ?? cellMap['A'] ?? '';
        final refCode = cellMap['C'] ?? cellMap['B'] ?? 'TXN-$rowNum';
        final desc = cellMap['D'] ?? cellMap['C'] ?? '';
        final amtStr = cellMap['E'] ?? cellMap['D'] ?? '';

        if (desc.isEmpty || amtStr.isEmpty) continue;
        if (desc.toLowerCase().contains('devir bakiyesi') || desc.toLowerCase().contains('açıklama')) {
          continue;
        }

        // Parse date (Excel date serial or DD.MM.YYYY)
        DateTime parsedDate = DateTime.now();
        final intDate = int.tryParse(dateVal);
        if (intDate != null && intDate > 30000 && intDate < 60000) {
          // Excel epoch: Dec 30 1899
          parsedDate = DateTime(1899, 12, 30).add(Duration(days: intDate));
        } else if (dateVal.contains('.')) {
          final parts = dateVal.split('.');
          if (parts.length == 3) {
            parsedDate = DateTime(
              int.tryParse(parts[2]) ?? 2026,
              int.tryParse(parts[1]) ?? 9,
              int.tryParse(parts[0]) ?? 1,
            );
          }
        }

        // Parse amount
        // Text cells use Turkish grouping (`1.423,33`); numeric cells use a
        // plain dot (`1423.33`). parseAmount handles both.
        final unsignedAmt = parseAmount(amtStr);
        if (unsignedAmt == null) continue;
        final amt = amtStr.trim().startsWith('-') ? -unsignedAmt : unsignedAmt;

        // Extract sender name from Turkish bank format:
        // e.g. "Para Transferi, Gönderen: ALAETTİN ÇELİK  , Alıcı: GÜRKAN İNDİBAY..."
        // e.g. "sait - Gönderen:SAİT ŞENER, Alıcı:gürkan indibay, FAST..."
        String? sender;
        final senderMatch = RegExp(r'Gönderen:\s*([A-ZÇĞİÖŞÜa-zçğıöşü\s]+?)(?:,|\*|Alıcı:|$)', caseSensitive: false)
            .firstMatch(desc);
        if (senderMatch != null) {
          sender = senderMatch.group(1)!.trim();
        }

        // Extract payment note
        String? note;
        if (desc.contains(' - Gönderen:')) {
          note = desc.split(' - Gönderen:').first.trim();
        }

        final isIncoming = amt > Decimal.zero;

        results.add(ParsedBankRow(
          rawId: refCode.isNotEmpty ? refCode : 'KT-$rowNum',
          date: parsedDate,
          amount: amt.abs(),
          description: desc,
          senderName: sender,
          paymentNote: note,
          isIncoming: isIncoming,
        ));
      }
    } catch (e) {
      // Fallback
    }

    return results;
  }

  /// Normalises a statement amount (`1.423,33`, `1423,33`, `1423.33`,
  /// `₺1.423,33`) with the shared [MoneyFormatter.tryParse] rule.
  static Decimal? parseAmount(String raw) => MoneyFormatter.tryParse(raw.replaceAll('-', ''));

  /// True when [content] carries SWIFT MT940 transaction tags.
  static bool isMt940(String content) => content.contains(':61:') && content.contains(':86:');

  static final _mt940Line61 = RegExp(
    r':61:\s*(\d{2})(\d{2})(\d{2})(?:\d{4})?(RC|RD|CR|DR|C|D)[A-Z]?([0-9]+,[0-9]{0,2})([^\n]*)',
  );
  static final _mt940Line86 = RegExp(r':86:\s*(.+?)(?=(?:\r?\n:[0-9]{2}[A-Z]?:)|\r?\n-\s*$|$)', dotAll: true);

  /// Parses every `:61:` statement line of an MT940 statement, pairing it with
  /// the `:86:` narrative that follows it.
  ///
  /// `C`/`CR`/`RD` entries are credits (incoming); `D`/`DR`/`RC` are debits.
  /// The value date (`YYMMDD`) becomes [ParsedBankRow.date]; the bank
  /// reference after `//` becomes [ParsedBankRow.rawId] when present.
  static List<ParsedBankRow> parseMt940(String content) {
    final results = <ParsedBankRow>[];
    final entries = _mt940Line61.allMatches(content).toList();
    for (var i = 0; i < entries.length; i++) {
      final m61 = entries[i];
      final rawAmount = m61.group(5)!;
      // MT940 allows a bare trailing comma (`1423,` means 1423,00).
      final amount = parseAmount(rawAmount.endsWith(',') ? '${rawAmount}00' : rawAmount);
      if (amount == null) continue;

      final nextStart = i + 1 < entries.length ? entries[i + 1].start : content.length;
      final m86 = _mt940Line86.firstMatch(content.substring(m61.end, nextStart));
      final narrative = (m86?.group(1) ?? '').replaceAll(RegExp(r'\s*\r?\n\s*'), ' ').trim();

      final mark = m61.group(4)!;
      final isIncoming = mark == 'C' || mark == 'CR' || mark == 'RD';
      final tail = m61.group(6) ?? '';
      final refIndex = tail.indexOf('//');
      final reference = refIndex >= 0 ? tail.substring(refIndex + 2).trim() : '';

      final year = 2000 + int.parse(m61.group(1)!);
      final date = DateTime(year, int.parse(m61.group(2)!), int.parse(m61.group(3)!));

      String? sender;
      final senderMatch = RegExp(r'Gönderen:\s*([A-ZÇĞİÖŞÜa-zçğıöşü\s]+?)(?:,|\*|Alıcı:|$)', caseSensitive: false)
          .firstMatch(narrative);
      if (senderMatch != null) sender = senderMatch.group(1)!.trim();

      results.add(ParsedBankRow(
        rawId: reference.isNotEmpty ? reference : 'TXN-MT940-${(i + 1).toString().padLeft(3, '0')}',
        date: date,
        amount: amount,
        description: narrative.isNotEmpty ? narrative : tail.trim(),
        senderName: sender,
        isIncoming: isIncoming,
      ));
    }
    return results;
  }

  /// Parses MT940, CSV/TSV, or free-form statement text.
  static List<ParsedBankRow> parseText(String content) {
    if (isMt940(content)) return parseMt940(content);
    final List<ParsedBankRow> results = [];
    final lines = content.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

    int rowIdx = 1;
    for (final line in lines) {
      final lower = line.toLowerCase();
      // Skip header lines
      if ((lower.contains('tarih') || lower.contains('date')) &&
          (lower.contains('tutar') || lower.contains('bakiye') || lower.contains('alacak'))) {
        continue;
      }
      if (lower.contains('müşteri numarası') || lower.contains('büyük mükellefler') || lower.contains('hesap özeti')) {
        continue;
      }

      // Check delimiter
      String? delim;
      if (line.contains('\t')) {
        delim = '\t';
      } else if (line.contains(';')) {
        delim = ';';
      } else if (line.contains(',') && line.split(',').length >= 4) {
        delim = ',';
      }

      if (delim != null) {
        final cols = line.split(delim).map((c) => c.replaceAll('"', '').trim()).toList();
        if (cols.length >= 3) {
          // Look for amount column
          Decimal? foundAmt;
          String desc = '';
          String ref = 'TXN-$rowIdx';
          DateTime date = DateTime.now();

          for (int i = 0; i < cols.length; i++) {
            final col = cols[i];
            if (foundAmt == null) {
              final amtReg = RegExp(r'^-?\s*([0-9]{1,3}(?:\.[0-9]{3})*,[0-9]{2}|[0-9]+[.,][0-9]{2}|[0-9]+)$');
              if (amtReg.hasMatch(col.replaceAll('₺', '').trim())) {
                final clean = col.replaceAll(' ', '').trim();
                final isNeg = clean.startsWith('-');
                final val = parseAmount(clean);
                if (val != null && val > Decimal.zero) {
                  foundAmt = isNeg ? -val : val;
                }
              }
            }

            if (col.length > desc.length && !col.contains('2026-') && !col.startsWith('TR')) {
              desc = col;
            }
            if (col.length > 10 && col.contains(RegExp(r'^\d+$'))) {
              ref = col;
            }
          }

          if (foundAmt != null && desc.isNotEmpty) {
            String? sender;
            final senderMatch = RegExp(r'Gönderen:\s*([A-ZÇĞİÖŞÜa-zçğıöşü\s]+?)(?:,|\*|Alıcı:|$)', caseSensitive: false)
                .firstMatch(desc);
            if (senderMatch != null) {
              sender = senderMatch.group(1)!.trim();
            }

            results.add(ParsedBankRow(
              rawId: ref,
              date: date,
              amount: foundAmt.abs(),
              description: desc,
              senderName: sender,
              isIncoming: foundAmt > Decimal.zero,
            ));
            rowIdx++;
            continue;
          }
        }
      }

      // Free-form regex extraction
      final amtReg = RegExp(r'₺?\s*([0-9]{1,3}(?:\.[0-9]{3})*,[0-9]{2}|[0-9]+[.,][0-9]{2})');
      final amtMatch = amtReg.firstMatch(line);
      if (amtMatch != null) {
        final amt = parseAmount(amtMatch.group(1)!);
        if (amt == null) continue;

        String? sender;
        final senderMatch = RegExp(r'Gönderen:\s*([A-ZÇĞİÖŞÜa-zçğıöşü\s]+?)(?:,|\*|Alıcı:|$)', caseSensitive: false)
            .firstMatch(line);
        if (senderMatch != null) {
          sender = senderMatch.group(1)!.trim();
        }

        results.add(ParsedBankRow(
          rawId: 'LINE-$rowIdx',
          date: DateTime.now(),
          amount: amt,
          description: line,
          senderName: sender,
          isIncoming: !line.contains(' -500') && !line.contains('-1000') && !line.contains('-14.000'),
        ));
        rowIdx++;
      }
    }

    return results;
  }
}
