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
    pub kuveyt_turk_client_id: Option<String>,
    pub kuveyt_turk_client_secret: Option<String>,
}

impl AppState {
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
            kuveyt_turk_client_id: std::env::var("KT_CLIENT_ID").ok(),
            kuveyt_turk_client_secret: std::env::var("KT_CLIENT_SECRET").ok(),
        };

        // Seed Begonya Sitesi
        inner.sites.push(Site {
            id: "site-1".to_string(),
            name: "Begonya Sitesi".to_string(),
            address: "Ataşehir, Begonya Sok. No:14, İstanbul".to_string(),
            slug: "begonya-sitesi".to_string(),
            status: "ACTIVE".to_string(),
            plan_type: "PREMIUM".to_string(),
            license_end_date: NaiveDate::from_ymd_opt(2027, 9, 1).unwrap(),
        });

        inner.sites.push(Site {
            id: "site-2".to_string(),
            name: "Kardelen Rezidans".to_string(),
            address: "Çankaya, Kardelen Cad. No:8, Ankara".to_string(),
            slug: "kardelen-rezidans".to_string(),
            status: "ACTIVE".to_string(),
            plan_type: "STANDARD".to_string(),
            license_end_date: NaiveDate::from_ymd_opt(2027, 10, 15).unwrap(),
        });

        // Seed Users
        // 1. Site Manager (Mehmet Demir)
        inner.users.push(User {
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

        // 2. Home Owner (Ahmet Yılmaz)
        inner.users.push(User {
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

        // 3. SaaS Admin
        inner.users.push(User {
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

        // Seed Unit A Blok D:14 (id: d-14)
        let seeded_virtual_iban = VirtualIbanService::generate_virtual_iban(
            VirtualIbanService::KUVEYT_TURK_BANK_CODE,
            "site-1",
            "A",
            14,
        );
        inner.units.push(IndependentUnit {
            id: "d-14".to_string(),
            site_id: "site-1".to_string(),
            block_id: "A".to_string(),
            unit_number: 14,
            floor: 4,
            land_share: 24,
            owner_user_id: Some("usr-home-owner-1".to_string()),
            tenant_user_id: None,
            virtual_iban: Some(seeded_virtual_iban),
        });

        // Seed initial matching criteria for unit d-14 (Ahmet Yılmaz)
        inner.unit_payer_names.insert(
            "d-14".to_string(),
            vec!["Ahmet Yılmaz".to_string(), "Zeynep Kaya".to_string()],
        );
        inner.remembered_sender_ibans.insert(
            "TR120006200000000000000001".to_string(),
            "d-14".to_string(),
        );
        inner.sender_iban_metadata.insert(
            "TR120006200000000000000001".to_string(),
            (Some("Garanti BBVA - Maaş Hesabı".to_string()), Some("Garanti BBVA".to_string())),
        );

        // Seed September 2026 Dues (₺1400 overdue 10 days)
        inner.dues.push(DuesLiability {
            id: "b-101".to_string(),
            unit_id: "d-14".to_string(),
            period: "Eylül 2026".to_string(),
            principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
            delay_penalty: Decimal::ZERO,
            total_amount: Decimal::from_str_exact("1400.00").unwrap(),
            due_date: NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
            status: DebtStatus::Pending,
        });

        // Seed pending registration
        inner.pending_registrations.push(PendingRegistrationResponse {
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

        // Seed household member
        inner.unit_members.insert(
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
        inner.site_bank_accounts.push(SiteBankAccount {
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

        Self {
            inner: Arc::new(RwLock::new(inner)),
        }
    }
}
