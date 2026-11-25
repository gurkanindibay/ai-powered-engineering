//! Payment collection, payment streams, debt aging, receipts, transfers and reversals.

use super::*;

/// HTTP status for a canonical-ingestion failure: storage problems are 503 (the
/// caller may retry; the payment is idempotent), anything else is a bad request.
pub(crate) fn payment_error_status(e: String) -> (StatusCode, String) {
    if e.starts_with("Database unavailable")
        || e.starts_with("Payment was not recorded")
        || e.starts_with("Reversal was not recorded")
    {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            crate::error::sanitized("Payment storage is temporarily unavailable", &e),
        )
    } else if e.contains("already PAID") || e.contains("CANCELLED") {
        (StatusCode::CONFLICT, e)
    } else {
        (StatusCode::BAD_REQUEST, e)
    }
}

/// Records a payment sent/recorded by a homeowner inside the application.
/// Matches against outstanding debts first (FIFO by due_date).
/// If no debt exists (or if payment > debt), credits the remainder to advance_payments (Avans Bakiye).
pub async fn record_homeowner_payment(
    State(state): State<AppState>,
    Json(payload): Json<RecordHomeownerPaymentRequest>,
) -> Result<(StatusCode, Json<RecordHomeownerPaymentResponse>), (StatusCode, String)> {
    let (unit, payer_role, payer_name) = {
        let inner = state.inner.read().await;
        let unit = inner
            .units
            .iter()
            .find(|u| u.id == payload.unit_id)
            .cloned()
            .ok_or_else(|| {
                (
                    StatusCode::NOT_FOUND,
                    format!("Unit '{}' not found.", payload.unit_id),
                )
            })?;
        let (payer_role, payer_name) =
            crate::handlers::resolve_payer(&inner, &unit, payload.homeowner_name.as_deref());
        (unit, payer_role, payer_name)
    };
    let reference = payload
        .reference_code
        .clone()
        .filter(|r| !r.trim().is_empty());

    // Canonical ingestion (SPEC-005 R1).
    let receipt = crate::services::PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(crate::models::RecordManualPaymentRequest {
            site_id: Some(unit.site_id.clone()),
            unit_id: unit.id.clone(),
            amount: payload.amount,
            payer_name: payer_name.clone(),
            payer_role,
            payer_person_id: None,
            payment_channel: payload.payment_method,
            description: payload.note.clone(),
            payment_date: None,
            idempotency_key: reference.as_ref().map(|r| format!("HOP:{}", r)),
            designation: None,
            settles_owner_capital_dues: false,
            settles_tenant_joint_liability: false,
            external_reference: reference.clone(),
            designate_from_description: true,
            settles_unmatched_entry_id: None,
        })
        .await
        .map_err(payment_error_status)?;

    let cleared_debt = receipt.allocated_principal + receipt.allocated_penalty;
    let advance_credit = receipt.allocated_advance;
    let match_status = if cleared_debt > Decimal::ZERO && advance_credit > Decimal::ZERO {
        PaymentMatchStatus::PartiallyMatched
    } else if cleared_debt > Decimal::ZERO {
        PaymentMatchStatus::MatchedDebt
    } else {
        PaymentMatchStatus::MatchedAdvance
    };

    let inner = state.inner.read().await;
    let total_unit_advance = inner.advance_total(&unit.id);
    let remaining_debt: Decimal = inner
        .dues
        .iter()
        .filter(|d| d.unit_id == unit.id && d.status.is_collectable())
        .map(|d| d.total_amount)
        .sum();
    let message = if cleared_debt > Decimal::ZERO && advance_credit > Decimal::ZERO {
        format!(
            "₺{} aidat borcu ödendi, kalan ₺{} avans bakiyesine aktarıldı (Mevcut Avans: ₺{}). Makbuz {}.",
            cleared_debt, advance_credit, total_unit_advance, receipt.receipt_number
        )
    } else if cleared_debt > Decimal::ZERO {
        format!(
            "₺{} tutarındaki aidat borcu başarıyla kapatıldı. Makbuz {}.",
            cleared_debt, receipt.receipt_number
        )
    } else {
        format!(
            "Aktif aidat borcu bulunmuyor. ₺{} tutarındaki ödeme avans bakiyenize eklendi (Mevcut Avans: ₺{}). Makbuz {}.",
            advance_credit, total_unit_advance, receipt.receipt_number
        )
    };

    // Approved digital receipt line for the site payment views.
    let is_card = receipt.payment_channel == PaymentChannel::CreditCard;
    let match_seq = inner.reconciliation_queue.len() + 1;
    let r_match = ReconciliationMatch {
        match_id: format!("MATCH-{}", match_seq),
        site_id: unit.site_id.clone(),
        transaction: BankTransactionItem {
            transaction_id: reference
                .clone()
                .unwrap_or_else(|| receipt.receipt_number.clone()),
            date: crate::services::finance_common::site_today(&inner, &unit.site_id),
            amount: payload.amount,
            currency: "TRY".to_string(),
            description: payload.note.clone().unwrap_or_else(|| {
                if is_card {
                    "Kredi Kartı ile Aidat Ödemesi".to_string()
                } else {
                    format!("{} ile Aidat Ödemesi", receipt.payment_channel)
                }
            }),
            sender_name: Some(payer_name),
            sender_iban: None,
            reference_no: Some(receipt.receipt_number.clone()),
        },
        matched_unit_id: Some(unit.id.clone()),
        matched_block: Some(unit.block_id.clone()),
        matched_unit_number: Some(unit.unit_number),
        matched_resident_name: payload.homeowner_name.clone(),
        confidence_score: 100,
        matched_due_id: receipt
            .allocation_breakdown
            .first()
            .and_then(|b| b.due_id.clone()),
        outstanding_balance: Some(cleared_debt),
        amount_matches_balance: cleared_debt == payload.amount,
        status: ReconciliationStatus::Approved,
        status_code: ReconciliationStatus::Approved.as_str().to_string(),
        notes: Some(message.clone()),
        assigned_unit_id: None,
        assigned_debtor_role: None,
    };
    // Persist without holding the global lock; memory follows on success.
    drop(inner);
    if let Some(ref pool) = state.pool {
        crate::db::save_reconciliation_match(pool, &r_match)
            .await
            .map_err(|e| {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    crate::error::sanitized("Database write failed", &e),
                )
            })?;
    }
    state.inner.write().await.reconciliation_queue.push(r_match);

    Ok((
        StatusCode::OK,
        Json(RecordHomeownerPaymentResponse {
            payment_id: receipt.receipt_number.clone(),
            unit_id: unit.id,
            amount: payload.amount,
            cleared_debt_amount: cleared_debt,
            advance_payment_amount: advance_credit,
            remaining_debt,
            total_unit_advance_balance: total_unit_advance,
            status: match_status,
            message,
        }),
    ))
}

/// Collects all homeowner payments recorded in the application and matches them with debts.
/// If a homeowner/unit has debts, matches and deducts from debts (FIFO).
/// If no debt exists (or remaining surplus), matches it as advance payment (Avans Bakiye).
pub async fn match_all_homeowner_payments(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Json(mut payload): Json<MatchAllPaymentsRequest>,
) -> Result<(StatusCode, Json<MatchAllPaymentsResponse>), (StatusCode, String)> {
    scope.pin_opt(&mut payload.site_id)?;
    let target_site_id = payload.site_id.unwrap_or_default();
    let pending: Vec<(crate::models::HomeownerPaymentRecord, String)> = {
        let inner = state.inner.read().await;
        inner
            .homeowner_payments
            .iter()
            .filter(|p| p.status == PaymentMatchStatus::Pending)
            .filter_map(|p| {
                inner
                    .units
                    .iter()
                    .find(|u| u.id == p.unit_id && u.site_id == target_site_id)
                    .map(|u| (p.clone(), u.site_id.clone()))
            })
            .collect()
    };

    let service = crate::services::PaymentTrackingService::new(state.clone());
    let mut total_processed = 0;
    let mut total_cleared = Decimal::ZERO;
    let mut total_advance = Decimal::ZERO;
    let mut matched_debts_count = 0;
    let mut matched_advance_count = 0;
    for (record, site_id) in pending {
        // The pending row becomes the settled entry (SPEC-005 R2): no duplicate.
        let (payer_role, payer_name) = {
            let inner = state.inner.read().await;
            let unit = inner.units.iter().find(|u| u.id == record.unit_id);
            match unit {
                Some(u) => {
                    crate::handlers::resolve_payer(&inner, u, record.homeowner_name.as_deref())
                }
                None => (
                    DebtorType::Owner,
                    record
                        .homeowner_name
                        .clone()
                        .unwrap_or_else(|| "Kat Maliki".to_string()),
                ),
            }
        };
        let receipt = service
            .record_and_allocate_payment(crate::models::RecordManualPaymentRequest {
                site_id: Some(site_id),
                unit_id: record.unit_id.clone(),
                amount: record.amount,
                payer_name,
                payer_role,
                payer_person_id: None,
                payment_channel: record.payment_method,
                description: record.note.clone(),
                payment_date: None,
                idempotency_key: Some(format!("HOP:{}", record.id)),
                designation: None,
                settles_owner_capital_dues: false,
                settles_tenant_joint_liability: false,
                external_reference: record.reference_code.clone(),
                designate_from_description: true,
                settles_unmatched_entry_id: Some(record.id.clone()),
            })
            .await
            .map_err(|e| {
                let (code, msg) = payment_error_status(e);
                (
                    code,
                    format!(
                        "Payment {} was not matched: {} ({} matched before it)",
                        record.id, msg, total_processed
                    ),
                )
            })?;
        let cleared = receipt.allocated_principal + receipt.allocated_penalty;
        if cleared > Decimal::ZERO {
            total_cleared += cleared;
            matched_debts_count += 1;
        }
        if receipt.allocated_advance > Decimal::ZERO {
            total_advance += receipt.allocated_advance;
            matched_advance_count += 1;
        }
        total_processed += 1;
    }

    Ok((
        StatusCode::OK,
        Json(MatchAllPaymentsResponse {
            total_payments_processed: total_processed,
            total_debt_cleared: total_cleared,
            total_advance_credited: total_advance,
            matched_debts_count,
            matched_advance_count,
            message: format!(
                "Toplam {} ödeme işlendi: ₺{} borç kapatıldı, ₺{} avans bakiyelerine aktarıldı.",
                total_processed, total_cleared, total_advance
            ),
        }),
    ))
}

/// Returns the homeowner payment records of the caller's site. (It used to
/// return every tenant's records to any site manager.)
pub async fn get_homeowner_payments(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(mut q): Query<SiteIdParam>,
) -> impl IntoResponse {
    if let Err(denied) = scope.pin_opt(&mut q.site_id) {
        return denied.into_response();
    }
    let site = q.site_id;
    if let Some(p) = state.db_pool() {
        return match crate::db::fetch_homeowner_payment_records_from_db(p, site.as_deref()).await {
            Ok(records) => (
                StatusCode::OK,
                Json(serde_json::to_value(records).unwrap_or_default()),
            )
                .into_response(),
            Err(e) => (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({
                    "status": "ERROR",
                    "message": crate::error::sanitized("Payment records unavailable", &e)
                })),
            )
                .into_response(),
        };
    }
    let inner = state.inner.read().await;
    let records: Vec<&HomeownerPaymentRecord> = inner
        .homeowner_payments
        .iter()
        .filter(|r| match site.as_deref() {
            None => true,
            Some(s) => inner.units.iter().any(|u| {
                crate::auth::same_id(&u.id, &r.unit_id) && crate::auth::same_id(&u.site_id, s)
            }),
        })
        .collect();
    (
        StatusCode::OK,
        Json(serde_json::to_value(records).unwrap_or_default()),
    )
        .into_response()
}

#[derive(Debug, Clone, Deserialize)]
pub struct SitePaymentsQuery {
    pub site_id: Option<String>,
}

/// Returns all incoming bank/FAST payments and reconciliation records for a given site
pub async fn get_site_payments(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(mut query): Query<SitePaymentsQuery>,
) -> impl IntoResponse {
    if let Err(denied) = scope.pin_opt(&mut query.site_id) {
        return denied.into_response();
    }
    if let Some(p) = state.db_pool() {
        if let Ok(res) =
            crate::db::payment_repository::fetch_site_payments_from_db(p, query.site_id.as_deref())
                .await
        {
            return (StatusCode::OK, Json(res)).into_response();
        }
    }

    let inner = state.inner.read().await;

    // 1. Resolve site
    let site = if let Some(ref s_id) = query.site_id {
        if s_id != "undefined" && !s_id.is_empty() {
            inner
                .sites
                .iter()
                .find(|s| &s.id == s_id)
                .cloned()
                .or_else(|| inner.sites.first().cloned())
        } else {
            inner.sites.first().cloned()
        }
    } else {
        inner.sites.first().cloned()
    };

    let site_id = site
        .as_ref()
        .map(|s| s.id.clone())
        .unwrap_or_else(|| query.site_id.clone().unwrap_or_default());
    let site_name = site.as_ref().map(|s| s.name.clone()).unwrap_or_default();
    let site_timezone = site
        .as_ref()
        .map(|s| s.timezone.clone())
        .unwrap_or_else(crate::models::default_site_timezone);

    // 2. Units in this site
    let site_units: Vec<_> = inner
        .units
        .iter()
        .filter(|u| u.site_id == site_id)
        .collect();
    let site_unit_ids: Vec<String> = site_units.iter().map(|u| u.id.clone()).collect();

    let total_advance: Decimal = site_units
        .iter()
        .map(|u| inner.advance_total(&u.id) + inner.held_advance_total(&u.id))
        .sum();

    // 3. Collect payments from reconciliation_queue and homeowner_payments for units of this site
    let mut payments = Vec::new();
    let mut total_collected = Decimal::ZERO;

    for item in inner.reconciliation_queue.iter().rev() {
        let is_site_item = if let Some(ref u_id) = item.matched_unit_id {
            site_unit_ids.contains(u_id) || site_unit_ids.is_empty()
        } else {
            // Include unmatched or general transactions
            true
        };

        if is_site_item {
            total_collected += item.transaction.amount;
            let flat_label = if let (Some(ref b), Some(u_num)) =
                (&item.matched_block, item.matched_unit_number)
            {
                inner.unit_label(b, u_num)
            } else {
                "Daire Belirlenemedi".to_string()
            };

            let is_advance = item.notes.as_deref().unwrap_or("").contains("avans")
                || item.notes.as_deref().unwrap_or("").contains("Avans");

            // Look up unit's virtual account number (Virtual IBAN)
            let virtual_iban = item.matched_unit_id.as_ref().and_then(|uid| {
                inner
                    .units
                    .iter()
                    .find(|u| &u.id == uid)
                    .and_then(|u| u.virtual_iban.clone())
            });

            // Check if there is a linked homeowner payment to detect exact method (e.g. CREDIT_CARD)
            let linked_hp = inner.homeowner_payments.iter().find(|hp| {
                hp.id == item.transaction.transaction_id
                    || hp.reference_code.as_deref() == Some(&item.transaction.transaction_id)
            });

            let desc_upper = item.transaction.description.to_uppercase();
            let txn_upper = item.transaction.transaction_id.to_uppercase();

            let (payment_channel, payment_channel_label) = if let Some(hp) = linked_hp {
                match hp.payment_method {
                    PaymentChannel::CreditCard => ("CREDIT_CARD", "Kredi Kartı (Online)"),
                    PaymentChannel::VirtualIban => ("VIRTUAL_IBAN", "Sanal IBAN (Virtual Account)"),
                    PaymentChannel::Fast => ("FAST", "FAST 7/24 Anlık Takas"),
                    _ => ("BANK_TRANSFER", "Banka Havale / EFT"),
                }
            } else if desc_upper.contains("KART")
                || desc_upper.contains("CARD")
                || txn_upper.contains("CC")
                || txn_upper.contains("CARD")
            {
                ("CREDIT_CARD", "Kredi Kartı (Online)")
            } else if desc_upper.contains("SANAL IBAN")
                || desc_upper.contains("VIRTUAL")
                || txn_upper.contains("VIBAN")
            {
                ("VIRTUAL_IBAN", "Sanal IBAN (Virtual Account)")
            } else if txn_upper.contains("FAST") || desc_upper.contains("FAST") {
                ("FAST", "FAST 7/24 Anlık Takas")
            } else if item.status == ReconciliationStatus::Unmatched {
                ("UNMATCHED", "Eşleşmeyen Transfer")
            } else {
                ("BANK_TRANSFER", "Banka Havale / EFT")
            };

            let resolved_resident_name = item
                .matched_resident_name
                .clone()
                .or_else(|| item.transaction.sender_name.clone())
                .or_else(|| {
                    item.matched_unit_id.as_ref().and_then(|uid| {
                        inner
                            .units
                            .iter()
                            .find(|u| &u.id == uid)
                            .and_then(|u| u.owner_user_id.as_ref())
                            .and_then(|owner_id| {
                                inner.users.iter().find(|user| &user.id == owner_id)
                            })
                            .map(|user| user.full_name.clone())
                    })
                })
                .unwrap_or_else(|| "Bilinmiyor".to_string());

            payments.push(serde_json::json!({
                "match_id": item.match_id,
                "transaction_id": item.transaction.transaction_id,
                "date": item.transaction.date.to_string(),
                "unit_id": item.matched_unit_id,
                "block": item.matched_block,
                "unit_number": item.matched_unit_number,
                "flat_label": flat_label,
                "resident_name": resolved_resident_name,
                "amount": item.transaction.amount.to_string(),
                "currency": item.transaction.currency,
                "description": item.transaction.description,
                "sender_name": item.transaction.sender_name,
                "sender_iban": item.transaction.sender_iban,
                "virtual_iban": virtual_iban,
                "payment_channel": payment_channel,
                "payment_channel_label": payment_channel_label,
                "status": item.status.as_str(),
                "status_code": item.status_code,
                "notes": item.notes,
                "confidence_score": item.confidence_score,
                "is_advance": is_advance,
                "reference_no": item.transaction.reference_no,
            }));
        }
    }

    // Also include any direct homeowner payments for units of this site that might not be in reconciliation_queue
    for hp in inner.homeowner_payments.iter().rev() {
        if site_unit_ids.contains(&hp.unit_id) {
            let already_included = payments.iter().any(|p| {
                p.get("transaction_id").and_then(|t| t.as_str()) == Some(&hp.id)
                    || (hp.reference_code.is_some()
                        && p.get("transaction_id").and_then(|t| t.as_str())
                            == hp.reference_code.as_deref())
            });

            if !already_included {
                total_collected += hp.amount;
                let unit = inner.units.iter().find(|u| u.id == hp.unit_id);
                let flat_label = inner.unit_label(&hp.block_id, hp.unit_number);

                let resident_name = hp.homeowner_name.clone().unwrap_or_else(|| {
                    unit.and_then(|u| u.owner_user_id.as_ref())
                        .and_then(|uid| inner.users.iter().find(|user| &user.id == uid))
                        .map(|user| user.full_name.clone())
                        .unwrap_or_else(|| "Bilinmiyor".to_string())
                });

                let virtual_iban = unit.and_then(|u| u.virtual_iban.clone());
                let is_advance = hp.advance_credit_amount > Decimal::ZERO;

                let payment_channel = hp.payment_method.as_str();
                let payment_channel_label = match hp.payment_method {
                    PaymentChannel::CreditCard => "Kredi Kartı (Online)".to_string(),
                    PaymentChannel::VirtualIban => "Sanal IBAN (Virtual Account)".to_string(),
                    PaymentChannel::Fast => "FAST 7/24 Anlık Takas".to_string(),
                    _ => "Banka Havale / EFT".to_string(),
                };

                payments.push(serde_json::json!({
                    "match_id": format!("MATCH-HP-{}", hp.id),
                    "transaction_id": hp.id.clone(),
                    "date": crate::domain::clock::local_date(&site_timezone, hp.created_at).to_string(),
                    "unit_id": Some(hp.unit_id.clone()),
                    "block": Some(hp.block_id.clone()),
                    "unit_number": Some(hp.unit_number),
                    "flat_label": flat_label,
                    "resident_name": resident_name.clone(),
                    "amount": hp.amount.to_string(),
                    "currency": "TRY",
                    "description": hp.note.clone().unwrap_or_else(|| format!("{} ile Aidat Ödemesi", payment_channel_label)),
                    "sender_name": Some(resident_name),
                    "sender_iban": Option::<String>::None,
                    "virtual_iban": virtual_iban,
                    "payment_channel": payment_channel,
                    "payment_channel_label": payment_channel_label,
                    "status": "ONAYLANDI",
                    "status_code": "ONAYLANDI",
                    "notes": hp.note,
                    "confidence_score": 100,
                    "is_advance": is_advance,
                    "reference_no": hp.reference_code.clone().or_else(|| Some(hp.id.clone())),
                }));
            }
        }
    }

    let payments_count = payments.len();

    let guidance = if site_id.is_empty() {
        "Sistemde kayıtlı bir site bulunmuyor. Ödeme takibi için önce site oluşturunuz."
    } else if site_units.is_empty() {
        "Bu sitede henüz kayıtlı kat maliki veya daire bulunmuyor. Sanal IBAN ve FAST ödemeleri için kat maliki tanımlayınız."
    } else if payments.is_empty() {
        "Bu site için henüz gerçekleşmiş bir aidat ödemesi veya banka transferi bulunmuyor. Kat malikleri kendilerine tahsis edilen Sanal IBAN, FAST veya kredi kartı ile ödeme yapabilir."
    } else {
        ""
    };

    (
        StatusCode::OK,
        Json(serde_json::json!({
            "site_id": site_id,
            "site_name": site_name,
            "total_units_count": site_units.len(),
            "total_collected": total_collected.to_string(),
            "total_advance_balance": total_advance.to_string(),
            "payments_count": payments_count,
            "payments": payments,
            "guidance": guidance
        })),
    )
        .into_response()
}

pub async fn get_payment_stream(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(mut filter): Query<crate::models::PaymentStreamFilter>,
) -> Result<Json<crate::models::PaymentStreamResponse>, (StatusCode, String)> {
    scope.pin_opt(&mut filter.site_id)?;
    let service = crate::services::PaymentTrackingService::new(state);
    service
        .get_payment_stream(filter)
        .await
        .map(Json)
        .map_err(|e| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                crate::error::sanitized("Internal error", &e),
            )
        })
}

pub async fn get_debt_aging_report(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<crate::models::DebtAgingReport>, (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = crate::services::PaymentTrackingService::new(state);
    service
        .get_debt_aging_report(&site_id)
        .await
        .map(Json)
        .map_err(|e| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                crate::error::sanitized("Internal error", &e),
            )
        })
}

pub async fn record_manual_payment(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    headers: axum::http::HeaderMap,
    Json(mut payload): Json<crate::models::RecordManualPaymentRequest>,
) -> Result<(StatusCode, Json<crate::models::PaymentReceipt>), (StatusCode, String)> {
    scope.pin_opt(&mut payload.site_id)?;
    // The standard `Idempotency-Key` header takes precedence over the body field.
    if let Some(key) = headers.get("idempotency-key").and_then(|v| v.to_str().ok()) {
        payload.idempotency_key = Some(key.to_string());
    }
    let service = crate::services::PaymentTrackingService::new(state);
    service
        .record_and_allocate_payment(payload)
        .await
        .map(|r| (StatusCode::CREATED, Json(r)))
        .map_err(payment_error_status)
}

pub async fn inter_ledger_transfer(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Json(mut payload): Json<crate::models::InterLedgerTransferRequest>,
) -> Result<Json<crate::models::InterLedgerTransferResponse>, (StatusCode, String)> {
    scope.pin_opt(&mut payload.site_id)?;
    let service = crate::services::PaymentTrackingService::new(state);
    service
        .inter_ledger_transfer(payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

/// Staff-only (auth::route_access): reverses a settled payment with a reason
/// (SPEC-006 R2). The operator is taken from the token, never from the body.
pub async fn reverse_payment(
    State(state): State<AppState>,
    ctx: crate::authorization::AuthzContext,
    Json(mut payload): Json<crate::models::ReversePaymentRequest>,
) -> Result<(StatusCode, Json<crate::models::ReversePaymentResponse>), (StatusCode, String)> {
    // A foreign site in the body is refused; a missing one becomes the caller's.
    crate::tenancy::TenantScope::from_claims(&ctx.claims).pin_opt(&mut payload.site_id)?;
    if payload.site_id.is_none() {
        payload.site_id = Some(ctx.claims.site_id.clone());
    }
    let site_id = payload.site_id.clone().unwrap_or_default();
    let service = crate::services::PaymentTrackingService::new(state.clone());
    let reversal = service
        .reverse_payment(payload, &ctx)
        .await
        .map_err(payment_error_status)?;
    // A reversed card payment is refunded at the provider (SPEC-007 R4).
    if reversal.reversal_receipt.payment_channel == PaymentChannel::CreditCard {
        if let Err(e) = crate::services::CardPaymentService::new(state)
            .refund_for_receipt(&site_id, &reversal.reversed_receipt_number)
            .await
        {
            tracing::error!(
                "Card refund for {} was not completed: {}",
                reversal.reversed_receipt_number,
                e
            );
        }
    }
    Ok((StatusCode::CREATED, Json(reversal)))
}

/// The `as_of_date` reported for a debt aging snapshot: today in the site's
/// time zone, or in the default site zone when no site was named.
fn debt_aging_as_of(
    inner: &crate::state::AppStateInner,
    site_filter: Option<&str>,
    now: chrono::DateTime<Utc>,
) -> chrono::NaiveDate {
    match site_filter {
        Some(site_id) => crate::services::finance_common::site_today_at(inner, site_id, now),
        None => crate::domain::clock::local_date(&crate::models::default_site_timezone(), now),
    }
}

/// Writes today's debt aging snapshot (O-8). The daily worker does the same.
pub async fn snapshot_debt_aging(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(mut q): Query<SiteIdParam>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    scope.pin_opt(&mut q.site_id)?;
    let site_filter = q.site_id.as_deref().filter(|s| !s.trim().is_empty());
    let as_of_date = {
        let inner = state.inner.read().await;
        debt_aging_as_of(&inner, site_filter, crate::e2e_clock::now_utc())
    };
    let service = crate::services::PaymentTrackingService::new(state);
    let rows = service
        .snapshot_debt_aging(site_filter)
        .await
        .map_err(|e| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                crate::error::sanitized("Internal error", &e),
            )
        })?;
    Ok(Json(
        serde_json::json!({ "status": "OK", "rows": rows, "as_of_date": as_of_date }),
    ))
}

pub async fn get_payment_receipt(
    State(state): State<AppState>,
    ctx: crate::authorization::AuthzContext,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<crate::models::PaymentReceipt>, crate::authorization::SecurityError> {
    let site = q.site_id.unwrap_or_else(|| ctx.claims.site_id.clone());
    ctx.require(crate::models::Permission::UnitRead, &site)?;
    crate::authorization::resource(&state, &ctx.claims, "receipt", &id).await?;
    let receipt = crate::services::PaymentTrackingService::new(state.clone())
        .get_receipt(&site, &id)
        .await
        .map_err(|_| crate::authorization::SecurityError::NotFound)?;
    crate::authorization::unit(&state, &ctx.claims, &receipt.unit_id).await?;
    Ok(Json(receipt))
}

pub async fn transfer_unit_ownership(
    State(state): State<AppState>,
    ctx: crate::authorization::AuthzContext,
    scope: crate::tenancy::TenantScope,
    Path(unit_id): Path<String>,
    Json(mut payload): Json<crate::models::TransferOwnershipRequest>,
) -> Result<Json<crate::models::TransferOwnershipResponse>, crate::error::AppError> {
    use crate::services::finance_common::{Caller, FinanceError};
    use crate::services::sale_clearance_service::TransferFlowError;
    // A site-scoped manager must use the site from their authenticated scope;
    // a stale client selection must not block an operation on an authorized unit.
    if let Some(site_id) = scope.own_site() {
        payload.site_id = Some(site_id.to_string());
    } else {
        scope.pin_opt(&mut payload.site_id)?;
    }
    payload.unit_id = unit_id;
    apply_new_owner_ref(&state, &mut payload).await?;
    let override_reason = payload
        .seller_pays_override_reason
        .as_deref()
        .map(str::trim)
        .filter(|reason| !reason.is_empty())
        .map(str::to_string);
    if override_reason.is_some() && payload.new_owner_person_id.is_none() {
        return Err(crate::error::AppError::validation(
            "A seller-pays override needs the buyer as an existing person or a new card",
        ));
    }
    let mut caller = Caller::from_claims(&ctx.claims);
    if let Some(site_id) = payload.site_id.clone() {
        caller.site_id = site_id;
    }
    let response = crate::services::sale_clearance_service::SaleClearanceService::new(&state)
        .transfer_with_follow_ups(&caller, payload, override_reason)
        .await
        .map_err(|error| match error {
            TransferFlowError::Override(e) => {
                let status = match e {
                    FinanceError::Invalid(_) => StatusCode::BAD_REQUEST,
                    FinanceError::NotFound(_) => StatusCode::NOT_FOUND,
                    _ => StatusCode::CONFLICT,
                };
                crate::error::AppError::from((status, e.to_string()))
            }
            TransferFlowError::Transfer(e) => {
                crate::error::AppError::from((StatusCode::BAD_REQUEST, e))
            }
        })?;
    Ok(Json(response))
}

/// Maps `new_owner` onto the legacy buyer fields. A new card is created first, so
/// the duplicate rules and `confirm_distinct` apply; an existing card is read from
/// the site. The buyer is then always identified by `new_owner_person_id`.
async fn apply_new_owner_ref(
    state: &AppState,
    payload: &mut crate::models::TransferOwnershipRequest,
) -> Result<(), crate::error::AppError> {
    use crate::models::{CreatePersonRequest, PersonRef};
    let Some(reference) = payload.new_owner.clone() else {
        return Ok(());
    };
    let site = payload
        .site_id
        .as_deref()
        .and_then(crate::db::parse_id_to_i64)
        .ok_or_else(|| crate::error::AppError::validation("Site is not valid"))?;
    let service = crate::services::person_service::PersonService::new(state);
    let person_id = match reference {
        PersonRef::Existing { person_id } => person_id,
        PersonRef::New {
            card,
            confirm_distinct,
        } => {
            service
                .create(
                    site,
                    &CreatePersonRequest {
                        card,
                        confirm_distinct,
                    },
                )
                .await
                .map_err(super::site_admin::person_api_error)?
                .card
                .person_id
        }
    };
    let card = service
        .card(site, person_id)
        .await
        .map_err(super::site_admin::person_api_error)?
        .card;
    payload.new_owner_person_id = Some(person_id);
    payload.new_owner_name = card.full_name;
    payload.new_owner_phone = card.phone;
    payload.new_owner_email = card.email;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn istanbul_site(id: &str) -> Site {
        Site {
            id: id.to_string(),
            name: "Site".to_string(),
            address: "Kadıköy, İstanbul".to_string(),
            slug: format!("site-{id}"),
            status: SiteStatus::Active,
            plan_type: PlanType::Premium,
            license_end_date: chrono::NaiveDate::from_ymd_opt(2027, 1, 1).unwrap_or_default(),
            timezone: "Europe/Istanbul".to_string(),
            proration_enabled: false,
            tax_id: None,
            tax_office: None,
        }
    }

    #[test]
    fn debt_aging_as_of_is_the_site_local_date_after_21_utc() {
        // 2026-11-30 22:30 UTC is 2026-12-01 01:30 in Istanbul.
        let now = Utc
            .with_ymd_and_hms(2026, 11, 30, 22, 30, 0)
            .single()
            .unwrap_or_default();
        let mut inner = crate::state::AppStateInner::default();
        inner.sites.push(istanbul_site("7"));
        let next_day = chrono::NaiveDate::from_ymd_opt(2026, 12, 1).unwrap_or_default();
        assert_eq!(debt_aging_as_of(&inner, Some("7"), now), next_day);
        assert_eq!(debt_aging_as_of(&inner, None, now), next_day);
        assert_ne!(debt_aging_as_of(&inner, Some("7"), now), now.date_naive());
    }

    #[tokio::test]
    async fn reconciliation_payments_date_is_the_site_local_date_after_21_utc() {
        let now = Utc
            .with_ymd_and_hms(2026, 11, 30, 22, 30, 0)
            .single()
            .unwrap_or_default();
        let state = crate::state::AppState::new();
        {
            let mut inner = state.inner.write().await;
            inner.sites.push(istanbul_site("7"));
            inner.units.push(crate::models::IndependentUnit {
                id: "u-1".to_string(),
                site_id: "7".to_string(),
                block_id: "A".to_string(),
                unit_number: 1,
                floor: 1,
                land_share: 100,
                owner_user_id: None,
                tenant_user_id: None,
                virtual_iban: None,
                house_type: None,
                monthly_tariff_override: None,
                created_on: None,
            });
            inner
                .homeowner_payments
                .push(crate::models::HomeownerPaymentRecord {
                    id: "hp-1".to_string(),
                    unit_id: "u-1".to_string(),
                    block_id: "A".to_string(),
                    unit_number: 1,
                    homeowner_name: Some("Test".to_string()),
                    amount: Decimal::from(100),
                    payment_method: PaymentChannel::CreditCard,
                    reference_code: None,
                    note: None,
                    status: crate::models::PaymentMatchStatus::MatchedDebt,
                    cleared_debt_amount: Decimal::from(100),
                    advance_credit_amount: Decimal::ZERO,
                    created_at: now,
                });
        }
        let response = get_site_payments(
            State(state),
            crate::tenancy::TenantScope::site("7"),
            Query(SitePaymentsQuery {
                site_id: Some("7".to_string()),
            }),
        )
        .await
        .into_response();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("bytes");
        let body: serde_json::Value = serde_json::from_slice(&bytes).expect("json");
        let payment = &body["payments"][0];
        assert_eq!(payment["date"], "2026-12-01");
        assert_ne!(payment["date"], now.date_naive().to_string());
    }
}
