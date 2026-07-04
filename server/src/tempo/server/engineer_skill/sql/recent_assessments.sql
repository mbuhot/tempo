-- recent_assessments.sql — one engineer's full skill-assessment timeline for the
-- people-detail Skills tab's history panel. Param: $1 = engineer_id.
--
-- Decomposed to plain dates at the boundary: skill id, skill name, level, lower(assessed_
-- during) AS valid_from. A current assessment is OPEN ([start, employment's end)
-- for an active engineer), so upper(assessed_during) can be NULL only if
-- employment itself is open — `ongoing` reports whether this version still
-- holds, and `valid_to` coalesces to the start so the column stays a non-null
-- date the boundary can decode (the server maps ongoing -> None). Most recent
-- first.
SELECT
  engineer_skill.skill_id,
  skill_profile.name,
  engineer_skill.level,
  lower(engineer_skill.assessed_during) AS valid_from,
  coalesce(upper(engineer_skill.assessed_during), lower(engineer_skill.assessed_during))
    AS valid_to,
  upper_inf(engineer_skill.assessed_during) AS ongoing
FROM engineer_skill
JOIN skill_profile
  ON skill_profile.skill_id = engineer_skill.skill_id
 AND skill_profile.defined_during @> lower(engineer_skill.assessed_during)
WHERE engineer_skill.engineer_id = $1
ORDER BY lower(engineer_skill.assessed_during) DESC;
