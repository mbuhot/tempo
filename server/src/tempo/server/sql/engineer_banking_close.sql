-- engineer_banking_close.sql — step 1 of the banking Change.
--
-- Close the engineer_banking row covering $2 by deleting its [$2, NULL) portion
-- (DELETE FOR PORTION OF; re-inserts the [row.lower, $2) remainder). Paired with
-- engineer_banking_open in ONE transaction — same delete-then-insert shape as the
-- contact/timesheet upsert. $1 = engineer_id, $2 = effective date.
DELETE FROM engineer_banking
   FOR PORTION OF recorded_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
