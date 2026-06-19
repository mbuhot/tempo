-- engineer_banking_revise.sql — record new banking details from $2 onward in ONE
-- statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
-- values on the [$2, NULL) portion of the row covering $2; PG carves off the
-- unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
-- $1 = engineer_id, $2 = effective, $3 = bank, $4 = branch, $5 = account_no,
-- $6 = account_name.
UPDATE engineer_banking
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET bank = $3, branch = $4, account_no = $5, account_name = $6
 WHERE engineer_id = $1
   AND recorded_during @> $2::date;
