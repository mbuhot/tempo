-- capability_coverage.sql — for one project's required capabilities as-of $2, every
-- allocated engineer with their rolled-up proficiency in that capability, for the
-- project-detail Capability coverage tab (FR-CP §2, P2-D3). Params: $1 =
-- project_id, $2 = as-of date.
--
-- One row per (required capability × engineer allocated to the project as-of
-- $2). Proficiency reuses the Phase 1 capability_rollup weighted-average join
-- (Σ(level × weight) / Σ(weight) over the capability's mapped skills, scoped to
-- the one engineer), numeric division so squirrel decodes it via
-- pog.numeric_decoder() (a Float on the read side). An engineer with no
-- assessment against any of the capability's skills still appears, at
-- proficiency 0 (LEFT JOIN engineer_skill + coalesce). All temporal joins as-of
-- $2. Ordered by capability then proficiency descending, so the strongest
-- covering engineers list first.
SELECT
  project_capability.capability_id,
  engineer.id AS engineer_id,
  coalesce(engineer_current.name, '') AS name,
  allocation.fraction::numeric AS fraction,
  (sum(coalesce(engineer_skill.level, 0) * capability_skill.weight)::numeric
    / sum(capability_skill.weight)::numeric) AS proficiency
FROM project_capability
JOIN capability_skill
  ON capability_skill.capability_id = project_capability.capability_id
 AND capability_skill.mapped_during @> $2::date
JOIN allocation
  ON allocation.project_id = project_capability.project_id
 AND allocation.allocated_during @> $2::date
JOIN employment
  ON employment.engineer_id = allocation.engineer_id
 AND employment.employed_during @> $2::date
JOIN engineer ON engineer.id = allocation.engineer_id
JOIN engineer_current ON engineer_current.id = engineer.id
LEFT JOIN engineer_skill
  ON engineer_skill.skill_id = capability_skill.skill_id
 AND engineer_skill.engineer_id = engineer.id
 AND engineer_skill.assessed_during @> $2::date
WHERE project_capability.project_id = $1
  AND project_capability.required_during @> $2::date
GROUP BY project_capability.capability_id, engineer.id, engineer_current.name, allocation.fraction
ORDER BY project_capability.capability_id, proficiency DESC;
