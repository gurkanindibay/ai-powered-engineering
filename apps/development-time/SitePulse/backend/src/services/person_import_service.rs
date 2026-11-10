//! Bulk registration of owners (and tenants) from a CSV file (person module F8).
//!
//! A dry run parses and checks every row (fields, duplicates inside the file, units
//! and emails already taken, likely duplicate people) and changes nothing. A commit
//! runs the same checks and registers the rows only when none has an error; each row
//! is then registered like a single registration, activation link included.

use std::collections::HashMap;

use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

use crate::authorization::AuthzContext;
use crate::db::Storage;
use crate::domain::email::NormalizedEmail;
use crate::domain::text::fold_turkish;
use crate::models::RegisterHomeOwnerRequest;
use crate::services::person_record_service::{match_reasons, PersonKeys};
use crate::services::site_admin_service::{
    block_code, parse_land_share, validate_email, validate_phone,
};
use crate::services::SiteAdminService;
use crate::state::AppState;

/// Largest file one import takes.
pub const MAX_ROWS: usize = 500;
pub const MAX_BYTES: usize = 1024 * 1024;

/// Columns of the import template, in order.
pub const COLUMNS: [&str; 12] = [
    "block",
    "unit_no",
    "floor",
    "owner_full_name",
    "owner_email",
    "owner_phone",
    "land_share",
    "monthly_dues",
    "is_resident",
    "tenant_full_name",
    "tenant_email",
    "tenant_phone",
];
const REQUIRED: [&str; 5] = [
    "block",
    "unit_no",
    "owner_full_name",
    "owner_email",
    "owner_phone",
];

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PersonImportError {
    #[error("The file has no rows")]
    Empty,
    #[error("The file has more than {MAX_ROWS} rows")]
    TooManyRows,
    #[error("The file is larger than 1 MB")]
    TooLarge,
    #[error("Missing columns: {0}")]
    MissingColumns(String),
    #[error("An unterminated quoted value starts on line {0}")]
    UnterminatedQuote(usize),
    #[error("Person import storage error: {0}")]
    Storage(String),
}

fn storage(e: impl std::fmt::Display) -> PersonImportError {
    PersonImportError::Storage(e.to_string())
}

#[derive(Debug, Clone, Deserialize)]
pub struct ImportRequest {
    pub csv: String,
    #[serde(default)]
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct ImportRow {
    /// Line of the file, counting the header as line 1.
    pub line: usize,
    pub block: String,
    pub unit_no: Option<i32>,
    pub owner_full_name: String,
    pub errors: Vec<String>,
    pub warnings: Vec<String>,
    /// Set by a commit for each registered row.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit_id: Option<String>,
    /// Activation link delivery of the owner (`SENT`, `NOT_SENT` …) after a commit.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub activation: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ImportReport {
    pub dry_run: bool,
    /// The rows were registered; false when any row has an error.
    pub committed: bool,
    pub total: usize,
    pub invalid: usize,
    pub created: usize,
    pub rows: Vec<ImportRow>,
}

/// One parsed line: its line number and cells.
type Record = (usize, Vec<String>);

/// Splits CSV text into a header and records. Takes `,`, `;` (spreadsheets in Turkish
/// locales) or tab, whichever the header uses most; a UTF-8 BOM is ignored; quoted
/// values may hold delimiters, `""` and line breaks.
///
/// # Errors
/// An empty file, too many rows, or an unterminated quote.
pub fn parse_csv(text: &str) -> Result<(Vec<String>, Vec<Record>), PersonImportError> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let first_line = text.lines().next().unwrap_or_default();
    let delimiter = [',', ';', '\t']
        .into_iter()
        .max_by_key(|d| first_line.matches(*d).count())
        .unwrap_or(',');
    let mut records: Vec<Record> = Vec::new();
    let (mut cells, mut cell) = (Vec::new(), String::new());
    let (mut line, mut record_line, mut quoted, mut quote_line) = (1usize, 1usize, false, 0usize);
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' if quoted && chars.peek() == Some(&'"') => {
                chars.next();
                cell.push('"');
            }
            '"' if quoted => quoted = false,
            '"' if cell.trim().is_empty() => {
                cell.clear();
                quoted = true;
                quote_line = line;
            }
            '\n' if quoted => {
                line += 1;
                cell.push('\n');
            }
            '\r' if !quoted => {}
            '\n' => {
                cells.push(std::mem::take(&mut cell));
                records.push((record_line, std::mem::take(&mut cells)));
                line += 1;
                record_line = line;
            }
            c if c == delimiter && !quoted => cells.push(std::mem::take(&mut cell)),
            c => cell.push(c),
        }
    }
    if quoted {
        return Err(PersonImportError::UnterminatedQuote(quote_line));
    }
    if !cell.is_empty() || !cells.is_empty() {
        cells.push(cell);
        records.push((record_line, cells));
    }
    records.retain(|(_, r)| r.iter().any(|c| !c.trim().is_empty()));
    if records.len() < 2 {
        return Err(PersonImportError::Empty);
    }
    if records.len() - 1 > MAX_ROWS {
        return Err(PersonImportError::TooManyRows);
    }
    let header = records
        .remove(0)
        .1
        .into_iter()
        .map(|h| h.trim().to_ascii_lowercase())
        .collect();
    Ok((header, records))
}

/// A money amount as typed in a Turkish or English spreadsheet: `1.250,50`, `1250,5`
/// or `1250.50`.
pub fn parse_amount(raw: &str) -> Option<Decimal> {
    let s: String = raw
        .trim()
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '₺')
        .collect();
    let normalized = if s.contains(',') {
        s.replace('.', "").replace(',', ".")
    } else {
        s
    };
    normalized
        .parse::<Decimal>()
        .ok()
        .filter(|d| !d.is_sign_negative())
}

fn parse_flag(raw: &str) -> Option<bool> {
    match fold_turkish(raw.trim()).as_str() {
        "" | "1" | "true" | "yes" | "y" | "evet" | "e" => Some(true),
        "0" | "false" | "no" | "n" | "hayir" | "h" => Some(false),
        _ => None,
    }
}

/// A row with its errors and, when it has none, the registration it stands for.
pub struct CheckedRow {
    pub row: ImportRow,
    pub request: Option<RegisterHomeOwnerRequest>,
}

/// Field checks and duplicates inside the file; no storage needed.
///
/// # Errors
/// A required column is missing from the header.
pub fn check_rows(
    header: &[String],
    records: &[Record],
) -> Result<Vec<CheckedRow>, PersonImportError> {
    let missing: Vec<&str> = REQUIRED
        .into_iter()
        .filter(|c| !header.iter().any(|h| h == c))
        .collect();
    if !missing.is_empty() {
        return Err(PersonImportError::MissingColumns(missing.join(", ")));
    }
    let index: HashMap<&str, usize> = header
        .iter()
        .enumerate()
        .map(|(i, h)| (h.as_str(), i))
        .collect();
    let mut seen_units: HashMap<(String, i32), usize> = HashMap::new();
    let mut seen_emails: HashMap<String, usize> = HashMap::new();
    let mut checked = Vec::with_capacity(records.len());
    for (line, cells) in records {
        let get = |name: &str| -> String {
            index
                .get(name)
                .and_then(|i| cells.get(*i))
                .map(|v| v.trim().to_string())
                .unwrap_or_default()
        };
        let mut errors: Vec<String> = Vec::new();
        let block = get("block");
        let owner = get("owner_full_name");
        if block.is_empty() {
            errors.push("Blok boş.".into());
        }
        if owner.is_empty() {
            errors.push("Malik adı boş.".into());
        }
        let unit_no = get("unit_no").parse::<i32>().ok().filter(|n| *n > 0);
        if unit_no.is_none() {
            errors.push("Daire numarası pozitif bir tam sayı olmalı.".into());
        }
        let floor_raw = get("floor");
        let floor = if floor_raw.is_empty() {
            Some(0)
        } else {
            floor_raw.parse::<i32>().ok()
        };
        if floor.is_none() {
            errors.push("Kat bir tam sayı olmalı.".into());
        }
        let email = get("owner_email");
        let phone = get("owner_phone");
        if let Err(e) = validate_email(&email) {
            errors.push(format!("Malik e-postası: {e}"));
        }
        if let Err(e) = validate_phone(&phone) {
            errors.push(format!("Malik telefonu: {e}"));
        }
        let land_share = get("land_share");
        if parse_land_share(Some(&land_share)).is_err() {
            errors.push("Arsa payı pozitif bir tam sayı olmalı.".into());
        }
        let dues_raw = get("monthly_dues");
        let monthly_dues = if dues_raw.is_empty() {
            None
        } else {
            parse_amount(&dues_raw)
        };
        if !dues_raw.is_empty() && monthly_dues.is_none() {
            errors.push("Aylık aidat geçerli bir tutar değil.".into());
        }
        let is_resident = parse_flag(&get("is_resident"));
        if is_resident.is_none() {
            errors.push("Oturuyor mu alanı evet ya da hayır olmalı.".into());
        }
        let (tenant_name, tenant_email, tenant_phone) = (
            get("tenant_full_name"),
            get("tenant_email"),
            get("tenant_phone"),
        );
        let has_tenant = [&tenant_name, &tenant_email, &tenant_phone]
            .iter()
            .any(|v| !v.is_empty());
        if has_tenant {
            if tenant_name.is_empty() {
                errors.push("Kiracı adı boş.".into());
            }
            if let Err(e) = validate_email(&tenant_email) {
                errors.push(format!("Kiracı e-postası: {e}"));
            }
            if let Err(e) = validate_phone(&tenant_phone) {
                errors.push(format!("Kiracı telefonu: {e}"));
            }
            if is_resident == Some(true) {
                errors.push(
                    "Malik dairede oturuyorsa kiracı girilemez (oturuyor: hayır yapın).".into(),
                );
            }
        }
        if let Some(n) = unit_no {
            if let Some(first) = seen_units.insert((block_code(&block), n), *line) {
                errors.push(format!("Bu daire dosyada {first}. satırda da var."));
            }
        }
        for address in [&email, &tenant_email]
            .into_iter()
            .filter(|e| !e.is_empty())
        {
            if let Some(first) = seen_emails.insert(NormalizedEmail::normalize(address), *line) {
                errors.push(format!("{address} dosyada {first}. satırda da var."));
            }
        }
        let request = match (errors.is_empty(), unit_no, floor, is_resident) {
            (true, Some(unit_no), Some(floor), Some(is_resident)) => {
                Some(RegisterHomeOwnerRequest {
                    block: block.clone(),
                    unit_no,
                    floor,
                    owner_full_name: owner.clone(),
                    email,
                    phone,
                    tenant_full_name: has_tenant.then(|| tenant_name.clone()),
                    tenant_email: has_tenant.then(|| tenant_email.clone()),
                    tenant_phone: has_tenant.then(|| tenant_phone.clone()),
                    land_share: Some(land_share).filter(|v| !v.is_empty()),
                    monthly_dues,
                    house_type: None,
                    is_resident,
                    role: None,
                })
            }
            _ => None,
        };
        checked.push(CheckedRow {
            row: ImportRow {
                line: *line,
                block,
                unit_no,
                owner_full_name: owner,
                errors,
                ..ImportRow::default()
            },
            request,
        });
    }
    Ok(checked)
}

pub struct PersonImportService {
    state: AppState,
    store: Storage,
}

/// What the site already holds that an import row can collide with.
struct SiteFacts {
    units: Vec<(String, i32)>,
    /// Memory mode keys units by number alone, as its registration does.
    unit_numbers_any_block: Vec<i32>,
    login_emails: Vec<String>,
    people: Vec<(String, PersonKeys)>,
}

impl PersonImportService {
    pub fn new(state: AppState) -> Self {
        let store = Storage::of(&state);
        Self { state, store }
    }

    async fn site_facts(
        &self,
        site_id: &str,
        emails: &[String],
    ) -> Result<SiteFacts, PersonImportError> {
        match &self.store {
            Storage::Postgres(pool) => {
                let site = crate::db::parse_id_to_i64(site_id).unwrap_or_default();
                let client = pool.get().await.map_err(storage)?;
                let units = client
                    .query(
                        "SELECT b.block_name, u.unit_number FROM units u JOIN blocks b ON b.id = u.block_id \
                         WHERE u.site_id = $1 AND u.deleted_at IS NULL",
                        &[&site],
                    )
                    .await
                    .map_err(storage)?
                    .iter()
                    .map(|r| (block_code(r.get::<_, &str>(0)), r.get(1)))
                    .collect();
                // Login emails are unique across the platform, as registration requires.
                let login_emails = client
                    .query(
                        "SELECT lower(email) FROM users WHERE lower(email) = ANY($1)",
                        &[&emails],
                    )
                    .await
                    .map_err(storage)?
                    .iter()
                    .map(|r| r.get(0))
                    .collect();
                let people = client
                    .query(
                        "SELECT full_name, COALESCE(email, ''), COALESCE(phone, '') FROM persons WHERE site_id = $1",
                        &[&site],
                    )
                    .await
                    .map_err(storage)?
                    .iter()
                    .map(|r| (r.get::<_, String>(0), PersonKeys::of(r.get(0), r.get(1), r.get(2), None)))
                    .collect();
                Ok(SiteFacts {
                    units,
                    login_emails,
                    people,
                    unit_numbers_any_block: Vec::new(),
                })
            }
            Storage::Memory => {
                let inner = self.state.inner.read().await;
                let unit_numbers_any_block = inner
                    .units
                    .iter()
                    .filter(|u| crate::auth::same_id(&u.site_id, site_id))
                    .map(|u| u.unit_number)
                    .collect();
                let login_emails = inner
                    .users
                    .iter()
                    .map(|u| NormalizedEmail::normalize(&u.email))
                    .collect();
                let people = inner
                    .users
                    .iter()
                    .filter(|u| crate::auth::same_id(&u.site_id, site_id))
                    .map(|u| {
                        (
                            u.full_name.clone(),
                            PersonKeys::of(&u.full_name, &u.email, &u.phone, None),
                        )
                    })
                    .collect();
                Ok(SiteFacts {
                    units: Vec::new(),
                    login_emails,
                    people,
                    unit_numbers_any_block,
                })
            }
        }
    }

    /// Checks (and, unless `dry_run`, registers) the rows of `csv`.
    ///
    /// # Errors
    /// A file that cannot be read as an import (see [`PersonImportError`]) or a
    /// storage failure while checking. Errors of single rows are in the report.
    pub async fn import(
        &self,
        ctx: &AuthzContext,
        site_id: &str,
        csv: &str,
        dry_run: bool,
    ) -> Result<ImportReport, PersonImportError> {
        if csv.len() > MAX_BYTES {
            return Err(PersonImportError::TooLarge);
        }
        let (header, records) = parse_csv(csv)?;
        let mut checked = check_rows(&header, &records)?;
        let emails: Vec<String> = checked
            .iter()
            .filter_map(|c| c.request.as_ref())
            .flat_map(|r| [Some(r.email.clone()), r.tenant_email.clone()])
            .flatten()
            .map(|e| NormalizedEmail::normalize(&e))
            .collect();
        let facts = self.site_facts(site_id, &emails).await?;
        for c in &mut checked {
            let Some(req) = &c.request else { continue };
            if facts.units.contains(&(block_code(&req.block), req.unit_no))
                || facts.unit_numbers_any_block.contains(&req.unit_no)
            {
                c.row.errors.push("Bu daire zaten kayıtlı.".into());
            }
            for address in [Some(&req.email), req.tenant_email.as_ref()]
                .into_iter()
                .flatten()
            {
                if facts
                    .login_emails
                    .contains(&NormalizedEmail::normalize(address))
                {
                    c.row
                        .errors
                        .push(format!("{address} başka bir hesapta kullanılıyor."));
                }
            }
            let probe = PersonKeys::of(&req.owner_full_name, "", &req.phone, None);
            if let Some((name, _)) = facts
                .people
                .iter()
                .find(|(_, k)| !match_reasons(k, &probe).is_empty())
            {
                c.row.warnings.push(format!(
                    "Sitede benzer bir kişi var: {name}. Aynı kişiyse tekrar eklemeyin."
                ));
            }
            if !c.row.errors.is_empty() {
                c.request = None;
            }
        }
        let invalid = checked.iter().filter(|c| !c.row.errors.is_empty()).count();
        let commit = !dry_run && invalid == 0;
        let mut created = 0;
        if commit {
            let service = SiteAdminService::new(self.state.clone());
            for c in &mut checked {
                let Some(req) = c.request.take() else {
                    continue;
                };
                match service.register_home_owner(site_id, req).await {
                    Ok(response) => {
                        created += 1;
                        c.row.unit_id = Some(response.unit_id);
                        c.row.activation = response.activation.map(|a| a.status);
                        c.row.warnings.extend(response.warnings);
                    }
                    Err(e) => c.row.errors.push(e),
                }
            }
            self.record_commit(ctx, site_id, checked.len(), created)
                .await?;
        }
        let rows: Vec<ImportRow> = checked.into_iter().map(|c| c.row).collect();
        let invalid = rows.iter().filter(|r| !r.errors.is_empty()).count();
        Ok(ImportReport {
            dry_run,
            committed: commit,
            total: rows.len(),
            invalid,
            created,
            rows,
        })
    }

    async fn record_commit(
        &self,
        ctx: &AuthzContext,
        site_id: &str,
        rows: usize,
        created: usize,
    ) -> Result<(), PersonImportError> {
        let Storage::Postgres(pool) = &self.store else {
            return Ok(());
        };
        let client = pool.get().await.map_err(storage)?;
        let site = crate::db::parse_id_to_i64(site_id);
        let (rows, created) = (
            i64::try_from(rows).unwrap_or(i64::MAX),
            i64::try_from(created).unwrap_or(i64::MAX),
        );
        client
            .execute(
                "INSERT INTO audit_events(request_id,actor_kind,actor_id,actor_role,site_id,action,resource_type,outcome,changes) \
                 VALUES ($1,'USER',$2,$3,$4,'PERSON_IMPORT_COMMITTED','persons','SUCCESS', \
                         jsonb_build_object('rows',$5::bigint,'created',$6::bigint))",
                &[&ctx.request_id, &ctx.claims.sub, &ctx.claims.role.as_str(), &site, &rows, &created],
            )
            .await
            .map_err(storage)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEADER: &str = "block;unit_no;floor;owner_full_name;owner_email;owner_phone;land_share;monthly_dues;is_resident;tenant_full_name;tenant_email;tenant_phone";

    #[test]
    fn semicolon_files_with_bom_quotes_and_crlf_are_read() {
        let text = format!("\u{feff}{HEADER}\r\nA;1;2;\"Yılmaz; Ayşe\";a@x.io;05321112233;10;\"1.250,50\";evet;;;\r\n\r\n");
        let (header, rows) = parse_csv(&text).expect("parses");
        assert_eq!(header.len(), 12);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].0, 2);
        assert_eq!(rows[0].1[3], "Yılmaz; Ayşe");
        assert_eq!(parse_amount(&rows[0].1[7]), Some(Decimal::new(125050, 2)));
    }

    #[test]
    fn unterminated_quotes_and_empty_files_are_refused() {
        assert_eq!(
            parse_csv("block,unit_no\n\"A,1\n"),
            Err(PersonImportError::UnterminatedQuote(2))
        );
        assert_eq!(parse_csv("block,unit_no\n"), Err(PersonImportError::Empty));
    }

    #[test]
    fn rows_report_field_errors_and_duplicates_inside_the_file() {
        let text = format!(
            "{HEADER}\nA;1;;Ali Veli;ali@x.io;05321112233;;;evet;;;\nA;1;;Can;ali@x.io;123;x;-5;belki;;;\nB;2;1;Ece Su;ece@x.io;05321112234;;1000;hayır;Kiracı Kişi;k@x.io;05321112235\n"
        );
        let (header, records) = parse_csv(&text).expect("parses");
        let rows = check_rows(&header, &records).expect("checks");
        assert!(rows[0].row.errors.is_empty());
        assert!(rows[0]
            .request
            .as_ref()
            .is_some_and(|r| r.is_resident && r.floor == 0));
        let second = &rows[1].row.errors;
        assert!(
            second.iter().any(|e| e.contains("2. satırda")),
            "{second:?}"
        );
        assert!(second.iter().any(|e| e.contains("telefonu")));
        assert!(second.iter().any(|e| e.contains("Arsa payı")));
        assert!(second.iter().any(|e| e.contains("aidat")));
        assert!(second.iter().any(|e| e.contains("Oturuyor")));
        assert!(rows[1].request.is_none());
        let third = rows[2].request.as_ref().expect("valid tenant row");
        assert_eq!(third.tenant_email.as_deref(), Some("k@x.io"));
        assert_eq!(third.monthly_dues, Some(Decimal::new(1000, 0)));
    }

    #[test]
    fn missing_required_columns_are_named() {
        let (header, records) = parse_csv("block,unit_no\nA,1\n").expect("parses");
        assert_eq!(
            check_rows(&header, &records).err(),
            Some(PersonImportError::MissingColumns(
                "owner_full_name, owner_email, owner_phone".into()
            ))
        );
    }
}
