-- engineer_banking_upsert.sql — record banking details from $2 onward (delete-then-insert
-- semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
-- rows that start at or after $2, then inserts [$2, NULL) with the new values. Passing NULL
-- as the upper bound asserts the new details hold to infinity, superseding any scheduled
-- future versions. $1 = engineer_id, $2 = effective, $3 = bank, $4 = branch,
-- $5 = account_no, $6 = account_name, $7 = audit_id.
WITH deleted AS (
  DELETE FROM engineer_banking
     FOR PORTION OF recorded_during FROM $2::date TO NULL
   WHERE engineer_id = $1
)
INSERT INTO engineer_banking
  (engineer_id, bank, branch, account_no, account_name, recorded_during, audit_id)
VALUES ($1, $3, $4, $5, $6, daterange($2::date, NULL, '[)'), $7);
