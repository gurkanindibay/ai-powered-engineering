// SPEC-007 backend calls: statement, receipt PDF, card payment intents,
// receipt reversal and the operating budget (işletme projesi) lifecycle.
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;

import '../models/payments_phase2_models.dart';
import 'api_client.dart';

/// A refused or failed call, with the server's message when it sent one.
class ApiFailure implements Exception {
  final int status;
  final String message;
  const ApiFailure(this.status, this.message);

  @override
  String toString() => message;
}

class PaymentsPhase2Api {
  PaymentsPhase2Api._();

  static const _timeout = Duration(seconds: 10);
  static const _json = {'Content-Type': 'application/json'};

  static dynamic _decode(http.Response r) {
    final text = utf8.decode(r.bodyBytes);
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return text.isEmpty ? null : json.decode(text);
    }
    var message = text;
    try {
      final parsed = json.decode(text);
      if (parsed is Map && parsed['message'] != null) message = parsed['message'].toString();
    } catch (_) {}
    throw ApiFailure(r.statusCode, message.isEmpty ? 'İstek başarısız (${r.statusCode})' : message);
  }

  static Future<ResidentStatement> statement(String unitId) async {
    final r = await ApiClient.get(ApiClient.uri('/api/v1/residents/$unitId/statement')).timeout(_timeout);
    return ResidentStatement.fromJson(_decode(r) as Map<String, dynamic>);
  }

  /// The receipt as PDF bytes.
  static Future<List<int>> receiptPdf(String receiptNumber, {String? siteId}) async {
    final r = await ApiClient.get(ApiClient.uri(
      '/api/v1/payments/receipts/$receiptNumber/pdf',
      siteId == null || siteId.isEmpty ? null : {'site_id': siteId},
    )).timeout(_timeout);
    if (r.statusCode != 200) _decode(r);
    return r.bodyBytes;
  }

  static Future<CardPaymentIntent> createCardPayment(String unitId, Decimal amount, {String? debtorType}) async {
    final r = await ApiClient.post(
      ApiClient.uri('/api/v1/residents/$unitId/payment-intents'),
      headers: _json,
      body: json.encode({'amount': amount.toStringAsFixed(2), 'debtor_type': ?debtorType}),
    ).timeout(_timeout);
    return CardPaymentIntent.fromJson(_decode(r) as Map<String, dynamic>);
  }

  static Future<CardPaymentIntent> cardPayment(String unitId, String intentId) async {
    final r = await ApiClient.get(ApiClient.uri('/api/v1/residents/$unitId/payment-intents/$intentId')).timeout(_timeout);
    return CardPaymentIntent.fromJson(_decode(r) as Map<String, dynamic>);
  }

  /// Reverses a receipt (collection or virman); returns the reversal receipt number.
  static Future<String> reverseReceipt(String receiptNumber, String reason, {String? siteId}) async {
    final r = await ApiClient.post(
      ApiClient.uri('/api/v1/payments/reverse'),
      headers: _json,
      body: json.encode({'receipt': receiptNumber, 'reason': reason, if (siteId != null && siteId.isNotEmpty) 'site_id': siteId}),
    ).timeout(_timeout);
    final body = _decode(r) as Map<String, dynamic>;
    return (body['reversal_receipt'] as Map<String, dynamic>)['receipt_number'].toString();
  }

  // ---- işletme projesi -----------------------------------------------------

  static Map<String, dynamic>? _site(String? siteId) => siteId == null || siteId.isEmpty ? null : {'site_id': siteId};

  static Future<List<OperatingBudget>> budgets({String? siteId}) async {
    final r = await ApiClient.get(ApiClient.uri('/api/v1/operating-budgets', _site(siteId))).timeout(_timeout);
    return (_decode(r) as List<dynamic>).map((e) => OperatingBudget.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<BudgetCompliance> compliance({String? siteId}) async {
    final r = await ApiClient.get(ApiClient.uri('/api/v1/operating-budgets/compliance', _site(siteId))).timeout(_timeout);
    return BudgetCompliance.fromJson(_decode(r) as Map<String, dynamic>);
  }

  static Future<OperatingBudget> createBudget(int fiscalYear, List<BudgetLine> lines, {String? siteId, String? notes}) async {
    final r = await ApiClient.post(
      ApiClient.uri('/api/v1/operating-budgets', _site(siteId)),
      headers: _json,
      body: json.encode({
        'fiscal_year': fiscalYear,
        'lines': lines.map((l) => l.toJson()).toList(),
        if (notes != null && notes.trim().isNotEmpty) 'notes': notes,
      }),
    ).timeout(_timeout);
    return OperatingBudget.fromJson(_decode(r) as Map<String, dynamic>);
  }

  static Future<OperatingBudget> _action(String budgetId, String action, Map<String, dynamic> body, {String? siteId}) async {
    final r = await ApiClient.post(
      ApiClient.uri('/api/v1/operating-budgets/$budgetId/$action', _site(siteId)),
      headers: _json,
      body: json.encode(body),
    ).timeout(_timeout);
    return OperatingBudget.fromJson(_decode(r) as Map<String, dynamic>);
  }

  static Future<OperatingBudget> issueInterim(String id, {String? siteId}) => _action(id, 'issue-interim', {}, siteId: siteId);

  static Future<OperatingBudget> approve(String id, String decisionRef, DateTime decisionDate, {String? siteId}) =>
      _action(id, 'approve', {'assembly_decision_ref': decisionRef, 'assembly_decision_date': _day(decisionDate)}, siteId: siteId);

  static Future<OperatingBudget> reject(String id, String reason, {String? siteId}) => _action(id, 'reject', {'reason': reason}, siteId: siteId);

  static Future<OperatingBudget> finalize(String id, {String? siteId}) => _action(id, 'finalize', {}, siteId: siteId);

  static Future<OperatingBudget> recordService(String id, String unitId, String recipient, String method, DateTime servedOn,
          {String? siteId}) =>
      _action(id, 'service', {'unit_id': unitId, 'recipient_name': recipient, 'method': method, 'served_on': _day(servedOn)},
          siteId: siteId);

  static Future<OperatingBudget> fileObjection(String id, String unitId, String objector, String reason, {String? siteId}) =>
      _action(id, 'objections', {'unit_id': unitId, 'objector_name': objector, 'reason': reason}, siteId: siteId);

  static Future<OperatingBudget> resolveObjection(String id, String objectionId, String status, {String? siteId}) =>
      _action(id, 'objections/$objectionId/resolve', {'status': status}, siteId: siteId);

  static Future<void> deleteDraft(String id, {String? siteId}) async {
    final r = await ApiClient.delete(ApiClient.uri('/api/v1/operating-budgets/$id', _site(siteId))).timeout(_timeout);
    if (r.statusCode != 204) _decode(r);
  }

  static Future<BudgetCompliance> setPolicy(bool require, {String? siteId}) async {
    final r = await ApiClient.put(
      ApiClient.uri('/api/v1/operating-budgets/policy', _site(siteId)),
      headers: _json,
      body: json.encode({'require_operating_budget': require}),
    ).timeout(_timeout);
    return BudgetCompliance.fromJson(_decode(r) as Map<String, dynamic>);
  }

  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
