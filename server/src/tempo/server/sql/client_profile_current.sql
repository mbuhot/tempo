-- client_profile_current.sql — a client's CURRENT profile (latest read).
--
-- The most-recently-effective client_profile row for one client: DISTINCT ON
-- ordered by the start of recorded_during descending. Append-only + WITHOUT
-- OVERLAPS means the row with the greatest start is the one whose [effective,
-- NULL) span is in force. Scalar columns only — recorded_during bounds are not
-- exposed (the read record is scalar-only). $1 = client_id.
SELECT DISTINCT ON (client_id)
  client_id,
  name
FROM client_profile
WHERE client_id = $1
ORDER BY client_id, lower(recorded_during) DESC;
