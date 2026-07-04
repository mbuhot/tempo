-- engineer_skill_close_all.sql — cap all of an engineer's skill assessments from
-- a date (termination cascade, part of record_departure).
--
-- Close/cascade pattern, mirroring engineer_role_close_all: DELETE FOR PORTION OF
-- intersects [$end, ∞) with each assessment row: a row wholly after $end is
-- dropped, a row straddling $end keeps its [row.lower, $end) leftover. No @>
-- filter — this is intentionally broad, ending every skill the engineer holds.
-- $1 = engineer_id, $2 = end date.
DELETE FROM engineer_skill
   FOR PORTION OF assessed_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
