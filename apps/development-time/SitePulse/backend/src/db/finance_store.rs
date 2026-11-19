//! The SPEC-009 persistence port.
//!
//! Services call `FinanceStore` and never look at the pool themselves. With
//! PostgreSQL a change is written first and applied to memory only after it
//! committed (so a failed write leaves both unchanged); without a database the
//! store assigns ids from the in-memory collection.

use deadpool_postgres::Pool;

use super::finance_records::{self as rec, Record};
use super::DbResult;
use crate::finance_book::FinanceBook;
use crate::state::{AppState, AppStateInner};

/// Selects the collection of a record type inside the book.
pub type Collection<T> = fn(&mut FinanceBook) -> &mut Vec<T>;

#[derive(Clone)]
pub struct FinanceStore {
    state: AppState,
}

fn next_memory_id<T: Record>(items: &[T]) -> i64 {
    items.iter().map(Record::id).max().unwrap_or(0) + 1
}

impl FinanceStore {
    pub fn new(state: &AppState) -> Self {
        Self {
            state: state.clone(),
        }
    }

    fn pool(&self) -> Option<&Pool> {
        self.state.db_pool()
    }

    pub fn has_database(&self) -> bool {
        self.pool().is_some()
    }

    /// Reads the in-memory state under a read lock (never held across `.await`).
    pub async fn read<R>(&self, f: impl FnOnce(&AppStateInner) -> R) -> R {
        let inner = self.state.inner.read().await;
        f(&inner)
    }

    /// Inserts a new record and returns it with its id.
    pub async fn insert<T: Record>(&self, mut record: T, collection: Collection<T>) -> DbResult<T> {
        match self.pool() {
            Some(pool) => {
                let client = pool.get().await?;
                let id = rec::insert(&**client, &record).await?;
                record.set_id(id);
                let mut inner = self.state.inner.write().await;
                collection(&mut inner.finance).push(record.clone());
            }
            None => {
                let mut inner = self.state.inner.write().await;
                let items = collection(&mut inner.finance);
                record.set_id(next_memory_id(items));
                items.push(record.clone());
            }
        }
        Ok(record)
    }

    /// Inserts a parent and its children in one transaction; `link` sets the
    /// parent id on each child.
    pub async fn insert_with_children<P: Record, C: Record>(
        &self,
        mut parent: P,
        parents: Collection<P>,
        mut children: Vec<C>,
        kids: Collection<C>,
        link: fn(&mut C, i64),
    ) -> DbResult<(P, Vec<C>)> {
        match self.pool() {
            Some(pool) => {
                let mut client = pool.get().await?;
                let tx = client.transaction().await?;
                let id = rec::insert(&*tx, &parent).await?;
                parent.set_id(id);
                for child in children.iter_mut() {
                    link(child, id);
                    let cid = rec::insert(&*tx, child).await?;
                    child.set_id(cid);
                }
                tx.commit().await?;
                let mut inner = self.state.inner.write().await;
                parents(&mut inner.finance).push(parent.clone());
                kids(&mut inner.finance).extend(children.iter().cloned());
            }
            None => {
                let mut inner = self.state.inner.write().await;
                let book = &mut inner.finance;
                let id = next_memory_id(parents(book));
                parent.set_id(id);
                parents(book).push(parent.clone());
                let base_id = next_memory_id(kids(book));
                for (offset, child) in children.iter_mut().enumerate() {
                    link(child, id);
                    child.set_id(base_id + offset as i64);
                }

                kids(book).extend(children.iter().cloned());
            }
        }
        Ok((parent, children))
    }

    /// Replaces a stored record (matched by id).
    pub async fn update<T: Record>(&self, record: T, collection: Collection<T>) -> DbResult<T> {
        if let Some(p) = self.pool() {
            let client = p.get().await?;
            rec::update(&**client, &record).await?;
        }
        let mut inner = self.state.inner.write().await;
        let items = collection(&mut inner.finance);
        match items.iter_mut().find(|r| r.id() == record.id()) {
            Some(slot) => *slot = record.clone(),
            None => return Err(format!("{} {} is not loaded", T::TABLE, record.id()).into()),
        }
        Ok(record)
    }

    /// Inserts a record with no id yet, or updates one that has an id.
    pub async fn upsert<T: Record>(&self, record: T, collection: Collection<T>) -> DbResult<T> {
        if record.id() > 0 {
            self.update(record, collection).await
        } else {
            self.insert(record, collection).await
        }
    }

    /// Deletes records by id.
    pub async fn delete<T: Record>(&self, ids: &[i64], collection: Collection<T>) -> DbResult<()> {
        if let Some(p) = self.pool() {
            let client = p.get().await?;
            for id in ids {
                rec::delete::<T>(&**client, *id).await?;
            }
        }
        let mut inner = self.state.inner.write().await;
        collection(&mut inner.finance).retain(|r| !ids.contains(&r.id()));
        Ok(())
    }

    /// Lowers what a liability owes (approved waiver or write-off) in the
    /// database and in memory.
    pub async fn apply_due_adjustment(
        &self,
        due_id: &str,
        principal: rust_decimal::Decimal,
        penalty: rust_decimal::Decimal,
    ) -> DbResult<()> {
        if let Some(p) = self.pool() {
            let client = p.get().await?;
            rec::apply_due_adjustment(&**client, due_id, principal, penalty).await?;
        }
        let mut inner = self.state.inner.write().await;
        let due = inner
            .dues
            .iter_mut()
            .find(|d| d.id == due_id)
            .ok_or_else(|| format!("Liability {} is not loaded", due_id))?;
        due.principal_amount = principal;
        due.delay_penalty = penalty;
        crate::services::dues_ledger::refresh(due);
        if due.total_amount > rust_decimal::Decimal::ZERO
            && due.status == crate::models::DebtStatus::Paid
        {
            due.status = crate::models::DebtStatus::Overdue;
        }
        Ok(())
    }

    pub async fn set_budget_transition(
        &self,
        site_id: &str,
        until: Option<chrono::NaiveDate>,
    ) -> DbResult<()> {
        if let Some(p) = self.pool() {
            let client = p.get().await?;
            rec::set_site_budget_transition(&**client, site_id, until).await?;
        }
        let mut inner = self.state.inner.write().await;
        let key = inner
            .sites
            .iter()
            .find(|s| crate::auth::same_id(&s.id, site_id))
            .map(|s| s.id.clone())
            .unwrap_or_else(|| site_id.to_string());
        match until {
            Some(d) => {
                inner.finance.budget_transitions.insert(key, d);
            }
            None => {
                inner.finance.budget_transitions.remove(&key);
            }
        }
        Ok(())
    }

    /// Units whose owner or tenant has this national id (none without a database:
    /// national ids are never held in memory).
    pub async fn units_by_national_id(
        &self,
        site_id: &str,
        national_id: &str,
    ) -> DbResult<Vec<String>> {
        match self.pool() {
            Some(pool) => {
                let client = pool.get().await?;
                rec::units_by_national_id(&**client, site_id, national_id).await
            }
            None => Ok(Vec::new()),
        }
    }

    /// Inserts a new liability (heat share and similar accruals). Returns `None`
    /// when the unit already has one for this period and expense type.
    pub async fn insert_due(
        &self,
        mut due: crate::models::DuesLiability,
    ) -> DbResult<Option<crate::models::DuesLiability>> {
        let due_site_id = self
            .state
            .inner
            .read()
            .await
            .units
            .iter()
            .find(|unit| crate::auth::same_id(&unit.id, &due.unit_id))
            .map(|unit| unit.site_id.clone())
            .ok_or_else(|| format!("Unit {} not found", due.unit_id))?;
        match self.pool() {
            Some(pool) => match super::insert_accrued_due(pool, &due, &due_site_id).await? {
                Some(id) => due.id = id.to_string(),
                None => return Ok(None),
            },
            None => {
                let inner = self.state.inner.read().await;
                if inner.dues.iter().any(|d| {
                    crate::auth::same_id(&d.unit_id, &due.unit_id)
                        && d.period == due.period
                        && d.expense_type == due.expense_type
                }) {
                    return Ok(None);
                }
                due.id = format!("due-{}", uuid::Uuid::new_v4().simple());
            }
        }
        let joint_owners = if due.debtor_type == crate::models::DebtorType::Tenant {
            match self.pool() {
                Some(pool) => {
                    super::load_joint_liability_owners(pool, &due.id, &due_site_id).await?
                }
                None => {
                    let inner = self.state.inner.read().await;
                    inner
                        .units
                        .iter()
                        .find(|unit| crate::auth::same_id(&unit.id, &due.unit_id))
                        .and_then(|unit| {
                            unit.owner_user_id
                            .as_ref()
                            .and_then(|id| inner.users.iter().find(|user| &user.id == id))
                            .and_then(|owner| owner.person_id)
                            .map(|person_id| {
                                let period = crate::domain::billing_period::BillingPeriod::parse(
                                    &due.period,
                                )
                                .unwrap_or_else(|_| {
                                    crate::domain::billing_period::BillingPeriod::of_date(
                                        due.due_date,
                                    )
                                });
                                vec![crate::models::JointLiabilityOwner {
                                    person_id,
                                    tenant_person_id: unit
                                        .tenant_user_id
                                        .as_ref()
                                        .and_then(|id| {
                                            inner.users.iter().find(|user| &user.id == id)
                                        })
                                        .and_then(|tenant| tenant.person_id),
                                    start_date: period.first_day(),
                                    end_date: Some(period.last_day()),
                                }]
                            })
                        })
                        .unwrap_or_default()
                }
            }
        } else {
            Vec::new()
        };
        let mut inner = self.state.inner.write().await;
        if !joint_owners.is_empty() {
            inner
                .joint_liability_owners
                .insert(due.id.clone(), joint_owners);
        }
        inner.dues.push(due.clone());
        Ok(Some(due))
    }

    /// Units of a site that have a tenant (the occupant pays operational costs).
    pub async fn tenanted_units(
        &self,
        site_id: &str,
    ) -> DbResult<std::collections::HashSet<String>> {
        match self.pool() {
            Some(pool) => super::tenanted_unit_ids(pool, site_id).await,
            None => Ok(self
                .state
                .inner
                .read()
                .await
                .units
                .iter()
                .filter(|u| crate::auth::same_id(&u.site_id, site_id) && u.tenant_user_id.is_some())
                .map(|u| u.id.clone())
                .collect()),
        }
    }

    pub async fn set_budget_decision(&self, budget_id: &str, decision_id: i64) -> DbResult<()> {
        if let Some(p) = self.pool() {
            let client = p.get().await?;
            rec::set_budget_decision(&**client, budget_id, decision_id).await?;
        }
        self.state
            .inner
            .write()
            .await
            .finance
            .budget_decisions
            .insert(budget_id.to_string(), decision_id);
        Ok(())
    }

    pub async fn set_intent_options(
        &self,
        intent_id: &str,
        installments: i32,
        save_card: bool,
    ) -> DbResult<()> {
        if let Some(p) = self.pool() {
            let client = p.get().await?;
            rec::set_intent_options(&**client, intent_id, installments, save_card).await?;
        }
        self.state
            .inner
            .write()
            .await
            .finance
            .intent_options
            .insert(intent_id.to_string(), (installments, save_card));
        Ok(())
    }
}

/// Loads every SPEC-009 table at boot.
pub async fn load_finance_book(pool: &Pool) -> DbResult<FinanceBook> {
    let client = pool.get().await?;
    let c = &**client;
    let mut book = FinanceBook {
        privacy_notices: rec::load_all(c).await?,
        privacy_acknowledgements: rec::load_all(c).await?,
        consents: rec::load_all(c).await?,
        access_log: rec::load_all(c).await?,
        retention_policies: rec::load_all(c).await?,
        leases: rec::load_all(c).await?,
        notifications: rec::load_all(c).await?,
        dunning_policies: rec::load_all(c).await?,
        dunning_actions: rec::load_all(c).await?,
        virman_requests: rec::load_all(c).await?,
        disputes: rec::load_all(c).await?,
        payment_methods: rec::load_all(c).await?,
        mandates: rec::load_all(c).await?,
        autopay_attempts: rec::load_all(c).await?,
        vendors: rec::load_all(c).await?,
        approval_policies: rec::load_all(c).await?,
        expenses: rec::load_all(c).await?,
        expense_payments: rec::load_all(c).await?,
        journal_entries: rec::load_all(c).await?,
        journal_lines: rec::load_all(c).await?,
        cases: rec::load_all(c).await?,
        case_events: rec::load_all(c).await?,
        bank_feeds: rec::load_all(c).await?,
        bank_reconciliations: rec::load_all(c).await?,
        plans: rec::load_all(c).await?,
        plan_installments: rec::load_all(c).await?,
        adjustments: rec::load_all(c).await?,
        corrections: rec::load_all(c).await?,
        late_fee_accruals: rec::load_all(c).await?,
        heat_periods: rec::load_all(c).await?,
        heat_readings: rec::load_all(c).await?,
        heat_shares: rec::load_all(c).await?,
        meetings: rec::load_all(c).await?,
        agenda_items: rec::load_all(c).await?,
        attendance: rec::load_all(c).await?,
        votes: rec::load_all(c).await?,
        decisions: rec::load_all(c).await?,
        companies: rec::load_all(c).await?,
        company_sites: rec::load_all(c).await?,
        company_members: rec::load_all(c).await?,
        fee_invoices: rec::load_all(c).await?,
        ..FinanceBook::default()
    };
    book.budget_transitions = rec::load_site_budget_transitions(c)
        .await?
        .into_iter()
        .collect();
    book.intent_options = rec::load_intent_options(c)
        .await?
        .into_iter()
        .map(|(id, n, save)| (id, (n, save)))
        .collect();
    book.budget_decisions = c
        .query(
            "SELECT id, assembly_decision_id FROM operating_budgets WHERE assembly_decision_id IS NOT NULL",
            &[],
        )
        .await?
        .iter()
        .map(|r| (r.get::<_, i64>(0).to_string(), r.get::<_, i64>(1)))
        .collect();
    Ok(book)
}
