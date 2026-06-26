//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/payroll/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `payroll_amounts` query
/// defined in `./src/tempo/server/payroll/sql/payroll_amounts.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PayrollAmountsRow {
  PayrollAmountsRow(
    engineer_id: Int,
    engineer: String,
    amount: Float,
    days: Float,
  )
}

/// payroll_amounts.sql — the prorated salary owed per employed engineer for a month
/// (FR-F5, FR-F6). One row per engineer employed at any point in the month.
///
/// Params: $1 = month start (date), $2 = month end (date, exclusive). The month
/// range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
/// Squirrel boundary.
///
/// Proration by day, split by level (FR-F6). The paid period is the intersection
/// (the * operator) of employment, the engineer_role (level) version, the salary
/// version, and the month. Splitting on BOTH the role version and the salary
/// version means a mid-month promotion is paid partly at each level's salary, and a
/// mid-month salary revision is honoured day-accurate within a level. A daterange's
/// day count is upper - lower (integer days; e.g. 30 for June). Days in the month
/// is likewise upper(month) - lower(month) (28..31), so the divisor is the actual
/// calendar length of the billed month.
///
/// amount = Σ over sub-periods of  monthly_salary[level] × days_in_subperiod
/// / days_in_month
/// days   = Σ over sub-periods of  days_in_subperiod   (the employed days in month)
///
/// Leave is IGNORED — full pay (FR-F6). The leave table is not consulted: a leave
/// period is paid at full salary, so payroll prorates only over employment, not over
/// "employment minus leave". A hire or termination mid-month clips the paid period
/// to the employed days (employment ∩ month); a promotion splits it.
///
/// Assumptions:
/// * salary has a version covering every (level, day) an engineer is employed in
/// the month (true in the seed: the baseline salary opens at the earliest
/// employment date). An employed day with no salary version yields no
/// sub-period and is silently unpaid — a seed/data gap, not a modelled state.
/// * engineer_role spans employment (every employed engineer has a level), so
/// every employed day is attributed to exactly one level via the intersection.
/// * Calendar days, not business days; full-month salary = monthly_salary when the
/// engineer is employed the whole month at one level.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_amounts(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Date,
) -> Result(pog.Returned(PayrollAmountsRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use engineer <- decode.field(1, decode.string)
    use amount <- decode.field(2, pog.numeric_decoder())
    use days <- decode.field(3, pog.numeric_decoder())
    decode.success(PayrollAmountsRow(engineer_id:, engineer:, amount:, days:))
  }

  "-- payroll_amounts.sql — the prorated salary owed per employed engineer for a month
-- (FR-F5, FR-F6). One row per engineer employed at any point in the month.
--
-- Params: $1 = month start (date), $2 = month end (date, exclusive). The month
-- range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
-- Squirrel boundary.
--
-- Proration by day, split by level (FR-F6). The paid period is the intersection
-- (the * operator) of employment, the engineer_role (level) version, the salary
-- version, and the month. Splitting on BOTH the role version and the salary
-- version means a mid-month promotion is paid partly at each level's salary, and a
-- mid-month salary revision is honoured day-accurate within a level. A daterange's
-- day count is upper - lower (integer days; e.g. 30 for June). Days in the month
-- is likewise upper(month) - lower(month) (28..31), so the divisor is the actual
-- calendar length of the billed month.
--
--   amount = Σ over sub-periods of  monthly_salary[level] × days_in_subperiod
--                                                          / days_in_month
--   days   = Σ over sub-periods of  days_in_subperiod   (the employed days in month)
--
-- Leave is IGNORED — full pay (FR-F6). The leave table is not consulted: a leave
-- period is paid at full salary, so payroll prorates only over employment, not over
-- \"employment minus leave\". A hire or termination mid-month clips the paid period
-- to the employed days (employment ∩ month); a promotion splits it.
--
-- Assumptions:
--   * salary has a version covering every (level, day) an engineer is employed in
--     the month (true in the seed: the baseline salary opens at the earliest
--     employment date). An employed day with no salary version yields no
--     sub-period and is silently unpaid — a seed/data gap, not a modelled state.
--   * engineer_role spans employment (every employed engineer has a level), so
--     every employed day is attributed to exactly one level via the intersection.
--   * Calendar days, not business days; full-month salary = monthly_salary when the
--     engineer is employed the whole month at one level.
WITH params AS (
  SELECT daterange($1::date, $2::date, '[)') AS month
),
sub AS (
  -- each employment ∩ engineer_role(level) ∩ salary-version ∩ month sub-period
  SELECT
    employment.engineer_id,
    salary.monthly_salary,
    employment.employed_during
      * engineer_role.held_during
      * salary.effective_during
      * params.month AS sub_period
  FROM params
  JOIN employment    ON employment.employed_during && params.month
  JOIN engineer_role ON engineer_role.engineer_id = employment.engineer_id
                    AND engineer_role.held_during && employment.employed_during
                    AND engineer_role.held_during && params.month
  JOIN salary        ON salary.level = engineer_role.level
                    AND salary.effective_during && engineer_role.held_during
                    AND salary.effective_during && params.month
)
SELECT
  sub.engineer_id,
  coalesce(engineer.name, '') AS engineer,
  sum(prorated_salary(sub.monthly_salary, sub.sub_period, params.month))::numeric
    AS amount,
  sum(range_days(sub.sub_period))::numeric AS days
FROM sub
CROSS JOIN params
JOIN engineer_current engineer ON engineer.id = sub.engineer_id
WHERE NOT isempty(sub.sub_period)
GROUP BY sub.engineer_id, engineer.name
ORDER BY engineer.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// payroll_line_insert.sql — one prorated payroll line. Last param is the audit_id.
/// $1 = run_id, $2 = engineer_id, $3 = amount, $4 = days.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_line_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: Float,
  arg_4: Float,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- payroll_line_insert.sql — one prorated payroll line. Last param is the audit_id.
-- $1 = run_id, $2 = engineer_id, $3 = amount, $4 = days.
INSERT INTO payroll_line (run_id, engineer_id, amount, days, audit_id)
VALUES ($1, $2, $3, $4, $5);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.float(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `payroll_lines` query
/// defined in `./src/tempo/server/payroll/sql/payroll_lines.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PayrollLinesRow {
  PayrollLinesRow(engineer: String, amount: Float, days: Float)
}

/// payroll_lines.sql — the persisted payroll lines for a period (GET /api/payroll).
/// Reads the SNAPSHOT lines a RunPayroll produced (payroll_line), joined to the
/// engineer name — not a recomputation (the read returns what was paid, the
/// write-time analogue of payroll_amounts).
///
/// Params: $1 = period start (date), $2 = period end (date, exclusive). The period
/// range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
/// Squirrel boundary. Lines for every run whose period OVERLAPS the window are
/// returned (the caller queries month-aligned windows, so in practice exactly the
/// one run for that month). Ordered by engineer name for a deterministic wire
/// order; an engineer with lines in two overlapping runs would appear twice (not
/// expected for month-aligned windows).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_lines(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Date,
) -> Result(pog.Returned(PayrollLinesRow), pog.QueryError) {
  let decoder = {
    use engineer <- decode.field(0, decode.string)
    use amount <- decode.field(1, pog.numeric_decoder())
    use days <- decode.field(2, pog.numeric_decoder())
    decode.success(PayrollLinesRow(engineer:, amount:, days:))
  }

  "-- payroll_lines.sql — the persisted payroll lines for a period (GET /api/payroll).
-- Reads the SNAPSHOT lines a RunPayroll produced (payroll_line), joined to the
-- engineer name — not a recomputation (the read returns what was paid, the
-- write-time analogue of payroll_amounts).
--
-- Params: $1 = period start (date), $2 = period end (date, exclusive). The period
-- range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
-- Squirrel boundary. Lines for every run whose period OVERLAPS the window are
-- returned (the caller queries month-aligned windows, so in practice exactly the
-- one run for that month). Ordered by engineer name for a deterministic wire
-- order; an engineer with lines in two overlapping runs would appear twice (not
-- expected for month-aligned windows).
WITH params AS (
  SELECT daterange($1::date, $2::date, '[)') AS period
)
SELECT
  coalesce(engineer.name, '') AS engineer,
  payroll_line.amount::numeric AS amount,
  payroll_line.days::numeric AS days
FROM params
JOIN payroll_period ON payroll_period.period && params.period
JOIN payroll_line   ON payroll_line.run_id = payroll_period.run_id
JOIN engineer_current engineer ON engineer.id = payroll_line.engineer_id
ORDER BY engineer.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// payroll_period_insert.sql — the immutable 1:1 payroll period (one run per month).
/// Last param is the audit_id. $1 = run_id, $2 = from, $3 = to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_period_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
  arg_3: Date,
  arg_4: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- payroll_period_insert.sql — the immutable 1:1 payroll period (one run per month).
-- Last param is the audit_id. $1 = run_id, $2 = from, $3 = to.
INSERT INTO payroll_period (run_id, period, audit_id)
VALUES ($1, daterange($2::date, $3::date, '[)'), $4);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `payroll_reconciliation` query
/// defined in `./src/tempo/server/payroll/sql/payroll_reconciliation.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PayrollReconciliationRow {
  PayrollReconciliationRow(
    run_id: Option(Int),
    engineer: String,
    preview_amount: String,
    preview_days: Float,
    paid_amount: Option(String),
    paid_days: Option(Float),
  )
}

/// payroll_reconciliation.sql — the month's payroll panel: the LIVE recompute over
/// current facts side by side with the MATERIALIZED payroll_line frozen at run time
/// (FR-F5/FR-F6). One row per engineer present on EITHER side, so an employed
/// engineer not yet in the run (preview only) and an engineer in the run but no
/// longer employed (paid only) both surface.
///
/// Params: $1 = month start (date), $2 = month end (date, exclusive). The month
/// range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
/// Squirrel boundary.
///
/// The LIVE side (preview_amount/preview_days) reuses payroll_amounts' proration
/// CTE verbatim: each employment ∩ engineer_role(level) ∩ salary-version ∩ month
/// sub-period, summed at monthly_salary × days_in_subperiod / days_in_month. A
/// back-dated promotion or salary revision shifts these slices, so the preview is
/// "what should be paid now".
///
/// The PAID side (paid_amount/paid_days) reads the payroll_line a RunPayroll wrote,
/// via the run whose period OVERLAPS the month (payroll_period.period && month). It
/// is NULL until a run exists, and frozen once written, so it does NOT move when a
/// fact is back-dated. The variance preview − paid is the back-pay the correction
/// owes — the bitemporal payoff.
///
/// run_id (nullable) is the run for the month, carried on every row so the caller
/// knows whether a materialized run exists without a second query. FULL OUTER JOIN
/// on engineer_id unions the two sides; ordered by engineer name.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_reconciliation(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Date,
) -> Result(pog.Returned(PayrollReconciliationRow), pog.QueryError) {
  let decoder = {
    use run_id <- decode.field(0, decode.optional(decode.int))
    use engineer <- decode.field(1, decode.string)
    use preview_amount <- decode.field(2, decode.string)
    use preview_days <- decode.field(3, pog.numeric_decoder())
    use paid_amount <- decode.field(4, decode.optional(decode.string))
    use paid_days <- decode.field(5, decode.optional(pog.numeric_decoder()))
    decode.success(PayrollReconciliationRow(
      run_id:,
      engineer:,
      preview_amount:,
      preview_days:,
      paid_amount:,
      paid_days:,
    ))
  }

  "-- payroll_reconciliation.sql — the month's payroll panel: the LIVE recompute over
-- current facts side by side with the MATERIALIZED payroll_line frozen at run time
-- (FR-F5/FR-F6). One row per engineer present on EITHER side, so an employed
-- engineer not yet in the run (preview only) and an engineer in the run but no
-- longer employed (paid only) both surface.
--
-- Params: $1 = month start (date), $2 = month end (date, exclusive). The month
-- range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
-- Squirrel boundary.
--
-- The LIVE side (preview_amount/preview_days) reuses payroll_amounts' proration
-- CTE verbatim: each employment ∩ engineer_role(level) ∩ salary-version ∩ month
-- sub-period, summed at monthly_salary × days_in_subperiod / days_in_month. A
-- back-dated promotion or salary revision shifts these slices, so the preview is
-- \"what should be paid now\".
--
-- The PAID side (paid_amount/paid_days) reads the payroll_line a RunPayroll wrote,
-- via the run whose period OVERLAPS the month (payroll_period.period && month). It
-- is NULL until a run exists, and frozen once written, so it does NOT move when a
-- fact is back-dated. The variance preview − paid is the back-pay the correction
-- owes — the bitemporal payoff.
--
-- run_id (nullable) is the run for the month, carried on every row so the caller
-- knows whether a materialized run exists without a second query. FULL OUTER JOIN
-- on engineer_id unions the two sides; ordered by engineer name.
WITH params AS (
  SELECT daterange($1::date, $2::date, '[)') AS month
),
sub AS (
  -- each employment ∩ engineer_role(level) ∩ salary-version ∩ month sub-period
  SELECT
    employment.engineer_id,
    salary.monthly_salary,
    employment.employed_during
      * engineer_role.held_during
      * salary.effective_during
      * params.month AS sub_period
  FROM params
  JOIN employment    ON employment.employed_during && params.month
  JOIN engineer_role ON engineer_role.engineer_id = employment.engineer_id
                    AND engineer_role.held_during && employment.employed_during
                    AND engineer_role.held_during && params.month
  JOIN salary        ON salary.level = engineer_role.level
                    AND salary.effective_during && engineer_role.held_during
                    AND salary.effective_during && params.month
),
preview AS (
  SELECT
    sub.engineer_id,
    sum(prorated_salary(sub.monthly_salary, sub.sub_period, params.month))::numeric
      AS amount,
    sum(range_days(sub.sub_period))::numeric AS days
  FROM sub
  CROSS JOIN params
  WHERE NOT isempty(sub.sub_period)
  GROUP BY sub.engineer_id
),
run AS (
  SELECT payroll_period.run_id
  FROM params
  JOIN payroll_period ON payroll_period.period && params.month
),
paid AS (
  SELECT
    payroll_line.engineer_id,
    payroll_line.amount::numeric AS amount,
    payroll_line.days::numeric AS days
  FROM payroll_line
  JOIN run ON run.run_id = payroll_line.run_id
)
SELECT
  (SELECT run_id FROM run) AS \"run_id?\",
  coalesce(engineer.name, '') AS engineer,
  coalesce(preview.amount, 0)::text AS preview_amount,
  coalesce(preview.days, 0)::numeric AS preview_days,
  paid.amount::text AS \"paid_amount?\",
  paid.days AS \"paid_days?\"
FROM preview
FULL OUTER JOIN paid ON paid.engineer_id = preview.engineer_id
JOIN engineer_current engineer
  ON engineer.id = coalesce(preview.engineer_id, paid.engineer_id)
ORDER BY engineer.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// payroll_run_create.sql — insert the payroll run identity (ID-ONLY anchor) at a reserved id.
///
/// Step 1 of run_payroll. The id is reserved up-front from payroll_run_id_seq
/// (payroll_run_next_id) and supplied as $1, so this is a plain insert with no
/// RETURNING. The period/lines are separate facts recorded alongside.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_run_create(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- payroll_run_create.sql — insert the payroll run identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of run_payroll. The id is reserved up-front from payroll_run_id_seq
-- (payroll_run_next_id) and supplied as $1, so this is a plain insert with no
-- RETURNING. The period/lines are separate facts recorded alongside.
INSERT INTO payroll_run (id) VALUES ($1);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `payroll_run_next_id` query
/// defined in `./src/tempo/server/payroll/sql/payroll_run_next_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PayrollRunNextIdRow {
  PayrollRunNextIdRow(id: Int)
}

/// payroll_run_next_id.sql — reserve the next payroll run id from its sequence.
///
/// Called before run_payroll records any payroll fact: the handler threads this id
/// into the PayrollRun anchor, its period, and lines in one transaction, so nothing is
/// read back.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_run_next_id(
  db: pog.Connection,
) -> Result(pog.Returned(PayrollRunNextIdRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(PayrollRunNextIdRow(id:))
  }

  "-- payroll_run_next_id.sql — reserve the next payroll run id from its sequence.
--
-- Called before run_payroll records any payroll fact: the handler threads this id
-- into the PayrollRun anchor, its period, and lines in one transaction, so nothing is
-- read back.
SELECT nextval('payroll_run_id_seq')::int AS id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}
