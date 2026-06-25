-- invoice_billing_lines.sql — the contract-agreed billable lines for a project
-- over a month (FR-F1, FR-F2: the temporal centerpiece). One row per (engineer,
-- level) who worked the project during the month, at the rate the CONTRACT agreed.
--
-- Params: $1 = project_id (entity id), $2 = month start (date), $3 = month end
-- (date, exclusive). The month range is built in SQL as daterange($2, $3, '[)'),
-- so only scalar dates cross the Squirrel boundary.
--
-- The agreed rate (FR-F2). The day_rate is rate_card[level] AS OF
-- lower(contract.term) — the contract's signing date — NOT as-of the billing
-- month. If the rate card has been revised since the contract was signed, the
-- invoice still bills the older agreed rate. `agreed_date` is computed once from
-- the contract active over the month (project ⊂ contract, both overlapping the
-- month) and pinned for every line.
--
-- Day counting. A daterange's day count is upper - lower (integer days; PG returns
-- e.g. 30 for a June [1st, next-1st) range). The billable sub-period for a line is
-- the THREE-way intersection (the * operator) of the allocation, the engineer_role
-- (level) version, and the month — so a mid-month promotion splits the work into
-- one sub-period per level, each billed at that level's agreed rate. Empty
-- intersections (a role version that does not actually overlap the allocation
-- within the month) are dropped via NOT isempty.
--
--   days   = Σ over sub-periods of  fraction × (upper - lower)
--   amount = Σ over sub-periods of  fraction × (upper - lower) × day_rate
--
-- Aggregated per (engineer, level): a single allocation under one level yields one
-- row; a promotion mid-month yields two rows (one per level) for that engineer.
--
-- Assumptions:
--   * Exactly one contract is active over the month for the project (project ⊂
--     contract by construction); LIMIT 1 pins the agreed date if the schema ever
--     admits more.
--   * Leave does NOT reduce billing (billing is allocation-fraction-weighted
--     working days; leave is a payroll concern, paid in full — FR-F6).
--   * Calendar days, not business days: "working days in the month" is the day
--     width of the intersection, matching the day-count convention used elsewhere.
--   * rate_card has a version covering agreed_date for every billed level (true in
--     the seed: the baseline rate card opens at the earliest contract date).
WITH params AS (
  SELECT
    $1::int AS project_id,
    daterange($2::date, $3::date, '[)') AS month
),
agreed AS (
  -- the contract active over the month, and its agreed date = lower(term)
  SELECT lower(contract_terms.term) AS agreed_date
  FROM params
  JOIN project_run    ON project_run.project_id = params.project_id
                     AND project_run.active_during && params.month
  JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
                     AND contract_terms.term && params.month
  LIMIT 1
),
sub AS (
  -- each allocation ∩ engineer_role(level) ∩ month sub-period for the project
  SELECT
    allocation.engineer_id,
    engineer_role.level,
    allocation.fraction,
    allocation.allocated_during * engineer_role.held_during * params.month
      AS sub_period
  FROM params
  JOIN allocation    ON allocation.project_id = params.project_id
                    AND allocation.allocated_during && params.month
  JOIN engineer_role ON engineer_role.engineer_id = allocation.engineer_id
                    AND engineer_role.held_during && allocation.allocated_during
                    AND engineer_role.held_during && params.month
)
SELECT
  sub.engineer_id,
  coalesce(engineer.name, '') AS engineer,
  sub.level,
  rate_card.day_rate::numeric AS day_rate,
  sum(sub.fraction * (upper(sub.sub_period) - lower(sub.sub_period)))::numeric
    AS days,
  sum(sub.fraction * (upper(sub.sub_period) - lower(sub.sub_period))
      * rate_card.day_rate)::numeric AS amount
FROM sub
CROSS JOIN agreed
JOIN engineer_current engineer ON engineer.id = sub.engineer_id
JOIN rate_card ON rate_card.level = sub.level
              AND rate_card.effective_during @> agreed.agreed_date
WHERE NOT isempty(sub.sub_period)
GROUP BY sub.engineer_id, engineer.name, sub.level, rate_card.day_rate
ORDER BY engineer.name, sub.level;
