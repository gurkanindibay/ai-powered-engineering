@Tags(['residents'])
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/errors/app_exception.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/domain/services/person_directory_api.dart';
import 'package:sitepulse/domain/validation/person_validators.dart';
import 'package:sitepulse/ui/components/sp_dialog_pages.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'package:sitepulse/ui/residents/person_import_page.dart';
import 'package:sitepulse/ui/residents/person_profile_page.dart';
import 'package:sitepulse/ui/theme/app_theme.dart';

/// Person module F7/F8/F9/F10 in the app: import with a mandatory dry run, the
/// profile's identity and preferences, the national ID rule and the duplicate check.
class _FakeApi extends PersonDirectoryApi {
  final List<bool> importRuns = [];
  final List<String> nationalIds = [];
  int invalidRows = 0;
  bool failCommit = false;
  bool stepUpNeeded = false;
  ContactPreferences preferences = const ContactPreferences();
  String? masked;

  @override
  Future<ImportReport> importCsv(String csv, {required bool dryRun}) async {
    importRuns.add(dryRun);
    final commitFailed = !dryRun && failCommit;
    return ImportReport(
      dryRun: dryRun,
      committed: !dryRun && invalidRows < 2 && !commitFailed,
      total: 2,
      invalid: invalidRows + (commitFailed ? 1 : 0),
      created: dryRun ? 0 : (commitFailed ? 0 : 2 - invalidRows),
      rows: [
        ImportRowResult(
          line: 2,
          block: 'A Blok',
          unitNo: 1,
          ownerName: 'Bir',
          errors: invalidRows > 0 || commitFailed ? const ['Malik telefonu: geçersiz'] : const [],
        ),
        const ImportRowResult(line: 3, block: 'A Blok', unitNo: 2, ownerName: 'İki'),
      ],
    );
  }

  @override
  Future<PersonProfile> profile(int personId) async => PersonProfile(
        person: PersonSummary(
          personId: personId,
          fullName: 'Deniz Arslan',
          email: 'deniz@example.com',
          phone: '05320000000',
          role: 'HOME_OWNER',
          ownedUnits: 1,
          occupiedUnits: 1,
          login: PersonLogin.active,
        ),
        units: const [],
        record: PersonRecord(
          nationalIdMasked: masked,
          preferences: preferences,
          consents: const [ChannelConsent(channel: 'EMAIL', granted: true), ChannelConsent(channel: 'SMS', granted: false)],
        ),
      );

  @override
  Future<String?> setNationalId(int personId, String nationalId) async {
    if (stepUpNeeded) {
      throw const ApiException(message: 'Step up', statusCode: 403, code: 'STEP_UP_REQUIRED');
    }
    nationalIds.add(nationalId);
    masked = nationalId.isEmpty ? null : '*******${nationalId.substring(7)}';
    return masked;
  }

  @override
  Future<ContactPreferences> updatePreferences(int personId, ContactPreferences preferences) async {
    this.preferences = preferences;
    return preferences;
  }
}

Widget _host(Widget child) => MaterialApp(theme: AppTheme.light(), home: child);

void main() {
  test('national ID check digits match the server rule', () {
    expect(validateTckn('10000000146'), isNull);
    expect(validateTckn('10000000147'), 'Kimlik numarası geçerli değil.');
    expect(validateTckn('01234567890'), isNotNull);
    expect(validateTckn(''), 'Kimlik numarası gerekli.');
  });

  testWidgets('import stays disabled until a clean dry run of the same text', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_host(PersonImportPage(api: api)));
    FilledButton commit() => tester.widget<FilledButton>(find.byKey(const Key('person_import_commit_btn')));
    expect(commit().onPressed, isNull);

    await tester.enterText(find.byKey(const Key('person_import_text')), PersonImportPage.template());
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('person_import_check_btn')));
    await tester.tap(find.byKey(const Key('person_import_check_btn')));
    await tester.pumpAndSettle();
    expect(api.importRuns, [true]);
    expect(find.text('2 satır kaydedilmeye hazır'), findsOneWidget);
    expect(commit().onPressed, isNotNull);

    // Editing after the check needs a new check.
    await tester.enterText(find.byKey(const Key('person_import_text')), '${PersonImportPage.template()}x');
    await tester.pump();
    expect(commit().onPressed, isNull);
  });

  testWidgets('a dry run with errors lists the row and commits only valid rows', (tester) async {
    final api = _FakeApi()..invalidRows = 1;
    await tester.pumpWidget(_host(PersonImportPage(api: api)));
    await tester.enterText(find.byKey(const Key('person_import_text')), PersonImportPage.template());
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('person_import_check_btn')));
    await tester.tap(find.byKey(const Key('person_import_check_btn')));
    await tester.pumpAndSettle();
    expect(find.text('1 satırda hata var'), findsOneWidget);
    expect(find.text('Malik telefonu: geçersiz'), findsOneWidget);
    final commit = find.byKey(const Key('person_import_commit_btn'));
    expect(tester.widget<FilledButton>(commit).onPressed, isNotNull);
    await tester.tap(commit);
    await tester.pumpAndSettle();
    expect(api.importRuns, [true, false]);
    expect(find.text('1 / 2 kayıt eklendi'), findsOneWidget);
    expect(find.text('1 satır kayıt sırasında reddedildi; aşağıda nedenleri var.'), findsOneWidget);
    expect(find.text('1 kayıt eklendi; 1 satır hatalı.'), findsOneWidget);
    expect(tester.widget<FilledButton>(commit).onPressed, isNull);
  });

  testWidgets('a commit with no registered rows reports the failure', (tester) async {
    final api = _FakeApi()..failCommit = true;
    await tester.pumpWidget(_host(PersonImportPage(api: api)));
    await tester.enterText(find.byKey(const Key('person_import_text')), PersonImportPage.template());
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('person_import_check_btn')));
    await tester.tap(find.byKey(const Key('person_import_check_btn')));
    await tester.pumpAndSettle();
    final commit = find.byKey(const Key('person_import_commit_btn'));
    await tester.tap(commit);
    await tester.pumpAndSettle();
    expect(find.text('1 satırda hata var'), findsOneWidget);
    expect(find.text('Malik telefonu: geçersiz'), findsOneWidget);
    expect(find.text('0 kayıt eklendi; 1 satır hatalı.'), findsOneWidget);
    expect(tester.widget<FilledButton>(commit).onPressed, isNull);
  });

  test('the template has every column the server reads', () {
    final header = PersonImportPage.template().split('\n').first.replaceFirst('﻿', '');
    expect(header.split(';'), personImportColumns);
  });

  testWidgets('profile shows the masked national ID, preferences and read-only consents', (tester) async {
    final api = _FakeApi()
      ..masked = '*******0146'
      ..preferences = const ContactPreferences(channel: 'SMS', language: 'en', emergencyName: 'Ali Veli', emergencyPhone: '05321112233');
    await tester.pumpWidget(_host(PersonProfilePage(personId: 7, api: api)));
    await tester.pumpAndSettle();
    expect(find.text('T.C. kimlik no: *******0146'), findsOneWidget);
    expect(find.text('SMS • English'), findsOneWidget);
    expect(find.text('Acil durum: Ali Veli (05321112233)'), findsOneWidget);
    expect(find.text('SMS: izin yok'), findsOneWidget);
    expect(find.textContaining('yalnızca kişinin kendisi'), findsOneWidget);
  });

  testWidgets('recording a national ID asks for the password when the server requires it', (tester) async {
    final api = _FakeApi()..stepUpNeeded = true;
    await tester.pumpWidget(_host(PersonProfilePage(personId: 7, api: api)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('person_national_id_btn')));
    await tester.tap(find.byKey(const Key('person_national_id_btn')));
    await tester.pumpAndSettle();
    final prompt = find.byType(SpTextPromptPage);
    await tester.enterText(find.descendant(of: prompt, matching: find.byType(TextField)), '10000000146');
    await tester.pump();
    await tester.tap(find.descendant(of: prompt, matching: find.text('Kaydet')));
    await tester.pumpAndSettle();
    expect(find.text('Şifrenizi doğrulayın'), findsOneWidget);
  });

  testWidgets('preferences are edited on their own page and shown after saving', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_host(PersonProfilePage(personId: 7, api: api)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('person_preferences_btn')));
    await tester.tap(find.byKey(const Key('person_preferences_btn')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('person_pref_emergency_name')), 'Ali Veli');
    await tester.tap(find.byKey(const Key('person_pref_save_btn')));
    await tester.pumpAndSettle();
    expect(find.text('Adı girdiyseniz telefonu da girin.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('person_pref_emergency_phone')), '0532 111 22 33');
    await tester.tap(find.byKey(const Key('person_pref_save_btn')));
    await tester.pumpAndSettle();
    expect(api.preferences.emergencyName, 'Ali Veli');
    expect(find.text('Acil durum: Ali Veli (0532 111 22 33)'), findsOneWidget);
  });

  group('duplicate check', () {
    late http.Client previous;
    setUp(() {
      previous = ApiClient.transport;
      ApiClient.setSession({'access_token': 'manager', 'refresh_token': 'refresh'});
    });
    tearDown(() {
      ApiClient.clearSession();
      ApiClient.transport = previous;
    });

    test('asks the server with a POST and reads the reasons', () async {
      late http.Request sent;
      ApiClient.transport = MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode([
            {
              'person': {'person_id': 3, 'full_name': 'Deniz Arslan', 'email': 'd@x.io', 'phone': '', 'role': 'HOME_OWNER',
                         'owned_units': 1, 'occupied_units': 0, 'login': 'ACTIVE'},
              'reasons': ['SAME_PHONE', 'SIMILAR_NAME'],
            }
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final found = await DashboardController(isTestMode: false)
          .findPossibleDuplicates(fullName: 'deniz arslan', email: '', phone: '05327001001');
      expect(sent.method, 'POST');
      expect(sent.url.path, endsWith('/persons/duplicate-check'));
      expect(found.single.reasonText, 'aynı telefon, benzer ad');
    });

    test('a failed check never blocks a registration', () async {
      ApiClient.transport = MockClient((request) async => http.Response('oops', 500));
      final found = await DashboardController(isTestMode: false)
          .findPossibleDuplicates(fullName: 'x', email: 'x@x.io', phone: '');
      expect(found, isEmpty);
    });
  });
}
