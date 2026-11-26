@Tags(['finance'])
library;
import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sitepulse/domain/models/auth_models.dart';
import 'package:sitepulse/domain/models/dues_models.dart';
import 'package:sitepulse/domain/services/api_client.dart';
import 'package:sitepulse/ui/components/bank_statement_reconciliation_page.dart';
import 'package:sitepulse/ui/components/dues_management_view.dart';
import 'package:sitepulse/ui/components/manager_cockpit_view.dart';
import 'package:sitepulse/ui/components/payment_tracking_page.dart';
import 'package:sitepulse/ui/dashboard/dashboard_controller.dart';
import 'test_fixtures.dart';

void main() {
  group('Payment Tracking & Debt Aging Module Tests', () {
    late DashboardController controller;

    setUp(() {
      controller = DashboardController(startAuthenticated: true);
      controller.loadTestFixtures();
      controller.switchSessionRole(UserRole.siteManager);
    });

    test('when fetching payment stream in test mode then returns mock stream entries and KPIs', () async {
      await controller.fetchPaymentStream();
      expect(controller.paymentStream, isNotNull);
      final stream = controller.paymentStream!;
      expect(stream.entries.isNotEmpty, isTrue);
      expect(stream.totalCount, stream.entries.length);
      expect(stream.totalVolume.toDouble(), greaterThan(0));

      final first = stream.entries.first;
      expect(first.receiptNumber, contains('TAH-'));
      expect(first.payerName.isNotEmpty, isTrue);
      expect(first.amount.toDouble(), greaterThan(0));
    });

    test('payment stream query includes selected filters and search term', () async {
      final originalTransport = ApiClient.transport;
      addTearDown(() => ApiClient.transport = originalTransport);
      final requests = <http.Request>[];
      ApiClient.transport = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/v1/payments/stream') {
          return http.Response(jsonEncode({
            'entries': [], 'total_volume': '0.00', 'settled_volume': '0.00',
            'unmatched_volume': '0.00', 'total_count': 0,
          }), 200, headers: {'content-type': 'application/json'});
        }
        return http.Response('[]', 200);
      });

      final networkController = DashboardController(isTestMode: false);
      addTearDown(networkController.dispose);
      await networkController.fetchPaymentStream(
        siteId: 'site-1', channel: 'MANUAL_CASH', payerRole: 'TENANT',
        settlementStatus: 'UNMATCHED', search: 'TAH-2026-000099',
      );

      final streamRequests = requests.where((request) => request.url.path == '/api/v1/payments/stream').toList();
      expect(streamRequests, hasLength(1));
      expect(streamRequests.single.url.queryParameters, {
        'site_id': 'site-1', 'channel': 'MANUAL_CASH', 'payer_role': 'TENANT',
        'settlement_status': 'UNMATCHED', 'search': 'TAH-2026-000099',
      });
    });

    // covers: SC-09-01-02
    test('when fetching debt aging report then returns brackets with 0-30, 31-60, and 60+ days', () async {
      await controller.fetchDebtAgingReport();
      expect(controller.debtAgingReport, isNotNull);
      final report = controller.debtAgingReport!;
      expect(report.brackets.isNotEmpty, isTrue);
      expect(report.grandTotal.toDouble(), greaterThan(0));
      expect(report.totalPenalty.toDouble(), greaterThanOrEqualTo(0));

      final firstBracket = report.brackets.first;
      expect(firstBracket.unitLabel.isNotEmpty, isTrue);
      expect(firstBracket.residentName.isNotEmpty, isTrue);
      expect(firstBracket.totalOutstanding.toDouble(), greaterThan(0));
      final sumOfBuckets = firstBracket.currentDue +
          firstBracket.overdue1to30Days +
          firstBracket.overdue31to60Days +
          firstBracket.overdue60PlusDays +
          firstBracket.accruedDelayPenalty;
      expect(firstBracket.totalOutstanding, equals(sumOfBuckets));
    });

    test('when recording manual cash payment then returns receipt and updates stream', () async {
      final res = await controller.recordManualPayment(
        unitId: 'unit-1',
        payerName: 'Gürkan İndibay',
        payerRole: 'TENANT',
        amount: Decimal.parse('1250.00'),
        paymentChannel: 'CASH',
        description: 'Elden nakit Ekim 2026 aidatı (Ref: ELDEN-MAKBUZ-001)',
      );

      expect(res, isNotNull);
      expect(res!.receiptNumber, contains('TAH-'));
      expect(res.allocatedPrincipal, Decimal.parse('1250.00'));
      expect(res.payerName, 'Gürkan İndibay');
    });

    // covers: SC-09-06-02
    test('when executing inter-ledger transfer then returns success and receipt number', () async {
      final res = await controller.executeInterLedgerTransfer(
        unitId: 'unit-2',
        amount: Decimal.parse('500.00'),
        note: 'Fazla ödenen aidat avansı asansör demirbaşına aktarıldı',
      );

      expect(res, isNotNull);
      expect(res!['success'], isTrue);
      expect(res['receipt_number'], contains('TAH-'));
      expect(res['remaining_advance_balance'], '500.00');
    });

    // covers: SC-09-07-01
    test('when transferring property ownership then records new owner and freezes old liabilities', () async {
      final res = await controller.transferUnitOwnership(
        unitId: 'unit-3',
        newOwnerName: 'Ahmet YeniMalik',
        newOwnerPhone: '05559998877',
        newOwnerEmail: 'ahmet@yenimalik.com',
        notes: 'Noter Satış Sözleşmesi No: 12345',
      );

      expect(res, isNotNull);
      expect(res!['success'], isTrue);
      expect(res['new_owner_name'], 'Ahmet YeniMalik');
    });

    testWidgets('PaymentTrackingPage renders stream items, aging tabs, and search bar', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await controller.fetchPaymentStream();
      await controller.fetchDebtAgingReport();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaymentTrackingPage(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check header title and KPI summary
      expect(find.text('Tahsilat & Ödeme Takibi'), findsOneWidget);
      expect(find.textContaining('Çok Kanallı Kasa & Yaşlandırma'), findsOneWidget);
      expect(find.text('TOPLAM TAHSİLAT HACMİ'), findsOneWidget);
      expect(find.textContaining('İşlem'), findsWidgets);

      // Check Tabs
      expect(find.text('Tahsilat Akışı (Stream)'), findsOneWidget);
      expect(find.text('Borç Yaşlandırma (Aging)'), findsOneWidget);

      // Check Unified Bank Reconciliation action buttons
      expect(find.byKey(const Key('action_open_bank_reconciliation')), findsOneWidget);
      expect(find.byKey(const Key('btn_stream_upload_bank_statement')), findsOneWidget);

      // Switch to Borç Yaşlandırma Tab
      await tester.ensureVisible(find.text('Borç Yaşlandırma (Aging)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Borç Yaşlandırma (Aging)'));
      await tester.pumpAndSettle();

      expect(find.text('Daire Bazlı Borç Yaşlandırma'), findsOneWidget);
      expect(find.text('KMK %5 Gecikme Zammı'), findsOneWidget);
      expect(find.text('Vadesi Gelmemiş'), findsOneWidget);
    });

    testWidgets('PaymentTrackingPage renders unmatched bank transactions banner and opens reconciliation', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      controller.setReconciliationQueueForTesting([
        ReconciliationQueueItem(
          matchId: 'recon-unmatched-1',
          transaction: BankStatementParsedItem(
            transactionId: 'TXN-UNMATCHED-1',
            date: DateTime.now(),
            senderName: 'Bilinmeyen Gönderen',
            amount: Decimal.parse('850.00'),
            currency: 'TRY',
            description: 'Açıklamasız Havale',
          ),
          status: 'ESLESTIRILEMEDI',
          confidenceScore: 20,
          amountMatchesBalance: false,
        ),
      ]);

      await controller.fetchPaymentStream();
      await controller.fetchDebtAgingReport();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaymentTrackingPage(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check warning banner is rendered
      expect(find.byKey(const Key('banner_unmatched_bank_transactions')), findsOneWidget);
      expect(find.textContaining('Banka Ekstresinde Eşleşme Bekleyen 1 İşlem Var'), findsOneWidget);
      expect(find.byKey(const Key('btn_resolve_unmatched_bank')), findsOneWidget);

      // Tap to open Bank Statement Reconciliation Page
      await tester.tap(find.byKey(const Key('btn_resolve_unmatched_bank')));
      await tester.pumpAndSettle();

      expect(find.byType(BankStatementReconciliationPage), findsOneWidget);
    });

    testWidgets('manual cash collection validates the amount and issues a receipt', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());
      await controller.fetchPaymentStream();
      await controller.fetchDebtAgingReport();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PaymentTrackingPage(controller: controller))));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Manuel Tahsilat Girişi'));
      await tester.pumpAndSettle();
      expect(find.text('Manuel Tahsilat Girişi'), findsOneWidget);
      await tester.tap(find.text('Tahsilatı Kaydet & Makbuz Üret'));
      await tester.pumpAndSettle();
      expect(find.text('Tutar zorunludur'), findsOneWidget);

      await tester.enterText(find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.hintText == '1400,00'), '1600,75');
      await tester.enterText(find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.hintText == 'Örn: Kerem Yılmaz'), 'Kerem Yılmaz');
      await tester.tap(find.text('Tahsilatı Kaydet & Makbuz Üret'));
      await tester.pumpAndSettle();
      expect(find.text('Dijital Tahsilat Makbuzu'), findsOneWidget);
      expect(find.text('TAH-2026-000099'), findsOneWidget);
    });

    testWidgets('payment stream filters and search can be changed and cleared', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());
      await controller.fetchPaymentStream();
      await controller.fetchDebtAgingReport();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PaymentTrackingPage(controller: controller))));
      await tester.pumpAndSettle();

      final channelFilter = find.text('Kanal: Tüm Kanallar');
      await tester.ensureVisible(channelFilter);
      await tester.tap(channelFilter);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter_channel_option_MANUAL_CASH')));
      await tester.pumpAndSettle();
      expect(find.text('Kanal: Elden Nakit'), findsOneWidget);

      final roleFilter = find.text('Rol: Tüm Roller');
      await tester.ensureVisible(roleFilter);
      await tester.tap(roleFilter);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter_role_option_TENANT')));
      await tester.pumpAndSettle();
      expect(find.text('Rol: Kiracı'), findsOneWidget);

      final settlementFilter = find.text('Durum: Tüm Durumlar');
      await tester.ensureVisible(settlementFilter);
      await tester.tap(settlementFilter);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter_settlement_option_UNMATCHED')));
      await tester.pumpAndSettle();
      expect(find.text('Durum: Havuzda Bekleyen'), findsOneWidget);

      final search = find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.hintText == 'Sakin adı, daire no, makbuz no veya açıklama ara...');
      await tester.enterText(search, 'TAH-2026-000002');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Aramayı temizle'), findsOneWidget);
      await tester.tap(find.text('Temizle'));
      await tester.pumpAndSettle();
      expect(find.text('Kanal: Tüm Kanallar'), findsOneWidget);
      expect(find.text('Rol: Tüm Roller'), findsOneWidget);
      expect(find.text('Durum: Tüm Durumlar'), findsOneWidget);
      await tester.tap(find.byTooltip('Aramayı temizle'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Aramayı temizle'), findsNothing);
    });

    testWidgets('DuesManagementView contains Tahsilat & Kasa Takibi action button', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DuesManagementView(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('action_payment_tracking')), findsOneWidget);
    });

    testWidgets('ManagerCockpitView provides navigation to unified dues and cash management', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      bool navigatedToDues = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ManagerCockpitView(
                controller: controller,
                onAddResidentTap: () {},
                onNavigateToDuesTab: () => navigatedToDues = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final duesNavBtn = find.byKey(const Key('btn_open_unified_dues_center'));
      expect(duesNavBtn, findsOneWidget);
      await tester.ensureVisible(duesNavBtn);
      await tester.pumpAndSettle();
      await tester.tap(duesNavBtn);
      await tester.pumpAndSettle();
      expect(navigatedToDues, isTrue);
    });

    // covers: SC-09-01-03
    testWidgets('opening payment tracking from the dues view sends one stream request', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final streamRequests = _countPaymentStreamRequests(controller);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DuesManagementView(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(streamRequests, isEmpty,
          reason: 'the dues view must not load the stream before it is opened');

      await tester.tap(find.byKey(const Key('action_payment_tracking')));
      await tester.pumpAndSettle();
      expect(streamRequests, hasLength(1),
          reason: 'the action button and the segment it mounts must not both fetch');

      // Re-selecting the active segment is the refresh gesture: one request,
      // not a second copy from a remount.
      await tester.tap(find.byKey(const Key('action_payment_tracking')));
      await tester.pumpAndSettle();
      expect(streamRequests, hasLength(2));

      // Leaving and re-entering the segment is one user action per entry, and
      // each entry fetches once.
      await tester.tap(find.byKey(const Key('segment_tab_2')));
      await tester.pumpAndSettle();
      expect(streamRequests, hasLength(2));

      await tester.tap(find.byKey(const Key('segment_tab_1')));
      await tester.pumpAndSettle();
      expect(streamRequests, hasLength(3));
    });

    // covers: SC-09-01-03
    testWidgets('opening the payment tracking page sends one stream request', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final streamRequests = _countPaymentStreamRequests(controller);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PaymentTrackingPage(controller: controller))),
      );
      await tester.pumpAndSettle();

      expect(streamRequests, hasLength(1),
          reason: 'the page and the stream widget it mounts must not both fetch');
    });

    test('a superseded payment stream response does not overwrite the newer one', () async {
      final originalTransport = ApiClient.transport;
      addTearDown(() => ApiClient.transport = originalTransport);
      final slowResponse = Completer<void>();
      ApiClient.transport = MockClient((request) async {
        if (request.url.queryParameters['search'] == 'slow') {
          await slowResponse.future;
          return _paymentStreamResponse(totalCount: 1);
        }
        return _paymentStreamResponse(totalCount: 2);
      });
      final networkController = DashboardController(isTestMode: false);
      addTearDown(networkController.dispose);

      final slow = networkController.fetchPaymentStream(search: 'slow');
      final fast = networkController.fetchPaymentStream(search: 'fast');
      await fast;
      slowResponse.complete();
      await slow;

      expect(networkController.paymentStream, isNotNull);
      expect(networkController.paymentStream!.totalCount, 2,
          reason: 'the response of the superseded request must be ignored');
      expect(networkController.paymentStreamError, isNull);
      expect(networkController.isPaymentStreamLoading, isFalse);
    });
  });
}

http.Response _paymentStreamResponse({required int totalCount}) => http.Response(
      jsonEncode({
        'entries': <Object>[],
        'total_volume': '0.00',
        'settled_volume': '0.00',
        'unmatched_volume': '0.00',
        'total_count': totalCount,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

/// Counts `/api/v1/payments/stream` requests for [controller] by switching it to
/// the network path with a recording transport. Returns the live request list.
List<http.Request> _countPaymentStreamRequests(DashboardController controller) {
  final originalTransport = ApiClient.transport;
  addTearDown(() => ApiClient.transport = originalTransport);
  final requests = <http.Request>[];
  ApiClient.transport = MockClient((request) async {
    if (request.url.path == '/api/v1/payments/stream') {
      requests.add(request);
      return _paymentStreamResponse(totalCount: 0);
    }
    return http.Response('[]', 200, headers: {'content-type': 'application/json'});
  });
  // Test mode answers the stream locally, so the network path is required to
  // observe the requests.
  controller.isTestMode = false;
  return requests;
}
