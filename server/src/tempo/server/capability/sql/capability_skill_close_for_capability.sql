-- capability_skill_close_for_capability.sql — cap all of a capability's skill
-- mappings from a date (retire cascade, part of RetireCapability).
--
-- Close/cascade pattern, mirroring engineer_role_close_all: DELETE FOR PORTION OF
-- intersects [$end, ∞) with each mapping row: a row wholly after $end is dropped,
-- a row straddling $end keeps its [row.lower, $end) leftover. No @> filter — this
-- is intentionally broad, ending every skill mapped to the capability.
-- $1 = capability_id, $2 = end date.
DELETE FROM capability_skill
   FOR PORTION OF mapped_during FROM $2::date TO NULL
 WHERE capability_id = $1;
