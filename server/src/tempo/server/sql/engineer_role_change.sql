-- engineer_role_change.sql — promote/change an engineer's level from a date onward.
--
-- Change pattern (one statement, no read). FOR PORTION OF intersects [effective, ∞)
-- with the role version in effect, so the new level + audit_id land on [effective,
-- row.upper) and PG re-inserts the [row.lower, effective) leftover at the OLD level
-- AND its original audit_id (per-version provenance). The `@> $3` filter confines
-- the edit to the version in effect; a scheduled future version is untouched.
-- $1 = engineer_id, $2 = new level, $3 = effective, $4 = audit_id.
UPDATE engineer_role
   FOR PORTION OF held_during FROM $3::date TO NULL
   SET level = $2, audit_id = $4
 WHERE engineer_id = $1 AND held_during @> $3::date;
