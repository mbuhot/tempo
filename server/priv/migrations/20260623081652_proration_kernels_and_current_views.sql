-- 20260623081652_proration_kernels_and_current_views.sql — de-duplicate the
-- proration/recognition business rules into shared SQL functions, and de-fragilize
-- the `*_current` views' row selection (#9).
--
-- Both halves are behaviour-preserving: the financial numbers are byte-identical
-- before and after. This file is additive (expand step) — it adds functions and
-- CREATE OR REPLACEs the three views; it never edits the 001 baseline.

-- Proration / recognition kernels ---------------------------------------------
-- The day-count, salary-proration, and revenue-recognition arithmetic was repeated
-- VERBATIM across pnl_rows.sql, forecast.sql, payroll_amounts.sql and
-- payroll_reconciliation.sql — the highest business-rule drift risk in the codebase.
-- Centralise the rules here once, the same way year_fraction / accrued_leave already
-- live in 001_schema.sql and are called from the leave queries. IMMUTABLE: the result
-- depends only on the arguments, so the planner may fold them.
--
-- A daterange's day count is upper - lower (integer days; e.g. 30 for June). The
-- capacity multiplier (an allocation's fraction, a requirement's quantity) is NOT
-- folded in: it differs by source between the readers, so each caller still applies
-- its own fraction/quantity to these per-unit kernels.

-- range_days(r): a daterange's calendar-day count, upper(r) - lower(r), as numeric
-- (so downstream multiply/divide stays exact numeric arithmetic). An empty range is 0.
CREATE FUNCTION range_days(r daterange) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN isempty(r) THEN 0 ELSE (upper(r) - lower(r))::numeric END;
$$;

-- prorated_salary(monthly_salary, sub_period, month): the salary recognised for a
-- sub-period of a month — monthly_salary × days_in_subperiod / days_in_month. The
-- divisor is the month's own calendar length (28..31), so a part-month employment,
-- a mid-month promotion split, or a mid-month salary revision is day-accurate. This
-- is payroll_amounts' core proration; pnl_rows' estimated_cost and forecast's cost
-- reuse it (forecast scales the result by the demand quantity).
CREATE FUNCTION prorated_salary(monthly_salary numeric, sub_period daterange, month daterange)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT monthly_salary * range_days(sub_period) / range_days(month);
$$;

-- recognized_revenue(day_rate, sub_period): the billable value of ONE capacity unit
-- over a sub-period — day_rate × days_in_subperiod (ACCRUAL, capacity-based). pnl_rows'
-- rev and forecast's revenue both scale this by their capacity multiplier (an
-- allocation's fraction / a requirement's quantity).
CREATE FUNCTION recognized_revenue(day_rate numeric, sub_period daterange)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT day_rate * range_days(sub_period);
$$;

-- `*_current` views: select the open-ended row, not the max-recorded-start row -----
-- These latest-read views previously did DISTINCT ON (anchor) ORDER BY
-- lower(recorded_during) DESC — picking the version with the greatest recorded START.
-- That encoded an UNDOCUMENTED write invariant: it is correct only because every
-- write opens a [effective, NULL) span and FOR-PORTION-OF re-closes the prior open
-- span, so the greatest-start row happens to be the open-ended one. Row ordering was
-- load-bearing.
--
-- Select the OPEN-ENDED row directly instead — the version whose recorded_during has
-- no upper bound (upper_inf), i.e. the one in force as of "now". The WITHOUT OVERLAPS
-- primary key guarantees at most one open-ended span per anchor, so no DISTINCT ON /
-- ORDER BY is needed and the result no longer depends on insertion ordering. The
-- selection rule is: the current row is the one still open in transaction time.
CREATE OR REPLACE VIEW client_current AS
  SELECT client_id AS id, name
    FROM client_profile WHERE upper_inf(recorded_during);

CREATE OR REPLACE VIEW engineer_current AS
  SELECT engineer_id AS id, name, email, phone, postal_address
    FROM engineer_contact WHERE upper_inf(recorded_during);

CREATE OR REPLACE VIEW project_current AS
  SELECT project_id AS id, title, summary
    FROM project_profile WHERE upper_inf(recorded_during);
