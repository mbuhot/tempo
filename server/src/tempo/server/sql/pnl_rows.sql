-- pnl_rows.sql — the per-engineer P&L over a period (FR-F7, FR-F8). One row per
-- engineer employed at any point in the period, carrying the raw components the
-- caller turns into profit / margin % / utilization %.
--
-- Params: $1 = period start (date), $2 = period end (date, exclusive). The same
-- two dates serve as the period range (daterange($1, $2, '[)')) AND $2 is the
-- as-of instant for invoice status (the period's exclusive upper bound — "the
-- state at the close of the period"). Only scalar dates cross the boundary.
--
-- Returned components (caller computes the rest):
--   revenue          — Σ invoice_line.amount over invoices whose billing_period
--                      OVERLAPS the period AND whose status AS OF $2 is issued or
--                      paid. Revenue is recognized on issue (PRD §8), and the
--                      as-of predicate (status_during @> $2) means scrubbing the
--                      period end back before an issue date drops that revenue
--                      (FR-F4 carried into the P&L).
--   cost             — Σ payroll_line.amount over payroll_runs whose period
--                      OVERLAPS the period.
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
--   * "Overlaps the period" (&&) for invoices/payroll, NOT containment: a billing
--     month or run period that straddles the P&L window contributes in full
--     (consistent with month-grained invoicing/payroll; the caller chooses
--     month/YTD windows aligned to month boundaries so straddling does not occur
--     in practice).
--   * An invoice has at most one status covering $2 (WITHOUT OVERLAPS guarantees
--     it); EXISTS over {issued, paid} is the recognition gate.
--   * revenue/cost are summed from the SNAPSHOT lines (invoice_line, payroll_line),
--     so they reflect what was billed/paid, not a recomputation (PRD §8).
WITH params AS (
  SELECT
    daterange($1::date, $2::date, '[)') AS period,
    $2::date AS as_of
),
emp AS (
  -- employed days in the period per engineer (employment ∩ period)
  SELECT
    employment.engineer_id,
    sum(upper(employment.employed_during * params.period)
        - lower(employment.employed_during * params.period))::numeric
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
        * (upper(allocation.allocated_during * employment.employed_during
                 * params.period)
           - lower(allocation.allocated_during * employment.employed_during
                   * params.period)))::numeric AS utilization_days
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
  -- revenue: invoice_line.amount for invoices overlapping the period whose status
  -- AS OF $2 (period end) is issued or paid
  SELECT
    invoice_line.engineer_id,
    sum(invoice_line.amount)::numeric AS revenue
  FROM params
  JOIN invoice      ON invoice.billing_period && params.period
  JOIN invoice_line ON invoice_line.invoice_id = invoice.id
  WHERE EXISTS (
    SELECT 1 FROM invoice_status
    WHERE invoice_status.invoice_id = invoice.id
      AND invoice_status.status_during @> params.as_of
      AND invoice_status.status IN ('issued', 'paid')
  )
  GROUP BY invoice_line.engineer_id
),
cost AS (
  -- cost: payroll_line.amount for payroll runs overlapping the period
  SELECT
    payroll_line.engineer_id,
    sum(payroll_line.amount)::numeric AS cost
  FROM params
  JOIN payroll_run  ON payroll_run.period && params.period
  JOIN payroll_line ON payroll_line.run_id = payroll_run.id
  GROUP BY payroll_line.engineer_id
)
SELECT
  emp.engineer_id,
  engineer.name AS engineer,
  coalesce(rev.revenue, 0)::numeric AS revenue,
  coalesce(cost.cost, 0)::numeric AS cost,
  coalesce(util.utilization_days, 0)::numeric AS utilization_days,
  emp.employed_days
FROM emp
JOIN engineer  ON engineer.id = emp.engineer_id
LEFT JOIN util ON util.engineer_id = emp.engineer_id
LEFT JOIN rev  ON rev.engineer_id = emp.engineer_id
LEFT JOIN cost ON cost.engineer_id = emp.engineer_id
ORDER BY engineer.name;
