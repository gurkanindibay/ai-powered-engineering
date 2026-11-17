@Tags(['ui'])
library;
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sitepulse/domain/formatting/json_decimal.dart';
import 'package:sitepulse/domain/formatting/money_formatter.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/domain/models/person_ref.dart';
import 'package:sitepulse/domain/repositories/person_repository.dart';
import 'package:sitepulse/domain/services/person_directory_api.dart';
import 'package:sitepulse/domain/services/bank_file_parser.dart';
import 'package:sitepulse/ui/components/sp_dialog_pages.dart';
import 'package:sitepulse/ui/components/step_up_prompt.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/ui/design_system/sp_clipboard.dart';
import 'package:sitepulse/ui/design_system/sp_filter_chip.dart';
import 'package:sitepulse/ui/design_system/sp_guidance_card.dart';
import 'package:sitepulse/ui/design_system/sp_metric.dart';
import 'package:sitepulse/ui/design_system/sp_page_header.dart';
import 'package:sitepulse/ui/components/app_fullscreen_page.dart';
import 'package:sitepulse/ui/design_system/sp_money_field.dart';
import 'package:sitepulse/ui/design_system/sp_status_badge.dart';
import 'package:sitepulse/ui/design_system/sp_tone.dart';
import 'package:sitepulse/ui/residents/resident_directory.dart';
import 'package:sitepulse/ui/residents/advance_exit_settlement_fields.dart';
import 'package:sitepulse/ui/residents/sp_directory_scaffold.dart';
import 'package:sitepulse/ui/residents/sp_person_card.dart';
import 'package:sitepulse/ui/residents/sp_person_field.dart';
import 'package:sitepulse/ui/residents/sp_person_form.dart';
import 'package:sitepulse/ui/theme/app_theme.dart';

/// Pumps [child] in the real SitePulse theme, without a DashboardController.
Future<void> _pump(WidgetTester tester, Widget child, {ThemeData? theme, double textScale = 1}) {
  return tester.pumpWidget(MaterialApp(
    theme: theme ?? AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  ));
}

class _PersonComponentRepository implements PersonRepository {
  final person = const PersonSummary(personId: 42, fullName: 'Ayşe Demir', email: 'ayse@example.test', phone: '0555 000 00 01', role: 'HOME_OWNER', ownedUnits: 2, occupiedUnits: 1, login: PersonLogin.active);

  @override
  Future<PersonSearchPage> search({String query = '', String? context, String? unitId, int page = 1, int pageSize = 50}) async => PersonSearchPage(items: [PersonSearchResult(person: person)], total: 1, page: 1, pageSize: pageSize);
  @override
  Future<List<DuplicateCandidate>> findDuplicates({required String fullName, String? email, String? phone, int? excludePersonId}) async => const [];
  @override
  Future<PersonSummary> create({required String fullName, String? phone, String? email, bool confirmDistinct = false}) async => person;
  @override
  Future<PersonSummary> update(int personId, {required int version, required String fullName, String? phone, String? email}) async => person;
  @override
  Future<PersonSummary?> getById(int personId) async => person;
  @override
  PersonRef referenceFor(PersonSearchResult result) => PersonRef.existing(result.person.personId);
}

HomeOwnerItem _unit({
  required String unitId,
  String block = 'A',
  int unitNo = 1,
  String occupancy = 'OWNER_OCCUPIED',
  String ownerName = 'Ali Malik',
  String email = 'ali@example.com',
  String? tenantName,
  String? tenantEmail,
  List<UnitResidentMember> household = const [],
}) {
  return HomeOwnerItem(
    unitId: unitId,
    siteId: 'site-1',
    block: block,
    unitNo: unitNo,
    floor: 1,
    ownerFullName: ownerName,
    email: email,
    phone: '0532 000 00 00',
    tenantFullName: tenantName,
    tenantEmail: tenantEmail,
    occupancyStatus: occupancy,
    landShare: '1/32',
    monthlyDues: Decimal.parse('1400.00'),
    isResident: true,
    mustChangePassword: false,
    createdAt: DateTime(2026, 1, 1),
    householdResidents: household,
  );
}

/// Records what the app writes to the platform clipboard.
List<String> _captureClipboard(WidgetTester tester, {bool fail = false}) {
  final written = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      if (fail) throw PlatformException(code: 'clipboard_unavailable');
      written.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return written;
}

void main() {
  for (final theme in [AppTheme.light(), AppTheme.dark()]) {
    for (final width in [320.0, 1200.0]) {
      testWidgets('page header wraps actions at $width in ${theme.brightness}', (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var calls = 0;
        await _pump(tester, SpPageHeader(
          title: 'Owners and residents management',
          subtitle: 'A long site name and occupancy summary',
          icon: Icons.people_outline,
          actions: [
            TextButton(onPressed: () => calls++, child: const Text('Add resident')),
            TextButton(onPressed: () {}, child: const Text('Housing types and rates')),
          ],
        ), theme: theme, textScale: 2);
        expect(find.text('Owners and residents management'), findsOneWidget);
        expect(find.text('A long site name and occupancy summary'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Add resident'));
        expect(calls, 1);
      });

      testWidgets('person components remain usable at $width and 2x text in ${theme.brightness}', (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repository = _PersonComponentRepository();
        PersonRef? selected;
        await _pump(tester, SpPersonField(repository: repository, onChanged: (value) => selected = value), theme: theme, textScale: 2);
        expect(find.text('Kişi seç veya ekle'), findsOneWidget);
        await tester.tap(find.text('Kişi seç veya ekle'));
        await tester.pumpAndSettle();
        expect(find.text('Kişi seç'), findsOneWidget);
        await tester.tap(find.text('Ayşe Demir'));
        await tester.pumpAndSettle();
        expect(selected?.personId, 42);
        expect(find.text('Değiştir'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(MaterialApp(theme: theme, home: MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2)), child: SpPersonForm(repository: repository))));
        expect(find.byKey(const Key('person_form_name')), findsOneWidget);
        expect(find.byKey(const Key('person_form_phone')), findsOneWidget);
        expect(find.byKey(const Key('person_form_email')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('person card stays readable at $width and 2x text in ${theme.brightness}', (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _pump(tester, SpPersonCard(person: const PersonSummary(personId: 42, fullName: 'Ayşe Demir', email: 'ayse@example.test', phone: '0555 000 00 01', role: 'HOME_OWNER', ownedUnits: 2, occupiedUnits: 1, login: PersonLogin.active), size: SpPersonCardSize.full, roles: const ['Malik', 'Sakin'], unitLabels: const ['A-12', 'D-1']), theme: theme, textScale: 2);
        expect(find.text('Ayşe Demir'), findsOneWidget);
        expect(find.text('A-12'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final scrollable in [true, false]) {
    testWidgets('fullscreen content begins at the top, scrollable=$scrollable', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: AppFullscreenPage(
        title: 'Details',
        isScrollable: scrollable,
        child: const SizedBox(height: 40, width: 200, child: Text('Short content')),
      )));
      final appBarBottom = tester.getBottomLeft(find.byType(AppBar)).dy;
      expect(tester.getTopLeft(find.text('Short content')).dy,
        closeTo(appBarBottom + AppSpacing.screenGutter, 1));
      expect(tester.takeException(), isNull);
    });
  }

  group('MoneyFormatter.tryParse (the single amount-input rule)', () {
    test('accepts Turkish grouping, plain comma or dot decimals and the lira symbol', () {
      expect(MoneyFormatter.tryParse('1.423,33'), Decimal.parse('1423.33'));
      expect(MoneyFormatter.tryParse('1423,33'), Decimal.parse('1423.33'));
      expect(MoneyFormatter.tryParse('1423.33'), Decimal.parse('1423.33'));
      expect(MoneyFormatter.tryParse('₺1.423'), Decimal.parse('1423'));
      expect(MoneyFormatter.tryParse('1.234.567,89'), Decimal.parse('1234567.89'));
    });

    test('without a comma, a dot is grouping only when followed by exactly three digits', () {
      expect(MoneyFormatter.tryParse('1.423'), Decimal.parse('1423'));
      expect(MoneyFormatter.tryParse('1.42'), Decimal.parse('1.42'));
      expect(MoneyFormatter.tryParse('1400.00'), Decimal.parse('1400.00'));
    });

    test('rejects text that is not an amount', () {
      expect(MoneyFormatter.tryParse(''), isNull);
      expect(MoneyFormatter.tryParse('abc'), isNull);
      expect(MoneyFormatter.tryParse('1.423.33'), isNull);
      expect(MoneyFormatter.tryParse('invalid_budget_amount'), isNull);
    });

    test('keeps large amounts exact (no double conversion)', () {
      expect(MoneyFormatter.tryParse('9.999.999.999.999,99'), Decimal.parse('9999999999999.99'));
    });
  });

  group('validateMoneyInput / MoneyInput', () {
    test('keeps empty, invalid and zero distinct', () {
      expect(MoneyInput.parse('').isEmpty, isTrue);
      expect(MoneyInput.parse('abc').isValid, isFalse);
      expect(MoneyInput.parse('0').amount, Decimal.zero);
      expect(validateMoneyInput(''), MoneyInputMessages.required);
      expect(validateMoneyInput('', required: false), isNull);
      expect(validateMoneyInput('abc'), MoneyInputMessages.invalid);
      expect(validateMoneyInput('0'), MoneyInputMessages.positive);
      expect(validateMoneyInput('0', positive: false), isNull);
      expect(validateMoneyInput('10,005'), MoneyInputMessages.scale);
      expect(validateMoneyInput('1.423,33'), isNull);
    });

    test('custom messages and caller rules are layered on top', () {
      expect(validateMoneyInput('', requiredMessage: 'Bütçe zorunludur'), 'Bütçe zorunludur');
      expect(validateMoneyInput('x', invalidMessage: 'Geçerli tutar girin'), 'Geçerli tutar girin');
      expect(
        validateMoneyInput('500', extra: (a) => a > Decimal.fromInt(100) ? 'Limit aşıldı' : null),
        'Limit aşıldı',
      );
    });

    testWidgets('SpMoneyFormField reports the parsed Decimal and validates inline', (tester) async {
      Decimal? reported;
      final formKey = GlobalKey<FormState>();
      await _pump(
        tester,
        Form(
          key: formKey,
          child: SpMoneyFormField(key: const Key('amount'), onAmountChanged: (v) => reported = v),
        ),
      );
      await tester.enterText(find.byKey(const Key('amount')), '1.423,33');
      expect(reported, Decimal.parse('1423.33'));
      expect(formKey.currentState!.validate(), isTrue);

      await tester.enterText(find.byKey(const Key('amount')), 'abc');
      expect(reported, isNull);
      expect(formKey.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text(MoneyInputMessages.invalid), findsOneWidget);
    });
  });

  group('readDecimal', () {
    test('parses strings and numbers through their string form', () {
      expect(readDecimal({'a': '1423.33'}, 'a'), Decimal.parse('1423.33'));
      expect(readDecimal({'a': 1400}, 'a'), Decimal.fromInt(1400));
      expect(readDecimalOrNull({'a': '0.10'}, 'a'), Decimal.parse('0.10'));
    });

    test('missing values use the fallback; malformed values are reported', () {
      final reported = <String>[];
      final previous = onMalformedDecimal;
      onMalformedDecimal = (key, value) => reported.add('$key=$value');
      addTearDown(() => onMalformedDecimal = previous);

      expect(readDecimal({}, 'a'), Decimal.zero);
      expect(readDecimal(null, 'a'), Decimal.zero);
      expect(readDecimal({'a': null}, 'a', fallback: Decimal.one), Decimal.one);
      expect(reported, isEmpty);

      expect(readDecimal({'a': 'n/a'}, 'a'), Decimal.zero);
      expect(readDecimalOrNull({'b': 'oops'}, 'b'), isNull);
      expect(reported, ['a=n/a', 'b=oops']);
    });
  });

  group('BankFileParser MT940', () {
    const statement = ':20:STMT\n'
        ':25:TR120006200000000000001001\n'
        ':60F:C260901TRY50000,00\n'
        ':61:2609150915CR1423,33NTRFNONREF//TXN77889\n'
        ':86:HAVALE - AHMET YILMAZ A BLOK D:14\n'
        'EYLUL AIDAT\n'
        ':61:260916D250,NTRFNONREF\n'
        ':86:ELEKTRIK FATURASI\n'
        ':62F:C260930TRY51173,33\n'
        '-';

    test('parses every transaction with date, direction, amount and reference', () {
      final rows = BankFileParser.parseMt940(statement);
      expect(rows, hasLength(2));

      expect(rows[0].amount, Decimal.parse('1423.33'));
      expect(rows[0].isIncoming, isTrue);
      expect(rows[0].date, DateTime(2026, 9, 15));
      expect(rows[0].rawId, 'TXN77889');
      expect(rows[0].description, 'HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT');

      expect(rows[1].amount, Decimal.parse('250.00'));
      expect(rows[1].isIncoming, isFalse);
      expect(rows[1].rawId, 'TXN-MT940-002');
      expect(rows[1].description, 'ELEKTRIK FATURASI');
    });

    test('parseText delegates MT940 content so files and pasted text agree', () {
      final viaText = BankFileParser.parseText(statement);
      final viaBytes = BankFileParser.parseBytes(fileName: 'ekstre.sta', bytes: Uint8List.fromList(statement.codeUnits));
      expect(viaText.map((r) => r.amount), [Decimal.parse('1423.33'), Decimal.parse('250.00')]);
      expect(viaBytes.map((r) => r.rawId), viaText.map((r) => r.rawId));
    });

    test('statement amounts share the MoneyFormatter rule', () {
      expect(BankFileParser.parseAmount('1.423,33'), Decimal.parse('1423.33'));
      expect(BankFileParser.parseAmount('-500,00'), Decimal.parse('500.00'));
      expect(BankFileParser.parseAmount('₺1423.33'), Decimal.parse('1423.33'));
    });
  });

  group('resident directory', () {
    final units = [
      _unit(unitId: 'u1', block: 'A Blok', unitNo: 1),
      _unit(unitId: 'u2', block: 'a-blok', unitNo: 2, occupancy: 'TENANT_OCCUPIED', tenantName: 'Ayşe Kiracı', tenantEmail: 'ayse@kira.com'),
      _unit(unitId: 'u3', block: 'B', unitNo: 3, occupancy: 'VACANT', household: const [
        UnitResidentMember(id: 'm1', fullName: 'Can Sakin', relationship: 'Oğlu', phone: '0555'),
      ]),
    ];

    test('block codes normalise and blocks de-duplicate case-insensitively', () {
      expect(normalizeBlockCode('A Blok'), 'A');
      expect(normalizeBlockCode('a-blok'), 'A');
      expect(distinctBlocks([' A ', 'a', 'B', '']), ['A', 'B']);
    });

    test('filters by block, occupancy and free text (including e-mail)', () {
      List<String> ids({String block = allBlocksFilter, String occ = OccupancyFilter.all, String q = ''}) => units
          .where((u) => matchesResidentFilters(u, blockFilter: block, occupancyFilter: occ, query: q))
          .map((u) => u.unitId)
          .toList();

      expect(ids(block: 'A'), ['u1', 'u2']);
      expect(ids(occ: OccupancyFilter.tenant), ['u2']);
      expect(ids(occ: OccupancyFilter.vacant), ['u3']);
      expect(ids(q: 'ayse@kira'), ['u2']);
      expect(ids(q: 'can sakin'), ['u3']);
    });

    test('occupancy stats and rate match the previous one-decimal formula', () {
      final stats = ResidentOccupancyStats.from(units);
      expect(stats.totalUnits, 3);
      expect(stats.tenantCount, 1);
      expect(stats.vacantCount, 1);
      expect(stats.totalCoResidents, 1);
      expect(stats.occupancyRate, '66.7');

      String rate(int total, int vacant) => ResidentOccupancyStats(
            totalUnits: total, tenantCount: 0, ownerCount: 0, vacantCount: vacant, totalCoResidents: 0,
          ).occupancyRate;
      expect(rate(0, 0), '0');
      expect(rate(12, 2), '83.3');
      expect(rate(8, 7), '12.5');
      expect(rate(6, 5), '16.7');
      expect(rate(4, 0), '100.0');
    });

    testWidgets('ResidentSummary renders both variants without a controller', (tester) async {
      final stats = ResidentOccupancyStats.from(units);
      await _pump(tester, Column(children: [ResidentSummary(stats: stats), ResidentSummary(stats: stats, dense: true)]));
      expect(find.text('Doluluk: %66.7'), findsNWidgets(2));
      expect(find.text('Toplam Daire'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });

  group('design-system widgets', () {
    testWidgets('SpMetricValue and SpIconMetric show label and value', (tester) async {
      await _pump(tester, const Row(children: [
        SpMetricValue(label: 'Kalan Borç', value: '₺1.423,33', tone: SpTone.warning),
        Expanded(child: SpIconMetric(label: 'Kiracılı', value: '4', icon: Icons.key)),
      ]));
      expect(find.text('Kalan Borç'), findsOneWidget);
      expect(find.text('₺1.423,33'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
    });

    for (final dark in [false, true]) {
      testWidgets('widgets lay out at 2x text scale in ${dark ? 'dark' : 'light'} theme', (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 1400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _pump(
          tester,
          Column(children: [
            const SpGuidanceCard(
              icon: Icons.info_outline,
              title: 'Çok uzun bir başlık metni küçük ekranlarda satır kaydırmalıdır',
              message: 'Uzun açıklama metni de ekran genişliğine sığacak şekilde kayar ve taşma oluşturmaz.',
              prominent: true,
              tip: 'İpucu metni',
            ),
            const SpStatusBadge(label: '60+g: ₺2.200,00', tone: SpTone.danger, icon: Icons.error_outline),
            SpIbanCopyRow(iban: 'TR41 0020 5042 1399 1067 0000 14'),
          ]),
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('SpGuidanceCard shows optional action and tip', (tester) async {
      var tapped = false;
      await _pump(tester, SpGuidanceCard(
        icon: Icons.add,
        title: 'Başlık',
        message: 'Mesaj',
        action: TextButton(onPressed: () => tapped = true, child: const Text('Başlat')),
        tip: 'İpucu',
      ));
      await tester.tap(find.text('Başlat'));
      expect(tapped, isTrue);
      expect(find.text('İpucu'), findsOneWidget);
    });

    testWidgets('SpFilterChip reports selection and exposes selected state', (tester) async {
      var taps = 0;
      await _pump(tester, SpFilterChip(label: 'Kiracılı (1)', selected: true, onSelected: () => taps++, id: 'chip'));
      await tester.tap(find.byKey(const Key('chip')));
      expect(taps, 1);
      expect(tester.widget<FilterChip>(find.byType(FilterChip)).selected, isTrue);
    });

    testWidgets('SpDirectoryScaffold shows rows in a bounded, paged layout', (tester) async {
      await tester.pumpWidget(MaterialApp(
        restorationScopeId: 'shared_directory_test',
        home: Scaffold(
          body: SpDirectoryScaffold<String>(
            restorationId: 'shared_directory',
            items: const ['A-1', 'A-2'],
            resultLabel: 'daire',
            header: const Text('Daireler'),
            emptyState: const Text('Daire bulunamadı'),
            itemBuilder: (context, item, index) => ListTile(title: Text(item)),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Daireler'), findsOneWidget);
      expect(find.text('A-1'), findsOneWidget);
      expect(find.text('1–2 / 2 daire'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SpDirectoryScaffold requests server pages and page sizes', (tester) async {
      (int, int)? requestedPage;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SpDirectoryScaffold<String>(
            restorationId: 'remote_directory',
            items: List.generate(25, (index) => 'Person ${index + 1}'),
            totalItems: 30,
            pageIndex: 0,
            pageSize: 25,
            onPageChanged: (page, pageSize) => requestedPage = (page, pageSize),
            header: const Text('People'),
            emptyState: const Text('No people'),
            itemBuilder: (context, item, index) => ListTile(title: Text(item)),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('1–25 / 30'), findsOneWidget);
      await tester.tap(find.byTooltip('Sonraki sayfa'));
      expect(requestedPage, (1, 25));
      expect(tester.takeException(), isNull);
    });
  });

  group('clipboard', () {
    test('normalizeIban removes grouping whitespace only', () {
      expect(normalizeIban(' tr41 0020 5042\t1399 '), 'TR41002050421399');
    });

    testWidgets('SpIbanCopyRow copies the IBAN without spaces and confirms', (tester) async {
      final written = _captureClipboard(tester);
      var copied = 0;
      await _pump(tester, SpIbanCopyRow(iban: 'TR41 0020 5042 1399 1067 0000 14', onCopied: () => copied++));
      await tester.tap(find.byKey(const Key('btn_copy_iban_row')));
      await tester.pumpAndSettle();
      expect(written, ['TR410020504213991067000014']);
      expect(copied, 1);
      expect(find.text('Sanal IBAN panoya kopyalandı!'), findsOneWidget);
    });

    testWidgets('an empty IBAN shows the empty label and no copy action', (tester) async {
      await _pump(tester, const SpIbanCopyRow(iban: ''));
      expect(find.text('Sanal IBAN henüz tahsis edilmedi'), findsOneWidget);
      expect(find.byKey(const Key('btn_copy_iban_row')), findsNothing);
    });

    testWidgets('spCopyToClipboard keeps text exactly, and reports failures', (tester) async {
      final written = _captureClipboard(tester);
      late BuildContext ctx;
      await _pump(tester, Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }));
      final ok = await spCopyToClipboard(ctx, 'A BLOK D 14', successMessage: 'Kopyalandı');
      await tester.pumpAndSettle();
      expect(ok, isTrue);
      expect(written, ['A BLOK D 14']);

      _captureClipboard(tester, fail: true);
      final failed = await spCopyToClipboard(ctx, 'x', successMessage: 'Kopyalandı', failureMessage: 'Kopyalanamadı');
      await tester.pumpAndSettle();
      expect(failed, isFalse);
      expect(find.text('Kopyalanamadı'), findsOneWidget);
    });
  });

  group('showSpSelection', () {
    testWidgets('returns the chosen option, or null when the user goes back', (tester) async {
      String? result = 'unset';
      await _pump(tester, Builder(builder: (context) {
        return TextButton(
          onPressed: () async {
            result = await showSpSelection<String>(
              context: context,
              title: 'Rol',
              options: const ['ALL', 'TENANT'],
              labelOf: (v) => v == 'ALL' ? 'Tümü' : 'Kiracı',
              selected: 'ALL',
              idOf: (v) => 'opt_$v',
            );
          },
          child: const Text('open'),
        );
      }));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.tap(find.byKey(const Key('opt_TENANT')));
      await tester.pumpAndSettle();
      expect(result, 'TENANT');

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key(spPageBackKey)));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });

  group('AdvanceExitSettlementFields', () {
    for (final dark in [false, true]) {
      testWidgets('offers keep, payout and transfer choices (${dark ? 'dark' : 'light'}, 2x text)', (tester) async {
        final amountController = TextEditingController();
        var choice = AdvanceExitSettlementChoice.keep;
        Decimal? amount;
        await tester.pumpWidget(MaterialApp(
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: StatefulBuilder(builder: (context, setState) => Scaffold(
              body: SingleChildScrollView(child: AdvanceExitSettlementFields(
                advanceBalance: Decimal.parse('800.00'),
                choice: choice,
                onChoiceChanged: (value) => setState(() => choice = value),
                sourceDebtor: 'TENANT',
                amountController: amountController,
                onAmountChanged: (value) => amount = value,
              )),
            )),
          ),
        ));
        expect(find.text('Toplam avans bakiyesi: ₺800,00'), findsOneWidget);
        expect(find.byKey(const Key('exit_advance_keep')), findsOneWidget);
        expect(find.byKey(const Key('exit_advance_payout')), findsOneWidget);
        expect(find.byKey(const Key('exit_advance_transfer')), findsOneWidget);
        expect(find.byKey(const Key('exit_advance_amount')), findsNothing);
        await tester.tap(find.byKey(const Key('exit_advance_payout')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('exit_advance_amount')), findsOneWidget);
        await tester.enterText(find.byKey(const Key('exit_advance_amount')), '250,00');
        expect(amount, Decimal.parse('250.00'));
        expect(tester.takeException(), isNull);
        amountController.dispose();
      });
    }
  });

  group('StepUpPromptPage', () {
    late http.Client previous;
    setUp(() => previous = ApiClient.transport);
    tearDown(() => ApiClient.transport = previous);

    for (final dark in [false, true]) {
      testWidgets('states the reason and verifies the password (${dark ? 'dark' : 'light'}, 2x text)', (tester) async {
        String? sent;
        ApiClient.transport = MockClient((request) async {
          sent = request.body;
          return http.Response('{}', 200);
        });
        bool? result;
        await tester.pumpWidget(MaterialApp(
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Builder(builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showStepUpPrompt(context, reason: 'Login email change'),
                child: const Text('open'),
              ),
            )),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('Login email change'), findsOneWidget);
        await tester.enterText(find.byKey(const Key('step_up_password')), 'Manager-Pass-1');
        await tester.tap(find.byKey(const Key('btn_step_up_verify')));
        await tester.pumpAndSettle();
        expect(sent, contains('Manager-Pass-1'));
        expect(result, isTrue);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('runWithStepUp asks for the password and retries the action once', (tester) async {
      ApiClient.transport = MockClient((_) async => http.Response('{}', 200));
      var calls = 0;
      Map<String, dynamic>? result;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Builder(builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await runWithStepUp(
              context,
              reason: 'Ownership transfer',
              action: () async => ++calls == 1
                  ? {'success': false, 'needs_step_up': true}
                  : {'success': true},
            ),
            child: const Text('open'),
          ),
        )),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Ownership transfer'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('step_up_password')), 'Manager-Pass-1');
      await tester.tap(find.byKey(const Key('btn_step_up_verify')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(result?['success'], isTrue);
    });

    testWidgets('a wrong password keeps the page open and says so', (tester) async {
      ApiClient.transport = MockClient((_) async => http.Response('{}', 401));
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: const StepUpPromptPage(reason: 'r')));
      await tester.enterText(find.byKey(const Key('step_up_password')), 'wrong');
      await tester.tap(find.byKey(const Key('btn_step_up_verify')));
      await tester.pumpAndSettle();
      expect(find.textContaining('doğrulanamadı'), findsOneWidget);
    });
  });
}
