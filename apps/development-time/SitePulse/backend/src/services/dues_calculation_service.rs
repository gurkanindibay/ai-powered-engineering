use chrono::NaiveDate;
use rust_decimal::Decimal;
use rust_decimal::RoundingStrategy;
use crate::models::{DebtStatus, DuesLiability};

pub struct DuesCalculationService;

impl DuesCalculationService {
    pub fn new() -> Self {
        Self
    }

    /// Calculates the KMK Article 20 statutory delay fee pro-rated daily.
    /// Penalty = Principal * 0.05 * (DaysOverdue / 30)
    pub fn calculate_delay_penalty(&self, mut dues: DuesLiability, evaluation_date: NaiveDate) -> DuesLiability {
        if dues.status == DebtStatus::Paid {
            return dues;
        }

        if evaluation_date <= dues.due_date {
            dues.status = DebtStatus::Pending;
            dues.delay_penalty = Decimal::ZERO;
            dues.total_amount = dues.principal_amount;
            return dues;
        }

        let days_overdue = (evaluation_date - dues.due_date).num_days();
        if days_overdue <= 0 {
            dues.status = DebtStatus::Pending;
            dues.delay_penalty = Decimal::ZERO;
            dues.total_amount = dues.principal_amount;
            return dues;
        }

        let monthly_rate = Decimal::from_str_exact("0.05").unwrap();
        let days = Decimal::from(days_overdue);
        let days_in_month = Decimal::from(30);

        let daily_ratio = days / days_in_month;
        let penalty_raw = dues.principal_amount * monthly_rate * daily_ratio;
        let penalty = penalty_raw.round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero);

        dues.status = DebtStatus::Overdue;
        dues.delay_penalty = penalty;
        dues.total_amount = dues.principal_amount + penalty;
        dues
    }
}
