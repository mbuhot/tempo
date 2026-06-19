-- engineer_emergency_current.sql — an engineer's CURRENT emergency contact
-- (latest read).
--
-- The most-recently-effective engineer_emergency row: DISTINCT ON ordered by the
-- start of recorded_during descending. Scalar columns only. $1 = engineer_id.
SELECT DISTINCT ON (engineer_id)
  engineer_id,
  relation,
  name,
  phone,
  email
FROM engineer_emergency
WHERE engineer_id = $1
ORDER BY engineer_id, lower(recorded_during) DESC;
