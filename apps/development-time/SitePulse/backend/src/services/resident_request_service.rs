//! Resident self-service requests, SPEC-009 R5: a virman request (move the
//! caller's own advance to the other ledger of the unit) and a dispute on a
//! liability (pauses dunning until staff decide).

use chrono::Utc;
use rust_decimal::Decimal;

use crate::db::finance_store::FinanceStore;
use crate::finance_book::col;
use crate::models::*;
use crate::services::dues_ledger::{DEBTOR_OWNER, DEBTOR_TENANT};
use crate::services::finance_common::*;
use crate::state::AppState;

pub struct ResidentRequestService {
    state: AppState,
    store: FinanceStore,
}

impl ResidentRequestService {
    pub fn new(state: &AppState) -> Self {
        Self {
            state: state.clone(),
            store: FinanceStore::new(state),
        }
    }

    pub async fn create_virman_request(
        &self,
        caller: &Caller,
        unit_id: &str,
        req: CreateVirmanRequest,
    ) -> FinanceResult<VirmanRequest> {
        money(req.amount, "amount")?;
        let (unit, available) = self
            .store
            .read(|inner| {
                let unit = find_unit(inner, &caller.site_id, unit_id)?;
                let own = resident_debtor(caller, &unit);
                let source = match (own, parse_debtor(req.source_debtor.as_deref())?) {
                    (Some(own), asked) if req.source_debtor.is_some() && asked != own => {
                        return Err(FinanceError::Forbidden(format!(
                            "You can only move your own ({}) advance",
                            own
                        )))
                    }
                    (Some(own), _) => own,
                    (None, asked) => asked,
                };
                let available = inner.advance_of(&unit.id, source);
                Ok((unit, (source, available)))
            })
            .await?;
        let (source, balance) = available;
        if balance < req.amount {
            return Err(conflict(format!(
                "The {} advance is ₺{:.2}; ₺{:.2} cannot be moved",
                source, balance, req.amount
            )));
        }
        let target = if source == DEBTOR_OWNER {
            DEBTOR_TENANT
        } else {
            DEBTOR_OWNER
        };
        let request = VirmanRequest {
            id: 0,
            site_id: caller.site_id.clone(),
            unit_id: unit.id.clone(),
            source_debtor: source.to_string(),
            target_debtor: target.to_string(),
            amount: req.amount,
            note: opt_text(&req.note),
            requested_by: caller.actor(),
            status: REQUEST_PENDING.to_string(),
            decided_by: None,
            decided_at: None,
            decision_note: None,
            receipt_number: None,
            created_at: Utc::now(),
        };
        Ok(self.store.insert(request, col::virman_requests).await?)
    }

    pub async fn virman_requests(&self, caller: &Caller, unit_id: Option<&str>) -> Vec<VirmanRequest> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .virman_requests
                    .iter()
                    .filter(|r| crate::auth::same_id(&r.site_id, &caller.site_id))
                    .filter(|r| unit_id.is_none_or(|u| crate::auth::same_id(&r.unit_id, u)))
                    .cloned()
                    .collect()
            })
            .await
    }

    /// Staff decision; an approval runs the inter-ledger transfer and stores its receipt.
    pub async fn decide_virman(
        &self,
        caller: &Caller,
        request_id: i64,
        decision: DecideRequest,
    ) -> FinanceResult<VirmanRequest> {
        let mut request = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .virman_requests
                    .iter()
                    .find(|r| r.id == request_id && crate::auth::same_id(&r.site_id, &caller.site_id))
                    .cloned()
            })
            .await
            .ok_or_else(|| not_found(format!("Virman request {} not found", request_id)))?;
        if request.status != REQUEST_PENDING {
            return Err(conflict(format!(
                "Virman request {} is already {}",
                request.id, request.status
            )));
        }
        if decision.approve {
            let response = crate::services::PaymentTrackingService::new(self.state.clone())
                .inter_ledger_transfer(InterLedgerTransferRequest {
                    site_id: Some(caller.site_id.clone()),
                    unit_id: request.unit_id.clone(),
                    amount: request.amount,
                    note: Some(format!(
                        "Sakin talebi #{}{}",
                        request.id,
                        request
                            .note
                            .as_deref()
                            .map(|n| format!(": {}", n))
                            .unwrap_or_default()
                    )),
                    operator_user_id: Some(caller.user_id.clone()),
                    source_debtor: Some(request.source_debtor.clone()),
                    target_debtor: Some(request.target_debtor.clone()),
                })
                .await
                .map_err(FinanceError::Conflict)?;
            if response.transferred_amount <= Decimal::ZERO {
                return Err(conflict(
                    "The target ledger has no open debt to settle; nothing was transferred",
                ));
            }
            request.status = REQUEST_APPROVED.to_string();
            request.receipt_number = Some(response.receipt_number);
        } else {
            request.status = REQUEST_REJECTED.to_string();
        }
        request.decided_by = Some(caller.actor());
        request.decided_at = Some(Utc::now());
        request.decision_note = opt_text(&decision.note);
        Ok(self.store.update(request, col::virman_requests).await?)
    }

    pub async fn create_dispute(
        &self,
        caller: &Caller,
        unit_id: &str,
        req: CreateDisputeRequest,
    ) -> FinanceResult<LedgerDispute> {
        let reason = non_empty(&req.reason, 5, "reason")?;
        let (unit, due) = self
            .store
            .read(|inner| {
                let unit = find_unit(inner, &caller.site_id, unit_id)?;
                let due = find_due(inner, &caller.site_id, &req.due_id)?.clone();
                if !crate::auth::same_id(&due.unit_id, &unit.id) {
                    return Err(not_found(format!("Liability {} is not on this unit", req.due_id)));
                }
                if let Some(own) = resident_debtor(caller, &unit) {
                    if due.debtor_type.as_str() != own {
                        return Err(FinanceError::Forbidden(
                            "You can only dispute your own liabilities".into(),
                        ));
                    }
                }
                if inner
                    .finance
                    .disputes
                    .iter()
                    .any(|d| d.due_id == due.id && d.status == DISPUTE_OPEN)
                {
                    return Err(conflict("This liability already has an open dispute"));
                }
                Ok((unit, due))
            })
            .await?;
        let dispute = LedgerDispute {
            id: 0,
            site_id: caller.site_id.clone(),
            unit_id: unit.id.clone(),
            due_id: due.id.clone(),
            debtor_type: due.debtor_type.as_str().to_string(),
            reason,
            raised_by: caller.actor(),
            status: DISPUTE_OPEN.to_string(),
            resolution_note: None,
            resolved_by: None,
            resolved_at: None,
            created_at: Utc::now(),
        };
        Ok(self.store.insert(dispute, col::disputes).await?)
    }

    pub async fn disputes(&self, caller: &Caller, unit_id: Option<&str>) -> Vec<LedgerDispute> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .disputes
                    .iter()
                    .filter(|d| crate::auth::same_id(&d.site_id, &caller.site_id))
                    .filter(|d| unit_id.is_none_or(|u| crate::auth::same_id(&d.unit_id, u)))
                    .cloned()
                    .collect()
            })
            .await
    }

    pub async fn resolve_dispute(
        &self,
        caller: &Caller,
        dispute_id: i64,
        req: ResolveDisputeRequest,
    ) -> FinanceResult<LedgerDispute> {
        let note = non_empty(&req.note, 3, "note")?;
        let mut dispute = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .disputes
                    .iter()
                    .find(|d| d.id == dispute_id && crate::auth::same_id(&d.site_id, &caller.site_id))
                    .cloned()
            })
            .await
            .ok_or_else(|| not_found(format!("Dispute {} not found", dispute_id)))?;
        if dispute.status != DISPUTE_OPEN {
            return Err(conflict(format!("Dispute {} is already {}", dispute.id, dispute.status)));
        }
        dispute.status = if req.accept {
            DISPUTE_ACCEPTED
        } else {
            DISPUTE_REJECTED
        }
        .to_string();
        dispute.resolution_note = Some(note);
        dispute.resolved_by = Some(caller.actor());
        dispute.resolved_at = Some(Utc::now());
        Ok(self.store.update(dispute, col::disputes).await?)
    }
}
