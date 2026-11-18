// SPEC-009 backend calls. The backend pins the site to the caller's token, so
// staff calls carry no site id.
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;

import '../models/payments_phase2_models.dart';
import '../models/payments_phase3_models.dart';
import 'api_client.dart';
import 'payments_phase2_api.dart' show ApiFailure;

class PaymentsPhase3Api {
  PaymentsPhase3Api._();

  static const _timeout = Duration(seconds: 15);
  static const _json = {'Content-Type': 'application/json'};

  static dynamic _decode(http.Response r) {
    final text = utf8.decode(r.bodyBytes);
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return text.isEmpty ? null : json.decode(text);
    }
    var message = text;
    try {
      final parsed = json.decode(text);
      if (parsed is Map) {
        final m = parsed['message'] ?? (parsed['error'] is Map ? parsed['error']['message'] : null);
        if (m != null) message = m.toString();
      }
    } catch (_) {}
    throw ApiFailure(r.statusCode, message.isEmpty ? 'İstek başarısız (${r.statusCode})' : message);
  }

  static Future<dynamic> _get(String path, [Map<String, String>? query]) async =>
      _decode(await ApiClient.get(ApiClient.uri(path, query)).timeout(_timeout));

  static Future<dynamic> _post(String path, [Object? body]) async => _decode(await ApiClient.post(
        ApiClient.uri(path),
        headers: _json,
        body: json.encode(body ?? const <String, dynamic>{}),
      ).timeout(_timeout));

  static Future<dynamic> _put(String path, Object body) async =>
      _decode(await ApiClient.put(ApiClient.uri(path), headers: _json, body: json.encode(body)).timeout(_timeout));

  static Future<List<int>> _bytes(String path, [Map<String, String>? query]) async {
    final r = await ApiClient.get(ApiClient.uri(path, query)).timeout(_timeout);
    if (r.statusCode != 200) _decode(r);
    return r.bodyBytes;
  }

  static List<Map<String, dynamic>> _rows(dynamic v) =>
      (v as List<dynamic>).map((e) => e as Map<String, dynamic>).toList();

  static String _money(Decimal d) => d.toStringAsFixed(2);

  // ---- R2: KVKK ------------------------------------------------------------

  static Future<PrivacyStatus> privacyStatus() async => PrivacyStatus.fromJson(await _get('/api/v1/kvkk/me'));
  static Future<PrivacyStatus> acknowledgePrivacy() async =>
      PrivacyStatus.fromJson(await _post('/api/v1/kvkk/me/acknowledge'));
  static Future<PrivacyStatus> setConsent(String channel, bool granted) async => PrivacyStatus.fromJson(await _put(
        '/api/v1/kvkk/me/consents',
        {
          'consents': [
            {'channel': channel, 'granted': granted},
          ],
        },
      ));
  static Future<void> publishPrivacyNotice(String title, String body) =>
      _post('/api/v1/kvkk/privacy-notices', {'title': title, 'body': body});
  static Future<List<AccessLogItem>> accessLog() async =>
      _rows(await _get('/api/v1/kvkk/access-log')).map(AccessLogItem.fromJson).toList();
  static Future<Map<String, dynamic>> debtorExport() async =>
      (await _get('/api/v1/kvkk/debtor-export')) as Map<String, dynamic>;

  // ---- R5: resident requests ------------------------------------------------

  static Future<VirmanRequestItem> requestVirman(String unitId, Decimal amount, {String? note}) async =>
      VirmanRequestItem.fromJson(await _post('/api/v1/residents/$unitId/virman-requests', {
        'amount': _money(amount),
        if (note != null && note.isNotEmpty) 'note': note,
      }));
  static Future<List<VirmanRequestItem>> unitVirmanRequests(String unitId) async =>
      _rows(await _get('/api/v1/residents/$unitId/virman-requests')).map(VirmanRequestItem.fromJson).toList();
  static Future<List<VirmanRequestItem>> siteVirmanRequests() async =>
      _rows(await _get('/api/v1/resident-requests/virman')).map(VirmanRequestItem.fromJson).toList();
  static Future<void> decideVirman(int id, bool approve, {String? note}) =>
      _post('/api/v1/resident-requests/virman/$id/decide', {'approve': approve, 'note': ?note});

  static Future<AdvanceExitSettlement> createAdvanceExitSettlement(
    String unitId, {
    required String kind,
    required String beneficiaryName,
    required String sourceDebtor,
    required String requestKey,
    required Decimal amount,
    String? beneficiaryPersonId,
    String? targetDebtor,
    String? note,
  }) async => AdvanceExitSettlement.fromJson(
    await _post('/api/v1/site-admin/units/$unitId/advance-exit-settlements', {
      'kind': kind,
      'beneficiary_name': beneficiaryName,
      'source_debtor': sourceDebtor,
      'request_key': requestKey,
      'amount': _money(amount),
      'beneficiary_person_id': ?beneficiaryPersonId,
      'target_debtor': ?targetDebtor,
      if (note != null && note.isNotEmpty) 'note': note,
    }),
  );

  static Future<List<AdvanceExitSettlement>> advanceExitSettlements() async =>
      _rows(await _get('/api/v1/site-admin/advance-exit-settlements'))
          .map(AdvanceExitSettlement.fromJson)
          .toList();

  static Future<void> decideAdvanceExitSettlement(
    int id, {
    required bool approve,
    String? paymentReference,
    String? note,
  }) => _post('/api/v1/site-admin/advance-exit-settlements/$id/decide', {
    'approve': approve,
    if (paymentReference != null && paymentReference.isNotEmpty)
      'payment_reference': paymentReference,
    if (note != null && note.isNotEmpty) 'note': note,
  });


  static Future<DisputeItem> dispute(String unitId, String dueId, String reason) async =>
      DisputeItem.fromJson(await _post('/api/v1/residents/$unitId/disputes', {'due_id': dueId, 'reason': reason}));
  static Future<List<DisputeItem>> unitDisputes(String unitId) async =>
      _rows(await _get('/api/v1/residents/$unitId/disputes')).map(DisputeItem.fromJson).toList();
  static Future<List<DisputeItem>> siteDisputes() async =>
      _rows(await _get('/api/v1/resident-requests/disputes')).map(DisputeItem.fromJson).toList();
  static Future<void> resolveDispute(int id, bool accept, String note) =>
      _post('/api/v1/resident-requests/disputes/$id/resolve', {'accept': accept, 'note': note});

  // ---- R5/R6: designated card payment, saved cards, autopay -----------------

  /// A hosted-page card payment for the chosen liabilities (TBK 101 designation).
  static Future<CardPaymentIntent> payDesignated(
    String unitId,
    Decimal amount,
    List<String> dueIds, {
    bool saveCard = false,
    int installments = 1,
  }) async =>
      CardPaymentIntent.fromJson(await _post('/api/v1/residents/$unitId/payment-intents', {
        'amount': _money(amount),
        if (dueIds.isNotEmpty) 'designation': {'due_ids': dueIds},
        'save_card': saveCard,
        'installments': installments,
      }));

  static Future<AutopayOverviewData> autopay(String unitId) async =>
      AutopayOverviewData.fromJson(await _get('/api/v1/residents/$unitId/autopay'));
  static Future<void> createMandate(String unitId, int cardId, {Decimal? maxAmount}) =>
      _post('/api/v1/residents/$unitId/autopay/mandates', {
        'payment_method_id': cardId,
        if (maxAmount != null) 'max_amount': _money(maxAmount),
      });
  static Future<void> cancelMandate(String unitId, int mandateId) =>
      _post('/api/v1/residents/$unitId/autopay/mandates/$mandateId/cancel');

  // ---- R7: accounting ---------------------------------------------------------

  static Future<List<ExpenseItem>> expenses() async =>
      _rows(await _get('/api/v1/accounting/expenses')).map(ExpenseItem.fromJson).toList();
  static Future<void> approveExpense(int id) => _post('/api/v1/accounting/expenses/$id/approve');
  static Future<void> rejectExpense(int id, String reason) =>
      _post('/api/v1/accounting/expenses/$id/reject', {'reason': reason});
  static Future<void> payExpense(int id, Decimal amount) =>
      _post('/api/v1/accounting/expenses/$id/payments', {'amount': _money(amount)});
  static Future<TrialBalanceData> trialBalance() async =>
      TrialBalanceData.fromJson(await _get('/api/v1/accounting/trial-balance'));
  static Future<List<int>> accountReportPdf(int year) =>
      _bytes('/api/v1/accounting/account-report', {'year': '$year', 'format': 'pdf'});

  // ---- R8/R10: collections, plans, adjustments ----------------------------------

  static Future<List<CaseItem>> cases() async =>
      _rows(await _get('/api/v1/collections/cases')).map(CaseItem.fromJson).toList();
  static Future<void> advanceCase(int id, String toStatus, {String? lawyerName}) =>
      _post('/api/v1/collections/cases/$id/advance', {'to_status': toStatus, 'lawyer_name': ?lawyerName});
  static Future<List<int>> evidencePackPdf(int id) =>
      _bytes('/api/v1/collections/cases/$id/evidence-pack', {'format': 'pdf'});
  static Future<String> lawyerLink(int id) async =>
      ((await _post('/api/v1/collections/cases/$id/lawyer-access')) as Map<String, dynamic>)['pack_url'].toString();

  static Future<List<PlanItem>> plans() async =>
      _rows(await _get('/api/v1/payment-plans')).map(PlanItem.fromJson).toList();
  static Future<List<PlanItem>> unitPlans(String unitId) async =>
      _rows(await _get('/api/v1/residents/$unitId/payment-plans')).map(PlanItem.fromJson).toList();
  static Future<List<AdjustmentItem>> adjustments() async =>
      _rows(await _get('/api/v1/adjustments')).map(AdjustmentItem.fromJson).toList();
  static Future<void> decideAdjustment(int id, bool approve) =>
      _post('/api/v1/adjustments/$id/decide', {'approve': approve});

  static Future<Map<String, dynamic>> runDunning() async =>
      (await _post('/api/v1/dunning/run')) as Map<String, dynamic>;

  // ---- R12/R14 -------------------------------------------------------------------

  static Future<List<DecisionItem>> decisions() async =>
      _rows(await _get('/api/v1/assembly/decisions')).map(DecisionItem.fromJson).toList();
  static Future<CollectionAnalyticsData> analytics() async =>
      CollectionAnalyticsData.fromJson(await _get('/api/v1/analytics/collections', {'months': '6'}));
}
