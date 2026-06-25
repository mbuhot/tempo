-- pnl_rows.sql — the per-engineer P&L over a period (FR-F7, FR-F8). One row per
-- engineer employed at any point in the period, carrying the raw components the
-- caller turns into profit / margin % / utilization %.
--
-- Params: $1 = period start (date), $2 = period end (date, exclusive) — the period
-- range daterange($1, $2, '[)'). Only scalar dates cross the boundary.
--
-- Returned components (caller computes the rest):
--   revenue          — Σ fraction × day_rate × days over each allocation ∩
--                      engineer_role(level) ∩ rate_card-version ∩ period sub-period
--                      (ACCRUAL, capacity-based): the billable value of the capacity
--                      worked, recognized as the work is performed — the SAME basis
--                      as utilization and cost, independent of invoicing. Leave does
--                      not reduce it.
--   cost             — settled MONTH BY MONTH over the (month-aligned) period: the
--                      SNAPSHOT Σ payroll_line.amount where a payroll run covers the
--                      month (actuals, carrying any back-dated variance), the EXPECTED
--                      salary per employed engineer (the payroll_amounts proration)
--                      where no run covers it yet — so a not-yet-run/future month
--                      shows its expected cost rather than $0. Summed across months.
--   utilization_days — Σ allocation.fraction × days in (allocation ∩ employment ∩
--                      period). Capacity-share numerator (PRD §8: capacity-based,
--                      not hours-based — the timesheet is not consulted; leave does
--                      not reduce it).
--   employed_days    — days in (employment ∩ period); the utilization denominator.
--                      Caller computes utilization_pct = utilization_days /
--                      employed_days, profit = revenue - cost, margin_pct =
--                      profit / revenue.
--
-- A daterange's day count is upper - lower (integer days). The employed/util day
-- counts use the intersection (the * operator) of the relevant facts with the
-- period; empty intersections are dropped via NOT isempty.
--
-- The driving set is engineers EMPLOYED in the period (employed_days > 0): an
-- engineer with revenue or cost but no employment overlap is out of scope for the
-- period and would have a zero denominator. Revenue/cost/util attach via LEFT JOIN
-- and coalesce to 0, so an employed engineer with no invoices, no payroll, or no
-- allocation still appears (zeros), and the per-engineer rows sum to the statement
-- totals.
--
-- Assumptions:
--   * Revenue is recomputed from the capacity facts (allocation × role × rate_card)
--     clipped to the period, so it reflects the work performed regardless of the
--     invoice lifecycle; it equals the billed amount once a month is invoiced at the
--     agreed rates, but does not wait on (or require) an invoice.
--   * Cost is settled MONTH BY MONTH over the (month-aligned) window. A month with a
--     payroll run contributes its SNAPSHOT payroll_line (what was paid — NOT a
--     recomputation, so a back-dated variance shows; PRD §8). A month with no run yet
--     contributes the EXPECTED salary (the payroll_amounts proration), so a future /
--     not-yet-run month reads its expected cost, not $0 — the cost-side mirror of the
--     capacity revenue. The two are mutually exclusive per month (NOT EXISTS), so
--     they never double-count. The caller's windows are month-aligned (month / YTD).
WITH params AS (
  SELECT daterange($1::date, $2::date, '[)') AS period
),
months AS (
  -- one calendar-month bucket per month in the period. The period is month-aligned
  -- (the caller passes first-of-month .. first-of-next-month, or first-of-year ..
  -- first-of-next-month), so cost can be settled per month: actuals where a payroll
  -- run covers the month, an estimate where none does yet.
  SELECT
    daterange(
      month_start::date,
      (month_start + interval '1 month')::date,
      '[)'
    ) AS span
  FROM params,
    generate_series(
      date_trunc('month', lower(params.period)),
      date_trunc('month', upper(params.period) - 1),
      interval '1 month'
    ) AS month_start
),
emp AS (
  -- employed days in the period per engineer (employment ∩ period)
  SELECT
    employment.engineer_id,
    sum(range_days(employment.employed_during * params.period))::numeric
      AS employed_days
  FROM params
  JOIN employment ON employment.employed_during && params.period
  GROUP BY employment.engineer_id
),
util AS (
  -- Σ fraction × days in allocation ∩ employment ∩ period (capacity share)
  SELECT
    allocation.engineer_id,
    sum(allocation.fraction
        * range_days(allocation.allocated_during * employment.employed_during
                     * params.period))::numeric AS utilization_days
  FROM params
  JOIN allocation ON allocation.allocated_during && params.period
  JOIN employment ON employment.engineer_id = allocation.engineer_id
                 AND employment.employed_during && allocation.allocated_during
                 AND employment.employed_during && params.period
  WHERE NOT isempty(allocation.allocated_during * employment.employed_during
                    * params.period)
  GROUP BY allocation.engineer_id
),
rev AS (
  -- revenue (ACCRUAL, capacity-based): the billable value of the capacity each
  -- engineer worked in the period — Σ fraction × day_rate × days over each
  -- allocation ∩ engineer_role(level) ∩ rate_card-version ∩ period sub-period.
  -- Recognized as the work is performed, on the SAME capacity basis as utilization
  -- and cost, independent of whether/when an invoice is drafted or issued (the
  -- invoice lifecycle governs billing/cash, not P&L revenue — ADR-043). Splitting on
  -- the role version AND the rate_card version bills a mid-period promotion or rate
  -- revision day-accurate at each level's rate. Leave does NOT reduce it (capacity,
  -- not hours) — symmetric with utilization_days.
  SELECT
    allocation.engineer_id,
    sum(allocation.fraction
        * recognized_revenue(
            rate_card.day_rate,
            allocation.allocated_during * engineer_role.held_during
              * rate_card.effective_during * params.period))::numeric
      AS revenue
  FROM params
  JOIN allocation    ON allocation.allocated_during && params.period
  JOIN engineer_role ON engineer_role.engineer_id = allocation.engineer_id
                    AND engineer_role.held_during && allocation.allocated_during
                    AND engineer_role.held_during && params.period
  JOIN rate_card     ON rate_card.level = engineer_role.level
                    AND rate_card.effective_during && engineer_role.held_during
                    AND rate_card.effective_during && params.period
  WHERE NOT isempty(allocation.allocated_during * engineer_role.held_during
                    * rate_card.effective_during * params.period)
  GROUP BY allocation.engineer_id
),
actual_cost AS (
  -- months WITH a payroll run: the SNAPSHOT amount paid each engineer (what was
  -- actually paid, carrying any back-dated variance).
  SELECT
    payroll_line.engineer_id,
    sum(payroll_line.amount)::numeric AS cost
  FROM months
  JOIN payroll_period ON payroll_period.period && months.span
  JOIN payroll_line   ON payroll_line.run_id = payroll_period.run_id
  GROUP BY payroll_line.engineer_id
),
estimated_cost AS (
  -- months with NO payroll run yet (a future / not-yet-run month, or a gap): the
  -- EXPECTED salary per employed engineer — the SAME proration as payroll_amounts
  -- (employment ∩ role-version ∩ salary-version ∩ month, full salary, leave-blind),
  -- so the estimate equals the run that later materializes the month. The NOT EXISTS
  -- excludes any month a run already covers, so actual and estimate never double-count.
  SELECT
    employment.engineer_id,
    sum(prorated_salary(
          salary.monthly_salary,
          employment.employed_during * engineer_role.held_during
            * salary.effective_during * months.span,
          months.span))::numeric AS cost
  FROM months
  JOIN employment    ON employment.employed_during && months.span
  JOIN engineer_role ON engineer_role.engineer_id = employment.engineer_id
                    AND engineer_role.held_during && employment.employed_during
                    AND engineer_role.held_during && months.span
  JOIN salary        ON salary.level = engineer_role.level
                    AND salary.effective_during && engineer_role.held_during
                    AND salary.effective_during && months.span
  WHERE NOT EXISTS (
    SELECT 1 FROM payroll_period WHERE payroll_period.period && months.span
  )
  AND NOT isempty(employment.employed_during * engineer_role.held_during
                  * salary.effective_during * months.span)
  GROUP BY employment.engineer_id
),
cost AS (
  -- per engineer: actuals for run-covered months + estimates for the rest
  SELECT engineer_id, sum(cost)::numeric AS cost
  FROM (
    SELECT engineer_id, cost FROM actual_cost
    UNION ALL
    SELECT engineer_id, cost FROM estimated_cost
  ) per_engineer
  GROUP BY engineer_id
)
SELECT
  emp.engineer_id,
  coalesce(engineer.name, '') AS engineer,
  coalesce(rev.revenue, 0)::numeric AS revenue,
  coalesce(cost.cost, 0)::numeric AS cost,
  coalesce(util.utilization_days, 0)::numeric AS utilization_days,
  emp.employed_days
FROM emp
JOIN engineer_current engineer ON engineer.id = emp.engineer_id
LEFT JOIN util ON util.engineer_id = emp.engineer_id
LEFT JOIN rev  ON rev.engineer_id = emp.engineer_id
LEFT JOIN cost ON cost.engineer_id = emp.engineer_id
ORDER BY engineer.name;
