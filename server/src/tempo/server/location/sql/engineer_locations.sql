-- engineer_locations.sql — every engineer and their location as-of $1, or NULLs when none
-- is set on that date. $1 = as-of date.
SELECT
  engineer_current.id   AS engineer_id,
  engineer_current.name AS name,
  loc.country           AS country,
  loc.region            AS region,
  loc.timezone          AS timezone,
  lower(loc.located_during) AS valid_from,
  upper(loc.located_during) AS valid_to
FROM engineer_current
LEFT JOIN engineer_location loc
  ON loc.engineer_id = engineer_current.id
 AND loc.located_during @> $1::date
ORDER BY engineer_current.name;
