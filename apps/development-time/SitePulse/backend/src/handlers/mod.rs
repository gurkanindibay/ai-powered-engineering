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
    AuthService, DuesCalculationService, HomeResidentInvitationService, KuveytTurkSandboxService,
    ReconciliationService, RegistrationApprovalService, SaasTenantService, SiteAdminService,
    SiteBankAccountService, VirtualIbanService,
};
use crate::state::AppState;
use uuid::Uuid;

/// Domain Service / Rule: Advance Balance Auto-Offsetting
/// When dues liabilities exist or arrive for a unit, any available advance balance
/// (Avans Bakiye) is automatically deducted against the debt (FIFO order by due_date).
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
        let advance = match inner.advance_payments.get_mut(&u_id) {
            Some(adv) if *adv > Decimal::ZERO => adv,
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

        let unit_block = inner.units.iter().find(|u| u.id == u_id).map(|u| u.block_id.clone()).unwrap_or_else(|| "A".to_string());
        let unit_number = inner.units.iter().find(|u| u.id == u_id).map(|u| u.unit_number).unwrap_or(1);

        for idx in unpaid_indices {
            if *advance <= Decimal::ZERO {
                break;
            }

            let due = &mut inner.dues[idx];
            let due_amount = due.total_amount;
            let period = due.period.clone();
            let due_id = due.id.clone();

            if *advance >= due_amount {
                // Full settlement of this due liability
                *advance -= due_amount;
                due.status = DebtStatus::Paid;
                total_offset_amount += due_amount;
                auto_settled_count += 1;

                let offset_txn_id = format!("TXN-ADV-OFFSET-{}", due_id);
                if !inner.reconciliation_queue.iter().any(|m| m.transaction.transaction_id == offset_txn_id) {
                    inner.reconciliation_queue.push(ReconciliationMatch {
                        match_id: format!("MATCH-OFFSET-{}", Uuid::new_v4().simple()),
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
                        matched_resident_name: Some("Ahmet Yılmaz".to_string()),
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
                let partial = *advance;
                *advance = Decimal::ZERO;
                due.principal_amount -= partial;
                due.total_amount -= partial;
                total_offset_amount += partial;

                let offset_txn_id = format!("TXN-ADV-PARTIAL-{}", due_id);
                if !inner.reconciliation_queue.iter().any(|m| m.transaction.transaction_id == offset_txn_id) {
                    inner.reconciliation_queue.push(ReconciliationMatch {
                        match_id: format!("MATCH-OFFSET-PARTIAL-{}", Uuid::new_v4().simple()),
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
                        matched_resident_name: Some("Ahmet Yılmaz".to_string()),
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

    let unit = inner
        .units
        .iter()
        .find(|u| u.id == unit_id)
        .cloned()
        .unwrap_or_else(|| {
            let default_viban = VirtualIbanService::generate_virtual_iban(
                VirtualIbanService::KUVEYT_TURK_BANK_CODE,
                "site-1",
                "A",
                14,
            );
            IndependentUnit {
                id: unit_id.clone(),
                site_id: "site-1".to_string(),
                block_id: "A".to_string(),
                unit_number: 14,
                floor: 4,
                land_share: 24,
                owner_user_id: None,
                tenant_user_id: None,
                virtual_iban: Some(default_viban),
            }
        });

    // Automatically apply available advance payments against any unpaid dues (FIFO)
    apply_advance_payments_offset(&mut inner, Some(&unit_id));

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

    let site_title = format!("Begonya Sitesi • {} Blok D:{}", unit.block_id, unit.unit_number);
    let advance_payment = inner
        .advance_payments
        .get(&unit_id)
        .copied()
        .unwrap_or(Decimal::ZERO);

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

    // 3. Historical baseline transactions
    transactions.push(AccountTransactionDto {
        id: "tx-hist-01".to_string(),
        title: "Ağustos 2026 Aidatı".to_string(),
        subtitle: "Kredi Kartı ile Ödendi".to_string(),
        amount: Decimal::from_str_exact("1400.00").unwrap(),
        date: "15.08.2026".to_string(),
        is_credit: true,
    });
    transactions.push(AccountTransactionDto {
        id: "tx-hist-02".to_string(),
        title: "Demirbaş Katılım Payı".to_string(),
        subtitle: "Yönetim Hesabına Transfer".to_string(),
        amount: Decimal::from_str_exact("500.00").unwrap(),
        date: "02.08.2026".to_string(),
        is_credit: true,
    });

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

    (StatusCode::OK, Json(response))
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

#[derive(Deserialize)]
pub struct ProfileQuery {
    pub user_id: Option<String>,
}

pub async fn get_profile(
    State(state): State<AppState>,
    Query(query): Query<ProfileQuery>,
) -> Result<Json<UserProfileResponse>, (StatusCode, String)> {
    let user_id = query
        .user_id
        .unwrap_or_else(|| "usr-site-manager-1".to_string());
    let service = AuthService::new(state);
    service
        .get_current_profile(&user_id)
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
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
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
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
    let service = SiteAdminService::new(state);
    Json(service.get_home_owners_for_site(&site_id).await)
}

// 5. Registration Approval Handlers
pub async fn generate_registration_link(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<SiteInvitationLinkResponse> {
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
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
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
    let service = RegistrationApprovalService::new(state);
    Json(service.get_pending_registrations(&site_id).await)
}

pub async fn approve_registration(
    Path(request_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ApprovalResultResponse>, (StatusCode, String)> {
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
) -> Result<Json<PendingRegistrationResponse>, (StatusCode, String)> {
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
        .cloned()
        .collect();

    let matches = recon_service.reconcile_transactions(&txns, &site_units, &site_users, &site_dues, today);

    // Append to reconciliation queue in state
    for m in &matches {
        inner.reconciliation_queue.push(m.clone());
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
) -> Json<Vec<ReconciliationMatch>> {
    let inner = state.inner.read().await;
    Json(inner.reconciliation_queue.clone())
}

pub async fn confirm_reconciliation(
    State(state): State<AppState>,
    Json(payload): Json<ConfirmReconciliationRequest>,
) -> Result<(StatusCode, Json<ConfirmReconciliationResponse>), (StatusCode, String)> {
    let mut inner = state.inner.write().await;
    let mut confirmed_count = 0;
    let mut total_amount_cleared = Decimal::ZERO;
    let mut updated_unit_ids = Vec::new();
    let mut confirmed_matches = Vec::new();

    let mut cleared_dues: Vec<String> = Vec::new();
    let mut advance_credits: Vec<(String, Decimal)> = Vec::new();

    for match_id in &payload.match_ids {
        if let Some(m) = inner.reconciliation_queue.iter_mut().find(|m| m.match_id == *match_id) {
            m.status = ReconciliationStatus::Approved;
            m.status_code = ReconciliationStatus::Approved.as_str().to_string();

            if let Some(ref unit_id) = m.matched_unit_id {
                updated_unit_ids.push(unit_id.clone());
                let txn_amount = m.transaction.amount;

                if let Some(ref due_id) = m.matched_due_id {
                    cleared_dues.push(due_id.clone());
                    let due_balance = m.outstanding_balance.unwrap_or(txn_amount);
                    if txn_amount > due_balance {
                        let surplus = txn_amount - due_balance;
                        advance_credits.push((unit_id.clone(), surplus));
                    }
                } else {
                    // No debt: full payment is matched as advance payment!
                    advance_credits.push((unit_id.clone(), txn_amount));
                }

                total_amount_cleared += txn_amount;
                confirmed_count += 1;
                confirmed_matches.push(m.clone());
            }
        }
    }

    // Now update dues liabilities without overlapping borrow
    for due_id in cleared_dues {
        if let Some(due) = inner.dues.iter_mut().find(|d| d.id == due_id) {
            due.status = DebtStatus::Paid;
        }
    }

    // Credit any surplus or zero-debt payments to advance_payments ledger
    for (unit_id, amount) in advance_credits {
        let entry = inner.advance_payments.entry(unit_id).or_insert(Decimal::ZERO);
        *entry += amount;
    }

    // Process site manager's preference to remember sender IBANs for future payments
    let mut remembered_ibans_count = 0;
    if payload.remember_sender_iban == Some(true) {
        for m in &confirmed_matches {
            if let (Some(sender_iban), Some(unit_id)) = (&m.transaction.sender_iban, &m.matched_unit_id) {
                let clean = sender_iban.replace(' ', "").to_uppercase();
                if !clean.is_empty() {
                    inner.remembered_sender_ibans.insert(clean, unit_id.clone());
                    remembered_ibans_count += 1;
                }
            }
        }
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
            remembered_ibans_count,
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
        .unwrap_or_else(|| "Ahmet Yılmaz".to_string());

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
        inner.sender_iban_metadata.insert(clean.clone(), (payload.label, payload.bank_name));
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

    get_unit_matching_criteria(Path(unit_id), State(state)).await
}

pub async fn update_unit_payer_names(
    Path(unit_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<UpdatePayerNamesRequest>,
) -> Result<Json<UnitMatchingCriteriaDto>, (StatusCode, String)> {
    {
        let mut inner = state.inner.write().await;
        if !inner.units.iter().any(|u| u.id == unit_id) {
            return Err((StatusCode::NOT_FOUND, format!("Unit '{}' not found", unit_id)));
        }
        let cleaned_names: Vec<String> = payload
            .payer_names
            .into_iter()
            .map(|n| n.trim().to_string())
            .filter(|n| !n.is_empty())
            .collect();

        inner.unit_payer_names.insert(unit_id.clone(), cleaned_names);
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
pub async fn handle_bank_incoming_webhook(
    State(state): State<AppState>,
    Json(payload): Json<BankIncomingWebhookRequest>,
) -> Result<(StatusCode, Json<BankIncomingWebhookResponse>), (StatusCode, String)> {
    let clean_viban = payload.virtual_iban.replace(' ', "").to_uppercase();
    let mut inner = state.inner.write().await;

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
                unit_index = inner.units.iter().position(|u| {
                    u.block_id.eq_ignore_ascii_case(blk) && u.unit_number == unit_no
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
            // Transaction arrived at site bank account, but cannot be automatically matched.
            // In financial & banking systems, money transfer succeeds and enters site bank account.
            // We record this in reconciliation_queue as UNMATCHED / ESLESTIRILEMEDI so the site manager can manually assign it!
            let txn_desc = payload.description.clone().unwrap_or_else(|| {
                format!("Site Ana Hesabı FAST Transferi: {}", payload.virtual_iban)
            });
            let match_id = format!("MATCH-{}", Uuid::new_v4().simple());
            let receipt_id = format!("DKN-UNM-{}", Uuid::new_v4().simple());

            inner.reconciliation_queue.push(ReconciliationMatch {
                match_id: match_id.clone(),
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
            });

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

    // 2. Check for duplicate transaction id (Idempotency Gate)
    let already_processed = inner
        .reconciliation_queue
        .iter()
        .any(|m| m.transaction.transaction_id == payload.transaction_id && m.status == ReconciliationStatus::Approved);

    if already_processed {
        let current_advance = inner
            .advance_payments
            .get(&unit.id)
            .copied()
            .unwrap_or(Decimal::ZERO);

        return Ok((
            StatusCode::OK,
            Json(BankIncomingWebhookResponse {
                status: "DUPLICATE_IGNORED".to_string(),
                transaction_id: payload.transaction_id,
                matched_unit_id: unit.id,
                matched_block: unit.block_id,
                matched_unit_number: unit.unit_number,
                cleared_due_period: None,
                cleared_amount: Decimal::ZERO,
                remaining_debt: Decimal::ZERO,
                advance_payment: current_advance,
                receipt_id: format!("DUP-{}", Uuid::new_v4().simple()),
                message: "Duplicate bank transaction notification ignored. Idempotency preserved.".to_string(),
            }),
        ));
    }

    // 3. Clear pending/overdue dues and credit surplus/advance payment
    let mut cleared_period: Option<String> = None;
    let mut cleared_amount = Decimal::ZERO;
    let mut remaining_payment = payload.amount;

    if let Some(due) = inner.dues.iter_mut().find(|d| d.unit_id == unit.id && d.status != DebtStatus::Paid) {
        if remaining_payment >= due.total_amount {
            due.status = DebtStatus::Paid;
            cleared_period = Some(due.period.clone());
            cleared_amount = due.total_amount;
            remaining_payment -= due.total_amount;
        } else {
            due.total_amount -= remaining_payment;
            cleared_period = Some(due.period.clone());
            cleared_amount = remaining_payment;
            remaining_payment = Decimal::ZERO;
        }
    }

    // Any surplus or subsequent payment is credited to unit's advance payment ledger (Avans Bakiye)
    let unit_advance = inner.advance_payments.entry(unit.id.clone()).or_insert(Decimal::ZERO);
    if remaining_payment > Decimal::ZERO {
        *unit_advance += remaining_payment;
    }
    let total_advance = *unit_advance;

    // 4. Calculate remaining debt
    let remaining_debt: Decimal = inner
        .dues
        .iter()
        .filter(|d| d.unit_id == unit.id && d.status != DebtStatus::Paid)
        .map(|d| d.total_amount)
        .sum();

    // 5. Generate immutable receipt and append to reconciliation queue
    let receipt_id = format!("DKN-2026-{}", Uuid::new_v4().simple());

    let message = if let Some(ref period) = cleared_period {
        if remaining_payment > Decimal::ZERO {
            format!(
                "₺{} dues settlement cleared for {} (Unit {} Blok D:{}). Surplus of ₺{} credited as advance payment (Avans Bakiye: ₺{}).",
                cleared_amount, period, unit.block_id, unit.unit_number, remaining_payment, total_advance
            )
        } else {
            format!(
                "₺{} dues settlement successfully cleared and matched to unit {} Blok D:{} via {}.",
                cleared_amount,
                unit.block_id,
                unit.unit_number,
                match_mechanism
            )
        }
    } else {
        format!(
            "No outstanding dues for unit {} Blok D:{}. Full payment of ₺{} credited as advance payment (Avans Bakiye: ₺{}) via {}.",
            unit.block_id,
            unit.unit_number,
            payload.amount,
            total_advance,
            match_mechanism
        )
    };

    let notes = if let Some(ref period) = cleared_period {
        if remaining_payment > Decimal::ZERO {
            let surplus_str = format!("{:.2}", remaining_payment).replace('.', ",");
            format!("{} aidatı ödendi • ₺{} avans bakiyenize aktarıldı", period, surplus_str)
        } else {
            format!("{} aidat borcu kapatıldı", period)
        }
    } else {
        "Aktif borç bulunmuyor • Avans bakiyenize aktarıldı".to_string()
    };

    let txn_desc = payload.description.unwrap_or_else(|| {
        if is_virtual_iban {
            format!("Sanal IBAN FAST Transferi: {}", payload.virtual_iban)
        } else {
            format!("Site Ana Hesabı FAST Transferi: {}", payload.virtual_iban)
        }
    });

    inner.reconciliation_queue.push(ReconciliationMatch {
        match_id: format!("MATCH-{}", Uuid::new_v4().simple()),
        transaction: BankTransactionItem {
            transaction_id: payload.transaction_id.clone(),
            date: Utc::now().date_naive(),
            amount: payload.amount,
            currency: payload.currency.unwrap_or_else(|| "TRY".to_string()),
            description: txn_desc,
            sender_name: payload.sender_name,
            sender_iban: payload.sender_iban,
            reference_no: Some(payload.transaction_id.clone()),
        },
        matched_unit_id: Some(unit.id.clone()),
        matched_block: Some(unit.block_id.clone()),
        matched_unit_number: Some(unit.unit_number),
        matched_resident_name: Some("Ahmet Yılmaz".to_string()),
        confidence_score: 100,
        matched_due_id: None,
        outstanding_balance: Some(cleared_amount),
        amount_matches_balance: true,
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
            receipt_id,
            message,
        }),
    ))
}

// Periodic Dues Accrual & Automatic Advance Balance Offsetting
pub async fn accrue_monthly_dues(
    State(state): State<AppState>,
    Json(payload): Json<AccrueDuesPeriodRequest>,
) -> Result<(StatusCode, Json<AccrueDuesPeriodResponse>), (StatusCode, String)> {
    let mut inner = state.inner.write().await;
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

    // Invariant Guard: Prevent duplicate accrual for already-accrued units
    let mut newly_accrued_units_count = 0;
    let mut total_amount_accrued = Decimal::ZERO;

    for unit in &units_in_site {
        let already_exists = inner
            .dues
            .iter()
            .any(|d| d.unit_id == unit.id && d.period == payload.period);
        if !already_exists {
            let due_id = format!("DUE-{}-{}", unit.id, Uuid::new_v4().simple());
            inner.dues.push(DuesLiability {
                id: due_id,
                unit_id: unit.id.clone(),
                period: payload.period.clone(),
                principal_amount: payload.amount,
                delay_penalty: Decimal::ZERO,
                total_amount: payload.amount,
                due_date: payload.due_date,
                status: DebtStatus::Pending,
            });
            total_amount_accrued += payload.amount;
            newly_accrued_units_count += 1;
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
    let mut inner = state.inner.write().await;

    let unit = inner
        .units
        .iter()
        .find(|u| u.id == payload.unit_id)
        .cloned();

    let unit = match unit {
        Some(u) => u,
        None => {
            return Err((
                StatusCode::NOT_FOUND,
                format!("Unit '{}' not found.", payload.unit_id),
            ));
        }
    };

    let payment_id = format!("PAY-{}", Uuid::new_v4().simple());
    let mut remaining_payment = payload.amount;
    let mut cleared_debt = Decimal::ZERO;

    // 1. Match against unpaid dues in FIFO order by due_date
    let mut unpaid_dues_indices: Vec<usize> = inner
        .dues
        .iter()
        .enumerate()
        .filter(|(_, d)| d.unit_id == unit.id && d.status != DebtStatus::Paid)
        .map(|(i, _)| i)
        .collect();

    unpaid_dues_indices.sort_by_key(|&i| inner.dues[i].due_date);

    for idx in unpaid_dues_indices {
        if remaining_payment <= Decimal::ZERO {
            break;
        }
        let due = &mut inner.dues[idx];
        if remaining_payment >= due.total_amount {
            cleared_debt += due.total_amount;
            remaining_payment -= due.total_amount;
            due.status = DebtStatus::Paid;
        } else {
            due.principal_amount -= remaining_payment;
            due.total_amount -= remaining_payment;
            cleared_debt += remaining_payment;
            remaining_payment = Decimal::ZERO;
        }
    }

    // 2. If there is remaining payment (or if unit had no debt), credit to advance_payments!
    let advance_credit = remaining_payment;
    if advance_credit > Decimal::ZERO {
        let entry = inner.advance_payments.entry(unit.id.clone()).or_insert(Decimal::ZERO);
        *entry += advance_credit;
    }

    let total_unit_advance = inner.advance_payments.get(&unit.id).copied().unwrap_or(Decimal::ZERO);

    let remaining_debt: Decimal = inner
        .dues
        .iter()
        .filter(|d| d.unit_id == unit.id && d.status != DebtStatus::Paid)
        .map(|d| d.total_amount)
        .sum();

    let match_status = if cleared_debt > Decimal::ZERO && advance_credit > Decimal::ZERO {
        PaymentMatchStatus::PartiallyMatched
    } else if cleared_debt > Decimal::ZERO {
        PaymentMatchStatus::MatchedDebt
    } else {
        PaymentMatchStatus::MatchedAdvance
    };

    let message = if cleared_debt > Decimal::ZERO && advance_credit > Decimal::ZERO {
        format!(
            "₺{} aidat borcu ödendi, kalan ₺{} avans bakiyesine aktarıldı (Mevcut Avans: ₺{}).",
            cleared_debt, advance_credit, total_unit_advance
        )
    } else if cleared_debt > Decimal::ZERO {
        format!("₺{} tutarındaki aidat borcu başarıyla kapatıldı.", cleared_debt)
    } else {
        format!(
            "Aktif aidat borcu bulunmuyor. ₺{} tutarındaki ödeme avans bakiyenize eklendi (Mevcut Avans: ₺{}).",
            advance_credit, total_unit_advance
        )
    };

    // Store in homeowner_payments ledger
    let record = HomeownerPaymentRecord {
        id: payment_id.clone(),
        unit_id: unit.id.clone(),
        block_id: unit.block_id.clone(),
        unit_number: unit.unit_number,
        homeowner_name: payload.homeowner_name.or_else(|| {
            unit.owner_user_id.as_ref().and_then(|uid| {
                inner.users.iter().find(|u| &u.id == uid).map(|u| u.full_name.clone())
            })
        }),
        amount: payload.amount,
        payment_method: payload.payment_method.clone(),
        reference_code: payload.reference_code.clone(),
        note: payload.note.clone(),
        status: match_status,
        cleared_debt_amount: cleared_debt,
        advance_credit_amount: advance_credit,
        created_at: Utc::now(),
    };

    let resident_name = inner.users.iter().find(|u| u.id == unit.id).map(|u| u.full_name.clone());

    inner.homeowner_payments.push(record);

    // Also record in reconciliation_queue as an approved digital receipt
    let receipt_id = format!("RCP-{}", Uuid::new_v4().simple());
    inner.reconciliation_queue.push(ReconciliationMatch {
        match_id: format!("MATCH-{}", Uuid::new_v4().simple()),
        transaction: BankTransactionItem {
            transaction_id: payload.reference_code.unwrap_or_else(|| payment_id.clone()),
            date: Utc::now().date_naive(),
            amount: payload.amount,
            currency: "TRY".to_string(),
            description: payload.note.unwrap_or_else(|| {
                if payload.payment_method.to_uppercase().contains("CARD") || payload.payment_method.to_uppercase().contains("KART") {
                    "Kredi Kartı ile Aidat Ödemesi".to_string()
                } else {
                    format!("{} ile Aidat Ödemesi", payload.payment_method)
                }
            }),
            sender_name: resident_name.clone(),
            sender_iban: None,
            reference_no: Some(receipt_id),
        },
        matched_unit_id: Some(unit.id.clone()),
        matched_block: Some(unit.block_id.clone()),
        matched_unit_number: Some(unit.unit_number),
        matched_resident_name: resident_name,
        confidence_score: 100,
        matched_due_id: None,
        outstanding_balance: Some(cleared_debt),
        amount_matches_balance: cleared_debt == payload.amount,
        status: ReconciliationStatus::Approved,
        status_code: ReconciliationStatus::Approved.as_str().to_string(),
        notes: Some(message.clone()),
    });

    Ok((
        StatusCode::OK,
        Json(RecordHomeownerPaymentResponse {
            payment_id,
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
    let mut inner = state.inner.write().await;

    let target_site_id = payload.site_id.unwrap_or_else(|| "site-1".to_string());
    let mut total_processed = 0;
    let mut total_cleared = Decimal::ZERO;
    let mut total_advance = Decimal::ZERO;
    let mut matched_debts_count = 0;
    let mut matched_advance_count = 0;

    let site_unit_ids: Vec<String> = inner
        .units
        .iter()
        .filter(|u| u.site_id == target_site_id)
        .map(|u| u.id.clone())
        .collect();

    for i in 0..inner.homeowner_payments.len() {
        if !site_unit_ids.contains(&inner.homeowner_payments[i].unit_id) {
            continue;
        }

        if inner.homeowner_payments[i].status != PaymentMatchStatus::Pending {
            continue;
        }

        let unit_id = inner.homeowner_payments[i].unit_id.clone();
        let mut remaining = inner.homeowner_payments[i].amount;
        let mut cleared = Decimal::ZERO;

        // Match against unpaid debts (FIFO by due date)
        let mut unpaid_dues_indices: Vec<usize> = inner
            .dues
            .iter()
            .enumerate()
            .filter(|(_, d)| d.unit_id == unit_id && d.status != DebtStatus::Paid)
            .map(|(idx, _)| idx)
            .collect();
        unpaid_dues_indices.sort_by_key(|&idx| inner.dues[idx].due_date);

        for idx in unpaid_dues_indices {
            if remaining <= Decimal::ZERO {
                break;
            }
            let due = &mut inner.dues[idx];
            if remaining >= due.total_amount {
                cleared += due.total_amount;
                remaining -= due.total_amount;
                due.status = DebtStatus::Paid;
            } else {
                due.principal_amount -= remaining;
                due.total_amount -= remaining;
                cleared += remaining;
                remaining = Decimal::ZERO;
            }
        }

        let advance = remaining;
        if advance > Decimal::ZERO {
            let entry = inner.advance_payments.entry(unit_id.clone()).or_insert(Decimal::ZERO);
            *entry += advance;
            total_advance += advance;
            matched_advance_count += 1;
        }

        if cleared > Decimal::ZERO {
            total_cleared += cleared;
            matched_debts_count += 1;
        }

        let new_status = if cleared > Decimal::ZERO && advance > Decimal::ZERO {
            PaymentMatchStatus::PartiallyMatched
        } else if cleared > Decimal::ZERO {
            PaymentMatchStatus::MatchedDebt
        } else {
            PaymentMatchStatus::MatchedAdvance
        };

        inner.homeowner_payments[i].status = new_status;
        inner.homeowner_payments[i].cleared_debt_amount = cleared;
        inner.homeowner_payments[i].advance_credit_amount = advance;
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


