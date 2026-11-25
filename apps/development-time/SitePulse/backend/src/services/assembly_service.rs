//! Kat malikleri kurulu meetings and the decisions book (karar defteri),
//! SPEC-009 R12 (KMK 30, verify).
//!
//! A meeting has an agenda, attendance (owner or proxy) and votes per unit.
//! Closing an agenda item tallies the votes with its rule
//! (`domain::assembly_vote`) and writes a numbered decision. A decision linked to
//! a budget approves it (R1): the decision number and date become the budget's
//! legal basis.

use chrono::Utc;

use crate::db::finance_store::FinanceStore;
use crate::domain::assembly_vote::{has_quorum, passes, Electorate, Tally, Vote, VoteRule};
use crate::finance_book::col;
use crate::models::*;
use crate::services::finance_common::*;
use crate::state::{AppState, AppStateInner};

fn electorate(inner: &AppStateInner, site_id: &str) -> Electorate {
    let units: Vec<&IndependentUnit> = site_units(inner, site_id).collect();
    Electorate {
        units: u64::try_from(units.len()).unwrap_or(0),
        land_share: units
            .iter()
            .map(|u| u64::try_from(u.land_share.max(1)).unwrap_or(1))
            .sum(),
    }
}

fn land_share_of(inner: &AppStateInner, unit_id: &str) -> u64 {
    inner
        .units
        .iter()
        .find(|u| crate::auth::same_id(&u.id, unit_id))
        .map(|u| u64::try_from(u.land_share.max(1)).unwrap_or(1))
        .unwrap_or(1)
}

fn meeting_view(inner: &AppStateInner, m: &AssemblyMeeting) -> MeetingView {
    let e = electorate(inner, &m.site_id);
    let attendance: Vec<AssemblyAttendance> = inner
        .finance
        .attendance
        .iter()
        .filter(|a| a.meeting_id == m.id)
        .cloned()
        .collect();
    let present_units = u64::try_from(attendance.len()).unwrap_or(0);
    let present_share: u64 = attendance
        .iter()
        .map(|a| land_share_of(inner, &a.unit_id))
        .sum();
    let mut agenda: Vec<AssemblyAgendaItem> = inner
        .finance
        .agenda_items
        .iter()
        .filter(|a| a.meeting_id == m.id)
        .cloned()
        .collect();
    agenda.sort_by_key(|a| a.seq);
    MeetingView {
        quorum: QuorumStatus {
            units_total: e.units,
            land_share_total: e.land_share,
            units_present: present_units,
            land_share_present: present_share,
            has_quorum: has_quorum(
                e,
                present_units,
                present_share,
                u8::try_from(m.call_number).unwrap_or(1),
            ),
        },
        meeting: m.clone(),
        agenda,
        attendance,
    }
}

pub struct AssemblyService {
    state: AppState,
    store: FinanceStore,
}

impl AssemblyService {
    pub fn new(state: &AppState) -> Self {
        Self {
            state: state.clone(),
            store: FinanceStore::new(state),
        }
    }

    pub async fn create_meeting(
        &self,
        caller: &Caller,
        req: CreateMeetingRequest,
    ) -> FinanceResult<MeetingView> {
        let location = non_empty(&req.location, 3, "location")?;
        if req.agenda.is_empty() {
            return Err(invalid("A meeting needs at least one agenda item"));
        }
        let kind = req
            .kind
            .as_deref()
            .unwrap_or("ORDINARY")
            .trim()
            .to_ascii_uppercase();
        if !matches!(kind.as_str(), "ORDINARY" | "EXTRAORDINARY") {
            return Err(invalid("kind must be ORDINARY or EXTRAORDINARY"));
        }
        let call = req.call_number.unwrap_or(1);
        if !(1..=2).contains(&call) {
            return Err(invalid("call_number is 1 or 2"));
        }
        let mut items = Vec::new();
        for (i, a) in req.agenda.iter().enumerate() {
            let rule = VoteRule::parse(a.rule.as_deref().unwrap_or("SIMPLE"))
                .map_err(|e| invalid(e.to_string()))?;
            if let Some(ref b) = a.linked_budget_id {
                let ok = self
                    .store
                    .read(|inner| {
                        inner.operating_budgets.iter().any(|x| {
                            x.id == *b && crate::auth::same_id(&x.site_id, &caller.site_id)
                        })
                    })
                    .await;
                if !ok {
                    return Err(not_found(format!("Operating budget {} not found", b)));
                }
            }
            items.push(AssemblyAgendaItem {
                id: 0,
                meeting_id: 0,
                seq: i32::try_from(i + 1).unwrap_or(i32::MAX),
                title: non_empty(&a.title, 3, "agenda title")?,
                description: opt_text(&a.description),
                rule: rule.as_str().to_string(),
                linked_budget_id: a.linked_budget_id.clone(),
                status: "OPEN".into(),
                decision_id: None,
            });
        }
        let meeting = AssemblyMeeting {
            id: 0,
            site_id: caller.site_id.clone(),
            kind,
            call_number: call,
            scheduled_at: req.scheduled_at,
            location,
            status: "PLANNED".into(),
            held_on: None,
            created_by: caller.actor(),
            created_at: Utc::now(),
        };
        let (meeting, _) = self
            .store
            .insert_with_children(meeting, col::meetings, items, col::agenda_items, |c, id| {
                c.meeting_id = id
            })
            .await?;
        Ok(self.store.read(|inner| meeting_view(inner, &meeting)).await)
    }

    pub async fn meetings(&self, site_id: &str) -> Vec<MeetingView> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .meetings
                    .iter()
                    .filter(|m| crate::auth::same_id(&m.site_id, site_id))
                    .map(|m| meeting_view(inner, m))
                    .collect()
            })
            .await
    }

    async fn find_meeting(&self, site_id: &str, id: i64) -> FinanceResult<AssemblyMeeting> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .meetings
                    .iter()
                    .find(|m| m.id == id && crate::auth::same_id(&m.site_id, site_id))
                    .cloned()
            })
            .await
            .ok_or_else(|| not_found(format!("Meeting {} not found", id)))
    }

    pub async fn meeting(&self, site_id: &str, id: i64) -> FinanceResult<MeetingView> {
        let m = self.find_meeting(site_id, id).await?;
        Ok(self.store.read(|inner| meeting_view(inner, &m)).await)
    }

    /// Records who attended; the meeting is HELD with a quorum, else NO_QUORUM.
    pub async fn record_attendance(
        &self,
        caller: &Caller,
        id: i64,
        req: RecordAttendanceRequest,
    ) -> FinanceResult<MeetingView> {
        let mut meeting = self.find_meeting(&caller.site_id, id).await?;
        if meeting.status == "CANCELLED" {
            return Err(conflict("The meeting was cancelled"));
        }
        for a in req.attendance {
            let (unit, existing) = self
                .store
                .read(|inner| {
                    let unit = find_unit(inner, &caller.site_id, &a.unit_id)?;
                    let existing = inner
                        .finance
                        .attendance
                        .iter()
                        .find(|x| x.meeting_id == id && crate::auth::same_id(&x.unit_id, &unit.id))
                        .map(|x| x.id);
                    Ok::<_, FinanceError>((unit, existing))
                })
                .await?;
            let row = AssemblyAttendance {
                id: existing.unwrap_or(0),
                meeting_id: id,
                unit_id: unit.id.clone(),
                attendee_name: non_empty(&a.attendee_name, 2, "attendee_name")?,
                is_proxy: a.is_proxy,
            };
            self.store.upsert(row, col::attendance).await?;
        }
        let quorum = self
            .store
            .read(|inner| meeting_view(inner, &meeting).quorum)
            .await;
        meeting.status = if quorum.has_quorum {
            "HELD"
        } else {
            "NO_QUORUM"
        }
        .to_string();
        meeting.held_on = Some(req.held_on.unwrap_or_else(|| {
            crate::domain::clock::local_date(
                &crate::models::default_site_timezone(),
                meeting.scheduled_at,
            )
        }));
        let meeting = self.store.update(meeting, col::meetings).await?;
        Ok(self.store.read(|inner| meeting_view(inner, &meeting)).await)
    }

    pub async fn cast_votes(
        &self,
        caller: &Caller,
        item_id: i64,
        req: CastVotesRequest,
    ) -> FinanceResult<Vec<AssemblyVote>> {
        let item = self.open_item(&caller.site_id, item_id).await?;
        let meeting = self.find_meeting(&caller.site_id, item.meeting_id).await?;
        if meeting.status != "HELD" {
            return Err(conflict(
                "Votes are cast in a meeting that was held with a quorum",
            ));
        }
        let mut out = Vec::new();
        for v in req.votes {
            let vote = Vote::parse(&v.vote).map_err(|e| invalid(e.to_string()))?;
            let (unit_id, existing, present) = self
                .store
                .read(|inner| {
                    let unit = find_unit(inner, &caller.site_id, &v.unit_id)?;
                    let present = inner.finance.attendance.iter().any(|a| {
                        a.meeting_id == meeting.id && crate::auth::same_id(&a.unit_id, &unit.id)
                    });
                    let existing = inner
                        .finance
                        .votes
                        .iter()
                        .find(|x| {
                            x.agenda_item_id == item_id
                                && crate::auth::same_id(&x.unit_id, &unit.id)
                        })
                        .map(|x| x.id);
                    Ok::<_, FinanceError>((unit.id, existing, present))
                })
                .await?;
            if !present {
                return Err(conflict(format!(
                    "Unit {} did not attend; it cannot vote",
                    v.unit_id
                )));
            }
            let row = AssemblyVote {
                id: existing.unwrap_or(0),
                agenda_item_id: item_id,
                unit_id,
                vote: vote.as_str().to_string(),
            };
            out.push(self.store.upsert(row, col::votes).await?);
        }
        Ok(out)
    }

    async fn open_item(&self, site_id: &str, item_id: i64) -> FinanceResult<AssemblyAgendaItem> {
        let item = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .agenda_items
                    .iter()
                    .find(|a| a.id == item_id)
                    .cloned()
                    .filter(|a| {
                        inner.finance.meetings.iter().any(|m| {
                            m.id == a.meeting_id && crate::auth::same_id(&m.site_id, site_id)
                        })
                    })
            })
            .await
            .ok_or_else(|| not_found(format!("Agenda item {} not found", item_id)))?;
        if item.status != "OPEN" {
            return Err(conflict("The agenda item is already closed"));
        }
        Ok(item)
    }

    fn next_decision_number(inner: &AppStateInner, site_id: &str) -> i32 {
        inner
            .finance
            .decisions
            .iter()
            .filter(|d| crate::auth::same_id(&d.site_id, site_id))
            .map(|d| d.decision_number)
            .max()
            .unwrap_or(0)
            + 1
    }

    /// Tallies the votes, writes the decision and applies it to a linked budget.
    pub async fn close_item(
        &self,
        caller: &Caller,
        item_id: i64,
        req: CloseAgendaItemRequest,
    ) -> FinanceResult<AssemblyDecision> {
        let text = non_empty(&req.decision_text, 5, "decision_text")?;
        let mut item = self.open_item(&caller.site_id, item_id).await?;
        let meeting = self.find_meeting(&caller.site_id, item.meeting_id).await?;
        if meeting.status != "HELD" {
            return Err(conflict(
                "Only a meeting held with a quorum takes decisions",
            ));
        }
        let rule = VoteRule::parse(&item.rule).map_err(|e| invalid(e.to_string()))?;
        let (tally, e, number) = self
            .store
            .read(|inner| {
                let mut tally = Tally::default();
                for v in inner
                    .finance
                    .votes
                    .iter()
                    .filter(|v| v.agenda_item_id == item_id)
                {
                    if let Ok(vote) = Vote::parse(&v.vote) {
                        tally.add(vote, land_share_of(inner, &v.unit_id));
                    }
                }
                (
                    tally,
                    electorate(inner, &caller.site_id),
                    Self::next_decision_number(inner, &caller.site_id),
                )
            })
            .await;
        let accepted = passes(rule, tally, e);
        let decision = AssemblyDecision {
            id: 0,
            site_id: caller.site_id.clone(),
            meeting_id: Some(meeting.id),
            decision_number: number,
            decided_on: meeting.held_on.unwrap_or_else(|| {
                crate::domain::clock::local_date(
                    &crate::models::default_site_timezone(),
                    meeting.scheduled_at,
                )
            }),
            title: item.title.clone(),
            text,
            outcome: if accepted { "ACCEPTED" } else { "REJECTED" }.to_string(),
            rule: rule.as_str().to_string(),
            yes_count: i32::try_from(tally.yes).unwrap_or(i32::MAX),
            no_count: i32::try_from(tally.no).unwrap_or(i32::MAX),
            abstain_count: i32::try_from(tally.abstain).unwrap_or(i32::MAX),
            yes_land_share: i64::try_from(tally.yes_share).unwrap_or(i64::MAX),
            total_land_share: i64::try_from(e.land_share).unwrap_or(i64::MAX),
            linked_budget_id: item.linked_budget_id.clone(),
            attachment_ref: opt_text(&req.attachment_ref),
            recorded_by: caller.actor(),
            created_at: Utc::now(),
        };
        let decision = self.store.insert(decision, col::decisions).await?;
        item.status = "CLOSED".into();
        item.decision_id = Some(decision.id);
        self.store.update(item, col::agenda_items).await?;
        if accepted {
            self.apply_to_budget(caller, &decision).await?;
        }
        Ok(decision)
    }

    /// A decision taken outside the app (copied from the paper karar defteri).
    pub async fn record_decision(
        &self,
        caller: &Caller,
        req: RecordDecisionRequest,
    ) -> FinanceResult<AssemblyDecision> {
        let outcome = req
            .outcome
            .as_deref()
            .unwrap_or("ACCEPTED")
            .trim()
            .to_ascii_uppercase();
        if !matches!(outcome.as_str(), "ACCEPTED" | "REJECTED") {
            return Err(invalid("outcome must be ACCEPTED or REJECTED"));
        }
        let today = self
            .store
            .read(|inner| site_today(inner, &caller.site_id))
            .await;
        if req.decided_on > today {
            return Err(invalid("decided_on is in the future"));
        }
        let number = self
            .store
            .read(|inner| Self::next_decision_number(inner, &caller.site_id))
            .await;
        let decision = AssemblyDecision {
            id: 0,
            site_id: caller.site_id.clone(),
            meeting_id: None,
            decision_number: number,
            decided_on: req.decided_on,
            title: non_empty(&req.title, 3, "title")?,
            text: non_empty(&req.text, 5, "text")?,
            outcome: outcome.clone(),
            rule: "RECORDED".into(),
            yes_count: 0,
            no_count: 0,
            abstain_count: 0,
            yes_land_share: 0,
            total_land_share: 0,
            linked_budget_id: req.linked_budget_id.clone(),
            attachment_ref: opt_text(&req.attachment_ref),
            recorded_by: caller.actor(),
            created_at: Utc::now(),
        };
        let decision = self.store.insert(decision, col::decisions).await?;
        if outcome == "ACCEPTED" {
            self.apply_to_budget(caller, &decision).await?;
        }
        Ok(decision)
    }

    async fn apply_to_budget(
        &self,
        caller: &Caller,
        decision: &AssemblyDecision,
    ) -> FinanceResult<()> {
        let Some(ref budget_id) = decision.linked_budget_id else {
            return Ok(());
        };
        let reference = format!("Karar No {} ({})", decision.decision_number, decision.title);
        crate::services::OperatingBudgetService::new(self.state.clone())
            .approve(
                &caller.site_id,
                budget_id,
                ApproveBudgetRequest {
                    assembly_decision_ref: reference,
                    assembly_decision_date: decision.decided_on,
                },
            )
            .await
            .map_err(|e| conflict(e.to_string()))?;
        self.store
            .set_budget_decision(budget_id, decision.id)
            .await?;
        Ok(())
    }

    pub async fn decisions(&self, site_id: &str) -> Vec<AssemblyDecision> {
        self.store
            .read(|inner| {
                let mut rows: Vec<AssemblyDecision> = inner
                    .finance
                    .decisions
                    .iter()
                    .filter(|d| crate::auth::same_id(&d.site_id, site_id))
                    .cloned()
                    .collect();
                rows.sort_by_key(|d| d.decision_number);
                rows
            })
            .await
    }
}
