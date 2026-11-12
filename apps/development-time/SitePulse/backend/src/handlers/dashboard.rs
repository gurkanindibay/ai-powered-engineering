//! Resident dashboard and site manager overview (read-only views).

use super::*;

fn site_ids_match(left: &str, right: &str) -> bool {
    left == right
        || matches!(
            (
                crate::db::parse_id_to_i64(left),
                crate::db::parse_id_to_i64(right)
            ),
            (Some(left_id), Some(right_id)) if left_id == right_id
        )
}

fn overdue_days(due_date: chrono::NaiveDate, today: chrono::NaiveDate, is_paid: bool) -> i32 {
    if is_paid {
        return 0;
    }

    (today - due_date).num_days().clamp(0, i64::from(i32::MAX)) as i32
}

/// (billed, collected) for one due in the period's collection stats.
///
/// Both sides use principal only: delay penalties are not part of the billed
/// amount, so counting a paid penalty as collected would push the collection
/// rate above 100%.
fn collection_amounts(principal: Decimal, paid_principal: Decimal) -> (Decimal, Decimal) {
    (principal, paid_principal.min(principal).max(Decimal::ZERO))
}

pub(crate) fn format_resident_transaction_display(m: &ReconciliationMatch) -> (String, String) {
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
        || (m.matched_due_id.is_none()
            && !note.contains("Settled")
            && (note.contains("advance payment") || note.contains("avans bakiyenize eklendi")))
    {
        let title = if is_card {
            "Kart ile Avans Yükleme".to_string()
        } else {
            "FAST ile Avans Yükleme".to_string()
        };
        let subtitle = "Aktif borç bulunmuyor • Avans bakiyenize aktarıldı".to_string();
        return (title, subtitle);
    }

    // Case 2: Settled dues (with or without surplus)
    if note.contains("Settled")
        || note.contains("aidat")
        || note.contains("Aidat")
        || m.matched_due_id.is_some()
        || desc_upper.contains("AIDAT")
    {
        let title = if is_card {
            "Kart ile Aidat Ödemesi".to_string()
        } else {
            "FAST ile Aidat Ödemesi".to_string()
        };

        let subtitle = if note.contains("surplus")
            || note.contains("artan")
            || note.contains("avans bakiyenize")
            || note.contains("avans bakiyesine")
        {
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
                    format!(
                        "{} aidatı ödendi • {} avans bakiyenize aktarıldı",
                        period, surplus_formatted
                    )
                } else {
                    format!(
                        "{} aidatı ödendi • Kalan tutar avans bakiyenize aktarıldı",
                        period
                    )
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
        } else if note.contains("aidat borcu kapatıldı")
            || note.contains("aidat borcu başarıyla kapatıldı")
        {
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
    ctx: crate::authorization::AuthzContext,
) -> impl IntoResponse {
    let calc_service = DuesCalculationService::new();
    // Read-only view: the global lock is taken for reading only and never held
    // across database I/O.
    let cached_unit = {
        let inner = state.inner.read().await;
        inner
            .units
            .iter()
            .find(|u| crate::auth::same_id(&u.id, &unit_id))
            .cloned()
    };

    let unit_opt = if let Some(u) = cached_unit {
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
                    site_id: s_id.map(|s| s.to_string()).unwrap_or_default(),
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
            return (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({
                    "status": "ERROR",
                    "message": format!("Unit '{}' not found in database", unit_id)
                })),
            )
                .into_response();
        }
    };

    // A GET never moves money: advance offsets run on the write paths
    // that create liabilities (accruals) through `settle_advances`.
    let inner = state.inner.read().await;

    let today = Utc::now().date_naive();
    let evaluated_dues: Vec<DuesLiability> = inner
        .dues
        .iter()
        .filter(|d| d.unit_id == unit_id && d.status != DebtStatus::Paid)
        .map(|d| calc_service.calculate_delay_penalty(d.clone(), today))
        .collect();

    let total_debt: Decimal = evaluated_dues.iter().map(|d| d.total_amount).sum();
    let is_overdue = evaluated_dues
        .iter()
        .any(|d| d.status == DebtStatus::Overdue);

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
    let site_title = format!(
        "{} • {}",
        site_name,
        inner.unit_label(&unit.block_id, unit.unit_number)
    );
    let advance_payment = inner.advance_total(&unit_id);

    let mut transactions: Vec<AccountTransactionDto> = Vec::new();

    // 1. Approved bank transactions from reconciliation queue for this unit
    for m in inner.reconciliation_queue.iter().rev() {
        if m.matched_unit_id.as_deref() == Some(&unit_id)
            && m.status == ReconciliationStatus::Approved
        {
            let (title, subtitle) = format_resident_transaction_display(m);
            // The receipt the ledger issued for this bank transaction, not the bank's id.
            let receipt_number = inner
                .payment_entries
                .iter()
                .filter(|e| {
                    crate::auth::same_id(&e.unit_id, &unit_id)
                        && e.entry_type == LEDGER_KIND_COLLECTION
                })
                .find(|e| {
                    e.external_reference.as_deref().is_some_and(|r| {
                        r == m.transaction.transaction_id
                            || Some(r) == m.transaction.reference_no.as_deref()
                    })
                })
                .and_then(|e| e.receipt_number.clone());
            transactions.push(AccountTransactionDto {
                id: m.transaction.transaction_id.clone(),
                title,
                subtitle,
                amount: m.transaction.amount,
                date: m.transaction.date.format("%d.%m.%Y").to_string(),
                is_credit: true,
                receipt_number,
            });
        }
    }

    // 2. If dues are unpaid/pending, show current dues as debit (negative)
    for due in &evaluated_dues {
        if due.delay_penalty > Decimal::ZERO {
            // Principal dues row
            transactions.push(AccountTransactionDto {
                id: due.id.clone(),
                title: format!("{} Aidatı", due.period),
                subtitle: if is_overdue {
                    "Gecikmeli Aidat Borcu"
                } else {
                    "Ödeme Bekleniyor"
                }
                .to_string(),
                amount: due.principal_amount,
                date: due.due_date.format("%d.%m.%Y").to_string(),
                is_credit: false,
                receipt_number: None,
            });
            // Itemized KMK delay penalty row
            transactions.push(AccountTransactionDto {
                id: format!("{}-penalty", due.id),
                title: "KMK Gecikme Tazminatı".to_string(),
                subtitle: format!("{} Gecikme Zammı", due.period),
                amount: due.delay_penalty,
                date: today.format("%d.%m.%Y").to_string(),
                is_credit: false,
                receipt_number: None,
            });
        } else {
            transactions.push(AccountTransactionDto {
                id: due.id.clone(),
                title: format!("{} Aidatı", due.period),
                subtitle: if is_overdue {
                    "Gecikmeli Aidat Borcu"
                } else {
                    "Ödeme Bekleniyor"
                }
                .to_string(),
                amount: due.total_amount,
                date: due.due_date.format("%d.%m.%Y").to_string(),
                is_credit: false,
                receipt_number: None,
            });
        }
    }

    let may_view_capital_dues = ctx.claims.role != Role::HomeResident;
    let mut capital_dues: Vec<CapitalDuesSummaryDto> = if may_view_capital_dues {
        inner
            .capital_projects
            .iter()
            .filter(|project| crate::auth::same_id(&project.site_id, &unit.site_id))
            .filter_map(|project| {
                let period_prefix = format!("{}: Taksit ", project.title);
                let outstanding: Decimal = inner
                    .dues
                    .iter()
                    .filter(|due| {
                        crate::auth::same_id(&due.unit_id, &unit_id)
                            && due.status != DebtStatus::Paid
                            && due.expense_type == ExpenseType::CapitalDues
                            && due.period.starts_with(&period_prefix)
                    })
                    .map(crate::services::dues_ledger::outstanding)
                    .sum();
                (outstanding > Decimal::ZERO).then(|| CapitalDuesSummaryDto {
                    project_id: project.id.clone(),
                    project_title: project.title.clone(),
                    outstanding_balance: outstanding,
                })
            })
            .collect()
    } else {
        Vec::new()
    };
    let site_announcement = inner
        .finance
        .notifications
        .iter()
        .filter(|notification| {
            crate::auth::same_id(&notification.site_id, &unit.site_id)
                && notification.category == "ANNOUNCEMENT"
                && notification.recipient_ref == format!("site:{}:all", unit.site_id)
        })
        .max_by_key(|notification| notification.created_at);
    let announcement_title = site_announcement
        .map(|notification| notification.subject.clone())
        .unwrap_or_else(|| "Planlı Su Kesintisi Hakkında".to_string());
    let announcement_content = site_announcement
        .map(|notification| notification.body.clone())
        .unwrap_or_else(|| {
            "İSKİ ana hat yenilemesi sebebiyle 18 Eylül 10:00 - 14:00 arası su kesilecektir."
                .to_string()
        });
    drop(inner);

    if may_view_capital_dues {
        if let Some(pool) = &state.pool {
            match crate::db::fetch_unit_capital_dues_from_db(pool, &unit.site_id, &unit_id).await {
                Ok(rows) => capital_dues = rows,
                Err(_) => {
                    return (
                        StatusCode::SERVICE_UNAVAILABLE,
                        Json(
                            json!({"status": "ERROR", "message": "Capital balance is unavailable"}),
                        ),
                    )
                        .into_response();
                }
            }
        }
    }

    let response = ResidentDashboardDto {
        unit_id: unit.id,
        site_title,
        total_debt,
        is_overdue,
        dues: dues_dtos,
        announcement_title,
        announcement_content,
        virtual_iban: unit.virtual_iban,
        advance_payment,
        transactions,
        capital_dues,
    };

    (StatusCode::OK, Json(response)).into_response()
}

/// Returns the comprehensive overview for the Site Manager:
/// Managed site details, collection summary, available periods, and list of flats with dues status.
pub async fn get_site_overview(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(mut query): Query<crate::models::SiteOverviewQuery>,
) -> impl IntoResponse {
    if let Err(denied) = scope.pin_opt(&mut query.site_id) {
        return denied.json();
    }
    // Read-only: no advance offset (that used to settle every tenant's dues on
    // each overview load, under the global write lock).
    let inner = state.inner.read().await;

    // 1. Resolve site
    let site = if let Some(ref s_id) = query.site_id {
        inner
            .sites
            .iter()
            .find(|s| site_ids_match(&s.id, s_id))
            .cloned()
    } else {
        inner
            .sites
            .iter()
            .find(|s| {
                inner
                    .units
                    .iter()
                    .filter(|u| site_ids_match(&u.site_id, &s.id))
                    .count()
                    >= 12
            })
            .or_else(|| {
                inner.sites.iter().find(|s| {
                    inner
                        .units
                        .iter()
                        .any(|u| site_ids_match(&u.site_id, &s.id))
                })
            })
            .or_else(|| inner.sites.first())
            .cloned()
    };

    let site_id = site.as_ref().map(|s| s.id.clone()).unwrap_or_default();
    let site_name = site.as_ref().map(|s| s.name.clone()).unwrap_or_default();
    let address = site.as_ref().map(|s| s.address.clone()).unwrap_or_default();

    // 2. Resolve manager name & email
    let (manager_name, manager_email) = inner
        .users
        .iter()
        .find(|u| {
            (!site_id.is_empty() && site_ids_match(&u.site_id, &site_id))
                && (u.role == Role::SiteManager
                    || u.email.contains("yonetici")
                    || u.email.contains("manager"))
        })
        .map(|u| (u.full_name.clone(), u.email.clone()))
        .unwrap_or_else(|| ("Site Yöneticisi".to_string(), String::new()));

    // 3. Collect available periods for this site from dues_periods and dues
    let mut available_periods: Vec<String> = Vec::new();
    let site_unit_ids: Vec<String> = inner
        .units
        .iter()
        .filter(|u| site_ids_match(&u.site_id, &site_id))
        .map(|u| u.id.clone())
        .collect();

    for p in &inner.dues_periods {
        if site_ids_match(&p.site_id, &site_id) && !available_periods.contains(&p.period_name) {
            available_periods.push(p.period_name.clone());
        }
    }

    for due in &inner.dues {
        if (site_unit_ids.contains(&due.unit_id) || site_unit_ids.is_empty())
            && !available_periods.contains(&due.period)
        {
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

    let selected_period = query
        .period
        .unwrap_or_else(|| available_periods.first().cloned().unwrap_or_default());
    let today = Utc::now().date_naive();

    // 4. Available sites list for site switcher (deduplicated by name)
    let mut available_sites: Vec<crate::models::SiteSummaryBriefDto> = Vec::new();
    for s in &inner.sites {
        if !available_sites
            .iter()
            .any(|existing| existing.name == s.name)
        {
            let count = inner
                .units
                .iter()
                .filter(|u| site_ids_match(&u.site_id, &s.id))
                .count();
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
                    let clean = blk_id
                        .to_uppercase()
                        .replace("BLOK", "")
                        .replace(['-', '_', ' '], "")
                        .trim()
                        .to_string();
                    if clean.is_empty() {
                        blk_id.to_string()
                    } else {
                        clean
                    }
                }
            }
        };

        for u in &inner.units {
            let matches_site = site_ids_match(&u.site_id, &site_id);
            if matches_site {
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
        let resident_name = unit
            .tenant_user_id
            .as_ref()
            .and_then(|uid| {
                inner
                    .users
                    .iter()
                    .find(|u| &u.id == uid)
                    .map(|u| u.full_name.clone())
            })
            .or_else(|| {
                unit.owner_user_id.as_ref().and_then(|uid| {
                    inner
                        .users
                        .iter()
                        .find(|u| &u.id == uid)
                        .map(|u| u.full_name.clone())
                })
            })
            .or_else(|| {
                inner
                    .unit_payer_names
                    .get(&unit.id)
                    .and_then(|names| names.first().cloned())
            })
            .unwrap_or_else(|| format!("Daire Sakini {}", unit.unit_number));

        // Find due for this unit in the selected period
        let due_opt = inner
            .dues
            .iter()
            .find(|d| d.unit_id == unit.id && d.period == selected_period);
        let advance = inner.advance_total(&unit.id);
        total_advance += advance;

        let (amount_due, billed_amount, collected_amount, is_paid, days_overdue, paid_date_str) =
            if let Some(due) = due_opt {
                let (billed, collected) =
                    collection_amounts(due.principal_amount, due.paid_principal);
                let is_p = due.status == DebtStatus::Paid;
                let days_o = overdue_days(due.due_date, today, is_p);
                let p_date = if is_p {
                    Some("Ödendi".to_string())
                } else {
                    None
                };
                (due.total_amount, billed, collected, is_p, days_o, p_date)
            } else {
                (Decimal::ZERO, Decimal::ZERO, Decimal::ZERO, true, 0, None)
            };

        if billed_amount > Decimal::ZERO {
            total_expected += billed_amount;
            total_collected += collected_amount;
            if is_paid {
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
                let clean = unit
                    .block_id
                    .to_uppercase()
                    .replace("BLOK", "")
                    .replace(['-', '_', ' '], "")
                    .trim()
                    .to_string();
                if clean.is_empty() {
                    unit.block_id.clone()
                } else {
                    clean
                }
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
            registered_payer_names: inner
                .unit_payer_names
                .get(&unit.id)
                .cloned()
                .unwrap_or_default(),
            house_type: unit.house_type.clone(),
        });
    }

    flats.sort_by_key(|f| (f.block.clone(), f.unit_no));

    let total_units_count = flats.len();
    let collection_percentage = if total_expected > Decimal::ZERO {
        let ratio = (total_collected / total_expected) * Decimal::from(100);
        ratio
            .to_string()
            .split('.')
            .next()
            .unwrap_or("0")
            .parse::<u32>()
            .unwrap_or(0)
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

    (
        StatusCode::OK,
        Json(serde_json::to_value(response).unwrap()),
    )
}

#[cfg(test)]
mod tests {
    use super::{collection_amounts, overdue_days, site_ids_match};
    use chrono::NaiveDate;
    use rust_decimal::Decimal;

    #[test]
    fn unpaid_due_calculates_days_from_its_due_date() {
        let due_date = NaiveDate::from_ymd_opt(2026, 10, 15).expect("valid test date");
        let today = NaiveDate::from_ymd_opt(2026, 11, 11).expect("valid test date");

        assert_eq!(overdue_days(due_date, today, false), 27);
    }

    #[test]
    fn paid_or_not_yet_due_items_have_no_overdue_days() {
        let due_date = NaiveDate::from_ymd_opt(2026, 11, 11).expect("valid test date");
        let tomorrow = NaiveDate::from_ymd_opt(2026, 11, 12).expect("valid test date");

        assert_eq!(overdue_days(due_date, tomorrow, true), 0);
        assert_eq!(overdue_days(tomorrow, due_date, false), 0);
    }

    #[test]
    fn fully_paid_due_remains_in_period_collection_totals() {
        let (billed, collected) = collection_amounts(Decimal::from(1400), Decimal::from(1400));

        assert_eq!(billed, Decimal::from(1400));
        assert_eq!(collected, Decimal::from(1400));
    }

    #[test]
    fn site_id_matching_does_not_treat_unparseable_ids_as_equal() {
        assert!(site_ids_match("site-1", "site-1"));
        assert!(!site_ids_match("site-alpha", "site-beta"));
        assert!(site_ids_match("site-1", "1"));
    }

    #[test]
    fn collected_never_exceeds_the_billed_principal() {
        let (billed, collected) = collection_amounts(Decimal::from(1400), Decimal::from(1450));

        assert_eq!(collected, billed);
    }
}
