-- client_profile_close.sql — step 1 of the profile Change.
--
-- Close the client_profile row covering $2 by deleting its [$2, NULL) portion:
-- DELETE FOR PORTION OF intersects [$2, ∞) with the covering row, dropping that
-- sub-period and re-inserting the unchanged [row.lower, $2) remainder. The
-- companion client_profile_open then inserts the new full [$2, NULL) row, both in
-- ONE transaction (the WITHOUT OVERLAPS PK cannot be an ON CONFLICT target). First
-- edit deletes 0 rows (a harmless no-op); a re-record deletes the tail of the
-- prior row. $1 = client_id, $2 = effective date.
DELETE FROM client_profile
   FOR PORTION OF recorded_during FROM $2::date TO NULL
 WHERE client_id = $1;
