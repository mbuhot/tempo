-- engineer_banking_open.sql — open an engineer's banking details. Last param is the
-- audit_id. $1 = engineer_id, $2 = bank, $3 = branch, $4 = account_no,
-- $5 = account_name, $6 = from.
INSERT INTO engineer_banking
  (engineer_id, bank, branch, account_no, account_name, recorded_during, audit_id)
VALUES ($1, $2, $3, $4, $5, daterange($6::date, NULL, '[)'), $7);
