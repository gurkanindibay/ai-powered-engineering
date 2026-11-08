use chrono::Utc;

use crate::models::{
    BankAccountConfigResponse, BankStatementFormat, ConfigureBankAccountRequest, SiteBankAccount,
    SupportedBank, SupportedBankEntry,
};
use crate::state::AppState;

/// Service responsible for reading and updating the active bank account for a site.
/// Invariant: at most one `SiteBankAccount` with `is_active == true` exists per site.
pub struct SiteBankAccountService {
    state: AppState,
}

impl SiteBankAccountService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    /// Returns the currently active bank account for the given site, or `None` if not yet
    /// configured.
    pub async fn get_active_account(&self, site_id: &str) -> Option<BankAccountConfigResponse> {
        if let Some(ref pool) = self.state.pool {
            if let Ok(Some(account)) = crate::db::get_active_site_bank_account(pool, site_id).await
            {
                return Some(Self::to_response(&account));
            }
        }

        let inner = self.state.inner.read().await;
        inner
            .site_bank_accounts
            .iter()
            .find(|a| a.site_id == site_id && a.is_active)
            .map(Self::to_response)
    }

    /// Configures (or replaces) the active bank account for the site.
    ///
    /// Rules:
    /// 1. Validate that the provided `bank_code` maps to a known `SupportedBank`.
    /// 2. Validate that the IBAN starts with "TR" and is 26 characters long.
    /// 3. Deactivate any existing active account for this site.
    /// 4. Create a new active `SiteBankAccount` with the format automatically derived from the bank.
    pub async fn configure_account(
        &self,
        site_id: &str,
        req: ConfigureBankAccountRequest,
    ) -> Result<BankAccountConfigResponse, String> {
        // --- Validate bank code ---
        let bank = SupportedBank::from_code(&req.bank_code).ok_or_else(|| {
            format!(
                "Unknown bank code '{}'. See /api/v1/site-admin/banks for supported banks.",
                req.bank_code
            )
        })?;

        // --- Validate IBAN ---
        let iban_clean = req.iban.replace(' ', "").to_uppercase();
        if !iban_clean.starts_with("TR") || iban_clean.len() != 26 {
            return Err(
                "Invalid IBAN. Turkish IBANs must start with 'TR' and be 26 characters long."
                    .to_string(),
            );
        }
        if req.account_holder.trim().is_empty() {
            return Err("Account holder name is required.".to_string());
        }

        let format: BankStatementFormat = bank.statement_format();
        let format_str = match format {
            BankStatementFormat::Excel => "EXCEL",
            BankStatementFormat::Csv => "CSV",
            BankStatementFormat::Mt940 => "MT940",
            BankStatementFormat::Auto => "AUTO",
        };

        let now = Utc::now();
        let new_id = if let Some(ref pool) = self.state.pool {
            let client = pool.get().await.map_err(|e| e.to_string())?;
            let site_id_num = crate::db::require_id("entity", site_id)?;
            let config_by_num = req
                .configured_by
                .as_deref()
                .and_then(crate::db::parse_id_to_i64);
            client.execute(
                "UPDATE site_bank_accounts SET is_active = false, updated_at = CURRENT_TIMESTAMP WHERE site_id = $1 AND is_active = true",
                &[&site_id_num],
            ).await.map_err(|e| e.to_string())?;

            let row = client.query_one(
                r#"
                INSERT INTO site_bank_accounts (site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by, created_at, updated_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                RETURNING id
                "#,
                &[
                    &site_id_num,
                    &bank.as_code().to_string(),
                    &bank.display_name().to_string(),
                    &iban_clean,
                    &req.account_holder.trim().to_string(),
                    &format_str.to_string(),
                    &true,
                    &config_by_num,
                    &now,
                    &now,
                ],
            ).await.map_err(|e| e.to_string())?;
            let db_id: i64 = row.get(0);
            db_id.to_string()
        } else {
            let inner = self.state.inner.read().await;
            let max_id = inner
                .site_bank_accounts
                .iter()
                .filter_map(|b| crate::db::parse_id_to_i64(&b.id))
                .max()
                .unwrap_or(0);
            (max_id + 1).to_string()
        };

        let new_account = SiteBankAccount {
            id: new_id,
            site_id: site_id.to_string(),
            bank_code: bank.as_code().to_string(),
            bank_name: bank.display_name().to_string(),
            iban: iban_clean,
            account_holder: req.account_holder.trim().to_string(),
            statement_format: format,
            is_active: true,
            configured_by: req.configured_by,
            created_at: now,
            updated_at: now,
        };

        let response = Self::to_response(&new_account);

        let mut inner = self.state.inner.write().await;
        // Deactivate any existing active account for this site
        for existing in inner.site_bank_accounts.iter_mut() {
            if existing.site_id == site_id && existing.is_active {
                existing.is_active = false;
                existing.updated_at = now;
            }
        }
        inner.site_bank_accounts.push(new_account.clone());

        Ok(response)
    }

    /// Returns the catalogue of all supported banks with their auto-set formats.
    /// Used to populate the bank selector dropdown in the UI.
    pub fn list_supported_banks() -> Vec<SupportedBankEntry> {
        const ALL_BANKS: &[SupportedBank] = &[
            SupportedBank::KuveytTurk,
            SupportedBank::IsBankasi,
            SupportedBank::ZiraatBankasi,
            SupportedBank::GarantiBbva,
            SupportedBank::AkBank,
            SupportedBank::YapiKredi,
            SupportedBank::Halkbank,
            SupportedBank::Vakifbank,
            SupportedBank::DenizBank,
            SupportedBank::QnbFinansbank,
        ];

        ALL_BANKS
            .iter()
            .map(|b| SupportedBankEntry {
                code: b.as_code().to_string(),
                display_name: b.display_name().to_string(),
                statement_format: b.statement_format(),
            })
            .collect()
    }

    // --- Private helpers ---

    fn to_response(a: &SiteBankAccount) -> BankAccountConfigResponse {
        BankAccountConfigResponse {
            id: a.id.clone(),
            site_id: a.site_id.clone(),
            bank_code: a.bank_code.clone(),
            bank_name: a.bank_name.clone(),
            iban: a.iban.clone(),
            account_holder: a.account_holder.clone(),
            statement_format: a.statement_format,
            is_active: a.is_active,
            configured_by: a.configured_by.clone(),
            updated_at: a.updated_at,
        }
    }
}
