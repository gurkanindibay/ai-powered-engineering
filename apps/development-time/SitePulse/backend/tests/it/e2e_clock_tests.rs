use chrono::NaiveDate;
use rust_decimal::Decimal;
use sitepulse_backend::models::{DebtStatus, DebtorType, DuesLiability, ExpenseType};
use sitepulse_backend::scheduler::run_e2e_tick;
use sitepulse_backend::state::AppState;

fn date(month: u32, day: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, month, day).unwrap_or(NaiveDate::MIN)
}

#[tokio::test]
async fn scheduler_runs_once_only_when_the_e2e_clock_is_ticked() {
    let state = AppState::with_e2e_test_clock(date(10, 1));
    {
        let mut inner = state.inner.write().await;
        let site_id = inner
            .sites
            .first()
            .map(|site| site.id.clone())
            .unwrap_or_default();
        assert!(!site_id.is_empty());
        if let Some(unit) = inner.units.first_mut() {
            unit.house_type = None;
        }
        inner.units.retain(|unit| unit.site_id == site_id);
        inner.dues.clear();
        inner.auto_scheduler_enabled = true;
        let unit_id = inner
            .units
            .first()
            .map(|unit| unit.id.clone())
            .unwrap_or_default();
        assert!(!unit_id.is_empty());
        inner.dues.push(DuesLiability {
            id: "e2e-clock-liability".to_string(),
            unit_id,
            period: "Ekim 2026".to_string(),
            principal_amount: Decimal::from(1400),
            delay_penalty: Decimal::ZERO,
            total_amount: Decimal::from(1400),
            due_date: date(10, 10),
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Owner,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: Some(date(10, 10)),
            liable_person_id: None,
        });
    }

    let Some(clock) = state.e2e_clock.as_ref() else {
        assert!(state.e2e_clock.is_some());
        return;
    };
    assert!(run_e2e_tick(&state).await.is_ok());
    assert!(state
        .inner
        .read()
        .await
        .finance
        .late_fee_accruals
        .is_empty());

    assert_eq!(clock.advance_to(date(11, 9)), Ok(()));
    let before_tick = state.inner.read().await;
    assert!(before_tick.finance.late_fee_accruals.is_empty());
    assert_eq!(
        before_tick.dues.first().map(|due| due.delay_penalty),
        Some(Decimal::ZERO)
    );
    drop(before_tick);

    let report = match run_e2e_tick(&state).await {
        Ok(report) => report,
        Err(error) => {
            assert_eq!(error, sitepulse_backend::e2e_clock::E2eClockError::Disabled);
            return;
        }
    };
    assert_eq!(report.date, date(11, 9));
    assert_eq!(report.late_fee_liabilities, 1);
    let after_tick = state.inner.read().await;
    assert_eq!(after_tick.finance.late_fee_accruals.len(), 30);
    assert_eq!(
        after_tick.dues.first().map(|due| due.delay_penalty),
        Some(Decimal::from(70))
    );
    drop(after_tick);

    let repeated = match run_e2e_tick(&state).await {
        Ok(report) => report,
        Err(error) => {
            assert_eq!(error, sitepulse_backend::e2e_clock::E2eClockError::Disabled);
            return;
        }
    };
    assert_eq!(repeated.late_fee_liabilities, 0);
    assert_eq!(state.inner.read().await.finance.late_fee_accruals.len(), 30);
}

#[tokio::test]
async fn e2e_scheduler_tick_fails_when_the_clock_is_disabled() {
    let state = AppState::new_empty();
    let error = run_e2e_tick(&state).await.err();
    assert_eq!(
        error,
        Some(sitepulse_backend::e2e_clock::E2eClockError::Disabled)
    );
}
