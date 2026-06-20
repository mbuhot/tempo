-- engineer_banking_revise.sql — record new banking details from $2 onward (the
-- Change pattern). FOR PORTION OF sets the new values + audit_id on the [$2, NULL)
-- portion; PG carves off the unchanged [start, $2) remainder keeping its original
-- audit_id. $1 = engineer_id, $2 = effective, $3 = bank, $4 = branch,
-- $5 = account_no, $6 = account_name, $7 = audit_id.
UPDATE engineer_banking
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET bank = $3, branch = $4, account_no = $5, account_name = $6, audit_id = $7
 WHERE engineer_id = $1
   AND recorded_during @> $2::date;
