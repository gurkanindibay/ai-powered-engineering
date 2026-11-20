// STORY-08-05: the sale clearance statement and the four-eyes seller-pays queue.
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sitepulse/domain/models/payments_phase3_models.dart';
import 'package:sitepulse/ui/payments/seller_pays_override_queue.dart';
import 'package:sitepulse/ui/residents/sale_clearance_panel.dart';
import 'package:sitepulse/ui/theme/app_theme.dart';

Decimal d(String s) => Decimal.parse(s);

Widget _app(Widget child) =>
    MaterialApp(theme: AppTheme.light(), home: Scaffold(body: SingleChildScrollView(child: child)));

Map<String, dynamic> _statementJson({Map<String, dynamic>? override}) => {
      'unit_label': 'A-4',
      'seller_name': 'Ahmet Yılmaz',
      'open_debt_principal': '5000.00',
      'open_debt_fee': '158.33',
      'open_debt_total': '5158.33',
      'debts': [
        {
          'due_id': '1',
          'period': '2026-11',
          'expense_type': 'OPERATIONAL_DUES',
          'due_date': '2026-11-10',
          'principal': '1500.00',
          'fee': '100.00',
          'total': '1600.00',
        },
      ],
      'advance': '0.00',
      'upcoming_installments': [
        {
          'project_title': 'Cephe',
          'installment_number': 2,
          'total_installments': 3,
          'due_date': '2027-01-10',
          'amount': '2000.00',
        },
        {
          'project_title': 'Cephe',
          'installment_number': 3,
          'total_installments': 3,
          'due_date': '2027-02-10',
          'amount': '2000.00',
        },
      ],
      'upcoming_installments_total': '4000.00',
      'override_request': override,
      'notice': 'Existing debt stays with the seller.',
    };

void main() {
  test('the statement is read with Decimal money', () {
    // covers: SC-08-05-04
    final statement = SaleClearance.fromJson(_statementJson());
    expect(statement.openDebtTotal, d('5158.33'));
    expect(statement.openDebtPrincipal + statement.openDebtFee, statement.openDebtTotal);
    expect(statement.debts.single.fee, d('100.00'));
    expect(statement.upcomingInstallments, hasLength(2));
    expect(statement.upcomingInstallmentsTotal, d('4000.00'));
    expect(statement.overrideRequest, isNull);
  });

  testWidgets('the panel shows debt apart, the advance and the installments not yet accrued', (tester) async {
    // covers: SC-08-05-04
    await tester.pumpWidget(_app(SaleClearancePanel(
      unitId: '4',
      loader: (unitId, date) async => SaleClearance.fromJson(_statementJson(
        override: {
          'id': 5,
          'unit_id': '4',
          'reason': 'Sözleşme gereği',
          'requested_by': 'm1',
          'status': 'PENDING',
        },
      )),
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sale_clearance_open_debt')), findsOneWidget);
    expect(find.byKey(const Key('sale_clearance_principal')), findsOneWidget);
    expect(find.byKey(const Key('sale_clearance_fee')), findsOneWidget);
    expect(find.byKey(const Key('sale_clearance_advance')), findsOneWidget);
    expect(find.textContaining('Cephe 2/3'), findsOneWidget);
    expect(find.textContaining('Cephe 3/3'), findsOneWidget);
    expect(find.text('PENDING'), findsOneWidget);
  });

  testWidgets('the download button asks the downloader for this unit', (tester) async {
    String? downloaded;
    await tester.pumpWidget(_app(SaleClearancePanel(
      unitId: '4',
      loader: (unitId, date) async => SaleClearance.fromJson(_statementJson()),
      downloader: (unitId, date) async {
        downloaded = unitId;
        return true;
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sale_clearance_download')));
    await tester.pump();
    expect(downloaded, '4');
  });

  testWidgets('a pending request is approved from the queue with the decision note', (tester) async {
    // covers: SC-08-05-06
    (int, bool, String?)? decision;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: SellerPaysOverrideQueuePage(
        loader: () async => const [
          SellerPaysOverrideItem(
            id: 5,
            unitId: '4',
            reason: 'Sözleşme gereği',
            requestedBy: 'm1',
            status: 'PENDING',
          ),
          SellerPaysOverrideItem(
            id: 6,
            unitId: '4',
            reason: 'Eski talep',
            requestedBy: 'm1',
            status: 'REJECTED',
          ),
        ],
        decider: (id, {required approve, note}) async => decision = (id, approve, note),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('seller_pays_override_5')), findsOneWidget);
    expect(find.byKey(const Key('seller_pays_override_6')), findsNothing);
    await tester.enterText(find.byKey(const Key('seller_pays_decision_note')), 'Sözleşme görüldü');
    await tester.tap(find.byKey(const Key('seller_pays_approve_5')));
    // The confirmation toast animates on a timer, so settle with fixed pumps.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(decision, (5, true, 'Sözleşme görüldü'));
  });
}
