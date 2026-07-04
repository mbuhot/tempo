-- engineer_locations_asof.sql — the location in force on $1 for every engineer that has
-- one, plus that timezone's UTC offset (minutes east of UTC) computed AT the as-of date so
-- it tracks DST. Engineers without a location on that date are absent; the caller attaches
-- them in Gleam. Only NOT-NULL range bounds are selected (coalesced upper + upper_inf flag)
-- so an open-ended span decodes cleanly. $1 = as-of date.
SELECT
  engineer_id,
  country,
  region,
  timezone,
  lower(located_during) AS valid_from,
  coalesce(upper(located_during), lower(located_during)) AS valid_to,
  upper_inf(located_during) AS ongoing,
  (extract(epoch from
     (($1::date::timestamp AT TIME ZONE 'UTC')
      - ($1::date::timestamp AT TIME ZONE timezone))) / 60)::int AS utc_offset_minutes
FROM engineer_location
WHERE located_during @> $1::date;
