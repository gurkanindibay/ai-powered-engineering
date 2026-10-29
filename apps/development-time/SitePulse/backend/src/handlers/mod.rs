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
                house_type: Some("2+1".to_string()),
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

    let site_name = inner
        .sites
        .iter()
        .find(|s| s.id == unit.site_id)
        .map(|s| s.name.clone())
        .unwrap_or_else(|| "Site".to_string());
    let site_title = format!("{} • {} Blok D:{}", site_name, unit.block_id, unit.unit_number);
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

pub async fn update_home_owner(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::UpdateHomeOwnerRequest>,
) -> Result<Json<HomeOwnerResponse>, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
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
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
    let service = SiteAdminService::new(state);
    service
        .delete_home_owner(&site_id, &id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn move_out_resident(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::MoveOutResidentRequest>,
) -> Result<Json<crate::models::OccupancyHistoryItem>, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
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
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
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
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
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
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
    let service = SiteAdminService::new(state);
    Json(service.get_house_types_for_site(&site_id).await)
}

pub async fn create_house_type(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::CreateHouseTypeRequest>,
) -> Result<(StatusCode, Json<crate::models::HouseTypeTariff>), (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
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
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
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
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
    let service = SiteAdminService::new(state);
    Json(service.get_blocks_for_site(&site_id).await)
}

pub async fn create_block(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::CreateBlockRequest>,
) -> Result<(StatusCode, Json<crate::models::BlockDto>), (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
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

pub async fn delete_unit_member(
    State(state): State<AppState>,
    Path((unit_id, resident_id)): Path<(String, String)>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
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
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
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

    // Step 1: Update queue items and collect details to process
    let mut to_process = Vec::new();
    for match_id in &payload.match_ids {
        if let Some(m) = inner.reconciliation_queue.iter_mut().find(|m| m.match_id == *match_id) {
            m.status = ReconciliationStatus::Approved;
            m.status_code = ReconciliationStatus::Approved.as_str().to_string();

            if let Some(ref unit_id) = m.matched_unit_id {
                to_process.push((
                    unit_id.clone(),
                    m.transaction.amount,
                    m.matched_due_id.clone(),
                    m.outstanding_balance,
                    m.transaction.description.clone(),
                    m.clone(),
                ));
            }
        }
    }

    // Step 2: Now resolve dues and advance credits without holding borrow on queue
    for (unit_id, txn_amount, matched_due_id, outstanding_bal, desc, m_clone) in to_process {
        updated_unit_ids.push(unit_id.clone());

        if let Some(ref due_id) = matched_due_id {
            cleared_dues.push(due_id.clone());
            let due_balance = outstanding_bal.unwrap_or(txn_amount);
            if txn_amount > due_balance {
                let surplus = txn_amount - due_balance;
                advance_credits.push((unit_id.clone(), surplus));
            }
        } else {
            let desc_lower = desc.to_lowercase();
            let matching_unpaid_due = inner.dues.iter()
                .find(|d| d.unit_id == unit_id && d.status != DebtStatus::Paid && desc_lower.contains(&d.period.to_lowercase()))
                .or_else(|| inner.dues.iter().find(|d| d.unit_id == unit_id && d.status != DebtStatus::Paid))
                .map(|d| (d.id.clone(), d.total_amount));

            if let Some((due_id, due_balance)) = matching_unpaid_due {
                cleared_dues.push(due_id);
                if txn_amount > due_balance {
                    let surplus = txn_amount - due_balance;
                    advance_credits.push((unit_id.clone(), surplus));
                }
            } else {
                advance_credits.push((unit_id.clone(), txn_amount));
            }
        }

        total_amount_cleared += txn_amount;
        confirmed_count += 1;
        confirmed_matches.push(m_clone);
    }

    // Now update dues liabilities without overlapping borrow
    for due_id in &cleared_dues {
        if let Some(due) = inner.dues.iter_mut().find(|d| d.id == *due_id) {
            due.status = DebtStatus::Paid;
        }
    }

    // Credit any surplus or zero-debt payments to advance_payments ledger
    for (unit_id, amount) in advance_credits {
        let entry = inner.advance_payments.entry(unit_id).or_insert(Decimal::ZERO);
        *entry += amount;
    }

    // Auto-offset any available advance against pending debts
    apply_advance_payments_offset(&mut inner, None);

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

    if let Some(ref pool) = state.pool {
        let pool = pool.clone();
        let matches_to_save: Vec<(String, Option<String>, Option<String>, Decimal, Option<String>, String)> = confirmed_matches
            .iter()
            .map(|m| {
                (
                    format!("txn-{}", Uuid::new_v4().simple()),
                    m.matched_due_id.clone(),
                    m.matched_unit_id.clone(),
                    m.transaction.amount,
                    m.transaction.reference_no.clone(),
                    m.transaction.description.clone(),
                )
            })
            .collect();
        let cleared = cleared_dues.clone();
        let confirmed_status_updates: Vec<(String, String, Option<String>)> = confirmed_matches
            .iter()
            .map(|m| (m.match_id.clone(), m.status_code.clone(), m.notes.clone()))
            .collect();
        let updated_advances: Vec<(String, Decimal)> = updated_unit_ids
            .iter()
            .map(|uid| (uid.clone(), inner.advance_payments.get(uid).copied().unwrap_or(Decimal::ZERO)))
            .collect();
        let remembered_to_save: Vec<(String, String)> = if payload.remember_sender_iban == Some(true) {
            confirmed_matches
                .iter()
                .filter_map(|m| {
                    if let (Some(sender_iban), Some(unit_id)) = (&m.transaction.sender_iban, &m.matched_unit_id) {
                        let clean = sender_iban.replace(' ', "").to_uppercase();
                        if !clean.is_empty() {
                            return Some((unit_id.clone(), clean));
                        }
                    }
                    None
                })
                .collect()
        } else {
            Vec::new()
        };

        tokio::spawn(async move {
            for (txn_id, due_id, unit_id, amt, ref_no, desc) in matches_to_save {
                let _ = crate::db::save_collection_transaction(
                    &pool,
                    &txn_id,
                    due_id.as_deref(),
                    unit_id.as_deref(),
                    "BANK_STATEMENT",
                    amt,
                    ref_no.as_deref(),
                    Some(&desc),
                ).await;
            }
            for d_id in cleared {
                let _ = crate::db::update_due_liability(&pool, &d_id, "PAID", Decimal::ZERO).await;
            }
            for (match_id, status_code, notes) in confirmed_status_updates {
                let _ = crate::db::update_reconciliation_status(
                    &pool,
                    &match_id,
                    "Approved",
                    &status_code,
                    notes.as_deref(),
                ).await;
            }
            for (uid, bal) in updated_advances {
                let _ = crate::db::save_advance_balance(&pool, &uid, bal).await;
            }
            for (uid, iban) in remembered_to_save {
                let _ = crate::db::save_remembered_sender_iban(&pool, &uid, &iban, None, None).await;
            }
        });
    }

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

    if let Some(ref pool) = state.pool {
        let pool = pool.clone();
        let u_id = payload.unit_id.clone();
        let s_iban = clean.clone();
        let s_name = payload.sender_name.clone();
        tokio::spawn(async move {
            let _ = crate::db::save_remembered_sender_iban(&pool, &u_id, &s_iban, s_name.as_deref(), None).await;
        });
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
        let pool = pool.clone();
        let u_id = unit_id.clone();
        let s_iban = clean.clone();
        let lbl = payload.label.clone();
        let bnk = payload.bank_name.clone();
        tokio::spawn(async move {
            let _ = crate::db::save_remembered_sender_iban(&pool, &u_id, &s_iban, lbl.as_deref(), bnk.as_deref()).await;
        });
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
        let pool = pool.clone();
        let s_iban = clean.clone();
        tokio::spawn(async move {
            let _ = crate::db::delete_remembered_sender_iban(&pool, &s_iban).await;
        });
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
        let pool = pool.clone();
        let u_id = unit_id.clone();
        let names = cleaned_names.clone();
        tokio::spawn(async move {
            let _ = crate::db::save_unit_payer_names(&pool, &u_id, &names).await;
        });
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

    // Check if narrative mentions a specific period
    let desc_str = payload.description.as_deref().unwrap_or("").to_lowercase();
    let target_due_idx = inner.dues.iter().position(|d| {
        d.unit_id == unit.id && d.status != DebtStatus::Paid && desc_str.contains(&d.period.to_lowercase())
    }).or_else(|| {
        inner.dues.iter().position(|d| d.unit_id == unit.id && d.status != DebtStatus::Paid)
    });
    let target_due_id = target_due_idx.map(|idx| inner.dues[idx].id.clone());

    if let Some(idx) = target_due_idx {
        let due = &mut inner.dues[idx];
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

    // Also auto-offset any advance against remaining unpaid dues
    apply_advance_payments_offset(&mut inner, Some(&unit.id));
    let total_advance = inner.advance_payments.get(&unit.id).copied().unwrap_or(Decimal::ZERO);

    // Persist to PostgreSQL database (STORY-05-01 / Financial Ledger)
    if let Some(ref pool) = state.pool {
        let pool = pool.clone();
        let txn_id = format!("txn-{}", Uuid::new_v4().simple());
        let due_id = target_due_id.clone();
        let unit_id = unit.id.clone();
        let amount = payload.amount;
        let ref_code = payload.transaction_id.clone();
        let desc = payload.description.clone().unwrap_or_else(|| format!("FAST Bank Transfer: {}", unit_id));
        tokio::spawn(async move {
            let _ = crate::db::save_collection_transaction(
                &pool,
                &txn_id,
                due_id.as_deref(),
                Some(&unit_id),
                "BANK_TRANSFER",
                amount,
                Some(&ref_code),
                Some(&desc),
            ).await;
            if let Some(ref d_id) = due_id {
                let _ = crate::db::update_due_liability(
                    &pool,
                    d_id,
                    "PAID",
                    amount,
                ).await;
            }
        });
    }

    // 4. Calculate remaining debt
    let remaining_debt: Decimal = inner
        .dues
        .iter()
        .filter(|d| d.unit_id == unit.id && d.status != DebtStatus::Paid)
        .map(|d| d.total_amount)
        .sum();

    // 5. Generate immutable receipt and append to reconciliation queue
    let receipt_id = format!("DKN-2026-{}", Uuid::new_v4().simple());

    let unit_block_desc = if unit.block_id.contains("Blok") {
        unit.block_id.clone()
    } else {
        format!("{} Blok", unit.block_id)
    };

    let message = if let Some(ref period) = cleared_period {
        if remaining_payment > Decimal::ZERO {
            format!(
                "₺{} dues settlement cleared for {} (Unit {} D:{}). Surplus of ₺{} credited as advance payment (Avans Bakiye: ₺{}).",
                cleared_amount, period, unit_block_desc, unit.unit_number, remaining_payment, total_advance
            )
        } else {
            format!(
                "₺{} dues settlement successfully cleared and matched to unit {} D:{} via {}.",
                cleared_amount,
                unit_block_desc,
                unit.unit_number,
                match_mechanism
            )
        }
    } else {
        format!(
            "No outstanding dues for unit {} D:{}. Full payment of ₺{} credited as advance payment (Avans Bakiye: ₺{}) via {}.",
            unit_block_desc,
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

    let matched_resident_name = unit
        .owner_user_id
        .as_ref()
        .and_then(|uid| inner.users.iter().find(|u| &u.id == uid))
        .map(|u| u.full_name.clone());

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
        matched_resident_name,
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

    let new_period = DuesPeriod {
        id: format!("PER-{}", Uuid::new_v4().simple()),
        site_id: payload.site_id.clone(),
        period_name: payload.period_name.clone(),
        due_date: payload.due_date,
        status: "ACTIVE".to_string(),
        created_at: Some(chrono::Utc::now()),
    };

    inner.dues_periods.push(new_period.clone());

    if let Some(ref pool) = state.pool {
        let pool = pool.clone();
        let p_save = new_period.clone();
        tokio::spawn(async move {
            let _ = crate::db::save_dues_period(&pool, &p_save).await;
        });
    }

    Ok((StatusCode::CREATED, Json(new_period)))
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

    // Ensure period is stored in the separate dues_periods table
    let period_exists = inner.dues_periods.iter().any(|p| {
        (p.site_id == payload.site_id || crate::db::parse_id_to_i64(&p.site_id) == crate::db::parse_id_to_i64(&payload.site_id))
            && p.period_name.eq_ignore_ascii_case(&payload.period)
    });
    if !period_exists {
        let period_record = DuesPeriod {
            id: format!("PER-{}", Uuid::new_v4().simple()),
            site_id: payload.site_id.clone(),
            period_name: payload.period.clone(),
            due_date: payload.due_date,
            status: "ACTIVE".to_string(),
            created_at: Some(chrono::Utc::now()),
        };
        inner.dues_periods.push(period_record.clone());
        if let Some(ref pool) = state.pool {
            let pool = pool.clone();
            let p_save = period_record.clone();
            tokio::spawn(async move {
                let _ = crate::db::save_dues_period(&pool, &p_save).await;
            });
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

            let due_id = format!("DUE-{}-{}", unit.id, Uuid::new_v4().simple());
            inner.dues.push(DuesLiability {
                id: due_id,
                unit_id: unit.id.clone(),
                period: payload.period.clone(),
                principal_amount: effective_amount,
                delay_penalty: Decimal::ZERO,
                total_amount: effective_amount,
                due_date: payload.due_date,
                status: DebtStatus::Pending,
            });
            total_amount_accrued += effective_amount;
            newly_accrued_units_count += 1;
        }
    }

    if let Some(ref pool) = state.pool {
        let pool = pool.clone();
        let dues_to_save: Vec<DuesLiability> = inner
            .dues
            .iter()
            .filter(|d| d.period == payload.period)
            .cloned()
            .collect();
        tokio::spawn(async move {
            for due in dues_to_save {
                let _ = crate::db::save_due_liability(&pool, &due).await;
            }
        });
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

    let resident_name = record.homeowner_name.clone();

    inner.homeowner_payments.push(record.clone());

    let receipt_id = format!("RCP-{}", Uuid::new_v4().simple());

    if let Some(ref pool) = state.pool {
        let pool = pool.clone();
        let txn_id = format!("txn-{}", Uuid::new_v4().simple());
        let unit_id = unit.id.clone();
        let amount = payload.amount;
        let ref_code = payload.reference_code.clone();
        let note = payload.note.clone();
        let matched_due_id = inner
            .dues
            .iter()
            .find(|d| d.unit_id == unit_id && d.status == DebtStatus::Paid)
            .map(|d| d.id.clone());
        let rec = record.clone();
        let adv_bal = total_unit_advance;
        let receipt_id_clone = receipt_id.clone();
        let res_name_clone = resident_name.clone();
        let msg_clone = message.clone();
        let p_method = payload.payment_method.clone();
        let is_card = p_method.to_uppercase().contains("CARD") || p_method.to_uppercase().contains("KART");

        tokio::spawn(async move {
            let _ = crate::db::save_homeowner_payment(&pool, &rec).await;
            let _ = crate::db::save_advance_balance(&pool, &unit_id, adv_bal).await;

            let r_match = ReconciliationMatch {
                match_id: format!("MATCH-{}", Uuid::new_v4().simple()),
                transaction: BankTransactionItem {
                    transaction_id: ref_code.clone().unwrap_or_else(|| rec.id.clone()),
                    date: Utc::now().date_naive(),
                    amount,
                    currency: "TRY".to_string(),
                    description: note.clone().unwrap_or_else(|| {
                        if is_card {
                            "Kredi Kartı ile Aidat Ödemesi".to_string()
                        } else {
                            format!("{} ile Aidat Ödemesi", p_method)
                        }
                    }),
                    sender_name: res_name_clone.clone(),
                    sender_iban: None,
                    reference_no: Some(receipt_id_clone),
                },
                matched_unit_id: Some(rec.unit_id.clone()),
                matched_block: Some(rec.block_id.clone()),
                matched_unit_number: Some(rec.unit_number),
                matched_resident_name: res_name_clone,
                confidence_score: 100,
                matched_due_id: None,
                outstanding_balance: Some(cleared_debt),
                amount_matches_balance: cleared_debt == amount,
                status: ReconciliationStatus::Approved,
                status_code: ReconciliationStatus::Approved.as_str().to_string(),
                notes: Some(msg_clone),
            };
            let _ = crate::db::save_reconciliation_match(&pool, &r_match).await;

            let _ = crate::db::save_collection_transaction(
                &pool,
                &txn_id,
                matched_due_id.as_deref(),
                Some(&unit_id),
                "ONLINE_PAYMENT",
                amount,
                ref_code.as_deref(),
                note.as_deref(),
            ).await;
            if let Some(ref d_id) = matched_due_id {
                let _ = crate::db::update_due_liability(
                    &pool,
                    d_id,
                    "PAID",
                    amount,
                ).await;
            }
        });
    }

    // Also record in reconciliation_queue as an approved digital receipt
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

    if let Some(ref pool) = state.pool {
        let pool = pool.clone();
        let updated_records: Vec<(String, String, Decimal, Decimal)> = inner
            .homeowner_payments
            .iter()
            .filter(|p| site_unit_ids.contains(&p.unit_id))
            .map(|p| (p.id.clone(), format!("{:?}", p.status), p.cleared_debt_amount, p.advance_credit_amount))
            .collect();
        let unit_advances: Vec<(String, Decimal)> = site_unit_ids
            .iter()
            .map(|uid| (uid.clone(), inner.advance_payments.get(uid).copied().unwrap_or(Decimal::ZERO)))
            .collect();
        tokio::spawn(async move {
            for (pid, st, clr, adv) in updated_records {
                let _ = crate::db::update_homeowner_payment_match(&pool, &pid, &st, clr, adv).await;
            }
            for (uid, bal) in unit_advances {
                let _ = crate::db::save_advance_balance(&pool, &uid, bal).await;
            }
        });
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
        let _ = crate::db::reset_db_to_seed_data(pool).await;
    }
    let mut inner = state.inner.write().await;
    inner.reset_all_payments_and_balances();
    if let Some(ref pool) = state.pool {
        crate::db::load_all_from_db(pool, &mut inner).await;
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
        let _ = crate::db::seed_test_data(pool).await;
        let mut inner = state.inner.write().await;
        crate::db::load_all_from_db(pool, &mut inner).await;
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
        let _ = crate::db::reset_db_to_seed_data(pool).await;
    }
    let mut inner = state.inner.write().await;
    inner.clear_all_data();
    if let Some(ref pool) = state.pool {
        crate::db::load_all_from_db(pool, &mut inner).await;
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
    inner.reset_all_payments_and_balances();
    if let Some(ref pool) = state.pool {
        crate::db::load_all_from_db(pool, &mut inner).await;
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

    let mut inner = state.inner.write().await;

    // 1. Resolve or register target site
    let site_id = if let Some(ref s_id) = payload.site_id {
        if inner.sites.iter().any(|s| &s.id == s_id) {
            s_id.clone()
        } else {
            let s_name = payload.site_name.clone().unwrap_or_else(|| "Yeni Yaşam Sitesi".to_string());
            let slug = crate::services::to_slug(&s_name);
            inner.sites.push(Site {
                id: s_id.clone(),
                name: s_name.clone(),
                address: "Ataşehir, İstanbul".to_string(),
                slug,
                status: "ACTIVE".to_string(),
                plan_type: "PREMIUM".to_string(),
                license_end_date: Utc::now().date_naive() + chrono::Days::new(365),
            });
            s_id.clone()
        }
    } else if let Some(ref s_name) = payload.site_name {
        let s_id = format!("site-{}", &uuid::Uuid::new_v4().to_string()[..8]);
        let slug = crate::services::to_slug(s_name);
        inner.sites.push(Site {
            id: s_id.clone(),
            name: s_name.clone(),
            address: "Kadıköy, İstanbul".to_string(),
            slug,
            status: "ACTIVE".to_string(),
            plan_type: "PREMIUM".to_string(),
            license_end_date: Utc::now().date_naive() + chrono::Days::new(365),
        });
        s_id
    } else if let Some(first_site) = inner.sites.first() {
        first_site.id.clone()
    } else {
        let s_id = "site-1".to_string();
        inner.sites.push(Site {
            id: s_id.clone(),
            name: "Begonya Sitesi".to_string(),
            address: "Ataşehir, Begonya Sok. No:14, İstanbul".to_string(),
            slug: "begonya-sitesi".to_string(),
            status: "ACTIVE".to_string(),
            plan_type: "PREMIUM".to_string(),
            license_end_date: Utc::now().date_naive() + chrono::Days::new(365),
        });
        s_id
    };

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
        let unit_id = format!("d-{}", i);
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

        let user_id = format!("usr-{}-{}", &site_id, i);

        // Add or update resident user
        if let Some(existing_user) = inner.users.iter_mut().find(|u| u.id == user_id) {
            existing_user.full_name = resident_name.clone();
            existing_user.email = email.clone();
            existing_user.phone = phone.clone();
        } else {
            inner.users.push(User {
                id: user_id.clone(),
                site_id: site_id.clone(),
                full_name: resident_name.clone(),
                email: email.clone(),
                phone: phone.clone(),
                password_hash: Some("ARGON2_HASH_123456".to_string()),
                role: Role::HomeOwner,
                must_change_password: false,
                auth_provider: "LOCAL".to_string(),
                google_sub: None,
                avatar_url: None,
                created_at: Utc::now(),
            });
        }

        // Add or update independent flat
        if let Some(existing_unit) = inner.units.iter_mut().find(|u| u.id == unit_id) {
            existing_unit.site_id = site_id.clone();
            existing_unit.block_id = block_name.clone();
            existing_unit.unit_number = unit_number;
            existing_unit.floor = floor;
            existing_unit.owner_user_id = Some(user_id.clone());
            existing_unit.virtual_iban = Some(virtual_iban.clone());
        } else {
            inner.units.push(IndependentUnit {
                id: unit_id.clone(),
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
        }

        // Matching criteria & sender IBAN
        inner.unit_payer_names.insert(unit_id.clone(), vec![resident_name.clone()]);
        let sample_sender_iban = format!("TR{:02}000620000000000000{:04}", (i % 80) + 10, i);
        inner.remembered_sender_ibans.insert(sample_sender_iban.clone(), unit_id.clone());
        inner.sender_iban_metadata.insert(
            sample_sender_iban.clone(),
            (Some(format!("Garanti BBVA - {}", resident_name)), Some("Garanti BBVA".to_string())),
        );

        // Optional dues accrual
        if accrue_dues {
            let due_id = format!("b-{}-{}", unit_id, crate::services::to_slug(&dues_period));
            if !inner.dues.iter().any(|d| d.id == due_id) {
                inner.dues.push(DuesLiability {
                    id: due_id,
                    unit_id: unit_id.clone(),
                    period: dues_period.clone(),
                    principal_amount: monthly_dues,
                    delay_penalty: Decimal::ZERO,
                    total_amount: monthly_dues,
                    due_date: Utc::now().date_naive() + chrono::Days::new(15),
                    status: DebtStatus::Pending,
                });
            }
        }

        // Auto-offset against any pre-existing advance balance for this unit
        apply_advance_payments_offset(&mut inner, Some(&unit_id));

        let current_debt: Decimal = inner.dues.iter()
            .filter(|d| d.unit_id == unit_id && d.status != DebtStatus::Paid)
            .map(|d| d.total_amount)
            .sum();
        let advance = inner.advance_payments.get(&unit_id).copied().unwrap_or(Decimal::ZERO);

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
        let pool = pool.clone();
        let units_to_save: Vec<IndependentUnit> = inner.units.clone();
        let dues_to_save: Vec<DuesLiability> = inner.dues.clone();
        tokio::spawn(async move {
            for u in units_to_save {
                let _ = crate::db::save_unit(&pool, &u).await;
            }
            for d in dues_to_save {
                let _ = crate::db::save_due_liability(&pool, &d).await;
            }
        });
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
        let advance = inner.advance_payments.get(&unit.id).copied().unwrap_or(Decimal::ZERO);

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
        .map(|u| inner.advance_payments.get(&u.id).copied().unwrap_or(Decimal::ZERO))
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
    apply_advance_payments_offset(&mut inner, None);

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

    available_periods.sort_by(|a, b| period_sort_key(b).cmp(&period_sort_key(a)));

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
        let advance = inner.advance_payments.get(&unit.id).copied().unwrap_or(Decimal::ZERO);
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
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
    let service = crate::services::PaymentTrackingService::new(state);
    Json(service.get_debt_aging_report(&site_id).await)
}

pub async fn record_manual_payment(
    State(state): State<AppState>,
    Json(payload): Json<crate::models::RecordManualPaymentRequest>,
) -> Result<(StatusCode, Json<crate::models::PaymentReceipt>), (StatusCode, String)> {
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

pub async fn get_payment_receipt(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<crate::models::PaymentReceipt>, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
    let service = crate::services::PaymentTrackingService::new(state);
    service
        .get_receipt(&site_id, &id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::NOT_FOUND, e))
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
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
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


