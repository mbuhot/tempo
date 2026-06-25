-- engineer_banking_current.sql — an engineer's CURRENT banking (latest read).
--
-- The most-recently-effective engineer_banking row: DISTINCT ON ordered by the
-- start of recorded_during descending (append-only + WITHOUT OVERLAPS → greatest
-- start is in force). Scalar columns only. $1 = engineer_id.
SELECT DISTINCT ON (engineer_id)
  engineer_id,
  bank,
  branch,
  account_no,
  account_name
FROM engineer_banking
WHERE engineer_id = $1
ORDER BY engineer_id, lower(recorded_during) DESC;
