import 'dues_models.dart';

/// Pure KMK liability and settlement eligibility rules mirroring the backend
/// (`dues_ledger::payer_may_settle`, `payment_tracking_service`, and accrual
/// assignment in `handlers/dues.rs`).
class LiabilityRules {
  const LiabilityRules._();

  /// Who owes a newly accrued charge for [occupancy] and [expenseType].
  ///
  /// Capital dues are always owner-only (KMK & `chk_dues_capital_owner_only`).
  /// Operational dues belong to the tenant only when the unit is tenant-occupied.
  static DebtorType accruedDebtorType({
    required OccupancyStatus occupancy,
    required ExpenseType expenseType,
  }) {
    if (expenseType == ExpenseType.capitalDues) {
      return DebtorType.owner;
    }
    if (occupancy == OccupancyStatus.tenantOccupied) {
      return DebtorType.tenant;
    }
    return DebtorType.owner;
  }

  /// Whether the unit owner carries KMK 22 joint liability for the charge.
  static bool hasJointOwnerLiability({
    required OccupancyStatus occupancy,
    required ExpenseType expenseType,
  }) {
    return occupancy == OccupancyStatus.tenantOccupied &&
        expenseType == ExpenseType.operationalDues;
  }

  /// Whether a payer in [payerRole] may settle a liability of [debtorType]
  /// and [expenseType], given explicit opt-in flags.
  static bool payerMaySettle({
    required DebtorType debtorType,
    required ExpenseType expenseType,
    required DebtorType payerRole,
    bool settlesOwnerCapitalDues = false,
    bool settlesTenantJointLiability = false,
  }) {
    if (payerRole == DebtorType.owner) {
      if (debtorType == DebtorType.owner) {
        return true;
      }
      return settlesTenantJointLiability &&
          expenseType == ExpenseType.operationalDues;
    }

    // Tenant payer:
    if (debtorType == DebtorType.tenant) {
      return expenseType != ExpenseType.capitalDues;
    }
    return settlesOwnerCapitalDues && expenseType == ExpenseType.capitalDues;
  }

  /// Whether the settlement qualifies as a tenant rent-offset payment against
  /// an owner capital liability.
  static bool isRentOffsetPayment({
    required DebtorType debtorType,
    required ExpenseType expenseType,
    required DebtorType payerRole,
    bool settlesOwnerCapitalDues = false,
  }) {
    return payerRole == DebtorType.tenant &&
        debtorType == DebtorType.owner &&
        expenseType == ExpenseType.capitalDues &&
        settlesOwnerCapitalDues;
  }
}
