use chrono::{DateTime, NaiveDate, Utc};
use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use tracing::info;

use super::base::{parse_id_to_i64, require_id, DbResult};
use super::dues_repository::*;
use super::payment_repository::*;
use super::site_repository::*;
use super::unit_repository::*;
use super::user_repository::*;
use crate::models::*;
use crate::services::VirtualIbanService;
use crate::state::AppStateInner;
/// Replaces the element with the same id, or appends it. One copy per id.
fn upsert_by_id<T>(items: &mut Vec<T>, item: T, id: impl Fn(&T) -> &String) {
    let key = id(&item).clone();
    if let Some(pos) = items.iter().position(|x| *id(x) == key) {
        items[pos] = item;
    } else {
        items.push(item);
    }
}

pub async fn load_all_from_db(pool: &Pool, state: &mut AppStateInner) -> DbResult<()> {
    let client = pool.get().await?;

    // 1. Load Sites
    {
        let rows = client.query("SELECT id, name, address, slug, status, plan_type, license_end_date, timezone, tax_id, tax_office FROM sites WHERE deleted_at IS NULL",
            &[],).await?;
        for row in rows {
            let id: i64 = row.get(0);
            let name: String = row.get(1);
            let address: String = row.get::<_, Option<String>>(2).unwrap_or_default();
            let slug: String = row
                .get::<_, Option<String>>(3)
                .unwrap_or_else(|| id.to_string());
            let status = row
                .get::<_, Option<SiteStatus>>(4)
                .unwrap_or(SiteStatus::Active);
            let plan_type = row
                .get::<_, Option<PlanType>>(5)
                .unwrap_or(PlanType::Standard);
            let license_end_date: Option<NaiveDate> = row.get(6);

            let s = Site {
                id: id.to_string(),
                name,
                address,
                slug,
                status,
                plan_type,
                license_end_date: license_end_date
                    .unwrap_or_else(|| Utc::now().date_naive() + chrono::Days::new(365)),
                timezone: row
                    .get::<_, Option<String>>(7)
                    .unwrap_or_else(crate::models::default_site_timezone),
                tax_id: row.get(8),
                tax_office: row.get(9),
            };

            upsert_by_id(&mut state.sites, s, |x| &x.id);
        }
        info!("Loaded {} sites from PostgreSQL", state.sites.len());
    }

    // 2. Load Users
    {
        let rows = client.query("SELECT u.id, u.site_id, COALESCE(p.full_name, ''), u.email, COALESCE(p.phone, ''), u.password_hash, u.role, u.must_change_password, u.auth_provider, u.google_sub, u.avatar_url, u.created_at, u.person_id
             FROM users u
             LEFT JOIN persons p ON u.person_id = p.id",
            &[],).await?;
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: Option<i64> = row.get(1);
            let full_name: String = row.get(2);
            let email: String = row.get(3);
            let phone: Option<String> = row.get(4);
            let password_hash: Option<String> = row.get(5);
            let role_str: String = row.get(6);
            let must_change_password: bool = row.get(7);
            let auth_provider: Option<String> = row.get(8);
            let google_sub: Option<String> = row.get(9);
            let avatar_url: Option<String> = row.get(10);
            let created_at: Option<DateTime<Utc>> = row.get(11);
            let person_id: Option<i64> = row.try_get(12).ok().flatten();

            let user = User {
                id: id.to_string(),
                site_id: site_id.map(|s| s.to_string()).unwrap_or_default(),
                full_name,
                email,
                phone: phone.unwrap_or_default(),
                password_hash,
                role: Role::parse(&role_str)?,
                must_change_password,
                auth_provider: auth_provider
                    .as_deref()
                    .map(AuthProvider::from_str_loose)
                    .unwrap_or(AuthProvider::Local),
                google_sub,
                avatar_url,
                created_at: created_at.unwrap_or_else(Utc::now),
                person_id,
            };

            // Drop any in-memory bootstrap copy of the same account.
            state
                .users
                .retain(|u| u.id == user.id || !u.email.eq_ignore_ascii_case(&user.email));
            upsert_by_id(&mut state.users, user, |x| &x.id);
        }
        info!("Loaded {} users from PostgreSQL", state.users.len());
    }

    // 2b. Load Persons into users state for resident resolution
    {
        let rows = client
            .query(
                "SELECT id, full_name, email, phone, person_type FROM persons",
                &[],
            )
            .await?;
        for row in rows {
            let p_id: i64 = row.get(0);
            let p_name: String = row.get(1);
            let p_email: Option<String> = row.get(2);
            let p_phone: Option<String> = row.get(3);
            let p_type: String = row.get(4);
            let role = Role::parse(&p_type)?;

            // Persons live in their own id namespace (`person-<id>`) so they can
            // never collide with, or overwrite, a real login account.
            let user = User {
                id: format!("person-{}", p_id),
                site_id: String::new(),
                full_name: p_name,
                email: p_email.unwrap_or_else(|| format!("kisi-{}@sitepulse.local", p_id)),
                phone: p_phone.unwrap_or_default(),
                password_hash: None,
                role,
                must_change_password: false,
                auth_provider: AuthProvider::Local,
                google_sub: None,
                avatar_url: None,
                created_at: Utc::now(),
                person_id: Some(p_id),
            };

            upsert_by_id(&mut state.users, user, |x| &x.id);
        }
        info!(
            "Loaded {} persons into users from PostgreSQL",
            state.users.len()
        );
    }

    // 3. Load Units
    {
        let rows = client.query("SELECT id, block_id, unit_number, floor, land_share, owner_person_id, tenant_person_id, site_id, virtual_iban, house_type FROM units WHERE deleted_at IS NULL",
            &[],).await?;
        for row in rows {
            let id: i64 = row.get(0);
            let block_id: i64 = row.get(1);
            let unit_number: i32 = row.get(2);
            let floor: i32 = row.get(3);
            let land_share: i32 = row.get(4);
            let owner_person_id: Option<i64> = row.get(5);
            let tenant_person_id: Option<i64> = row.get(6);
            let site_id: Option<i64> = row.get(7);
            let virtual_iban: Option<String> = row.get(8);
            let house_type: Option<String> = row.get(9);

            let block_label = if block_id == 1 { "blok-A" } else { "blok-B" };
            let resolved_viban = virtual_iban.or_else(|| {
                VirtualIbanService::generate_virtual_iban(
                    VirtualIbanService::KUVEYT_TURK_BANK_CODE,
                    &site_id.map(|s| s.to_string()).unwrap_or_default(),
                    block_label,
                    unit_number,
                )
                .ok()
            });

            let unit = IndependentUnit {
                id: id.to_string(),
                site_id: site_id.map(|s| s.to_string()).unwrap_or_default(),
                block_id: block_id.to_string(),
                unit_number,
                floor,
                land_share,
                owner_user_id: owner_person_id.map(|p| format!("person-{}", p)),
                tenant_user_id: tenant_person_id.map(|p| format!("person-{}", p)),
                virtual_iban: resolved_viban,
                house_type,
            };

            // Register unit payer names (tenant first as primary payer, then owner)
            for (p_id, primary) in [(tenant_person_id, true), (owner_person_id, false)] {
                let Some(p_id) = p_id else { continue };
                let key = format!("person-{}", p_id);
                if let Some(p) = state.users.iter().find(|u| u.id == key) {
                    let name = p.full_name.clone();
                    let entry = state.unit_payer_names.entry(unit.id.clone()).or_default();
                    if !entry.contains(&name) {
                        if primary {
                            entry.insert(0, name)
                        } else {
                            entry.push(name)
                        }
                    }
                }
            }

            upsert_by_id(&mut state.units, unit, |x| &x.id);
        }
        info!("Loaded {} units from PostgreSQL", state.units.len());
    }

    // 3b. Load House Types (Tariffs)
    {
        let rows = client
            .query(
                "SELECT id, site_id, type_name, dues_amount, description FROM house_types",
                &[],
            )
            .await?;
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: i64 = row.get(1);
            let type_name: String = row.get(2);
            let dues_amount: Decimal = row.get(3);
            let description: Option<String> = row.get(4);

            let ht = crate::models::HouseTypeTariff {
                id: id.to_string(),
                site_id: site_id.to_string(),
                type_name,
                dues_amount,
                description,
            };

            let legacy_site_id = format!("site-{}", site_id);
            if let Some(pos) = state.house_types.iter().position(|h| {
                h.id == ht.id || (h.site_id == ht.site_id && h.type_name == ht.type_name)
            }) {
                state.house_types[pos] = ht.clone();
            } else {
                state.house_types.push(ht.clone());
            }
            if !state
                .house_types
                .iter()
                .any(|h| h.site_id == legacy_site_id && h.type_name == ht.type_name)
            {
                let mut legacy_ht = ht;
                legacy_ht.site_id = legacy_site_id;
                state.house_types.push(legacy_ht);
            }
        }
        info!(
            "Loaded {} house type tariffs from PostgreSQL",
            state.house_types.len()
        );
    }

    // 3c. Load Blocks
    {
        let rows = client
            .query(
                "SELECT id, site_id, block_name, total_floors FROM blocks",
                &[],
            )
            .await?;
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: i64 = row.get(1);
            let block_name: String = row.get(2);
            let total_floors: i32 = row.get(3);

            let block = crate::models::BlockDto {
                id: id.to_string(),
                site_id: site_id.to_string(),
                block_name: block_name.clone(),
                total_floors,
            };

            let legacy_site_id = format!("site-{}", site_id);
            if let Some(pos) = state.blocks.iter().position(|b| {
                b.id == block.id || (b.site_id == block.site_id && b.block_name == block.block_name)
            }) {
                state.blocks[pos] = block.clone();
            } else {
                state.blocks.push(block.clone());
            }
            if !state
                .blocks
                .iter()
                .any(|b| b.site_id == legacy_site_id && b.block_name == block.block_name)
            {
                let mut legacy_b = block;
                legacy_b.site_id = legacy_site_id;
                state.blocks.push(legacy_b);
            }
        }
        info!("Loaded {} blocks from PostgreSQL", state.blocks.len());
    }

    // 4. Load Dues Liabilities
    {
        let rows = client.query("SELECT id, unit_id, period, principal_amount, due_date, status, delay_penalty, paid_principal, paid_penalty, debtor_type, expense_type, penalty_accrued_through FROM dues_liabilities d WHERE d.status <> 'CANCELLED' AND EXISTS (SELECT 1 FROM units u WHERE u.id = d.unit_id AND u.deleted_at IS NULL)",
            &[],).await?;
        for row in rows {
            let id: i64 = row.get(0);
            let unit_id: i64 = row.get(1);
            let period: String = row.get(2);
            let principal_amount: Decimal = row.get(3);
            let due_date: NaiveDate = row.get(4);
            let status_str: String = row.get(5);
            let delay_penalty: Decimal = row.get(6);
            let paid_principal: Decimal = row.get(7);
            let paid_penalty: Decimal = row.get(8);
            let debtor_type: DebtorType = row.get(9);
            let expense_type: ExpenseType = row.get(10);
            let penalty_accrued_through: Option<NaiveDate> = row.get(11);

            let status = match status_str.to_uppercase().as_str() {
                "PAID" => DebtStatus::Paid,
                "OVERDUE" => DebtStatus::Overdue,
                _ => DebtStatus::Pending,
            };

            let mut due = DuesLiability {
                id: id.to_string(),
                unit_id: unit_id.to_string(),
                period,
                principal_amount,
                due_date,
                status,
                delay_penalty,
                total_amount: Decimal::ZERO,
                paid_principal,
                paid_penalty,
                debtor_type,
                expense_type,
                penalty_accrued_through,
            };
            crate::services::dues_ledger::refresh(&mut due);
            upsert_by_id(&mut state.dues, due, |x| &x.id);
        }
        info!(
            "Loaded {} dues liabilities from PostgreSQL",
            state.dues.len()
        );
    }

    // 4b. Load Dues Periods
    {
        let rows = client.query("SELECT id, site_id, period_name, due_date, status, created_at FROM dues_periods ORDER BY due_date ASC",
            &[],).await?;
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: i64 = row.get(1);
            let period_name: String = row.get(2);
            let due_date: NaiveDate = row.get(3);
            let status: DuesPeriodStatus = row.get(4);
            let created_at: Option<DateTime<Utc>> = row.get(5);

            let site_id_str = site_id.to_string();
            let period_item = crate::models::DuesPeriod {
                id: id.to_string(),
                site_id: site_id_str.clone(),
                period_name: period_name.clone(),
                due_date,
                status,
                created_at,
            };

            let legacy_site_id = format!("site-{}", site_id);
            if let Some(pos) = state.dues_periods.iter().position(|p| {
                (p.site_id == site_id_str || p.site_id == legacy_site_id)
                    && p.period_name == period_name
            }) {
                state.dues_periods[pos] = period_item.clone();
            } else {
                state.dues_periods.push(period_item.clone());
            }

            if !state
                .dues_periods
                .iter()
                .any(|p| p.site_id == legacy_site_id && p.period_name == period_name)
            {
                let mut leg_p = period_item;
                leg_p.site_id = legacy_site_id;
                state.dues_periods.push(leg_p);
            }
        }
        info!(
            "Loaded {} dues periods from PostgreSQL",
            state.dues_periods.len()
        );
    }

    // 5. Load Site Bank Accounts
    {
        let rows = client.query("SELECT id, site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by, created_at, updated_at FROM site_bank_accounts",
            &[],).await?;
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: i64 = row.get(1);
            let bank_code: String = row.get(2);
            let bank_name: String = row.get(3);
            let iban: String = row.get(4);
            let account_holder: String = row.get(5);
            let statement_format: BankStatementFormat = row.get(6);
            let is_active: bool = row.get(7);
            let configured_by: Option<i64> = row.get(8);
            let created_at: Option<DateTime<Utc>> = row.get(9);
            let updated_at: Option<DateTime<Utc>> = row.get(10);

            let sba = SiteBankAccount {
                id: id.to_string(),
                site_id: site_id.to_string(),
                bank_code,
                bank_name,
                iban,
                account_holder,
                statement_format,
                is_active,
                configured_by: configured_by.map(|c| c.to_string()),
                created_at: created_at.unwrap_or_else(Utc::now),
                updated_at: updated_at.unwrap_or_else(Utc::now),
            };

            let legacy_id = format!("sba-{}", id);
            if let Some(pos) = state
                .site_bank_accounts
                .iter()
                .position(|b| b.id == sba.id || b.id == legacy_id)
            {
                state.site_bank_accounts[pos] = sba.clone();
            } else {
                state.site_bank_accounts.push(sba.clone());
            }
            if !state.site_bank_accounts.iter().any(|b| b.id == legacy_id) {
                let mut leg_sba = sba;
                leg_sba.id = legacy_id;
                state.site_bank_accounts.push(leg_sba);
            }
        }
        info!(
            "Loaded {} site bank accounts from PostgreSQL",
            state.site_bank_accounts.len()
        );
    }

    // 6. Load the unified payment ledger (payment_entries) and derive the legacy
    // homeowner-payment view from it so existing endpoints keep working.
    {
        let rows = client.query("SELECT id, site_id, unit_id, payer_name, payer_role, receipt_id, amount, payment_channel, settlement_status, description, external_reference, payment_date, created_at, entry_type, reverses_entry_id, reversal_reason, recorded_by FROM payment_entries ORDER BY payment_date ASC, id ASC",
            &[],).await?;
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: i64 = row.get(1);
            let unit_id: i64 = row.get(2);
            let payer_name: String = row.get(3);
            let payer_role: DebtorType = row.get(4);
            let receipt_id: Option<i64> = row.get(5);
            let amount: Decimal = row.get(6);
            let payment_channel: PaymentChannel = row.get(7);
            let settlement_status: SettlementStatus = row.get(8);
            let description: Option<String> = row.get(9);
            let external_reference: Option<String> = row.get(10);
            let payment_date: Option<DateTime<Utc>> = row.get(11);
            let created_at: Option<DateTime<Utc>> = row.get(12);

            let entry = PaymentEntry {
                id,
                site_id: site_id.to_string(),
                unit_id: unit_id.to_string(),
                unit_label: None,
                payer_name: payer_name.clone(),
                payer_role,
                receipt_id,
                receipt_number: None,
                amount,
                payment_channel,
                settlement_status,
                description: description.clone(),
                external_reference: external_reference.clone(),
                payment_date: payment_date.unwrap_or_else(Utc::now),
                created_at: created_at.unwrap_or_else(Utc::now),
                entry_type: row.get(13),
                reverses_entry_id: row.get(14),
                reversal_reason: row.get(15),
                recorded_by: row.get(16),
            };
            let is_contra = entry.entry_type == crate::models::LEDGER_KIND_REVERSAL;

            if let Some(pos) = state.payment_entries.iter().position(|e| e.id == id) {
                state.payment_entries[pos] = entry;
            } else {
                state.payment_entries.push(entry);
            }

            // Derive the legacy homeowner-payment record for the match/reconcile endpoints
            // (reversal contra entries have no counterpart there).
            if is_contra {
                continue;
            }
            let matched_unit = state
                .units
                .iter()
                .find(|u| parse_id_to_i64(&u.id) == Some(unit_id));
            let record = HomeownerPaymentRecord {
                id: id.to_string(),
                unit_id: unit_id.to_string(),
                block_id: matched_unit.map(|u| u.block_id.clone()).unwrap_or_default(),
                unit_number: matched_unit.map(|u| u.unit_number).unwrap_or(0),
                homeowner_name: Some(payer_name),
                amount,
                payment_method: payment_channel,
                reference_code: external_reference,
                note: description,
                status: if settlement_status == SettlementStatus::Settled {
                    PaymentMatchStatus::MatchedDebt
                } else if settlement_status == SettlementStatus::Unmatched {
                    PaymentMatchStatus::Pending
                } else {
                    PaymentMatchStatus::MatchedDebt
                },
                cleared_debt_amount: if settlement_status == SettlementStatus::Settled {
                    amount
                } else {
                    Decimal::ZERO
                },
                advance_credit_amount: Decimal::ZERO,
                created_at: created_at.unwrap_or_else(Utc::now),
            };
            if let Some(pos) = state
                .homeowner_payments
                .iter()
                .position(|h| h.id == record.id)
            {
                state.homeowner_payments[pos] = record;
            } else {
                state.homeowner_payments.push(record);
            }
        }
        info!(
            "Loaded {} payment entries from PostgreSQL",
            state.payment_entries.len()
        );
    }

    // 6b. Load Payment Receipts
    {
        let rows = client
            .query(&format!("SELECT {} FROM payment_receipts ORDER BY receipt_type ASC, sequence_number ASC", super::RECEIPT_COLUMNS), &[])
            .await?;
        for row in rows {
            let receipt = super::receipt_from_row(&row);
            let id = receipt.id;
            if let Some(pos) = state.payment_receipts.iter().position(|r| r.id == id) {
                state.payment_receipts[pos] = receipt;
            } else {
                state.payment_receipts.push(receipt);
            }
        }
        info!(
            "Loaded {} payment receipts from PostgreSQL",
            state.payment_receipts.len()
        );
    }

    // 7. Load Pending Registrations
    {
        let rows = client.query("SELECT request_id, site_id, block, unit_no, floor, full_name, email, phone, is_resident, status, submitted_at FROM pending_registrations",
            &[],).await?;
        for row in rows {
            let req = PendingRegistrationResponse {
                request_id: row.get(0),
                site_id: row.get::<_, i64>(1).to_string(),
                block: row.get(2),
                unit_no: row.get(3),
                floor: row.get(4),
                full_name: row.get(5),
                email: row.get(6),
                phone: row.get(7),
                is_resident: row.get(8),
                status: row.get(9),
                submitted_at: row
                    .get::<_, Option<DateTime<Utc>>>(10)
                    .unwrap_or_else(Utc::now),
            };
            if let Some(pos) = state
                .pending_registrations
                .iter()
                .position(|r| r.request_id == req.request_id)
            {
                state.pending_registrations[pos] = req;
            } else {
                state.pending_registrations.push(req);
            }
        }
        info!(
            "Loaded {} pending registrations from PostgreSQL",
            state.pending_registrations.len()
        );
    }

    // 8. Load Household Members (occupancy_members — the canonical table)
    {
        let rows = client
            .query(
                r#"
            SELECT uo.unit_id, om.id, om.full_name, om.relationship, om.phone, om.email,
                   om.occupancy_id, om.person_id, om.resident_user_id,
                   (uo.occupancy_type = 'OWNER') AS is_owner
            FROM occupancy_members om
            JOIN unit_occupancies uo ON om.occupancy_id = uo.id
            WHERE uo.is_active = true
            ORDER BY om.id ASC
            "#,
                &[],
            )
            .await?;
        for row in rows {
            let unit_id: i64 = row.get(0);
            let key = unit_id.to_string();
            let member = UnitMemberDto {
                resident_id: row.get::<_, i64>(1).to_string(),
                full_name: row.get(2),
                relationship: row.get(3),
                phone: row.get::<_, Option<String>>(4).unwrap_or_default(),
                email: row.get::<_, Option<String>>(5).unwrap_or_default(),
                is_owner: row.get(9),
                occupancy_id: row.try_get(6).ok().flatten(),
                person_id: row.try_get(7).ok().flatten(),
                resident_user_id: row.try_get(8).ok().flatten(),
            };
            let list = state.unit_members.entry(key).or_default();
            if !list.iter().any(|m| m.resident_id == member.resident_id) {
                list.push(member);
            }
        }
        info!(
            "Loaded household members for {} units from PostgreSQL",
            state.unit_members.len()
        );
    }

    // 8b. Load Occupancy History
    {
        let rows = client
            .query(
                r#"
            SELECT uo.id, uo.unit_id, uo.person_id, p.full_name, p.phone, p.email,
                   uo.occupancy_type, uo.start_date, uo.end_date, uo.is_active,
                   COALESCE(uo.exit_balance, 0.00), uo.notes, uo.created_at
            FROM unit_occupancies uo
            JOIN persons p ON uo.person_id = p.id
            ORDER BY uo.start_date ASC
            "#,
                &[],
            )
            .await?;
        for row in rows {
            let id: i64 = row.get(0);
            let unit_id: i64 = row.get(1);
            let person_id: i64 = row.get(2);
            let person_name: String = row.get(3);
            let person_phone: Option<String> = row.get(4);
            let person_email: Option<String> = row.get(5);
            let role: DebtorType = row.get(6);
            let start_date: NaiveDate = row.get(7);
            let end_date: Option<NaiveDate> = row.get(8);
            let is_active: bool = row.get(9);
            let exit_balance: Decimal = row.get(10);
            let notes: Option<String> = row.get(11);
            let created_at: Option<DateTime<Utc>> = row.get(12);

            let item = OccupancyHistoryItem {
                id,
                unit_id,
                person_id,
                person_name,
                person_phone,
                person_email,
                role,
                start_date: start_date.to_string(),
                end_date: end_date.map(|d| d.to_string()),
                is_active,
                exit_balance,
                notes,
                created_at: created_at.unwrap_or_else(Utc::now),
            };

            let key = unit_id.to_string();
            let history = state.unit_occupancies.entry(key).or_default();
            if !history.iter().any(|h| h.id == item.id) {
                history.push(item);
            }
        }
        info!(
            "Loaded occupancy history for {} units from PostgreSQL",
            state.unit_occupancies.len()
        );
    }

    // 9. Load Invitation Tokens
    {
        let rows = client.query("SELECT token, site_id, unit_id, building, unit_number, relationship, invite_url, security_notice, expires_at FROM invitation_tokens",
            &[],).await?;
        for row in rows {
            let token: String = row.get(0);
            let unit_id: Option<i64> = row.get(2);
            let building: Option<String> = row.get(3);
            let unit_number: Option<String> = row.get(4);
            let relationship: Option<String> = row.get(5);
            let invite_url: String = row.get(6);
            let security_notice: Option<String> = row.get(7);
            let expires_at: DateTime<Utc> = row.get(8);

            let invite = UnitInviteLinkResponse {
                invite_url,
                token: token.clone(),
                unit_id: unit_id.map(|v| v.to_string()).unwrap_or_default(),
                building: building.unwrap_or_default(),
                unit_number: unit_number.unwrap_or_default(),
                relationship: relationship.unwrap_or_default(),
                expires_at,
                security_notice: security_notice.unwrap_or_default(),
            };
            state.unit_invite_tokens.insert(token, invite);
        }
    }

    // 10. Load Advance Balances
    {
        let rows = client
            .query(
                "SELECT unit_id, debtor_type, balance FROM advance_balances",
                &[],
            )
            .await?;
        state.advance_balances.clear();
        for row in rows {
            let unit_id: i64 = row.get(0);
            let debtor_type: String = row.get(1);
            let balance: Decimal = row.get(2);
            state.adjust_advance(&unit_id.to_string(), &debtor_type, balance);
        }
        info!(
            "Loaded advance balances of {} units from PostgreSQL",
            state.advance_balances.len()
        );
    }

    // 10b. Load idempotency keys (O-4: the only home of idempotency).
    {
        let rows = client
            .query(
                "SELECT site_id, idempotency_key, receipt_id FROM payment_idempotency_keys",
                &[],
            )
            .await?;
        for row in rows {
            let site: i64 = row.get(0);
            state
                .payment_idempotency
                .insert((site.to_string(), row.get(1)), row.get(2));
        }
    }

    // 11. Load Unit Sender IBANs
    {
        let rows = client
            .query(
                "SELECT sender_iban, unit_id, label, bank_name FROM unit_sender_ibans",
                &[],
            )
            .await?;
        for row in rows {
            let sender_iban: String = row.get(0);
            let unit_id: i64 = row.get(1);
            let label: Option<String> = row.get(2);
            let bank_name: Option<String> = row.get(3);

            state
                .remembered_sender_ibans
                .insert(sender_iban.clone(), unit_id.to_string());
            state
                .sender_iban_metadata
                .insert(sender_iban, (label, bank_name));
        }
        info!(
            "Loaded {} remembered sender IBANs from PostgreSQL",
            state.remembered_sender_ibans.len()
        );
    }

    // 12. Load Unit Payer Names
    {
        let rows = client
            .query("SELECT unit_id, payer_name FROM unit_payer_names", &[])
            .await?;
        for row in rows {
            let unit_id: i64 = row.get(0);
            let payer_name: String = row.get(1);
            let list = state
                .unit_payer_names
                .entry(unit_id.to_string())
                .or_default();
            if !list.contains(&payer_name) {
                list.push(payer_name);
            }
        }
    }

    // 13. Load Reconciliation Queue
    {
        let rows = client.query("SELECT match_id, transaction_id, txn_date, amount, currency, description, sender_name, sender_iban, reference_no, matched_unit_id, matched_block, matched_unit_number, matched_resident_name, confidence_score, matched_due_id, outstanding_balance, amount_matches_balance, status, notes, site_id FROM reconciliation_queue ORDER BY txn_date ASC",
            &[],).await?;
        for row in rows {
            let match_id: String = row.get(0);
            let transaction_id: String = row.get(1);
            let txn_date: NaiveDate = row.get(2);
            let amount: Decimal = row.get(3);
            let currency: String = row.get(4);
            let description: String = row.get(5);
            let sender_name: Option<String> = row.get(6);
            let sender_iban: Option<String> = row.get(7);
            let reference_no: Option<String> = row.get(8);
            let matched_unit_id: Option<i64> = row.get(9);
            let matched_block: Option<String> = row.get(10);
            let matched_unit_number: Option<i32> = row.get(11);
            let matched_resident_name: Option<String> = row.get(12);
            let confidence_score: i32 = row.get(13);
            let matched_due_id: Option<i64> = row.get(14);
            let outstanding_balance: Option<Decimal> = row.get(15);
            let amount_matches_balance: bool = row.get(16);
            let status_str: String = row.get(17);
            let notes: Option<String> = row.get(18);
            let site_id_num: Option<i64> = row.get(19);
            let site_id = site_id_num
                .map(|s| s.to_string())
                .unwrap_or_else(|| "1".to_string());

            let status = ReconciliationStatus::from_db_code(&status_str);
            let status_code = status.as_str().to_string();

            let m = ReconciliationMatch {
                match_id: match_id.clone(),
                site_id,
                transaction: BankTransactionItem {
                    transaction_id,
                    date: txn_date,
                    amount,
                    currency,
                    description,
                    sender_name,
                    sender_iban,
                    reference_no,
                },
                matched_unit_id: matched_unit_id.map(|v| v.to_string()),
                matched_block,
                matched_unit_number,
                matched_resident_name,
                confidence_score: confidence_score as u8,
                matched_due_id: matched_due_id.map(|v| v.to_string()),
                outstanding_balance,
                amount_matches_balance,
                status,
                status_code,
                notes,
            };

            if let Some(pos) = state
                .reconciliation_queue
                .iter()
                .position(|q| q.match_id == m.match_id)
            {
                state.reconciliation_queue[pos] = m;
            } else {
                state.reconciliation_queue.push(m);
            }
        }
        info!(
            "Loaded {} reconciliation queue items from PostgreSQL",
            state.reconciliation_queue.len()
        );
    }

    // SPEC-007: operating budgets, revaluation rates, liabilities' legal basis, card payment intents.
    {
        let labels: std::collections::HashMap<i64, String> = state
            .units
            .iter()
            .filter_map(|u| {
                u.id.parse::<i64>()
                    .ok()
                    .map(|id| (id, state.unit_label(&u.block_id, u.unit_number)))
            })
            .collect();
        let snapshot = super::load_budget_snapshot(pool, |id| {
            labels.get(&id).cloned().unwrap_or_else(|| id.to_string())
        })
        .await?;
        state.operating_budgets = snapshot.budgets;
        for rate in snapshot.rates {
            state.revaluation_rates.insert(rate.year, rate);
        }
        state.budget_required_sites = snapshot.required_sites;
        state.dues_budget_basis = snapshot.due_basis.into_iter().collect();
        state.payment_intents = super::load_payment_intents(pool).await?;
        info!(
            "Loaded {} operating budgets and {} payment intents from PostgreSQL",
            state.operating_budgets.len(),
            state.payment_intents.len()
        );
    }
    Ok(())
}

pub async fn sync_all_in_memory_to_db(
    pool: &Pool,
    state: &AppStateInner,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;

    // 1. Sync Sites
    for site in &state.sites {
        save_site(pool, site).await.map_err(|e| e.to_string())?;
    }

    // 2. Sync Blocks
    for block in &state.blocks {
        let site_id_num = require_id("entity", &block.site_id)?;
        if let Some(block_id_num) = parse_id_to_i64(&block.id) {
            client
                .execute(
                    r#"
                    INSERT INTO blocks (id, site_id, block_name, total_floors)
                    VALUES ($1, $2, $3, $4)
                    ON CONFLICT (id) DO UPDATE SET
                        site_id = EXCLUDED.site_id,
                        block_name = EXCLUDED.block_name,
                        total_floors = EXCLUDED.total_floors
                    "#,
                    &[
                        &block_id_num,
                        &site_id_num,
                        &block.block_name,
                        &block.total_floors,
                    ],
                )
                .await
                .map_err(|e| e.to_string())?;
        } else {
            client
                .execute(
                    r#"
                    INSERT INTO blocks (site_id, block_name, total_floors)
                    VALUES ($1, $2, $3)
                    ON CONFLICT DO NOTHING
                    "#,
                    &[&site_id_num, &block.block_name, &block.total_floors],
                )
                .await
                .map_err(|e| e.to_string())?;
        }
    }

    // 3. Sync Users and Persons
    for user in &state.users {
        save_user(pool, user).await.map_err(|e| e.to_string())?;
    }

    // 4. Sync Units
    for unit in &state.units {
        save_unit(pool, unit).await.map_err(|e| e.to_string())?;
    }

    // 5. Sync Dues Liabilities
    for due in &state.dues {
        save_due_liability(pool, due)
            .await
            .map_err(|e| e.to_string())?;
    }

    // 6. Sync Remembered Sender IBANs & Payer Names
    for (iban, unit_id) in &state.remembered_sender_ibans {
        let meta = state.sender_iban_metadata.get(iban);
        let label = meta.and_then(|m| m.0.as_deref());
        let bank = meta.and_then(|m| m.1.as_deref());
        save_remembered_sender_iban(pool, iban, unit_id, label, bank)
            .await
            .map_err(|e| e.to_string())?;
    }
    for (unit_id, names) in &state.unit_payer_names {
        save_unit_payer_names(pool, unit_id, names)
            .await
            .map_err(|e| e.to_string())?;
    }

    // 7. Sync Advance Balances
    for (unit_id, adv) in &state.advance_balances {
        save_advance_balance(pool, unit_id, "OWNER", adv.owner)
            .await
            .map_err(|e| e.to_string())?;
        save_advance_balance(pool, unit_id, "TENANT", adv.tenant)
            .await
            .map_err(|e| e.to_string())?;
    }

    // 8. Sync Payment Receipts
    for r in &state.payment_receipts {
        save_payment_receipt(pool, r)
            .await
            .map_err(|e| e.to_string())?;
    }

    info!("Synchronized all in-memory state to PostgreSQL database successfully.");
    Ok(())
}

// ---------------------------------------------------------------------------
// Transaction-scoped payment persistence (C7, H1–H4, H6, H9).
// Every helper runs on the caller's transaction; nothing is committed until the
// caller commits, and any error rolls the whole payment back.
// ---------------------------------------------------------------------------
