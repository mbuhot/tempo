-- skill_matrix.sql — one engineer's level in every skill in force as-of $2 (0 for
-- a skill never assessed), for the people-detail Skills tab. Driven from
-- skill_profile (not engineer_skill) so a retired skill drops out of the matrix
-- automatically, joined through as-of $2 like every other taxonomy read.
-- $1 = engineer_id, $2 = as_of date.
SELECT
  skill_profile.skill_id,
  skill_profile.name,
  coalesce(engineer_skill.level, 0) AS level
FROM skill_profile
LEFT JOIN engineer_skill
  ON engineer_skill.skill_id = skill_profile.skill_id
 AND engineer_skill.engineer_id = $1
 AND engineer_skill.assessed_during @> $2::date
WHERE skill_profile.defined_during @> $2::date
ORDER BY skill_profile.name;
