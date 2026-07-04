-- skill_catalog.sql — every skill + summary in force as-of $1, for the taxonomy
-- snapshot. $1 = as_of date.
SELECT skill_id AS id, name, summary
  FROM skill_profile
 WHERE defined_during @> $1::date
 ORDER BY name;
