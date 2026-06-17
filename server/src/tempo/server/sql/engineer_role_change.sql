-- engineer_role_change.sql — promote/change an engineer's level from a date onward.
--
-- Change pattern (one statement, no read). FOR PORTION OF intersects [effective,
-- ∞) with the role version in effect, so the new level lands on [effective,
-- row.upper) and PG re-inserts the [row.lower, effective) leftover at the old
-- level. The `held_during @> $3::date` filter confines the edit to the version
-- in effect at `effective`; a separately scheduled future version doesn't
-- contain `effective`, so WHERE excludes it and TO NULL cannot clobber it.
-- $1 = engineer_id, $2 = new level, $3 = effective date.
UPDATE engineer_role
   FOR PORTION OF held_during FROM $3::date TO NULL
   SET level = $2
 WHERE engineer_id = $1 AND held_during @> $3::date;
