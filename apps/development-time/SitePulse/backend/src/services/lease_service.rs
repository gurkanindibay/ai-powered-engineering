//! KMK 22 tenant joint liability with the rent cap, SPEC-009 R3 (verify).
//!
//! The internal dual ledger stays as it is (who is billed); this service adds
//! the legal view: how much of the owner's open operational dues the site may
//! claim from the tenant, capped at the rent the tenant still owes.

use chrono::Utc;
use rust_decimal::Decimal;

use crate::db::finance_store::FinanceStore;
use crate::domain::joint_liability::{self, Lease};
use crate::finance_book::col;
use crate::models::*;
use crate::services::dues_ledger;
use crate::services::finance_common::*;
use crate::services::receipt_document::{try_amount, DocSection, DocTable, TextDocument};
use crate::state::AppState;

pub const KMK22_NOTE: &str = "KMK 22: kiracı, kat malikinin ortak gider ve avans borcundan kira bedeli ile sınırlı olarak malikle birlikte sorumludur; kiracının bu kapsamda yaptığı ödeme kira borcundan düşülür (TBK 314; verify).";

fn as_lease(l: &TenancyLease) -> Lease {
    Lease {
        monthly_rent: l.monthly_rent,
        lease_start: l.lease_start,
        lease_end: l.lease_end,
        rent_paid_through: l.rent_paid_through,
    }
}

pub struct LeaseService {
    store: FinanceStore,
}

impl LeaseService {
    pub fn new(state: &AppState) -> Self {
        Self {
            store: FinanceStore::new(state),
        }
    }

    pub async fn list(&self, site_id: &str) -> Vec<TenancyLease> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .leases
                    .iter()
                    .filter(|l| crate::auth::same_id(&l.site_id, site_id))
                    .cloned()
                    .collect()
            })
            .await
    }

    /// Records the unit's lease; the previous active lease of the unit ends.
    pub async fn upsert(
        &self,
        caller: &Caller,
        req: UpsertLeaseRequest,
    ) -> FinanceResult<TenancyLease> {
        money(req.monthly_rent, "monthly_rent")?;
        if req.lease_end.is_some_and(|e| e < req.lease_start) {
            return Err(invalid("lease_end is before lease_start"));
        }
        let tenant_name = non_empty(&req.tenant_name, 2, "tenant_name")?;
        let (unit, previous) = self
            .store
            .read(|inner| {
                let unit = find_unit(inner, &caller.site_id, &req.unit_id)?;
                let previous: Vec<TenancyLease> = inner
                    .finance
                    .leases
                    .iter()
                    .filter(|l| l.active && crate::auth::same_id(&l.unit_id, &unit.id))
                    .cloned()
                    .collect();
                Ok::<_, FinanceError>((unit, previous))
            })
            .await?;
        for mut old in previous {
            old.active = false;
            old.lease_end = old.lease_end.or(Some(req.lease_start));
            self.store.update(old, col::leases).await?;
        }
        let lease = TenancyLease {
            id: 0,
            site_id: caller.site_id.clone(),
            unit_id: unit.id.clone(),
            tenant_name,
            tenant_user_ref: opt_text(&req.tenant_user_ref).or(unit.tenant_user_id.clone()),
            monthly_rent: req.monthly_rent,
            lease_start: req.lease_start,
            lease_end: req.lease_end,
            rent_paid_through: req.rent_paid_through,
            active: true,
            created_by: caller.actor(),
            created_at: Utc::now(),
        };
        Ok(self.store.insert(lease, col::leases).await?)
    }

    /// Owner debts claimable from each tenant, up to the unpaid rent.
    pub async fn joint_exposure(&self, site_id: &str) -> JointExposureReport {
        self.store
            .read(|inner| {
                let as_of = site_today(inner, site_id);
                let mut rows = Vec::new();
                for lease in inner
                    .finance
                    .leases
                    .iter()
                    .filter(|l| l.active && crate::auth::same_id(&l.site_id, site_id))
                {
                    let l = as_lease(lease);
                    if !joint_liability::is_active_on(&l, as_of) {
                        continue;
                    }
                    let owner_open: Decimal = inner
                        .dues
                        .iter()
                        .filter(|d| {
                            crate::auth::same_id(&d.unit_id, &lease.unit_id)
                                && d.debtor_type == DebtorType::Owner
                                && d.expense_type == ExpenseType::OperationalDues
                                && is_open(d)
                        })
                        .map(dues_ledger::outstanding)
                        .sum();
                    rows.push(JointExposureRow {
                        unit_id: lease.unit_id.clone(),
                        unit_label: label_of(inner, &lease.unit_id),
                        tenant_name: lease.tenant_name.clone(),
                        monthly_rent: lease.monthly_rent,
                        claimable_rent_months: joint_liability::claimable_rent_months(&l, as_of),
                        rent_cap: joint_liability::rent_cap(&l, as_of),
                        owner_open_operational: owner_open,
                        claimable_from_tenant: joint_liability::claimable_from_tenant(
                            &l, owner_open, as_of,
                        ),
                    });
                }
                rows.sort_by(|a, b| a.unit_label.cmp(&b.unit_label));
                JointExposureReport {
                    site_id: site_id.to_string(),
                    as_of,
                    total_claimable: rows.iter().map(|r| r.claimable_from_tenant).sum(),
                    rows,
                    legal_note: KMK22_NOTE.to_string(),
                }
            })
            .await
    }

    /// The rent-deduction certificate for a receipt where the tenant paid the
    /// owner's items (`is_rent_offset_eligible`).
    pub async fn rent_deduction_certificate(
        &self,
        site_id: &str,
        receipt: &str,
    ) -> FinanceResult<TextDocument> {
        self.store
            .read(|inner| {
                let r = inner
                    .payment_receipts
                    .iter()
                    .find(|r| {
                        crate::auth::same_id(&r.site_id, site_id)
                            && (r.receipt_number == receipt || r.id.to_string() == receipt)
                    })
                    .ok_or_else(|| not_found(format!("Receipt {} not found", receipt)))?;
                let owner_items: Vec<&AllocationBreakdownItem> = r
                    .allocation_breakdown
                    .iter()
                    .filter(|i| {
                        inner
                            .dues
                            .iter()
                            .find(|d| i.due_id.as_deref() == Some(d.id.as_str()))
                            .is_some_and(|d| d.debtor_type == DebtorType::Owner)
                    })
                    .collect();
                if r.payer_role != DebtorType::Tenant || (!r.is_rent_offset_eligible && owner_items.is_empty()) {
                    return Err(conflict(format!(
                        "Receipt {} is not a tenant payment of the owner's items",
                        r.receipt_number
                    )));
                }
                let deductible: Decimal = if owner_items.is_empty() {
                    r.allocated_principal + r.allocated_penalty
                } else {
                    owner_items.iter().map(|i| i.principal_paid + i.penalty_paid).sum()
                };
                let site = inner.sites.iter().find(|s| crate::auth::same_id(&s.id, site_id));
                let owner = r
                    .on_behalf_of_name
                    .clone()
                    .unwrap_or_else(|| "Kat maliki".into());
                Ok(TextDocument {
                    issuer: site.map(|s| s.name.clone()).unwrap_or_else(|| "Site Yönetimi".into()),
                    issuer_lines: site
                        .and_then(|s| s.tax_id.clone().map(|t| format!("VKN/TCKN {}", t)))
                        .into_iter()
                        .collect(),
                    title: "KİRA BEDELİNDEN MAHSUP BELGESİ".into(),
                    sections: vec![
                        DocSection {
                            rows: vec![
                                ("Makbuz".into(), r.receipt_number.clone()),
                                ("Tarih".into(), r.issued_at.format("%d.%m.%Y").to_string()),
                                ("Bağımsız bölüm".into(), label_of(inner, &r.unit_id)),
                                ("Ödeyen kiracı".into(), r.payer_name.clone()),
                                ("Adına ödenen kat maliki".into(), owner),
                                ("Kiradan düşülecek tutar".into(), try_amount(deductible)),
                            ],
                            ..DocSection::default()
                        },
                        DocSection {
                            heading: Some("Mahsup edilen kalemler".into()),
                            table: Some(DocTable {
                                headers: vec!["Dönem".into(), "Anapara".into(), "Gecikme".into()],
                                rows: r
                                    .allocation_breakdown
                                    .iter()
                                    .map(|i| {
                                        vec![
                                            i.period.clone(),
                                            try_amount(i.principal_paid),
                                            try_amount(i.penalty_paid),
                                        ]
                                    })
                                    .collect(),
                            }),
                            ..DocSection::default()
                        },
                        DocSection {
                            paragraphs: vec![KMK22_NOTE.to_string()],
                            ..DocSection::default()
                        },
                    ],
                    footer: "Bu belge kiracının kat maliki adına yaptığı ödemeyi gösterir; kira sözleşmesinin tarafları arasında mahsup için kullanılabilir.".into(),
                })
            })
            .await
    }
}
