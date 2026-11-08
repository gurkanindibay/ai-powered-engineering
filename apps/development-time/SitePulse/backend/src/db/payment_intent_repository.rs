//! Card payment intents (SPEC-007 R4): provider references and states only.

use deadpool_postgres::Pool;

use super::{require_id, DbResult};
use crate::models::{PaymentDesignation, PaymentIntent};

const INTENT_COLUMNS: &str = "id, site_id, unit_id, debtor_type, payer_name, amount, currency, provider, provider_ref, status, \
     checkout_url, three_ds_status, fee_amount, failure_reason, receipt_number, designation::text, created_by, created_at, \
     updated_at, captured_at";

fn designation_json(d: &Option<PaymentDesignation>) -> Option<String> {
    d.as_ref().and_then(|d| serde_json::to_string(d).ok())
}

pub async fn insert_payment_intent(pool: &Pool, i: &PaymentIntent) -> DbResult<i64> {
    let site = require_id("site", &i.site_id)?;
    let unit = require_id("unit", &i.unit_id)?;
    let client = pool.get().await?;
    let row = client
        .query_one(
            r#"
            INSERT INTO payment_intents (site_id, unit_id, debtor_type, payer_name, amount, currency, provider, provider_ref,
                                         status, checkout_url, designation, created_by, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::text::jsonb, $12, $13, $13)
            RETURNING id
            "#,
            &[
                &site,
                &unit,
                &i.debtor_type,
                &i.payer_name,
                &i.amount,
                &i.currency,
                &i.provider,
                &i.provider_ref,
                &i.status,
                &i.checkout_url,
                &designation_json(&i.designation),
                &i.created_by,
                &i.created_at,
            ],
        )
        .await?;
    Ok(row.get(0))
}

pub async fn update_payment_intent(pool: &Pool, i: &PaymentIntent) -> DbResult<()> {
    let id = require_id("payment intent", &i.id)?;
    let client = pool.get().await?;
    let n = client
        .execute(
            r#"
            UPDATE payment_intents SET status = $2, three_ds_status = $3, fee_amount = $4, failure_reason = $5,
                   receipt_number = $6, captured_at = $7, updated_at = $8
            WHERE id = $1
            "#,
            &[&id, &i.status, &i.three_ds_status, &i.fee_amount, &i.failure_reason, &i.receipt_number, &i.captured_at, &i.updated_at],
        )
        .await?;
    if n != 1 {
        return Err(format!("payment intent {} not found", i.id).into());
    }
    Ok(())
}

pub async fn load_payment_intents(pool: &Pool) -> DbResult<Vec<PaymentIntent>> {
    let client = pool.get().await?;
    let rows = client
        .query(
            &format!("SELECT {} FROM payment_intents ORDER BY id", INTENT_COLUMNS),
            &[],
        )
        .await?;
    Ok(rows
        .iter()
        .map(|r| PaymentIntent {
            id: r.get::<_, i64>(0).to_string(),
            site_id: r.get::<_, i64>(1).to_string(),
            unit_id: r.get::<_, i64>(2).to_string(),
            debtor_type: r.get(3),
            payer_name: r.get(4),
            amount: r.get(5),
            currency: r.get::<_, String>(6).trim().to_string(),
            provider: r.get(7),
            provider_ref: r.get(8),
            status: r.get(9),
            checkout_url: r.get(10),
            three_ds_status: r.get(11),
            fee_amount: r.get(12),
            failure_reason: r.get(13),
            receipt_number: r.get(14),
            designation: r
                .get::<_, Option<String>>(15)
                .and_then(|v| serde_json::from_str(&v).ok()),
            created_by: r.get(16),
            created_at: r.get(17),
            updated_at: r.get(18),
            captured_at: r.get(19),
        })
        .collect())
}
