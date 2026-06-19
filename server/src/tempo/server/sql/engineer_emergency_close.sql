-- engineer_emergency_close.sql — step 1 of the emergency Change.
--
-- Close the engineer_emergency row covering $2 by deleting its [$2, NULL) portion
-- (DELETE FOR PORTION OF; re-inserts the [row.lower, $2) remainder). Paired with
-- engineer_emergency_open in ONE transaction. $1 = engineer_id, $2 = effective.
DELETE FROM engineer_emergency
   FOR PORTION OF recorded_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
