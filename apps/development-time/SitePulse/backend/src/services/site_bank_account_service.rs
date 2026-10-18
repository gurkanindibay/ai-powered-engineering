use chrono::Utc;
use uuid::Uuid;

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
    pub async fn get_active_account(
        &self,
        site_id: &str,
    ) -> Option<BankAccountConfigResponse> {
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
        let bank = SupportedBank::from_code(&req.bank_code)
            .ok_or_else(|| format!("Unknown bank code '{}'. See /api/v1/site-admin/banks for supported banks.", req.bank_code))?;

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
        let new_id = format!("sba-{}", Uuid::new_v4().simple());

        let new_account = SiteBankAccount {
            id: new_id,
            site_id: site_id.to_string(),
            bank_code: bank.as_code().to_string(),
            bank_name: bank.display_name().to_string(),
            iban: iban_clean,
            account_holder: req.account_holder.trim().to_string(),
            statement_format: format_str.to_string(),
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

        if let Some(ref pool) = self.state.pool {
            let pool = pool.clone();
            let acc = new_account.clone();
            tokio::spawn(async move {
                let _ = crate::db::save_site_bank_account(&pool, &acc).await;
            });
        }

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
            .map(|b| {
                let fmt = match b.statement_format() {
                    BankStatementFormat::Excel => "EXCEL",
                    BankStatementFormat::Csv => "CSV",
                    BankStatementFormat::Mt940 => "MT940",
                    BankStatementFormat::Auto => "AUTO",
                };
                SupportedBankEntry {
                    code: b.as_code().to_string(),
                    display_name: b.display_name().to_string(),
                    statement_format: fmt.to_string(),
                }
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
            statement_format: a.statement_format.clone(),
            is_active: a.is_active,
            configured_by: a.configured_by.clone(),
            updated_at: a.updated_at,
        }
    }
}
