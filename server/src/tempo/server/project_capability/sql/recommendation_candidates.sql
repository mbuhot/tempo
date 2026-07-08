-- recommendation_candidates.sql — for one project's required capabilities as-of
-- $2, every candidate engineer NOT currently on the project, with their rolled-up
-- proficiency in that capability and their free fraction across all allocations
-- (the assignment recommender, #40 Phase 3). Params: $1 = project_id, $2 = as-of
-- date.
--
-- The candidate pool (qualifier CTE, rooted at employment like
-- schedule_candidates.sql) is every engineer employed as-of $2 who is NOT on
-- leave as-of $2 (NOT EXISTS, the house leave-suppression pattern) and NOT
-- allocated to $1 as-of $2 (NOT EXISTS). One row per (required capability × pool
-- candidate), built by CROSS JOINing the pool against the project's required
-- capabilities so a candidate with zero fit still lists (the view filters).
-- Proficiency is the Phase 1 capability_rollup weighted average (same LATERAL
-- shape as capability_coverage.sql, coalesced to 0 when nothing is mapped or
-- assessed). Free is `greatest(0, 1 - sum(fraction))` over ALL of the
-- candidate's allocations as-of $2 (not just this project), coalescing an
-- unallocated candidate to fully free (1.0). Ranking (the capped-fit tie-break,
-- ready-now vs growth split) happens in Gleam, so the ORDER BY here is only for
-- a stable read.
WITH qualifier AS (
  SELECT employment.engineer_id,
         coalesce(engineer_current.name, '') AS name,
         engineer_role.level
  FROM employment
  JOIN engineer_role
    ON engineer_role.engineer_id = employment.engineer_id
   AND engineer_role.held_during @> $2::date
  JOIN engineer_current ON engineer_current.id = employment.engineer_id
  WHERE employment.employed_during @> $2::date
    AND NOT EXISTS (
      SELECT 1 FROM leave
       WHERE leave.engineer_id = employment.engineer_id
         AND leave.on_leave_during @> $2::date
    )
    AND NOT EXISTS (
      SELECT 1 FROM allocation
       WHERE allocation.engineer_id = employment.engineer_id
         AND allocation.project_id = $1
         AND allocation.allocated_during @> $2::date
    )
),
required_capability AS (
  SELECT DISTINCT project_capability.capability_id
  FROM project_capability
  WHERE project_capability.project_id = $1
    AND project_capability.required_during @> $2::date
)
SELECT
  required_capability.capability_id,
  qualifier.engineer_id,
  qualifier.name,
  qualifier.level,
  coalesce(rollup.proficiency, 0::numeric) AS proficiency,
  greatest(0::numeric, 1::numeric - coalesce(load.total, 0::numeric)) AS free
FROM required_capability
CROSS JOIN qualifier
LEFT JOIN LATERAL (
  SELECT
    (sum(coalesce(engineer_skill.level, 0) * capability_skill.weight)::numeric
      / sum(capability_skill.weight)::numeric) AS proficiency
  FROM capability_skill
  LEFT JOIN engineer_skill
    ON engineer_skill.skill_id = capability_skill.skill_id
   AND engineer_skill.engineer_id = qualifier.engineer_id
   AND engineer_skill.assessed_during @> $2::date
  WHERE capability_skill.capability_id = required_capability.capability_id
    AND capability_skill.mapped_during @> $2::date
) rollup ON true
LEFT JOIN LATERAL (
  SELECT sum(allocation.fraction) AS total
  FROM allocation
  WHERE allocation.engineer_id = qualifier.engineer_id
    AND allocation.allocated_during @> $2::date
) load ON true
ORDER BY required_capability.capability_id, qualifier.engineer_id;
