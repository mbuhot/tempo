//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/leave/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `leave_balance` query
/// defined in `./src/tempo/server/leave/sql/leave_balance.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type LeaveBalanceRow {
  LeaveBalanceRow(policied: Bool, balance: Float)
}

/// leave_balance.sql — an engineer's leave balance for a kind as of a date: days
/// accrued (employment ∩ role ∩ leave_policy[kind, level], leap-aware) minus days
/// taken, both up to as_of. `policied` is false when the kind has no policy at all —
/// then it is unlimited and the take_leave guard does not apply. The balance is a
/// pure calculation at any past or future date; nothing is stored.
/// $1 = engineer_id, $2 = kind, $3 = as_of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_balance(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
) -> Result(pog.Returned(LeaveBalanceRow), pog.QueryError) {
  let decoder = {
    use policied <- decode.field(0, decode.bool)
    use balance <- decode.field(1, pog.numeric_decoder())
    decode.success(LeaveBalanceRow(policied:, balance:))
  }

  "-- leave_balance.sql — an engineer's leave balance for a kind as of a date: days
-- accrued (employment ∩ role ∩ leave_policy[kind, level], leap-aware) minus days
-- taken, both up to as_of. `policied` is false when the kind has no policy at all —
-- then it is unlimited and the take_leave guard does not apply. The balance is a
-- pure calculation at any past or future date; nothing is stored.
-- $1 = engineer_id, $2 = kind, $3 = as_of date.
SELECT
  EXISTS (SELECT 1 FROM leave_policy WHERE kind = $2) AS policied,
  (accrued_leave($1, $2, $3::date) - taken_leave($1, $2, $3::date))::numeric AS balance;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `leave_balances` query
/// defined in `./src/tempo/server/leave/sql/leave_balances.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type LeaveBalancesRow {
  LeaveBalancesRow(
    engineer_id: Int,
    engineer: String,
    annual: Float,
    sick: Float,
  )
}

/// leave_balances.sql — each engineer employed as of $1 with their annual and sick
/// leave balance (accrued − taken, rounded to one day) on that date, for the board
/// readout; it recomputes as the board's date moves. $1 = the as-of date.
///
/// engineer_id is emitted alongside the name so the people-roster read model can
/// join the annual balance to people_list.sql rows by id (the board readout keys by
/// name; /api/people keys by id).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_balances(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(LeaveBalancesRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use engineer <- decode.field(1, decode.string)
    use annual <- decode.field(2, pog.numeric_decoder())
    use sick <- decode.field(3, pog.numeric_decoder())
    decode.success(LeaveBalancesRow(engineer_id:, engineer:, annual:, sick:))
  }

  "-- leave_balances.sql — each engineer employed as of $1 with their annual and sick
-- leave balance (accrued − taken, rounded to one day) on that date, for the board
-- readout; it recomputes as the board's date moves. $1 = the as-of date.
--
-- engineer_id is emitted alongside the name so the people-roster read model can
-- join the annual balance to people_list.sql rows by id (the board readout keys by
-- name; /api/people keys by id).
SELECT
  engineer.id AS engineer_id,
  coalesce(engineer_current.name, '') AS engineer,
  round(accrued_leave(engineer.id, 'annual', $1::date)
        - taken_leave(engineer.id, 'annual', $1::date), 1)::numeric AS annual,
  round(accrued_leave(engineer.id, 'sick', $1::date)
        - taken_leave(engineer.id, 'sick', $1::date), 1)::numeric AS sick
FROM engineer
JOIN engineer_current ON engineer_current.id = engineer.id
WHERE EXISTS (
  SELECT 1 FROM employment
  WHERE employment.engineer_id = engineer.id
    AND employment.employed_during @> $1::date
)
ORDER BY engineer;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `leave_check` query
/// defined in `./src/tempo/server/leave/sql/leave_check.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type LeaveCheckRow {
  LeaveCheckRow(policied: Bool, available: Float, requested: Float)
}

/// leave_check.sql — the take_leave guard input for a [valid_from, valid_to) leave:
/// `available` is the balance on return (accrued − taken as of valid_to, the new
/// leave not yet recorded), `requested` the calendar days (valid_to − valid_from), and
/// `policied` whether the kind has any policy (false ⇒ unlimited, no guard). The
/// handler rejects when policied AND available < requested.
/// $1 = engineer_id, $2 = kind, $3 = valid_from, $4 = valid_to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_check(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
  arg_4: Date,
) -> Result(pog.Returned(LeaveCheckRow), pog.QueryError) {
  let decoder = {
    use policied <- decode.field(0, decode.bool)
    use available <- decode.field(1, pog.numeric_decoder())
    use requested <- decode.field(2, pog.numeric_decoder())
    decode.success(LeaveCheckRow(policied:, available:, requested:))
  }

  "-- leave_check.sql — the take_leave guard input for a [valid_from, valid_to) leave:
-- `available` is the balance on return (accrued − taken as of valid_to, the new
-- leave not yet recorded), `requested` the calendar days (valid_to − valid_from), and
-- `policied` whether the kind has any policy (false ⇒ unlimited, no guard). The
-- handler rejects when policied AND available < requested.
-- $1 = engineer_id, $2 = kind, $3 = valid_from, $4 = valid_to.
SELECT
  EXISTS (SELECT 1 FROM leave_policy WHERE kind = $2) AS policied,
  (accrued_leave($1, $2, $4::date) - taken_leave($1, $2, $4::date))::numeric AS available,
  ($4::date - $3::date)::numeric AS requested;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// leave_close_all.sql — cap all of an engineer's leave from a date (§5a, pattern 4).
///
/// DELETE … FOR PORTION OF over `[end, ∞)` with no `@>` filter: intentionally
/// broad so it caps every spanning leave row to `[lo, end)` and drops the
/// fully-future ones. Invoked by `terminate_employment` as the children-first
/// cascade reaches `leave` (before `engineer_role` / `employment`).
/// $1 = engineer_id, $2 = end.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_close_all(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- leave_close_all.sql — cap all of an engineer's leave from a date (§5a, pattern 4).
--
-- DELETE … FOR PORTION OF over `[end, ∞)` with no `@>` filter: intentionally
-- broad so it caps every spanning leave row to `[lo, end)` and drops the
-- fully-future ones. Invoked by `terminate_employment` as the children-first
-- cascade reaches `leave` (before `engineer_role` / `employment`).
-- $1 = engineer_id, $2 = end.
DELETE FROM leave
   FOR PORTION OF on_leave_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `leave_history` query
/// defined in `./src/tempo/server/leave/sql/leave_history.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type LeaveHistoryRow {
  LeaveHistoryRow(kind: String, valid_from: Date, valid_to: Date)
}

/// leave_history.sql — one engineer's full leave timeline for the detail read model
/// (GET /api/engineers/:id; the LeaveRecord list). Param: $1 = engineer_id.
///
/// Every leave period-row for the engineer, decomposed to plain dates: kind,
/// lower(on_leave_during) AS valid_from, upper(on_leave_during) AS valid_to. A leave
/// window always has an end, so upper(on_leave_during) is non-null for every seed
/// row. Not as-of filtered — the detail page lists all leave. Ordered oldest-first.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_history(
  db: pog.Connection,
  leave_engineer_id: Int,
) -> Result(pog.Returned(LeaveHistoryRow), pog.QueryError) {
  let decoder = {
    use kind <- decode.field(0, decode.string)
    use valid_from <- decode.field(1, pog.calendar_date_decoder())
    use valid_to <- decode.field(2, pog.calendar_date_decoder())
    decode.success(LeaveHistoryRow(kind:, valid_from:, valid_to:))
  }

  "-- leave_history.sql — one engineer's full leave timeline for the detail read model
-- (GET /api/engineers/:id; the LeaveRecord list). Param: $1 = engineer_id.
--
-- Every leave period-row for the engineer, decomposed to plain dates: kind,
-- lower(on_leave_during) AS valid_from, upper(on_leave_during) AS valid_to. A leave
-- window always has an end, so upper(on_leave_during) is non-null for every seed
-- row. Not as-of filtered — the detail page lists all leave. Ordered oldest-first.
SELECT
  leave.kind,
  lower(leave.on_leave_during) AS valid_from,
  upper(leave.on_leave_during) AS valid_to
FROM leave
WHERE leave.engineer_id = $1
ORDER BY lower(leave.on_leave_during);
"
  |> pog.query
  |> pog.parameter(pog.int(leave_engineer_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `leave_policy_list` query
/// defined in `./src/tempo/server/leave/sql/leave_policy_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type LeavePolicyListRow {
  LeavePolicyListRow(kind: String, level: Int, days_per_year: Float)
}

/// leave_policy_list.sql — the leave-accrual policy in force as of $1 (GET
/// /api/settings?as_of=$1; the leave-policy table on the Settings page; FR-ST3). One
/// row per (kind, level) whose policy span covers $1: kind + level + days_per_year,
/// ordered by kind then level. A (kind, level) with no policy row covering $1 is
/// absent from the list and is treated as unlimited (the take_leave guard does not
/// fire for it). Param: $1 = the as-of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_policy_list(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(LeavePolicyListRow), pog.QueryError) {
  let decoder = {
    use kind <- decode.field(0, decode.string)
    use level <- decode.field(1, decode.int)
    use days_per_year <- decode.field(2, pog.numeric_decoder())
    decode.success(LeavePolicyListRow(kind:, level:, days_per_year:))
  }

  "-- leave_policy_list.sql — the leave-accrual policy in force as of $1 (GET
-- /api/settings?as_of=$1; the leave-policy table on the Settings page; FR-ST3). One
-- row per (kind, level) whose policy span covers $1: kind + level + days_per_year,
-- ordered by kind then level. A (kind, level) with no policy row covering $1 is
-- absent from the list and is treated as unlimited (the take_leave guard does not
-- fire for it). Param: $1 = the as-of date.
SELECT
  leave_policy.kind,
  leave_policy.level,
  leave_policy.days_per_year
FROM leave_policy
WHERE leave_policy.effective_during @> $1::date
ORDER BY leave_policy.kind, leave_policy.level;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// leave_take.sql — assert an engineer on leave over a bounded period, contained by
/// employment (leave_within_employment PERIOD FK). Last param is the audit_id.
/// $1 = engineer_id, $2 = kind, $3 = from, $4 = to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_take(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
  arg_4: Date,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- leave_take.sql — assert an engineer on leave over a bounded period, contained by
-- employment (leave_within_employment PERIOD FK). Last param is the audit_id.
-- $1 = engineer_id, $2 = kind, $3 = from, $4 = to.
INSERT INTO leave (engineer_id, kind, on_leave_during, audit_id)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'), $5);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
