-- engineer_contact_current.sql — an engineer's CURRENT contact (latest read).
--
-- The most-recently-effective engineer_contact row for one engineer: DISTINCT ON
-- ordered by the start of recorded_during descending. Append-only + WITHOUT
-- OVERLAPS means the row with the greatest start is the one whose [effective,
-- NULL) span is in force. Scalar columns only — recorded_during bounds are not
-- exposed (the read record is scalar-only). $1 = engineer_id.
SELECT DISTINCT ON (engineer_id)
  engineer_id,
  name,
  email,
  phone,
  postal_address
FROM engineer_contact
WHERE engineer_id = $1
ORDER BY engineer_id, lower(recorded_during) DESC;
