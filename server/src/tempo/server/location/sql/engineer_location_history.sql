-- engineer_location_history.sql — all location spans for one engineer, oldest first, each
-- with the timezone's UTC offset (minutes east of UTC) as-of $2 so the covering span's
-- offset tracks DST on the viewing date. Coalesced upper + upper_inf flag keep an
-- open-ended span's NULL upper bound from decoding as a non-null Date.
-- $1 = engineer_id, $2 = as-of date.
SELECT
  country,
  region,
  timezone,
  lower(located_during) AS valid_from,
  coalesce(upper(located_during), lower(located_during)) AS valid_to,
  upper_inf(located_during) AS ongoing,
  (extract(epoch from
     (($2::date::timestamp AT TIME ZONE 'UTC')
      - ($2::date::timestamp AT TIME ZONE timezone))) / 60)::int AS utc_offset_minutes
FROM engineer_location
WHERE engineer_id = $1
ORDER BY lower(located_during);
