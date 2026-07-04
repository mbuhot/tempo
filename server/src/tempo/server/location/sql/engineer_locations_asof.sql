-- engineer_locations_asof.sql — the location in force on $1 for every engineer that has
-- one. Engineers without a location on that date are absent; the caller attaches them in
-- Gleam. Only NOT-NULL range bounds are selected (coalesced upper + upper_inf flag) so an
-- open-ended span decodes cleanly. $1 = as-of date.
SELECT
  engineer_id,
  country,
  region,
  timezone,
  lower(located_during) AS valid_from,
  coalesce(upper(located_during), lower(located_during)) AS valid_to,
  upper_inf(located_during) AS ongoing
FROM engineer_location
WHERE located_during @> $1::date;
