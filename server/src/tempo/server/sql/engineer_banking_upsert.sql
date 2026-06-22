-- engineer_banking_upsert.sql — record banking details from $2 onward in one
-- statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
-- sets the new values + audit_id on the [$2, NULL) portion of the covering version,
-- and PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id.
-- If no version covers $2 (the founding write) the Change touches nothing, so the
-- guarded INSERT opens the first [$2, NULL) span instead. $1 = engineer_id,
-- $2 = effective, $3 = bank, $4 = branch, $5 = account_no, $6 = account_name,
-- $7 = audit_id.
WITH changed AS (
  UPDATE engineer_banking
     FOR PORTION OF recorded_during FROM $2::date TO NULL
     SET bank = $3, branch = $4, account_no = $5, account_name = $6, audit_id = $7
   WHERE engineer_id = $1
     AND recorded_during @> $2::date
  RETURNING 1
)
INSERT INTO engineer_banking
  (engineer_id, bank, branch, account_no, account_name, recorded_during, audit_id)
SELECT $1, $3, $4, $5, $6, daterange($2::date, NULL, '[)'), $7
WHERE NOT EXISTS (SELECT 1 FROM changed);
