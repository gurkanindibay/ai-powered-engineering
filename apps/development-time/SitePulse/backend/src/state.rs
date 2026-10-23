use std::collections::HashMap;
use std::sync::Arc;
use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;
use tokio::sync::RwLock;

use crate::models::{
    DebtStatus, DuesLiability, HomeownerPaymentRecord, IndependentUnit, PendingRegistrationResponse,
    ReconciliationMatch, Role, Site, SiteBankAccount, SiteInvitationLinkResponse,
    UnitInviteLinkResponse, UnitMemberDto, User,
};
use crate::services::VirtualIbanService;

#[derive(Clone)]
pub struct AppState {
    pub inner: Arc<RwLock<AppStateInner>>,
    pub pool: Option<deadpool_postgres::Pool>,
}

pub struct AppStateInner {
    pub sites: Vec<Site>,
    pub users: Vec<User>,
    pub units: Vec<IndependentUnit>,
    pub dues: Vec<DuesLiability>,
    pub pending_registrations: Vec<PendingRegistrationResponse>,
    pub unit_members: HashMap<String, Vec<UnitMemberDto>>,
    pub unit_invite_tokens: HashMap<String, UnitInviteLinkResponse>,
    #[allow(dead_code)]
    pub site_invite_tokens: HashMap<String, SiteInvitationLinkResponse>,
    pub reconciliation_queue: Vec<ReconciliationMatch>,
    pub site_bank_accounts: Vec<SiteBankAccount>,
    pub advance_payments: HashMap<String, Decimal>,
    pub homeowner_payments: Vec<HomeownerPaymentRecord>,
    pub remembered_sender_ibans: HashMap<String, String>,
    pub sender_iban_metadata: HashMap<String, (Option<String>, Option<String>)>,
    pub unit_payer_names: HashMap<String, Vec<String>>,
    pub house_types: Vec<crate::models::HouseTypeTariff>,
    pub kuveyt_turk_client_id: Option<String>,
    pub kuveyt_turk_client_secret: Option<String>,
    pub auto_scheduler_enabled: bool,
}

impl AppStateInner {
    pub fn new() -> Self {
        let mut inner = AppStateInner {
            sites: Vec::new(),
            users: Vec::new(),
            units: Vec::new(),
            dues: Vec::new(),
            pending_registrations: Vec::new(),
            unit_members: HashMap::new(),
            unit_invite_tokens: HashMap::new(),
            site_invite_tokens: HashMap::new(),
            reconciliation_queue: Vec::new(),
            site_bank_accounts: Vec::new(),
            advance_payments: HashMap::new(),
            homeowner_payments: Vec::new(),
            remembered_sender_ibans: HashMap::new(),
            sender_iban_metadata: HashMap::new(),
            unit_payer_names: HashMap::new(),
            house_types: Vec::new(),
            kuveyt_turk_client_id: std::env::var("KT_CLIENT_ID").ok(),
            kuveyt_turk_client_secret: std::env::var("KT_CLIENT_SECRET").ok(),
            auto_scheduler_enabled: false,
        };
        inner.seed_system_lookups();
        if Self::should_seed_test_fixtures() {
            inner.seed_test_fixtures();
        }
        inner
    }

    /// Strictly verifies whether the backend is executing in a production environment
    pub fn is_production() -> bool {
        if let Ok(env) = std::env::var("APP_ENV").or_else(|_| std::env::var("ENVIRONMENT")) {
            let lower = env.to_ascii_lowercase();
            if lower == "production" || lower == "prod" || lower == "live" {
                return true;
            }
        }
        false
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
        if let Ok(exe) = std::env::current_exe() {
            let exe_str = exe.to_string_lossy();
            if exe_str.contains("/deps/integration_tests")
                || exe_str.contains("/deps/sitepulse_backend")
                || exe_str.ends_with("test")
            {
                return true;
            }
        }
        cfg!(test)
    }

    /// Essential system lookups and root administrator identity required for platform operation.
    /// Production-safe: contains ZERO mock sites, ZERO flats, and ZERO debts.
    pub fn seed_system_lookups(&mut self) {
        if !self.users.iter().any(|u| u.id == "usr-saas-root" || u.id == "usr-saas-admin-1") {
            self.users.push(User {
                id: "usr-saas-admin-1".to_string(),
                site_id: "site-1".to_string(),
                full_name: "SaaS Platform Admin".to_string(),
                email: "admin@sitepulse.io".to_string(),
                phone: "+90 532 999 0000".to_string(),
                password_hash: Some("ARGON2_HASH_admin123".to_string()),
                role: Role::SaasAdmin,
                must_change_password: false,
                auth_provider: "LOCAL".to_string(),
                google_sub: None,
                avatar_url: None,
                created_at: Utc::now(),
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
                status: "ACTIVE".to_string(),
                plan_type: "PREMIUM".to_string(),
                license_end_date: NaiveDate::from_ymd_opt(2027, 9, 1).unwrap(),
            });
        }

        if !self.sites.iter().any(|s| s.id == "site-2") {
            self.sites.push(Site {
                id: "site-2".to_string(),
                name: "Kardelen Rezidans".to_string(),
                address: "Çankaya, Kardelen Cad. No:8, Ankara".to_string(),
                slug: "kardelen-rezidans".to_string(),
                status: "ACTIVE".to_string(),
                plan_type: "STANDARD".to_string(),
                license_end_date: NaiveDate::from_ymd_opt(2027, 10, 15).unwrap(),
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
                password_hash: Some("ARGON2_HASH_mehmet123".to_string()),
                role: Role::SiteManager,
                must_change_password: false,
                auth_provider: "LOCAL".to_string(),
                google_sub: None,
                avatar_url: None,
                created_at: Utc::now(),
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
                password_hash: Some("ARGON2_HASH_ahmet123".to_string()),
                role: Role::HomeOwner,
                must_change_password: false,
                auth_provider: "LOCAL".to_string(),
                google_sub: None,
                avatar_url: None,
                created_at: Utc::now(),
            });
        }

        // Seed Unit A Blok D:14 (id: d-14)
        if !self.units.iter().any(|u| u.id == "d-14") {
            let seeded_virtual_iban = VirtualIbanService::generate_virtual_iban(
                VirtualIbanService::KUVEYT_TURK_BANK_CODE,
                "site-1",
                "A",
                14,
            );
            self.units.push(IndependentUnit {
                id: "d-14".to_string(),
                site_id: "site-1".to_string(),
                block_id: "A".to_string(),
                unit_number: 14,
                floor: 4,
                land_share: 24,
                owner_user_id: Some("usr-home-owner-1".to_string()),
                tenant_user_id: None,
                virtual_iban: Some(seeded_virtual_iban),
                house_type: Some("3+1".to_string()),
            });
        }

        // Seed initial matching criteria for unit d-14 (Ahmet Yılmaz)
        self.unit_payer_names.insert(
            "d-14".to_string(),
            vec!["Ahmet Yılmaz".to_string(), "Zeynep Kaya".to_string()],
        );
        self.remembered_sender_ibans.insert(
            "TR120006200000000000000001".to_string(),
            "d-14".to_string(),
        );
        self.sender_iban_metadata.insert(
            "TR120006200000000000000001".to_string(),
            (Some("Garanti BBVA - Maaş Hesabı".to_string()), Some("Garanti BBVA".to_string())),
        );

        // Seed September 2026 Dues only when actively executing cargo test suites
        let is_running_test = cfg!(test) || std::env::current_exe().map(|exe| {
            let s = exe.to_string_lossy();
            s.contains("/deps/integration_tests") || s.contains("/deps/sitepulse_backend") || s.ends_with("test")
        }).unwrap_or(false);

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
            });
        }

        // Seed pending registration
        if !self.pending_registrations.iter().any(|r| r.request_id == "req-seed-01") {
            self.pending_registrations.push(PendingRegistrationResponse {
                request_id: "req-seed-01".to_string(),
                site_id: "site-1".to_string(),
                block: "B Blok".to_string(),
                unit_no: 18,
                floor: 5,
                full_name: "Kerem Yılmaz".to_string(),
                email: "kerem.yilmaz@gmail.com".to_string(),
                phone: "+90 533 111 22 33".to_string(),
                is_resident: true,
                status: "PENDING".to_string(),
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
            }],
        );

        // Seed Bank Account for Begonya Sitesi (site-1)
        if !self.site_bank_accounts.iter().any(|b| b.id == "sba-site-1-kt") {
            self.site_bank_accounts.push(SiteBankAccount {
                id: "sba-site-1-kt".to_string(),
                site_id: "site-1".to_string(),
                bank_code: "KUVEYT_TURK".to_string(),
                bank_name: "Kuveyt Türk Katılım Bankası".to_string(),
                iban: "TR620020500009863791600001".to_string(),
                account_holder: "Begonya Sitesi Yönetimi".to_string(),
                statement_format: "EXCEL".to_string(),
                is_active: true,
                configured_by: Some("usr-site-manager-1".to_string()),
                created_at: Utc::now(),
                updated_at: Utc::now(),
            });
        }
    }

    /// Backward compatibility alias for seed_test_fixtures
    #[allow(dead_code)]
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
        self.unit_invite_tokens.clear();
        self.site_invite_tokens.clear();
        self.reconciliation_queue.clear();
        self.site_bank_accounts.clear();
        self.advance_payments.clear();
        self.homeowner_payments.clear();
        self.remembered_sender_ibans.clear();
        self.sender_iban_metadata.clear();
        self.unit_payer_names.clear();
        self.auto_scheduler_enabled = false;
        self.seed_system_lookups();
    }

    pub fn reset_all_payments_and_balances(&mut self) {
        self.auto_scheduler_enabled = false;
        self.advance_payments.clear();
        self.homeowner_payments.clear();
        self.reconciliation_queue.clear();

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
            );
            self.units.push(IndependentUnit {
                id: "d-14".to_string(),
                site_id: "site-1".to_string(),
                block_id: "A".to_string(),
                unit_number: 14,
                floor: 4,
                land_share: 24,
                owner_user_id: Some("usr-home-owner-1".to_string()),
                tenant_user_id: None,
                virtual_iban: Some(seeded_virtual_iban),
                house_type: Some("3+1".to_string()),
            });
        }
        if !self.dues.iter().any(|d| d.unit_id == "d-14" && d.period == "Eylül 2026") {
            self.dues.push(DuesLiability {
                id: "b-101".to_string(),
                unit_id: "d-14".to_string(),
                period: "Eylül 2026".to_string(),
                principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
                delay_penalty: Decimal::ZERO,
                total_amount: Decimal::from_str_exact("1400.00").unwrap(),
                due_date: NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
                status: DebtStatus::Pending,
            });
        }
    }
}

impl AppState {
    #[allow(dead_code)]
    pub fn new() -> Self {
        Self {
            inner: Arc::new(RwLock::new(AppStateInner::new())),
            pool: None,
        }
    }

    pub fn with_pool(pool: Option<deadpool_postgres::Pool>) -> Self {
        let mut inner = AppStateInner::new();
        // Server with database pool starts clean and loads strictly from PostgreSQL
        inner.clear_all_data();
        inner.seed_system_lookups();
        Self {
            inner: Arc::new(RwLock::new(inner)),
            pool,
        }
    }

    #[allow(dead_code)]
    pub fn new_empty() -> Self {
        let mut inner = AppStateInner::new();
        inner.clear_all_data();
        Self {
            inner: Arc::new(RwLock::new(inner)),
            pool: None,
        }
    }

    #[allow(dead_code)]
    pub fn new_with_test_fixtures() -> Self {
        let mut inner = AppStateInner::new();
        inner.seed_test_fixtures();
        Self {
            inner: Arc::new(RwLock::new(inner)),
            pool: None,
        }
    }
}

