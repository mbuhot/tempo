-- engineer_location_upsert.sql — set an engineer's location from $2 onward. The temporal
-- DELETE clips the row covering $2 to [start, $2) and removes rows starting at/after $2,
-- then inserts [$2, NULL) with the new values, superseding scheduled future versions.
-- $1 engineer_id, $2 effective, $3 country, $4 region (nullable), $5 timezone, $6 audit_id.
WITH deleted AS (
  DELETE FROM engineer_location
     FOR PORTION OF located_during FROM $2::date TO NULL
   WHERE engineer_id = $1
)
INSERT INTO engineer_location
  (engineer_id, located_during, country, region, timezone, audit_id)
VALUES ($1, daterange($2::date, NULL, '[)'), $3, $4, $5, $6);
