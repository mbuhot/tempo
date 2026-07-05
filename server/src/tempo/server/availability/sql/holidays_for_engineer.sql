-- holidays_for_engineer.sql — next 10 holidays for the engineer's location as-of $2;
-- nationwide ('') and subdivision rows both match. $1 engineer_id, $2 as_of.
SELECT h.holiday_on AS holiday_on, h.name AS name
FROM engineer_location loc
JOIN holiday h ON h.country = loc.country AND h.region IN ('', loc.region)
WHERE loc.engineer_id = $1 AND loc.located_during @> $2::date
  AND h.holiday_on >= $2::date
ORDER BY h.holiday_on
LIMIT 10;
