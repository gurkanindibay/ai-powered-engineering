// SPEC-007 client models: resident statement, card payment intents, operating
// budget (işletme projesi). Amounts are Decimal, parsed from the API's strings.
import 'package:decimal/decimal.dart';

Decimal _dec(dynamic v) =>
    Decimal.tryParse(v?.toString() ?? '') ?? Decimal.zero;
Decimal? _decOrNull(dynamic v) =>
    v == null ? null : Decimal.tryParse(v.toString());
DateTime? _date(dynamic v) =>
    v == null ? null : DateTime.tryParse(v.toString());
List<Map<String, dynamic>> _list(dynamic v) => (v as List<dynamic>? ?? const [])
    .map((e) => e as Map<String, dynamic>)
    .toList();

class StatementOpenItem {
  final String dueId;
  final String period;
  final String expenseType;
  final DateTime? dueDate;
  final DateTime? effectiveDueDate;
  final bool chargeCreatedLate;
  final int daysOverdue;
  final Decimal principalOutstanding;
  final Decimal penaltyOutstanding;
  final Decimal totalOutstanding;
  final String? operatingBudgetId;
  final bool limitationWarning;

  const StatementOpenItem({
    required this.dueId,
    required this.period,
    required this.expenseType,
    required this.dueDate,
    this.effectiveDueDate,
    this.chargeCreatedLate = false,
    required this.daysOverdue,
    required this.principalOutstanding,
    required this.penaltyOutstanding,
    required this.totalOutstanding,
    required this.operatingBudgetId,
    required this.limitationWarning,
  });

  factory StatementOpenItem.fromJson(Map<String, dynamic> j) =>
      StatementOpenItem(
        dueId: j['due_id']?.toString() ?? '',
        period: j['period']?.toString() ?? '',
        expenseType: j['expense_type']?.toString() ?? '',
        dueDate: _date(j['due_date']),
        effectiveDueDate: _date(j['effective_due_date']),
        chargeCreatedLate: j['charge_created_late'] == true,
        daysOverdue: (j['days_overdue'] as num?)?.toInt() ?? 0,
        principalOutstanding: _dec(j['principal_outstanding']),
        penaltyOutstanding: _dec(j['penalty_outstanding']),
        totalOutstanding: _dec(j['total_outstanding']),
        operatingBudgetId: j['operating_budget_id']?.toString(),
        limitationWarning: j['limitation_warning'] == true,
      );
}

class StatementDebtor {
  final String debtorType;
  final String name;
  final Decimal currentDue;
  final Decimal overdue1To30;
  final Decimal overdue31To60;
  final Decimal overdue61To90;
  final Decimal overdue90Plus;
  final Decimal principalOutstanding;
  final Decimal penaltyOutstanding;
  final Decimal totalOutstanding;
  final Decimal advanceBalance;
  final List<StatementOpenItem> openItems;
  final Decimal jointlyLiableTotal;
  final List<StatementOpenItem> jointlyLiableOpenItems;

  const StatementDebtor({
    required this.debtorType,
    required this.name,
    required this.currentDue,
    required this.overdue1To30,
    required this.overdue31To60,
    required this.overdue61To90,
    required this.overdue90Plus,
    required this.principalOutstanding,
    required this.penaltyOutstanding,
    required this.totalOutstanding,
    required this.advanceBalance,
    required this.openItems,
    required this.jointlyLiableTotal,
    required this.jointlyLiableOpenItems,
  });

  factory StatementDebtor.fromJson(Map<String, dynamic> j) => StatementDebtor(
    debtorType: j['debtor_type']?.toString() ?? 'OWNER',
    name: j['name']?.toString() ?? '',
    currentDue: _dec(j['current_due']),
    overdue1To30: _dec(j['overdue_1_30_days']),
    overdue31To60: _dec(j['overdue_31_60_days']),
    overdue61To90: _dec(j['overdue_61_90_days']),
    overdue90Plus: _dec(j['overdue_90_plus_days']),
    principalOutstanding: _dec(j['principal_outstanding']),
    penaltyOutstanding: _dec(j['penalty_outstanding']),
    totalOutstanding: _dec(j['total_outstanding']),
    advanceBalance: _dec(j['advance_balance']),
    openItems: _list(j['open_items']).map(StatementOpenItem.fromJson).toList(),
    jointlyLiableTotal: _dec(j['jointly_liable_total']),
    jointlyLiableOpenItems: _list(j['jointly_liable_open_items'])
        .map(StatementOpenItem.fromJson)
        .toList(),
  );
}

class StatementReceipt {
  final String receiptNumber;
  final String receiptType;
  final DateTime? issuedAt;
  final String payerRole;
  final String paymentChannel;
  final Decimal totalAmount;
  final bool reversed;

  const StatementReceipt({
    required this.receiptNumber,
    required this.receiptType,
    required this.issuedAt,
    required this.payerRole,
    required this.paymentChannel,
    required this.totalAmount,
    required this.reversed,
  });

  bool get isReversal => receiptType == 'REVERSAL';

  factory StatementReceipt.fromJson(Map<String, dynamic> j) => StatementReceipt(
    receiptNumber: j['receipt_number']?.toString() ?? '',
    receiptType: j['receipt_type']?.toString() ?? 'COLLECTION',
    issuedAt: _date(j['issued_at']),
    payerRole: j['payer_role']?.toString() ?? '',
    paymentChannel: j['payment_channel']?.toString() ?? '',
    totalAmount: _dec(j['total_amount']),
    reversed: j['reversed'] == true,
  );
}

class ResidentStatement {
  final String unitId;
  final String unitLabel;
  final DateTime? asOf;
  final List<StatementDebtor> debtors;
  final List<StatementReceipt> receipts;

  const ResidentStatement({
    required this.unitId,
    required this.unitLabel,
    required this.asOf,
    required this.debtors,
    required this.receipts,
  });

  factory ResidentStatement.fromJson(Map<String, dynamic> j) =>
      ResidentStatement(
        unitId: j['unit_id']?.toString() ?? '',
        unitLabel: j['unit_label']?.toString() ?? '',
        asOf: _date(j['as_of']),
        debtors: _list(j['debtors']).map(StatementDebtor.fromJson).toList(),
        receipts: _list(j['receipts']).map(StatementReceipt.fromJson).toList(),
      );
}

class CardPaymentIntent {
  final String id;
  final Decimal amount;
  final String status;
  final String provider;
  final String? checkoutUrl;
  final String? receiptNumber;
  final String? failureReason;

  const CardPaymentIntent({
    required this.id,
    required this.amount,
    required this.status,
    required this.provider,
    required this.checkoutUrl,
    required this.receiptNumber,
    required this.failureReason,
  });

  bool get isCaptured => status == 'CAPTURED';
  bool get isFailed => status == 'FAILED';
  bool get isFinished => isCaptured || isFailed || status == 'REFUNDED';

  factory CardPaymentIntent.fromJson(Map<String, dynamic> j) =>
      CardPaymentIntent(
        id: j['id']?.toString() ?? '',
        amount: _dec(j['amount']),
        status: j['status']?.toString() ?? 'CREATED',
        provider: j['provider']?.toString() ?? '',
        checkoutUrl: j['checkout_url']?.toString(),
        receiptNumber: j['receipt_number']?.toString(),
        failureReason: j['failure_reason']?.toString(),
      );
}

const budgetCategories = <String, String>{
  'PERSONNEL': 'Personel',
  'CLEANING': 'Temizlik',
  'ENERGY': 'Enerji (ortak alan)',
  'WATER': 'Su',
  'MAINTENANCE': 'Bakım-onarım',
  'INSURANCE': 'Sigorta',
  'MANAGEMENT_FEE': 'Yönetim ücreti',
  'SECURITY': 'Güvenlik',
  'GARDENING': 'Bahçe',
  'RESERVE': 'Yedek akçe',
  'OTHER': 'Diğer',
};

const budgetStatusLabels = <String, String>{
  'DRAFT': 'Taslak',
  'INTERIM': 'Geçici proje (yürürlükte)',
  'APPROVED': 'Genel kurul onaylı',
  'FINAL': 'Kesinleşti',
  'REJECTED': 'Reddedildi',
  'SUPERSEDED': 'Yerine yenisi geçti',
};

class BudgetLine {
  final String category;
  final String? description;
  final Decimal annualAmount;
  final String allocationKey;

  const BudgetLine({
    required this.category,
    this.description,
    required this.annualAmount,
    required this.allocationKey,
  });

  factory BudgetLine.fromJson(Map<String, dynamic> j) => BudgetLine(
    category: j['category']?.toString() ?? 'OTHER',
    description: j['description']?.toString(),
    annualAmount: _dec(j['annual_amount']),
    allocationKey: j['allocation_key']?.toString() ?? 'LAND_SHARE',
  );

  Map<String, dynamic> toJson() => {
    'category': category,
    if (description != null && description!.trim().isNotEmpty)
      'description': description,
    'annual_amount': annualAmount.toStringAsFixed(2),
    'allocation_key': allocationKey,
  };
}

class BudgetUnitShare {
  final String unitId;
  final String unitLabel;
  final int landShare;
  final Decimal annualAmount;
  final Decimal monthlyAmount;

  const BudgetUnitShare({
    required this.unitId,
    required this.unitLabel,
    required this.landShare,
    required this.annualAmount,
    required this.monthlyAmount,
  });

  factory BudgetUnitShare.fromJson(Map<String, dynamic> j) => BudgetUnitShare(
    unitId: j['unit_id']?.toString() ?? '',
    unitLabel: j['unit_label']?.toString() ?? '',
    landShare: (j['land_share'] as num?)?.toInt() ?? 1,
    annualAmount: _dec(j['annual_amount']),
    monthlyAmount: _dec(j['monthly_amount']),
  );
}

class BudgetObjection {
  final String id;
  final String unitId;
  final String objectorName;
  final DateTime? filedOn;
  final String reason;
  final String status;

  const BudgetObjection({
    required this.id,
    required this.unitId,
    required this.objectorName,
    required this.filedOn,
    required this.reason,
    required this.status,
  });

  factory BudgetObjection.fromJson(Map<String, dynamic> j) => BudgetObjection(
    id: j['id']?.toString() ?? '',
    unitId: j['unit_id']?.toString() ?? '',
    objectorName: j['objector_name']?.toString() ?? '',
    filedOn: _date(j['filed_on']),
    reason: j['reason']?.toString() ?? '',
    status: j['status']?.toString() ?? 'OPEN',
  );
}

class OperatingBudget {
  final String id;
  final int fiscalYear;
  final String status;
  final Decimal baselineAnnualAmount;
  final Decimal totalAnnualAmount;
  final Decimal? increaseRate;
  final Decimal? capRate;
  final String? assemblyDecisionRef;
  final DateTime? interimDeadline;
  final DateTime? objectionDeadline;
  final List<BudgetLine> lines;
  final List<BudgetUnitShare> unitShares;
  final Set<String> servedUnitIds;
  final List<BudgetObjection> objections;

  const OperatingBudget({
    required this.id,
    required this.fiscalYear,
    required this.status,
    required this.baselineAnnualAmount,
    required this.totalAnnualAmount,
    required this.increaseRate,
    required this.capRate,
    required this.assemblyDecisionRef,
    required this.interimDeadline,
    required this.objectionDeadline,
    required this.lines,
    required this.unitShares,
    required this.servedUnitIds,
    required this.objections,
  });

  String get statusLabel => budgetStatusLabels[status] ?? status;
  bool get isInForce =>
      status == 'INTERIM' || status == 'APPROVED' || status == 'FINAL';

  factory OperatingBudget.fromJson(Map<String, dynamic> j) => OperatingBudget(
    id: j['id']?.toString() ?? '',
    fiscalYear: (j['fiscal_year'] as num?)?.toInt() ?? 0,
    status: j['status']?.toString() ?? 'DRAFT',
    baselineAnnualAmount: _dec(j['baseline_annual_amount']),
    totalAnnualAmount: _dec(j['total_annual_amount']),
    increaseRate: _decOrNull(j['increase_rate']),
    capRate: _decOrNull(j['cap_rate']),
    assemblyDecisionRef: j['assembly_decision_ref']?.toString(),
    interimDeadline: _date(j['interim_deadline']),
    objectionDeadline: _date(j['objection_deadline']),
    lines: _list(j['lines']).map(BudgetLine.fromJson).toList(),
    unitShares: _list(j['unit_shares']).map(BudgetUnitShare.fromJson).toList(),
    servedUnitIds: _list(j['service_records'])
        .map((r) => r['unit_id']?.toString() ?? '')
        .toSet(),
    objections: _list(j['objections']).map(BudgetObjection.fromJson).toList(),
  );
}

class BudgetCompliance {
  final bool requireOperatingBudget;
  final OperatingBudget? budgetInForce;
  final List<String> warnings;

  const BudgetCompliance({
    required this.requireOperatingBudget,
    required this.budgetInForce,
    required this.warnings,
  });

  factory BudgetCompliance.fromJson(Map<String, dynamic> j) => BudgetCompliance(
    requireOperatingBudget: j['require_operating_budget'] == true,
    budgetInForce: j['budget_in_force'] == null
        ? null
        : OperatingBudget.fromJson(
            j['budget_in_force'] as Map<String, dynamic>,
          ),
    warnings: (j['warnings'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList(),
  );
}
