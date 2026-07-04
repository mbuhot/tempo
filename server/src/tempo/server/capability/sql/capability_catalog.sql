-- capability_catalog.sql — every capability + summary in force as-of $1, for the
-- taxonomy snapshot. $1 = as_of date.
SELECT capability_id AS id, name, summary
  FROM capability_profile
 WHERE defined_during @> $1::date
 ORDER BY name;
