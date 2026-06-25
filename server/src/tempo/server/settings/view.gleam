//// Domain: the settings READ model (`GET /api/settings?as_of=`). Runs the three
//// as-of policy reads — `rate_card_list` (charge rate per level), `salary_list`
//// (monthly cost per level), `leave_policy_list` (days-per-year per kind+level) —
//// and bundles them with the date. No HTTP — this layer never imports `wisp`.

import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/settings/view.{
  type LeavePolicyRow, type RateCardRow, type SalaryRow, type Settings,
  LeavePolicyRow, RateCardRow, SalaryRow, Settings,
}
import tempo/server/context.{type Context}
import tempo/server/sql

/// The settings as-of `as_of`: the current rate card, salaries, and leave policy.
pub fn read(context: Context, as_of: Date) -> Result(Settings, pog.QueryError) {
  use rate_card <- result.try(sql.rate_card_list(context.db, as_of))
  use salaries <- result.try(sql.salary_list(context.db, as_of))
  use leave_policy <- result.map(sql.leave_policy_list(context.db, as_of))
  Settings(
    date: as_of,
    rate_card: list.map(rate_card.rows, rate_card_row_to_shared),
    salaries: list.map(salaries.rows, salary_row_to_shared),
    leave_policy: list.map(leave_policy.rows, leave_policy_row_to_shared),
  )
}

fn rate_card_row_to_shared(row: sql.RateCardListRow) -> RateCardRow {
  RateCardRow(level: row.level, day_rate: row.day_rate)
}

fn salary_row_to_shared(row: sql.SalaryListRow) -> SalaryRow {
  SalaryRow(level: row.level, monthly_salary: row.monthly_salary)
}

fn leave_policy_row_to_shared(row: sql.LeavePolicyListRow) -> LeavePolicyRow {
  LeavePolicyRow(
    kind: row.kind,
    level: row.level,
    days_per_year: row.days_per_year,
  )
}
