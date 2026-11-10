//! The site's people, as people rather than units (person module F1, U3, U4, F8).
//!
//! A directory with search, role and activation filters and paging; one person's
//! profile with every unit they own, rent or live in, over time; and a CSV export
//! of the directory. Every query is limited to the caller's site.

use chrono::NaiveDate;
use deadpool_postgres::Pool;
use serde::{Deserialize, Serialize};

use crate::db::Storage;
use crate::state::AppState;

/// Largest page the directory returns.
pub const MAX_PAGE_SIZE: i64 = 100;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PersonDirectoryError {
    #[error("Person not found")]
    NotFound,
    #[error("Invalid directory filter: {0}")]
    InvalidFilter(String),
    #[error("Person directory storage error: {0}")]
    Storage(String),
}

fn storage(e: impl std::fmt::Display) -> PersonDirectoryError {
    PersonDirectoryError::Storage(e.to_string())
}

/// Login state of a person, as a manager may see it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum LoginState {
    /// No login account (a household member, for example).
    None,
    /// An account waiting for the person to use their activation link.
    Pending,
    /// The person has set a password or linked Google.
    Active,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct DirectoryQuery {
    /// Matches name, email or phone (case-insensitive substring).
    #[serde(default)]
    pub q: Option<String>,
    /// `HOME_OWNER` or `HOME_RESIDENT`.
    #[serde(default)]
    pub role: Option<String>,
    /// `NONE`, `PENDING` or `ACTIVE`.
    #[serde(default)]
    pub login: Option<String>,
    #[serde(default)]
    pub page: Option<i64>,
    #[serde(default)]
    pub page_size: Option<i64>,
    #[serde(default)]
    pub site_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonSummary {
    pub person_id: i64,
    pub full_name: String,
    pub email: String,
    pub phone: String,
    /// Derived from what the person holds now (V23).
    pub role: String,
    pub owned_units: i64,
    pub occupied_units: i64,
    pub login: LoginState,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DirectoryPage {
    pub items: Vec<PersonSummary>,
    pub total: i64,
    pub page: i64,
    pub page_size: i64,
}

/// One period of a person's relation to a unit.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonUnit {
    pub unit_id: String,
    pub block: String,
    pub unit_no: i32,
    /// `OWNER`, `OCCUPANT_OWNER`, `TENANT` or `MEMBER`.
    pub relation: String,
    pub start_date: Option<NaiveDate>,
    pub end_date: Option<NaiveDate>,
    pub active: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonProfile {
    pub person: PersonSummary,
    /// Newest first; active relations before ended ones.
    pub units: Vec<PersonUnit>,
}

struct Filters {
    q: String,
    role: String,
    login: String,
    page: i64,
    page_size: i64,
}

fn filters(query: &DirectoryQuery) -> Result<Filters, PersonDirectoryError> {
    let role = query.role.clone().unwrap_or_default().to_uppercase();
    if !matches!(role.as_str(), "" | "HOME_OWNER" | "HOME_RESIDENT") {
        return Err(PersonDirectoryError::InvalidFilter("role".into()));
    }
    let login = query.login.clone().unwrap_or_default().to_uppercase();
    if !matches!(login.as_str(), "" | "NONE" | "PENDING" | "ACTIVE") {
        return Err(PersonDirectoryError::InvalidFilter("login".into()));
    }
    Ok(Filters {
        q: query.q.clone().unwrap_or_default().trim().to_lowercase(),
        role,
        login,
        page: query.page.unwrap_or(1).max(1),
        page_size: query.page_size.unwrap_or(25).clamp(1, MAX_PAGE_SIZE),
    })
}

const SUMMARY_SELECT: &str = "SELECT p.id, p.full_name, COALESCE(p.email, ''), COALESCE(p.phone, ''), \
     COALESCE(r.derived_role, ''), r.owned_units, r.occupied_units + r.member_units, \
     CASE WHEN usr.id IS NULL THEN 'NONE' \
          WHEN usr.password_hash IS NULL AND usr.google_sub IS NULL THEN 'PENDING' ELSE 'ACTIVE' END \
     FROM persons p JOIN v_person_roles r ON r.person_id = p.id \
     LEFT JOIN users usr ON usr.person_id = p.id AND usr.is_active";

fn summary(row: &tokio_postgres::Row) -> PersonSummary {
    let login: String = row.get(7);
    PersonSummary {
        person_id: row.get(0),
        full_name: row.get(1),
        email: row.get(2),
        phone: row.get(3),
        role: row.get(4),
        owned_units: row.get(5),
        occupied_units: row.get(6),
        login: match login.as_str() {
            "PENDING" => LoginState::Pending,
            "ACTIVE" => LoginState::Active,
            _ => LoginState::None,
        },
    }
}

pub struct PersonDirectoryService {
    state: AppState,
    store: Storage,
}

impl PersonDirectoryService {
    pub fn new(state: AppState) -> Self {
        let store = Storage::of(&state);
        Self { state, store }
    }

    /// A page of the site's people.
    ///
    /// # Errors
    /// An unknown filter value or a storage failure.
    pub async fn directory(
        &self,
        site_id: &str,
        query: &DirectoryQuery,
    ) -> Result<DirectoryPage, PersonDirectoryError> {
        let f = filters(query)?;
        let site = crate::db::parse_id_to_i64(site_id)
            .ok_or_else(|| PersonDirectoryError::InvalidFilter("site".into()))?;
        match &self.store {
            Storage::Postgres(pool) => Self::directory_in_db(pool, site, &f).await,
            Storage::Memory => Ok(self.directory_in_memory(site_id, &f).await),
        }
    }

    async fn directory_in_db(
        pool: &Pool,
        site: i64,
        f: &Filters,
    ) -> Result<DirectoryPage, PersonDirectoryError> {
        let client = pool.get().await.map_err(storage)?;
        let filter = "WHERE p.site_id = $1 \
             AND ($2 = '' OR strpos(lower(p.full_name), $2) > 0 OR strpos(lower(COALESCE(p.email, '')), $2) > 0 \
                  OR strpos(regexp_replace(COALESCE(p.phone, ''), '\\D', '', 'g'), regexp_replace($2, '\\D', '', 'g')) > 0 AND regexp_replace($2, '\\D', '', 'g') <> '') \
             AND ($3 = '' OR r.derived_role = $3) \
             AND ($4 = '' OR (CASE WHEN usr.id IS NULL THEN 'NONE' \
                  WHEN usr.password_hash IS NULL AND usr.google_sub IS NULL THEN 'PENDING' ELSE 'ACTIVE' END) = $4)";
        let total: i64 = client
            .query_one(
                &format!(
                    "SELECT count(*) FROM persons p JOIN v_person_roles r ON r.person_id = p.id \
                     LEFT JOIN users usr ON usr.person_id = p.id AND usr.is_active {filter}"
                ),
                &[&site, &f.q, &f.role, &f.login],
            )
            .await
            .map_err(storage)?
            .get(0);
        let offset = (f.page - 1) * f.page_size;
        let rows = client
            .query(
                &format!(
                    "{SUMMARY_SELECT} {filter} ORDER BY lower(p.full_name), p.id LIMIT $5 OFFSET $6"
                ),
                &[&site, &f.q, &f.role, &f.login, &f.page_size, &offset],
            )
            .await
            .map_err(storage)?;
        Ok(DirectoryPage {
            items: rows.iter().map(summary).collect(),
            total,
            page: f.page,
            page_size: f.page_size,
        })
    }

    async fn directory_in_memory(&self, site_id: &str, f: &Filters) -> DirectoryPage {
        let inner = self.state.inner.read().await;
        let mut items: Vec<PersonSummary> = inner
            .users
            .iter()
            .filter(|u| crate::auth::same_id(&u.site_id, site_id))
            .filter(|u| {
                matches!(
                    u.role,
                    crate::models::Role::HomeOwner | crate::models::Role::HomeResident
                )
            })
            .map(|u| PersonSummary {
                person_id: u.person_id.unwrap_or_default(),
                full_name: u.full_name.clone(),
                email: u.email.clone(),
                phone: u.phone.clone(),
                role: u.role.as_str().to_string(),
                owned_units: inner
                    .units
                    .iter()
                    .filter(|x| x.owner_user_id.as_deref() == Some(&u.id))
                    .count() as i64,
                occupied_units: inner
                    .units
                    .iter()
                    .filter(|x| x.tenant_user_id.as_deref() == Some(&u.id))
                    .count() as i64,
                login: if u.password_hash.is_some() || u.google_sub.is_some() {
                    LoginState::Active
                } else {
                    LoginState::Pending
                },
            })
            .filter(|p| {
                f.q.is_empty()
                    || p.full_name.to_lowercase().contains(&f.q)
                    || crate::domain::email::NormalizedEmail::normalize(&p.email).contains(&f.q)
            })
            .filter(|p| f.role.is_empty() || p.role == f.role)
            .filter(|p| {
                f.login.is_empty()
                    || serde_json::to_value(p.login)
                        .ok()
                        .and_then(|v| v.as_str().map(str::to_string))
                        == Some(f.login.clone())
            })
            .collect();
        items.sort_by_key(|p| p.full_name.to_lowercase());
        let total = items.len() as i64;
        let start = usize::try_from((f.page - 1) * f.page_size).unwrap_or(usize::MAX);
        let items = items
            .into_iter()
            .skip(start)
            .take(usize::try_from(f.page_size).unwrap_or(0))
            .collect();
        DirectoryPage {
            items,
            total,
            page: f.page,
            page_size: f.page_size,
        }
    }

    /// One person of the site, with every unit relation over time.
    ///
    /// # Errors
    /// [`PersonDirectoryError::NotFound`] for a person of another site or none.
    pub async fn profile(
        &self,
        site_id: &str,
        person_id: i64,
    ) -> Result<PersonProfile, PersonDirectoryError> {
        let site = crate::db::parse_id_to_i64(site_id).ok_or(PersonDirectoryError::NotFound)?;
        let Storage::Postgres(pool) = &self.store else {
            return Err(PersonDirectoryError::NotFound);
        };
        let client = pool.get().await.map_err(storage)?;
        let person = client
            .query_opt(
                &format!("{SUMMARY_SELECT} WHERE p.id = $1 AND p.site_id = $2"),
                &[&person_id, &site],
            )
            .await
            .map_err(storage)?
            .map(|row| summary(&row))
            .ok_or(PersonDirectoryError::NotFound)?;
        let rows = client
            .query(
                "SELECT u.id::text, b.block_name, u.unit_number, rel, start_date, end_date, active FROM ( \
                    SELECT o.unit_id, 'OWNER' AS rel, o.start_date, o.end_date, o.is_active AS active \
                      FROM unit_ownerships o WHERE o.person_id = $1 \
                    UNION ALL \
                    SELECT u.id, 'OWNER', NULL::date, NULL::date, true FROM units u \
                      WHERE u.owner_person_id = $1 AND u.deleted_at IS NULL \
                        AND NOT EXISTS (SELECT 1 FROM unit_ownerships o WHERE o.unit_id = u.id AND o.person_id = $1) \
                    UNION ALL \
                    SELECT o.unit_id, CASE WHEN o.occupancy_type = 'TENANT' THEN 'TENANT' ELSE 'OCCUPANT_OWNER' END, \
                           o.start_date, o.end_date, o.is_active AND o.end_date IS NULL \
                      FROM unit_occupancies o WHERE o.person_id = $1 \
                    UNION ALL \
                    SELECT o.unit_id, 'MEMBER', o.start_date, o.end_date, o.is_active AND o.end_date IS NULL \
                      FROM occupancy_members m JOIN unit_occupancies o ON o.id = m.occupancy_id WHERE m.person_id = $1 \
                 ) rel_rows JOIN units u ON u.id = rel_rows.unit_id AND u.site_id = $2 \
                 JOIN blocks b ON b.id = u.block_id \
                 ORDER BY active DESC, start_date DESC NULLS LAST, u.unit_number",
                &[&person_id, &site],
            )
            .await
            .map_err(storage)?;
        let units = rows
            .iter()
            .map(|r| PersonUnit {
                unit_id: r.get(0),
                block: r.get(1),
                unit_no: r.get(2),
                relation: r.get(3),
                start_date: r.get(4),
                end_date: r.get(5),
                active: r.get(6),
            })
            .collect();
        Ok(PersonProfile { person, units })
    }

    /// Record an export in the audit log (who, which site, how many rows).
    ///
    /// # Errors
    /// A storage failure; the export is then not handed out.
    pub async fn record_export(
        &self,
        ctx: &crate::authorization::AuthzContext,
        site_id: &str,
        rows: usize,
    ) -> Result<(), PersonDirectoryError> {
        let Storage::Postgres(pool) = &self.store else {
            return Ok(());
        };
        let client = pool.get().await.map_err(storage)?;
        let site = crate::db::parse_id_to_i64(site_id);
        let rows = i64::try_from(rows).unwrap_or(i64::MAX);
        client
            .execute(
                "INSERT INTO audit_events(request_id,actor_kind,actor_id,actor_role,site_id,action,resource_type,outcome,changes) \
                 VALUES ($1,'USER',$2,$3,$4,'PERSON_DIRECTORY_EXPORTED','persons','SUCCESS',jsonb_build_object('rows',$5::bigint))",
                &[&ctx.request_id, &ctx.claims.sub, &ctx.claims.role.as_str(), &site, &rows],
            )
            .await
            .map_err(storage)?;
        Ok(())
    }

    /// The whole filtered directory as CSV (UTF-8 with BOM, so spreadsheet tools read
    /// Turkish characters). Cells that a spreadsheet would run as a formula are escaped.
    ///
    /// # Errors
    /// An unknown filter value or a storage failure.
    pub async fn export_csv(
        &self,
        site_id: &str,
        query: &DirectoryQuery,
    ) -> Result<(String, usize), PersonDirectoryError> {
        let mut all = DirectoryQuery {
            page: Some(1),
            page_size: Some(MAX_PAGE_SIZE),
            ..query.clone()
        };
        let mut rows: Vec<PersonSummary> = Vec::new();
        loop {
            let page = self.directory(site_id, &all).await?;
            let done = page.items.len() < usize::try_from(page.page_size).unwrap_or(0);
            rows.extend(page.items);
            if done || rows.len() as i64 >= page.total {
                break;
            }
            all.page = Some(page.page + 1);
        }
        let mut out = String::from(
            "\u{feff}person_id,full_name,email,phone,role,owned_units,occupied_units,login\n",
        );
        for p in &rows {
            let login = match p.login {
                LoginState::None => "NONE",
                LoginState::Pending => "PENDING",
                LoginState::Active => "ACTIVE",
            };
            out.push_str(&format!(
                "{},{},{},{},{},{},{},{}\n",
                p.person_id,
                csv_cell(&p.full_name),
                csv_cell(&p.email),
                csv_cell(&p.phone),
                p.role,
                p.owned_units,
                p.occupied_units,
                login
            ));
        }
        Ok((out, rows.len()))
    }
}

/// Quote a CSV cell and neutralize spreadsheet formula injection (`=`, `+`, `-`, `@`).
pub fn csv_cell(value: &str) -> String {
    let guarded = if value.starts_with(['=', '+', '-', '@', '\t', '\r']) {
        format!("'{value}")
    } else {
        value.to_string()
    };
    format!("\"{}\"", guarded.replace('"', "\"\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn csv_cells_are_quoted_and_formulas_neutralized() {
        assert_eq!(csv_cell("Ali \"Kaya\""), "\"Ali \"\"Kaya\"\"\"");
        assert_eq!(csv_cell("=HYPERLINK(1)"), "\"'=HYPERLINK(1)\"");
        assert_eq!(csv_cell("+90 532"), "\"'+90 532\"");
    }

    #[test]
    fn filters_are_validated_and_paging_is_bounded() {
        let bad = DirectoryQuery {
            role: Some("ADMIN".into()),
            ..Default::default()
        };
        assert!(filters(&bad).is_err());
        let big = DirectoryQuery {
            page: Some(0),
            page_size: Some(10_000),
            ..Default::default()
        };
        let f = filters(&big).expect("valid");
        assert_eq!((f.page, f.page_size), (1, MAX_PAGE_SIZE));
    }
}
