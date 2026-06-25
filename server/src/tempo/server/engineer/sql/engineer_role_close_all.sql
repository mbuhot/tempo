-- engineer_role_close_all.sql — cap all of an engineer's roles from a date.
--
-- Close/cascade pattern. DELETE FOR PORTION OF intersects [$end, ∞) with each
-- role row: a row wholly after $end is dropped, a row straddling $end keeps its
-- [row.lower, $end) leftover. No @> filter — this is intentionally broad, ending
-- every role the engineer holds (part of terminating employment).
-- $1 = engineer_id, $2 = end date.
DELETE FROM engineer_role
   FOR PORTION OF held_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
