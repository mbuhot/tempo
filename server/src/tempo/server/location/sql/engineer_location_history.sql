-- engineer_location_history.sql — all location spans for one engineer, oldest first.
-- $1 = engineer_id.
SELECT
  engineer_location.country  AS country,
  engineer_location.region   AS region,
  engineer_location.timezone AS timezone,
  lower(engineer_location.located_during) AS valid_from,
  upper(engineer_location.located_during) AS valid_to
FROM engineer_location
WHERE engineer_location.engineer_id = $1
ORDER BY lower(engineer_location.located_during);
