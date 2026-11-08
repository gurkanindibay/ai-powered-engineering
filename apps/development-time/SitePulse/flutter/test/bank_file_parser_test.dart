@Tags(['finance'])
library;
import 'dart:io';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'test_fixtures.dart';

void main() {
  group('Real Bank Statement Ingestion Tests (Kuveyt Turk & Is Bankasi)', () {
    late DashboardController controller;

    setUp(() {
      controller = DashboardController(startAuthenticated: true);
      controller.loadTestFixtures();
    });

    test('parses Kuveyt Turk XLSX and matches resident flats with high confidence', () {
      final file = File('/home/gurkanindibay/Downloads/hesap-ekstresi.xlsx');
      expect(file.existsSync(), isTrue);

      final bytes = file.readAsBytesSync();
      controller.parseBankStatementFile(fileName: 'hesap-ekstresi.xlsx', bytes: bytes);

      expect(controller.reconciliationQueue.length, greaterThan(15));

      // 1. Alaettin Celik (1320.00 TL -> A Blok D:10)
      final matchAlaettin = controller.reconciliationQueue.firstWhere(
        (m) => m.matchedResidentName == 'Alaettin Çelik' && m.transaction.amount == Decimal.parse('1320.00'),
      );
      expect(matchAlaettin.matchedBlock, 'A');
      expect(matchAlaettin.matchedUnitNumber, 10);
      expect(matchAlaettin.confidenceScore, 100);
      expect(matchAlaettin.amountMatchesBalance, true);
      expect(matchAlaettin.status, 'ONAY_BEKLIYOR');

      // 2. Mustafa Ruzgar (715.00 TL -> B Blok D:4)
      final matchMustafa = controller.reconciliationQueue.firstWhere(
        (m) => m.matchedResidentName == 'Mustafa Rüzgar' && m.transaction.amount == Decimal.parse('715.00'),
      );
      expect(matchMustafa.matchedBlock, 'B');
      expect(matchMustafa.matchedUnitNumber, 4);
      expect(matchMustafa.confidenceScore, 100);

      // 3. Sait Sener (715.00 TL -> B Blok D:12)
      final matchSait = controller.reconciliationQueue.firstWhere(
        (m) => m.matchedResidentName == 'Sait Şener' && m.transaction.amount == Decimal.parse('715.00'),
      );
      expect(matchSait.matchedBlock, 'B');
      expect(matchSait.matchedUnitNumber, 12);
      expect(matchSait.confidenceScore, 100);

      // 4. Servet Karaca (715.00 TL -> A Blok D:6)
      final matchServet = controller.reconciliationQueue.firstWhere(
        (m) => m.matchedResidentName == 'Servet Karaca' && m.transaction.amount == Decimal.parse('715.00'),
      );
      expect(matchServet.matchedBlock, 'A');
      expect(matchServet.matchedUnitNumber, 6);
      expect(matchServet.confidenceScore, 100);

      // 5. Outgoing transfers (e.g. Abdullah haidari -14.000 TL) are flagged as GIDER
      final outgoing = controller.reconciliationQueue.where((m) => m.status == 'GIDER').toList();
      expect(outgoing.length, greaterThan(0));
    });

    test('parses Is Bankasi statement CSV/XLS and extracts operations', () {
      const isBankCsv =
          '06/08/2026-21:06:38;Bankamatik;Para Yatırma;EFEKTİF YATAN 6500********57 62.KART HESABINA PARA YATIRMA;500,00;USD\n'
          '02/08/2026-07:55:32;Bankamatik;Para Yatırma;EFEKTİF YATAN 6500********57 62.KART HESABINA PARA YATIRMA;1000,00;USD\n'
          '06/08/2026-21:07:50;İşCep;Havale;MİDAS MENKUL DEĞERLER ANONİM ŞİRKETİ*GÜRKAN İNDİBAY tarafından aktarılan;-500,00;USD';

      controller.parseBankStatement(isBankCsv);
      expect(controller.reconciliationQueue.length, 3);

      final incoming = controller.reconciliationQueue.where((m) => m.status != 'GIDER').toList();
      expect(incoming.length, 2);
      expect(incoming.any((m) => m.transaction.amount == Decimal.parse('500.00')), true);
      expect(incoming.any((m) => m.transaction.amount == Decimal.parse('1000.00')), true);
    });
  });
}
