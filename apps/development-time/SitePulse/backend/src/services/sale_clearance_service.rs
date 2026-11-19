//! Sale clearance statement and four-eyes seller-pays override (STORY-08-05).
//!
//! * The statement is read from the ledger: the seller's open debt (principal and late fee
//!   apart), the seller's advance, and the capital installments not yet accrued. It moves
//!   nothing.
//! * By default each capital installment is billed to the owner on record when it accrues.
//!   A seller-pays override changes that for one sale, and only after a different manager
//!   approves it (the same four-eyes rule as the advance exit settlements). A pending or
//!   rejected request leaves the default.

use chrono::{DateTime, NaiveDate, Utc};
use deadpool_postgres::GenericClient;
use rust_decimal::Decimal;

use crate::domain::sale_clearance::{csv_cell, CLEARANCE_NOTICE};
use crate::models::{
    ClearanceDebtItem, ClearanceInstallment, DecideSellerPaysOverrideRequest,
    RequestSellerPaysOverrideRequest, SaleClearanceStatement, SellerPaysOverride,
};
use crate::services::capital_project_service::CapitalProjectService;
use crate::services::finance_common::{
    conflict, find_unit, invalid, not_found, same_actor, unit_label, Caller, FinanceError,
    FinanceResult,
};
use crate::state::AppState;

const PENDING: &str = "PENDING";
const APPROVED: &str = "APPROVED";
const REJECTED: &str = "REJECTED";

const COLUMNS: &str = "id, site_id, unit_id, seller_person_id, buyer_person_id, transfer_date, \
reason, requested_by, status, decided_by, decided_at, decision_note, created_at";

pub struct SaleClearanceService {
    state: AppState,
}

impl SaleClearanceService {
    pub fn new(state: &AppState) -> Self {
        Self {
            state: state.clone(),
        }
    }

    /// The statement for selling `unit_id` effective `effective_date`.
    pub async fn statement(
        &self,
        caller: &Caller,
        unit_id: &str,
        effective_date: NaiveDate,
    ) -> FinanceResult<SaleClearanceStatement> {
        let (unit, label, seller_name, debts, advance) = {
            let inner = self.state.inner.read().await;
            let unit = find_unit(&inner, &caller.site_id, unit_id)?;
            let label = unit_label(&inner, &unit);
            let seller_name = unit
                .owner_user_id
                .as_deref()
                .and_then(|owner| inner.users.iter().find(|user| user.id == owner))
                .map(|user| user.full_name.clone());
            let mut debts: Vec<ClearanceDebtItem> = inner
                .dues
                .iter()
                .filter(|due| {
                    crate::auth::same_id(&due.unit_id, &unit.id)
                        && due.debtor_type == crate::models::DebtorType::Owner
                        && due.status != crate::models::DebtStatus::Cancelled
                })
                .filter_map(|due| {
                    let principal = (due.principal_amount - due.paid_principal).max(Decimal::ZERO);
                    let fee = (due.delay_penalty - due.paid_penalty).max(Decimal::ZERO);
                    (principal + fee > Decimal::ZERO).then(|| ClearanceDebtItem {
                        due_id: due.id.clone(),
                        period: due.period.clone(),
                        expense_type: due.expense_type.as_str().to_string(),
                        due_date: due.due_date,
                        principal,
                        fee,
                        total: principal + fee,
                    })
                })
                .collect();
            debts.sort_by(|a, b| (a.due_date, &a.period).cmp(&(b.due_date, &b.period)));
            let advance = inner.advance_of(&unit.id, "OWNER");
            (unit, label, seller_name, debts, advance)
        };
        let open_debt_principal: Decimal = debts.iter().map(|d| d.principal).sum();
        let open_debt_fee: Decimal = debts.iter().map(|d| d.fee).sum();
        let upcoming_installments = self
            .upcoming_installments(&caller.site_id, &unit.id)
            .await?;
        let upcoming_installments_total = upcoming_installments.iter().map(|i| i.amount).sum();
        let override_request = self.latest_override(&caller.site_id, &unit.id).await?;
        Ok(SaleClearanceStatement {
            site_id: caller.site_id.clone(),
            unit_id: unit.id,
            unit_label: label,
            seller_name,
            effective_date,
            open_debt_principal,
            open_debt_fee,
            open_debt_total: open_debt_principal + open_debt_fee,
            debts,
            advance,
            upcoming_installments,
            upcoming_installments_total,
            override_request,
            notice: CLEARANCE_NOTICE.to_string(),
        })
    }

    /// The statement as a CSV document, totals last, for download.
    pub fn render_csv(statement: &SaleClearanceStatement) -> String {
        let mut out = String::from("section,description,due_date,principal,fee,total\n");
        let mut row = |cells: [String; 6]| {
            out.push_str(&cells.map(|c| csv_cell(&c)).join(","));
            out.push('\n');
        };
        for debt in &statement.debts {
            row([
                "open_debt".to_string(),
                format!("{} ({})", debt.period, debt.expense_type),
                debt.due_date.to_string(),
                debt.principal.to_string(),
                debt.fee.to_string(),
                debt.total.to_string(),
            ]);
        }
        row([
            "open_debt_total".to_string(),
            "Seller open debt".to_string(),
            String::new(),
            statement.open_debt_principal.to_string(),
            statement.open_debt_fee.to_string(),
            statement.open_debt_total.to_string(),
        ]);
        row([
            "advance".to_string(),
            "Seller advance".to_string(),
            String::new(),
            String::new(),
            String::new(),
            statement.advance.to_string(),
        ]);
        for item in &statement.upcoming_installments {
            row([
                "not_yet_accrued".to_string(),
                format!(
                    "{} installment {}/{}",
                    item.project_title, item.installment_number, item.total_installments
                ),
                item.due_date.to_string(),
                item.amount.to_string(),
                String::new(),
                item.amount.to_string(),
            ]);
        }
        row([
            "not_yet_accrued_total".to_string(),
            "Installments not yet accrued".to_string(),
            String::new(),
            statement.upcoming_installments_total.to_string(),
            String::new(),
            statement.upcoming_installments_total.to_string(),
        ]);
        row([
            "notice".to_string(),
            statement.notice.clone(),
            String::new(),
            String::new(),
            String::new(),
            String::new(),
        ]);
        out
    }

    /// The unit's share of every installment of an active project that is not accrued yet.
    async fn upcoming_installments(
        &self,
        site_id: &str,
        unit_id: &str,
    ) -> FinanceResult<Vec<ClearanceInstallment>> {
        let capital = CapitalProjectService::new(self.state.clone());
        let units: Vec<crate::models::IndependentUnit> = {
            let inner = self.state.inner.read().await;
            crate::services::finance_common::site_units(&inner, site_id)
                .cloned()
                .collect()
        };
        let Some(position) = units
            .iter()
            .position(|u| crate::auth::same_id(&u.id, unit_id))
        else {
            return Ok(Vec::new());
        };
        let mut items = Vec::new();
        for project in capital.list_projects(site_id).await {
            if project.status != crate::models::CapitalProjectStatus::Active {
                continue;
            }
            for installment in capital.list_installments(&project.id).await {
                if installment.is_accrued {
                    continue;
                }
                let shares = CapitalProjectService::apportion_to_units(
                    &project,
                    installment.installment_budget,
                    &units,
                )
                .map_err(invalid)?;
                items.push(ClearanceInstallment {
                    project_id: project.id.clone(),
                    project_title: project.title.clone(),
                    installment_number: installment.installment_number,
                    total_installments: installment.total_installments,
                    due_date: installment.due_date,
                    amount: shares.get(position).copied().unwrap_or(Decimal::ZERO),
                });
            }
        }
        items.sort_by(|a, b| {
            (a.due_date, &a.project_id, a.installment_number).cmp(&(
                b.due_date,
                &b.project_id,
                b.installment_number,
            ))
        });
        Ok(items)
    }

    async fn latest_override(
        &self,
        site_id: &str,
        unit_id: &str,
    ) -> FinanceResult<Option<SellerPaysOverride>> {
        let Some(pool) = self.state.db_pool() else {
            return Ok(None);
        };
        let (Ok(site), Ok(unit)) = (
            crate::db::require_id("site", site_id),
            crate::db::require_id("unit", unit_id),
        ) else {
            return Ok(None);
        };
        let mut client = pool.get().await.map_err(db_unavailable)?;
        let tx = client.transaction().await.map_err(db_unavailable)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(db_unavailable)?;
        let row = tx
            .query_opt(
                &format!(
                    "SELECT {COLUMNS} FROM seller_pays_overrides
                      WHERE site_id = $1 AND unit_id = $2 ORDER BY id DESC LIMIT 1"
                ),
                &[&site, &unit],
            )
            .await
            .map_err(db_unavailable)?;
        tx.commit().await.map_err(db_unavailable)?;
        Ok(row.map(|r| from_row(&r)))
    }

    /// Requests that the seller (the owner on record) pays the installments accruing after the
    /// sale to `req.buyer_person_id`. Pending until a different manager approves it.
    pub async fn request(
        &self,
        caller: &Caller,
        unit_id: &str,
        req: RequestSellerPaysOverrideRequest,
    ) -> FinanceResult<SellerPaysOverride> {
        self.create(caller, unit_id, None, req).await
    }

    /// Like [`Self::request`] for a transfer that already ran, so the seller is named
    /// explicitly instead of read from the unit.
    pub async fn request_for_seller(
        &self,
        caller: &Caller,
        unit_id: &str,
        seller_person_id: i64,
        req: RequestSellerPaysOverrideRequest,
    ) -> FinanceResult<SellerPaysOverride> {
        self.create(caller, unit_id, Some(seller_person_id), req)
            .await
    }

    async fn create(
        &self,
        caller: &Caller,
        unit_id: &str,
        seller: Option<i64>,
        req: RequestSellerPaysOverrideRequest,
    ) -> FinanceResult<SellerPaysOverride> {
        let reason = req.reason.trim().to_string();
        if reason.chars().count() < 5 {
            return Err(invalid("A reason of at least 5 characters is required"));
        }
        let site = parse_id("site", &caller.site_id)?;
        let unit = parse_id("unit", unit_id)?;
        let pool = self
            .state
            .pool
            .as_ref()
            .ok_or_else(|| FinanceError::Unavailable("Database unavailable".into()))?;
        let mut client = pool.get().await.map_err(db_unavailable)?;
        let tx = client.transaction().await.map_err(db_unavailable)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(db_unavailable)?;
        let owner: Option<Option<i64>> = tx
            .query_opt(
                "SELECT owner_person_id FROM units WHERE id = $1 AND site_id = $2",
                &[&unit, &site],
            )
            .await
            .map_err(db_unavailable)?
            .map(|r| r.get(0));
        let owner = owner.ok_or_else(|| not_found("Unit not found in this site"))?;
        let seller = seller
            .or(owner)
            .ok_or_else(|| conflict("The unit has no owner on record to act as the seller"))?;
        if seller == req.buyer_person_id {
            return Err(invalid("The seller and the buyer must be different people"));
        }
        let buyer_exists: bool = tx
            .query_one(
                "SELECT EXISTS(SELECT 1 FROM persons WHERE id = $1 AND site_id = $2 AND deleted_at IS NULL)",
                &[&req.buyer_person_id, &site],
            )
            .await
            .map_err(db_unavailable)?
            .get(0);
        if !buyer_exists {
            return Err(not_found("Buyer not found in this site"));
        }
        let pending: bool = tx
            .query_one(
                "SELECT EXISTS(SELECT 1 FROM seller_pays_overrides
                                WHERE unit_id = $1 AND buyer_person_id = $2 AND status = 'PENDING')",
                &[&unit, &req.buyer_person_id],
            )
            .await
            .map_err(db_unavailable)?
            .get(0);
        if pending {
            return Err(conflict(
                "A seller-pays override for this sale is already waiting for approval",
            ));
        }
        let row = tx
            .query_one(
                &format!(
                    "INSERT INTO seller_pays_overrides
                         (site_id, unit_id, seller_person_id, buyer_person_id, transfer_date,
                          reason, requested_by)
                     VALUES ($1, $2, $3, $4, $5, $6, $7)
                     RETURNING {COLUMNS}"
                ),
                &[
                    &site,
                    &unit,
                    &seller,
                    &req.buyer_person_id,
                    &req.transfer_date,
                    &reason,
                    &caller.actor(),
                ],
            )
            .await
            .map_err(db_unavailable)?;
        tx.commit().await.map_err(db_unavailable)?;
        Ok(from_row(&row))
    }

    /// Every override request of the caller's site, newest first.
    pub async fn list(&self, caller: &Caller) -> FinanceResult<Vec<SellerPaysOverride>> {
        let site = parse_id("site", &caller.site_id)?;
        let pool = self
            .state
            .pool
            .as_ref()
            .ok_or_else(|| FinanceError::Unavailable("Database unavailable".into()))?;
        let mut client = pool.get().await.map_err(db_unavailable)?;
        let tx = client.transaction().await.map_err(db_unavailable)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(db_unavailable)?;
        let rows = tx
            .query(
                &format!(
                    "SELECT {COLUMNS} FROM seller_pays_overrides WHERE site_id = $1 ORDER BY id DESC"
                ),
                &[&site],
            )
            .await
            .map_err(db_unavailable)?;
        tx.commit().await.map_err(db_unavailable)?;
        Ok(rows.iter().map(from_row).collect())
    }

    /// Approves or rejects a pending request. The approver must differ from the requester.
    pub async fn decide(
        &self,
        caller: &Caller,
        override_id: i64,
        decision: DecideSellerPaysOverrideRequest,
    ) -> FinanceResult<SellerPaysOverride> {
        if override_id <= 0 {
            return Err(invalid("override id must be positive"));
        }
        let note = decision
            .note
            .as_deref()
            .map(str::trim)
            .filter(|n| !n.is_empty())
            .map(str::to_string);
        let site = parse_id("site", &caller.site_id)?;
        let pool = self
            .state
            .pool
            .as_ref()
            .ok_or_else(|| FinanceError::Unavailable("Database unavailable".into()))?;
        let mut client = pool.get().await.map_err(db_unavailable)?;
        let tx = client.transaction().await.map_err(db_unavailable)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(db_unavailable)?;
        let row = tx
            .query_opt(
                &format!(
                    "SELECT {COLUMNS} FROM seller_pays_overrides
                      WHERE site_id = $1 AND id = $2 FOR UPDATE"
                ),
                &[&site, &override_id],
            )
            .await
            .map_err(db_unavailable)?
            .ok_or_else(|| not_found(format!("Seller-pays override {override_id} not found")))?;
        let current = from_row(&row);
        if current.status != PENDING {
            return Err(conflict(format!(
                "Seller-pays override {} is already {}",
                current.id, current.status
            )));
        }
        if same_actor(&current.requested_by, &caller.actor()) {
            return Err(FinanceError::Forbidden(
                "The approver must be a different person from the requester (four-eyes)".into(),
            ));
        }
        let status = if decision.approve { APPROVED } else { REJECTED };
        let decided_at = Utc::now();
        let updated = tx
            .query_one(
                &format!(
                    "UPDATE seller_pays_overrides
                        SET status = $3, decided_by = $4, decided_at = $5, decision_note = $6
                      WHERE site_id = $1 AND id = $2
                      RETURNING {COLUMNS}"
                ),
                &[
                    &site,
                    &override_id,
                    &status,
                    &caller.actor(),
                    &decided_at,
                    &note,
                ],
            )
            .await
            .map_err(db_unavailable)?;
        tx.commit().await.map_err(db_unavailable)?;
        Ok(from_row(&updated))
    }
}

/// The seller who pays the capital installments of `unit` accruing now, if an approved
/// override names the owner on record as the buyer. `None` is the default: the owner on record.
pub async fn approved_seller_for_unit<C: GenericClient>(
    client: &C,
    unit: i64,
) -> Result<Option<i64>, tokio_postgres::Error> {
    let row = client
        .query_opt(
            "SELECT o.seller_person_id
               FROM seller_pays_overrides o
               JOIN units u ON u.id = o.unit_id AND u.owner_person_id = o.buyer_person_id
              WHERE o.unit_id = $1 AND o.status = 'APPROVED'
              ORDER BY o.id DESC LIMIT 1",
            &[&unit],
        )
        .await?;
    Ok(row.map(|r| r.get(0)))
}

fn parse_id(kind: &str, raw: &str) -> FinanceResult<i64> {
    crate::db::require_id(kind, raw).map_err(invalid)
}

fn db_unavailable<E: std::fmt::Display>(error: E) -> FinanceError {
    FinanceError::Unavailable(format!("Database operation failed: {}", error))
}

fn from_row(row: &tokio_postgres::Row) -> SellerPaysOverride {
    SellerPaysOverride {
        id: row.get(0),
        site_id: row.get::<_, i64>(1).to_string(),
        unit_id: row.get::<_, i64>(2).to_string(),
        seller_person_id: row.get(3),
        buyer_person_id: row.get(4),
        transfer_date: row.get(5),
        reason: row.get(6),
        requested_by: row.get(7),
        status: row.get(8),
        decided_by: row.get(9),
        decided_at: row.get::<_, Option<DateTime<Utc>>>(10),
        decision_note: row.get(11),
        created_at: row.get(12),
    }
}
