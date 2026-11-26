//! Platform (SaaS-admin) system operations: health, demo/test data, purge and provisioning.

use super::*;

// 7. Liveness Check
pub async fn health_check() -> impl IntoResponse {
    (
        StatusCode::OK,
        Json(json!({
            "status": "UP",
            "readiness": "LIVE",
            "service": "SitePulse Rust Backend",
            "version": "1.0.0",
            "engine": "Axum / Tokio",
        })),
    )
}

/// Readiness probe for tenant RLS and runtime database role configuration.
pub async fn readiness_check(State(state): State<AppState>) -> impl IntoResponse {
    let mut tenant_rls_status = "not_configured";
    let mut ready = true;
    match crate::db::tenant_rls_readiness(state.db_pool()).await {
        Ok(Some((policies_installed, role))) => {
            ready = policies_installed && role.is_safe();
            tenant_rls_status = if ready { "ready" } else { "misconfigured" };
        }
        Ok(None) => {}
        Err(error) => {
            ready = false;
            crate::error::sanitized("Tenant RLS readiness probe failed", &error);
            tenant_rls_status = "probe_failed";
        }
    }
    let status = if ready {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (
        status,
        Json(json!({
            "status": if ready { "UP" } else { "DEGRADED" },
            "readiness": if ready { "READY" } else { "NOT_READY" },
            "tenant_rls": { "status": tenant_rls_status },
        })),
    )
}

pub(crate) fn system_error(message: String) -> (StatusCode, Json<serde_json::Value>) {
    tracing::error!("{}", message);
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(serde_json::json!({ "status": "ERROR", "message": message })),
    )
}

/// Resets all payments, advance balances, reconciliation items, and dues back to a 100% clean state (₺0.00 debt, 0 transactions)
pub async fn reset_demo_data(State(state): State<AppState>) -> impl IntoResponse {
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
        if let Err(e) = crate::db::reset_db_to_seed_data(pool).await {
            return system_error(crate::error::sanitized("Database write failed", &e));
        }
        if let Err(e) = state.reload_from_db().await {
            return system_error(e);
        }
    } else {
        state.inner.write().await.reset_all_payments_and_balances();
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
pub async fn accrue_test_due(State(state): State<AppState>) -> impl IntoResponse {
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
pub async fn seed_test_fixtures(State(state): State<AppState>) -> impl IntoResponse {
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
        if let Err(e) = crate::db::seed_test_data(pool).await {
            return system_error(crate::error::sanitized("Database write failed", &e));
        }
        if let Err(e) = state.reload_from_db().await {
            return system_error(e);
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
pub async fn clear_all_data(State(state): State<AppState>) -> impl IntoResponse {
    if crate::state::AppStateInner::is_production() {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "status": "ERROR",
                "message": "Tüm verileri temizleme işlemi canlı (production) ortamında güvenlik nedeniyle engellenmiştir."
            })),
        );
    }
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::wipe_all_db_data(pool).await {
            return system_error(crate::error::sanitized("Database write failed", &e));
        }
        if let Err(e) = state.reload_from_db().await {
            return system_error(e);
        }
    } else {
        state.inner.write().await.clear_all_data();
    }
    let inner = state.inner.read().await;
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
pub async fn recreate_db(State(state): State<AppState>) -> impl IntoResponse {
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
                    "message": crate::error::sanitized("Veritabanı sıfırlanamadı", &e)
                })),
            );
        }
    }
    if state.pool.is_some() {
        if let Err(e) = state.reload_from_db().await {
            return system_error(e);
        }
    } else {
        let mut inner = state.inner.write().await;
        inner.clear_all_data();
        inner.seed_test_fixtures();
    }
    let inner = state.inner.read().await;
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
pub async fn reset_to_initial_state(State(state): State<AppState>) -> impl IntoResponse {
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
                    "message": crate::error::sanitized("Veritabanı sıfırlanamadı", &e)
                })),
            );
        }
    }
    if state.pool.is_some() {
        if let Err(e) = state.reload_from_db().await {
            return system_error(e);
        }
    } else {
        let mut inner = state.inner.write().await;
        inner.clear_all_data();
        inner.seed_test_fixtures();
    }
    let inner = state.inner.read().await;
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
pub async fn wipe_all_data(State(state): State<AppState>) -> impl IntoResponse {
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
                    "message": crate::error::sanitized("Tüm veriler silinemedi", &e)
                })),
            );
        }
    }
    if state.pool.is_some() {
        if let Err(e) = state.reload_from_db().await {
            return system_error(e);
        }
    } else {
        let mut inner = state.inner.write().await;
        inner.clear_all_data();
        inner.users.push(crate::models::User {
            id: "1".to_string(),
            site_id: "".to_string(),
            full_name: "SaaS Platform Admin".to_string(),
            email: "admin@sitepulse.io".to_string(),
            phone: "+90 850 555 0000".to_string(),
            password_hash: crate::state::seed_password_hash(
                &crate::state::bootstrap_admin_password(),
            ),
            role: crate::models::Role::SaasAdmin,
            must_change_password: true,
            auth_provider: AuthProvider::Local,
            google_sub: None,
            avatar_url: None,
            created_at: chrono::Utc::now(),
            person_id: Some(1),
        });
    }
    let inner = state.inner.read().await;
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

/// Retired: this endpoint wrote every tenant's in-memory state over PostgreSQL
/// (absolute balances and statuses), which could undo committed payments.
/// PostgreSQL is written by each operation in its own transaction instead.
pub async fn sync_db(State(_state): State<AppState>) -> impl IntoResponse {
    (
        StatusCode::GONE,
        Json(serde_json::json!({
            "status": "ERROR",
            "message": "sync-db has been retired: every operation persists its own changes transactionally."
        })),
    )
}

/// Deletes every row of one site in a single transaction, child tables first.
/// The append-only ledger guard (V16) is lifted for this transaction only via
/// `sitepulse.allow_ledger_purge`; callers must be non-production test rollbacks.
pub(crate) async fn purge_site_rows(
    pool: &deadpool_postgres::Pool,
    site_id: i64,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    const UNIT_SCOPED: &[&str] = &[
        "payment_allocations WHERE payment_entry_id IN (SELECT id FROM payment_entries WHERE site_id = $1)",
        "payment_allocations WHERE dues_liability_id IN (SELECT d.id FROM dues_liabilities d JOIN units u ON u.id = d.unit_id WHERE u.site_id = $1)",
        "processed_bank_webhooks WHERE site_id = $1 OR receipt_id IN (SELECT id FROM payment_receipts WHERE site_id = $1)
             OR site_bank_account_id IN (SELECT id FROM site_bank_accounts WHERE site_id = $1)",
        "payment_entries WHERE site_id = $1 AND reverses_entry_id IS NOT NULL",
        "payment_entries WHERE site_id = $1",
        "payment_idempotency_keys WHERE site_id = $1",
        "payment_intents WHERE site_id = $1",
        "payment_receipts WHERE site_id = $1 AND reverses_receipt_id IS NOT NULL",
        "payment_receipts WHERE site_id = $1",
        "receipt_counters WHERE site_id = $1",
        "advance_ledger_entries WHERE unit_id IN (SELECT id FROM units WHERE site_id = $1)",
        "advance_balances WHERE unit_id IN (SELECT id FROM units WHERE site_id = $1)",
        "person_advance_holds WHERE site_id = $1",
        "debt_aging_snapshots WHERE site_id = $1",
        "reconciliation_queue WHERE site_id = $1",
        "unit_sender_ibans WHERE unit_id IN (SELECT id FROM units WHERE site_id = $1)",
        "unit_payer_names WHERE unit_id IN (SELECT id FROM units WHERE site_id = $1)",
        "dues_liabilities WHERE unit_id IN (SELECT id FROM units WHERE site_id = $1)",
        // Budget lines, shares, service records and objections cascade with the budget.
        "operating_budgets WHERE site_id = $1",
        "occupancy_transitions WHERE site_id = $1",
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
        "account_activations WHERE site_id = $1",
        "users WHERE site_id = $1",
        "units WHERE site_id = $1",
        // Persons belong to one site (V21); every reference to them is gone by now.
        "persons WHERE site_id = $1",
        "blocks WHERE site_id = $1",
        "house_types WHERE site_id = $1",
        "site_bank_accounts WHERE site_id = $1",
        "sites WHERE id = $1",
    ];
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    crate::db::tx_bind_tenant(&tx, site_id).await?;
    tx.batch_execute("SET LOCAL sitepulse.allow_ledger_purge = 'on'")
        .await?;
    for target in UNIT_SCOPED {
        let table = target.split_whitespace().next().unwrap_or_default();
        let exists: bool = tx
            .query_one("SELECT to_regclass($1) IS NOT NULL", &[&table])
            .await?
            .get(0);
        if exists {
            tx.execute(&format!("DELETE FROM {}", target), &[&site_id])
                .await?;
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
            Err(_) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(
                        serde_json::json!({"status": "ERROR", "message": format!("Invalid site id '{}'", site_id)}),
                    ),
                )
            }
        };
        if let Err(e) = purge_site_rows(pool, site_id_num).await {
            tracing::error!("Site purge failed: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(
                    serde_json::json!({"status": "ERROR", "message": crate::error::sanitized("Site purge failed", &e)}),
                ),
            );
        }
    }

    let mut inner = state.inner.write().await;
    let unit_ids: Vec<String> = inner
        .units
        .iter()
        .filter(|u| u.site_id == site_id)
        .map(|u| u.id.clone())
        .collect();
    inner.units.retain(|u| u.site_id != site_id);
    inner.users.retain(|u| u.site_id != site_id);
    inner.dues.retain(|d| !unit_ids.contains(&d.unit_id));
    for uid in &unit_ids {
        inner.advance_balances.remove(uid);
        inner
            .person_advance_holds
            .retain(|(unit, _, _), _| unit != uid);
        inner
            .reconciliation_queue
            .retain(|q| q.matched_unit_id.as_deref() != Some(uid.as_str()));
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
        })),
    )
}

/// Dynamically provisions a residential site with N units (default: 12),
/// allocated Virtual IBANs, realistic resident profiles, matching criteria, and optional monthly dues.
pub async fn provision_site_units(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Json(mut payload): Json<ProvisionSiteUnitsRequest>,
) -> impl IntoResponse {
    // A SaaS-admin route (auth::route_access); the scope still refuses any
    // other caller a foreign site.
    if let Err(denied) = scope.pin_opt(&mut payload.site_id) {
        return denied.json();
    }
    if crate::state::AppStateInner::is_production() {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "status": "ERROR",
                "message": "Test site & sakin provizyon işlemi canlı (production) ortamında güvenlik nedeniyle engellenmiştir."
            })),
        );
    }

    let block_name = payload
        .block
        .clone()
        .unwrap_or_else(|| "A Blok".to_string());
    let units_count = payload.units_count.unwrap_or(12).clamp(1, 48);
    let monthly_dues = payload
        .monthly_dues
        .unwrap_or_else(|| Decimal::from_str_exact("1400.00").unwrap());
    let accrue_dues = payload.accrue_initial_dues.unwrap_or(true);
    let dues_period = payload
        .period
        .clone()
        .unwrap_or_else(|| "Ekim 2026".to_string());

    // 1. Resolve or register target site
    let s_name = payload
        .site_name
        .clone()
        .unwrap_or_else(|| "Yeni Yaşam Sitesi".to_string());
    let slug = crate::services::to_slug(&s_name);

    let site_id = if let Some(ref s_id) = payload.site_id {
        let in_mem = {
            let inner = state.inner.read().await;
            inner
                .sites
                .iter()
                .find(|s| {
                    s.id == *s_id
                        || crate::db::parse_id_to_i64(&s.id) == crate::db::parse_id_to_i64(s_id)
                })
                .map(|s| s.id.clone())
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
            let mut conn = match pool.get().await {
                Ok(c) => c,
                Err(e) => {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({
                            "status": "ERROR",
                            "message": crate::error::sanitized("Database error", &e)
                        })),
                    );
                }
            };
            let client = match crate::db::begin_tenant_read(&mut conn, id_num).await {
                Ok(tx) => tx,
                Err(e) => {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({
                            "status": "ERROR",
                            "message": crate::error::sanitized("Database error", &e)
                        })),
                    );
                }
            };
            let row = match client.query_opt("SELECT id, name, slug, address, status, plan_type, license_end_date FROM sites WHERE id = $1", &[&id_num]).await {
                Ok(r) => {
                    let _ = client.commit().await;
                    r
                }
                Err(e) => {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({
                            "status": "ERROR",
                            "message": crate::error::sanitized("Database error", &e)
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
                let st: SiteStatus = r.get(4);
                let plan: PlanType = r.get(5);
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
                        license_end_date: lic_end.unwrap_or_else(new_site_license_end),
                        timezone: crate::models::default_site_timezone(),
                        proration_enabled: false,
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
            inner
                .sites
                .iter()
                .find(|s| s.slug == slug || s.name.eq_ignore_ascii_case(&s_name))
                .map(|s| s.id.clone())
        };
        if let Some(id) = in_mem {
            id
        } else if let Some(ref pool) = state.pool {
            // tenant-guard: platform — test helper lookup by slug/name before site_id is known.
            let mut conn = match pool.get().await {
                Ok(c) => c,
                Err(e) => {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({
                            "status": "ERROR",
                            "message": crate::error::sanitized("Database error", &e)
                        })),
                    );
                }
            };
            let client = match crate::db::begin_platform_read(&mut conn).await {
                Ok(tx) => tx,
                Err(e) => {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({
                            "status": "ERROR",
                            "message": crate::error::sanitized("Database error", &e)
                        })),
                    );
                }
            };
            let row = match client.query_opt("SELECT id, name, slug, address, status, plan_type, license_end_date FROM sites WHERE slug = $1 OR LOWER(name) = LOWER($2)", &[&slug, &s_name]).await {
                Ok(r) => {
                    let _ = client.commit().await;
                    r
                }
                Err(e) => {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({
                            "status": "ERROR",
                            "message": crate::error::sanitized("Database error", &e)
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
                let st: SiteStatus = r.get(4);
                let plan: PlanType = r.get(5);
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
                        license_end_date: lic_end.unwrap_or_else(new_site_license_end),
                        timezone: crate::models::default_site_timezone(),
                        proration_enabled: false,
                        tax_id: None,
                        tax_office: None,
                    });
                }
                id_str
            } else {
                let license_end = new_site_license_end();
                // tenant-guard: platform — the read transaction above is already committed.
                let wtx = match crate::db::begin_platform_tx(&mut conn).await {
                    Ok(tx) => tx,
                    Err(e) => {
                        return (
                            StatusCode::INTERNAL_SERVER_ERROR,
                            Json(serde_json::json!({
                                "status": "ERROR",
                                "message": crate::error::sanitized("Failed to create site", &e)
                            })),
                        );
                    }
                };
                let ins_row = match wtx
                    .query_one(
                        r#"
                        INSERT INTO sites (name, address, slug, status, plan_type, license_end_date)
                        VALUES ($1, $2, $3, 'ACTIVE', 'PREMIUM', $4)
                        ON CONFLICT (slug) WHERE deleted_at IS NULL DO UPDATE SET name = EXCLUDED.name
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
                                "message": crate::error::sanitized("Failed to create site", &e)
                            })),
                        );
                    }
                };
                if let Err(e) = wtx.commit().await {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({
                            "status": "ERROR",
                            "message": crate::error::sanitized("Failed to create site", &e)
                        })),
                    );
                }
                let new_id: i64 = ins_row.get(0);
                let id_str = new_id.to_string();
                let mut inner = state.inner.write().await;
                inner.sites.push(Site {
                    id: id_str.clone(),
                    name: s_name,
                    address: "Kadıköy, İstanbul".to_string(),
                    slug,
                    status: SiteStatus::Active,
                    plan_type: PlanType::Premium,
                    license_end_date: license_end,
                    timezone: crate::models::default_site_timezone(),
                    proration_enabled: false,
                    tax_id: None,
                    tax_office: None,
                });
                id_str
            }
        } else {
            let mut inner = state.inner.write().await;
            if let Some(existing) = inner
                .sites
                .iter()
                .find(|s| s.slug == slug || s.name.eq_ignore_ascii_case(&s_name))
            {
                existing.id.clone()
            } else {
                let max_id = inner
                    .sites
                    .iter()
                    .filter_map(|s| crate::db::parse_id_to_i64(&s.id))
                    .max()
                    .unwrap_or(0);
                let id_str = (max_id + 1).to_string();
                inner.sites.push(Site {
                    id: id_str.clone(),
                    name: s_name,
                    address: "Kadıköy, İstanbul".to_string(),
                    slug,
                    status: SiteStatus::Active,
                    plan_type: PlanType::Premium,
                    license_end_date: new_site_license_end(),
                    timezone: crate::models::default_site_timezone(),
                    proration_enabled: false,
                    tax_id: None,
                    tax_office: None,
                });
                id_str
            }
        }
    };

    let mut inner = state.inner.write().await;
    let site_name = inner
        .sites
        .iter()
        .find(|s| s.id == site_id)
        .map(|s| s.name.clone())
        .unwrap_or_else(|| "Site".to_string());

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

    let site_today = crate::services::finance_common::site_today(&inner, &site_id);
    let mut provisioned_dtos = Vec::new();
    let site_slug = crate::services::to_slug(&site_name);
    // Only this site's rows are persisted afterwards (never other tenants').
    let mut touched_users: Vec<String> = Vec::new();
    let mut touched_units: Vec<String> = Vec::new();
    let mut touched_sender_ibans: Vec<String> = Vec::new();

    for i in 1..=units_count {
        let unit_number = i as i32;
        let floor = ((i - 1) / 4 + 1) as i32;
        let name_idx = (i - 1) % sample_names.len();
        let resident_name = sample_names[name_idx].to_string();
        let email = format!("daire{}@{}.com", i, site_slug);
        let phone = format!("+90 532 555 {:04}", i + 100);

        let virtual_iban = match VirtualIbanService::generate_virtual_iban(
            VirtualIbanService::KUVEYT_TURK_BANK_CODE,
            &site_id,
            &block_name,
            unit_number,
        ) {
            Ok(iban) => iban,
            Err(e) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({ "status": "ERROR", "message": e.to_string() })),
                )
            }
        };

        // Add or update resident user
        let user_id =
            if let Some(existing_user) = inner.users.iter_mut().find(|u| {
                u.email == email || (u.site_id == site_id && u.full_name == resident_name)
            }) {
                existing_user.full_name = resident_name.clone();
                existing_user.phone = phone.clone();
                existing_user.id.clone()
            } else {
                let max_u = inner
                    .users
                    .iter()
                    .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                    .max()
                    .unwrap_or(0);
                let u_id = (max_u + 1).to_string();
                inner.users.push(User {
                    id: u_id.clone(),
                    site_id: site_id.clone(),
                    full_name: resident_name.clone(),
                    email: email.clone(),
                    phone: phone.clone(),
                    password_hash: crate::state::seed_password_hash(
                        &crate::auth::generate_temporary_password("SP-SAKIN-"),
                    ),
                    role: Role::HomeOwner,
                    must_change_password: true,
                    auth_provider: AuthProvider::Local,
                    google_sub: None,
                    avatar_url: None,
                    created_at: Utc::now(),
                    person_id: None,
                });
                u_id
            };

        // Add or update independent flat
        let existing_pos = inner
            .units
            .iter()
            .position(|u| u.site_id == site_id && u.unit_number == unit_number);
        let unit_id = if let Some(pos) = existing_pos {
            let u = &mut inner.units[pos];
            u.block_id = block_name.clone();
            u.floor = floor;
            u.owner_user_id = Some(user_id.clone());
            u.virtual_iban = Some(virtual_iban.clone());
            u.id.clone()
        } else {
            let max_unit = inner
                .units
                .iter()
                .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                .max()
                .unwrap_or(0);
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
                house_type: Some(if unit_number % 2 == 0 {
                    "3+1".to_string()
                } else {
                    "2+1".to_string()
                }),
                monthly_tariff_override: None,
                created_on: Some(site_today),
            });
            new_unit_id
        };

        // Matching criteria & sender IBAN
        inner
            .unit_payer_names
            .insert(unit_id.clone(), vec![resident_name.clone()]);
        let sample_sender_iban = format!("TR{:02}000620000000000000{:04}", (i % 80) + 10, i);
        inner
            .remembered_sender_ibans
            .insert(sample_sender_iban.clone(), unit_id.clone());
        inner.sender_iban_metadata.insert(
            sample_sender_iban.clone(),
            (
                Some(format!("Garanti BBVA - {}", resident_name)),
                Some("Garanti BBVA".to_string()),
            ),
        );

        // Optional dues accrual
        if accrue_dues
            && !inner
                .dues
                .iter()
                .any(|d| d.unit_id == unit_id && d.period == dues_period)
        {
            let max_due = inner
                .dues
                .iter()
                .filter_map(|d| crate::db::parse_id_to_i64(&d.id))
                .max()
                .unwrap_or(0);
            let due_id = (max_due + 1).to_string();
            inner.dues.push(DuesLiability {
                id: due_id,
                unit_id: unit_id.clone(),
                period: dues_period.clone(),
                principal_amount: monthly_dues,
                delay_penalty: Decimal::ZERO,
                total_amount: monthly_dues,
                due_date: site_today + chrono::Days::new(15),
                status: DebtStatus::Pending,
                paid_principal: Decimal::ZERO,
                paid_penalty: Decimal::ZERO,
                // A freshly provisioned unit has no tenant: its dues are the owner's.
                debtor_type: DebtorType::Owner,
                expense_type: ExpenseType::OperationalDues,
                penalty_accrued_through: None,
                grace_days: 0,
                effective_due_date: None,
                liable_person_id: None,
            });
        }

        touched_users.push(user_id.clone());
        touched_units.push(unit_id.clone());
        touched_sender_ibans.push(sample_sender_iban.clone());

        let current_debt: Decimal = inner
            .dues
            .iter()
            .filter(|d| d.unit_id == unit_id && d.status.is_collectable())
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

    // Persist this site's provisioned rows without holding the global lock.
    let batch = crate::db::ProvisionedSiteBatch::collect(
        &inner,
        &site_id,
        &touched_users,
        &touched_units,
        &touched_sender_ibans,
        &dues_period,
    );
    drop(inner);
    if let Some(ref pool) = state.pool {
        if let Err(e) = crate::db::persist_provisioned_site(pool, &batch).await {
            tracing::error!("Provisioned site {} was not saved: {}", site_id, e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({
                    "status": "ERROR",
                    "message": crate::error::sanitized("Provisioned units were not saved", &e)
                })),
            );
        }
    }
    // Offset existing advances against the new dues of this site only.
    if let Err(e) = settle_advances(&state, OffsetScope::Site(&site_id)).await {
        tracing::error!("{}", e);
    }
    {
        let inner = state.inner.read().await;
        for dto in provisioned_dtos.iter_mut() {
            dto.current_debt = inner
                .dues
                .iter()
                .filter(|d| d.unit_id == dto.unit_id && d.status.is_collectable())
                .map(|d| d.total_amount)
                .sum();
            dto.advance_balance = inner.advance_total(&dto.unit_id);
        }
    }

    let total_volume = monthly_dues * Decimal::from(units_count);

    (
        StatusCode::OK,
        Json(
            serde_json::to_value(ProvisionSiteUnitsResponse {
                status: "SUCCESS".to_string(),
                message: format!(
                    "{} için {} daire ve sakin kaydı başarıyla oluşturuldu.",
                    site_name, units_count
                ),
                site_id,
                site_name,
                units_count,
                total_monthly_dues_volume: total_volume,
                units: provisioned_dtos,
            })
            .unwrap(),
        ),
    )
}

/// Returns a summary list of all units in the system for testing & simulator dropdowns
pub async fn get_units_summary(State(state): State<AppState>) -> impl IntoResponse {
    if let Some(p) = state.db_pool() {
        if let Ok(units) = crate::db::unit_repository::fetch_units_summary_from_db(p).await {
            return (StatusCode::OK, Json(units)).into_response();
        }
    }
    let inner = state.inner.read().await;
    let mut result = Vec::new();

    for unit in &inner.units {
        let site_name = inner
            .sites
            .iter()
            .find(|s| s.id == unit.site_id)
            .map(|s| s.name.clone())
            .unwrap_or_else(|| "Site".to_string());
        let resident_name = unit
            .owner_user_id
            .as_ref()
            .and_then(|uid| {
                inner
                    .users
                    .iter()
                    .find(|u| &u.id == uid)
                    .map(|u| u.full_name.clone())
            })
            .unwrap_or_else(|| format!("Daire Sakini {}", unit.unit_number));
        let email = unit
            .owner_user_id
            .as_ref()
            .and_then(|uid| {
                inner
                    .users
                    .iter()
                    .find(|u| &u.id == uid)
                    .map(|u| u.email.clone())
            })
            .unwrap_or_default();
        let current_debt: Decimal = inner
            .dues
            .iter()
            .filter(|d| d.unit_id == unit.id && d.status.is_collectable())
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

    (StatusCode::OK, Json(result)).into_response()
}

/// The license end assumed for a site created or loaded without one: 365 days
/// after today in the default site time zone (new sites use that zone).
fn new_site_license_end() -> chrono::NaiveDate {
    crate::domain::clock::default_license_end(
        &crate::models::default_site_timezone(),
        crate::e2e_clock::now_utc(),
    )
}
