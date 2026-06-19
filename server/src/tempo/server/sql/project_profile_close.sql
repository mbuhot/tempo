-- project_profile_close.sql — step 1 of the profile Change.
--
-- Close the project_profile row covering $2 by deleting its [$2, NULL) portion:
-- DELETE FOR PORTION OF intersects [$2, ∞) with the covering row, dropping that
-- sub-period and re-inserting the unchanged [row.lower, $2) remainder. The
-- companion project_profile_open then inserts the new full [$2, NULL) row, both in
-- ONE transaction (the WITHOUT OVERLAPS PK cannot be an ON CONFLICT target). First
-- edit deletes 0 rows (a harmless no-op when seeding from StartProject); a
-- re-record deletes the tail of the prior row. $1 = project_id, $2 = effective date.
DELETE FROM project_profile
   FOR PORTION OF recorded_during FROM $2::date TO NULL
 WHERE project_id = $1;
