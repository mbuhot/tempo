//// Leave-balance tests (the leave-policy enhancement). The balance is a pure as-of
//// calculation — days accrued (employment ∩ engineer_role ∩ leave_policy[kind,
//// level], leap-aware) minus days taken — so these assert it against the seed at
//// fixed dates, and drive the `take_leave` guard through `command.dispatch_in`.
////
//// Mutating tests run inside a `pog.transaction` that is always rolled back,
//// smuggling the result out through `TransactionRolledBack` (the same pattern as
//// constraint_test/operations_test), so the shared seed is undisturbed.
////
//// Seed reference: Priya (id 1) is L5 employed [2024-01-01, 2027-01-01); Aisha
//// (id 3) is L6 employed [2025-01-01, 2027-01-01) with annual leave 2026-06-08..22
//// (14 days). Policy: annual 20/yr (L1-5), 25/yr (L6-7); sick 10/yr (all).

import gleam/time/calendar.{type Date, Date, January, March, September}
import pog
import shared/types.{Promote, TakeLeave}
import tempo/server/command
import tempo/server/operation.{InsufficientLeaveBalance}
import tempo/server/sql
import test_pool

/// Run `body` inside a transaction, then roll back, smuggling its return value out.
fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

fn balance(
  conn: pog.Connection,
  engineer: Int,
  kind: String,
  as_of: Date,
) -> Float {
  let assert Ok(returned) = sql.leave_balance(conn, engineer, kind, as_of)
  let assert [row] = returned.rows
  row.balance
}

// --- balance calculation ----------------------------------------------------

// Per-level accrual: Priya (L5) accrues 20/yr until 2025-07-01 then 25/yr, so by
// 2026-01-01 she has ~42.52 days (the time-varying policy); Aisha (L6) accrues
// 25/yr, so one full year is 25.
pub fn balance_accrues_per_level_test() {
  rolling_back(fn(conn) {
    assert balance(conn, 1, "annual", Date(2026, January, 1))
      == 42.52054794520548
    assert balance(conn, 3, "annual", Date(2026, January, 1)) == 25.0
  })
}

// Leap-aware: a full leap year (2024, 366 days) accrues exactly the annual grant —
// 20.0, not 20×365/366 — because year_fraction scales by the year's own length.
pub fn full_leap_year_accrues_exactly_the_grant_test() {
  rolling_back(fn(conn) {
    assert balance(conn, 1, "annual", Date(2025, January, 1)) == 20.0
  })
}

// Taken leave reduces the balance: Aisha accrues 25×2 = 50 by 2027-01-01 and has
// taken 14 days (her seeded 2026 leave), leaving 36.
pub fn taken_leave_reduces_balance_test() {
  rolling_back(fn(conn) {
    assert balance(conn, 3, "annual", Date(2027, January, 1)) == 36.0
  })
}

// A kind with no policy (e.g. unpaid) is unlimited: `policied` is false and the
// guard never fires for it.
pub fn unpolicied_kind_is_unlimited_test() {
  rolling_back(fn(conn) {
    let assert Ok(returned) =
      sql.leave_balance(conn, 1, "unpaid", Date(2026, January, 1))
    let assert [row] = returned.rows
    assert row.policied == False
  })
}

// A promotion blends the accrual rate across the promotion date, exactly like
// payroll blends salary: promote Priya L5 -> L6 at 2025-01-01, and by 2026-01-01 she
// has accrued one year at 20 (L5) + one year at 25 (L6) = 45.
pub fn promotion_blends_accrual_rate_test() {
  rolling_back(fn(conn) {
    let assert Ok(_) =
      command.dispatch_in(conn, "tester", Promote(1, 6, Date(2025, January, 1)))
    assert balance(conn, 1, "annual", Date(2026, January, 1)) == 45.0
  })
}

// A future policy change is picked up automatically — the calculation is unchanged,
// it just integrates the right policy version per period. Priya accrues 20/yr until
// 2025-07-01 then 25/yr (the seeded L1-5 step); revising L5 to 30/yr from 2026-01-01
// then layers 30/yr over 2026, giving ~72.52 by 2027.
pub fn policy_change_applies_automatically_test() {
  rolling_back(fn(conn) {
    let assert Ok(_) =
      pog.query(
        "UPDATE leave_policy FOR PORTION OF effective_during FROM $1::date TO NULL"
        <> " SET days_per_year = 30"
        <> " WHERE kind = 'annual' AND level = 5 AND effective_during @> $1::date",
      )
      |> pog.parameter(pog.calendar_date(Date(2026, January, 1)))
      |> pog.execute(on: conn)
    assert balance(conn, 1, "annual", Date(2027, January, 1)) == 72.52054794520548
  })
}

// --- the take_leave guard ---------------------------------------------------

// Within balance: Priya has ~40 days annual by early 2026; a 30-day request on
// return is allowed.
pub fn take_leave_within_balance_is_allowed_test() {
  rolling_back(fn(conn) {
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        TakeLeave(1, "annual", Date(2026, January, 1), Date(2026, January, 31)),
      )
  })
}

// Exceeding balance: a 60-day annual request exceeds Priya's ~40-day balance on
// return, so the guard rejects it as InsufficientLeaveBalance.
pub fn take_leave_exceeding_balance_is_rejected_test() {
  rolling_back(fn(conn) {
    let result =
      command.dispatch_in(
        conn,
        "tester",
        TakeLeave(1, "annual", Date(2026, January, 1), Date(2026, March, 2)),
      )
    let assert Error(InsufficientLeaveBalance(kind:, ..)) = result
    assert kind == "annual"
  })
}

// An un-policied kind is unlimited: a long unpaid leave is allowed regardless of any
// balance.
pub fn take_leave_unpolicied_kind_is_unlimited_test() {
  rolling_back(fn(conn) {
    let assert Ok(_) =
      command.dispatch_in(
        conn,
        "tester",
        TakeLeave(1, "unpaid", Date(2026, January, 1), Date(2026, September, 1)),
      )
  })
}
