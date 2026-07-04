-- engineer_location_history.sql — all location spans for one engineer, oldest first.
-- Coalesced upper + upper_inf flag keep an open-ended span's NULL upper bound from
-- decoding as a non-null Date. $1 = engineer_id.
SELECT
  country,
  region,
  timezone,
  lower(located_during) AS valid_from,
  coalesce(upper(located_during), lower(located_during)) AS valid_to,
  upper_inf(located_during) AS ongoing
FROM engineer_location
WHERE engineer_id = $1
ORDER BY lower(located_during);
