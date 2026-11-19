use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::models::{
    AllocationBasis, AuthProvider, BankStatementFormat, CapitalProjectCategory,
    CapitalProjectStatus, DebtStatus, DebtorType, DisbursementMethod, DuesLiability, ExpenseType,
    HomeownerPaymentRecord, IndependentUnit, PendingRegistrationResponse, PlanType,
    ReconciliationMatch, RegistrationStatus, Role, Site, SiteBankAccount, SiteStatus,
    UnitInviteLinkResponse, UnitMemberDto, User,
};
use crate::services::VirtualIbanService;

/// Password for the bootstrap SaaS administrator: `SITEPULSE_BOOTSTRAP_ADMIN_PASSWORD`
/// when set, otherwise a random one-time password logged once at startup. The
/// account is always created with `must_change_password = true`.
pub fn bootstrap_admin_password() -> String {
    static PASSWORD: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    PASSWORD
        .get_or_init(|| match std::env::var("SITEPULSE_BOOTSTRAP_ADMIN_PASSWORD") {
            Ok(p) if p.chars().count() >= crate::auth::MIN_PASSWORD_LENGTH => p,
            _ => {
                let p = crate::auth::generate_temporary_password("SP-ADMIN-");
                tracing::warn!("Bootstrap administrator requires a configured password for interactive sign-in");
                p
            }
        })
        .clone()
}

#[derive(Clone)]
pub struct AppState {
    pub security: Arc<tokio::sync::Mutex<crate::security::MemorySecurity>>,
    pub inner: Arc<RwLock<AppStateInner>>,
    pub pool: Option<deadpool_postgres::Pool>,
    #[cfg(feature = "e2e")]
    pub e2e_clock: Option<Arc<crate::e2e_clock::E2eClock>>,
}

#[derive(Clone)]
pub struct AppStateInner {
    pub sites: Vec<Site>,
    pub users: Vec<User>,
    pub units: Vec<IndependentUnit>,
    pub dues: Vec<DuesLiability>,
    pub pending_registrations: Vec<PendingRegistrationResponse>,
    pub unit_members: HashMap<String, Vec<UnitMemberDto>>,
    pub unit_invite_tokens: HashMap<String, UnitInviteLinkResponse>,
    pub reconciliation_queue: Vec<ReconciliationMatch>,
    pub site_bank_accounts: Vec<SiteBankAccount>,
    /// Advance (avans) balance per unit, split by debtor like `advance_balances`.
    pub advance_balances: HashMap<String, crate::models::UnitAdvance>,
    /// Amounts reserved by pending exit-settlement requests, by unit and source debtor.
    pub pending_exit_advance_reservations: HashMap<(String, String), Decimal>,
    /// Idempotency keys: (site id, key) -> receipt id. Mirrors `payment_idempotency_keys`.
    pub payment_idempotency: HashMap<(String, String), i64>,
    pub homeowner_payments: Vec<HomeownerPaymentRecord>,
    pub remembered_sender_ibans: HashMap<String, String>,
    pub sender_iban_metadata: HashMap<String, (Option<String>, Option<String>)>,
    pub unit_primary_contacts: HashMap<String, crate::models::PrimaryResponsibleContact>,
    pub unit_payer_names: HashMap<String, Vec<String>>,
    pub house_types: Vec<crate::models::HouseTypeTariff>,
    pub dues_periods: Vec<crate::models::DuesPeriod>,
    pub dues_period_snapshots: Vec<crate::models::DuesPeriodSnapshot>,
    pub dues_period_reopen_requests: Vec<crate::models::DuesPeriodReopenRequest>,
    pub blocks: Vec<crate::models::BlockDto>,
    pub kuveyt_turk_client_id: Option<String>,
    pub kuveyt_turk_client_secret: Option<String>,
    pub auto_scheduler_enabled: bool,
    pub unit_occupancies: HashMap<String, Vec<crate::models::OccupancyHistoryItem>>,
    pub payment_receipts: Vec<crate::models::PaymentReceipt>,
    pub payment_entries: Vec<crate::models::PaymentEntry>,
    pub capital_projects: Vec<crate::models::CapitalProject>,
    pub capital_installments: Vec<crate::models::CapitalProjectInstallment>,
    pub capital_disbursements: Vec<crate::models::CapitalContractorDisbursement>,
    /// İşletme projesi per site and fiscal year (SPEC-007 R5), with lines and shares.
    pub operating_budgets: Vec<crate::models::OperatingBudget>,
    /// Yeniden değerleme oranı per year, the interim budget cap.
    pub revaluation_rates: HashMap<i32, crate::models::RevaluationRate>,
    /// Sites that never accrue operational dues without a budget in force.
    pub budget_required_sites: Vec<String>,
    /// Dues liability id -> operating budget id (its legal basis).
    pub dues_budget_basis: HashMap<String, String>,
    /// Accrual day, due day, grace period and catch-up limit per site (STORY-07-10); a site
    /// without an entry uses the defaults.
    pub site_accrual_schedules: HashMap<String, crate::domain::accrual_schedule::AccrualSchedule>,
    /// Card payment intents through the licensed provider (SPEC-007 R4).
    pub payment_intents: Vec<crate::models::PaymentIntent>,
    /// SPEC-009 aggregates (KVKK, notifications, autopay, expenses, collections, ...).
    pub finance: crate::finance_book::FinanceBook,
    /// Activation and email-confirmation tokens by SHA-256 digest (no-database mode).
    pub account_activations:
        HashMap<String, crate::services::account_activation_service::MemoryActivation>,
}

impl Default for AppStateInner {
    fn default() -> Self {
        Self::new()
    }
}

impl AppStateInner {
    pub fn new() -> Self {
        let mut inner = Self::blank();
        inner.seed_system_lookups();
        if Self::should_seed_test_fixtures() {
            inner.seed_test_fixtures();
        }
        inner
    }

    /// An empty state with no seeded lookups (no password hashing, no fixtures).
    pub fn blank() -> Self {
        AppStateInner {
            sites: Vec::new(),
            users: Vec::new(),
            units: Vec::new(),
            dues: Vec::new(),
            pending_registrations: Vec::new(),
            unit_members: HashMap::new(),
            unit_invite_tokens: HashMap::new(),
            reconciliation_queue: Vec::new(),
            site_bank_accounts: Vec::new(),
            advance_balances: HashMap::new(),
            pending_exit_advance_reservations: HashMap::new(),
            payment_idempotency: HashMap::new(),
            homeowner_payments: Vec::new(),
            remembered_sender_ibans: HashMap::new(),
            sender_iban_metadata: HashMap::new(),
            unit_primary_contacts: HashMap::new(),
            unit_payer_names: HashMap::new(),
            house_types: Vec::new(),
            dues_periods: Vec::new(),
            dues_period_snapshots: Vec::new(),
            dues_period_reopen_requests: Vec::new(),
            blocks: Vec::new(),
            kuveyt_turk_client_id: std::env::var("KT_CLIENT_ID").ok(),
            kuveyt_turk_client_secret: std::env::var("KT_CLIENT_SECRET").ok(),
            auto_scheduler_enabled: false,
            unit_occupancies: HashMap::new(),
            payment_receipts: Vec::new(),
            payment_entries: Vec::new(),
            capital_projects: Vec::new(),
            capital_installments: Vec::new(),
            capital_disbursements: Vec::new(),
            operating_budgets: Vec::new(),
            revaluation_rates: HashMap::new(),
            budget_required_sites: Vec::new(),
            dues_budget_basis: HashMap::new(),
            site_accrual_schedules: HashMap::new(),
            payment_intents: Vec::new(),
            account_activations: HashMap::new(),
            finance: crate::finance_book::FinanceBook::default(),
        }
    }

    /// Declared runtime mode: `Some(Some(true))` production, `Some(Some(false))`
    /// development, `Some(None)` an unrecognised value, `None` not declared.
    fn declared_production_mode() -> Option<Option<bool>> {
        let raw = std::env::var("APP_ENV")
            .or_else(|_| std::env::var("ENVIRONMENT"))
            .ok();
        match raw.as_deref().map(str::to_ascii_lowercase).as_deref() {
            Some("production" | "prod" | "live") => Some(Some(true)),
            Some("development" | "dev" | "local" | "test") => Some(Some(false)),
            Some(_) => Some(None),
            None => None,
        }
    }

    /// Fails closed: production unless development was explicitly requested.
    /// Test binaries that run against seeded fixtures count as development
    /// when no mode is declared.
    pub fn is_production() -> bool {
        match Self::declared_production_mode() {
            Some(Some(production)) => production,
            Some(None) => true,
            None => !(cfg!(test) || Self::is_running_fixture_test_binary()),
        }
    }

    /// Validates that the runtime mode is declared with a recognised value.
    ///
    /// # Errors
    /// Returns a message when `APP_ENV`/`ENVIRONMENT` is unset (outside tests) or unknown.
    pub fn validate_mode() -> Result<(), String> {
        match Self::declared_production_mode() {
            Some(None) => Err("APP_ENV must be 'development' or 'production'".to_string()),
            None if !cfg!(test) => {
                Err("APP_ENV is not set; set it to 'development' or 'production'".to_string())
            }
            _ => Ok(()),
        }
    }

    /// Determines whether test fixtures should be seeded into memory
    pub fn should_seed_test_fixtures() -> bool {
        // Strict guard: NEVER seed test fixtures in production under any circumstances
        if Self::is_production() {
            return false;
        }
        // 1. Explicit environment variable
        if let Ok(val) = std::env::var("SITEPULSE_SEED_TEST_DATA") {
            return val == "true" || val == "1";
        }
        // 2. Active test runner detection (cargo test)
        Self::is_running_fixture_test_binary() || cfg!(test)
    }

    /// Whether the current executable is a test binary that runs against the seeded fixtures.
    fn is_running_fixture_test_binary() -> bool {
        // `cargo test` sets this for every test binary, whatever its name. The server
        // refuses to start without a declared mode (`validate_mode`), so this can only
        // relax behaviour inside tests.
        std::env::var_os("CARGO_MANIFEST_DIR").is_some()
            || std::env::current_exe()
                .ok()
                .and_then(|exe| exe.file_name().map(|n| n.to_string_lossy().into_owned()))
                .is_some_and(|name| Self::is_fixture_test_binary(&name))
    }

    /// Whether a test binary file name belongs to a suite that runs against the seeded fixtures.
    ///
    /// Matched on the file name, not the directory: Cargo names test binaries
    /// `<target>-<hash>` both in the classic `target/debug/deps/` layout and in the
    /// build-dir layout of Cargo 1.100+ (`target/debug/build/<pkg>/<hash>/out/`).
    /// The server binary (`sitepulse-backend`, with a hyphen) never matches.
    pub fn is_fixture_test_binary(file_name: &str) -> bool {
        file_name.starts_with("integration_tests-")
            || file_name.starts_with("sitepulse_backend-")
            || file_name.ends_with("test")
    }

    /// Essential system lookups and root administrator identity required for platform operation.
    /// Production-safe: contains ZERO mock sites, ZERO flats, and ZERO debts.
    pub fn seed_system_lookups(&mut self) {
        // Mirrors the V18 seed (the figure must be verified before production use).
        self.revaluation_rates.entry(2026).or_insert_with(|| crate::models::RevaluationRate {
            year: 2026,
            rate: rust_decimal::Decimal::new(254900, 4),
            source: Some("VUK mükerrer 298: yeniden değerleme oranı (verify against the published communiqué)".to_string()),
        });
        if !self
            .users
            .iter()
            .any(|u| u.id == "usr-saas-root" || u.id == "usr-saas-admin-1")
        {
            self.users.push(User {
                id: "usr-saas-admin-1".to_string(),
                site_id: "site-1".to_string(),
                full_name: "SaaS Platform Admin".to_string(),
                email: "admin@sitepulse.io".to_string(),
                phone: "+90 532 999 0000".to_string(),
                password_hash: seed_password_hash(&bootstrap_admin_password()),
                role: Role::SaasAdmin,
                must_change_password: true,
                auth_provider: AuthProvider::Local,
                google_sub: None,
                avatar_url: None,
                created_at: Utc::now(),
                person_id: Some(1),
            });
        }

        if self.house_types.is_empty() {
            let defaults = vec![
                ("1+1", "1000.00", "1 Oda 1 Salon"),
                ("2+1", "1400.00", "2 Oda 1 Salon"),
                ("3+1", "1800.00", "3 Oda 1 Salon"),
                ("4+1", "2200.00", "4 Oda 1 Salon"),
                ("Dublex", "2500.00", "Çatı Dubleks / Bahçe Katı"),
            ];
            for (name, amount, desc) in defaults {
                self.house_types.push(crate::models::HouseTypeTariff {
                    id: format!("ht-{}", name.to_lowercase().replace('+', "_")),
                    site_id: "site-1".to_string(),
                    type_name: name.to_string(),
                    dues_amount: Decimal::from_str_exact(amount).unwrap(),
                    description: Some(desc.to_string()),
                });
                self.house_types.push(crate::models::HouseTypeTariff {
                    id: format!("ht-1-{}", name.to_lowercase().replace('+', "_")),
                    site_id: "1".to_string(),
                    type_name: name.to_string(),
                    dues_amount: Decimal::from_str_exact(amount).unwrap(),
                    description: Some(desc.to_string()),
                });
            }
        }

        if self.blocks.is_empty() {
            let default_blocks = ["A Blok", "B Blok"];
            for (idx, bname) in default_blocks.iter().enumerate() {
                self.blocks.push(crate::models::BlockDto {
                    id: (idx + 1).to_string(),
                    site_id: "site-1".to_string(),
                    block_name: bname.to_string(),
                    total_floors: 10,
                });
                self.blocks.push(crate::models::BlockDto {
                    id: format!("1-{}", idx + 1),
                    site_id: "1".to_string(),
                    block_name: bname.to_string(),
                    total_floors: 10,
                });
            }
        }
    }

    /// Isolated development/test fixtures (Begonya Sitesi, test units, test debts).
    /// Used only in test suites or when SITEPULSE_SEED_TEST_DATA=true.
    pub fn seed_test_fixtures(&mut self) {
        // Seed Begonya Sitesi
        if !self.sites.iter().any(|s| s.id == "site-1") {
            self.sites.push(Site {
                id: "site-1".to_string(),
                name: "Begonya Sitesi".to_string(),
                address: "Ataşehir, Begonya Sok. No:14, İstanbul".to_string(),
                slug: "begonya-sitesi".to_string(),
                status: SiteStatus::Active,
                plan_type: PlanType::Premium,
                license_end_date: NaiveDate::from_ymd_opt(2027, 9, 1).unwrap(),
                timezone: crate::models::default_site_timezone(),
                proration_enabled: false,
                tax_id: None,
                tax_office: None,
            });
        }

        if !self.sites.iter().any(|s| s.id == "site-2") {
            self.sites.push(Site {
                id: "site-2".to_string(),
                name: "Kardelen Rezidans".to_string(),
                address: "Çankaya, Kardelen Cad. No:8, Ankara".to_string(),
                slug: "kardelen-rezidans".to_string(),
                status: SiteStatus::Active,
                plan_type: PlanType::Standard,
                license_end_date: NaiveDate::from_ymd_opt(2027, 10, 15).unwrap(),
                timezone: crate::models::default_site_timezone(),
                proration_enabled: false,
                tax_id: None,
                tax_office: None,
            });
        }

        // Seed Users
        // 1. Site Manager (Mehmet Demir)
        if !self.users.iter().any(|u| u.id == "usr-site-manager-1") {
            self.users.push(User {
                id: "usr-site-manager-1".to_string(),
                site_id: "site-1".to_string(),
                full_name: "Mehmet Demir".to_string(),
                email: "mehmet.demir@begonya.com".to_string(),
                phone: "+90 532 100 2030".to_string(),
                password_hash: seed_password_hash("mehmet123"),
                role: Role::SiteManager,
                must_change_password: false,
                auth_provider: AuthProvider::Local,
                google_sub: None,
                avatar_url: None,
                created_at: Utc::now(),
                person_id: Some(1),
            });
        }

        // 2. Home Owner (Ahmet Yılmaz)
        if !self.users.iter().any(|u| u.id == "usr-home-owner-1") {
            self.users.push(User {
                id: "usr-home-owner-1".to_string(),
                site_id: "site-1".to_string(),
                full_name: "Ahmet Yılmaz".to_string(),
                email: "ahmet.yilmaz@begonya.com".to_string(),
                phone: "+90 532 111 22 33".to_string(),
                password_hash: seed_password_hash("ahmet123"),
                role: Role::HomeOwner,
                must_change_password: false,
                auth_provider: AuthProvider::Local,
                google_sub: None,
                avatar_url: None,
                created_at: Utc::now(),
                person_id: Some(1),
            });
        }

        // Seed Unit A Blok D:14 (id: d-14)
        if !self.units.iter().any(|u| u.id == "d-14") {
            let seeded_virtual_iban = VirtualIbanService::generate_virtual_iban(
                VirtualIbanService::KUVEYT_TURK_BANK_CODE,
                "site-1",
                "A",
                14,
            )
            .ok();
            self.units.push(IndependentUnit {
                id: "d-14".to_string(),
                site_id: "site-1".to_string(),
                block_id: "A".to_string(),
                unit_number: 14,
                floor: 4,
                land_share: 24,
                owner_user_id: Some("usr-home-owner-1".to_string()),
                tenant_user_id: None,
                virtual_iban: seeded_virtual_iban,
                house_type: Some("3+1".to_string()),
                created_on: None,
            });
        }

        // Seed initial matching criteria for unit d-14 (Ahmet Yılmaz)
        self.unit_payer_names.insert(
            "d-14".to_string(),
            vec!["Ahmet Yılmaz".to_string(), "Zeynep Kaya".to_string()],
        );
        self.remembered_sender_ibans
            .insert("TR120006200000000000000001".to_string(), "d-14".to_string());
        self.sender_iban_metadata.insert(
            "TR120006200000000000000001".to_string(),
            (
                Some("Garanti BBVA - Maaş Hesabı".to_string()),
                Some("Garanti BBVA".to_string()),
            ),
        );

        let initial_history = vec![
            crate::models::OccupancyHistoryItem {
                id: 1,
                unit_id: 14,
                person_id: 1,
                person_name: "Ahmet Yılmaz".to_string(),
                person_phone: Some("+90 532 111 22 33".to_string()),
                person_email: Some("ahmet.yilmaz@begonya.com".to_string()),
                role: DebtorType::Owner,
                start_date: "2025-01-01".to_string(),
                end_date: Some("2026-01-01".to_string()),
                is_active: false,
                exit_balance: Decimal::ZERO,
                notes: Some("Ev sahibi taşındı, kiraya verildi".to_string()),
                created_at: Utc::now(),
            },
            crate::models::OccupancyHistoryItem {
                id: 2,
                unit_id: 14,
                person_id: 2,
                person_name: "Zeynep Kaya".to_string(),
                person_phone: Some("+90 542 333 44 55".to_string()),
                person_email: Some("zeynep@example.com".to_string()),
                role: DebtorType::Tenant,
                start_date: "2026-01-01".to_string(),
                end_date: None,
                is_active: true,
                exit_balance: Decimal::ZERO,
                notes: Some("Aktif kiracı (Zeynep Kaya)".to_string()),
                created_at: Utc::now(),
            },
        ];
        self.unit_occupancies
            .insert("d-14".to_string(), initial_history.clone());
        self.unit_occupancies
            .insert("14".to_string(), initial_history);

        // Seed September 2026 Dues only when actively executing cargo test suites
        let is_running_test = cfg!(test) || Self::is_running_fixture_test_binary();

        if is_running_test && !self.dues.iter().any(|d| d.id == "b-101") {
            self.dues.push(DuesLiability {
                id: "b-101".to_string(),
                unit_id: "d-14".to_string(),
                period: "Eylül 2026".to_string(),
                principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
                delay_penalty: Decimal::ZERO,
                total_amount: Decimal::from_str_exact("1400.00").unwrap(),
                due_date: NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
                status: DebtStatus::Pending,
                paid_principal: Decimal::ZERO,
                paid_penalty: Decimal::ZERO,
                debtor_type: DebtorType::Tenant,
                expense_type: ExpenseType::OperationalDues,
                penalty_accrued_through: None,
                grace_days: 0,
            });
        }

        // Seed pending registration
        if !self
            .pending_registrations
            .iter()
            .any(|r| r.request_id == "req-seed-01")
        {
            self.pending_registrations
                .push(PendingRegistrationResponse {
                    request_id: "req-seed-01".to_string(),
                    site_id: "site-1".to_string(),
                    block: "B Blok".to_string(),
                    unit_no: 18,
                    floor: 5,
                    full_name: "Kerem Yılmaz".to_string(),
                    email: "kerem.yilmaz@gmail.com".to_string(),
                    phone: "+90 533 111 22 33".to_string(),
                    is_resident: true,
                    status: RegistrationStatus::Pending,
                    submitted_at: Utc::now(),
                });
        }

        // Seed household member
        self.unit_members.insert(
            "d-14".to_string(),
            vec![UnitMemberDto {
                resident_id: "usr-ahmet-14".to_string(),
                full_name: "Ahmet Yılmaz".to_string(),
                relationship: "Kat Maliki (Ev Sahibi)".to_string(),
                phone: "+90 532 111 22 33".to_string(),
                email: "ahmet.yilmaz@begonya.com".to_string(),
                is_owner: true,
                occupancy_id: Some(1),
                person_id: None,
                resident_user_id: None,
            }],
        );

        // Seed Bank Account for Begonya Sitesi (site-1)
        if !self
            .site_bank_accounts
            .iter()
            .any(|b| b.id == "sba-site-1-kt")
        {
            self.site_bank_accounts.push(SiteBankAccount {
                id: "sba-site-1-kt".to_string(),
                site_id: "site-1".to_string(),
                bank_code: "KUVEYT_TURK".to_string(),
                bank_name: "Kuveyt Türk Katılım Bankası".to_string(),
                iban: "TR620020500009863791600001".to_string(),
                account_holder: "Begonya Sitesi Yönetimi".to_string(),
                statement_format: BankStatementFormat::Excel,
                is_active: true,
                configured_by: Some("usr-site-manager-1".to_string()),
                created_at: Utc::now(),
                updated_at: Utc::now(),
            });
        }
    }

    /// Backward compatibility alias for seed_test_fixtures
    #[allow(dead_code)]
    /// Display name of a block: units loaded from PostgreSQL carry the numeric
    /// block id, fixtures carry a letter; both resolve through `blocks`.
    /// Always ends in "Blok" (e.g. "A Blok").
    pub fn block_label(&self, block_id: &str) -> String {
        let name = self
            .blocks
            .iter()
            .find(|b| crate::auth::same_id(&b.id, block_id))
            .map(|b| b.block_name.clone())
            .unwrap_or_else(|| block_id.to_string());
        if name.to_lowercase().contains("blok") {
            name
        } else {
            format!("{} Blok", name)
        }
    }

    /// "A Blok D:14" for a unit.
    pub fn unit_label(&self, block_id: &str, unit_number: i32) -> String {
        format!("{} D:{}", self.block_label(block_id), unit_number)
    }

    /// Total advance of a unit (owner + tenant buckets).
    pub fn advance_total(&self, unit_id: &str) -> Decimal {
        self.advance_balances
            .get(unit_id)
            .map(|a| a.total())
            .unwrap_or(Decimal::ZERO)
    }

    /// Advance of one debtor (`OWNER` / `TENANT`) of a unit.
    pub fn advance_of(&self, unit_id: &str, debtor_type: &str) -> Decimal {
        self.advance_balances
            .get(unit_id)
            .map(|a| a.of(debtor_type))
            .unwrap_or(Decimal::ZERO)
    }

    /// Advance remaining for a new in-memory spend after pending exit requests.
    pub fn available_advance_of(&self, unit_id: &str, debtor_type: &str) -> Decimal {
        let reserved = self
            .pending_exit_advance_reservations
            .get(&(unit_id.to_string(), debtor_type.to_string()))
            .copied()
            .unwrap_or(Decimal::ZERO);
        (self.advance_of(unit_id, debtor_type) - reserved).max(Decimal::ZERO)
    }

    pub fn reserve_exit_advance(&mut self, unit_id: &str, debtor_type: &str, amount: Decimal) {
        *self
            .pending_exit_advance_reservations
            .entry((unit_id.to_string(), debtor_type.to_string()))
            .or_default() += amount;
    }

    pub fn release_exit_advance_reservation(
        &mut self,
        unit_id: &str,
        debtor_type: &str,
        amount: Decimal,
    ) {
        let key = (unit_id.to_string(), debtor_type.to_string());
        if let Some(reserved) = self.pending_exit_advance_reservations.get_mut(&key) {
            *reserved = (*reserved - amount).max(Decimal::ZERO);
            if reserved.is_zero() {
                self.pending_exit_advance_reservations.remove(&key);
            }
        }
    }

    /// Adds `delta` (may be negative) to one debtor's advance of a unit.
    pub fn adjust_advance(&mut self, unit_id: &str, debtor_type: &str, delta: Decimal) {
        let entry = self
            .advance_balances
            .entry(unit_id.to_string())
            .or_default();
        *entry.bucket_mut(debtor_type) += delta;
    }

    pub fn seed(&mut self) {
        self.seed_test_fixtures();
    }

    /// Completely wipes all user, site, flat, dues, and transaction data, restoring system to clean slate
    pub fn clear_all_data(&mut self) {
        self.sites.clear();
        self.users.clear();
        self.units.clear();
        self.dues.clear();
        self.pending_registrations.clear();
        self.unit_members.clear();
        self.unit_primary_contacts.clear();
        self.unit_invite_tokens.clear();
        self.reconciliation_queue.clear();
        self.site_bank_accounts.clear();
        self.advance_balances.clear();
        self.pending_exit_advance_reservations.clear();
        self.payment_idempotency.clear();
        self.homeowner_payments.clear();
        self.remembered_sender_ibans.clear();
        self.sender_iban_metadata.clear();
        self.unit_payer_names.clear();
        self.house_types.clear();
        self.blocks.clear();
        self.payment_receipts.clear();
        self.payment_entries.clear();
        self.operating_budgets.clear();
        self.dues_budget_basis.clear();
        self.site_accrual_schedules.clear();
        self.payment_intents.clear();
        self.finance = crate::finance_book::FinanceBook::default();
        self.auto_scheduler_enabled = false;
        self.seed_system_lookups();
    }

    pub fn reset_all_payments_and_balances(&mut self) {
        self.auto_scheduler_enabled = false;
        self.advance_balances.clear();
        self.pending_exit_advance_reservations.clear();
        self.payment_idempotency.clear();
        self.homeowner_payments.clear();
        self.reconciliation_queue.clear();
        self.payment_receipts.clear();
        self.payment_entries.clear();
        self.operating_budgets.clear();
        self.dues_budget_basis.clear();
        self.site_accrual_schedules.clear();
        self.payment_intents.clear();
        self.finance = crate::finance_book::FinanceBook::default();

        // 100% clean slate: ₺0.00 debt
        self.dues.clear();

        // Reset remembered sender IBANs and payer names
        self.remembered_sender_ibans.clear();
        self.sender_iban_metadata.clear();
        self.unit_payer_names.clear();
    }

    pub fn accrue_test_due(&mut self) {
        if !self.units.iter().any(|u| u.id == "d-14") {
            let seeded_virtual_iban = VirtualIbanService::generate_virtual_iban(
                VirtualIbanService::KUVEYT_TURK_BANK_CODE,
                "site-1",
                "A",
                14,
            )
            .ok();
            self.units.push(IndependentUnit {
                id: "d-14".to_string(),
                site_id: "site-1".to_string(),
                block_id: "A".to_string(),
                unit_number: 14,
                floor: 4,
                land_share: 24,
                owner_user_id: Some("usr-home-owner-1".to_string()),
                tenant_user_id: None,
                virtual_iban: seeded_virtual_iban,
                house_type: Some("3+1".to_string()),
                created_on: None,
            });
        }
        if !self
            .dues
            .iter()
            .any(|d| d.unit_id == "d-14" && d.period == "Eylül 2026")
        {
            self.dues.push(DuesLiability {
                id: "b-101".to_string(),
                unit_id: "d-14".to_string(),
                period: "Eylül 2026".to_string(),
                principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
                delay_penalty: Decimal::ZERO,
                total_amount: Decimal::from_str_exact("1400.00").unwrap(),
                due_date: NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
                status: DebtStatus::Pending,
                paid_principal: Decimal::ZERO,
                paid_penalty: Decimal::ZERO,
                debtor_type: DebtorType::Tenant,
                expense_type: ExpenseType::OperationalDues,
                penalty_accrued_through: None,
                grace_days: 0,
            });
        }

        if !self.capital_projects.iter().any(|p| p.id == "cproj-1") {
            self.capital_projects.push(crate::models::CapitalProject {
                id: "cproj-1".to_string(),
                site_id: "site-1".to_string(),
                title: "A & B Blok Asansör Revizyonu ve Yeşil Etiket".to_string(),
                category: CapitalProjectCategory::Elevator,
                description: Some(
                    "TSE standartlarına uyum, motor yenileme ve kabin modernizasyonu".to_string(),
                ),
                total_budget: Decimal::from_str_exact("360000.00").unwrap(),
                allocation_basis: AllocationBasis::ByLandShare,
                target_start_date: NaiveDate::from_ymd_opt(2026, 10, 1).unwrap(),
                target_completion_date: Some(NaiveDate::from_ymd_opt(2027, 1, 15).unwrap()),
                contractor_name: Some("Otis Asansör San. ve Tic. A.Ş.".to_string()),
                contractor_tax_no: Some("6480029182".to_string()),
                contractor_iban: Some("TR120006200000000000000099".to_string()),
                contract_amount: Some(Decimal::from_str_exact("360000.00").unwrap()),
                status: CapitalProjectStatus::Active,
                collected_amount: Decimal::from_str_exact("120000.00").unwrap(),
                disbursed_amount: Decimal::from_str_exact("60000.00").unwrap(),
                remaining_fund_balance: Decimal::from_str_exact("60000.00").unwrap(),
                total_units_count: 12,
                installments_count: 3,
                created_at: Some(Utc::now()),
            });

            self.capital_installments
                .push(crate::models::CapitalProjectInstallment {
                    id: "cinst-1".to_string(),
                    project_id: "cproj-1".to_string(),
                    installment_number: 1,
                    total_installments: 3,
                    due_date: NaiveDate::from_ymd_opt(2026, 10, 31).unwrap(),
                    installment_budget: Decimal::from_str_exact("120000.00").unwrap(),
                    percentage: Decimal::from_str_exact("33.33").unwrap(),
                    is_accrued: true,
                    accrued_at: Some(Utc::now()),
                    created_at: Some(Utc::now()),
                });
            self.capital_installments
                .push(crate::models::CapitalProjectInstallment {
                    id: "cinst-2".to_string(),
                    project_id: "cproj-1".to_string(),
                    installment_number: 2,
                    total_installments: 3,
                    due_date: NaiveDate::from_ymd_opt(2026, 11, 30).unwrap(),
                    installment_budget: Decimal::from_str_exact("120000.00").unwrap(),
                    percentage: Decimal::from_str_exact("33.33").unwrap(),
                    is_accrued: false,
                    accrued_at: None,
                    created_at: Some(Utc::now()),
                });
            self.capital_installments
                .push(crate::models::CapitalProjectInstallment {
                    id: "cinst-3".to_string(),
                    project_id: "cproj-1".to_string(),
                    installment_number: 3,
                    total_installments: 3,
                    due_date: NaiveDate::from_ymd_opt(2026, 12, 31).unwrap(),
                    installment_budget: Decimal::from_str_exact("120000.00").unwrap(),
                    percentage: Decimal::from_str_exact("33.34").unwrap(),
                    is_accrued: false,
                    accrued_at: None,
                    created_at: Some(Utc::now()),
                });

            self.capital_disbursements
                .push(crate::models::CapitalContractorDisbursement {
                    id: "cdis-1".to_string(),
                    project_id: "cproj-1".to_string(),
                    milestone_name: "1. Hakediş: Malzeme Temini ve Sözleşme Avansı (%50)"
                        .to_string(),
                    invoice_number: Some("OTIS-2026-00441".to_string()),
                    amount: Decimal::from_str_exact("60000.00").unwrap(),
                    disbursement_date: NaiveDate::from_ymd_opt(2026, 10, 15).unwrap(),
                    recipient_name: "Otis Asansör San. ve Tic. A.Ş.".to_string(),
                    recipient_iban: "TR120006200000000000000099".to_string(),
                    payment_reference: Some("OTIS-HAKEDIS-1".to_string()),
                    disbursement_method: DisbursementMethod::BankTransfer,
                    notes: Some("Sözleşme gereği peşin avans ödendi".to_string()),
                    created_at: Some(Utc::now()),
                });
        }
    }
}

impl Default for AppState {
    fn default() -> Self {
        Self::new()
    }
}

impl AppState {
    pub fn db_pool(&self) -> Option<&deadpool_postgres::Pool> {
        self.pool.as_ref()
    }

    #[allow(dead_code)]
    pub fn new() -> Self {
        Self {
            security: Arc::default(),
            inner: Arc::new(RwLock::new(AppStateInner::new())),
            pool: None,
            #[cfg(feature = "e2e")]
            e2e_clock: None,
        }
    }

    pub fn with_pool(pool: Option<deadpool_postgres::Pool>) -> Self {
        let mut inner = AppStateInner::new();
        // Server with database pool starts clean and loads strictly from PostgreSQL
        inner.clear_all_data();
        if pool.is_some() {
            // When connected to PostgreSQL, no lookups or users are held/mocked in memory.
            inner.users.clear();
            inner.house_types.clear();
            inner.blocks.clear();
        }
        Self {
            security: Arc::default(),
            inner: Arc::new(RwLock::new(inner)),
            pool,
            #[cfg(feature = "e2e")]
            e2e_clock: crate::e2e_clock::validate_e2e_configuration()
                .ok()
                .filter(|enabled| *enabled)
                .map(|_| Arc::new(crate::e2e_clock::E2eClock::new(Utc::now().date_naive()))),
        }
    }

    /// Creates an in-memory state with an enabled E2E clock for deterministic tests.
    #[cfg(feature = "e2e")]
    pub fn with_e2e_test_clock(date: NaiveDate) -> Self {
        let mut state = Self::new();
        state.e2e_clock = Some(Arc::new(crate::e2e_clock::E2eClock::new(date)));
        state
    }

    /// Rebuilds the in-memory read model from PostgreSQL without holding the
    /// global lock during I/O: a fresh state is loaded first and swapped in
    /// atomically. Settings that do not live in the database (Kuveyt Türk
    /// credentials) are carried over. A no-op without a database.
    pub async fn reload_from_db(&self) -> Result<(), String> {
        let Some(pool) = self.pool.as_ref() else {
            return Ok(());
        };
        let mut fresh = AppStateInner::blank();
        fresh.clear_all_data();
        crate::db::load_all_from_db(pool, &mut fresh)
            .await
            .map_err(|e| format!("Reloading state from PostgreSQL failed: {}", e))?;
        let mut inner = self.inner.write().await;
        fresh.kuveyt_turk_client_id = inner.kuveyt_turk_client_id.take();
        fresh.kuveyt_turk_client_secret = inner.kuveyt_turk_client_secret.take();
        *inner = fresh;
        Ok(())
    }

    #[allow(dead_code)]
    pub fn new_empty() -> Self {
        let mut inner = AppStateInner::new();
        inner.clear_all_data();
        Self {
            security: Arc::default(),
            inner: Arc::new(RwLock::new(inner)),
            pool: None,
            #[cfg(feature = "e2e")]
            e2e_clock: None,
        }
    }

    #[allow(dead_code)]
    pub fn new_with_test_fixtures() -> Self {
        let mut inner = AppStateInner::new();
        inner.seed_test_fixtures();
        Self {
            security: Arc::default(),
            inner: Arc::new(RwLock::new(inner)),
            pool: None,
            #[cfg(feature = "e2e")]
            e2e_clock: None,
        }
    }
}

/// Development fixture accounts fail closed if password initialization fails.
pub fn seed_password_hash(password: &str) -> Option<String> {
    match crate::auth::hash_password(password) {
        Ok(hash) => Some(hash),
        Err(error) => {
            tracing::error!(%error,"Fixture account password unavailable");
            None
        }
    }
}

#[cfg(test)]
mod fixture_detection_tests {
    use super::AppStateInner;
    use rust_decimal::Decimal;

    #[test]
    fn when_test_binary_uses_either_cargo_layout_then_fixtures_are_seeded() {
        // Same file name in target/debug/deps/ (classic) and target/debug/build/<pkg>/<hash>/out/ (Cargo 1.100+).
        assert!(AppStateInner::is_fixture_test_binary(
            "integration_tests-2c11bc1fa6fc1e5c"
        ));
        assert!(AppStateInner::is_fixture_test_binary(
            "integration_tests-376014e7de84e0fc"
        ));
        assert!(AppStateInner::is_fixture_test_binary(
            "sitepulse_backend-0123456789abcdef"
        ));
    }

    #[test]
    fn when_binary_is_the_server_or_another_suite_then_fixtures_are_not_seeded() {
        assert!(!AppStateInner::is_fixture_test_binary("sitepulse-backend"));
        assert!(!AppStateInner::is_fixture_test_binary(
            "payments_phase3_tests-0123456789abcdef"
        ));
        assert!(!AppStateInner::is_fixture_test_binary(""));
    }

    #[test]
    fn pending_exit_reservations_reduce_only_spendable_advance() {
        let mut state = AppStateInner::blank();
        state.adjust_advance("14", "TENANT", Decimal::new(80000, 2));
        state.reserve_exit_advance("14", "TENANT", Decimal::new(30000, 2));

        assert_eq!(state.advance_of("14", "TENANT"), Decimal::new(80000, 2));
        assert_eq!(
            state.available_advance_of("14", "TENANT"),
            Decimal::new(50000, 2)
        );

        state.release_exit_advance_reservation("14", "TENANT", Decimal::new(30000, 2));
        assert_eq!(
            state.available_advance_of("14", "TENANT"),
            Decimal::new(80000, 2)
        );
    }
}
