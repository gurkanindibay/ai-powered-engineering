use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use chrono::Utc;
use rust_decimal::Decimal;
use serde::Deserialize;
use serde_json::json;

use crate::models::*;
use crate::services::{
    AuthService, CapitalProjectService, DuesCalculationService, HomeResidentInvitationService,
    KuveytTurkSandboxService, ReconciliationService, RegistrationApprovalService,
    SaasTenantService, SiteAdminService, SiteBankAccountService, VirtualIbanService,
};
use crate::state::AppState;


/// Snapshot of the in-memory ledger (liability payment state and advance
/// balances), used to persist exactly what an in-memory operation changed.
pub struct LedgerSnapshot {
    dues: std::collections::HashMap<String, (Decimal, Decimal, Decimal, DebtStatus)>,
    advances: std::collections::HashMap<String, UnitAdvance>,
}

pub fn ledger_snapshot(inner: &crate::state::AppStateInner) -> LedgerSnapshot {
    LedgerSnapshot {
        dues: inner
            .dues
            .iter()
            .map(|d| (d.id.clone(), (d.paid_principal, d.paid_penalty, d.delay_penalty, d.status)))
            .collect(),
        advances: inner.advance_balances.clone(),
    }
}

/// Persists every liability and advance balance that differs from `before`.
/// Errors are returned (and logged), never discarded.
pub async fn persist_ledger_changes(
    pool: &deadpool_postgres::Pool,
    before: &LedgerSnapshot,
    inner: &crate::state::AppStateInner,
) -> Result<(), String> {
    let mut errors: Vec<String> = Vec::new();
    for d in &inner.dues {
        let now = (d.paid_principal, d.paid_penalty, d.delay_penalty, d.status);
        if before.dues.get(&d.id) != Some(&now) && crate::db::parse_id_to_i64(&d.id).is_some() {
            if let Err(e) = crate::db::sync_due_payment_state(pool, d).await {
                errors.push(format!("dues liability {}: {}", d.id, e));
            }
        }
    }
    for (unit, adv) in &inner.advance_balances {
        let old = before.advances.get(unit).copied().unwrap_or_default();
        for (debtor, now, was) in [("OWNER", adv.owner, old.owner), ("TENANT", adv.tenant, old.tenant)] {
            if now != was {
                if let Err(e) = crate::db::save_advance_balance(pool, unit, debtor, now).await {
                    errors.push(format!("advance balance {}/{}: {}", unit, debtor, e));
                }
            }
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        tracing::error!("Ledger persistence failed: {}", errors.join("; "));
        Err(format!("Ledger changes were not fully saved: {}", errors.join("; ")))
    }
}

/// Domain Service / Rule: Advance Balance Auto-Offsetting
/// When dues liabilities exist or arrive for a unit, available advance balance
/// (Avans Bakiye) is automatically deducted against the debt (FIFO order by
/// due_date). Each liability is offset only from its own debtor's advance
/// (O-1): a tenant's surplus never silently pays the owner's dues; that takes an
/// explicit TENANT -> OWNER inter-ledger transfer.
pub fn apply_advance_payments_offset(
    inner: &mut crate::state::AppStateInner,
    target_unit_id: Option<&str>,
) -> (usize, Decimal) {
    let unit_ids: Vec<String> = match target_unit_id {
        Some(u) => vec![u.to_string()],
        None => inner.units.iter().map(|u| u.id.clone()).collect(),
    };

    let mut auto_settled_count = 0;
    let mut total_offset_amount = Decimal::ZERO;

    for u_id in unit_ids {
        let mut buckets = match inner.advance_balances.get(&u_id) {
            Some(adv) if adv.total() > Decimal::ZERO => *adv,
            _ => continue,
        };

        // Find all unpaid dues for this unit
        let mut unpaid_indices: Vec<usize> = inner
            .dues
            .iter()
            .enumerate()
            .filter(|(_, d)| d.unit_id == u_id && d.status != DebtStatus::Paid)
            .map(|(i, _)| i)
            .collect();

        // FIFO: Sort by due_date ascending
        unpaid_indices.sort_by_key(|&i| inner.dues[i].due_date);

        let unit_site_id = inner.units.iter().find(|u| u.id == *u_id).map(|u| u.site_id.clone()).unwrap_or_else(|| "1".to_string());
        let unit_block = inner.units.iter().find(|u| u.id == *u_id).map(|u| u.block_id.clone()).unwrap_or_else(|| "A".to_string());
        let unit_number = inner.units.iter().find(|u| u.id == *u_id).map(|u| u.unit_number).unwrap_or(1);
        let unit_resident_name = inner
            .units
            .iter()
            .find(|u| u.id == *u_id)
            .and_then(|u| u.owner_user_id.as_ref())
            .and_then(|uid| inner.users.iter().find(|user| &user.id == uid))
            .map(|user| user.full_name.clone());

        for idx in unpaid_indices {
            let debtor = inner.dues[idx].debtor_type.clone();
            let advance = buckets.bucket_mut(&debtor);
            if *advance <= Decimal::ZERO {
                continue;
            }

            let due = &mut inner.dues[idx];
            // KMK 20 segmented accrual: bring the penalty up to today before the
            // offset changes the principal it accrues on.
            *due = crate::services::DuesCalculationService::new().calculate_delay_penalty(due.clone(), Utc::now().date_naive());
            let due_amount = due.total_amount;
            let period = due.period.clone();
            let due_id = due.id.clone();

            if *advance >= due_amount {
                // Full settlement of this due liability (penalty first, then principal)
                let settled = crate::services::dues_ledger::settle(due, due_amount);
                *advance -= settled.total();
                total_offset_amount += settled.total();
                auto_settled_count += 1;

                let offset_txn_id = format!("TXN-ADV-OFFSET-{}", due_id);
                if !inner.reconciliation_queue.iter().any(|m| m.transaction.transaction_id == offset_txn_id) {
                    let match_seq = inner.reconciliation_queue.len() + 1;
                    inner.reconciliation_queue.push(ReconciliationMatch {
                        match_id: format!("MATCH-OFFSET-{}", match_seq),
                        site_id: unit_site_id.clone(),
                        transaction: BankTransactionItem {
                            transaction_id: offset_txn_id,
                            date: Utc::now().date_naive(),
                            amount: due_amount,
                            currency: "TRY".to_string(),
                            description: format!("Avans Mahsubu: {} Aidatı", period),
                            sender_name: Some("Otomatik Avans Mahsubu".to_string()),
                            sender_iban: None,
                            reference_no: Some(due_id.clone()),
                        },
                        matched_unit_id: Some(u_id.clone()),
                        matched_block: Some(unit_block.clone()),
                        matched_unit_number: Some(unit_number),
                        matched_resident_name: unit_resident_name.clone(),
                        confidence_score: 100,
                        matched_due_id: Some(due_id),
                        outstanding_balance: Some(due_amount),
                        amount_matches_balance: true,
                        status: ReconciliationStatus::Approved,
                        status_code: ReconciliationStatus::Approved.as_str().to_string(),
                        notes: Some(format!("{} aidatı avans bakiyenizden otomatik mahsup edildi", period)),
                    });
                }
            } else {
                // Partial deduction
                let partial = crate::services::dues_ledger::settle(due, *advance).total();
                *advance -= partial;
                total_offset_amount += partial;

                let offset_txn_id = format!("TXN-ADV-PARTIAL-{}", due_id);
                if !inner.reconciliation_queue.iter().any(|m| m.transaction.transaction_id == offset_txn_id) {
                    let match_seq = inner.reconciliation_queue.len() + 1;
                    inner.reconciliation_queue.push(ReconciliationMatch {
                        match_id: format!("MATCH-OFFSET-PARTIAL-{}", match_seq),
                        site_id: unit_site_id.clone(),
                        transaction: BankTransactionItem {
                            transaction_id: offset_txn_id,
                            date: Utc::now().date_naive(),
                            amount: partial,
                            currency: "TRY".to_string(),
                            description: format!("Kısmi Avans Mahsubu: {} Aidatı", period),
                            sender_name: Some("Otomatik Avans Mahsubu".to_string()),
                            sender_iban: None,
                            reference_no: Some(due_id.clone()),
                        },
                        matched_unit_id: Some(u_id.clone()),
                        matched_block: Some(unit_block.clone()),
                        matched_unit_number: Some(unit_number),
                        matched_resident_name: unit_resident_name.clone(),
                        confidence_score: 100,
                        matched_due_id: Some(due_id),
                        outstanding_balance: Some(partial),
                        amount_matches_balance: false,
                        status: ReconciliationStatus::Approved,
                        status_code: ReconciliationStatus::Approved.as_str().to_string(),
                        notes: Some(format!("₺{:.2} tutarındaki avans {} aidatından mahsup edildi", partial, period)),
                    });
                }
            }
        }
        inner.advance_balances.insert(u_id.clone(), buckets);
    }

    (auto_settled_count, total_offset_amount)
}

fn format_resident_transaction_display(m: &ReconciliationMatch) -> (String, String) {
    let note = m.notes.as_deref().unwrap_or("");
    let desc = &m.transaction.description;
    let desc_upper = desc.to_uppercase();
    let note_upper = note.to_uppercase();

    let is_card = desc_upper.contains("KART") 
        || desc_upper.contains("CREDIT_CARD") 
        || desc_upper.contains("CARD") 
        || note_upper.contains("KART")
        || note_upper.contains("CREDIT_CARD");

    // Case 0: Settled dues via Advance Offset (Avans Mahsubu)
    if note.contains("mahsup") || note.contains("otomatik mahsup") {
        let title = if note.contains("Kısmi") || note.contains("kısmi") {
            "Kısmi Avans Mahsubu".to_string()
        } else {
            "Avans ile Aidat Tahsili".to_string()
        };
        let subtitle = note.to_string();
        return (title, subtitle);
    }

    // Case 1: Advance top-up (pure advance when no debt exists)
    if note.contains("No outstanding debt") 
        || note.contains("Aktif aidat borcu bulunmuyor") 
        || note.contains("Aktif borç bulunmuyor") 
        || (m.matched_due_id.is_none() && !note.contains("Settled") && (note.contains("advance payment") || note.contains("avans bakiyenize eklendi"))) {
        let title = if is_card {
            "Kart ile Avans Yükleme".to_string()
        } else {
            "FAST ile Avans Yükleme".to_string()
        };
        let subtitle = "Aktif borç bulunmuyor • Avans bakiyenize aktarıldı".to_string();
        return (title, subtitle);
    }

    // Case 2: Settled dues (with or without surplus)
    if note.contains("Settled") || note.contains("aidat") || note.contains("Aidat") || m.matched_due_id.is_some() || desc_upper.contains("AIDAT") {
        let title = if is_card {
            "Kart ile Aidat Ödemesi".to_string()
        } else {
            "FAST ile Aidat Ödemesi".to_string()
        };

        let subtitle = if note.contains("surplus") || note.contains("artan") || note.contains("avans bakiyenize") || note.contains("avans bakiyesine") {
            // Support legacy English notes from queue: "100% Match via Virtual IBAN. Settled Eylül 2026; ₺60.67 surplus credited to advance payment."
            if let Some(settled_idx) = note.find("Settled ") {
                let after_settled = &note[settled_idx + 8..];
                let period = after_settled.split(';').next().unwrap_or("Dönem").trim();
                let surplus = if let Some(surplus_idx) = note.find(';') {
                    let after_semi = &note[surplus_idx + 1..];
                    after_semi.split(" surplus").next().unwrap_or("").trim()
                } else {
                    ""
                };
                let surplus_formatted = surplus.replace('.', ",");
                if !surplus_formatted.is_empty() {
                    format!("{} aidatı ödendi • {} avans bakiyenize aktarıldı", period, surplus_formatted)
                } else {
                    format!("{} aidatı ödendi • Kalan tutar avans bakiyenize aktarıldı", period)
                }
            } else if note.contains("aidatı ödendi") || note.contains("aidat borcu ödendi") {
                note.to_string()
            } else {
                "Aidat ödendi • Artan tutar avans bakiyenize aktarıldı".to_string()
            }
        } else if let Some(settled_idx) = note.find("Settled ") {
            let after_settled = &note[settled_idx + 8..];
            let period = after_settled.split(';').next().unwrap_or("Dönem").trim();
            format!("{} aidat borcu kapatıldı", period)
        } else if note.contains("aidat borcu kapatıldı") || note.contains("aidat borcu başarıyla kapatıldı") {
            note.to_string()
        } else {
            "Aidat borcu başarıyla kapatıldı".to_string()
        };

        (title, subtitle)
    } 
    // Case 3: Other bank transfer
    else {
        let title = if is_card {
            "Kart ile Bakiye Yükleme".to_string()
        } else {
            "FAST ile Bakiye Yükleme".to_string()
        };
        let subtitle = if note.is_empty() || note.contains("Virtual IBAN") {
            if is_card {
                "Kredi kartı ödemesi başarıyla hesabınıza aktarıldı".to_string()
            } else {
                "FAST transferi başarıyla hesabınıza aktarıldı".to_string()
            }
        } else {
            note.to_string()
        };
        (title, subtitle)
    }
}

// 1. Resident Dashboard Handler
pub async fn get_resident_dashboard(
    Path(unit_id): Path<String>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let calc_service = DuesCalculationService::new();
    let mut inner = state.inner.write().await;
    let ledger_before = ledger_snapshot(&inner);

    let unit_opt = if let Some(u) = inner.units.iter().find(|u| u.id == unit_id || crate::db::parse_id_to_i64(&u.id) == crate::db::parse_id_to_i64(&unit_id)).cloned() {
        Some(u)
    } else if let Some(ref pool) = state.pool {
        if let Ok(client) = pool.get().await {
            let num_id = crate::db::parse_id_to_i64(&unit_id).unwrap_or(0);
            if let Ok(Some(row)) = client.query_opt(
                "SELECT u.id, u.site_id, COALESCE(b.block_name, 'A Blok'), u.unit_number, u.floor, u.land_share, u.owner_person_id, u.tenant_person_id, u.virtual_iban, u.house_type FROM units u LEFT JOIN blocks b ON u.block_id = b.id WHERE u.id = $1 OR u.id::text = $2",
                &[&num_id, &unit_id],
            ).await {
                let u_id: i64 = row.get(0);
                let s_id: Option<i64> = row.get(1);
                let b_name: String = row.get(2);
                let u_num: i32 = row.get(3);
                let floor: i32 = row.get(4);
                let land_share: i32 = row.get(5);
                let o_pid: Option<i64> = row.get(6);
                let t_pid: Option<i64> = row.get(7);
                let v_iban: Option<String> = row.get(8);
                let h_type: Option<String> = row.get(9);
                Some(IndependentUnit {
                    id: u_id.to_string(),
                    site_id: s_id.map(|s| s.to_string()).unwrap_or_else(|| "1".to_string()),
                    block_id: b_name,
                    unit_number: u_num,
                    floor,
                    land_share,
                    owner_user_id: o_pid.map(|p| p.to_string()),
                    tenant_user_id: t_pid.map(|p| p.to_string()),
                    virtual_iban: v_iban,
                    house_type: h_type,
                })
            } else {
                None
            }
        } else {
            None
        }
    } else {
        None
    };

    let unit = match unit_opt {
        Some(u) => u,
        None => {
            {
                return (
                    StatusCode::NOT_FOUND,
                    Json(serde_json::json!({
                        "status": "ERROR",
                        "message": format!("Unit '{}' not found in database", unit_id)
                    })),
                ).into_response();
            }
        }
    };

    // Automatically apply available advance payments against any unpaid dues (FIFO)
    apply_advance_payments_offset(&mut inner, Some(&unit_id));
    if let Some(ref pool) = state.pool {
        // Errors are logged by persist_ledger_changes; the view is still served.
        let _logged = persist_ledger_changes(pool, &ledger_before, &inner).await;
    }

    let today = Utc::now().date_naive();
    let evaluated_dues: Vec<DuesLiability> = inner
        .dues
        .iter()
        .filter(|d| d.unit_id == unit_id && d.status != DebtStatus::Paid)
        .map(|d| calc_service.calculate_delay_penalty(d.clone(), today))
        .collect();

    let total_debt: Decimal = evaluated_dues.iter().map(|d| d.total_amount).sum();
    let is_overdue = evaluated_dues.iter().any(|d| d.status == DebtStatus::Overdue);

    let dues_dtos: Vec<DuesSummaryDto> = inner
        .dues
        .iter()
        .filter(|d| d.unit_id == unit_id)
        .map(|d| {
            if d.status == DebtStatus::Paid {
                DuesSummaryDto {
                    id: d.id.clone(),
                    period: d.period.clone(),
                    principal_amount: d.principal_amount,
                    delay_penalty: Decimal::ZERO,
                    total_amount: d.total_amount,
                    due_date: d.due_date.to_string(),
                    status: "PAID".to_string(),
                }
            } else {
                let evaluated = calc_service.calculate_delay_penalty(d.clone(), today);
                DuesSummaryDto {
                    id: evaluated.id.clone(),
                    period: evaluated.period.clone(),
                    principal_amount: evaluated.principal_amount,
                    delay_penalty: evaluated.delay_penalty,
                    total_amount: evaluated.total_amount,
                    due_date: evaluated.due_date.to_string(),
                    status: format!("{:?}", evaluated.status).to_uppercase(),
                }
            }
        })
        .collect();

    let site_name = inner
        .sites
        .iter()
        .find(|s| s.id == unit.site_id)
        .map(|s| s.name.clone())
        .unwrap_or_else(|| "Site".to_string());
    let site_title = format!("{} • {} Blok D:{}", site_name, unit.block_id, unit.unit_number);
    let advance_payment = inner.advance_total(&unit_id);

    let mut transactions: Vec<AccountTransactionDto> = Vec::new();

    // 1. Approved bank transactions from reconciliation queue for this unit
    for m in inner.reconciliation_queue.iter().rev() {
        if m.matched_unit_id.as_deref() == Some(&unit_id) && m.status == ReconciliationStatus::Approved {
            let (title, subtitle) = format_resident_transaction_display(m);
            transactions.push(AccountTransactionDto {
                id: m.transaction.transaction_id.clone(),
                title,
                subtitle,
                amount: m.transaction.amount,
                date: m.transaction.date.format("%d.%m.%Y").to_string(),
                is_credit: true,
            });
        }
    }

    // 2. If dues are unpaid/pending, show current dues as debit (negative)
    for due in &evaluated_dues {
        transactions.push(AccountTransactionDto {
            id: due.id.clone(),
            title: format!("{} Aidatı", due.period),
            subtitle: if is_overdue { "Gecikmeli Aidat Borcu" } else { "Ödeme Bekleniyor" }.to_string(),
            amount: due.total_amount,
            date: due.due_date.format("%d.%m.%Y").to_string(),
            is_credit: false,
        });
    }

    let response = ResidentDashboardDto {
        unit_id: unit.id,
        site_title,
        total_debt,
        is_overdue,
        dues: dues_dtos,
        announcement_title: "Planlı Su Kesintisi Hakkında".to_string(),
        announcement_content:
            "İSKİ ana hat yenilemesi sebebiyle 18 Eylül 10:00 - 14:00 arası su kesilecektir."
                .to_string(),
        virtual_iban: unit.virtual_iban,
        advance_payment,
        transactions,
    };

    (StatusCode::OK, Json(response)).into_response()
}

// 2. Auth Handlers
pub async fn login_password(
    State(state): State<AppState>,
    Json(payload): Json<PasswordLoginRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    let service = AuthService::new(state);
    service
        .authenticate_with_password(payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::UNAUTHORIZED, e))
}

pub async fn login_google(
    State(state): State<AppState>,
    Json(payload): Json<GoogleLoginRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    let service = AuthService::new(state);
    service
        .authenticate_with_google(payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn register_password(
    State(state): State<AppState>,
    Json(payload): Json<RegisterUserRequest>,
) -> Result<(StatusCode, Json<AuthResponse>), (StatusCode, String)> {
    let service = AuthService::new(state);
    service
        .register_with_password(payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn change_password(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<crate::auth::Claims>,
    Json(payload): Json<ChangePasswordRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    if !payload.email.trim().eq_ignore_ascii_case(&claims.email) {
        return Err((StatusCode::FORBIDDEN, "You can only change your own password".to_string()));
    }
    let service = AuthService::new(state);
    service
        .change_password(payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

/// Returns the profile of the authenticated caller (identity comes from the token).
pub async fn get_profile(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<crate::auth::Claims>,
) -> Result<Json<UserProfileResponse>, (StatusCode, String)> {
    let service = AuthService::new(state);
    service
        .get_current_profile(&claims.sub)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::NOT_FOUND, e))
}

// 3. SaaS Tenant Handlers
pub async fn register_site(
    State(state): State<AppState>,
    Json(payload): Json<RegisterSiteRequest>,
) -> Result<(StatusCode, Json<SiteRegistrationResponse>), (StatusCode, String)> {
    let service = SaasTenantService::new(state);
    service
        .register_site(payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_all_sites(State(state): State<AppState>) -> Json<Vec<SaasSiteSummaryDto>> {
    let service = SaasTenantService::new(state);
    Json(service.get_all_sites().await)
}

pub async fn get_saas_stats(State(state): State<AppState>) -> Json<SaasGlobalStatsDto> {
    let service = SaasTenantService::new(state);
    Json(service.get_global_stats().await)
}

pub async fn delete_site(
    Path(site_id): Path<String>,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let service = SaasTenantService::new(state);
    service
        .delete_site(&site_id)
        .await
        .map(|_| {
            (
                StatusCode::OK,
                Json(json!({
                    "success": true,
                    "message": format!("Site '{}' successfully deleted", site_id)
                })),
            )
        })
        .map_err(|e| (StatusCode::CONFLICT, e))
}

pub async fn update_site(
    Path(site_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<UpdateSiteRequest>,
) -> Result<(StatusCode, Json<SaasSiteSummaryDto>), (StatusCode, String)> {
    let service = SaasTenantService::new(state);
    service
        .update_site(&site_id, payload)
        .await
        .map(|res| (StatusCode::OK, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn reset_site_admin_password(
    Path(site_id): Path<String>,
    State(state): State<AppState>,
) -> Result<(StatusCode, Json<SiteAdminPasswordResetResponse>), (StatusCode, String)> {
    let service = SaasTenantService::new(state);
    service
        .reset_site_admin_password(&site_id)
        .await
        .map(|res| (StatusCode::OK, Json(res)))
        .map_err(|e| (StatusCode::NOT_FOUND, e))
}

// 4. Site Admin Handlers
#[derive(Deserialize)]
pub struct SiteIdParam {
    pub site_id: Option<String>,
}

pub async fn register_home_owner(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<RegisterHomeOwnerRequest>,
) -> Result<(StatusCode, Json<HomeOwnerResponse>), (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .register_home_owner(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_home_owners(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<HomeOwnerResponse>> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    Json(service.get_home_owners_for_site(&site_id).await)
}

pub async fn update_home_owner(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::UpdateHomeOwnerRequest>,
) -> Result<Json<HomeOwnerResponse>, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .update_home_owner(&site_id, &id, payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn delete_home_owner(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .delete_home_owner(&site_id, &id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| {
            let code = if e == crate::services::site_admin_service::UNIT_HAS_FINANCIAL_HISTORY {
                StatusCode::CONFLICT
            } else {
                StatusCode::BAD_REQUEST
            };
            (code, e)
        })
}

pub async fn move_out_resident(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::MoveOutResidentRequest>,
) -> Result<Json<crate::models::OccupancyHistoryItem>, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .move_out_resident(&site_id, &id, payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn move_in_resident(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::MoveInResidentRequest>,
) -> Result<Json<crate::models::OccupancyHistoryItem>, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .move_in_resident(&site_id, &id, payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_unit_occupancy_history(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<crate::models::OccupancyHistoryItem>>, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .get_unit_occupancy_history(&site_id, &id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_house_types(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<crate::models::HouseTypeTariff>> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    Json(service.get_house_types_for_site(&site_id).await)
}

pub async fn create_house_type(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::CreateHouseTypeRequest>,
) -> Result<(StatusCode, Json<crate::models::HouseTypeTariff>), (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .create_or_update_house_type(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn delete_house_type(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .delete_house_type(&site_id, &id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_blocks(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<crate::models::BlockDto>> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    Json(service.get_blocks_for_site(&site_id).await)
}

pub async fn create_block(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::CreateBlockRequest>,
) -> Result<(StatusCode, Json<crate::models::BlockDto>), (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .create_or_update_block(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

// 5. Registration Approval Handlers
pub async fn generate_registration_link(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<SiteInvitationLinkResponse> {
    let site_id = q.site_id.unwrap_or_default();
    let service = RegistrationApprovalService::new(state);
    Json(service.generate_invitation_link(&site_id).await)
}

pub async fn submit_self_registration(
    Path(slug): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<SubmitSelfRegistrationRequest>,
) -> Result<(StatusCode, Json<PendingRegistrationResponse>), (StatusCode, String)> {
    let service = RegistrationApprovalService::new(state);
    service
        .submit_self_registration(&slug, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_pending_registrations(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<PendingRegistrationResponse>> {
    let site_id = q.site_id.unwrap_or_default();
    let service = RegistrationApprovalService::new(state);
    Json(service.get_pending_registrations(&site_id).await)
}

pub async fn approve_registration(
    Path(request_id): Path<String>,
    State(state): State<AppState>,
    claims: Option<axum::Extension<crate::auth::Claims>>,
) -> Result<Json<ApprovalResultResponse>, (StatusCode, String)> {
    if let Some(axum::Extension(ref c)) = claims {
        if !c.is_saas_admin() {
            let inner = state.inner.read().await;
            if let Some(r) = inner.pending_registrations.iter().find(|r| r.request_id == request_id) {
                if !crate::auth::same_id(&r.site_id, &c.site_id) {
                    return Err((StatusCode::FORBIDDEN, "Registration application belongs to another site".to_string()));
                }
            }
        }
    }
    let service = RegistrationApprovalService::new(state);
    service
        .approve_registration(&request_id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn reject_registration(
    Path(request_id): Path<String>,
    State(state): State<AppState>,
    claims: Option<axum::Extension<crate::auth::Claims>>,
) -> Result<Json<PendingRegistrationResponse>, (StatusCode, String)> {
    if let Some(axum::Extension(ref c)) = claims {
        if !c.is_saas_admin() {
            let inner = state.inner.read().await;
            if let Some(r) = inner.pending_registrations.iter().find(|r| r.request_id == request_id) {
                if !crate::auth::same_id(&r.site_id, &c.site_id) {
                    return Err((StatusCode::FORBIDDEN, "Registration application belongs to another site".to_string()));
                }
            }
        }
    }
    let service = RegistrationApprovalService::new(state);
    service
        .reject_registration(&request_id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

// 6. Unit Co-Resident Invitation Handlers
pub async fn generate_unit_invite_link(
    Path(unit_id): Path<String>,
    State(state): State<AppState>,
) -> Json<UnitInviteLinkResponse> {
    let service = HomeResidentInvitationService::new(state);
    Json(service.generate_unit_invite_link(&unit_id, None).await)
}

pub async fn register_home_resident(
    State(state): State<AppState>,
    Json(payload): Json<RegisterHomeResidentRequest>,
) -> Result<(StatusCode, Json<HomeResidentResponse>), (StatusCode, String)> {
    let service = HomeResidentInvitationService::new(state);
    service
        .register_home_resident(payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_unit_members(
    Path(unit_id): Path<String>,
    State(state): State<AppState>,
) -> Json<Vec<UnitMemberDto>> {
    let service = HomeResidentInvitationService::new(state);
    Json(service.get_unit_members(&unit_id).await)
}

pub async fn add_unit_member(
    State(state): State<AppState>,
    Path(unit_id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::AddUnitMemberRequest>,
) -> Result<(StatusCode, Json<UnitMemberDto>), (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    let relationship = payload.relationship.unwrap_or_else(|| "Ev Sakini".to_string());
    service
        .add_unit_member(
            &site_id,
            &unit_id,
            &payload.full_name,
            &payload.phone,
            &payload.email,
            &relationship,
        )
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn delete_unit_member(
    State(state): State<AppState>,
    Path((unit_id, resident_id)): Path<(String, String)>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .delete_unit_member(&site_id, &unit_id, &resident_id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

#[derive(Debug, serde::Deserialize)]
pub struct UpdateUnitMemberRequest {
    pub full_name: String,
    pub phone: String,
    pub email: String,
    #[serde(default)]
    pub relationship: Option<String>,
}

pub async fn update_unit_member(
    State(state): State<AppState>,
    Path((unit_id, resident_id)): Path<(String, String)>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<UpdateUnitMemberRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    let relationship = payload.relationship.unwrap_or_else(|| "Ev Sakini".to_string());
    service
        .update_unit_member(
            &site_id,
            &unit_id,
            &resident_id,
            &payload.full_name,
            &payload.phone,
            &payload.email,
            &relationship,
        )
        .await
        .map(|_| StatusCode::OK)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

// 7. Health Check
pub async fn health_check() -> impl IntoResponse {
    (
        StatusCode::OK,
        Json(json!({
            "status": "UP",
            "service": "SitePulse Rust Backend",
            "version": "1.0.0",
            "engine": "Axum / Tokio",
        })),
    )
}

// 8. Bank Statement Ingestion & Automated Reconciliation Handlers (STORY-07-02)
pub async fn parse_bank_statement(
    State(state): State<AppState>,
    Json(payload): Json<ParseBankStatementRequest>,
) -> Result<(StatusCode, Json<ParseBankStatementResponse>), (StatusCode, String)> {
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
            let is_mt940 = trimmed.starts_with(":20:") || (trimmed.contains(":61:") && trimmed.contains(":86:"));
            if bank_fmt == BankStatementFormat::Mt940 && !is_mt940 {
                return Err((
                    StatusCode::BAD_REQUEST,
                    format!(
                        "File format mismatch: Bank '{}' requires SWIFT MT940 format (with :20:, :61:, :86: tags), but uploaded file is tabular/CSV.",
                        account.bank_name
                    ),
                ));
            } else if (bank_fmt == BankStatementFormat::Excel || bank_fmt == BankStatementFormat::Csv) && is_mt940 {
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

    let txns = parser
        .parse_statement(&payload.content, effective_format)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))?;

    let today = Utc::now().date_naive();
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

    let matches = recon_service.reconcile_transactions_with_site(Some(&payload.site_id), &txns, &site_units, &site_users, &site_dues, today);

    // Append to reconciliation queue in state
    for m in &matches {
        inner.reconciliation_queue.push(m.clone());
    }
    drop(inner);

    if let Some(ref pool) = state.pool {
        let site_bank_id = active_account.as_ref().and_then(|a| crate::db::parse_id_to_i64(&a.id));
        for m in &matches {
            crate::db::save_reconciliation_match_for_site(pool, m, &payload.site_id, site_bank_id).await.map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, format!("Database write failed: {}", e)))?;
        }
    }

    let matched_count = matches.iter().filter(|m| m.status == ReconciliationStatus::PendingApproval).count();
    let already_processed_count = matches.iter().filter(|m| m.status == ReconciliationStatus::AlreadyProcessed).count();
    let unmatched_count = matches.iter().filter(|m| m.status == ReconciliationStatus::Unmatched).count();

    Ok((
        StatusCode::OK,
        Json(ParseBankStatementResponse {
            site_id: payload.site_id,
            total_transactions: matches.len(),
            matched_count,
            unmatched_count,
            already_processed_count,
            matches,
        }),
    ))
}

pub async fn get_reconciliation_queue(
    State(state): State<AppState>,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Json<Vec<ReconciliationMatch>> {
    let inner = state.inner.read().await;
    let site_id = params.get("site_id").or_else(|| params.get("siteId"));
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
    Json(payload): Json<ConfirmReconciliationRequest>,
) -> Result<(StatusCode, Json<ConfirmReconciliationResponse>), (StatusCode, String)> {
    // Phase 1 (state lock): tenant boundary and the lines to settle.
    struct Line {
        match_id: String,
        unit: crate::models::IndependentUnit,
        payer_role: String,
        payer_name: String,
        request_designation: Option<crate::models::PaymentDesignation>,
        item: ReconciliationMatch,
    }
    let lines: Vec<Line> = {
        let inner = state.inner.read().await;
        for match_id in &payload.match_ids {
            if let Some(m) = inner.reconciliation_queue.iter().find(|m| m.match_id == *match_id) {
                if !crate::auth::same_id(&m.site_id, &payload.site_id) {
                    return Err((
                        StatusCode::FORBIDDEN,
                        format!("Match {} belongs to site {}, not {}", match_id, m.site_id, payload.site_id),
                    ));
                }
            }
        }
        let mut lines = Vec::new();
        for match_id in &payload.match_ids {
            let Some(m) = inner.reconciliation_queue.iter().find(|m| m.match_id == *match_id) else { continue };
            let Some(unit) = m.matched_unit_id.as_ref().and_then(|uid| inner.units.iter().find(|u| &u.id == uid)).cloned() else {
                continue;
            };
            let (payer_role, payer_name) = resolve_payer(&inner, &unit, m.transaction.sender_name.as_deref());
            let request_designation = m.matched_due_id.clone().map(|due_id| crate::models::PaymentDesignation {
                due_ids: vec![due_id],
                ..Default::default()
            });
            lines.push(Line { match_id: match_id.clone(), unit, payer_role, payer_name, request_designation, item: m.clone() });
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
        let key = if txn.transaction_id.trim().is_empty() { line.match_id.clone() } else { txn.transaction_id.clone() };
        let result = service
            .record_and_allocate_payment(crate::models::RecordManualPaymentRequest {
                site_id: Some(line.unit.site_id.clone()),
                unit_id: line.unit.id.clone(),
                amount: txn.amount,
                payer_name: line.payer_name.clone(),
                payer_role: line.payer_role.clone(),
                payment_channel: "BANK_STATEMENT".to_string(),
                description: Some(txn.description.clone()),
                payment_date: None,
                idempotency_key: Some(format!("STMT:{}", key)),
                designation: line.request_designation.clone(),
                external_reference: txn.reference_no.clone().or_else(|| Some(key.clone())),
                designate_from_description: true,
                settles_unmatched_entry_id: None,
            })
            .await;
        match result {
            Ok(receipt) => confirmed.push((line, receipt)),
            Err(e) => {
                let (code, msg) = payment_error_status(e);
                failure = Some((code, format!("Statement line {} was not settled: {}", line.match_id, msg)));
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
        if let Some(m) = inner.reconciliation_queue.iter_mut().find(|m| m.match_id == line.match_id) {
            m.status = ReconciliationStatus::Approved;
            m.status_code = ReconciliationStatus::Approved.as_str().to_string();
            m.notes = Some(format!(
                "Makbuz {}: ₺{:.2} borca, ₺{:.2} avansa işlendi",
                receipt.receipt_number,
                receipt.allocated_principal + receipt.allocated_penalty,
                receipt.allocated_advance
            ));
            confirmed_matches.push(m.clone());
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
        inner.remembered_sender_ibans.insert(iban.clone(), unit_id.clone());
    }
    let confirmed_count = confirmed_matches.len();

    if let Some(ref pool) = state.pool {
        for m in &confirmed_matches {
            crate::db::update_reconciliation_status(pool, &m.match_id, ReconciliationStatus::Approved, m.notes.as_deref())
                .await
                .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, format!("Database write failed: {}", e)))?;
        }
        for (uid, iban) in &remembered {
            crate::db::save_remembered_sender_iban(pool, uid, iban, None, None)
                .await
                .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, format!("Database write failed: {}", e)))?;
        }
    }
    drop(inner);
    if let Some((code, msg)) = failure {
        // Lines before the failing one are settled and recorded; retrying the
        // whole batch is safe (each line is idempotent).
        return Err((code, format!("{} ({} line(s) settled before the failure)", msg, confirmed_count)));
    }

    let message_sent = payload.optional_message.as_ref().map(|msg| !msg.trim().is_empty()).unwrap_or(false);
    let notification_summary = if message_sent {
        Some(format!("{} ev sahibine/kat sakinine bilgilendirme mesajı iletildi.", confirmed_count))
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
    Json(payload): Json<RememberSenderIbanRequest>,
) -> Result<Json<RememberSenderIbanResponse>, (StatusCode, String)> {
    let mut inner = state.inner.write().await;
    let clean = payload.sender_iban.replace(' ', "").to_uppercase();
    if clean.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "Sender IBAN cannot be empty.".to_string()));
    }
    if !inner.units.iter().any(|u| u.id == payload.unit_id) {
        return Err((StatusCode::NOT_FOUND, format!("Unit '{}' not found in this site.", payload.unit_id)));
    }

    inner.remembered_sender_ibans.insert(clean.clone(), payload.unit_id.clone());
    if let Some(ref sender_name) = payload.sender_name {
        inner.sender_iban_metadata.insert(clean.clone(), (Some(sender_name.clone()), None));
    }

    if let Some(ref pool) = state.pool {
        crate::db::save_remembered_sender_iban(pool, &payload.unit_id, &clean, payload.sender_name.as_deref(), None).await.map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, format!("Database write failed: {}", e)))?;
    }

    Ok(Json(RememberSenderIbanResponse {
        success: true,
        unit_id: payload.unit_id,
        sender_iban: clean,
        message: "Sender IBAN successfully mapped and remembered for automated future matching.".to_string(),
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
        .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Unit '{}' not found", unit_id)))?;

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

    let recommended_desc = format!("{} Blok D:{}", unit.block_id, unit.unit_number);

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
        return Err((StatusCode::BAD_REQUEST, "Geçersiz IBAN formatı (minimum 15 karakter).".to_string()));
    }

    {
        let mut inner = state.inner.write().await;
        if !inner.units.iter().any(|u| u.id == unit_id) {
            return Err((StatusCode::NOT_FOUND, format!("Unit '{}' not found", unit_id)));
        }

        inner.remembered_sender_ibans.insert(clean.clone(), unit_id.clone());
        inner.sender_iban_metadata.insert(clean.clone(), (payload.label.clone(), payload.bank_name.clone()));
    }

    if let Some(ref pool) = state.pool {
        crate::db::save_remembered_sender_iban(pool, &unit_id, &clean, payload.label.as_deref(), payload.bank_name.as_deref()).await.map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, format!("Database write failed: {}", e)))?;
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
        crate::db::delete_remembered_sender_iban(pool, &clean).await.map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, format!("Database write failed: {}", e)))?;
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
            return Err((StatusCode::NOT_FOUND, format!("Unit '{}' not found", unit_id)));
        }

        inner.unit_payer_names.insert(unit_id.clone(), cleaned_names.clone());
    }

    if let Some(ref pool) = state.pool {
        crate::db::save_unit_payer_names(pool, &unit_id, &cleaned_names).await.map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, format!("Database write failed: {}", e)))?;
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
        .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Unit '{}' not found", unit_id)))?;

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
    );
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
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

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
    let signature = headers.get(BANK_WEBHOOK_SIGNATURE_HEADER).and_then(|v| v.to_str().ok());
    if !crate::auth::verify_webhook_signature(&body, signature) {
        return Err((StatusCode::UNAUTHORIZED, "Invalid or missing webhook signature".to_string()));
    }
    let payload: BankIncomingWebhookRequest = serde_json::from_slice(&body)
        .map_err(|e| (StatusCode::BAD_REQUEST, format!("Invalid webhook payload: {}", e)))?;
    validate_bank_webhook(&payload)?;

    // Durable idempotency (O-3): the transaction id is claimed in PostgreSQL,
    // scoped by the receiving bank account (or site), before any state changes,
    // so a replay (even after a restart) is never applied twice. A transaction id
    // reused with different content is rejected rather than silently ignored.
    let mut claim_id: Option<i64> = None;
    let mut account_scope: Option<i64> = None;
    if let Some(ref pool) = state.pool {
        let unavailable = |e: Box<dyn std::error::Error + Send + Sync>| {
            (StatusCode::SERVICE_UNAVAILABLE, format!("Could not record webhook: {}", e))
        };
        let destination = payload.virtual_iban.replace(' ', "").to_uppercase();
        let scope = crate::db::resolve_webhook_scope(pool, &destination).await.map_err(unavailable)?;
        account_scope = scope.site_bank_account_id;
        match crate::db::claim_bank_webhook_transaction(pool, &scope, &payload.transaction_id, &webhook_payload_hash(&payload))
            .await
            .map_err(unavailable)?
        {
            crate::db::WebhookClaim::Claimed(id) => claim_id = Some(id),
            crate::db::WebhookClaim::Duplicate { same_payload: false, .. } => {
                return Err((
                    StatusCode::CONFLICT,
                    format!("transaction_id {} was already delivered with different content", payload.transaction_id),
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
                    inner.payment_receipts.iter().find(|r| r.receipt_number == resp.receipt_id && r.site_id == resp_site(&inner, resp)).map(|r| r.id)
                };
                if let Some(rid) = receipt {
                    if let Err(e) = crate::db::attach_bank_webhook_receipt(pool, id, rid).await {
                        tracing::error!("Could not link webhook claim {} to receipt {}: {}", id, rid, e);
                    }
                }
            }
            Ok(_) => {}
        }
    }
    result
}

/// Site of the unit a cleared webhook settled.
fn resp_site(inner: &crate::state::AppStateInner, resp: &BankIncomingWebhookResponse) -> String {
    inner.units.iter().find(|u| u.id == resp.matched_unit_id).map(|u| u.site_id.clone()).unwrap_or_default()
}

/// SHA-256 over the fields that define a bank transfer, so a redelivery can be
/// told apart from a transaction id reused for a different transfer.
pub fn webhook_payload_hash(payload: &BankIncomingWebhookRequest) -> String {
    use sha2::{Digest, Sha256};
    let clean = |s: Option<&str>| s.unwrap_or("").replace(' ', "").to_uppercase();
    let canonical = format!(
        "{}|{:.2}|{}|{}|{}|{}",
        payload.transaction_id.trim(),
        payload.amount,
        payload.currency.as_deref().unwrap_or("TRY").trim().to_uppercase(),
        clean(Some(&payload.virtual_iban)),
        clean(payload.sender_iban.as_deref()),
        payload.description.as_deref().unwrap_or("").trim(),
    );
    hex::encode(Sha256::digest(canonical.as_bytes()))
}

fn duplicate_webhook_response(transaction_id: String) -> BankIncomingWebhookResponse {
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
        message: "Duplicate bank transaction notification ignored. Idempotency preserved.".to_string(),
    }
}

fn validate_bank_webhook(payload: &BankIncomingWebhookRequest) -> Result<(), (StatusCode, String)> {
    if payload.transaction_id.trim().is_empty() {
        return Err((StatusCode::BAD_REQUEST, "transaction_id is required".to_string()));
    }
    if payload.amount <= Decimal::ZERO || payload.amount.scale() > 2 {
        return Err((StatusCode::BAD_REQUEST, "amount must be positive with at most 2 decimals".to_string()));
    }
    match payload.currency.as_deref().map(|c| c.trim().to_uppercase()) {
        None => Ok(()),
        Some(c) if c == "TRY" => Ok(()),
        Some(c) => Err((StatusCode::UNPROCESSABLE_ENTITY, format!("Unsupported currency '{}'; only TRY is accepted", c))),
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
async fn process_bank_incoming_webhook_scoped(
    state: AppState,
    payload: BankIncomingWebhookRequest,
    account_scope: Option<i64>,
) -> Result<(StatusCode, Json<BankIncomingWebhookResponse>), (StatusCode, String)> {
    let clean_viban = payload.virtual_iban.replace(' ', "").to_uppercase();
    let mut inner = state.inner.write().await;

    // Any earlier delivery of this transaction id (matched or not) to the same
    // site is a duplicate (transaction ids are unique per bank, not globally).
    let destination_site = inner
        .units
        .iter()
        .find(|u| u.virtual_iban.as_ref().map(|v| v.replace(' ', "").to_uppercase() == clean_viban).unwrap_or(false))
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
            && destination_site.as_deref().map(|s| crate::auth::same_id(s, &m.site_id)).unwrap_or(true)
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
                let clean_blk = blk.to_uppercase().replace("BLOK", "").replace("BLOCK", "").replace(['-', '_', ' '], "");
                unit_index = inner.units.iter().position(|u| {
                    let u_blk = u.block_id.to_uppercase().replace("BLOK", "").replace("BLOCK", "").replace(['-', '_', ' '], "");
                    (u_blk == clean_blk || u.block_id.eq_ignore_ascii_case(blk)) && u.unit_number == unit_no
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
                        if user.full_name.to_lowercase().contains(&sender_lower) || sender_lower.contains(&user.full_name.to_lowercase()) {
                            unit_index = inner.units.iter().position(|u| u.owner_user_id.as_deref() == Some(&user.id));
                            if unit_index.is_some() {
                                match_mechanism = "Regular IBAN & Sender Name Matching (Gönderen İsim Eşleşmesi)";
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
                        format!("Destination IBAN {} is not a site account or a unit's virtual IBAN", payload.virtual_iban),
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
                    date: Utc::now().date_naive(),
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
            if let Some(ref pool) = state.pool {
                crate::db::save_reconciliation_match_for_site(pool, &unmatched, &unmatched.site_id, bank_account_id.or(account_scope))
                    .await
                    .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, format!("Database write failed: {}", e)))?;
            }
            inner.reconciliation_queue.push(unmatched);

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

    // 2. Settle through the canonical ingestion path (SPEC-005 R1): TAH- receipt,
    // allocation rows, penalty-first waterfall, idempotent on the bank transaction.
    let (payer_role, payer_name) = resolve_payer(&inner, &unit, payload.sender_name.as_deref());
    let matched_resident_name = unit
        .owner_user_id
        .as_ref()
        .and_then(|uid| inner.users.iter().find(|u| &u.id == uid))
        .map(|u| u.full_name.clone());
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
            payment_channel: if is_virtual_iban { "VIRTUAL_IBAN" } else { "BANK_TRANSFER" }.to_string(),
            description: Some(txn_desc.clone()),
            payment_date: None,
            idempotency_key: Some(match account_scope {
                Some(account) => format!("BANK:{}:{}", account, payload.transaction_id),
                None => format!("BANK:{}", payload.transaction_id),
            }),
            designation: None,
            external_reference: Some(payload.transaction_id.clone()),
            designate_from_description: true,
            settles_unmatched_entry_id: None,
        })
        .await
        .map_err(payment_error_status)?;

    let mut inner = state.inner.write().await;
    let cleared_amount = receipt.allocated_principal + receipt.allocated_penalty;
    let cleared_period = receipt.allocation_breakdown.first().map(|b| b.period.clone());
    let surplus = receipt.allocated_advance;
    let total_advance = inner.advance_total(&unit.id);
    let remaining_debt: Decimal = inner
        .dues
        .iter()
        .filter(|d| d.unit_id == unit.id && d.status != DebtStatus::Paid)
        .map(|d| d.total_amount)
        .sum();

    let unit_block_desc = if unit.block_id.contains("Blok") {
        unit.block_id.clone()
    } else {
        format!("{} Blok", unit.block_id)
    };

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
            format!("{} aidatı ödendi • ₺{} avans bakiyenize aktarıldı", period, surplus_str)
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
            date: Utc::now().date_naive(),
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
        matched_due_id: receipt.allocation_breakdown.first().and_then(|b| b.due_id.clone()),
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

/// Who paid, for an incoming transfer: the unit's tenant when the sender name
/// matches the tenant account, otherwise the owner (who may settle any of the
/// unit's liabilities). Returns `(payer_role, payer_name)`.
fn resolve_payer(
    inner: &crate::state::AppStateInner,
    unit: &crate::models::IndependentUnit,
    sender_name: Option<&str>,
) -> (String, String) {
    let name_of = |uid: &Option<String>| {
        uid.as_ref().and_then(|id| inner.users.iter().find(|u| &u.id == id)).map(|u| u.full_name.clone())
    };
    let sender = sender_name.map(str::trim).filter(|s| !s.is_empty());
    if let (Some(sender), Some(tenant)) = (sender, name_of(&unit.tenant_user_id)) {
        let (a, b) = (crate::services::dues_ledger::fold_turkish(sender), crate::services::dues_ledger::fold_turkish(&tenant));
        if a.contains(&b) || b.contains(&a) {
            return ("TENANT".to_string(), sender.to_string());
        }
    }
    let name = sender
        .map(str::to_string)
        .or_else(|| name_of(&unit.owner_user_id))
        .unwrap_or_else(|| "Bilinmeyen Gönderen".to_string());
    ("OWNER".to_string(), name)
}

/// HTTP status for a canonical-ingestion failure: storage problems are 503 (the
/// caller may retry; the payment is idempotent), anything else is a bad request.
fn payment_error_status(e: String) -> (StatusCode, String) {
    if e.starts_with("Database unavailable") || e.starts_with("Payment was not recorded") || e.starts_with("Reversal was not recorded") {
        (StatusCode::SERVICE_UNAVAILABLE, e)
    } else {
        (StatusCode::BAD_REQUEST, e)
    }
}

#[derive(Debug, Deserialize)]
pub struct DuesPeriodsQuery {
    pub site_id: Option<String>,
}

/// Returns the defined billing periods for a site from the separate dues_periods table
pub async fn list_dues_periods(
    State(state): State<AppState>,
    Query(query): Query<DuesPeriodsQuery>,
) -> Result<Json<Vec<DuesPeriod>>, (StatusCode, String)> {
    let inner = state.inner.read().await;
    let site_id = query.site_id.unwrap_or_else(|| "site-begonya".to_string());
    let periods: Vec<DuesPeriod> = inner
        .dues_periods
        .iter()
        .filter(|p| p.site_id == site_id || crate::db::parse_id_to_i64(&p.site_id) == crate::db::parse_id_to_i64(&site_id))
        .cloned()
        .collect();
    Ok(Json(periods))
}

/// Creates a new billing period for a site in the dues_periods table
pub async fn create_dues_period(
    State(state): State<AppState>,
    Json(payload): Json<CreateDuesPeriodRequest>,
) -> Result<(StatusCode, Json<DuesPeriod>), (StatusCode, String)> {
    let mut inner = state.inner.write().await;

    // Check if period already exists
    if let Some(existing) = inner.dues_periods.iter().find(|p| {
        (p.site_id == payload.site_id || crate::db::parse_id_to_i64(&p.site_id) == crate::db::parse_id_to_i64(&payload.site_id))
            && p.period_name.eq_ignore_ascii_case(&payload.period_name)
    }) {
        return Ok((StatusCode::OK, Json(existing.clone())));
    }

    let max_p = inner.dues_periods.iter().filter_map(|p| crate::db::parse_id_to_i64(&p.id)).max().unwrap_or(0);
    let new_period = DuesPeriod {
        id: (max_p + 1).to_string(),
        site_id: payload.site_id.clone(),
        period_name: payload.period_name.clone(),
        due_date: payload.due_date,
        status: "ACTIVE".to_string(),
        created_at: Some(chrono::Utc::now()),
    };

    inner.dues_periods.push(new_period.clone());

    if let Some(ref pool) = state.pool {
        crate::db::save_dues_period(pool, &new_period).await.map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, format!("Database write failed: {}", e)))?;
    }

    Ok((StatusCode::CREATED, Json(new_period)))
}

// Periodic Dues Accrual & Automatic Advance Balance Offsetting
pub async fn accrue_monthly_dues(
    State(state): State<AppState>,
    Json(payload): Json<AccrueDuesPeriodRequest>,
) -> Result<(StatusCode, Json<AccrueDuesPeriodResponse>), (StatusCode, String)> {
    let mut inner = state.inner.write().await;
    let ledger_before = ledger_snapshot(&inner);
    let units_in_site: Vec<IndependentUnit> = inner
        .units
        .iter()
        .filter(|u| u.site_id == payload.site_id)
        .cloned()
        .collect();

    if units_in_site.is_empty() {
        return Err((
            StatusCode::NOT_FOUND,
            format!("No units found for site '{}'", payload.site_id),
        ));
    }

    let total_units_in_site = units_in_site.len();

    // Ensure period is stored in the separate dues_periods table
    let period_exists = inner.dues_periods.iter().any(|p| {
        (p.site_id == payload.site_id || crate::db::parse_id_to_i64(&p.site_id) == crate::db::parse_id_to_i64(&payload.site_id))
            && p.period_name.eq_ignore_ascii_case(&payload.period)
    });
    if !period_exists {
        let max_p = inner.dues_periods.iter().filter_map(|p| crate::db::parse_id_to_i64(&p.id)).max().unwrap_or(0);
        let period_record = DuesPeriod {
            id: (max_p + 1).to_string(),
            site_id: payload.site_id.clone(),
            period_name: payload.period.clone(),
            due_date: payload.due_date,
            status: "ACTIVE".to_string(),
            created_at: Some(chrono::Utc::now()),
        };
        inner.dues_periods.push(period_record.clone());
        if let Some(ref pool) = state.pool {
            crate::db::save_dues_period(pool, &period_record).await.map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, format!("Database write failed: {}", e)))?;
        }
    }

    // Invariant Guard: Prevent duplicate accrual for already-accrued units
    let mut newly_accrued_units_count = 0;
    let mut total_amount_accrued = Decimal::ZERO;

    for unit in &units_in_site {
        let already_exists = inner
            .dues
            .iter()
            .any(|d| d.unit_id == unit.id && d.period == payload.period);
        if !already_exists {
            let effective_amount = if payload.amount > Decimal::ZERO {
                payload.amount
            } else {
                let unit_house_type = unit.house_type.as_deref().unwrap_or("2+1");
                inner
                    .house_types
                    .iter()
                    .find(|ht| {
                        (ht.site_id == payload.site_id || crate::db::parse_id_to_i64(&ht.site_id) == crate::db::parse_id_to_i64(&payload.site_id))
                            && ht.type_name.eq_ignore_ascii_case(unit_house_type)
                    })
                    .map(|ht| ht.dues_amount)
                    .unwrap_or(Decimal::new(1400, 0))
            };

            let max_d = inner.dues.iter().filter_map(|d| crate::db::parse_id_to_i64(&d.id)).max().unwrap_or(0);
            let due_id = (max_d + 1).to_string();
            inner.dues.push(DuesLiability {
                id: due_id,
                unit_id: unit.id.clone(),
                period: payload.period.clone(),
                principal_amount: effective_amount,
                delay_penalty: Decimal::ZERO,
                total_amount: effective_amount,
                due_date: payload.due_date,
                status: DebtStatus::Pending,
                paid_principal: Decimal::ZERO,
                paid_penalty: Decimal::ZERO,
                // Operational dues are the occupant's: the tenant's when the unit is
                // let, otherwise the owner's (same rule as the scheduler).
                debtor_type: if unit.tenant_user_id.is_some() { "TENANT" } else { "OWNER" }.to_string(),
                expense_type: "OPERATIONAL_DUES".to_string(),
                penalty_accrued_through: None,
            });
            total_amount_accrued += effective_amount;
            newly_accrued_units_count += 1;
        }
    }

    if let Some(ref pool) = state.pool {
        let dues_to_save: Vec<DuesLiability> = inner
            .dues
            .iter()
            .filter(|d| d.period == payload.period)
            .cloned()
            .collect();
        for due in &dues_to_save {
            crate::db::save_due_liability(pool, due).await.map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, format!("Database write failed: {}", e)))?;
        }
    }

    if newly_accrued_units_count == 0 {
        return Ok((
            StatusCode::OK,
            Json(AccrueDuesPeriodResponse {
                site_id: payload.site_id,
                period: payload.period.clone(),
                total_units_accrued: total_units_in_site,
                newly_accrued_units_count: 0,
                auto_settled_units_count: 0,
                total_amount_accrued: Decimal::ZERO,
                total_amount_offset_from_advance: Decimal::ZERO,
                already_accrued: true,
                message: format!(
                    "'{}' dönemi için aidat tahakkuku bu sitede daha önce yapılmış. Mükerrer tahakkuk engellendi.",
                    payload.period
                ),
            }),
        ));
    }

    // Automatically apply available advance payments against newly accrued dues!
    let (auto_settled_count, total_offset) = apply_advance_payments_offset(&mut inner, None);
    if let Some(ref pool) = state.pool {
        persist_ledger_changes(pool, &ledger_before, &inner)
            .await
            .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, e))?;
    }

    Ok((
        StatusCode::OK,
        Json(AccrueDuesPeriodResponse {
            site_id: payload.site_id,
            period: payload.period.clone(),
            total_units_accrued: total_units_in_site,
            newly_accrued_units_count,
            auto_settled_units_count: auto_settled_count,
            total_amount_accrued,
            total_amount_offset_from_advance: total_offset,
            already_accrued: false,
            message: format!(
                "'{}' dönemi için {} daireye başarıyla aidat tahakkuk ettirildi. {} daire avanstan otomatik kapatıldı.",
                payload.period, newly_accrued_units_count, auto_settled_count
            ),
        }),
    ))
}

/// Records a payment sent/recorded by a homeowner inside the application.
/// Matches against outstanding debts first (FIFO by due_date).
/// If no debt exists (or if payment > debt), credits the remainder to advance_payments (Avans Bakiye).
pub async fn record_homeowner_payment(
    State(state): State<AppState>,
    Json(payload): Json<RecordHomeownerPaymentRequest>,
) -> Result<(StatusCode, Json<RecordHomeownerPaymentResponse>), (StatusCode, String)> {
    let (unit, owner_name) = {
        let inner = state.inner.read().await;
        let unit = inner
            .units
            .iter()
            .find(|u| u.id == payload.unit_id)
            .cloned()
            .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Unit '{}' not found.", payload.unit_id)))?;
        let owner_name = unit
            .owner_user_id
            .as_ref()
            .and_then(|uid| inner.users.iter().find(|u| &u.id == uid).map(|u| u.full_name.clone()));
        (unit, owner_name)
    };
    let payer_name = payload
        .homeowner_name
        .clone()
        .filter(|n| !n.trim().is_empty())
        .or(owner_name)
        .unwrap_or_else(|| "Kat Maliki".to_string());
    let reference = payload.reference_code.clone().filter(|r| !r.trim().is_empty());

    // Canonical ingestion (SPEC-005 R1). Recorded by site staff on behalf of the owner.
    let receipt = crate::services::PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(crate::models::RecordManualPaymentRequest {
            site_id: Some(unit.site_id.clone()),
            unit_id: unit.id.clone(),
            amount: payload.amount,
            payer_name: payer_name.clone(),
            payer_role: "OWNER".to_string(),
            payment_channel: payload.payment_method.clone(),
            description: payload.note.clone(),
            payment_date: None,
            idempotency_key: reference.as_ref().map(|r| format!("HOP:{}", r)),
            designation: None,
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

    let mut inner = state.inner.write().await;
    let total_unit_advance = inner.advance_total(&unit.id);
    let remaining_debt: Decimal = inner
        .dues
        .iter()
        .filter(|d| d.unit_id == unit.id && d.status != DebtStatus::Paid)
        .map(|d| d.total_amount)
        .sum();
    let message = if cleared_debt > Decimal::ZERO && advance_credit > Decimal::ZERO {
        format!(
            "₺{} aidat borcu ödendi, kalan ₺{} avans bakiyesine aktarıldı (Mevcut Avans: ₺{}). Makbuz {}.",
            cleared_debt, advance_credit, total_unit_advance, receipt.receipt_number
        )
    } else if cleared_debt > Decimal::ZERO {
        format!("₺{} tutarındaki aidat borcu başarıyla kapatıldı. Makbuz {}.", cleared_debt, receipt.receipt_number)
    } else {
        format!(
            "Aktif aidat borcu bulunmuyor. ₺{} tutarındaki ödeme avans bakiyenize eklendi (Mevcut Avans: ₺{}). Makbuz {}.",
            advance_credit, total_unit_advance, receipt.receipt_number
        )
    };

    // Approved digital receipt line for the site payment views.
    let is_card = receipt.payment_channel == "CREDIT_CARD";
    let match_seq = inner.reconciliation_queue.len() + 1;
    let r_match = ReconciliationMatch {
        match_id: format!("MATCH-{}", match_seq),
        site_id: unit.site_id.clone(),
        transaction: BankTransactionItem {
            transaction_id: reference.clone().unwrap_or_else(|| receipt.receipt_number.clone()),
            date: Utc::now().date_naive(),
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
        matched_due_id: receipt.allocation_breakdown.first().and_then(|b| b.due_id.clone()),
        outstanding_balance: Some(cleared_debt),
        amount_matches_balance: cleared_debt == payload.amount,
        status: ReconciliationStatus::Approved,
        status_code: ReconciliationStatus::Approved.as_str().to_string(),
        notes: Some(message.clone()),
    };
    if let Some(ref pool) = state.pool {
        crate::db::save_reconciliation_match(pool, &r_match)
            .await
            .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, format!("Database write failed: {}", e)))?;
    }
    inner.reconciliation_queue.push(r_match);

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
    Json(payload): Json<MatchAllPaymentsRequest>,
) -> Result<(StatusCode, Json<MatchAllPaymentsResponse>), (StatusCode, String)> {
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
        let receipt = service
            .record_and_allocate_payment(crate::models::RecordManualPaymentRequest {
                site_id: Some(site_id),
                unit_id: record.unit_id.clone(),
                amount: record.amount,
                payer_name: record.homeowner_name.clone().unwrap_or_else(|| "Kat Maliki".to_string()),
                payer_role: "OWNER".to_string(),
                payment_channel: record.payment_method.clone(),
                description: record.note.clone(),
                payment_date: None,
                idempotency_key: Some(format!("HOP:{}", record.id)),
                designation: None,
                external_reference: record.reference_code.clone(),
                designate_from_description: true,
                settles_unmatched_entry_id: Some(record.id.clone()),
            })
            .await
            .map_err(|e| {
                let (code, msg) = payment_error_status(e);
                (code, format!("Payment {} was not matched: {} ({} matched before it)", record.id, msg, total_processed))
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

/// Returns the list of homeowner payment records
pub async fn get_homeowner_payments(
    State(state): State<AppState>,
) -> impl IntoResponse {
    let inner = state.inner.read().await;
    (StatusCode::OK, Json(inner.homeowner_payments.clone()))
}

/// Resets all payments, advance balances, reconciliation items, and dues back to a 100% clean state (₺0.00 debt, 0 transactions)
pub async fn reset_demo_data(
    State(state): State<AppState>,
) -> impl IntoResponse {
    if crate::state::AppStateInner::is_production() {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "status": "ERROR",
                "message": "Demo veri sıfırlama işlemi canlı (production) ortamında güvenlik nedeniyle engellenmiştir."
            })),
        );
    }
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::reset_db_to_seed_data(pool).await { tracing::error!("Database write failed: {}", e); }
    }
    let mut inner = state.inner.write().await;
    inner.reset_all_payments_and_balances();
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::load_all_from_db(pool, &mut inner).await {
            tracing::error!("Reloading state from PostgreSQL failed: {}", e);
        }
    }
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "status": "SUCCESS",
            "message": "Tüm ödeme, borç, avans ve hesap hareketleri sıfırlandı. Sistem tertemiz başlangıç durumuna (₺0,00 Borç, 0 Hareket) döndürüldü.",
            "unit_id": "d-14",
            "active_debt": "0.00",
            "advance_payment": "0.00",
            "transactions_count": 0
        })),
    )
}

/// Accrues a single test monthly due (Eylül 2026: ₺1.400,00) for d-14 to test payment clearing
pub async fn accrue_test_due(
    State(state): State<AppState>,
) -> impl IntoResponse {
    if crate::state::AppStateInner::is_production() {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "status": "ERROR",
                "message": "Test aidatı tahakkuk ettirme işlemi canlı (production) ortamında güvenlik nedeniyle engellenmiştir."
            })),
        );
    }
    let mut inner = state.inner.write().await;
    inner.accrue_test_due();
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "status": "SUCCESS",
            "message": "A Blok D:14 için Eylül 2026 Aidat Borcu (₺1.400,00) tahakkuk ettirildi.",
            "unit_id": "d-14",
            "period": "Eylül 2026",
            "active_debt": "1400.00"
        })),
    )
}

/// Explicitly loads test fixtures on demand (development/testing environments only)
pub async fn seed_test_fixtures(
    State(state): State<AppState>,
) -> impl IntoResponse {
    if crate::state::AppStateInner::is_production() {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "status": "ERROR",
                "message": "Test verisi yükleme işlemi canlı (production) ortamında güvenlik nedeniyle engellenmiştir."
            })),
        );
    }
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::seed_test_data(pool).await { tracing::error!("Database write failed: {}", e); }
        let mut inner = state.inner.write().await;
        if let Err(e) = crate::db::load_all_from_db(pool, &mut inner).await {
            tracing::error!("Reloading state from PostgreSQL failed: {}", e);
        }
    } else {
        let mut inner = state.inner.write().await;
        inner.seed_test_fixtures();
    }
    let inner = state.inner.read().await;
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "status": "SUCCESS",
            "message": "Test verileri (Begonya Sitesi, Kardelen Rezidans, test sakinleri ve daireler) başarıyla yüklendi.",
            "sites_count": inner.sites.len(),
            "users_count": inner.users.len(),
            "units_count": inner.units.len(),
            "dues_count": inner.dues.len()
        })),
    )
}

/// Clears all business data (sites, users, units, dues, transactions) leaving only system lookups
pub async fn clear_all_data(
    State(state): State<AppState>,
) -> impl IntoResponse {
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::wipe_all_db_data(pool).await { tracing::error!("Database write failed: {}", e); }
    }
    let mut inner = state.inner.write().await;
    inner.clear_all_data();
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::load_all_from_db(pool, &mut inner).await {
            tracing::error!("Reloading state from PostgreSQL failed: {}", e);
        }
    }
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "status": "SUCCESS",
            "message": "Tüm site, kullanıcı, daire, aidat ve hareket verileri temizlendi. Sistem sıfırlandı.",
            "sites_count": inner.sites.len(),
            "users_count": inner.users.len(),
            "units_count": inner.units.len(),
            "dues_count": inner.dues.len()
        })),
    )
}

/// Drops all tables, recreates schema with auto-increment BIGINT identity, and seeds fresh initial state
pub async fn recreate_db(
    State(state): State<AppState>,
) -> impl IntoResponse {
    if crate::state::AppStateInner::is_production() {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "status": "ERROR",
                "message": "Veritabanını sıfırdan oluşturma işlemi canlı ortamda güvenlik nedeniyle engellenmiştir."
            })),
        );
    }
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::recreate_db_schema_and_seed(pool).await {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({
                    "status": "ERROR",
                    "message": format!("Veritabanı sıfırlanamadı: {}", e)
                })),
            );
        }
    }
    let mut inner = state.inner.write().await;
    inner.clear_all_data();
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::load_all_from_db(pool, &mut inner).await {
            tracing::error!("Reloading state from PostgreSQL failed: {}", e);
        }
    } else {
        inner.seed_test_fixtures();
    }
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "status": "SUCCESS",
            "message": "Tüm tablolar başarıyla silindi, yeniden oluşturuldu ve başlangıç verileriyle yüklendi.",
            "sites_count": inner.sites.len(),
            "users_count": inner.users.len(),
            "units_count": inner.units.len(),
            "dues_count": inner.dues.len()
        })),
    )
}

/// Fully restores the application and database back to pristine initial seed fixtures
pub async fn reset_to_initial_state(
    State(state): State<AppState>,
) -> impl IntoResponse {
    if crate::state::AppStateInner::is_production() {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "status": "ERROR",
                "message": "Sistemi sıfırlama işlemi canlı ortamda güvenlik nedeniyle engellenmiştir."
            })),
        );
    }
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::recreate_db_schema_and_seed(pool).await {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({
                    "status": "ERROR",
                    "message": format!("Veritabanı sıfırlanamadı: {}", e)
                })),
            );
        }
    }
    let mut inner = state.inner.write().await;
    inner.clear_all_data();
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::load_all_from_db(pool, &mut inner).await {
            tracing::error!("Reloading state from PostgreSQL failed: {}", e);
        }
    } else {
        inner.seed_test_fixtures();
    }
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "status": "SUCCESS",
            "message": "Uygulama başarıyla başlangıç durumuna (Fabrika Ayarları) döndürüldü. Tüm test verileri ve geçici kayıtlar temizlendi.",
            "sites_count": inner.sites.len(),
            "users_count": inner.users.len(),
            "units_count": inner.units.len(),
            "dues_count": inner.dues.len()
        })),
    )
}

/// Completely wipes all data across the platform: all sites, units, homeowners, tenants,
/// residents, dues, transactions, and balances — yielding a 100% fresh start (Zero-Data State).
pub async fn wipe_all_data(
    State(state): State<AppState>,
) -> impl IntoResponse {
    if crate::state::AppStateInner::is_production() {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "status": "ERROR",
                "message": "Tüm verileri silme işlemi canlı ortamda güvenlik nedeniyle engellenmiştir."
            })),
        );
    }
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::wipe_all_db_data(pool).await {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({
                    "status": "ERROR",
                    "message": format!("Tüm veriler silinemedi: {}", e)
                })),
            );
        }
    }
    let mut inner = state.inner.write().await;
    inner.clear_all_data();
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::load_all_from_db(pool, &mut inner).await {
            tracing::error!("Reloading state from PostgreSQL failed: {}", e);
        }
    } else {
        inner.users.push(crate::models::User {
            id: "1".to_string(),
            site_id: "".to_string(),
            full_name: "SaaS Platform Admin".to_string(),
            email: "admin@sitepulse.io".to_string(),
            phone: "+90 850 555 0000".to_string(),
            password_hash: Some(crate::auth::hash_password(&crate::state::bootstrap_admin_password())),
            role: crate::models::Role::SaasAdmin,
            must_change_password: true,
            auth_provider: "LOCAL".to_string(),
            google_sub: None,
            avatar_url: None,
            created_at: chrono::Utc::now(),
            person_id: Some(1),
        });
    }
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "status": "SUCCESS",
            "message": "Tüm siteler, daireler, kat malikleri, kiracılar, sakinler ve aidat verileri başarıyla silindi. Sistem sıfırdan tertemiz başlangıç (Fresh Start) durumundadır.",
            "sites_count": inner.sites.len(),
            "users_count": inner.users.len(),
            "units_count": inner.units.len(),
            "dues_count": inner.dues.len()
        })),
    )
}

pub async fn sync_db(
    State(state): State<AppState>,
) -> impl IntoResponse {
    if let Some(ref pool) = state.pool {
        let inner = state.inner.read().await;
        if let Err(e) = crate::db::sync_all_in_memory_to_db(pool, &inner).await {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({
                    "status": "ERROR",
                    "message": format!("Database sync failed: {}", e)
                })),
            );
        }
        (
            StatusCode::OK,
            Json(serde_json::json!({
                "status": "SUCCESS",
                "message": "All in-memory sites, blocks, units, users, and dues synchronized to PostgreSQL successfully.",
                "sites_count": inner.sites.len(),
                "users_count": inner.users.len(),
                "units_count": inner.units.len(),
                "dues_count": inner.dues.len()
            })),
        )
    } else {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({
                "status": "ERROR",
                "message": "PostgreSQL connection pool is not configured."
            })),
        )
    }
}

/// Deletes every row of one site in a single transaction, child tables first.
/// The append-only ledger guard (V16) is lifted for this transaction only via
/// `sitepulse.allow_ledger_purge`; callers must be non-production test rollbacks.
async fn purge_site_rows(pool: &deadpool_postgres::Pool, site_id: i64) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    const UNIT_SCOPED: &[&str] = &[
        "payment_allocations WHERE payment_entry_id IN (SELECT id FROM payment_entries WHERE site_id = $1)",
        "payment_allocations WHERE dues_liability_id IN (SELECT d.id FROM dues_liabilities d JOIN units u ON u.id = d.unit_id WHERE u.site_id = $1)",
        "processed_bank_webhooks WHERE site_id = $1 OR receipt_id IN (SELECT id FROM payment_receipts WHERE site_id = $1)
             OR site_bank_account_id IN (SELECT id FROM site_bank_accounts WHERE site_id = $1)",
        "payment_entries WHERE site_id = $1 AND reverses_entry_id IS NOT NULL",
        "payment_entries WHERE site_id = $1",
        "payment_idempotency_keys WHERE site_id = $1",
        "payment_receipts WHERE site_id = $1 AND reverses_receipt_id IS NOT NULL",
        "payment_receipts WHERE site_id = $1",
        "receipt_counters WHERE site_id = $1",
        "advance_ledger_entries WHERE unit_id IN (SELECT id FROM units WHERE site_id = $1)",
        "advance_balances WHERE unit_id IN (SELECT id FROM units WHERE site_id = $1)",
        "debt_aging_snapshots WHERE site_id = $1",
        "reconciliation_queue WHERE site_id = $1",
        "unit_sender_ibans WHERE unit_id IN (SELECT id FROM units WHERE site_id = $1)",
        "unit_payer_names WHERE unit_id IN (SELECT id FROM units WHERE site_id = $1)",
        "dues_liabilities WHERE unit_id IN (SELECT id FROM units WHERE site_id = $1)",
        "occupancy_members WHERE occupancy_id IN (SELECT o.id FROM unit_occupancies o JOIN units u ON u.id = o.unit_id WHERE u.site_id = $1)",
        "unit_occupancies WHERE unit_id IN (SELECT id FROM units WHERE site_id = $1)",
        "unit_ownerships WHERE unit_id IN (SELECT id FROM units WHERE site_id = $1)",
        "invitation_tokens WHERE site_id = $1",
        "pending_registrations WHERE site_id = $1",
        "capital_contractor_disbursements WHERE project_id IN (SELECT id FROM capital_projects WHERE site_id = $1)",
        "capital_project_installments WHERE project_id IN (SELECT id FROM capital_projects WHERE site_id = $1)",
        "capital_projects WHERE site_id = $1",
        "dues_periods WHERE site_id = $1",
        "user_site_roles WHERE site_id = $1",
        "users WHERE site_id = $1",
        "units WHERE site_id = $1",
        "blocks WHERE site_id = $1",
        "house_types WHERE site_id = $1",
        "site_bank_accounts WHERE site_id = $1",
        "sites WHERE id = $1",
    ];
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    tx.batch_execute("SET LOCAL sitepulse.allow_ledger_purge = 'on'").await?;
    for target in UNIT_SCOPED {
        let table = target.split_whitespace().next().unwrap_or_default();
        let exists: bool = tx
            .query_one("SELECT to_regclass($1) IS NOT NULL", &[&table])
            .await?
            .get(0);
        if exists {
            tx.execute(&format!("DELETE FROM {}", target), &[&site_id]).await?;
        }
    }
    tx.commit().await?;
    Ok(())
}

/// Permanently purges a specific residential site and all associated units, residents,
/// homeowners, tenants, and dues records — useful for fine-grained test rollbacks.
pub async fn purge_site_cascade(
    axum::extract::Path(site_id): axum::extract::Path<String>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    if crate::state::AppStateInner::is_production() {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "status": "ERROR",
                "message": "Site silme işlemi canlı ortamda güvenlik nedeniyle engellenmiştir."
            })),
        );
    }

    if let Some(ref pool) = state.pool {
        let site_id_num = match site_id.parse::<i64>() {
            Ok(n) => n,
            Err(_) => return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"status": "ERROR", "message": format!("Invalid site id '{}'", site_id)}))
            ),
        };
        if let Err(e) = purge_site_rows(pool, site_id_num).await {
            tracing::error!("Site purge failed: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"status": "ERROR", "message": format!("Site purge failed: {}", e)}))
            );
        }
    }

    let mut inner = state.inner.write().await;
    let unit_ids: Vec<String> = inner.units.iter().filter(|u| u.site_id == site_id).map(|u| u.id.clone()).collect();
    inner.units.retain(|u| u.site_id != site_id);
    inner.users.retain(|u| u.site_id != site_id);
    inner.dues.retain(|d| !unit_ids.contains(&d.unit_id));
    for uid in &unit_ids {
        inner.advance_balances.remove(uid);
        inner.reconciliation_queue.retain(|q| q.matched_unit_id.as_deref() != Some(uid.as_str()));
        inner.unit_members.remove(uid);
    }
    inner.sites.retain(|s| s.id != site_id);

    (
        StatusCode::OK,
        Json(serde_json::json!({
            "status": "SUCCESS",
            "message": format!("Site '{}' ve bağlı tüm daireler, sakinler ve aidat kayıtları başarıyla silindi.", site_id),
            "remaining_sites_count": inner.sites.len(),
            "remaining_units_count": inner.units.len(),
            "remaining_users_count": inner.users.len()
        }))
    )
}

/// Dynamically provisions a residential site with N units (default: 12),
/// allocated Virtual IBANs, realistic resident profiles, matching criteria, and optional monthly dues.
pub async fn provision_site_units(
    State(state): State<AppState>,
    Json(payload): Json<ProvisionSiteUnitsRequest>,
) -> impl IntoResponse {
    if crate::state::AppStateInner::is_production() {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "status": "ERROR",
                "message": "Test site & sakin provizyon işlemi canlı (production) ortamında güvenlik nedeniyle engellenmiştir."
            })),
        );
    }

    let block_name = payload.block.clone().unwrap_or_else(|| "A Blok".to_string());
    let units_count = payload.units_count.unwrap_or(12).clamp(1, 48);
    let monthly_dues = payload.monthly_dues.unwrap_or_else(|| Decimal::from_str_exact("1400.00").unwrap());
    let accrue_dues = payload.accrue_initial_dues.unwrap_or(true);
    let dues_period = payload.period.clone().unwrap_or_else(|| "Ekim 2026".to_string());

    // 1. Resolve or register target site
    let s_name = payload.site_name.clone().unwrap_or_else(|| "Yeni Yaşam Sitesi".to_string());
    let slug = crate::services::to_slug(&s_name);

    let site_id = if let Some(ref s_id) = payload.site_id {
        let in_mem = {
            let inner = state.inner.read().await;
            inner.sites.iter().find(|s| s.id == *s_id || crate::db::parse_id_to_i64(&s.id) == crate::db::parse_id_to_i64(s_id)).map(|s| s.id.clone())
        };
        if let Some(id) = in_mem {
            id
        } else if let Some(ref pool) = state.pool {
            let id_num = match crate::db::parse_id_to_i64(s_id) {
                Some(n) => n,
                None => {
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(serde_json::json!({
                            "status": "ERROR",
                            "message": format!("Invalid site ID: {}", s_id)
                        })),
                    );
                }
            };
            let client = match pool.get().await {
                Ok(c) => c,
                Err(e) => {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({
                            "status": "ERROR",
                            "message": format!("Database error: {}", e)
                        })),
                    );
                }
            };
            let row = match client.query_opt("SELECT id, name, slug, address, status, plan_type, license_end_date FROM sites WHERE id = $1", &[&id_num]).await {
                Ok(r) => r,
                Err(e) => {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({
                            "status": "ERROR",
                            "message": format!("Database error: {}", e)
                        })),
                    );
                }
            };
            if let Some(r) = row {
                let id_val: i64 = r.get(0);
                let id_str = id_val.to_string();
                let name: String = r.get(1);
                let s_slug: Option<String> = r.get(2);
                let addr: Option<String> = r.get(3);
                let st: String = r.get(4);
                let plan: String = r.get(5);
                let lic_end: Option<chrono::NaiveDate> = r.get(6);
                let mut inner = state.inner.write().await;
                if !inner.sites.iter().any(|s| s.id == id_str) {
                    inner.sites.push(Site {
                        id: id_str.clone(),
                        name,
                        address: addr.unwrap_or_else(|| "Adres".to_string()),
                        slug: s_slug.unwrap_or_else(|| slug.clone()),
                        status: st,
                        plan_type: plan,
                        license_end_date: lic_end.unwrap_or_else(|| Utc::now().date_naive() + chrono::Days::new(365)),
                        timezone: crate::models::default_site_timezone(),
                        tax_id: None,
                        tax_office: None,
                    });
                }
                id_str
            } else {
                return (
                    StatusCode::NOT_FOUND,
                    Json(serde_json::json!({
                        "status": "ERROR",
                        "message": format!("Site with ID '{}' not found", s_id)
                    })),
                );
            }
        } else {
            return (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({
                    "status": "ERROR",
                    "message": format!("Site with ID '{}' not found", s_id)
                })),
            );
        }
    } else {
        let in_mem = {
            let inner = state.inner.read().await;
            inner.sites.iter().find(|s| s.slug == slug || s.name.eq_ignore_ascii_case(&s_name)).map(|s| s.id.clone())
        };
        if let Some(id) = in_mem {
            id
        } else if let Some(ref pool) = state.pool {
            let client = match pool.get().await {
                Ok(c) => c,
                Err(e) => {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({
                            "status": "ERROR",
                            "message": format!("Database error: {}", e)
                        })),
                    );
                }
            };
            let row = match client.query_opt("SELECT id, name, slug, address, status, plan_type, license_end_date FROM sites WHERE slug = $1 OR LOWER(name) = LOWER($2)", &[&slug, &s_name]).await {
                Ok(r) => r,
                Err(e) => {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({
                            "status": "ERROR",
                            "message": format!("Database error: {}", e)
                        })),
                    );
                }
            };
            if let Some(r) = row {
                let id_val: i64 = r.get(0);
                let id_str = id_val.to_string();
                let name: String = r.get(1);
                let s_slug: Option<String> = r.get(2);
                let addr: Option<String> = r.get(3);
                let st: String = r.get(4);
                let plan: String = r.get(5);
                let lic_end: Option<chrono::NaiveDate> = r.get(6);
                let mut inner = state.inner.write().await;
                if !inner.sites.iter().any(|s| s.id == id_str) {
                    inner.sites.push(Site {
                        id: id_str.clone(),
                        name,
                        address: addr.unwrap_or_else(|| "Kadıköy, İstanbul".to_string()),
                        slug: s_slug.unwrap_or_else(|| slug.clone()),
                        status: st,
                        plan_type: plan,
                        license_end_date: lic_end.unwrap_or_else(|| Utc::now().date_naive() + chrono::Days::new(365)),
                        timezone: crate::models::default_site_timezone(),
                        tax_id: None,
                        tax_office: None,
                    });
                }
                id_str
            } else {
                let license_end = Utc::now().date_naive() + chrono::Days::new(365);
                let ins_row = match client
                    .query_one(
                        r#"
                        INSERT INTO sites (name, address, slug, status, plan_type, license_end_date)
                        VALUES ($1, $2, $3, 'ACTIVE', 'PREMIUM', $4)
                        ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name
                        RETURNING id
                        "#,
                        &[&s_name, &"Kadıköy, İstanbul", &slug, &license_end],
                    )
                    .await
                {
                    Ok(r) => r,
                    Err(e) => {
                        return (
                            StatusCode::INTERNAL_SERVER_ERROR,
                            Json(serde_json::json!({
                                "status": "ERROR",
                                "message": format!("Failed to create site: {}", e)
                            })),
                        );
                    }
                };
                let new_id: i64 = ins_row.get(0);
                let id_str = new_id.to_string();
                let mut inner = state.inner.write().await;
                inner.sites.push(Site {
                    id: id_str.clone(),
                    name: s_name,
                    address: "Kadıköy, İstanbul".to_string(),
                    slug,
                    status: "ACTIVE".to_string(),
                    plan_type: "PREMIUM".to_string(),
                    license_end_date: license_end,
                    timezone: crate::models::default_site_timezone(),
                    tax_id: None,
                    tax_office: None,
                });
                id_str
            }
        } else {
            let mut inner = state.inner.write().await;
            if let Some(existing) = inner.sites.iter().find(|s| s.slug == slug || s.name.eq_ignore_ascii_case(&s_name)) {
                existing.id.clone()
            } else {
                let max_id = inner.sites.iter().filter_map(|s| crate::db::parse_id_to_i64(&s.id)).max().unwrap_or(0);
                let id_str = (max_id + 1).to_string();
                inner.sites.push(Site {
                    id: id_str.clone(),
                    name: s_name,
                    address: "Kadıköy, İstanbul".to_string(),
                    slug,
                    status: "ACTIVE".to_string(),
                    plan_type: "PREMIUM".to_string(),
                    license_end_date: Utc::now().date_naive() + chrono::Days::new(365),
                    timezone: crate::models::default_site_timezone(),
                    tax_id: None,
                    tax_office: None,
                });
                id_str
            }
        }
    };

    let mut inner = state.inner.write().await;
    let site_name = inner.sites.iter().find(|s| s.id == site_id).map(|s| s.name.clone()).unwrap_or_else(|| "Site".to_string());

    // 2. Sample 12 Turkish resident names
    let sample_names = [
        "Ahmet Yılmaz",
        "Ayşe Demir",
        "Mehmet Öztürk",
        "Fatma Kaya",
        "Canan Çelik",
        "Burak Şahin",
        "Emre Yıldız",
        "Gamze Arslan",
        "Hakan Aydın",
        "İrem Koç",
        "Kemal Güven",
        "Leyla Aksoy",
    ];

    let mut provisioned_dtos = Vec::new();
    let site_slug = crate::services::to_slug(&site_name);

    for i in 1..=units_count {
        let unit_number = i as i32;
        let floor = ((i - 1) / 4 + 1) as i32;
        let name_idx = (i - 1) % sample_names.len();
        let resident_name = sample_names[name_idx].to_string();
        let email = format!("daire{}@{}.com", i, site_slug);
        let phone = format!("+90 532 555 {:04}", i + 100);

        let virtual_iban = VirtualIbanService::generate_virtual_iban(
            VirtualIbanService::KUVEYT_TURK_BANK_CODE,
            &site_id,
            &block_name,
            unit_number,
        );

        // Add or update resident user
        let user_id = if let Some(existing_user) = inner.users.iter_mut().find(|u| u.email == email || (u.site_id == site_id && u.full_name == resident_name)) {
            existing_user.full_name = resident_name.clone();
            existing_user.phone = phone.clone();
            existing_user.id.clone()
        } else {
            let max_u = inner.users.iter().filter_map(|u| crate::db::parse_id_to_i64(&u.id)).max().unwrap_or(0);
            let u_id = (max_u + 1).to_string();
            inner.users.push(User {
                id: u_id.clone(),
                site_id: site_id.clone(),
                full_name: resident_name.clone(),
                email: email.clone(),
                phone: phone.clone(),
                password_hash: Some(crate::auth::hash_password(&crate::auth::generate_temporary_password("SP-SAKIN-"))),
                role: Role::HomeOwner,
                must_change_password: true,
                auth_provider: "LOCAL".to_string(),
                google_sub: None,
                avatar_url: None,
                created_at: Utc::now(),
                person_id: None,
            });
            u_id
        };

        // Add or update independent flat
        let existing_pos = inner.units.iter().position(|u| u.site_id == site_id && u.unit_number == unit_number);
        let unit_id = if let Some(pos) = existing_pos {
            let u = &mut inner.units[pos];
            u.block_id = block_name.clone();
            u.floor = floor;
            u.owner_user_id = Some(user_id.clone());
            u.virtual_iban = Some(virtual_iban.clone());
            u.id.clone()
        } else {
            let max_unit = inner.units.iter().filter_map(|u| crate::db::parse_id_to_i64(&u.id)).max().unwrap_or(0);
            let new_unit_id = (max_unit + 1).to_string();
            inner.units.push(IndependentUnit {
                id: new_unit_id.clone(),
                site_id: site_id.clone(),
                block_id: block_name.clone(),
                unit_number,
                floor,
                land_share: 24,
                owner_user_id: Some(user_id.clone()),
                tenant_user_id: None,
                virtual_iban: Some(virtual_iban.clone()),
                house_type: Some(if unit_number % 2 == 0 { "3+1".to_string() } else { "2+1".to_string() }),
            });
            new_unit_id
        };

        // Matching criteria & sender IBAN
        inner.unit_payer_names.insert(unit_id.clone(), vec![resident_name.clone()]);
        let sample_sender_iban = format!("TR{:02}000620000000000000{:04}", (i % 80) + 10, i);
        inner.remembered_sender_ibans.insert(sample_sender_iban.clone(), unit_id.clone());
        inner.sender_iban_metadata.insert(
            sample_sender_iban.clone(),
            (Some(format!("Garanti BBVA - {}", resident_name)), Some("Garanti BBVA".to_string())),
        );

        // Optional dues accrual
        if accrue_dues && !inner.dues.iter().any(|d| d.unit_id == unit_id && d.period == dues_period) {
            let max_due = inner.dues.iter().filter_map(|d| crate::db::parse_id_to_i64(&d.id)).max().unwrap_or(0);
            let due_id = (max_due + 1).to_string();
            inner.dues.push(DuesLiability {
                id: due_id,
                unit_id: unit_id.clone(),
                period: dues_period.clone(),
                principal_amount: monthly_dues,
                delay_penalty: Decimal::ZERO,
                total_amount: monthly_dues,
                due_date: Utc::now().date_naive() + chrono::Days::new(15),
                status: DebtStatus::Pending,
                paid_principal: Decimal::ZERO,
                paid_penalty: Decimal::ZERO,
                // A freshly provisioned unit has no tenant: its dues are the owner's.
                debtor_type: "OWNER".to_string(),
                expense_type: "OPERATIONAL_DUES".to_string(),
                penalty_accrued_through: None,
            });
        }

        // Auto-offset against any pre-existing advance balance for this unit
        apply_advance_payments_offset(&mut inner, Some(&unit_id));

        let current_debt: Decimal = inner.dues.iter()
            .filter(|d| d.unit_id == unit_id && d.status != DebtStatus::Paid)
            .map(|d| d.total_amount)
            .sum();
        let advance = inner.advance_total(&unit_id);

        provisioned_dtos.push(ProvisionedUnitDto {
            unit_id,
            unit_number,
            block: block_name.clone(),
            floor,
            resident_name,
            email,
            phone,
            virtual_iban,
            current_debt,
            advance_balance: advance,
            sender_iban: sample_sender_iban,
        });
    }

    if let Some(ref pool) = state.pool {
        let snapshot = inner.clone();
        if let Err(e) = crate::db::sync_all_in_memory_to_db(pool, &snapshot).await { tracing::error!("Database write failed: {}", e); }
    }

    let total_volume = monthly_dues * Decimal::from(units_count);

    (
        StatusCode::OK,
        Json(serde_json::to_value(ProvisionSiteUnitsResponse {
            status: "SUCCESS".to_string(),
            message: format!("{} için {} daire ve sakin kaydı başarıyla oluşturuldu.", site_name, units_count),
            site_id,
            site_name,
            units_count,
            total_monthly_dues_volume: total_volume,
            units: provisioned_dtos,
        }).unwrap()),
    )
}

/// Returns a summary list of all units in the system for testing & simulator dropdowns
pub async fn get_units_summary(
    State(state): State<AppState>,
) -> impl IntoResponse {
    let inner = state.inner.read().await;
    let mut result = Vec::new();

    for unit in &inner.units {
        let site_name = inner.sites.iter().find(|s| s.id == unit.site_id).map(|s| s.name.clone()).unwrap_or_else(|| "Site".to_string());
        let resident_name = unit.owner_user_id.as_ref().and_then(|uid| {
            inner.users.iter().find(|u| &u.id == uid).map(|u| u.full_name.clone())
        }).unwrap_or_else(|| format!("Daire Sakini {}", unit.unit_number));
        let email = unit.owner_user_id.as_ref().and_then(|uid| {
            inner.users.iter().find(|u| &u.id == uid).map(|u| u.email.clone())
        }).unwrap_or_default();
        let current_debt: Decimal = inner.dues.iter()
            .filter(|d| d.unit_id == unit.id && d.status != DebtStatus::Paid)
            .map(|d| d.total_amount)
            .sum();
        let advance = inner.advance_total(&unit.id);

        result.push(serde_json::json!({
            "unit_id": unit.id,
            "site_id": unit.site_id,
            "site_name": site_name,
            "block": unit.block_id,
            "unit_number": unit.unit_number,
            "floor": unit.floor,
            "resident_name": resident_name,
            "email": email,
            "virtual_iban": unit.virtual_iban.clone().unwrap_or_default(),
            "current_debt": current_debt.to_string(),
            "advance_balance": advance.to_string()
        }));
    }

    (StatusCode::OK, Json(result))
}

#[derive(Debug, Clone, Deserialize)]
pub struct SitePaymentsQuery {
    pub site_id: Option<String>,
}

/// Returns all incoming bank/FAST payments and reconciliation records for a given site
pub async fn get_site_payments(
    State(state): State<AppState>,
    Query(query): Query<SitePaymentsQuery>,
) -> impl IntoResponse {
    let inner = state.inner.read().await;

    // 1. Resolve site
    let site = if let Some(ref s_id) = query.site_id {
        if s_id != "undefined" && !s_id.is_empty() {
            inner.sites.iter().find(|s| &s.id == s_id).cloned().or_else(|| inner.sites.first().cloned())
        } else {
            inner.sites.first().cloned()
        }
    } else {
        inner.sites.first().cloned()
    };

    let site_id = site.as_ref().map(|s| s.id.clone()).unwrap_or_else(|| query.site_id.clone().unwrap_or_default());
    let site_name = site.as_ref().map(|s| s.name.clone()).unwrap_or_default();

    // 2. Units in this site
    let site_units: Vec<_> = inner.units.iter().filter(|u| u.site_id == site_id).collect();
    let site_unit_ids: Vec<String> = site_units.iter().map(|u| u.id.clone()).collect();

    let total_advance: Decimal = site_units
        .iter()
        .map(|u| inner.advance_total(&u.id))
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
            let flat_label = if let (Some(ref b), Some(u_num)) = (&item.matched_block, item.matched_unit_number) {
                if b.contains("Blok") {
                    format!("{} D:{}", b, u_num)
                } else {
                    format!("{} Blok D:{}", b, u_num)
                }
            } else {
                "Daire Belirlenemedi".to_string()
            };

            let is_advance = item.notes.as_deref().unwrap_or("").contains("avans")
                || item.notes.as_deref().unwrap_or("").contains("Avans");

            // Look up unit's virtual account number (Virtual IBAN)
            let virtual_iban = item.matched_unit_id.as_ref().and_then(|uid| {
                inner.units.iter().find(|u| &u.id == uid).and_then(|u| u.virtual_iban.clone())
            });

            // Check if there is a linked homeowner payment to detect exact method (e.g. CREDIT_CARD)
            let linked_hp = inner.homeowner_payments.iter().find(|hp| {
                hp.id == item.transaction.transaction_id
                    || hp.reference_code.as_deref() == Some(&item.transaction.transaction_id)
            });

            let desc_upper = item.transaction.description.to_uppercase();
            let txn_upper = item.transaction.transaction_id.to_uppercase();

            let (payment_channel, payment_channel_label) = if let Some(hp) = linked_hp {
                let m = hp.payment_method.to_uppercase();
                if m.contains("CARD") || m.contains("KART") {
                    ("CREDIT_CARD", "Kredi Kartı (Online)")
                } else if m.contains("VIBAN") || m.contains("VIRTUAL") {
                    ("VIRTUAL_IBAN", "Sanal IBAN (Virtual Account)")
                } else if m.contains("FAST") {
                    ("FAST", "FAST 7/24 Anlık Takas")
                } else {
                    ("BANK_TRANSFER", "Banka Havale / EFT")
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

            let resolved_resident_name = item.matched_resident_name.clone()
                .or_else(|| item.transaction.sender_name.clone())
                .or_else(|| {
                    item.matched_unit_id.as_ref().and_then(|uid| {
                        inner.units.iter().find(|u| &u.id == uid)
                            .and_then(|u| u.owner_user_id.as_ref())
                            .and_then(|owner_id| inner.users.iter().find(|user| &user.id == owner_id))
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
                    || (hp.reference_code.is_some() && p.get("transaction_id").and_then(|t| t.as_str()) == hp.reference_code.as_deref())
            });

            if !already_included {
                total_collected += hp.amount;
                let unit = inner.units.iter().find(|u| u.id == hp.unit_id);
                let flat_label = if hp.block_id.contains("Blok") {
                    format!("{} D:{}", hp.block_id, hp.unit_number)
                } else {
                    format!("{} Blok D:{}", hp.block_id, hp.unit_number)
                };

                let resident_name = hp.homeowner_name.clone().unwrap_or_else(|| {
                    unit.and_then(|u| u.owner_user_id.as_ref())
                        .and_then(|uid| inner.users.iter().find(|user| &user.id == uid))
                        .map(|user| user.full_name.clone())
                        .unwrap_or_else(|| "Bilinmiyor".to_string())
                });

                let virtual_iban = unit.and_then(|u| u.virtual_iban.clone());
                let is_advance = hp.advance_credit_amount > Decimal::ZERO;

                let payment_channel = hp.payment_method.clone();
                let payment_channel_label = if payment_channel.to_uppercase().contains("CARD") || payment_channel.to_uppercase().contains("KART") {
                    "Kredi Kartı (Online)".to_string()
                } else if payment_channel.to_uppercase().contains("VIBAN") || payment_channel.to_uppercase().contains("VIRTUAL") {
                    "Sanal IBAN (Virtual Account)".to_string()
                } else if payment_channel.to_uppercase().contains("FAST") {
                    "FAST 7/24 Anlık Takas".to_string()
                } else {
                    "Banka Havale / EFT".to_string()
                };

                payments.push(serde_json::json!({
                    "match_id": format!("MATCH-HP-{}", hp.id),
                    "transaction_id": hp.id.clone(),
                    "date": hp.created_at.date_naive().to_string(),
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

    (StatusCode::OK, Json(serde_json::json!({
        "site_id": site_id,
        "site_name": site_name,
        "total_units_count": site_units.len(),
        "total_collected": total_collected.to_string(),
        "total_advance_balance": total_advance.to_string(),
        "payments_count": payments_count,
        "payments": payments,
        "guidance": guidance
    })))
}

/// Returns the comprehensive overview for the Site Manager:
/// Managed site details, collection summary, available periods, and list of flats with dues status.
pub async fn get_site_overview(
    State(state): State<AppState>,
    Query(query): Query<crate::models::SiteOverviewQuery>,
) -> impl IntoResponse {
    let mut inner = state.inner.write().await;
    let ledger_before = ledger_snapshot(&inner);
    apply_advance_payments_offset(&mut inner, None);
    if let Some(ref pool) = state.pool {
        // Errors are logged by persist_ledger_changes; the view is still served.
        let _logged = persist_ledger_changes(pool, &ledger_before, &inner).await;
    }

    // 1. Resolve site
    let site = if let Some(ref s_id) = query.site_id {
        inner.sites.iter().find(|s| &s.id == s_id || crate::db::parse_id_to_i64(&s.id) == crate::db::parse_id_to_i64(s_id)).cloned()
    } else {
        inner.sites.iter()
            .find(|s| inner.units.iter().filter(|u| u.site_id == s.id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&s.id)).count() >= 12)
            .or_else(|| inner.sites.iter().find(|s| inner.units.iter().any(|u| u.site_id == s.id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&s.id))))
            .or_else(|| inner.sites.first())
            .cloned()
    };

    let site_id = site.as_ref().map(|s| s.id.clone()).unwrap_or_default();
    let site_name = site.as_ref().map(|s| s.name.clone()).unwrap_or_default();
    let address = site.as_ref().map(|s| s.address.clone()).unwrap_or_default();

    // 2. Resolve manager name & email
    let (manager_name, manager_email) = inner.users.iter()
        .find(|u| (!site_id.is_empty() && (u.site_id == site_id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&site_id))) && (u.role == Role::SiteManager || u.email.contains("yonetici") || u.email.contains("manager")))
        .map(|u| (u.full_name.clone(), u.email.clone()))
        .unwrap_or_else(|| ("Site Yöneticisi".to_string(), String::new()));

    // 3. Collect available periods for this site from dues_periods and dues
    let mut available_periods: Vec<String> = Vec::new();
    let site_unit_ids: Vec<String> = inner.units.iter()
        .filter(|u| u.site_id == site_id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&site_id))
        .map(|u| u.id.clone())
        .collect();

    for p in &inner.dues_periods {
        if (p.site_id == site_id || crate::db::parse_id_to_i64(&p.site_id) == crate::db::parse_id_to_i64(&site_id))
            && !available_periods.contains(&p.period_name) {
            available_periods.push(p.period_name.clone());
        }
    }

    for due in &inner.dues {
        if (site_unit_ids.contains(&due.unit_id) || site_unit_ids.is_empty()) && !available_periods.contains(&due.period) {
            available_periods.push(due.period.clone());
        }
    }

    fn period_sort_key(period: &str) -> (i32, u32) {
        let parts: Vec<&str> = period.split_whitespace().collect();
        if parts.len() == 2 {
            let month_idx = match parts[0].to_lowercase().as_str() {
                "ocak" => 1,
                "şubat" | "subat" => 2,
                "mart" => 3,
                "nisan" => 4,
                "mayıs" | "mayis" => 5,
                "haziran" => 6,
                "temmuz" => 7,
                "ağustos" | "agustos" => 8,
                "eylül" | "eylul" => 9,
                "ekim" => 10,
                "kasım" | "kasim" => 11,
                "aralık" | "aralik" => 12,
                _ => 0,
            };
            let year = parts[1].parse::<i32>().unwrap_or(0);
            (year, month_idx)
        } else {
            (0, 0)
        }
    }

    available_periods.sort_by_key(|p| std::cmp::Reverse(period_sort_key(p)));

    let selected_period = query.period.unwrap_or_else(|| {
        available_periods.first().cloned().unwrap_or_default()
    });

    // 4. Available sites list for site switcher (deduplicated by name)
    let mut available_sites: Vec<crate::models::SiteSummaryBriefDto> = Vec::new();
    for s in &inner.sites {
        if !available_sites.iter().any(|existing| existing.name == s.name) {
            let count = inner.units.iter().filter(|u| u.site_id == s.id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&s.id)).count();
            available_sites.push(crate::models::SiteSummaryBriefDto {
                id: s.id.clone(),
                name: s.name.clone(),
                address: s.address.clone(),
                total_units: count,
            });
        }
    }

    // 5. Gather flats for this site (deduplicated by block and unit_number)
    let matching_units: Vec<_> = {
        let mut seen_units = std::collections::HashSet::new();
        let mut deduped = Vec::new();
        let normalize_block = |blk_id: &str| -> String {
            match blk_id {
                "1" | "blok-A" => "A".to_string(),
                "2" | "blok-B" => "B".to_string(),
                "3" | "blok-C" => "C".to_string(),
                "4" | "blok-D" => "D".to_string(),
                _ => {
                    let clean = blk_id.to_uppercase().replace("BLOK", "").replace(['-', '_', ' '], "").trim().to_string();
                    if clean.is_empty() { blk_id.to_string() } else { clean }
                }
            }
        };

        for u in &inner.units {
            let matches_site = u.site_id == site_id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&site_id);
            if matches_site {
                let clean_blk = normalize_block(&u.block_id);
                if seen_units.insert((clean_blk, u.unit_number)) {
                    deduped.push(u.clone());
                }
            }
        }
        if deduped.is_empty() {
            for u in &inner.units {
                let clean_blk = normalize_block(&u.block_id);
                if seen_units.insert((clean_blk, u.unit_number)) {
                    deduped.push(u.clone());
                }
            }
        }
        deduped
    };

    let mut flats = Vec::new();
    let mut total_expected = Decimal::ZERO;
    let mut total_collected = Decimal::ZERO;
    let mut total_overdue = Decimal::ZERO;
    let mut total_advance = Decimal::ZERO;
    let mut paid_count = 0;
    let mut overdue_count = 0;

    for unit in &matching_units {
        let resident_name = unit.tenant_user_id.as_ref().and_then(|uid| {
            inner.users.iter().find(|u| &u.id == uid).map(|u| u.full_name.clone())
        }).or_else(|| {
            unit.owner_user_id.as_ref().and_then(|uid| {
                inner.users.iter().find(|u| &u.id == uid).map(|u| u.full_name.clone())
            })
        }).or_else(|| {
            inner.unit_payer_names.get(&unit.id).and_then(|names| names.first().cloned())
        }).unwrap_or_else(|| format!("Daire Sakini {}", unit.unit_number));

        // Find due for this unit in the selected period
        let due_opt = inner.dues.iter().find(|d| d.unit_id == unit.id && d.period == selected_period);
        let advance = inner.advance_total(&unit.id);
        total_advance += advance;

        let (amount_due, is_paid, days_overdue, paid_date_str) = if let Some(due) = due_opt {
            let is_p = due.status == DebtStatus::Paid;
            let days_o = if due.status == DebtStatus::Overdue { 15 } else { 0 };
            let p_date = if is_p { Some("Ödendi".to_string()) } else { None };
            (due.total_amount, is_p, days_o, p_date)
        } else {
            (Decimal::ZERO, true, 0, None)
        };

        if amount_due > Decimal::ZERO {
            total_expected += amount_due;
            if is_paid {
                total_collected += amount_due;
                paid_count += 1;
            } else {
                total_overdue += amount_due;
                overdue_count += 1;
            }
        }

        let effective_block = match unit.block_id.as_str() {
            "1" => "A".to_string(),
            "2" => "B".to_string(),
            "3" => "C".to_string(),
            "4" => "D".to_string(),
            _ => {
                let clean = unit.block_id.to_uppercase().replace("BLOK", "").replace(['-', '_', ' '], "").trim().to_string();
                if clean.is_empty() { unit.block_id.clone() } else { clean }
            }
        };

        flats.push(crate::models::SiteFlatStatusDto {
            id: unit.id.clone(),
            block: effective_block,
            unit_no: unit.unit_number,
            resident_name,
            amount_due,
            days_overdue,
            is_paid,
            paid_date_str,
            virtual_iban: unit.virtual_iban.clone(),
            advance_balance: advance,
            house_type: unit.house_type.clone(),
        });
    }

    flats.sort_by_key(|f| (f.block.clone(), f.unit_no));

    let total_units_count = flats.len();
    let collection_percentage = if total_expected > Decimal::ZERO {
        let ratio = (total_collected / total_expected) * Decimal::from(100);
        ratio.to_string().split('.').next().unwrap_or("0").parse::<u32>().unwrap_or(0)
    } else {
        100
    };

    let summary = crate::models::SiteCollectionSummaryDto {
        total_expected,
        total_collected,
        total_overdue_with_interest: total_overdue,
        total_advance_balance: total_advance,
        paid_units_count: paid_count,
        overdue_units_count: overdue_count,
        total_units_count,
        collection_percentage,
    };

    let guidance = if inner.sites.is_empty() {
        Some("Sistemde kayıtlı bir site bulunmuyor. Yeni bir site ve blok yapısı oluşturarak başlayabilirsiniz.".to_string())
    } else if matching_units.is_empty() {
        Some("Bu sitede henüz kayıtlı daire veya kat maliki bulunmuyor. Sakin ekleme menüsünden dairelerinizi tanımlayabilirsiniz.".to_string())
    } else if available_periods.is_empty() {
        Some("Bu site için henüz bir aidat dönemi tahakkuk ettirilmemiş. 'Aidat Tahakkuk Ettir' işlemiyle ilk dönemi başlatabilirsiniz.".to_string())
    } else {
        None
    };

    let response = crate::models::SiteOverviewResponse {
        site_id,
        site_name,
        address,
        manager_name,
        manager_email,
        selected_period,
        available_periods,
        available_sites,
        summary,
        flats,
        guidance,
    };

    (StatusCode::OK, Json(serde_json::to_value(response).unwrap()))
}

pub async fn get_payment_stream(
    State(state): State<AppState>,
    Query(filter): Query<crate::models::PaymentStreamFilter>,
) -> Json<crate::models::PaymentStreamResponse> {
    let service = crate::services::PaymentTrackingService::new(state);
    Json(service.get_payment_stream(filter).await)
}

pub async fn get_debt_aging_report(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<crate::models::DebtAgingReport> {
    let site_id = q.site_id.unwrap_or_default();
    let service = crate::services::PaymentTrackingService::new(state);
    Json(service.get_debt_aging_report(&site_id).await)
}

pub async fn record_manual_payment(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Json(mut payload): Json<crate::models::RecordManualPaymentRequest>,
) -> Result<(StatusCode, Json<crate::models::PaymentReceipt>), (StatusCode, String)> {
    // The standard `Idempotency-Key` header takes precedence over the body field.
    if let Some(key) = headers.get("idempotency-key").and_then(|v| v.to_str().ok()) {
        payload.idempotency_key = Some(key.to_string());
    }
    let service = crate::services::PaymentTrackingService::new(state);
    service
        .record_and_allocate_payment(payload)
        .await
        .map(|r| (StatusCode::CREATED, Json(r)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn inter_ledger_transfer(
    State(state): State<AppState>,
    Json(payload): Json<crate::models::InterLedgerTransferRequest>,
) -> Result<Json<crate::models::InterLedgerTransferResponse>, (StatusCode, String)> {
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
    axum::Extension(claims): axum::Extension<crate::auth::Claims>,
    Json(mut payload): Json<crate::models::ReversePaymentRequest>,
) -> Result<(StatusCode, Json<crate::models::ReversePaymentResponse>), (StatusCode, String)> {
    if !claims.is_site_staff() {
        return Err((StatusCode::FORBIDDEN, "Only site staff may reverse payments".to_string()));
    }
    if payload.site_id.as_deref().map(str::trim).unwrap_or("").is_empty() {
        payload.site_id = Some(claims.site_id.clone());
    }
    let actor = format!("user:{} <{}>", claims.sub, claims.email);
    let service = crate::services::PaymentTrackingService::new(state);
    service
        .reverse_payment(payload, &actor)
        .await
        .map(|r| (StatusCode::CREATED, Json(r)))
        .map_err(payment_error_status)
}

/// Writes today's debt aging snapshot (O-8). The daily worker does the same.
pub async fn snapshot_debt_aging(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let service = crate::services::PaymentTrackingService::new(state);
    let rows = service
        .snapshot_debt_aging(q.site_id.as_deref().filter(|s| !s.trim().is_empty()))
        .await
        .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, e))?;
    Ok(Json(serde_json::json!({ "status": "OK", "rows": rows, "as_of_date": Utc::now().date_naive() })))
}

pub async fn get_payment_receipt(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<crate::auth::Claims>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<crate::models::PaymentReceipt>, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_else(|| claims.site_id.clone());
    let service = crate::services::PaymentTrackingService::new(state);
    let receipt = service.get_receipt(&site_id, &id).await.map_err(|e| (StatusCode::NOT_FOUND, e))?;
    // Residents may only read receipts issued for their own unit.
    if !claims.is_site_staff() {
        let own = claims.unit_id.as_deref().unwrap_or("");
        if !crate::auth::same_id(own, &receipt.unit_id) {
            return Err((StatusCode::NOT_FOUND, "Receipt not found".to_string()));
        }
    }
    Ok(Json(receipt))
}

pub async fn transfer_unit_ownership(
    State(state): State<AppState>,
    Path(unit_id): Path<String>,
    Json(mut payload): Json<crate::models::TransferOwnershipRequest>,
) -> Result<Json<crate::models::TransferOwnershipResponse>, (StatusCode, String)> {
    payload.unit_id = unit_id;
    let service = crate::services::PaymentTrackingService::new(state);
    service
        .transfer_ownership(payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

// ---------------------------------------------------------------------------
// Capital Projects & Fixtures (Demirbaş Yönetimi - EPIC-10) Handlers
// ---------------------------------------------------------------------------

pub async fn list_capital_projects(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<CapitalProject>> {
    let site_id = q.site_id.unwrap_or_default();
    let service = CapitalProjectService::new(state);
    Json(service.list_projects(&site_id).await)
}

pub async fn create_capital_project(
    State(state): State<AppState>,
    Json(payload): Json<CreateCapitalProjectRequest>,
) -> Result<(StatusCode, Json<CapitalProject>), (StatusCode, String)> {
    let service = CapitalProjectService::new(state);
    service
        .create_project(payload)
        .await
        .map(|p| (StatusCode::CREATED, Json(p)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_capital_project(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<CapitalProject>, (StatusCode, String)> {
    let service = CapitalProjectService::new(state);
    service
        .get_project(&id)
        .await
        .map(Json)
        .ok_or_else(|| (StatusCode::NOT_FOUND, "Demirbaş projesi bulunamadı.".to_string()))
}

pub async fn list_capital_installments(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Json<Vec<CapitalProjectInstallment>> {
    let service = CapitalProjectService::new(state);
    Json(service.list_installments(&id).await)
}

pub async fn accrue_capital_installment(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(payload): Json<AccrueInstallmentRequest>,
) -> Result<Json<AccrueInstallmentResponse>, (StatusCode, String)> {
    let service = CapitalProjectService::new(state);
    service
        .accrue_installment(&id, payload.installment_number)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn record_capital_disbursement(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(payload): Json<RecordDisbursementRequest>,
) -> Result<(StatusCode, Json<CapitalContractorDisbursement>), (StatusCode, String)> {
    let service = CapitalProjectService::new(state);
    service
        .record_disbursement(&id, payload)
        .await
        .map(|d| (StatusCode::CREATED, Json(d)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn list_capital_disbursements(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Json<Vec<CapitalContractorDisbursement>> {
    let service = CapitalProjectService::new(state);
    Json(service.list_disbursements(&id).await)
}

pub async fn get_unit_capital_shares(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Vec<UnitCapitalShareSummary>>, (StatusCode, String)> {
    let service = CapitalProjectService::new(state);
    service
        .get_unit_capital_shares(&id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}


