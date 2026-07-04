-- engineer_roster.sql — every current engineer (id + name), for listing pages that
-- attach as-of data (e.g. location) in the application layer.
SELECT id AS engineer_id, name
FROM engineer_current
ORDER BY name;
