-- recommendation_pairings.sql — for one project's required capabilities as-of
-- $2, every qualifying growth pairing: a candidate learner below the target
-- (level 1 or 2 on one of the capability's weight >= 2 skills) matched to an
-- on-team level-4 teacher on that same skill (the assignment recommender, #40
-- Phase 3). Params: $1 = project_id, $2 = as-of date.
--
-- Learner pool (same shape as recommendation_candidates.sql's qualifier): every
-- engineer employed as-of $2, not on leave as-of $2, not already allocated to
-- $1 as-of $2. Team pool: every engineer allocated to $1 as-of $2, employed as-of
-- $2, not on leave as-of $2 — the "current team" a learner could shadow. A
-- pairing row exists only where a learner's level 1/2 skill (weight >= 2 within
-- the required capability, as-of $2) is matched by a team member's level-4
-- assessment on that exact skill as-of $2 — so every returned row already has a
-- real teacher; picking ONE pairing per learner (highest weight, then skill
-- name, then teacher name) happens in Gleam.
WITH learner AS (
  SELECT employment.engineer_id, coalesce(engineer_current.name, '') AS name
  FROM employment
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
team AS (
  SELECT allocation.engineer_id, coalesce(engineer_current.name, '') AS name
  FROM allocation
  JOIN employment
    ON employment.engineer_id = allocation.engineer_id
   AND employment.employed_during @> $2::date
  JOIN engineer_current ON engineer_current.id = allocation.engineer_id
  WHERE allocation.project_id = $1
    AND allocation.allocated_during @> $2::date
    AND NOT EXISTS (
      SELECT 1 FROM leave
       WHERE leave.engineer_id = allocation.engineer_id
         AND leave.on_leave_during @> $2::date
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
  learner.engineer_id AS learner_id,
  capability_skill.skill_id,
  skill_profile.name AS skill_name,
  capability_skill.weight,
  team.engineer_id AS teacher_id,
  team.name AS teacher_name
FROM required_capability
JOIN capability_skill
  ON capability_skill.capability_id = required_capability.capability_id
 AND capability_skill.mapped_during @> $2::date
 AND capability_skill.weight >= 2
JOIN skill_profile
  ON skill_profile.skill_id = capability_skill.skill_id
 AND skill_profile.defined_during @> $2::date
JOIN learner ON true
JOIN engineer_skill AS learner_skill
  ON learner_skill.engineer_id = learner.engineer_id
 AND learner_skill.skill_id = capability_skill.skill_id
 AND learner_skill.assessed_during @> $2::date
 AND learner_skill.level IN (1, 2)
JOIN engineer_skill AS teacher_skill
  ON teacher_skill.skill_id = capability_skill.skill_id
 AND teacher_skill.assessed_during @> $2::date
 AND teacher_skill.level = 4
JOIN team ON team.engineer_id = teacher_skill.engineer_id
ORDER BY required_capability.capability_id, learner.engineer_id,
         capability_skill.weight DESC, skill_profile.name, team.name;
