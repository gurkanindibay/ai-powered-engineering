use std::collections::HashMap;
use std::sync::Arc;
use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;
use tokio::sync::RwLock;

use crate::models::{
    DebtStatus, DuesLiability, IndependentUnit, PendingRegistrationResponse, ReconciliationMatch,
    Role, Site, SiteInvitationLinkResponse, UnitInviteLinkResponse, UnitMemberDto, User,
};

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
        inner.units.push(IndependentUnit {
            id: "d-14".to_string(),
            site_id: "site-1".to_string(),
            block_id: "A".to_string(),
            unit_number: 14,
            floor: 4,
            land_share: 24,
            owner_user_id: Some("usr-home-owner-1".to_string()),
            tenant_user_id: None,
        });

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

        Self {
            inner: Arc::new(RwLock::new(inner)),
        }
    }
}
