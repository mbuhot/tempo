-- engineer_contact_close.sql — step 1 of the contact Change.
--
-- Close the engineer_contact row covering $2 by deleting its [$2, NULL) portion:
-- DELETE FOR PORTION OF intersects [$2, ∞) with the covering row, dropping that
-- sub-period and re-inserting the unchanged [row.lower, $2) remainder. The
-- companion engineer_contact_open then inserts the new full [$2, NULL) row, both
-- in ONE transaction (mirrors the timesheet delete-then-insert: the WITHOUT
-- OVERLAPS PK cannot be an ON CONFLICT target). First edit deletes 0 rows (a
-- harmless no-op when seeding from onboarding); a re-record deletes the tail of
-- the prior row. $1 = engineer_id, $2 = effective date.
DELETE FROM engineer_contact
   FOR PORTION OF recorded_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
