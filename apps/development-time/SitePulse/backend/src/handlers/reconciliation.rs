//! Bank statements, reconciliation queue, sender IBANs, bank accounts and the signed bank webhook.

use super::*;

// 8. Bank Statement Ingestion & Automated Reconciliation Handlers (STORY-07-02)
pub async fn parse_bank_statement(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Json(mut payload): Json<ParseBankStatementRequest>,
) -> Result<(StatusCode, Json<ParseBankStatementResponse>), (StatusCode, String)> {
    scope.pin(&mut payload.site_id)?;
    // Automatically derive permissible format from the site's active bank account
    let bank_service = SiteBankAccountService::new(state.clone());
    let active_account = bank_service.get_active_account(&payload.site_id).await;

    let effective_format = match active_account {
        Some(ref account) => {
            let bank_fmt = match account.statement_format.as_str() {
                "EXCEL" => BankStatementFormat::Excel,
                "CSV" => BankStatementFormat::Csv,
                "MT940" => BankStatementFormat::Mt940,
                _ => BankStatementFormat::Auto,
            };

            // If caller specified an explicit format, verify it matches the active bank's permissible format
            if let Some(req_fmt) = payload.format {
                if req_fmt != BankStatementFormat::Auto && req_fmt != bank_fmt {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        format!(
                            "Invalid file format: Site '{}' bank '{}' requires {} statement files. {:?} is not allowed.",
                            payload.site_id, account.bank_name, account.statement_format, req_fmt
                        ),
                    ));
                }
            }

            // Validate file content structure against bank's format
            let trimmed = payload.content.trim();
            let is_mt940 = trimmed.starts_with(":20:")
                || (trimmed.contains(":61:") && trimmed.contains(":86:"));
            if bank_fmt == BankStatementFormat::Mt940 && !is_mt940 {
                return Err((
                    StatusCode::BAD_REQUEST,
                    format!(
                        "File format mismatch: Bank '{}' requires SWIFT MT940 format (with :20:, :61:, :86: tags), but uploaded file is tabular/CSV.",
                        account.bank_name
                    ),
                ));
            } else if (bank_fmt == BankStatementFormat::Excel
                || bank_fmt == BankStatementFormat::Csv)
                && is_mt940
            {
                return Err((
                    StatusCode::BAD_REQUEST,
                    format!(
                        "File format mismatch: Bank '{}' requires {} format, but uploaded file appears to be SWIFT MT940.",
                        account.bank_name, account.statement_format
                    ),
                ));
            }

            Some(bank_fmt)
        }
        None => payload.format,
    };

    let parser = crate::services::BankStatementParser::new();
    let recon_service = crate::services::ReconciliationService::new();

    let today = crate::e2e_clock::now_utc().date_naive();
    let report = parser
        .parse_statement_report(&payload.content, effective_format, today)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    let txns = report.transactions;
    let mut inner = state.inner.write().await;

    // Filter units, users, and dues for the requested site_id
    let site_units: Vec<IndependentUnit> = inner
        .units
        .iter()
        .filter(|u| u.site_id == payload.site_id)
        .cloned()
        .collect();

    let site_users: Vec<User> = inner
        .users
        .iter()
        .filter(|u| u.site_id == payload.site_id)
        .cloned()
        .collect();

    let site_dues: Vec<DuesLiability> = inner
        .dues
        .iter()
        .filter(|d| site_units.iter().any(|u| u.id == d.unit_id))
        .cloned()
        .collect();

    let matches = recon_service.reconcile_transactions_with_site(
        Some(&payload.site_id),
        &txns,
        &site_units,
        &site_users,
        &site_dues,
        today,
    );

    // Append to reconciliation queue in state
    for m in &matches {
        inner.reconciliation_queue.push(m.clone());
    }
    drop(inner);

    if let Some(ref pool) = state.pool {
        let site_bank_id = active_account
            .as_ref()
            .and_then(|a| crate::db::parse_id_to_i64(&a.id));
        for m in &matches {
            crate::db::save_reconciliation_match_for_site(pool, m, &payload.site_id, site_bank_id)
                .await
                .map_err(|e| {
                    (
                        StatusCode::SERVICE_UNAVAILABLE,
                        crate::error::sanitized("Database write failed", &e),
                    )
                })?;
        }
    }

    let matched_count = matches
        .iter()
        .filter(|m| m.status == ReconciliationStatus::PendingApproval)
        .count();
    let already_processed_count = matches
        .iter()
        .filter(|m| m.status == ReconciliationStatus::AlreadyProcessed)
        .count();
    let unmatched_count = matches
        .iter()
        .filter(|m| m.status == ReconciliationStatus::Unmatched)
        .count();

    Ok((
        StatusCode::OK,
        Json(ParseBankStatementResponse {
            site_id: payload.site_id,
            total_transactions: matches.len(),
            matched_count,
            unmatched_count,
            already_processed_count,
            matches,
            skipped_entries: report.skipped,
        }),
    ))
}

pub async fn get_reconciliation_queue(
    State(state): State<AppState>,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Json<Vec<ReconciliationMatch>> {
    let site_id = params
        .get("site_id")
        .or_else(|| params.get("siteId"))
        .map(String::as_str);
    if let Some(p) = state.db_pool() {
        if let Ok(db_queue) = crate::db::fetch_reconciliation_queue_from_db(p, site_id).await {
            return Json(db_queue);
        }
    }
    let inner = state.inner.read().await;
    if let Some(target_site) = site_id {
        let filtered: Vec<ReconciliationMatch> = inner
            .reconciliation_queue
            .iter()
            .filter(|m| crate::auth::same_id(&m.site_id, target_site))
            .cloned()
            .collect();
        Json(filtered)
    } else {
        Json(inner.reconciliation_queue.clone())
    }
}

pub async fn confirm_reconciliation(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Json(mut payload): Json<ConfirmReconciliationRequest>,
) -> Result<(StatusCode, Json<ConfirmReconciliationResponse>), (StatusCode, String)> {
    scope.pin(&mut payload.site_id)?;
    // Phase 1 (state lock): tenant boundary and the lines to settle.
    struct Line {
        match_id: String,
        unit: crate::models::IndependentUnit,
        payer_role: DebtorType,
        payer_name: String,
        request_designation: Option<crate::models::PaymentDesignation>,
        settles_owner_capital_dues: bool,
        item: ReconciliationMatch,
    }
    let lines: Vec<Line> = {
        let inner = state.inner.read().await;
        let submitted: std::collections::HashMap<_, _> = payload
            .matches
            .iter()
            .map(|m| (m.match_id.as_str(), m))
            .collect();
        for match_id in &payload.match_ids {
            if let Some(m) = inner
                .reconciliation_queue
                .iter()
                .find(|m| m.match_id == *match_id)
                .or_else(|| submitted.get(match_id.as_str()).copied())
            {
                if !m.site_id.is_empty() && !crate::auth::same_id(&m.site_id, &payload.site_id) {
                    return Err((
                        StatusCode::FORBIDDEN,
                        format!(
                            "Match {} belongs to site {}, not {}",
                            match_id, m.site_id, payload.site_id
                        ),
                    ));
                }
            }
        }
        let mut lines = Vec::new();
        for match_id in &payload.match_ids {
            let Some(m) = inner
                .reconciliation_queue
                .iter()
                .find(|m| m.match_id == *match_id)
                .or_else(|| submitted.get(match_id.as_str()).copied())
            else {
                continue;
            };
            let Some(unit) = m
                .matched_unit_id
                .as_ref()
                .and_then(|uid| inner.units.iter().find(|u| &u.id == uid))
                .cloned()
            else {
                continue;
            };
            if !crate::auth::same_id(&unit.site_id, &payload.site_id) {
                return Err((
                    StatusCode::FORBIDDEN,
                    format!(
                        "Unit {} does not belong to site {}",
                        unit.id, payload.site_id
                    ),
                ));
            }
            let queued = inner
                .reconciliation_queue
                .iter()
                .find(|q| q.match_id == *match_id);
            if match_id.starts_with(DEBTOR_REVIEW_PREFIX)
                && queued.is_some_and(|q| q.status == ReconciliationStatus::Approved)
            {
                return Err((
                    StatusCode::CONFLICT,
                    format!("Match {} is already approved", match_id),
                ));
            }
            let assigned = payload.debtor_assignments.get(match_id).copied();
            if assigned.is_none()
                && queued.is_some_and(|q| {
                    q.status == ReconciliationStatus::Unmatched
                        && q.notes.as_deref() == Some(SEVERAL_OPEN_DEBTORS_REASON)
                })
            {
                return Err((
                    StatusCode::UNPROCESSABLE_ENTITY,
                    format!(
                        "Match {} needs a debtor assignment (several open debtors)",
                        match_id
                    ),
                ));
            }
            let (resolved_role, resolved_name) =
                resolve_payer(&inner, &unit, m.transaction.sender_name.as_deref());
            let (payer_role, payer_name) = match assigned {
                Some(role) => (role, resolved_name),
                None => (resolved_role, resolved_name),
            };
            // A due id is only trusted when it names a real due of the matched unit;
            // client-built rows may carry placeholders, which fall back to oldest-first.
            let matched_due_id = m.matched_due_id.clone().filter(|due_id| {
                inner
                    .dues
                    .iter()
                    .any(|due| &due.id == due_id && due.unit_id == unit.id)
            });
            let request_designation =
                matched_due_id
                    .clone()
                    .map(|due_id| crate::models::PaymentDesignation {
                        due_ids: vec![due_id],
                        ..Default::default()
                    });
            lines.push(Line {
                match_id: match_id.clone(),
                unit,
                payer_role,
                payer_name,
                request_designation,
                settles_owner_capital_dues: payload.owner_capital_match_ids.contains(match_id),
                item: {
                    let mut item = m.clone();
                    item.site_id = payload.site_id.clone();
                    item.matched_due_id = matched_due_id;
                    item
                },
            });
        }
        lines
    };

    // Phase 2: each line through the canonical ingestion path (SPEC-005 R1),
    // idempotent on the statement transaction, so a re-confirmation is harmless.
    let service = crate::services::PaymentTrackingService::new(state.clone());
    let mut confirmed: Vec<(Line, crate::models::PaymentReceipt)> = Vec::new();
    let mut failure: Option<(StatusCode, String)> = None;
    for line in lines {
        let txn = &line.item.transaction;
        let key = if txn.transaction_id.trim().is_empty() {
            line.match_id.clone()
        } else {
            txn.transaction_id.clone()
        };
        let result = service
            .record_and_allocate_payment(crate::models::RecordManualPaymentRequest {
                site_id: Some(line.unit.site_id.clone()),
                unit_id: line.unit.id.clone(),
                amount: txn.amount,
                payer_name: line.payer_name.clone(),
                payer_role: line.payer_role,
                payment_channel: PaymentChannel::BankStatement,
                description: Some(txn.description.clone()),
                // The money arrived on the statement date; penalties stop accruing there.
                payment_date: txn.date.and_hms_opt(0, 0, 0).map(|d| d.and_utc()),
                idempotency_key: Some(format!("STMT:{}", key)),
                designation: line.request_designation.clone(),
                settles_owner_capital_dues: line.settles_owner_capital_dues,
                settles_tenant_joint_liability: false,
                external_reference: txn.reference_no.clone().or_else(|| Some(key.clone())),
                designate_from_description: true,
                settles_unmatched_entry_id: None,
            })
            .await;
        match result {
            Ok(receipt) => confirmed.push((line, receipt)),
            Err(e) => {
                let (code, msg) = payment_error_status(e);
                failure = Some((
                    code,
                    format!("Statement line {} was not settled: {}", line.match_id, msg),
                ));
                break;
            }
        }
    }

    // Phase 3 (state lock): queue status and remembered sender IBANs for what settled.
    let mut inner = state.inner.write().await;
    let mut confirmed_matches = Vec::new();
    let mut updated_unit_ids = Vec::new();
    let mut total_amount_cleared = Decimal::ZERO;
    let mut remembered: Vec<(String, String)> = Vec::new();
    for (line, receipt) in &confirmed {
        if let Some(m) = inner
            .reconciliation_queue
            .iter_mut()
            .find(|m| m.match_id == line.match_id)
        {
            m.status = ReconciliationStatus::Approved;
            m.status_code = ReconciliationStatus::Approved.as_str().to_string();
            m.notes = Some(format!(
                "Makbuz {}: ₺{:.2} borca, ₺{:.2} avansa işlendi",
                receipt.receipt_number,
                receipt.allocated_principal + receipt.allocated_penalty,
                receipt.allocated_advance
            ));
            confirmed_matches.push(m.clone());
        } else {
            let mut m = line.item.clone();
            m.status = ReconciliationStatus::Approved;
            m.status_code = ReconciliationStatus::Approved.as_str().to_string();
            m.notes = Some(format!(
                "Makbuz {}: ₺{:.2} borca, ₺{:.2} avansa işlendi",
                receipt.receipt_number,
                receipt.allocated_principal + receipt.allocated_penalty,
                receipt.allocated_advance
            ));
            inner.reconciliation_queue.push(m.clone());
            confirmed_matches.push(m);
        }
        updated_unit_ids.push(line.unit.id.clone());
        total_amount_cleared += line.item.transaction.amount;
        if payload.remember_sender_iban == Some(true) {
            if let Some(sender_iban) = &line.item.transaction.sender_iban {
                let clean = sender_iban.replace(' ', "").to_uppercase();
                if !clean.is_empty() {
                    remembered.push((line.unit.id.clone(), clean));
                }
            }
        }
    }
    for (unit_id, iban) in &remembered {
        inner
            .remembered_sender_ibans
            .insert(iban.clone(), unit_id.clone());
    }
    let confirmed_count = confirmed_matches.len();
    // The queue is updated in memory; release the global lock before the
    // database writes below.
    drop(inner);

    if let Some(ref pool) = state.pool {
        for m in &confirmed_matches {
            crate::db::save_reconciliation_match_for_site(pool, m, &payload.site_id, None)
                .await
                .map_err(|e| {
                    (
                        StatusCode::SERVICE_UNAVAILABLE,
                        crate::error::sanitized("Database write failed", &e),
                    )
                })?;
            crate::db::update_reconciliation_status(
                pool,
                &m.match_id,
                ReconciliationStatus::Approved,
                m.notes.as_deref(),
            )
            .await
            .map_err(|e| {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    crate::error::sanitized("Database write failed", &e),
                )
            })?;
        }
        for (uid, iban) in &remembered {
            // (iban, unit_id): the arguments used to be swapped, so remembering a
            // sender IBAN always failed after the payments had settled.
            crate::db::save_remembered_sender_iban(pool, iban, uid, None, None)
                .await
                .map_err(|e| {
                    (
                        StatusCode::SERVICE_UNAVAILABLE,
                        crate::error::sanitized("Database write failed", &e),
                    )
                })?;
        }
    }
    if let Some((code, msg)) = failure {
        // Lines before the failing one are settled and recorded; retrying the
        // whole batch is safe (each line is idempotent).
        return Err((
            code,
            format!(
                "{} ({} line(s) settled before the failure)",
                msg, confirmed_count
            ),
        ));
    }

    let message_sent = payload
        .optional_message
        .as_ref()
        .map(|msg| !msg.trim().is_empty())
        .unwrap_or(false);
    let notification_summary = if message_sent {
        Some(format!(
            "{} ev sahibine/kat sakinine bilgilendirme mesajı iletildi.",
            confirmed_count
        ))
    } else {
        None
    };

    Ok((
        StatusCode::OK,
        Json(ConfirmReconciliationResponse {
            confirmed_count,
            total_amount_cleared,
            updated_unit_ids,
            confirmed_matches,
            message_sent,
            notification_summary,
            remembered_ibans_count: remembered.len(),
        }),
    ))
}

pub async fn remember_sender_iban(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Json(mut payload): Json<RememberSenderIbanRequest>,
) -> Result<Json<RememberSenderIbanResponse>, (StatusCode, String)> {
    scope.pin(&mut payload.site_id)?;
    let clean = payload.sender_iban.replace(' ', "").to_uppercase();
    if clean.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Sender IBAN cannot be empty.".to_string(),
        ));
    }
    let in_site = {
        let inner = state.inner.read().await;
        inner.units.iter().any(|u| {
            crate::auth::same_id(&u.id, &payload.unit_id)
                && crate::auth::same_id(&u.site_id, &payload.site_id)
        })
    };
    if !in_site {
        return Err((
            StatusCode::NOT_FOUND,
            format!("Unit '{}' not found in this site.", payload.unit_id),
        ));
    }

    // Database first, without the global lock; memory follows on success.
    if let Some(ref pool) = state.pool {
        crate::db::save_remembered_sender_iban(
            pool,
            &clean,
            &payload.unit_id,
            payload.sender_name.as_deref(),
            None,
        )
        .await
        .map_err(|e| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                crate::error::sanitized("Database write failed", &e),
            )
        })?;
    }
    {
        let mut inner = state.inner.write().await;
        inner
            .remembered_sender_ibans
            .insert(clean.clone(), payload.unit_id.clone());
        if let Some(ref sender_name) = payload.sender_name {
            inner
                .sender_iban_metadata
                .insert(clean.clone(), (Some(sender_name.clone()), None));
        }
    }

    Ok(Json(RememberSenderIbanResponse {
        success: true,
        unit_id: payload.unit_id,
        sender_iban: clean,
        message: "Sender IBAN successfully mapped and remembered for automated future matching."
            .to_string(),
    }))
}

// 8b. Homeowner Payment Matching Criteria Handlers
pub async fn get_unit_matching_criteria(
    Path(unit_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<UnitMatchingCriteriaDto>, (StatusCode, String)> {
    let inner = state.inner.read().await;
    let unit = inner
        .units
        .iter()
        .find(|u| u.id == unit_id)
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                format!("Unit '{}' not found", unit_id),
            )
        })?;

    let owner_name = unit
        .owner_user_id
        .as_ref()
        .and_then(|uid| inner.users.iter().find(|u| &u.id == uid))
        .map(|u| u.full_name.clone())
        .unwrap_or_default();

    let mut remembered = Vec::new();
    for (iban, u_id) in &inner.remembered_sender_ibans {
        if u_id == &unit_id {
            let (label, bank_name) = inner
                .sender_iban_metadata
                .get(iban)
                .cloned()
                .unwrap_or((None, None));
            remembered.push(RegisteredSenderIbanDto {
                sender_iban: iban.clone(),
                formatted_iban: VirtualIbanService::format_for_display(iban),
                label,
                bank_name,
            });
        }
    }
    remembered.sort_by(|a, b| a.sender_iban.cmp(&b.sender_iban));

    let registered_payer_names = inner
        .unit_payer_names
        .get(&unit_id)
        .cloned()
        .unwrap_or_else(|| vec![owner_name.clone()]);

    let recommended_desc = inner.unit_label(&unit.block_id, unit.unit_number);

    Ok(Json(UnitMatchingCriteriaDto {
        unit_id: unit.id.clone(),
        block: unit.block_id.clone(),
        unit_number: unit.unit_number,
        resident_name: owner_name,
        virtual_iban: unit.virtual_iban.clone(),
        remembered_ibans: remembered,
        registered_payer_names,
        recommended_description: recommended_desc,
    }))
}

pub async fn add_unit_sender_iban(
    Path(unit_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<AddSenderIbanRequest>,
) -> Result<Json<UnitMatchingCriteriaDto>, (StatusCode, String)> {
    let clean = payload.sender_iban.replace(' ', "").to_uppercase();
    if clean.len() < 15 {
        return Err((
            StatusCode::BAD_REQUEST,
            "Geçersiz IBAN formatı (minimum 15 karakter).".to_string(),
        ));
    }

    let known = {
        let inner = state.inner.read().await;
        inner
            .units
            .iter()
            .any(|u| crate::auth::same_id(&u.id, &unit_id))
    };
    if !known {
        return Err((
            StatusCode::NOT_FOUND,
            format!("Unit '{}' not found", unit_id),
        ));
    }

    // Database first, without the global lock: (iban, unit_id) — the arguments
    // used to be swapped, so every database-backed save failed.
    if let Some(ref pool) = state.pool {
        crate::db::save_remembered_sender_iban(
            pool,
            &clean,
            &unit_id,
            payload.label.as_deref(),
            payload.bank_name.as_deref(),
        )
        .await
        .map_err(|e| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                crate::error::sanitized("Database write failed", &e),
            )
        })?;
    }
    {
        let mut inner = state.inner.write().await;
        inner
            .remembered_sender_ibans
            .insert(clean.clone(), unit_id.clone());
        inner.sender_iban_metadata.insert(
            clean.clone(),
            (payload.label.clone(), payload.bank_name.clone()),
        );
    }

    get_unit_matching_criteria(Path(unit_id), State(state)).await
}

pub async fn delete_unit_sender_iban(
    Path((unit_id, sender_iban)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<Json<UnitMatchingCriteriaDto>, (StatusCode, String)> {
    let clean = sender_iban.replace(' ', "").to_uppercase();
    {
        let mut inner = state.inner.write().await;
        if let Some(mapped_unit) = inner.remembered_sender_ibans.get(&clean) {
            if mapped_unit == &unit_id {
                inner.remembered_sender_ibans.remove(&clean);
                inner.sender_iban_metadata.remove(&clean);
            }
        }
    }

    if let Some(ref pool) = state.pool {
        crate::db::delete_remembered_sender_iban(pool, &clean)
            .await
            .map_err(|e| {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    crate::error::sanitized("Database write failed", &e),
                )
            })?;
    }

    get_unit_matching_criteria(Path(unit_id), State(state)).await
}

pub async fn update_unit_payer_names(
    Path(unit_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<UpdatePayerNamesRequest>,
) -> Result<Json<UnitMatchingCriteriaDto>, (StatusCode, String)> {
    let cleaned_names: Vec<String> = payload
        .payer_names
        .into_iter()
        .map(|n| n.trim().to_string())
        .filter(|n| !n.is_empty())
        .collect();

    {
        let mut inner = state.inner.write().await;
        if !inner.units.iter().any(|u| u.id == unit_id) {
            return Err((
                StatusCode::NOT_FOUND,
                format!("Unit '{}' not found", unit_id),
            ));
        }

        inner
            .unit_payer_names
            .insert(unit_id.clone(), cleaned_names.clone());
    }

    if let Some(ref pool) = state.pool {
        crate::db::save_unit_payer_names(pool, &unit_id, &cleaned_names)
            .await
            .map_err(|e| {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    crate::error::sanitized("Database write failed", &e),
                )
            })?;
    }

    get_unit_matching_criteria(Path(unit_id), State(state)).await
}

// 9. Site Bank Account Configuration Handlers (STORY-08-01)
pub async fn list_supported_banks() -> Json<Vec<SupportedBankEntry>> {
    Json(SiteBankAccountService::list_supported_banks())
}

pub async fn get_site_bank_account(
    Path(site_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<BankAccountConfigResponse>, (StatusCode, String)> {
    let service = SiteBankAccountService::new(state);
    match service.get_active_account(&site_id).await {
        Some(account) => Ok(Json(account)),
        None => Err((
            StatusCode::NOT_FOUND,
            format!("No active bank account configured for site '{}'", site_id),
        )),
    }
}

pub async fn configure_site_bank_account(
    Path(site_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<ConfigureBankAccountRequest>,
) -> Result<(StatusCode, Json<BankAccountConfigResponse>), (StatusCode, String)> {
    let service = SiteBankAccountService::new(state);
    service
        .configure_account(&site_id, payload)
        .await
        .map(|res| (StatusCode::OK, Json(res)))
        .map_err(|err| (StatusCode::BAD_REQUEST, err))
}

// 10. Kuveyt Türk Sandbox & Flat Virtual IBAN Allocation Handlers (STORY-07-01 & STORY-07-06)
pub async fn get_or_allocate_virtual_iban(
    Path(unit_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let mut inner = state.inner.write().await;
    let unit = inner
        .units
        .iter_mut()
        .find(|u| u.id == unit_id)
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                format!("Unit '{}' not found", unit_id),
            )
        })?;

    if let Some(existing) = &unit.virtual_iban {
        return Ok(Json(json!({
            "unit_id": unit.id,
            "virtual_iban": existing,
            "formatted": VirtualIbanService::format_for_display(existing),
            "bank_code": VirtualIbanService::KUVEYT_TURK_BANK_CODE,
            "bank_name": "Kuveyt Türk Katılım Bankası",
            "status": "ALLOCATED"
        })));
    }

    let generated = VirtualIbanService::generate_virtual_iban(
        VirtualIbanService::KUVEYT_TURK_BANK_CODE,
        &unit.site_id,
        &unit.block_id,
        unit.unit_number,
    )
    .map_err(|e| (StatusCode::UNPROCESSABLE_ENTITY, e.to_string()))?;
    unit.virtual_iban = Some(generated.clone());

    Ok(Json(json!({
        "unit_id": unit.id,
        "virtual_iban": generated,
        "formatted": VirtualIbanService::format_for_display(&generated),
        "bank_code": VirtualIbanService::KUVEYT_TURK_BANK_CODE,
        "bank_name": "Kuveyt Türk Katılım Bankası",
        "status": "NEWLY_ALLOCATED"
    })))
}

pub async fn get_kuveyt_turk_status(
    State(state): State<AppState>,
) -> Json<crate::services::KuveytTurkSandboxConfig> {
    let inner = state.inner.read().await;
    let service = KuveytTurkSandboxService::new();
    let config = service.get_config_status(inner.kuveyt_turk_client_id.as_deref());
    Json(config)
}

pub async fn configure_kuveyt_turk(
    State(state): State<AppState>,
    Json(payload): Json<crate::services::ConfigureKuveytTurkRequest>,
) -> (StatusCode, Json<crate::services::KuveytTurkSandboxConfig>) {
    let mut inner = state.inner.write().await;
    inner.kuveyt_turk_client_id = Some(payload.client_id.trim().to_string());
    inner.kuveyt_turk_client_secret = Some(payload.client_secret.trim().to_string());

    let service = KuveytTurkSandboxService::new();
    let config = service.get_config_status(inner.kuveyt_turk_client_id.as_deref());
    (StatusCode::OK, Json(config))
}

pub async fn test_kuveyt_turk_connection(
    State(state): State<AppState>,
    Json(payload): Json<Option<crate::services::ConfigureKuveytTurkRequest>>,
) -> Result<Json<crate::services::KuveytTurkProbeResult>, (StatusCode, String)> {
    let (client_id, client_secret) = {
        let inner = state.inner.read().await;
        if let Some(req) = payload {
            (req.client_id, req.client_secret)
        } else {
            let id = inner
                .kuveyt_turk_client_id
                .clone()
                .or_else(|| std::env::var("KT_CLIENT_ID").ok())
                .unwrap_or_default();
            let secret = inner
                .kuveyt_turk_client_secret
                .clone()
                .or_else(|| std::env::var("KT_CLIENT_SECRET").ok())
                .unwrap_or_default();
            (id, secret)
        }
    };

    if client_id.trim().is_empty() || client_secret.trim().is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Client ID and Client Secret are required to test connection with Kuveyt Türk Sandbox."
                .to_string(),
        ));
    }

    let service = KuveytTurkSandboxService::new();
    let probe = service
        .test_connection(&client_id, &client_secret)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                crate::error::sanitized("Internal error", &e),
            )
        })?;

    Ok(Json(probe))
}

// 11. Bank Incoming Webhook & Real-Time Virtual IBAN Settlement (STORY-07-03)
/// Header carrying `hex(HMAC-SHA256(SITEPULSE_BANK_WEBHOOK_SECRET, raw_body))`.
pub const BANK_WEBHOOK_SIGNATURE_HEADER: &str = "x-sitepulse-signature";

pub async fn handle_bank_incoming_webhook(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    body: axum::body::Bytes,
) -> Result<(StatusCode, Json<BankIncomingWebhookResponse>), (StatusCode, String)> {
    let signature = headers
        .get(BANK_WEBHOOK_SIGNATURE_HEADER)
        .and_then(|v| v.to_str().ok());
    if !crate::auth::verify_webhook_signature(&body, signature) {
        return Err((
            StatusCode::UNAUTHORIZED,
            "Invalid or missing webhook signature".to_string(),
        ));
    }
    let payload: BankIncomingWebhookRequest = serde_json::from_slice(&body).map_err(|e| {
        (
            StatusCode::BAD_REQUEST,
            crate::error::sanitized("Invalid webhook payload", &e),
        )
    })?;
    validate_bank_webhook(&payload)?;

    // Durable idempotency (O-3): the transaction id is claimed in PostgreSQL,
    // scoped by the receiving bank account (or site), before any state changes,
    // so a replay (even after a restart) is never applied twice. A transaction id
    // reused with different content is rejected rather than silently ignored.
    let mut claim_id: Option<i64> = None;
    let mut account_scope: Option<i64> = None;
    if let Some(ref pool) = state.pool {
        let unavailable = |e: Box<dyn std::error::Error + Send + Sync>| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                crate::error::sanitized("Could not record webhook", &e),
            )
        };
        let destination = payload.virtual_iban.replace(' ', "").to_uppercase();
        let scope = crate::db::resolve_webhook_scope(pool, &destination)
            .await
            .map_err(unavailable)?;
        account_scope = scope.site_bank_account_id;
        match crate::db::claim_bank_webhook_transaction(
            pool,
            &scope,
            &payload.transaction_id,
            &webhook_payload_hash(&payload),
        )
        .await
        .map_err(unavailable)?
        {
            crate::db::WebhookClaim::Claimed(id) => claim_id = Some(id),
            crate::db::WebhookClaim::Duplicate {
                same_payload: false,
                ..
            } => {
                return Err((
                    StatusCode::CONFLICT,
                    format!(
                        "transaction_id {} was already delivered with different content",
                        payload.transaction_id
                    ),
                ));
            }
            crate::db::WebhookClaim::Duplicate { receipt_id, .. } => {
                let mut resp = duplicate_webhook_response(payload.transaction_id);
                if let Some(rid) = receipt_id {
                    let inner = state.inner.read().await;
                    if let Some(r) = inner.payment_receipts.iter().find(|r| r.id == rid) {
                        resp.receipt_id = r.receipt_number.clone();
                    }
                }
                return Ok((StatusCode::OK, Json(resp)));
            }
        }
    }
    let result = process_bank_incoming_webhook_scoped(state.clone(), payload, account_scope).await;
    if let (Some(pool), Some(id)) = (state.pool.as_ref(), claim_id) {
        match &result {
            Err(_) => {
                if let Err(e) = crate::db::release_bank_webhook_transaction(pool, id).await {
                    tracing::error!("Could not release webhook claim {}: {}", id, e);
                }
            }
            Ok((_, Json(resp))) if resp.status == "CLEARED" => {
                let receipt = {
                    let inner = state.inner.read().await;
                    inner
                        .payment_receipts
                        .iter()
                        .find(|r| {
                            r.receipt_number == resp.receipt_id
                                && r.site_id == resp_site(&inner, resp)
                        })
                        .map(|r| r.id)
                };
                if let Some(rid) = receipt {
                    if let Err(e) = crate::db::attach_bank_webhook_receipt(pool, id, rid).await {
                        tracing::error!(
                            "Could not link webhook claim {} to receipt {}: {}",
                            id,
                            rid,
                            e
                        );
                    }
                }
            }
            Ok(_) => {}
        }
    }
    result
}

/// Site of the unit a cleared webhook settled.
pub(crate) fn resp_site(
    inner: &crate::state::AppStateInner,
    resp: &BankIncomingWebhookResponse,
) -> String {
    inner
        .units
        .iter()
        .find(|u| u.id == resp.matched_unit_id)
        .map(|u| u.site_id.clone())
        .unwrap_or_default()
}

/// SHA-256 over the fields that define a bank transfer, so a redelivery can be
/// told apart from a transaction id reused for a different transfer. The
/// canonical form is the persisted contract [`crate::domain::fingerprint::transfer_canonical_v1`].
pub fn webhook_payload_hash(payload: &BankIncomingWebhookRequest) -> String {
    crate::domain::fingerprint::transfer_hash_v1(&crate::domain::fingerprint::TransferFields {
        transaction_id: &payload.transaction_id,
        amount: payload.amount,
        currency: payload.currency.as_deref(),
        virtual_iban: &payload.virtual_iban,
        sender_iban: payload.sender_iban.as_deref(),
        description: payload.description.as_deref(),
    })
}

pub(crate) fn duplicate_webhook_response(transaction_id: String) -> BankIncomingWebhookResponse {
    BankIncomingWebhookResponse {
        status: "DUPLICATE_IGNORED".to_string(),
        transaction_id,
        matched_unit_id: String::new(),
        matched_block: String::new(),
        matched_unit_number: 0,
        cleared_due_period: None,
        cleared_amount: Decimal::ZERO,
        remaining_debt: Decimal::ZERO,
        advance_payment: Decimal::ZERO,
        receipt_id: String::new(),
        message: "Duplicate bank transaction notification ignored. Idempotency preserved."
            .to_string(),
    }
}

pub(crate) fn validate_bank_webhook(
    payload: &BankIncomingWebhookRequest,
) -> Result<(), (StatusCode, String)> {
    if payload.transaction_id.trim().is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "transaction_id is required".to_string(),
        ));
    }
    if payload.amount <= Decimal::ZERO || payload.amount.scale() > 2 {
        return Err((
            StatusCode::BAD_REQUEST,
            "amount must be positive with at most 2 decimals".to_string(),
        ));
    }
    match payload.currency.as_deref().map(|c| c.trim().to_uppercase()) {
        None => Ok(()),
        Some(c) if c == "TRY" => Ok(()),
        Some(c) => Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            format!("Unsupported currency '{}'; only TRY is accepted", c),
        )),
    }
}

pub async fn process_bank_incoming_webhook(
    state: AppState,
    payload: BankIncomingWebhookRequest,
) -> Result<(StatusCode, Json<BankIncomingWebhookResponse>), (StatusCode, String)> {
    process_bank_incoming_webhook_scoped(state, payload, None).await
}

/// `account_scope`: the receiving site bank account when known; the payment's
/// idempotency key is then `BANK:<account>:<transaction_id>`, so two accounts
/// reusing a transaction id never share a receipt (O-3).
pub(crate) async fn process_bank_incoming_webhook_scoped(
    state: AppState,
    payload: BankIncomingWebhookRequest,
    account_scope: Option<i64>,
) -> Result<(StatusCode, Json<BankIncomingWebhookResponse>), (StatusCode, String)> {
    let clean_viban = payload.virtual_iban.replace(' ', "").to_uppercase();
    let inner = state.inner.read().await;

    // Any earlier delivery of this transaction id (matched or not) to the same
    // site is a duplicate (transaction ids are unique per bank, not globally).
    let destination_site = inner
        .units
        .iter()
        .find(|u| {
            u.virtual_iban
                .as_ref()
                .map(|v| v.replace(' ', "").to_uppercase() == clean_viban)
                .unwrap_or(false)
        })
        .map(|u| u.site_id.clone())
        .or_else(|| {
            inner
                .site_bank_accounts
                .iter()
                .find(|ba| ba.iban.replace(' ', "").to_uppercase() == clean_viban)
                .map(|ba| ba.site_id.clone())
        });
    let same_delivery = |m: &ReconciliationMatch| {
        m.transaction.transaction_id == payload.transaction_id
            && destination_site
                .as_deref()
                .map(|s| crate::auth::same_id(s, &m.site_id))
                .unwrap_or(true)
    };
    if inner.reconciliation_queue.iter().any(same_delivery) {
        let unit = inner
            .reconciliation_queue
            .iter()
            .find(|m| same_delivery(m))
            .and_then(|m| m.matched_unit_id.clone())
            .and_then(|uid| inner.units.iter().find(|u| u.id == uid).cloned());
        let mut resp = duplicate_webhook_response(payload.transaction_id);
        if let Some(u) = unit {
            resp.advance_payment = inner.advance_total(&u.id);
            resp.matched_unit_id = u.id;
            resp.matched_block = u.block_id;
            resp.matched_unit_number = u.unit_number;
        }
        return Ok((StatusCode::OK, Json(resp)));
    }

    // 1. Match unit by Virtual IBAN or Remembered Sender IBAN or Regular IBAN + Description / Sender Roster
    let mut is_virtual_iban = false;
    let mut match_mechanism = "Virtual IBAN";
    let mut unit_index = inner.units.iter().position(|u| {
        u.virtual_iban
            .as_ref()
            .map(|v| v.replace(' ', "").to_uppercase() == clean_viban)
            .unwrap_or(false)
    });

    if unit_index.is_some() {
        is_virtual_iban = true;
        match_mechanism = "Virtual IBAN";
    } else {
        // Priority 1: Check if sender_iban was previously remembered/authorized by site manager for a unit
        if let Some(ref sender_iban) = payload.sender_iban {
            let clean_sender = sender_iban.replace(' ', "").to_uppercase();
            if let Some(saved_unit_id) = inner.remembered_sender_ibans.get(&clean_sender) {
                unit_index = inner.units.iter().position(|u| u.id == *saved_unit_id);
                if unit_index.is_some() {
                    match_mechanism = "Remembered Sender IBAN (Yönetici Tarafından Eşleştirilmiş Gönderici IBAN'ı)";
                }
            }
        }

        // Priority 2: Check if payment was sent to Site's Regular/Main Account IBAN,
        // or check narrative / description for block and flat
        if unit_index.is_none() {
            let desc = payload.description.as_deref().unwrap_or("");
            if let Some((ref blk, unit_no)) = ReconciliationService::extract_block_and_flat(desc) {
                let clean_blk = blk
                    .to_uppercase()
                    .replace("BLOK", "")
                    .replace("BLOCK", "")
                    .replace(['-', '_', ' '], "");
                unit_index = inner.units.iter().position(|u| {
                    let u_blk = u
                        .block_id
                        .to_uppercase()
                        .replace("BLOK", "")
                        .replace("BLOCK", "")
                        .replace(['-', '_', ' '], "");
                    (u_blk == clean_blk || u.block_id.eq_ignore_ascii_case(blk))
                        && u.unit_number == unit_no
                });
                if unit_index.is_some() {
                    match_mechanism = "Regular IBAN & Narrative Matching (Açıklama Ayrıştırması)";
                }
            }
        }

        // Priority 3: Check sender name against registered unit payer names or resident roster
        if unit_index.is_none() {
            if let Some(ref sender) = payload.sender_name {
                let sender_lower = sender.to_lowercase();
                for (u_id, names) in &inner.unit_payer_names {
                    if names.iter().any(|n| {
                        let nl = n.to_lowercase();
                        sender_lower.contains(&nl) || nl.contains(&sender_lower)
                    }) {
                        unit_index = inner.units.iter().position(|u| u.id == *u_id);
                        if unit_index.is_some() {
                            match_mechanism = "Regular IBAN & Registered Payer Name Matching (Kayıtlı Gönderen İsim Eşleşmesi)";
                            break;
                        }
                    }
                }

                if unit_index.is_none() {
                    for user in &inner.users {
                        if user.full_name.to_lowercase().contains(&sender_lower)
                            || sender_lower.contains(&user.full_name.to_lowercase())
                        {
                            unit_index = inner
                                .units
                                .iter()
                                .position(|u| u.owner_user_id.as_deref() == Some(&user.id));
                            if unit_index.is_some() {
                                match_mechanism =
                                    "Regular IBAN & Sender Name Matching (Gönderen İsim Eşleşmesi)";
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    let unit = match unit_index {
        Some(idx) => inner.units[idx].clone(),
        None => {
            // The unmatched transfer belongs to the site whose account received it;
            // an IBAN that is no site's account is rejected (never filed under site 1).
            let (bank_site_id, bank_account_id) = inner
                .site_bank_accounts
                .iter()
                .find(|ba| ba.iban.replace(' ', "").to_uppercase() == clean_viban)
                .map(|ba| (ba.site_id.clone(), crate::db::parse_id_to_i64(&ba.id)))
                .ok_or_else(|| {
                    (
                        StatusCode::UNPROCESSABLE_ENTITY,
                        format!(
                            "Destination IBAN {} is not a site account or a unit's virtual IBAN",
                            payload.virtual_iban
                        ),
                    )
                })?;

            let txn_desc = payload.description.clone().unwrap_or_else(|| {
                format!("Site Ana Hesabı FAST Transferi: {}", payload.virtual_iban)
            });
            let match_seq = inner.reconciliation_queue.len() + 1;
            let receipt_seq = inner.reconciliation_queue.len() + 1;
            let match_id = format!("MATCH-{}", match_seq);
            let receipt_id = format!("DKN-UNM-{}", receipt_seq);

            let unmatched = ReconciliationMatch {
                match_id: match_id.clone(),
                site_id: bank_site_id,
                transaction: BankTransactionItem {
                    transaction_id: payload.transaction_id.clone(),
                    date: crate::e2e_clock::now_utc().date_naive(),
                    amount: payload.amount,
                    currency: payload.currency.clone().unwrap_or_else(|| "TRY".to_string()),
                    description: txn_desc,
                    sender_name: payload.sender_name.clone(),
                    sender_iban: payload.sender_iban.clone(),
                    reference_no: Some(payload.transaction_id.clone()),
                },
                matched_unit_id: None,
                matched_block: None,
                matched_unit_number: None,
                matched_resident_name: None,
                confidence_score: 0,
                matched_due_id: None,
                outstanding_balance: None,
                amount_matches_balance: false,
                status: ReconciliationStatus::Unmatched,
                status_code: ReconciliationStatus::Unmatched.as_str().to_string(),
                notes: Some("Açıklama boş veya daire tespit edilemedi. Yönetici manuel eşleştirmesi bekliyor.".to_string()),
            };
            // The transaction id is already claimed, so the unmatched transfer must be
            // durable: it waits in the reconciliation queue for manual matching.
            // The global lock is released for the write and re-taken for memory.
            drop(inner);
            if let Some(ref pool) = state.pool {
                crate::db::save_reconciliation_match_for_site(
                    pool,
                    &unmatched,
                    &unmatched.site_id,
                    bank_account_id.or(account_scope),
                )
                .await
                .map_err(|e| {
                    (
                        StatusCode::SERVICE_UNAVAILABLE,
                        crate::error::sanitized("Database write failed", &e),
                    )
                })?;
            }
            state
                .inner
                .write()
                .await
                .reconciliation_queue
                .push(unmatched);

            return Ok((
                StatusCode::OK,
                Json(BankIncomingWebhookResponse {
                    status: "UNMATCHED".to_string(),
                    transaction_id: payload.transaction_id,
                    matched_unit_id: "UNMATCHED".to_string(),
                    matched_block: "-".to_string(),
                    matched_unit_number: 0,
                    cleared_due_period: None,
                    cleared_amount: Decimal::ZERO,
                    remaining_debt: Decimal::ZERO,
                    advance_payment: Decimal::ZERO,
                    receipt_id,
                    message: "Para transferi site banka hesabına ulaştı fakat daire ile otomatik eşleştirilemedi. İşlem, Site Yöneticisinin manuel eşleştirmesi için EŞLEŞMEYENLER havuzuna eklendi.".to_string(),
                }),
            ));
        }
    };

    // A unit-level transfer with no payer identity must not guess between debtors.
    if is_virtual_iban
        && open_debtor_types(&inner, &unit.id).len() > 1
        && !payer_identified(&inner, &unit, payload.sender_name.as_deref())
    {
        let match_id = format!("{}{}", DEBTOR_REVIEW_PREFIX, payload.transaction_id);
        let receipt_id = format!("DKN-UNM-{}", inner.reconciliation_queue.len() + 1);
        let txn_desc = payload
            .description
            .clone()
            .unwrap_or_else(|| format!("Sanal IBAN FAST Transferi: {}", payload.virtual_iban));
        let held = ReconciliationMatch {
            match_id,
            site_id: unit.site_id.clone(),
            transaction: BankTransactionItem {
                transaction_id: payload.transaction_id.clone(),
                date: crate::e2e_clock::now_utc().date_naive(),
                amount: payload.amount,
                currency: payload
                    .currency
                    .clone()
                    .unwrap_or_else(|| "TRY".to_string()),
                description: txn_desc,
                sender_name: payload.sender_name.clone(),
                sender_iban: payload.sender_iban.clone(),
                reference_no: Some(payload.transaction_id.clone()),
            },
            matched_unit_id: Some(unit.id.clone()),
            matched_block: Some(unit.block_id.clone()),
            matched_unit_number: Some(unit.unit_number),
            matched_resident_name: None,
            confidence_score: 0,
            matched_due_id: None,
            outstanding_balance: None,
            amount_matches_balance: false,
            status: ReconciliationStatus::Unmatched,
            status_code: ReconciliationStatus::Unmatched.as_str().to_string(),
            notes: Some(SEVERAL_OPEN_DEBTORS_REASON.to_string()),
        };
        drop(inner);
        if let Some(p) = state.db_pool() {
            crate::db::save_reconciliation_match_for_site(p, &held, &held.site_id, account_scope)
                .await
                .map_err(|e| {
                    (
                        StatusCode::SERVICE_UNAVAILABLE,
                        crate::error::sanitized("Database write failed", &e),
                    )
                })?;
        }
        state.inner.write().await.reconciliation_queue.push(held);
        return Ok((
            StatusCode::OK,
            Json(BankIncomingWebhookResponse {
                status: "UNMATCHED".to_string(),
                transaction_id: payload.transaction_id,
                matched_unit_id: unit.id,
                matched_block: unit.block_id,
                matched_unit_number: unit.unit_number,
                cleared_due_period: None,
                cleared_amount: Decimal::ZERO,
                remaining_debt: Decimal::ZERO,
                advance_payment: Decimal::ZERO,
                receipt_id,
                message: SEVERAL_OPEN_DEBTORS_REASON.to_string(),
            }),
        ));
    }

    // 2. Settle through the canonical ingestion path (SPEC-005 R1): TAH- receipt,
    // allocation rows, penalty-first waterfall, idempotent on the bank transaction.
    let (payer_role, payer_name) = resolve_payer(&inner, &unit, payload.sender_name.as_deref());
    let matched_resident_name = unit
        .owner_user_id
        .as_ref()
        .and_then(|uid| inner.users.iter().find(|u| &u.id == uid))
        .map(|u| u.full_name.clone());

    let txn_desc = payload.description.clone().unwrap_or_else(|| {
        if is_virtual_iban {
            format!("Sanal IBAN FAST Transferi: {}", payload.virtual_iban)
        } else {
            format!("Site Ana Hesabı FAST Transferi: {}", payload.virtual_iban)
        }
    });
    if payer_role == DebtorType::Tenant
        && crate::services::PaymentTrackingService::is_capital_expenditure_intent(&txn_desc)
    {
        let review_match = ReconciliationMatch {
            match_id: format!("CAPITAL-REVIEW:{}", payload.transaction_id),
            site_id: unit.site_id.clone(),
            transaction: BankTransactionItem {
                transaction_id: payload.transaction_id.clone(),
                date: crate::e2e_clock::now_utc().date_naive(),
                amount: payload.amount,
                currency: payload.currency.clone().unwrap_or_else(|| "TRY".to_string()),
                description: txn_desc,
                sender_name: payload.sender_name.clone(),
                sender_iban: payload.sender_iban.clone(),
                reference_no: Some(payload.transaction_id.clone()),
            },
            matched_unit_id: Some(unit.id.clone()),
            matched_block: Some(unit.block_id.clone()),
            matched_unit_number: Some(unit.unit_number),
            matched_resident_name,
            confidence_score: 100,
            matched_due_id: None,
            outstanding_balance: None,
            amount_matches_balance: false,
            status: ReconciliationStatus::PendingApproval,
            status_code: ReconciliationStatus::PendingApproval.as_str().to_string(),
            notes: Some("Açıklamada demirbaş niyeti var. Malik borcuna işlem için yöneticinin açık onayı bekleniyor.".to_string()),
        };
        drop(inner);
        if let Some(ref pool) = state.pool {
            crate::db::save_reconciliation_match_for_site(
                pool,
                &review_match,
                &review_match.site_id,
                account_scope,
            )
            .await
            .map_err(|e| {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    crate::error::sanitized("Database write failed", &e),
                )
            })?;
        }
        state
            .inner
            .write()
            .await
            .reconciliation_queue
            .push(review_match);
        return Ok((
            StatusCode::ACCEPTED,
            Json(BankIncomingWebhookResponse {
                status: "PENDING_REVIEW".to_string(),
                transaction_id: payload.transaction_id,
                matched_unit_id: unit.id,
                matched_block: unit.block_id,
                matched_unit_number: unit.unit_number,
                cleared_due_period: None,
                cleared_amount: Decimal::ZERO,
                remaining_debt: Decimal::ZERO,
                advance_payment: Decimal::ZERO,
                receipt_id: String::new(),
                message: "Capital payment intent needs manager review before allocation."
                    .to_string(),
            }),
        ));
    }
    drop(inner);

    let txn_desc = payload.description.clone().unwrap_or_else(|| {
        if is_virtual_iban {
            format!("Sanal IBAN FAST Transferi: {}", payload.virtual_iban)
        } else {
            format!("Site Ana Hesabı FAST Transferi: {}", payload.virtual_iban)
        }
    });
    let receipt = crate::services::PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(crate::models::RecordManualPaymentRequest {
            site_id: Some(unit.site_id.clone()),
            unit_id: unit.id.clone(),
            amount: payload.amount,
            payer_name,
            payer_role,
            payment_channel: if is_virtual_iban {
                PaymentChannel::VirtualIban
            } else {
                PaymentChannel::BankTransfer
            },
            description: Some(txn_desc.clone()),
            payment_date: None,
            idempotency_key: Some(match account_scope {
                Some(account) => format!("BANK:{}:{}", account, payload.transaction_id),
                None => format!("BANK:{}", payload.transaction_id),
            }),
            designation: None,
            settles_owner_capital_dues: false,
            settles_tenant_joint_liability: false,
            external_reference: Some(payload.transaction_id.clone()),
            designate_from_description: true,
            settles_unmatched_entry_id: None,
        })
        .await
        .map_err(payment_error_status)?;

    let mut inner = state.inner.write().await;
    let cleared_amount = receipt.allocated_principal + receipt.allocated_penalty;
    let cleared_period = receipt
        .allocation_breakdown
        .first()
        .map(|b| b.period.clone());
    let surplus = receipt.allocated_advance;
    let total_advance = inner.advance_total(&unit.id);
    let remaining_debt: Decimal = inner
        .dues
        .iter()
        .filter(|d| d.unit_id == unit.id && d.status.is_collectable())
        .map(|d| d.total_amount)
        .sum();

    let unit_block_desc = inner.block_label(&unit.block_id);

    let message = if let Some(ref period) = cleared_period {
        if surplus > Decimal::ZERO {
            format!(
                "₺{} dues settlement cleared for {} (Unit {} D:{}). Surplus of ₺{} credited as advance payment (Avans Bakiye: ₺{}). Receipt {}.",
                cleared_amount, period, unit_block_desc, unit.unit_number, surplus, total_advance, receipt.receipt_number
            )
        } else {
            format!(
                "₺{} dues settlement successfully cleared and matched to unit {} D:{} via {}. Receipt {}.",
                cleared_amount, unit_block_desc, unit.unit_number, match_mechanism, receipt.receipt_number
            )
        }
    } else {
        format!(
            "No outstanding dues for unit {} D:{}. Full payment of ₺{} credited as advance payment (Avans Bakiye: ₺{}) via {}. Receipt {}.",
            unit_block_desc, unit.unit_number, payload.amount, total_advance, match_mechanism, receipt.receipt_number
        )
    };

    let notes = if let Some(ref period) = cleared_period {
        if surplus > Decimal::ZERO {
            let surplus_str = format!("{:.2}", surplus).replace('.', ",");
            format!(
                "{} aidatı ödendi • ₺{} avans bakiyenize aktarıldı",
                period, surplus_str
            )
        } else {
            format!("{} aidat borcu kapatıldı", period)
        }
    } else {
        "Aktif borç bulunmuyor • Avans bakiyenize aktarıldı".to_string()
    };

    let match_seq = inner.reconciliation_queue.len() + 1;
    inner.reconciliation_queue.push(ReconciliationMatch {
        match_id: format!("MATCH-{}", match_seq),
        site_id: unit.site_id.clone(),
        transaction: BankTransactionItem {
            transaction_id: payload.transaction_id.clone(),
            date: crate::e2e_clock::now_utc().date_naive(),
            amount: payload.amount,
            currency: payload.currency.unwrap_or_else(|| "TRY".to_string()),
            description: txn_desc,
            sender_name: payload.sender_name,
            sender_iban: payload.sender_iban,
            reference_no: Some(receipt.receipt_number.clone()),
        },
        matched_unit_id: Some(unit.id.clone()),
        matched_block: Some(unit.block_id.clone()),
        matched_unit_number: Some(unit.unit_number),
        matched_resident_name,
        confidence_score: 100,
        matched_due_id: receipt
            .allocation_breakdown
            .first()
            .and_then(|b| b.due_id.clone()),
        outstanding_balance: Some(cleared_amount),
        amount_matches_balance: surplus == Decimal::ZERO,
        status: ReconciliationStatus::Approved,
        status_code: ReconciliationStatus::Approved.as_str().to_string(),
        notes: Some(notes),
    });

    Ok((
        StatusCode::OK,
        Json(BankIncomingWebhookResponse {
            status: "CLEARED".to_string(),
            transaction_id: payload.transaction_id,
            matched_unit_id: unit.id,
            matched_block: unit.block_id.clone(),
            matched_unit_number: unit.unit_number,
            cleared_due_period: cleared_period,
            cleared_amount,
            remaining_debt,
            advance_payment: total_advance,
            receipt_id: receipt.receipt_number,
            message,
        }),
    ))
}

/// Who paid, for an incoming transfer:
/// - The unit's tenant when the sender name matches the tenant account.
/// - When only one debtor type has open debt on the unit, follow that debt.
/// - Otherwise, the owner (who may settle owner liabilities, with surplus to advance).
///
/// Returns `(payer_role, payer_name)`.
pub(crate) fn resolve_payer(
    inner: &crate::state::AppStateInner,
    unit: &crate::models::IndependentUnit,
    sender_name: Option<&str>,
) -> (DebtorType, String) {
    let name_of = |uid: &Option<String>| {
        uid.as_ref()
            .and_then(|id| inner.users.iter().find(|u| &u.id == id))
            .map(|u| u.full_name.clone())
    };
    let tenant_name = name_of(&unit.tenant_user_id).or_else(|| {
        inner.unit_occupancies.get(&unit.id).and_then(|occ| {
            occ.iter()
                .find(|h| h.is_active && h.role == DebtorType::Tenant)
                .map(|h| h.person_name.clone())
        })
    });
    let sender = sender_name.map(str::trim).filter(|s| !s.is_empty());
    if let (Some(sender), Some(ref tenant)) = (sender, &tenant_name) {
        let (a, b) = (
            crate::services::dues_ledger::fold_turkish(sender),
            crate::services::dues_ledger::fold_turkish(tenant),
        );
        if a.contains(&b) || b.contains(&a) {
            return (DebtorType::Tenant, sender.to_string());
        }
    }
    let owner_name = name_of(&unit.owner_user_id);
    if let (Some(sender), Some(ref owner)) = (sender, &owner_name) {
        let (a, b) = (
            crate::services::dues_ledger::fold_turkish(sender),
            crate::services::dues_ledger::fold_turkish(owner),
        );
        if a.contains(&b) || b.contains(&a) {
            return (DebtorType::Owner, sender.to_string());
        }
    }

    // Follow the debt: when only one debtor type has open debt, resolve to that type.
    let open_debtors = open_debtor_types(inner, &unit.id);
    if open_debtors.len() == 1 {
        let single_role = open_debtors[0];
        let name = sender
            .map(str::to_string)
            .or_else(|| match single_role {
                DebtorType::Tenant => tenant_name,
                DebtorType::Owner => name_of(&unit.owner_user_id),
            })
            .unwrap_or_else(|| "Bilinmeyen Gönderen".to_string());
        return (single_role, name);
    }

    let name = sender
        .map(str::to_string)
        .or_else(|| name_of(&unit.owner_user_id))
        .unwrap_or_else(|| "Bilinmeyen Gönderen".to_string());
    (DebtorType::Owner, name)
}

/// Match id prefix of a transfer held for the manager to pick one debtor; such an
/// item is approved exactly once.
pub(crate) const DEBTOR_REVIEW_PREFIX: &str = "DEBTOR-REVIEW:";

/// Stored reason of a transfer held back because the unit has several open debtors.
pub(crate) const SEVERAL_OPEN_DEBTORS_REASON: &str = "several open debtors";

/// The debtors (owner, tenant) that currently have an open charge on the unit.
pub(crate) fn open_debtor_types(
    inner: &crate::state::AppStateInner,
    unit_id: &str,
) -> Vec<DebtorType> {
    let mut debtors: Vec<DebtorType> = Vec::new();
    for due in inner.dues.iter().filter(|d| {
        crate::auth::same_id(&d.unit_id, unit_id) && crate::services::finance_common::is_open(d)
    }) {
        if !debtors.contains(&due.debtor_type) {
            debtors.push(due.debtor_type);
        }
    }
    debtors
}

/// True when the sender name points at the unit's tenant or owner.
fn payer_identified(
    inner: &crate::state::AppStateInner,
    unit: &crate::models::IndependentUnit,
    sender_name: Option<&str>,
) -> bool {
    let Some(sender) = sender_name.map(str::trim).filter(|s| !s.is_empty()) else {
        return false;
    };
    let folded = crate::services::dues_ledger::fold_turkish(sender);
    [&unit.tenant_user_id, &unit.owner_user_id]
        .into_iter()
        .filter_map(|uid| uid.as_ref())
        .filter_map(|id| inner.users.iter().find(|u| &u.id == id))
        .any(|u| {
            let name = crate::services::dues_ledger::fold_turkish(&u.full_name);
            folded.contains(&name) || name.contains(&folded)
        })
}
