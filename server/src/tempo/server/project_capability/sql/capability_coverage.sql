-- capability_coverage.sql — for one project's required capabilities as-of $2, every
-- allocated engineer with their rolled-up proficiency in that capability, for the
-- project-detail Capability coverage tab (FR-CP §2). Params: $1 = project_id,
-- $2 = as-of date.
--
-- One row per (required capability × engineer allocated to the project as-of
-- $2), built by joining the allocated team to the project's required
-- capabilities FIRST, then LEFT JOINing the rollup — so a capability with no
-- capability_skill rows mapped as-of $2 still lists every allocated engineer
-- rather than vanishing. Proficiency is the Phase 1 capability_rollup
-- weighted-average (Σ(level × weight) / Σ(weight) over the capability's mapped
-- skills, scoped to the one engineer) computed in a LATERAL subquery so it
-- never collapses the outer row; a NULL rollup (no mapped skills, or no
-- assessment against any of them) coalesces to 0, numeric so squirrel decodes
-- it via pog.numeric_decoder() (a Float on the read side). An engineer covered
-- by a leave fact on $2 is excluded (NOT EXISTS), matching the project-detail
-- team card and the board: on leave means not working the project on the
-- date. All temporal joins as-of $2. Ordered by capability then proficiency
-- descending, so the strongest covering engineers list first.
SELECT
  project_capability.capability_id,
  engineer.id AS engineer_id,
  coalesce(engineer_current.name, '') AS name,
  allocation.fraction::numeric AS fraction,
  coalesce(rollup.proficiency, 0::numeric) AS proficiency
FROM project_capability
JOIN allocation
  ON allocation.project_id = project_capability.project_id
 AND allocation.allocated_during @> $2::date
JOIN employment
  ON employment.engineer_id = allocation.engineer_id
 AND employment.employed_during @> $2::date
JOIN engineer ON engineer.id = allocation.engineer_id
JOIN engineer_current ON engineer_current.id = engineer.id
LEFT JOIN LATERAL (
  SELECT
    (sum(coalesce(engineer_skill.level, 0) * capability_skill.weight)::numeric
      / sum(capability_skill.weight)::numeric) AS proficiency
  FROM capability_skill
  LEFT JOIN engineer_skill
    ON engineer_skill.skill_id = capability_skill.skill_id
   AND engineer_skill.engineer_id = engineer.id
   AND engineer_skill.assessed_during @> $2::date
  WHERE capability_skill.capability_id = project_capability.capability_id
    AND capability_skill.mapped_during @> $2::date
) rollup ON true
WHERE project_capability.project_id = $1
  AND project_capability.required_during @> $2::date
  AND NOT EXISTS (
    SELECT 1 FROM leave
     WHERE leave.engineer_id = engineer.id
       AND leave.on_leave_during @> $2::date
  )
ORDER BY project_capability.capability_id, proficiency DESC;
