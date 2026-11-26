//! Dues periods and monthly dues accrual.

use super::*;
use crate::domain::billing_period::BillingPeriod;

#[derive(Debug, Deserialize)]
pub struct DuesPeriodsQuery {
    pub site_id: Option<String>,
}

/// Returns the defined billing periods for a site from the separate dues_periods table
pub async fn list_dues_periods(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(mut query): Query<DuesPeriodsQuery>,
) -> Result<Json<Vec<DuesPeriod>>, (StatusCode, String)> {
    scope.pin_opt(&mut query.site_id)?;
    let inner = state.inner.read().await;
    // No guessed tenant: the scope supplies the caller's site.
    let site_id = query
        .site_id
        .ok_or((StatusCode::BAD_REQUEST, "site_id is required".to_string()))?;
    let periods: Vec<DuesPeriod> = inner
        .dues_periods
        .iter()
        .filter(|p| {
            p.site_id == site_id
                || crate::db::parse_id_to_i64(&p.site_id) == crate::db::parse_id_to_i64(&site_id)
        })
        .cloned()
        .collect();
    Ok(Json(periods))
}

/// Creates a new billing period for a site in the dues_periods table
pub async fn create_dues_period(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Json(mut payload): Json<CreateDuesPeriodRequest>,
) -> Result<(StatusCode, Json<DuesPeriod>), (StatusCode, String)> {
    scope.pin(&mut payload.site_id)?;
    // The period is one canonical month: any spelling resolves to the same key.
    let billing_period = BillingPeriod::parse(&payload.period_name)
        .map_err(|reason| (StatusCode::BAD_REQUEST, reason))?;
    if !billing_period.accepts_due_date(payload.due_date) {
        return Err((
            StatusCode::BAD_REQUEST,
            format!(
                "Due date {} is outside period {} ({})",
                payload.due_date,
                billing_period.key(),
                billing_period.label()
            ),
        ));
    }
    payload.period_name = billing_period.label();
    let inner = state.inner.read().await;

    // Check if period already exists
    if let Some(existing) = inner.dues_periods.iter().find(|p| {
        (p.site_id == payload.site_id
            || crate::db::parse_id_to_i64(&p.site_id)
                == crate::db::parse_id_to_i64(&payload.site_id))
            && BillingPeriod::parse(&p.period_name).ok() == Some(billing_period)
    }) {
        return Ok((StatusCode::OK, Json(existing.clone())));
    }

    let max_p = inner
        .dues_periods
        .iter()
        .filter_map(|p| crate::db::parse_id_to_i64(&p.id))
        .max()
        .unwrap_or(0);
    let new_period = DuesPeriod {
        id: (max_p + 1).to_string(),
        site_id: payload.site_id.clone(),
        period_name: payload.period_name.clone(),
        due_date: payload.due_date,
        status: DuesPeriodStatus::Draft,
        created_at: Some(chrono::Utc::now()),
    };

    // Persist first, without the global lock; memory follows only on success.
    drop(inner);
    if let Some(ref pool) = state.pool {
        crate::db::save_dues_period(pool, &new_period)
            .await
            .map_err(|e| {
                if e.to_string()
                    .contains("cannot accrue into a closed billing period")
                {
                    (
                        StatusCode::CONFLICT,
                        "Billing period is closed and cannot be accrued".to_string(),
                    )
                } else {
                    (
                        StatusCode::SERVICE_UNAVAILABLE,
                        crate::error::sanitized("Database write failed", &e),
                    )
                }
            })?;
    }
    let mut inner = state.inner.write().await;
    if !inner.dues_periods.iter().any(|p| {
        crate::auth::same_id(&p.site_id, &new_period.site_id)
            && BillingPeriod::parse(&p.period_name).ok() == Some(billing_period)
    }) {
        inner.dues_periods.push(new_period.clone());
    }

    Ok((StatusCode::CREATED, Json(new_period)))
}

// SPEC-007 R5: the amount is the unit's monthly share of the operating budget
// (işletme projesi) in force on the due date, and the liability records that
// budget as its legal basis. A free-typed amount is refused while a budget is in
// force or when the site requires one; only a site without a budget falls back to
// its house-type tariffs, and the response then carries a KMK 37 warning.
pub async fn accrue_monthly_dues(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Json(mut payload): Json<AccrueDuesPeriodRequest>,
) -> Result<(StatusCode, Json<AccrueDuesPeriodResponse>), (StatusCode, String)> {
    scope.pin(&mut payload.site_id)?;
    use crate::services::operating_budget_service as budgets;

    // STORY-07-08: one canonical period key, and a due date that belongs to it.
    let billing_period = BillingPeriod::parse(&payload.period)
        .map_err(|reason| (StatusCode::BAD_REQUEST, reason))?;
    if !billing_period.accepts_due_date(payload.due_date) {
        return Err((
            StatusCode::BAD_REQUEST,
            format!(
                "Due date {} is outside period {} ({}); it must fall in that month or within {} days after it",
                payload.due_date,
                billing_period.key(),
                billing_period.label(),
                crate::domain::billing_period::DUE_DATE_GRACE_DAYS
            ),
        ));
    }
    if let Some(amt) = payload.amount {
        if amt <= Decimal::ZERO {
            return Err((
                StatusCode::BAD_REQUEST,
                "amount must be positive".to_string(),
            ));
        }
    }
    let period_key = billing_period.key();
    let period_label = billing_period.label();

    // The grace period in force now is fixed on every liability this run creates.
    let site_grace_days = state
        .inner
        .read()
        .await
        .site_accrual_schedules
        .get(&payload.site_id)
        .map_or(0, |s| s.grace_days);

    // 1. Decide every unit's amount and basis under a read lock.
    let (units_in_site, planned, mut skipped, budget_id, proration_enabled, accrued_on) = {
        let inner = state.inner.read().await;
        crate::services::billing_period_service::ensure_open_for_accrual(
            &inner,
            &payload.site_id,
            billing_period,
        )
        .map_err(|error| (StatusCode::CONFLICT, error.to_string()))?;
        let units_in_site: Vec<IndependentUnit> = inner
            .units
            .iter()
            .filter(|u| crate::auth::same_id(&u.site_id, &payload.site_id))
            .cloned()
            .collect();
        if units_in_site.is_empty() {
            return Err((
                StatusCode::NOT_FOUND,
                format!("No units found for site '{}'", payload.site_id),
            ));
        }
        let in_force = budgets::budget_in_force(&inner, &payload.site_id, payload.due_date)
            .map(|b| (b.id.clone(), b.fiscal_year));
        let required = budgets::site_requires_budget(&inner, &payload.site_id);
        if payload.amount.is_some() {
            if let Some((id, year)) = &in_force {
                return Err((
                    StatusCode::CONFLICT,
                    format!("Operating budget {} ({}) is in force on {}; dues are accrued from its unit shares, not a typed amount", id, year, payload.due_date),
                ));
            }
            if required {
                return Err((
                    StatusCode::CONFLICT,
                    "This site requires an operating budget (işletme projesi); a typed dues amount has no legal basis".to_string(),
                ));
            }
        } else if in_force.is_none() && required {
            return Err((
                StatusCode::CONFLICT,
                format!(
                    "No operating budget (işletme projesi) is in force on {}; issue an interim budget or record the assembly's approval first",
                    payload.due_date
                ),
            ));
        }
        let proration_enabled = inner
            .sites
            .iter()
            .find(|site| crate::auth::same_id(&site.id, &payload.site_id))
            .is_some_and(|site| site.proration_enabled);
        let accrued_on = crate::services::finance_common::site_today(&inner, &payload.site_id);
        let mut planned: Vec<(
            IndependentUnit,
            Decimal,
            Option<String>,
            Vec<OccupancyHistoryItem>,
        )> = Vec::new();
        let mut skipped: Vec<String> = Vec::new();
        for unit in &units_in_site {
            let basis = if let Some(typed_amount) = payload.amount {
                Ok(budgets::DuesBasis {
                    amount: typed_amount,
                    operating_budget_id: None,
                })
            } else {
                // Budget share, else house-type tariff. A unit with neither is
                // skipped and reported, never charged an invented amount.
                budgets::operational_dues_basis(&inner, unit, payload.due_date)
            };
            match basis {
                Ok(b) if b.amount > Decimal::ZERO => {
                    let history = inner
                        .unit_occupancies
                        .get(&unit.id)
                        .cloned()
                        .unwrap_or_default();
                    planned.push((unit.clone(), b.amount, b.operating_budget_id, history))
                }
                Ok(_) => skipped.push(format!(
                    "{}: zero share",
                    inner.unit_label(&unit.block_id, unit.unit_number)
                )),
                Err(reason) => skipped.push(format!(
                    "{}: {}",
                    inner.unit_label(&unit.block_id, unit.unit_number),
                    reason
                )),
            }
        }
        (
            units_in_site,
            planned,
            skipped,
            in_force.map(|(id, _)| id),
            proration_enabled,
            accrued_on,
        )
    };
    let total_units_in_site = units_in_site.len();
    // With PostgreSQL the occupancy (tenant or not) is read from the units table: a
    // tenant moved in without a user account has no in-memory tenant user.
    let (tenanted, owned): (
        Option<std::collections::HashSet<String>>,
        Option<std::collections::HashSet<String>>,
    ) = match state.pool {
        Some(ref pool) => {
            let t = crate::db::tenanted_unit_ids(pool, &payload.site_id)
                .await
                .map_err(|e| {
                    (
                        StatusCode::SERVICE_UNAVAILABLE,
                        crate::error::sanitized("Database unavailable", &e),
                    )
                })?;
            let o = crate::db::owned_unit_ids(pool, &payload.site_id)
                .await
                .map_err(|e| {
                    (
                        StatusCode::SERVICE_UNAVAILABLE,
                        crate::error::sanitized("Database unavailable", &e),
                    )
                })?;
            (Some(t), Some(o))
        }
        None => (None, None),
    };

    // With PostgreSQL the in-memory unit list can hold stale rows (their ids may
    // not exist, or belong to another site, in the database). Accrue only against
    // the canonical tenant-scoped inventory so every insert satisfies row-level
    // security instead of failing the whole batch.
    let canonical =
        crate::db::unit_repository::canonical_unit_ids(state.db_pool(), &payload.site_id)
            .await
            .map_err(|e| {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    crate::error::sanitized("Database unavailable", &e),
                )
            })?;
    let (planned, dropped_from_canonical): (Vec<_>, Vec<_>) = planned
        .into_iter()
        .partition(|(unit, ..)| canonical.as_ref().is_none_or(|ids| ids.contains(&unit.id)));

    for (unit, ..) in dropped_from_canonical {
        tracing::warn!(
            site_id = %payload.site_id,
            unit_id = %unit.id,
            "Unit is outside the canonical database inventory; skipping from accrual"
        );
        skipped.push(format!("{}: outside canonical inventory", unit.id));
    }

    let period_already_exists = {
        let inner = state.inner.read().await;
        inner.dues_periods.iter().any(|p| {
            crate::auth::same_id(&p.site_id, &payload.site_id)
                && BillingPeriod::parse(&p.period_name).ok() == Some(billing_period)
                && (p.status == DuesPeriodStatus::Active || p.status == DuesPeriodStatus::Closed)
        })
    };

    let existing_units: std::collections::HashSet<String> = {
        let inner = state.inner.read().await;
        let mut units = std::collections::HashSet::new();
        for due in &inner.dues {
            if crate::services::supplementary_charge_service::billed_period(&inner, due)
                == Some(billing_period)
                && due.expense_type == ExpenseType::OperationalDues
            {
                units.insert(due.unit_id.clone());
            }
        }
        units
    };

    // 2. Build every liability; nothing is written yet.
    let mut accrued: Vec<(DuesLiability, Option<String>)> = Vec::new();
    let mut units_without_owner: Vec<String> = Vec::new();
    for (unit, amount, basis, mut history) in planned {
        let is_owned = owned
            .as_ref()
            .map(|o| o.contains(&unit.id))
            .unwrap_or(unit.owner_user_id.is_some());
        if proration_enabled && !is_owned {
            let unit_code = {
                let inner = state.inner.read().await;
                let block_name = inner
                    .blocks
                    .iter()
                    .find(|b| crate::auth::same_id(&b.id, &unit.block_id))
                    .map(|b| b.block_name.as_str())
                    .unwrap_or(&unit.block_id);
                let block_code = block_name
                    .trim()
                    .strip_suffix("Blok")
                    .or_else(|| block_name.trim().strip_suffix("blok"))
                    .unwrap_or(block_name)
                    .trim();
                format!("{}-{}", block_code, unit.unit_number)
            };
            units_without_owner.push(unit_code);
            continue;
        }

        let is_tenant = tenanted
            .as_ref()
            .map(|t| t.contains(&unit.id))
            .unwrap_or(unit.tenant_user_id.is_some());
        if proration_enabled && history.is_empty() && is_tenant {
            history.push(OccupancyHistoryItem {
                id: 0,
                unit_id: crate::db::parse_id_to_i64(&unit.id).unwrap_or_default(),
                person_id: 0,
                person_name: String::new(),
                person_phone: None,
                person_email: None,
                role: DebtorType::Tenant,
                start_date: billing_period.first_day().to_string(),
                end_date: None,
                is_active: true,
                exit_balance: Decimal::ZERO,
                notes: None,
                created_at: chrono::Utc::now(),
            });
        }
        let shares = if proration_enabled {
            crate::services::occupancy_service::accrual_shares(
                amount,
                billing_period,
                unit.created_on,
                &history,
                true,
                accrued_on,
            )
        } else {
            vec![(
                if is_tenant {
                    DebtorType::Tenant
                } else {
                    DebtorType::Owner
                },
                amount,
                None,
            )]
        };
        if existing_units.contains(&unit.id) {
            continue;
        }
        for (debtor_type, share_amount, share_person) in shares {
            let history_pid = if debtor_type == DebtorType::Tenant {
                history
                    .iter()
                    .filter(|h| h.role == DebtorType::Tenant && h.is_active && h.person_id > 0)
                    .map(|h| h.person_id)
                    .next_back()
            } else {
                None
            };
            // Days no session covers are the titled owner's; the insert names the same
            // person, so this only matters for the in-memory path.
            let owner_pid = if debtor_type == DebtorType::Owner {
                unit.owner_user_id
                    .as_deref()
                    .and_then(|id| id.strip_prefix("person-").unwrap_or(id).parse::<i64>().ok())
            } else {
                None
            };
            let liable_person_id = share_person.or(history_pid).or(owner_pid);
            accrued.push((
                DuesLiability {
                    id: String::new(),
                    unit_id: unit.id.clone(),
                    period: period_label.clone(),
                    principal_amount: share_amount,
                    delay_penalty: Decimal::ZERO,
                    total_amount: share_amount,
                    due_date: payload.due_date,
                    status: DebtStatus::Pending,
                    paid_principal: Decimal::ZERO,
                    paid_penalty: Decimal::ZERO,
                    debtor_type,
                    expense_type: ExpenseType::OperationalDues,
                    penalty_accrued_through: None,
                    grace_days: site_grace_days,
                    effective_due_date: Some(DuesLiability::effective_due_date_for(
                        payload.due_date,
                        accrued_on,
                    )),
                    liable_person_id,
                },
                basis.clone(),
            ));
        }
    }

    // 3. One transaction per site batch: the period row, every liability (linked to it,
    //    with its budget basis) and the run report commit together or not at all.
    //    Memory follows from the committed result only.
    let mut period_db_id: Option<String> = None;
    let mut joint_owners = std::collections::HashMap::new();
    if let Some(ref pool) = state.pool {
        if !accrued.is_empty() || !skipped.is_empty() || !units_without_owner.is_empty() {
            let committed = crate::db::commit_accrual_batch(
                pool,
                &crate::db::AccrualBatch {
                    site_id: &payload.site_id,
                    period_key: &period_key,
                    period_label: &period_label,
                    due_date: payload.due_date,
                    source: "MANUAL",
                    dues: &accrued,
                    skipped: &skipped,
                },
            )
            .await
            .map_err(|e| {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    crate::error::sanitized("Database write failed", &e),
                )
            })?;
            period_db_id = committed.period_id.map(|id| id.to_string());
            joint_owners = committed.joint_owners;
            let mut kept = Vec::new();
            for (((mut due, basis), id), liable_pid) in accrued
                .into_iter()
                .zip(committed.due_ids)
                .zip(committed.liable_person_ids)
            {
                if let Some(id) = id {
                    due.id = id.to_string();
                    if liable_pid.is_some() {
                        due.liable_person_id = liable_pid;
                    }
                    kept.push((due, basis)); // else accrued concurrently
                }
            }
            accrued = kept;
        }
    }

    {
        let mut inner = state.inner.write().await;
        let known = inner.dues_periods.iter().any(|p| {
            crate::auth::same_id(&p.site_id, &payload.site_id)
                && BillingPeriod::parse(&p.period_name).ok() == Some(billing_period)
        });
        if !known {
            let id = period_db_id.unwrap_or_else(|| {
                (inner
                    .dues_periods
                    .iter()
                    .filter_map(|p| crate::db::parse_id_to_i64(&p.id))
                    .max()
                    .unwrap_or(0)
                    + 1)
                .to_string()
            });
            inner.dues_periods.push(DuesPeriod {
                id,
                site_id: payload.site_id.clone(),
                period_name: period_label.clone(),
                due_date: payload.due_date,
                status: DuesPeriodStatus::Active,
                created_at: Some(chrono::Utc::now()),
            });
        } else if let Some(period) = inner.dues_periods.iter_mut().find(|period| {
            crate::auth::same_id(&period.site_id, &payload.site_id)
                && BillingPeriod::parse(&period.period_name).ok() == Some(billing_period)
        }) {
            period.status = DuesPeriodStatus::Active;
        }
    }

    let mut inner = state.inner.write().await;
    let mut total_amount_accrued = Decimal::ZERO;
    let newly_accrued_units_count = accrued
        .iter()
        .map(|(due, _)| due.unit_id.as_str())
        .collect::<std::collections::HashSet<_>>()
        .len();
    for (mut due, basis) in accrued {
        if due.id.is_empty() {
            due.id = (inner
                .dues
                .iter()
                .filter_map(|d| crate::db::parse_id_to_i64(&d.id))
                .max()
                .unwrap_or(0)
                + 1)
            .to_string();
        }
        total_amount_accrued += due.principal_amount;
        if let Some(b) = basis {
            inner.dues_budget_basis.insert(due.id.clone(), b);
        }
        inner.dues.push(due);
    }
    inner.joint_liability_owners.extend(joint_owners);
    drop(inner);
    let legal_basis_warning = budget_id.is_none().then(|| {
        "KMK 37 (Law 7579): these dues were accrued without an operating budget (işletme projesi) in force; they have no assembly-approved basis".to_string()
    });

    if newly_accrued_units_count == 0 {
        return Ok((
            StatusCode::OK,
            Json(AccrueDuesPeriodResponse {
                site_id: payload.site_id,
                period: period_label.clone(),
                period_key: period_key.clone(),
                total_units_accrued: total_units_in_site,
                newly_accrued_units_count: 0,
                auto_settled_units_count: 0,
                total_amount_accrued: Decimal::ZERO,
                total_amount_offset_from_advance: Decimal::ZERO,
                already_accrued: period_already_exists,
                message: if period_already_exists {
                    format!("'{}' dönemi için aidat tahakkuku bu sitede daha önce yapılmış. Mükerrer tahakkuk engellendi.", period_label)
                } else if !units_without_owner.is_empty() {
                    format!(
                        "'{}' dönemi için aidat tahakkuku tamamlandı. {} dairede kat maliki bulunmadığından tahakkuk yapılmadı.",
                        period_label,
                        units_without_owner.len()
                    )
                } else {
                    format!(
                        "'{}' dönemi için tahakkuk yapılamadı: {}",
                        period_label,
                        skipped.join("; ")
                    )
                },
                operating_budget_id: budget_id,
                legal_basis_warning: None,
                skipped_units: skipped,
                units_without_owner,
            }),
        ));
    }

    // Apply available advance payments against the newly accrued dues of this
    // site only (each unit in its own tenant-bound transaction).
    let offset = settle_advances(&state, OffsetScope::Site(&payload.site_id))
        .await
        .map_err(|e| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                crate::error::sanitized("Internal error", &e),
            )
        })?;
    let (auto_settled_count, total_offset) = (offset.fully_settled_dues, offset.total_offset);

    Ok((
        StatusCode::OK,
        Json(AccrueDuesPeriodResponse {
            site_id: payload.site_id,
            period: period_label.clone(),
            period_key: period_key.clone(),
            total_units_accrued: total_units_in_site,
            newly_accrued_units_count,
            auto_settled_units_count: auto_settled_count,
            total_amount_accrued,
            total_amount_offset_from_advance: total_offset,
            already_accrued: false,
            message: {
                let mut message = format!(
                    "'{}' dönemi için {} daireye başarıyla aidat tahakkuk ettirildi. {} daire avanstan otomatik kapatıldı.",
                    period_label, newly_accrued_units_count, auto_settled_count
                );
                if !units_without_owner.is_empty() {
                    message.push_str(&format!(
                        " Kat maliki bulunmayan daireler: {}",
                        units_without_owner.join(", ")
                    ));
                }
                if !skipped.is_empty() {
                    message.push_str(&format!(
                        " {} daire atlandı: {}",
                        skipped.len(),
                        skipped.join("; ")
                    ));
                }
                message
            },
            operating_budget_id: budget_id,
            legal_basis_warning,
            skipped_units: skipped,
            units_without_owner,
        }),
    ))
}

/// The latest accrual runs of a site with the units each one skipped and why, so the
/// manager sees what a scheduled run did not charge (STORY-07-08). Empty without
/// PostgreSQL, where the manual response already lists the skipped units.
pub async fn list_accrual_runs(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(mut query): Query<DuesPeriodsQuery>,
) -> Result<Json<Vec<crate::db::AccrualRunRecord>>, (StatusCode, String)> {
    scope.pin_opt(&mut query.site_id)?;
    let site_id = query
        .site_id
        .ok_or((StatusCode::BAD_REQUEST, "site_id is required".to_string()))?;
    let Some(ref pool) = state.pool else {
        return Ok(Json(Vec::new()));
    };
    crate::db::list_accrual_runs(pool, &site_id, 50)
        .await
        .map(Json)
        .map_err(|e| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                crate::error::sanitized("Database unavailable", &e),
            )
        })
}
