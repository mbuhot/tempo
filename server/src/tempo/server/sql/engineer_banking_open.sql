-- engineer_banking_open.sql — step 2 of the banking Change.
--
-- Insert the new full banking row over [$6, NULL). account_no is text (leading
-- zeros preserved). Only scalar params cross the boundary; the range is built in
-- SQL. $1 = engineer_id, $2 = bank, $3 = branch, $4 = account_no,
-- $5 = account_name, $6 = effective date.
INSERT INTO engineer_banking
  (engineer_id, bank, branch, account_no, account_name, recorded_during)
VALUES ($1, $2, $3, $4, $5, daterange($6::date, NULL, '[)'));
