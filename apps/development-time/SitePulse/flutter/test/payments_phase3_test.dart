@Tags(['ui'])
library;

import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/payments_phase2_models.dart';
import 'package:sitepulse/domain/models/payments_phase3_models.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/components/sp_dialog_pages.dart';
import 'package:sitepulse/ui/payments/finance_hub_page.dart';
import 'package:sitepulse/ui/payments/resident_self_service.dart';
import 'package:sitepulse/ui/theme/app_theme.dart';

Decimal d(String s) => Decimal.parse(s);

http.Response _json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(json.encode(body)), status, headers: {'content-type': 'application/json'});

Widget _app(Widget child) => MaterialApp(theme: AppTheme.light(), home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  late http.Client previous;
  setUp(() => previous = ApiClient.transport);
  tearDown(() => ApiClient.transport = previous);

  group('SPEC-009 models', () {
    test('the auditor role is recognised; unknown roles still fail', () {
      expect(UserRole.fromApi('AUDITOR'), UserRole.auditor);
      expect(() => UserRole.fromApi('ROOT'), throwsFormatException);
    });

    test('expense, case and plan views read the flattened backend JSON with Decimal money', () {
      final e = ExpenseItem.fromJson({
        'id': 7, 'vendor_name': 'Temiz A.Ş.', 'invoice_number': 'F-1', 'invoice_date': '2026-11-01',
        'category': 'CLEANING', 'total_amount': '1200.50', 'open_amount': '200.50', 'status': 'PENDING_APPROVAL', 'needs_auditor': true,
      });
      expect(e.total, d('1200.50'));
      expect(e.needsAuditor, isTrue);
      final c = CaseItem.fromJson({
        'id': 3, 'unit_label': 'A Blok D:14', 'debtor_type': 'OWNER', 'status': 'NOTICE_SENT', 'outstanding': '1800.00',
        'evidence_ready': false, 'kmk25_threshold_reached': false, 'limitation_warnings': [{'due_id': '1'}],
      });
      expect(c.nextStatus, 'MEDIATION');
      expect(c.limitationWarnings, 1);
      final p = PlanItem.fromJson({
        'id': 2, 'unit_label': 'A Blok D:14', 'status': 'ACTIVE', 'total_amount': '900.00', 'paid': '300.00',
        'installments': [
          {'seq': 1, 'due_date': '2026-12-01', 'amount': '300.00', 'covered': '300.00', 'status': 'PAID'},
        ],
      });
      expect(p.installments.single.covered, d('300.00'));
    });

    test('the privacy status lists consents per channel', () {
      // covers: SC-11-02-04
      final s = PrivacyStatus.fromJson({
        'current_notice': {'title': 'Aydınlatma', 'body': 'Metin', 'version': 2},
        'acknowledged': false,
        'consents': [
          {'channel': 'SMS', 'granted': false},
          {'channel': 'EMAIL', 'granted': true},
        ],
      });
      expect(s.noticeVersion, 2);
      expect(s.consents.firstWhere((c) => c.channel == 'SMS').granted, isFalse);
    });

    test('the designated amount is the sum of the selected items only', () {
      // covers: SC-11-05-04
      StatementOpenItem item(String id, String amount) => StatementOpenItem.fromJson({
            'due_id': id, 'period': id, 'expense_type': 'OPERATIONAL_DUES', 'due_date': '2026-10-15', 'days_overdue': 5,
            'principal_outstanding': amount, 'penalty_outstanding': '0', 'total_outstanding': amount, 'limitation_warning': false,
          });
      final items = [item('a', '100.10'), item('b', '50.05'), item('c', '7.00')];
      expect(designatedTotal(items, {'a', 'c'}), d('107.10'));
      expect(designatedTotal(items, {}), Decimal.zero);
    });
  });

  testWidgets('the text prompt returns the trimmed text and needs the minimum length', (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(builder: (context) => TextButton(
            onPressed: () async => result = await showSpTextPrompt(context: context, title: 'Gerekçe', label: 'Neden', minLength: 5),
            child: const Text('open'),
          )),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final submit = find.byKey(const Key(spPromptSubmitKey));
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.enterText(find.byKey(const Key(spPromptFieldKey)), '  yanlış tutar  ');
    await tester.pump();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(result, 'yanlış tutar');
  });

  testWidgets('the finance hub lists expenses and hides changes in the auditor view', (tester) async {
    ApiClient.transport = MockClient((request) async {
      if (request.url.path == '/api/v1/accounting/expenses') {
        return _json([
          {
            'id': 1, 'vendor_name': 'Temiz A.Ş.', 'invoice_number': 'F-1', 'invoice_date': '2026-11-01', 'category': 'CLEANING',
            'total_amount': '1000.00', 'open_amount': '1000.00', 'status': 'APPROVED', 'needs_auditor': false,
          },
        ]);
      }
      return _json([]);
    });
    await tester.pumpWidget(_app(const FinanceHubView()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('expense_pay_1')), findsOneWidget);
    expect(find.byKey(const Key('finance_tab_requests')), findsOneWidget);

    await tester.pumpWidget(_app(const FinanceHubView(readOnly: true)));
    await tester.pumpAndSettle();
    expect(find.text('Temiz A.Ş. · F-1'), findsOneWidget);
    expect(find.byKey(const Key('expense_pay_1')), findsNothing);
    expect(find.byKey(const Key('finance_tab_requests')), findsNothing);
  });

  testWidgets('selecting open items enables a designated card payment', (tester) async {
    // covers: SC-11-05-03
    final statement = ResidentStatement.fromJson({
      'unit_id': '14',
      'unit_label': 'A Blok D:14',
      'as_of': '2026-11-08',
      'debtors': [
        {
          'debtor_type': 'OWNER', 'name': 'Ahmet', 'current_due': '0', 'overdue_1_30_days': '150.00', 'overdue_31_60_days': '0',
          'overdue_61_90_days': '0', 'overdue_90_plus_days': '0', 'principal_outstanding': '150.00', 'penalty_outstanding': '0',
          'total_outstanding': '150.00', 'advance_balance': '25.00',
          'open_items': [
            {
              'due_id': '9', 'period': 'Ekim 2026', 'expense_type': 'OPERATIONAL_DUES', 'due_date': '2026-10-15', 'days_overdue': 24,
              'principal_outstanding': '150.00', 'penalty_outstanding': '0', 'total_outstanding': '150.00', 'limitation_warning': false,
            },
          ],
        },
      ],
      'receipts': [],
    });
    await tester.pumpWidget(_app(StatementSelfService(unitId: '14', statement: statement, onChanged: () {})));
    final pay = find.byKey(const Key('designate_pay'));
    expect(tester.widget<ButtonStyleButton>(pay).onPressed, isNull);
    await tester.tap(find.byKey(const Key('designate_9')));
    await tester.pump();
    expect(find.textContaining('Seçilenleri öde'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(pay).onPressed, isNotNull);
    expect(find.byKey(const Key('virman_request_owner')), findsOneWidget);
    expect(find.byKey(const Key('dispute_9')), findsOneWidget);
  });
}
