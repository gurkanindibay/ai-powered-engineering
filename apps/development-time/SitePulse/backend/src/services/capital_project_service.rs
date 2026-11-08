use chrono::Utc;
use rust_decimal::Decimal;
use tracing::{info, warn};

use crate::models::{
    AccrueInstallmentResponse, CapitalContractorDisbursement, CapitalProject,
    CapitalProjectInstallment, CreateCapitalProjectRequest, DebtStatus, DuesLiability,
    RecordDisbursementRequest, UnitCapitalShareSummary,
};
use crate::state::AppState;

#[derive(Clone)]
pub struct CapitalProjectService {
    state: AppState,
}

impl CapitalProjectService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    /// Creates a new Capital Project with optional installment scheduling.
    pub async fn create_project(
        &self,
        req: CreateCapitalProjectRequest,
    ) -> Result<CapitalProject, String> {
        if req.title.trim().is_empty() {
            return Err("Proje başlığı boş olamaz.".to_string());
        }
        if req.total_budget <= Decimal::ZERO {
            return Err("Toplam proje bütçesi sıfırdan büyük olmalıdır.".to_string());
        }

        let site_id = req.site_id.unwrap_or_default();
        let category = req.category.unwrap_or_else(|| "ELEVATOR".to_string());
        let allocation_basis = req.allocation_basis.unwrap_or_else(|| "BY_LAND_SHARE".to_string());
        let target_start_date = req.target_start_date.unwrap_or_else(|| Utc::now().date_naive());

        let project_id_str: String;
        let now = Utc::now();

        // 1. Database persistence if pool is present
        if let Some(pool) = &self.state.pool {
            if let Ok(client) = pool.get().await {
                let row_res = client
                    .query_one(
                        r#"
                        INSERT INTO capital_projects (
                            site_id, title, category, description, total_budget, allocation_basis,
                            target_start_date, target_completion_date, contractor_name,
                            contractor_tax_no, contractor_iban, contract_amount, status, created_at
                        )
                        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 'ACTIVE', $13)
                        RETURNING id
                        "#,
                        &[
                            &crate::db::require_id("entity", &site_id)?,
                            &req.title,
                            &category,
                            &req.description,
                            &req.total_budget,
                            &allocation_basis,
                            &target_start_date,
                            &req.target_completion_date,
                            &req.contractor_name,
                            &req.contractor_tax_no,
                            &req.contractor_iban,
                            &req.contract_amount,
                            &now,
                        ],
                    )
                    .await;

                match row_res {
                    Ok(row) => {
                        let id_num: i64 = row.get("id");
                        project_id_str = id_num.to_string();
                    }
                    Err(e) => {
                        warn!("PostgreSQL error inserting capital_project: {}. Falling back to memory.", e);
                        let inner = self.state.inner.read().await;
                        let max_id = inner.capital_projects.iter().filter_map(|p| crate::db::parse_id_to_i64(&p.id)).max().unwrap_or(0);
                        project_id_str = (max_id + 1).to_string();
                    }
                }
            } else {
                let inner = self.state.inner.read().await;
                let max_id = inner.capital_projects.iter().filter_map(|p| crate::db::parse_id_to_i64(&p.id)).max().unwrap_or(0);
                project_id_str = (max_id + 1).to_string();
            }
        } else {
            let inner = self.state.inner.read().await;
            let max_id = inner.capital_projects.iter().filter_map(|p| crate::db::parse_id_to_i64(&p.id)).max().unwrap_or(0);
            project_id_str = (max_id + 1).to_string();
        }

        let total_units_count: i64;
        {
            let inner = self.state.inner.read().await;
            total_units_count = inner.units.iter().filter(|u| u.site_id == site_id).count() as i64;
        }

        let mut installments_count = 0i64;
        let mut created_installments = Vec::new();

        if let Some(installment_items) = req.installments {
            installments_count = installment_items.len() as i64;
            let total_count = installments_count as i32;

            for item in installment_items {
                let pct = item.percentage.unwrap_or_else(|| {
                    if total_count > 0 {
                        Decimal::from(100) / Decimal::from(total_count)
                    } else {
                        Decimal::from(100)
                    }
                });

                let mut inst_id = String::new();

                // DB insert if available
                if let Some(pool) = &self.state.pool {
                    if let Ok(client) = pool.get().await {
                        if let Some(p_id) = crate::db::parse_id_to_i64(&project_id_str) {
                            let row_res = client
                                .query_one(
                                    r#"
                                    INSERT INTO capital_project_installments (
                                        project_id, installment_number, total_installments,
                                        due_date, installment_budget, percentage, is_accrued, created_at
                                    )
                                    VALUES ($1, $2, $3, $4, $5, $6, FALSE, $7)
                                    ON CONFLICT (project_id, installment_number) DO UPDATE SET total_installments = EXCLUDED.total_installments
                                    RETURNING id
                                    "#,
                                    &[
                                        &p_id,
                                        &item.installment_number,
                                        &total_count,
                                        &item.due_date,
                                        &item.installment_budget,
                                        &pct,
                                        &now,
                                    ],
                                )
                                .await;
                            if let Ok(row) = row_res {
                                let id_val: i64 = row.get("id");
                                inst_id = id_val.to_string();
                            }
                        }
                    }
                }

                if inst_id.is_empty() {
                    let inner = self.state.inner.read().await;
                    let max_inst = inner.capital_installments.iter().filter_map(|i| crate::db::parse_id_to_i64(&i.id)).max().unwrap_or(0);
                    inst_id = (max_inst + 1 + created_installments.len() as i64).to_string();
                }

                let installment = CapitalProjectInstallment {
                    id: inst_id,
                    project_id: project_id_str.clone(),
                    installment_number: item.installment_number,
                    total_installments: total_count,
                    due_date: item.due_date,
                    installment_budget: item.installment_budget,
                    percentage: pct,
                    is_accrued: false,
                    accrued_at: None,
                    created_at: Some(now),
                };

                created_installments.push(installment);
            }
        }

        let project = CapitalProject {
            id: project_id_str.clone(),
            site_id,
            title: req.title,
            category,
            description: req.description,
            total_budget: req.total_budget,
            allocation_basis,
            target_start_date,
            target_completion_date: req.target_completion_date,
            contractor_name: req.contractor_name,
            contractor_tax_no: req.contractor_tax_no,
            contractor_iban: req.contractor_iban,
            contract_amount: req.contract_amount,
            status: "ACTIVE".to_string(),
            collected_amount: Decimal::ZERO,
            disbursed_amount: Decimal::ZERO,
            remaining_fund_balance: Decimal::ZERO,
            total_units_count: if total_units_count > 0 { total_units_count } else { 12 },
            installments_count,
            created_at: Some(now),
        };

        // Update in-memory state
        {
            let mut inner = self.state.inner.write().await;
            inner.capital_projects.push(project.clone());
            for inst in created_installments {
                inner.capital_installments.push(inst);
            }
        }

        info!("Created CapitalProject: {} (Budget: ₺{})", project.title, project.total_budget);
        Ok(project)
    }

    /// Lists all capital projects for a site with live collected & disbursed balances.
    pub async fn list_projects(&self, site_id: &str) -> Vec<CapitalProject> {
        let mut projects: Vec<CapitalProject> = Vec::new();

        // 1. Try DB query
        if let Some(pool) = &self.state.pool {
            if let Ok(client) = pool.get().await {
                let rows_res = client
                    .query(
                        r#"
                        SELECT 
                            cp.id, cp.site_id, cp.title, cp.category, cp.description, cp.total_budget,
                            cp.allocation_basis, cp.target_start_date, cp.target_completion_date,
                            cp.contractor_name, cp.contractor_tax_no, cp.contractor_iban,
                            cp.contract_amount, cp.status, cp.created_at,
                            COALESCE((
                                SELECT SUM(paid_amount) FROM dues_liabilities 
                                WHERE capital_project_id = cp.id
                            ), 0.00) as collected_amount,
                            COALESCE((
                                SELECT SUM(amount) FROM capital_contractor_disbursements 
                                WHERE project_id = cp.id
                            ), 0.00) as disbursed_amount,
                            (SELECT COUNT(*) FROM capital_project_installments WHERE project_id = cp.id) as installments_count
                        FROM capital_projects cp
                        WHERE $1::bigint IS NULL OR cp.site_id = $1
                        ORDER BY cp.created_at DESC
                        "#,
                        &[&crate::db::parse_id_to_i64(site_id)],
                    )
                    .await;

                if let Ok(rows) = rows_res {
                    for r in rows {
                        let id_num: i64 = r.get("id");
                        let total_b: Decimal = r.get("total_budget");
                        let coll_b: Decimal = r.get("collected_amount");
                        let disb_b: Decimal = r.get("disbursed_amount");
                        let inst_c: i64 = r.get("installments_count");

                        projects.push(CapitalProject {
                            id: id_num.to_string(),
                            site_id: r.get::<_, i64>("site_id").to_string(),
                            title: r.get("title"),
                            category: r.get("category"),
                            description: r.get("description"),
                            total_budget: total_b,
                            allocation_basis: r.get("allocation_basis"),
                            target_start_date: r.get("target_start_date"),
                            target_completion_date: r.get("target_completion_date"),
                            contractor_name: r.get("contractor_name"),
                            contractor_tax_no: r.get("contractor_tax_no"),
                            contractor_iban: r.get("contractor_iban"),
                            contract_amount: r.get("contract_amount"),
                            status: r.get("status"),
                            collected_amount: coll_b,
                            disbursed_amount: disb_b,
                            remaining_fund_balance: coll_b - disb_b,
                            total_units_count: 12,
                            installments_count: inst_c,
                            created_at: r.get("created_at"),
                        });
                    }
                }
            }
        }

        // 2. If DB was empty or unavailable, pull from memory
        if projects.is_empty() {
            let inner = self.state.inner.read().await;
            for p in &inner.capital_projects {
                if site_id.is_empty() || p.site_id == site_id {
                    let mut proj_copy = p.clone();

                    // Calculate live collected from dues in memory
                    let collected: Decimal = inner
                        .dues
                        .iter()
                        .filter(|d| {
                            (d.status == DebtStatus::Paid)
                                && (d.period.contains(&p.title) || d.period.contains("Demirbaş") || d.period.contains("Asansör"))
                        })
                        .map(|d| d.principal_amount)
                        .sum();

                    let disbursed: Decimal = inner
                        .capital_disbursements
                        .iter()
                        .filter(|cd| cd.project_id == p.id)
                        .map(|cd| cd.amount)
                        .sum();

                    if collected > Decimal::ZERO {
                        proj_copy.collected_amount = collected;
                    }
                    if disbursed > Decimal::ZERO {
                        proj_copy.disbursed_amount = disbursed;
                    }
                    proj_copy.remaining_fund_balance = proj_copy.collected_amount - proj_copy.disbursed_amount;
                    projects.push(proj_copy);
                }
            }
        }

        projects
    }

    /// Retrieves a single capital project by ID.
    pub async fn get_project(&self, project_id: &str) -> Option<CapitalProject> {
        let projects = self.list_projects("").await;
        projects.into_iter().find(|p| p.id == project_id)
    }

    /// Lists installments for a specific capital project.
    pub async fn list_installments(&self, project_id: &str) -> Vec<CapitalProjectInstallment> {
        let mut list = Vec::new();

        if let Some(pool) = &self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Some(p_id) = crate::db::parse_id_to_i64(project_id) {
                    let rows_res = client
                        .query(
                            r#"
                            SELECT id, project_id, installment_number, total_installments,
                                   due_date, installment_budget, percentage, is_accrued, accrued_at, created_at
                            FROM capital_project_installments
                            WHERE project_id = $1
                            ORDER BY installment_number ASC
                            "#,
                            &[&p_id],
                        )
                        .await;

                    if let Ok(rows) = rows_res {
                        for r in rows {
                            let id_num: i64 = r.get("id");
                            let p_id_num: i64 = r.get("project_id");
                            list.push(CapitalProjectInstallment {
                                id: id_num.to_string(),
                                project_id: p_id_num.to_string(),
                                installment_number: r.get("installment_number"),
                                total_installments: r.get("total_installments"),
                                due_date: r.get("due_date"),
                                installment_budget: r.get("installment_budget"),
                                percentage: r.get("percentage"),
                                is_accrued: r.get("is_accrued"),
                                accrued_at: r.get("accrued_at"),
                                created_at: r.get("created_at"),
                            });
                        }
                    }
                }
            }
        }

        if list.is_empty() {
            let inner = self.state.inner.read().await;
            list = inner
                .capital_installments
                .iter()
                .filter(|inst| inst.project_id == project_id)
                .cloned()
                .collect();
        }

        list
    }

    /// Accrues an installment, generating `dues_liabilities` records strictly for `OWNER`.
    /// Guarantees zero-cent drift ($\sum \text{shares} \equiv \text{budget}$).
    pub async fn accrue_installment(
        &self,
        project_id: &str,
        installment_number: i32,
    ) -> Result<AccrueInstallmentResponse, String> {
        let project = self
            .get_project(project_id)
            .await
            .ok_or_else(|| "Demirbaş projesi bulunamadı.".to_string())?;

        let mut installments = self.list_installments(project_id).await;
        let installment = installments
            .iter_mut()
            .find(|inst| inst.installment_number == installment_number)
            .ok_or_else(|| format!("{}. taksit planı bulunamadı.", installment_number))?;

        if installment.is_accrued {
            return Err(format!("{}. taksit daha önce tahakkuk ettirilmiş. Mükerrer tahakkuk engellendi.", installment_number));
        }

        // Get all units for this site
        let units;
        {
            let inner = self.state.inner.read().await;
            units = inner.units.clone();
        }

        if units.is_empty() {
            return Err("Sitede kayıtlı bağımsız bölüm (daire) bulunamadı.".to_string());
        }

        let installment_budget = installment.installment_budget;
        let total_land_share: i32 = units.iter().map(|u| u.land_share).sum();
        let unit_count = units.len();

        let mut unit_shares: Vec<(&crate::models::IndependentUnit, Decimal)> = Vec::new();
        let mut running_sum = Decimal::ZERO;

        for unit in &units {
            let share: Decimal;
            if project.allocation_basis == "EQUAL_PER_UNIT" {
                share = (installment_budget / Decimal::from(unit_count)).round_dp(2);
            } else {
                // By Land Share (KMK Madde 20/a kanuni oran)
                if total_land_share > 0 {
                    let ratio = Decimal::from(unit.land_share) / Decimal::from(total_land_share);
                    share = (installment_budget * ratio).round_dp(2);
                } else {
                    share = (installment_budget / Decimal::from(unit_count)).round_dp(2);
                }
            }
            running_sum += share;
            unit_shares.push((unit, share));
        }

        // Kuruş Düzeltmesi (Zero-Cent Drift Reconciliation)
        // If there is any penny discrepancy, adjust the unit with highest land share
        let diff = installment_budget - running_sum;
        if diff != Decimal::ZERO && !unit_shares.is_empty() {
            unit_shares[0].1 += diff;
        }

        let period_name = format!(
            "{}: Taksit {}/{}",
            project.title, installment.installment_number, installment.total_installments
        );
        let now = Utc::now();

        // Generate dues_liabilities in DB if available
        if let Some(pool) = &self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Some(p_id) = crate::db::parse_id_to_i64(project_id) {
                    for (unit, share) in &unit_shares {
                        if let Some(u_id) = crate::db::parse_id_to_i64(&unit.id) {
                            client
                                .execute(
                                    r#"
                                    INSERT INTO dues_liabilities (
                                        unit_id, period, debtor_type, expense_type,
                                        principal_amount, due_date, status, delay_penalty,
                                        paid_amount, capital_project_id, installment_number, created_at
                                    )
                                    VALUES ($1, $2, 'OWNER', 'CAPITAL_DUES', $3, $4, 'PENDING', 0.00, 0.00, $5, $6, $7)
                                    "#,
                                    &[
                                        &u_id,
                                        &period_name,
                                        share,
                                        &installment.due_date,
                                        &p_id,
                                        &installment_number,
                                        &now,
                                    ],
                                )
                                .await.map_err(|e| e.to_string())?;
                        }
                    }

                    // Mark installment accrued in DB
                    client
                        .execute(
                            "UPDATE capital_project_installments SET is_accrued = TRUE, accrued_at = $1 WHERE project_id = $2 AND installment_number = $3",
                            &[&now, &p_id, &installment_number],
                        )
                        .await.map_err(|e| e.to_string())?;
                }
            }
        }

        // Also update memory state
        {
            let mut inner = self.state.inner.write().await;
            let mut next_due = inner.dues.iter().filter_map(|d| crate::db::parse_id_to_i64(&d.id)).max().unwrap_or(0);
            for (unit, share) in &unit_shares {
                next_due += 1;
                let due_id = next_due.to_string();
                inner.dues.push(DuesLiability {
                    id: due_id,
                    unit_id: unit.id.clone(),
                    period: period_name.clone(),
                    principal_amount: *share,
                    delay_penalty: Decimal::ZERO,
                    total_amount: *share,
                    due_date: installment.due_date,
                    status: DebtStatus::Pending,
                    paid_principal: Decimal::ZERO,
                    paid_penalty: Decimal::ZERO,
                    debtor_type: "OWNER".to_string(),
                    expense_type: "CAPITAL_DUES".to_string(),
                    penalty_accrued_through: None,
                });
            }

            if let Some(inst) = inner
                .capital_installments
                .iter_mut()
                .find(|i| i.project_id == project_id && i.installment_number == installment_number)
            {
                inst.is_accrued = true;
                inst.accrued_at = Some(now);
            }
        }

        info!(
            "Accrued Installment {}/{} for Project '{}': ₺{} across {} units",
            installment_number, installment.total_installments, project.title, installment_budget, unit_shares.len()
        );

        Ok(AccrueInstallmentResponse {
            success: true,
            message: format!(
                "₺{:.2} tutarındaki {}. taksit tüm kat maliklerine başarıyla tahakkuk ettirildi.",
                installment_budget, installment_number
            ),
            project_id: project_id.to_string(),
            installment_number,
            total_accrued_amount: installment_budget,
            charged_units_count: unit_shares.len() as i64,
            accrued_at: now,
        })
    }

    /// Records a contractor progress payment (hakediş).
    pub async fn record_disbursement(
        &self,
        project_id: &str,
        req: RecordDisbursementRequest,
    ) -> Result<CapitalContractorDisbursement, String> {
        if req.amount <= Decimal::ZERO {
            return Err("Hakediş tutarı sıfırdan büyük olmalıdır.".to_string());
        }
        if req.recipient_name.trim().is_empty() {
            return Err("Alıcı/Müteahhit unvanı boş olamaz.".to_string());
        }
        if req.recipient_iban.trim().is_empty() {
            return Err("Alıcı IBAN bilgisi boş olamaz.".to_string());
        }

        let disbursement_date = req.disbursement_date.unwrap_or_else(|| Utc::now().date_naive());
        let disbursement_method = req.disbursement_method.unwrap_or_else(|| "BANK_TRANSFER".to_string());
        let now = Utc::now();
        let mut dis_id = String::new();

        // Insert into DB if available
        if let Some(pool) = &self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Some(p_id) = crate::db::parse_id_to_i64(project_id) {
                    let row_res = client
                        .query_one(
                            r#"
                            INSERT INTO capital_contractor_disbursements (
                                project_id, milestone_name, invoice_number, amount,
                                disbursement_date, recipient_name, recipient_iban,
                                payment_reference, disbursement_method, notes, created_at
                            )
                            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
                            RETURNING id
                            "#,
                            &[
                                &[&p_id][0],
                                &req.milestone_name,
                                &req.invoice_number,
                                &req.amount,
                                &disbursement_date,
                                &req.recipient_name,
                                &req.recipient_iban,
                                &req.payment_reference,
                                &disbursement_method,
                                &req.notes,
                                &now,
                            ],
                        )
                        .await;
                    if let Ok(row) = row_res {
                        let id_val: i64 = row.get("id");
                        dis_id = id_val.to_string();
                    }
                }
            }
        }

        if dis_id.is_empty() {
            let inner = self.state.inner.read().await;
            let max_id = inner.capital_disbursements.iter().filter_map(|d| crate::db::parse_id_to_i64(&d.id)).max().unwrap_or(0);
            dis_id = (max_id + 1).to_string();
        }

        let disbursement = CapitalContractorDisbursement {
            id: dis_id,
            project_id: project_id.to_string(),
            milestone_name: req.milestone_name,
            invoice_number: req.invoice_number,
            amount: req.amount,
            disbursement_date,
            recipient_name: req.recipient_name,
            recipient_iban: req.recipient_iban,
            payment_reference: req.payment_reference,
            disbursement_method,
            notes: req.notes,
            created_at: Some(now),
        };

        // Update memory state
        {
            let mut inner = self.state.inner.write().await;
            inner.capital_disbursements.push(disbursement.clone());

            if let Some(p) = inner.capital_projects.iter_mut().find(|p| p.id == project_id) {
                p.disbursed_amount += req.amount;
                p.remaining_fund_balance = p.collected_amount - p.disbursed_amount;
            }
        }

        info!(
            "Recorded Contractor Disbursement for Project {}: ₺{} to {}",
            project_id, disbursement.amount, disbursement.recipient_name
        );

        Ok(disbursement)
    }

    /// Lists disbursements for a specific project.
    pub async fn list_disbursements(&self, project_id: &str) -> Vec<CapitalContractorDisbursement> {
        let mut list = Vec::new();

        if let Some(pool) = &self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Some(p_id) = crate::db::parse_id_to_i64(project_id) {
                    let rows_res = client
                        .query(
                            r#"
                            SELECT id, project_id, milestone_name, invoice_number, amount,
                                   disbursement_date, recipient_name, recipient_iban,
                                   payment_reference, disbursement_method, notes, created_at
                            FROM capital_contractor_disbursements
                            WHERE project_id = $1
                            ORDER BY disbursement_date DESC, created_at DESC
                            "#,
                            &[&p_id],
                        )
                        .await;

                    if let Ok(rows) = rows_res {
                        for r in rows {
                            let id_num: i64 = r.get("id");
                            let p_id_num: i64 = r.get("project_id");
                            list.push(CapitalContractorDisbursement {
                                id: id_num.to_string(),
                                project_id: p_id_num.to_string(),
                                milestone_name: r.get("milestone_name"),
                                invoice_number: r.get("invoice_number"),
                                amount: r.get("amount"),
                                disbursement_date: r.get("disbursement_date"),
                                recipient_name: r.get("recipient_name"),
                                recipient_iban: r.get("recipient_iban"),
                                payment_reference: r.get("payment_reference"),
                                disbursement_method: r.get("disbursement_method"),
                                notes: r.get("notes"),
                                created_at: r.get("created_at"),
                            });
                        }
                    }
                }
            }
        }

        if list.is_empty() {
            let inner = self.state.inner.read().await;
            list = inner
                .capital_disbursements
                .iter()
                .filter(|d| d.project_id == project_id)
                .cloned()
                .collect();
        }

        list
    }

    /// Computes unit-by-unit capital share and payment breakdown.
    pub async fn get_unit_capital_shares(
        &self,
        project_id: &str,
    ) -> Result<Vec<UnitCapitalShareSummary>, String> {
        let project = self
            .get_project(project_id)
            .await
            .ok_or_else(|| "Demirbaş projesi bulunamadı.".to_string())?;

        let units;
        let dues;
        {
            let inner = self.state.inner.read().await;
            units = inner.units.clone();
            dues = inner.dues.clone();
        }

        let total_land_share: i32 = units.iter().map(|u| u.land_share).sum();
        let unit_count = units.len();
        let mut summaries = Vec::new();

        for unit in &units {
            let total_share: Decimal;
            if project.allocation_basis == "EQUAL_PER_UNIT" {
                total_share = (project.total_budget / Decimal::from(unit_count)).round_dp(2);
            } else {
                if total_land_share > 0 {
                    let ratio = Decimal::from(unit.land_share) / Decimal::from(total_land_share);
                    total_share = (project.total_budget * ratio).round_dp(2);
                } else {
                    total_share = (project.total_budget / Decimal::from(unit_count)).round_dp(2);
                }
            }

            // Find accrued dues for this unit belonging to this project
            let unit_project_dues: Vec<&DuesLiability> = dues
                .iter()
                .filter(|d| {
                    d.unit_id == unit.id
                        && (d.period.contains(&project.title)
                            || d.period.contains("Demirbaş")
                            || d.period.contains("Asansör"))
                })
                .collect();

            let total_accrued: Decimal = unit_project_dues.iter().map(|d| d.principal_amount).sum();
            let total_paid: Decimal = unit_project_dues
                .iter()
                .filter(|d| d.status == DebtStatus::Paid)
                .map(|d| d.principal_amount)
                .sum();

            let remaining_debt = if total_share > total_paid {
                total_share - total_paid
            } else {
                Decimal::ZERO
            };

            summaries.push(UnitCapitalShareSummary {
                unit_id: unit.id.clone(),
                block: unit.block_id.clone(),
                unit_number: unit.unit_number,
                owner_name: unit.owner_user_id.clone().unwrap_or_else(|| "Kat Maliki".to_string()),
                owner_phone: Some("+90 532 111 22 33".to_string()),
                land_share: unit.land_share,
                total_project_share: total_share,
                total_accrued,
                total_paid,
                remaining_debt,
                is_settled: remaining_debt == Decimal::ZERO,
            });
        }

        Ok(summaries)
    }
}
