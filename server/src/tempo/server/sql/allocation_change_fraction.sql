-- allocation_change_fraction.sql — Change: re-fraction from a date onward.
--
-- Sets a new `fraction` from `$3` to the end of time. `WHERE … @> $3` matches only
-- the allocation version in effect at $3; `FOR PORTION OF allocated_during FROM $3
-- TO NULL` then intersects [$3, ∞) with that row's own period, so the change lands
-- on [$3, row.upper) and Postgres re-inserts the [row.lower, $3) leftover at the
-- old fraction. A separately scheduled future version doesn't contain $3, so the
-- @> filter excludes it and TO NULL cannot clobber it.
--
-- Boundaries are scalar `date` params cast in SQL. $1 = engineer_id,
-- $2 = project_id, $3 = effective day, $4 = new fraction.
UPDATE allocation
   FOR PORTION OF allocated_during FROM $3::date TO NULL
   SET fraction = $4
 WHERE engineer_id = $1 AND project_id = $2 AND allocated_during @> $3::date;
