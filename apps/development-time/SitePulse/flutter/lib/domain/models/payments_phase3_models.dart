// SPEC-009 models (payments phase 3): KVKK, resident requests, autopay,
// expenses and the ledger, collections, payment plans and adjustments,
// assembly decisions, heat-share and analytics. Money is always Decimal.
import 'package:decimal/decimal.dart';

import '../formatting/json_decimal.dart';

String _s(Map<String, dynamic> j, String k) => j[k]?.toString() ?? '';
String? _so(Map<String, dynamic> j, String k) => j[k]?.toString();
int _i(Map<String, dynamic> j, String k) => (j[k] as num?)?.toInt() ?? 0;
DateTime? _d(Map<String, dynamic> j, String k) => j[k] == null ? null : DateTime.tryParse(j[k].toString());
List<Map<String, dynamic>> _list(Object? v) =>
    (v as List<dynamic>? ?? const []).map((e) => e as Map<String, dynamic>).toList();

class ConsentState {
  final String channel;
  final bool granted;
  const ConsentState(this.channel, this.granted);
  factory ConsentState.fromJson(Map<String, dynamic> j) => ConsentState(_s(j, 'channel'), j['granted'] == true);
}

class PrivacyStatus {
  final String? noticeTitle;
  final String? noticeBody;
  final int? noticeVersion;
  final bool acknowledged;
  final List<ConsentState> consents;

  const PrivacyStatus({this.noticeTitle, this.noticeBody, this.noticeVersion, required this.acknowledged, required this.consents});

  factory PrivacyStatus.fromJson(Map<String, dynamic> j) {
    final n = j['current_notice'] as Map<String, dynamic>?;
    return PrivacyStatus(
      noticeTitle: n == null ? null : _s(n, 'title'),
      noticeBody: n == null ? null : _s(n, 'body'),
      noticeVersion: n == null ? null : _i(n, 'version'),
      acknowledged: j['acknowledged'] == true,
      consents: _list(j['consents']).map(ConsentState.fromJson).toList(),
    );
  }
}

class VirmanRequestItem {
  final int id;
  final String unitId;
  final String sourceDebtor;
  final String targetDebtor;
  final Decimal amount;
  final String status;
  final String? note;
  final String? receiptNumber;

  const VirmanRequestItem({required this.id, required this.unitId, required this.sourceDebtor, required this.targetDebtor, required this.amount, required this.status, this.note, this.receiptNumber});

  factory VirmanRequestItem.fromJson(Map<String, dynamic> j) => VirmanRequestItem(
        id: _i(j, 'id'),
        unitId: _s(j, 'unit_id'),
        sourceDebtor: _s(j, 'source_debtor'),
        targetDebtor: _s(j, 'target_debtor'),
        amount: readDecimal(j, 'amount'),
        status: _s(j, 'status'),
        note: _so(j, 'note'),
        receiptNumber: _so(j, 'receipt_number'),
      );
}

/// A requested payout or transfer of an exiting debtor's advance balance.
class AdvanceExitSettlement {
  final int id;
  final String siteId;
  final String unitId;
  final String kind;
  final String beneficiaryName;
  final String? beneficiaryPersonId;
  final String sourceDebtor;
  final String? targetDebtor;
  final Decimal amount;
  final String? note;
  final String requestedBy;
  final String status;
  final String? decidedBy;
  final DateTime? decidedAt;
  final String? decisionNote;
  final String? paymentReference;
  final DateTime? createdAt;

  const AdvanceExitSettlement({
    required this.id,
    required this.siteId,
    required this.unitId,
    required this.kind,
    required this.beneficiaryName,
    this.beneficiaryPersonId,
    required this.sourceDebtor,
    this.targetDebtor,
    required this.amount,
    this.note,
    required this.requestedBy,
    required this.status,
    this.decidedBy,
    this.decidedAt,
    this.decisionNote,
    this.paymentReference,
    this.createdAt,
  });

  factory AdvanceExitSettlement.fromJson(Map<String, dynamic> j) =>
      AdvanceExitSettlement(
        id: _i(j, 'id'),
        siteId: _s(j, 'site_id'),
        unitId: _s(j, 'unit_id'),
        kind: _s(j, 'kind'),
        beneficiaryName: _s(j, 'beneficiary_name'),
        beneficiaryPersonId: _so(j, 'beneficiary_person_id'),
        sourceDebtor: _s(j, 'source_debtor'),
        targetDebtor: _so(j, 'target_debtor'),
        amount: readDecimal(j, 'amount'),
        note: _so(j, 'note'),
        requestedBy: _s(j, 'requested_by'),
        status: _s(j, 'status'),
        decidedBy: _so(j, 'decided_by'),
        decidedAt: _d(j, 'decided_at'),
        decisionNote: _so(j, 'decision_note'),
        paymentReference: _so(j, 'payment_reference'),
        createdAt: _d(j, 'created_at'),
      );
}


class DisputeItem {
  final int id;
  final String unitId;
  final String dueId;
  final String reason;
  final String status;
  final String? resolutionNote;

  const DisputeItem({required this.id, required this.unitId, required this.dueId, required this.reason, required this.status, this.resolutionNote});

  factory DisputeItem.fromJson(Map<String, dynamic> j) => DisputeItem(
        id: _i(j, 'id'),
        unitId: _s(j, 'unit_id'),
        dueId: _s(j, 'due_id'),
        reason: _s(j, 'reason'),
        status: _s(j, 'status'),
        resolutionNote: _so(j, 'resolution_note'),
      );
}

class SavedCard {
  final int id;
  final String brand;
  final String last4;
  final int expMonth;
  final int expYear;
  final String status;
  const SavedCard({required this.id, required this.brand, required this.last4, required this.expMonth, required this.expYear, required this.status});
  factory SavedCard.fromJson(Map<String, dynamic> j) => SavedCard(
        id: _i(j, 'id'),
        brand: _s(j, 'brand'),
        last4: _s(j, 'last4'),
        expMonth: _i(j, 'exp_month'),
        expYear: _i(j, 'exp_year'),
        status: _s(j, 'status'),
      );
}

class AutopayMandateItem {
  final int id;
  final int paymentMethodId;
  final String debtorType;
  final String status;
  final Decimal? maxAmount;
  final String? suspendedReason;
  const AutopayMandateItem({required this.id, required this.paymentMethodId, required this.debtorType, required this.status, this.maxAmount, this.suspendedReason});
  factory AutopayMandateItem.fromJson(Map<String, dynamic> j) => AutopayMandateItem(
        id: _i(j, 'id'),
        paymentMethodId: _i(j, 'payment_method_id'),
        debtorType: _s(j, 'debtor_type'),
        status: _s(j, 'status'),
        maxAmount: readDecimalOrNull(j, 'max_amount'),
        suspendedReason: _so(j, 'suspended_reason'),
      );
}

class AutopayOverviewData {
  final List<SavedCard> cards;
  final List<AutopayMandateItem> mandates;
  const AutopayOverviewData(this.cards, this.mandates);
  factory AutopayOverviewData.fromJson(Map<String, dynamic> j) => AutopayOverviewData(
        _list(j['payment_methods']).map(SavedCard.fromJson).toList(),
        _list(j['mandates']).map(AutopayMandateItem.fromJson).toList(),
      );
}

class ExpenseItem {
  final int id;
  final String vendorName;
  final String invoiceNumber;
  final DateTime? invoiceDate;
  final String category;
  final Decimal total;
  final Decimal open;
  final String status;
  final bool needsAuditor;
  const ExpenseItem({required this.id, required this.vendorName, required this.invoiceNumber, this.invoiceDate, required this.category, required this.total, required this.open, required this.status, required this.needsAuditor});
  factory ExpenseItem.fromJson(Map<String, dynamic> j) => ExpenseItem(
        id: _i(j, 'id'),
        vendorName: _s(j, 'vendor_name'),
        invoiceNumber: _s(j, 'invoice_number'),
        invoiceDate: _d(j, 'invoice_date'),
        category: _s(j, 'category'),
        total: readDecimal(j, 'total_amount'),
        open: readDecimal(j, 'open_amount'),
        status: _s(j, 'status'),
        needsAuditor: j['needs_auditor'] == true,
      );
}

class TrialBalanceRow {
  final String code;
  final String name;
  final Decimal debit;
  final Decimal credit;
  final Decimal balance;
  const TrialBalanceRow(this.code, this.name, this.debit, this.credit, this.balance);
  factory TrialBalanceRow.fromJson(Map<String, dynamic> j) => TrialBalanceRow(
        _s(j, 'account_code'),
        _s(j, 'account_name'),
        readDecimal(j, 'debit'),
        readDecimal(j, 'credit'),
        readDecimal(j, 'balance'),
      );
}

class TrialBalanceData {
  final List<TrialBalanceRow> rows;
  final Decimal totalDebit;
  final Decimal totalCredit;
  final bool balanced;
  const TrialBalanceData(this.rows, this.totalDebit, this.totalCredit, this.balanced);
  factory TrialBalanceData.fromJson(Map<String, dynamic> j) => TrialBalanceData(
        _list(j['rows']).map(TrialBalanceRow.fromJson).toList(),
        readDecimal(j, 'total_debit'),
        readDecimal(j, 'total_credit'),
        j['balanced'] == true,
      );
}

class CaseItem {
  final int id;
  final String unitLabel;
  final String debtorType;
  final String status;
  final Decimal outstanding;
  final bool evidenceReady;
  final bool kmk25;
  final int limitationWarnings;
  final String? lawyerName;
  const CaseItem({required this.id, required this.unitLabel, required this.debtorType, required this.status, required this.outstanding, required this.evidenceReady, required this.kmk25, required this.limitationWarnings, this.lawyerName});
  factory CaseItem.fromJson(Map<String, dynamic> j) => CaseItem(
        id: _i(j, 'id'),
        unitLabel: _s(j, 'unit_label'),
        debtorType: _s(j, 'debtor_type'),
        status: _s(j, 'status'),
        outstanding: readDecimal(j, 'outstanding'),
        evidenceReady: j['evidence_ready'] == true,
        kmk25: j['kmk25_threshold_reached'] == true,
        limitationWarnings: (j['limitation_warnings'] as List<dynamic>? ?? const []).length,
        lawyerName: _so(j, 'lawyer_name'),
      );

  /// The next forward step of the case workflow, or null when closed.
  String? get nextStatus => const {
        'REMINDED': 'NOTICE_SENT',
        'NOTICE_SENT': 'MEDIATION',
        'MEDIATION': 'LAWYER_ASSIGNED',
        'LAWYER_ASSIGNED': 'ICRA_FILED',
        'ICRA_FILED': 'COLLECTED',
      }[status];
}

class PlanInstallmentItem {
  final int seq;
  final DateTime? dueDate;
  final Decimal amount;
  final Decimal covered;
  final String status;
  const PlanInstallmentItem(this.seq, this.dueDate, this.amount, this.covered, this.status);
  factory PlanInstallmentItem.fromJson(Map<String, dynamic> j) =>
      PlanInstallmentItem(_i(j, 'seq'), _d(j, 'due_date'), readDecimal(j, 'amount'), readDecimal(j, 'covered'), _s(j, 'status'));
}

class PlanItem {
  final int id;
  final String unitLabel;
  final String status;
  final Decimal total;
  final Decimal paid;
  final List<PlanInstallmentItem> installments;
  const PlanItem({required this.id, required this.unitLabel, required this.status, required this.total, required this.paid, required this.installments});
  factory PlanItem.fromJson(Map<String, dynamic> j) => PlanItem(
        id: _i(j, 'id'),
        unitLabel: _s(j, 'unit_label'),
        status: _s(j, 'status'),
        total: readDecimal(j, 'total_amount'),
        paid: readDecimal(j, 'paid'),
        installments: _list(j['installments']).map(PlanInstallmentItem.fromJson).toList(),
      );
}

class AdjustmentItem {
  final int id;
  final String dueId;
  final String kind;
  final Decimal amount;
  final String reason;
  final String status;
  final String requestedBy;
  const AdjustmentItem({required this.id, required this.dueId, required this.kind, required this.amount, required this.reason, required this.status, required this.requestedBy});
  factory AdjustmentItem.fromJson(Map<String, dynamic> j) => AdjustmentItem(
        id: _i(j, 'id'),
        dueId: _s(j, 'due_id'),
        kind: _s(j, 'kind'),
        amount: readDecimal(j, 'amount'),
        reason: _s(j, 'reason'),
        status: _s(j, 'status'),
        requestedBy: _s(j, 'requested_by'),
      );
}

class DecisionItem {
  final int number;
  final DateTime? decidedOn;
  final String title;
  final String outcome;
  final int yes;
  final int no;
  const DecisionItem({required this.number, this.decidedOn, required this.title, required this.outcome, required this.yes, required this.no});
  factory DecisionItem.fromJson(Map<String, dynamic> j) => DecisionItem(
        number: _i(j, 'decision_number'),
        decidedOn: _d(j, 'decided_on'),
        title: _s(j, 'title'),
        outcome: _s(j, 'outcome'),
        yes: _i(j, 'yes_count'),
        no: _i(j, 'no_count'),
      );
}

class MonthlyKpi {
  final String month;
  final Decimal principalDue;
  final Decimal? collectionRate;
  final Decimal? onTimeRate;
  final Decimal? dsoDays;
  const MonthlyKpi(this.month, this.principalDue, this.collectionRate, this.onTimeRate, this.dsoDays);
  factory MonthlyKpi.fromJson(Map<String, dynamic> j) => MonthlyKpi(
        _s(j, 'month'),
        readDecimal(j, 'principal_due'),
        readDecimalOrNull(j, 'collection_rate'),
        readDecimalOrNull(j, 'on_time_rate'),
        readDecimalOrNull(j, 'dso_days'),
      );
}

class AtRiskUnitItem {
  final String unitLabel;
  final int score;
  final String tier;
  final Decimal overdue;
  const AtRiskUnitItem(this.unitLabel, this.score, this.tier, this.overdue);
  factory AtRiskUnitItem.fromJson(Map<String, dynamic> j) =>
      AtRiskUnitItem(_s(j, 'unit_label'), _i(j, 'score'), _s(j, 'tier'), readDecimal(j, 'overdue_amount'));
}

class CollectionAnalyticsData {
  final List<MonthlyKpi> months;
  final Decimal? digitalShare;
  final Decimal? zeroTouchShare;
  final Decimal? trailingRate;
  final List<AtRiskUnitItem> atRisk;
  const CollectionAnalyticsData({required this.months, this.digitalShare, this.zeroTouchShare, this.trailingRate, required this.atRisk});
  factory CollectionAnalyticsData.fromJson(Map<String, dynamic> j) => CollectionAnalyticsData(
        months: _list(j['months']).map(MonthlyKpi.fromJson).toList(),
        digitalShare: readDecimalOrNull(j, 'digital_share_percent'),
        zeroTouchShare: readDecimalOrNull(j, 'zero_touch_share_percent'),
        trailingRate: readDecimalOrNull(j, 'trailing_collection_rate'),
        atRisk: _list(j['at_risk_units']).map(AtRiskUnitItem.fromJson).toList(),
      );
}

class AccessLogItem {
  final DateTime? at;
  final String actor;
  final String action;
  final String resource;
  const AccessLogItem(this.at, this.actor, this.action, this.resource);
  factory AccessLogItem.fromJson(Map<String, dynamic> j) =>
      AccessLogItem(_d(j, 'occurred_at'), _s(j, 'actor'), _s(j, 'action'), _s(j, 'resource'));
}

// ---- STORY-08-05: sale clearance and seller-pays override --------------------

/// One open liability of the seller: principal and late fee apart.
class ClearanceDebtItem {
  final String dueId;
  final String period;
  final String expenseType;
  final DateTime? dueDate;
  final Decimal principal;
  final Decimal fee;
  final Decimal total;

  const ClearanceDebtItem({
    required this.dueId,
    required this.period,
    required this.expenseType,
    this.dueDate,
    required this.principal,
    required this.fee,
    required this.total,
  });

  factory ClearanceDebtItem.fromJson(Map<String, dynamic> j) => ClearanceDebtItem(
        dueId: _s(j, 'due_id'),
        period: _s(j, 'period'),
        expenseType: _s(j, 'expense_type'),
        dueDate: _d(j, 'due_date'),
        principal: readDecimal(j, 'principal'),
        fee: readDecimal(j, 'fee'),
        total: readDecimal(j, 'total'),
      );
}

/// A capital installment of the unit that is not accrued yet.
class ClearanceInstallment {
  final String projectTitle;
  final int installmentNumber;
  final int totalInstallments;
  final DateTime? dueDate;
  final Decimal amount;

  const ClearanceInstallment({
    required this.projectTitle,
    required this.installmentNumber,
    required this.totalInstallments,
    this.dueDate,
    required this.amount,
  });

  factory ClearanceInstallment.fromJson(Map<String, dynamic> j) => ClearanceInstallment(
        projectTitle: _s(j, 'project_title'),
        installmentNumber: _i(j, 'installment_number'),
        totalInstallments: _i(j, 'total_installments'),
        dueDate: _d(j, 'due_date'),
        amount: readDecimal(j, 'amount'),
      );
}

/// A four-eyes request that the seller pays the installments accruing after the sale.
class SellerPaysOverrideItem {
  final int id;
  final String unitId;
  final String reason;
  final String requestedBy;
  final String status;
  final DateTime? transferDate;

  const SellerPaysOverrideItem({
    required this.id,
    required this.unitId,
    required this.reason,
    required this.requestedBy,
    required this.status,
    this.transferDate,
  });

  factory SellerPaysOverrideItem.fromJson(Map<String, dynamic> j) => SellerPaysOverrideItem(
        id: _i(j, 'id'),
        unitId: _s(j, 'unit_id'),
        reason: _s(j, 'reason'),
        requestedBy: _s(j, 'requested_by'),
        status: _s(j, 'status'),
        transferDate: _d(j, 'transfer_date'),
      );
}

/// What stays with the seller and what goes to the buyer when the unit is sold.
class SaleClearance {
  final String unitLabel;
  final String? sellerName;
  final Decimal openDebtPrincipal;
  final Decimal openDebtFee;
  final Decimal openDebtTotal;
  final List<ClearanceDebtItem> debts;
  final Decimal advance;
  final List<ClearanceInstallment> upcomingInstallments;
  final Decimal upcomingInstallmentsTotal;
  final SellerPaysOverrideItem? overrideRequest;
  final String notice;

  const SaleClearance({
    required this.unitLabel,
    this.sellerName,
    required this.openDebtPrincipal,
    required this.openDebtFee,
    required this.openDebtTotal,
    required this.debts,
    required this.advance,
    required this.upcomingInstallments,
    required this.upcomingInstallmentsTotal,
    this.overrideRequest,
    required this.notice,
  });

  factory SaleClearance.fromJson(Map<String, dynamic> j) => SaleClearance(
        unitLabel: _s(j, 'unit_label'),
        sellerName: _so(j, 'seller_name'),
        openDebtPrincipal: readDecimal(j, 'open_debt_principal'),
        openDebtFee: readDecimal(j, 'open_debt_fee'),
        openDebtTotal: readDecimal(j, 'open_debt_total'),
        debts: _list(j['debts']).map(ClearanceDebtItem.fromJson).toList(),
        advance: readDecimal(j, 'advance'),
        upcomingInstallments: _list(j['upcoming_installments']).map(ClearanceInstallment.fromJson).toList(),
        upcomingInstallmentsTotal: readDecimal(j, 'upcoming_installments_total'),
        overrideRequest: j['override_request'] == null
            ? null
            : SellerPaysOverrideItem.fromJson(j['override_request'] as Map<String, dynamic>),
        notice: _s(j, 'notice'),
      );
}
