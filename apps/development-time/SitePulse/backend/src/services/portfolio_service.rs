//! Management-company portfolio and fee invoicing, SPEC-009 R13 (verify the
//! e-document duties with a mali müşavir).
//!
//! A professional management company runs several sites. Its members (site
//! managers) and SaaS admins see one summary row per site. The company's
//! monthly fee per site is invoiced through the `EInvoiceIntegrator` port:
//! e-Fatura when the buyer has a VKN, otherwise e-Arşiv (a site is generally
//! not a taxpayer).

use chrono::{Datelike, NaiveDate, Utc};
use rust_decimal::{Decimal, RoundingStrategy};

use crate::db::finance_store::FinanceStore;
use crate::domain::tax_id::TaxId;
use crate::finance_book::col;
use crate::models::*;
use crate::services::dues_ledger;
use crate::services::finance_common::*;
use crate::state::{AppState, AppStateInner};

/// Default VAT on management services (verify the current rate).
pub const DEFAULT_VAT_PERCENT: i64 = 20;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct IntegratorError(pub String);

/// A GİB-authorised e-invoice integrator (özel entegratör).
pub trait EInvoiceIntegrator: Send + Sync {
    fn name(&self) -> &'static str;
    /// Issues the document and returns its ETTN (UUID).
    fn issue(&self, invoice: &FeeInvoice) -> Result<String, IntegratorError>;
}

pub struct SandboxIntegrator;

impl EInvoiceIntegrator for SandboxIntegrator {
    fn name(&self) -> &'static str {
        "SANDBOX"
    }
    fn issue(&self, _invoice: &FeeInvoice) -> Result<String, IntegratorError> {
        Ok(uuid::Uuid::new_v4().to_string())
    }
}

pub fn configured_integrator() -> Result<Box<dyn EInvoiceIntegrator>, IntegratorError> {
    let name = std::env::var("SITEPULSE_EINVOICE_INTEGRATOR").unwrap_or_else(|_| "SANDBOX".into());
    match name.trim().to_ascii_uppercase().as_str() {
        "SANDBOX" if !crate::state::AppStateInner::is_production() => {
            Ok(Box::new(SandboxIntegrator))
        }
        "SANDBOX" => Err(IntegratorError(
            "No e-invoice integrator is configured for production".into(),
        )),
        other => Err(IntegratorError(format!(
            "e-invoice integrator '{}' is not integrated in this build",
            other
        ))),
    }
}

fn month_bounds(today: NaiveDate) -> (NaiveDate, NaiveDate) {
    let start = NaiveDate::from_ymd_opt(today.year(), today.month(), 1).unwrap_or(today);
    (start, today)
}

fn site_row(inner: &AppStateInner, link: &ManagementCompanySite) -> PortfolioSiteRow {
    let site_id = link.site_id.as_str();
    let today = site_today(inner, site_id);
    let (start, end) = month_bounds(today);
    let dues: Vec<&DuesLiability> = site_dues(inner, site_id).collect();
    let month: Vec<&&DuesLiability> = dues
        .iter()
        .filter(|d| d.due_date >= start && d.due_date <= end)
        .collect();
    let due_sum: Decimal = month.iter().map(|d| d.principal_amount).sum();
    let paid_sum: Decimal = month.iter().map(|d| d.paid_principal).sum();
    PortfolioSiteRow {
        site_id: site_id.to_string(),
        site_name: site_name(inner, site_id),
        units: site_units(inner, site_id).count(),
        open_receivables: dues
            .iter()
            .filter(|d| is_open(d))
            .map(|d| dues_ledger::outstanding(d))
            .sum(),
        overdue_items: dues
            .iter()
            .filter(|d| is_open(d) && d.fee_due_date() < today)
            .count(),
        collection_rate_this_month: crate::domain::collection_metrics::collection_rate(
            due_sum, paid_sum,
        ),
        open_cases: inner
            .finance
            .cases
            .iter()
            .filter(|c| crate::auth::same_id(&c.site_id, site_id) && c.closed_at.is_none())
            .count(),
        pending_expense_approvals: inner
            .finance
            .expenses
            .iter()
            .filter(|e| crate::auth::same_id(&e.site_id, site_id) && e.status == EXPENSE_PENDING)
            .count(),
        monthly_fee: link.monthly_fee,
    }
}

pub struct PortfolioService {
    store: FinanceStore,
}

impl PortfolioService {
    pub fn new(state: &AppState) -> Self {
        Self {
            store: FinanceStore::new(state),
        }
    }

    pub async fn create_company(
        &self,
        req: CreateCompanyRequest,
    ) -> FinanceResult<ManagementCompany> {
        let tax = TaxId::parse(&req.tax_id).map_err(|e| invalid(e.to_string()))?;
        let exists = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .companies
                    .iter()
                    .any(|c| c.tax_id == tax.as_str())
            })
            .await;
        if exists {
            return Err(conflict(format!(
                "A company with tax id {} exists",
                tax.as_str()
            )));
        }
        let company = ManagementCompany {
            id: 0,
            name: non_empty(&req.name, 2, "name")?,
            tax_id: tax.as_str().to_string(),
            tax_office: non_empty(&req.tax_office, 2, "tax_office")?,
            address: opt_text(&req.address),
            created_at: Utc::now(),
        };
        Ok(self.store.insert(company, col::companies).await?)
    }

    pub async fn companies(&self) -> Vec<ManagementCompany> {
        self.store
            .read(|inner| inner.finance.companies.clone())
            .await
    }

    async fn company(&self, id: i64) -> FinanceResult<ManagementCompany> {
        self.store
            .read(|inner| inner.finance.companies.iter().find(|c| c.id == id).cloned())
            .await
            .ok_or_else(|| not_found(format!("Company {} not found", id)))
    }

    pub async fn attach_site(
        &self,
        company_id: i64,
        req: AttachSiteRequest,
    ) -> FinanceResult<ManagementCompanySite> {
        self.company(company_id).await?;
        if req.monthly_fee < Decimal::ZERO || req.monthly_fee.scale() > 2 {
            return Err(invalid(
                "monthly_fee must be zero or positive with at most 2 decimals",
            ));
        }
        let vat = req
            .vat_rate
            .unwrap_or_else(|| Decimal::from(DEFAULT_VAT_PERCENT));
        if vat < Decimal::ZERO || vat > Decimal::ONE_HUNDRED {
            return Err(invalid("vat_rate is a percentage"));
        }
        let (site, taken) = self
            .store
            .read(|inner| {
                let site = inner
                    .sites
                    .iter()
                    .find(|s| crate::auth::same_id(&s.id, &req.site_id))
                    .map(|s| s.id.clone());
                let taken = inner
                    .finance
                    .company_sites
                    .iter()
                    .any(|l| crate::auth::same_id(&l.site_id, &req.site_id));
                (site, taken)
            })
            .await;
        let site = site.ok_or_else(|| not_found(format!("Site {} not found", req.site_id)))?;
        if taken {
            return Err(conflict("The site is already managed by a company"));
        }
        let link = ManagementCompanySite {
            id: 0,
            company_id,
            site_id: site,
            monthly_fee: req.monthly_fee,
            vat_rate: vat,
            active: true,
        };
        Ok(self.store.insert(link, col::company_sites).await?)
    }

    pub async fn add_member(
        &self,
        company_id: i64,
        req: AddMemberRequest,
    ) -> FinanceResult<ManagementCompanyMember> {
        self.company(company_id).await?;
        let user = non_empty(&req.user_ref, 1, "user_ref")?;
        let exists =
            self.store
                .read(|inner| {
                    inner.finance.company_members.iter().any(|m| {
                        m.company_id == company_id && crate::auth::same_id(&m.user_ref, &user)
                    })
                })
                .await;
        if exists {
            return Err(conflict("The user is already a member"));
        }
        let member = ManagementCompanyMember {
            id: 0,
            company_id,
            user_ref: user,
        };
        Ok(self.store.insert(member, col::company_members).await?)
    }

    /// SaaS admins see every company; anyone else must be a member.
    pub async fn summary(
        &self,
        caller: &Caller,
        company_id: i64,
    ) -> FinanceResult<PortfolioSummary> {
        let company = self.company(company_id).await?;
        self.store
            .read(|inner| {
                let member = inner.finance.company_members.iter().any(|m| {
                    m.company_id == company_id && crate::auth::same_id(&m.user_ref, &caller.user_id)
                });
                if caller.role != Role::SaasAdmin && !member {
                    return Err(FinanceError::Forbidden(
                        "You are not a member of this company".into(),
                    ));
                }
                let sites: Vec<PortfolioSiteRow> = inner
                    .finance
                    .company_sites
                    .iter()
                    .filter(|l| l.company_id == company_id && l.active)
                    .map(|l| site_row(inner, l))
                    .collect();
                Ok(PortfolioSummary {
                    total_receivables: sites.iter().map(|s| s.open_receivables).sum(),
                    total_monthly_fees: sites.iter().map(|s| s.monthly_fee).sum(),
                    company,
                    sites,
                })
            })
            .await
    }

    /// Issues one fee invoice per active site for `YYYY-MM`, once.
    pub async fn issue_invoices(
        &self,
        company_id: i64,
        req: IssueFeeInvoicesRequest,
    ) -> FinanceResult<Vec<FeeInvoice>> {
        let period = req.period.trim().to_string();
        let valid = period.len() == 7
            && NaiveDate::parse_from_str(&format!("{}-01", period), "%Y-%m-%d").is_ok();
        if !valid {
            return Err(invalid("period must be YYYY-MM"));
        }
        self.company(company_id).await?;
        let integrator = configured_integrator().map_err(|e| FinanceError::Unavailable(e.0))?;
        let todo: Vec<(ManagementCompanySite, Option<String>)> = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .company_sites
                    .iter()
                    .filter(|l| {
                        l.company_id == company_id && l.active && l.monthly_fee > Decimal::ZERO
                    })
                    .filter(|l| {
                        !inner.finance.fee_invoices.iter().any(|f| {
                            f.company_id == company_id
                                && f.site_id == l.site_id
                                && f.period == period
                                && f.status == "ISSUED"
                        })
                    })
                    .map(|l| {
                        let tax = inner
                            .sites
                            .iter()
                            .find(|s| crate::auth::same_id(&s.id, &l.site_id))
                            .and_then(|s| s.tax_id.clone());
                        (l.clone(), tax)
                    })
                    .collect()
            })
            .await;
        let mut out = Vec::new();
        for (link, buyer_tax) in todo {
            let vat = (link.monthly_fee * link.vat_rate / Decimal::ONE_HUNDRED)
                .round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven);
            let e_fatura = buyer_tax
                .as_deref()
                .and_then(|t| TaxId::parse(t).ok())
                .is_some_and(|t| t.is_legal_entity());
            let mut invoice = FeeInvoice {
                id: 0,
                company_id,
                site_id: link.site_id.clone(),
                period: period.clone(),
                net_amount: link.monthly_fee,
                vat_amount: vat,
                total_amount: link.monthly_fee + vat,
                document_type: if e_fatura { "E_FATURA" } else { "E_ARSIV" }.to_string(),
                status: "ISSUED".into(),
                integrator: integrator.name().to_string(),
                integrator_uuid: String::new(),
                issued_at: Utc::now(),
            };
            invoice.integrator_uuid = integrator
                .issue(&invoice)
                .map_err(|e| FinanceError::Unavailable(e.0))?;
            out.push(self.store.insert(invoice, col::fee_invoices).await?);
        }
        Ok(out)
    }

    pub async fn invoices(&self, company_id: i64) -> Vec<FeeInvoice> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .fee_invoices
                    .iter()
                    .filter(|f| f.company_id == company_id)
                    .cloned()
                    .collect()
            })
            .await
    }
}
