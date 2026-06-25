//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/forecast/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `forecast` query
/// defined in `./src/tempo/server/forecast/sql/forecast.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ForecastRow {
  ForecastRow(month: Date, revenue: Float, cost: Float)
}

/// forecast.sql — the forward P&L from COMMITTED DEMAND (the demand-side mirror of
/// the capacity-based P&L in pnl_rows.sql). One row per calendar month from the
/// as-of month to the cliff, carrying the projected revenue and cost; the caller
/// derives profit and margin.
///
/// Param: $1 = as-of date. Only the scalar as-of crosses the Squirrel boundary; the
/// window and every sub-period range are built in SQL.
///
/// WINDOW. From the first of the as-of month to the CLIFF =
/// max(upper(required_during) over all project_requirement,
/// upper(allocated_during) over all allocation)
/// i.e. the last day any committed demand exists (a requirement's end or, where a
/// project forecasts off its allocations, the allocation's end). generate_series
/// steps month-by-month from the as-of month's first day up to (but not including)
/// the cliff, and each step's calendar month [first, first-of-next) is one bucket.
///
/// EFFECTIVE DEMAND per (project, month) — decision (b): if the project has ANY
/// requirement covering the month it forecasts off its REQUIREMENT lines
/// (level, quantity); otherwise off its ALLOCATIONS mapped to (level, fraction) via
/// engineer_role. Never both, so no double-count. The switch is the
/// EXISTS (requirement for this project overlapping the month)
/// predicate: requirement-bearing project-months take the `requirement_demand`
/// branch; the rest take the `allocation_demand` branch (its WHERE NOT EXISTS
/// excludes any project-month a requirement already covers). The two branches are
/// UNIONed into one demand stream of (project_id, month, level, quantity, sub_period)
/// where sub_period is the demand-line ∩ month — the slice that month sees.
///
/// REVENUE(month) = Σ quantity × rate_card[level].day_rate × days over each
/// demand ∩ rate_card-version ∩ month sub-period — the SAME rate/version splitting
/// as pnl_rows.rev (split on the rate_card version so a mid-month rate revision
/// bills day-accurate). quantity replaces the allocation fraction as the capacity
/// multiplier; for the allocation branch quantity IS the fraction, so a forecast
/// that falls through to allocations reproduces the capacity-based revenue.
///
/// COST(month) = Σ quantity × monthly_salary[level] × days / days-in-month over each
/// demand ∩ salary-version ∩ month sub-period — the expected cost to FULFIL the
/// demand at the standard salary for the level, INCLUDING roles that would have to
/// be hired (a requirement with no engineer behind it still costs salary[level]).
/// Same proration as payroll_amounts (days_in_subperiod / days_in_month), split on
/// the salary version.
///
/// A daterange's day count is upper - lower (integer days). days-in-month is
/// upper(month) - lower(month) (28..31). Empty intersections are dropped via NOT
/// isempty. revenue/cost attach to the month bucket via LEFT JOIN and coalesce to 0,
/// so a month inside the window with no covered demand still appears as a zero row
/// (the series is dense from the as-of month to the cliff).
///
/// Assumptions:
/// * The cliff is finite: every requirement and allocation period is bounded
/// above (true in the seed — runs/contracts are bounded). With no requirements
/// AND no allocations the cliff is NULL and the series is empty.
/// * rate_card / salary have a version covering each (level, day) the demand spans
/// (true in the seed: baselines open at/under the earliest run). An uncovered
/// day yields no sub-period and is silently unpriced — a seed/data gap.
/// * Cost for to-hire roles uses the standard salary[level] (no hiring ramp or
/// recruiting cost) — per the spec's out-of-scope note.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn forecast(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(ForecastRow), pog.QueryError) {
  let decoder = {
    use month <- decode.field(0, pog.calendar_date_decoder())
    use revenue <- decode.field(1, pog.numeric_decoder())
    use cost <- decode.field(2, pog.numeric_decoder())
    decode.success(ForecastRow(month:, revenue:, cost:))
  }

  "-- forecast.sql — the forward P&L from COMMITTED DEMAND (the demand-side mirror of
-- the capacity-based P&L in pnl_rows.sql). One row per calendar month from the
-- as-of month to the cliff, carrying the projected revenue and cost; the caller
-- derives profit and margin.
--
-- Param: $1 = as-of date. Only the scalar as-of crosses the Squirrel boundary; the
-- window and every sub-period range are built in SQL.
--
-- WINDOW. From the first of the as-of month to the CLIFF =
--   max(upper(required_during) over all project_requirement,
--       upper(allocated_during) over all allocation)
-- i.e. the last day any committed demand exists (a requirement's end or, where a
-- project forecasts off its allocations, the allocation's end). generate_series
-- steps month-by-month from the as-of month's first day up to (but not including)
-- the cliff, and each step's calendar month [first, first-of-next) is one bucket.
--
-- EFFECTIVE DEMAND per (project, month) — decision (b): if the project has ANY
-- requirement covering the month it forecasts off its REQUIREMENT lines
-- (level, quantity); otherwise off its ALLOCATIONS mapped to (level, fraction) via
-- engineer_role. Never both, so no double-count. The switch is the
--   EXISTS (requirement for this project overlapping the month)
-- predicate: requirement-bearing project-months take the `requirement_demand`
-- branch; the rest take the `allocation_demand` branch (its WHERE NOT EXISTS
-- excludes any project-month a requirement already covers). The two branches are
-- UNIONed into one demand stream of (project_id, month, level, quantity, sub_period)
-- where sub_period is the demand-line ∩ month — the slice that month sees.
--
-- REVENUE(month) = Σ quantity × rate_card[level].day_rate × days over each
--   demand ∩ rate_card-version ∩ month sub-period — the SAME rate/version splitting
--   as pnl_rows.rev (split on the rate_card version so a mid-month rate revision
--   bills day-accurate). quantity replaces the allocation fraction as the capacity
--   multiplier; for the allocation branch quantity IS the fraction, so a forecast
--   that falls through to allocations reproduces the capacity-based revenue.
--
-- COST(month) = Σ quantity × monthly_salary[level] × days / days-in-month over each
--   demand ∩ salary-version ∩ month sub-period — the expected cost to FULFIL the
--   demand at the standard salary for the level, INCLUDING roles that would have to
--   be hired (a requirement with no engineer behind it still costs salary[level]).
--   Same proration as payroll_amounts (days_in_subperiod / days_in_month), split on
--   the salary version.
--
-- A daterange's day count is upper - lower (integer days). days-in-month is
-- upper(month) - lower(month) (28..31). Empty intersections are dropped via NOT
-- isempty. revenue/cost attach to the month bucket via LEFT JOIN and coalesce to 0,
-- so a month inside the window with no covered demand still appears as a zero row
-- (the series is dense from the as-of month to the cliff).
--
-- Assumptions:
--   * The cliff is finite: every requirement and allocation period is bounded
--     above (true in the seed — runs/contracts are bounded). With no requirements
--     AND no allocations the cliff is NULL and the series is empty.
--   * rate_card / salary have a version covering each (level, day) the demand spans
--     (true in the seed: baselines open at/under the earliest run). An uncovered
--     day yields no sub-period and is silently unpriced — a seed/data gap.
--   * Cost for to-hire roles uses the standard salary[level] (no hiring ramp or
--     recruiting cost) — per the spec's out-of-scope note.
WITH cliff AS (
  SELECT greatest(
    (SELECT max(upper(required_during)) FROM project_requirement),
    (SELECT max(upper(allocated_during)) FROM allocation)
  ) AS at
),
months AS (
  -- one calendar-month bucket per step from the as-of month to the cliff
  SELECT
    month_start::date AS month,
    daterange(
      month_start::date,
      (month_start + interval '1 month')::date,
      '[)'
    ) AS span
  FROM cliff,
    generate_series(
      date_trunc('month', $1::date),
      date_trunc('month', cliff.at - 1),
      interval '1 month'
    ) AS month_start
),
requirement_demand AS (
  -- the requirement branch: a project's requirement lines, sliced to each month
  SELECT
    project_requirement.project_id,
    months.month,
    months.span,
    project_requirement.level,
    project_requirement.quantity,
    project_requirement.required_during * months.span AS sub_period
  FROM months
  JOIN project_requirement
    ON project_requirement.required_during && months.span
),
allocation_demand AS (
  -- the allocation fallback: a project's allocations mapped to (level, fraction)
  -- via engineer_role, but ONLY for project-months no requirement covers (the (b)
  -- switch). quantity = the allocation fraction.
  SELECT
    allocation.project_id,
    months.month,
    months.span,
    engineer_role.level,
    allocation.fraction AS quantity,
    allocation.allocated_during
      * engineer_role.held_during
      * months.span AS sub_period
  FROM months
  JOIN allocation
    ON allocation.allocated_during && months.span
  JOIN engineer_role
    ON engineer_role.engineer_id = allocation.engineer_id
   AND engineer_role.held_during && allocation.allocated_during
   AND engineer_role.held_during && months.span
  WHERE NOT EXISTS (
    SELECT 1 FROM project_requirement
     WHERE project_requirement.project_id = allocation.project_id
       AND project_requirement.required_during && months.span
  )
),
demand AS (
  SELECT project_id, month, span, level, quantity, sub_period
    FROM requirement_demand
  UNION ALL
  SELECT project_id, month, span, level, quantity, sub_period
    FROM allocation_demand
),
revenue AS (
  -- Σ quantity × day_rate × days over each demand ∩ rate_card-version ∩ month
  SELECT
    demand.month,
    sum(demand.quantity
        * recognized_revenue(
            rate_card.day_rate,
            demand.sub_period * rate_card.effective_during))::numeric
      AS revenue
  FROM demand
  JOIN rate_card ON rate_card.level = demand.level
                AND rate_card.effective_during && demand.sub_period
  WHERE NOT isempty(demand.sub_period * rate_card.effective_during)
  GROUP BY demand.month
),
cost AS (
  -- Σ quantity × monthly_salary × days / days-in-month over each demand ∩
  -- salary-version ∩ month
  SELECT
    demand.month,
    sum(demand.quantity
        * prorated_salary(
            salary.monthly_salary,
            demand.sub_period * salary.effective_during,
            demand.span))::numeric
      AS cost
  FROM demand
  JOIN salary ON salary.level = demand.level
             AND salary.effective_during && demand.sub_period
  WHERE NOT isempty(demand.sub_period * salary.effective_during)
  GROUP BY demand.month
)
SELECT
  months.month,
  coalesce(revenue.revenue, 0)::numeric AS revenue,
  coalesce(cost.cost, 0)::numeric AS cost
FROM months
LEFT JOIN revenue ON revenue.month = months.month
LEFT JOIN cost    ON cost.month = months.month
ORDER BY months.month;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
