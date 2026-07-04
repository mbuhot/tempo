-- capability_rollup.sql — one engineer's weighted-average proficiency per
-- capability as-of $2, for the people-detail Skills tab's rollup aside.
-- proficiency = Σ(level × weight) / Σ(weight) over the capability's mapped
-- skills, with an unassessed skill counting as level 0. numeric division so
-- squirrel decodes proficiency via pog.numeric_decoder() (a Float on the read
-- side). $1 = engineer_id, $2 = as_of date.
SELECT
  capability_profile.capability_id,
  capability_profile.name,
  (sum(coalesce(engineer_skill.level, 0) * capability_skill.weight)::numeric
    / sum(capability_skill.weight)::numeric) AS proficiency
FROM capability_profile
JOIN capability_skill
  ON capability_skill.capability_id = capability_profile.capability_id
 AND capability_skill.mapped_during @> $2::date
LEFT JOIN engineer_skill
  ON engineer_skill.skill_id = capability_skill.skill_id
 AND engineer_skill.engineer_id = $1
 AND engineer_skill.assessed_during @> $2::date
WHERE capability_profile.defined_during @> $2::date
GROUP BY capability_profile.capability_id, capability_profile.name
ORDER BY capability_profile.name;
