//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/project_capability/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `capability_coverage` query
/// defined in `./src/tempo/server/project_capability/sql/capability_coverage.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type CapabilityCoverageRow {
  CapabilityCoverageRow(
    capability_id: Int,
    engineer_id: Int,
    name: String,
    fraction: Float,
    proficiency: Float,
  )
}

/// capability_coverage.sql — for one project's required capabilities as-of $2, every
/// allocated engineer with their rolled-up proficiency in that capability, for the
/// project-detail Capability coverage tab (FR-CP §2). Params: $1 = project_id,
/// $2 = as-of date.
///
/// One row per (required capability × engineer allocated to the project as-of
/// $2), built by joining the allocated team to the project's required
/// capabilities FIRST, then LEFT JOINing the rollup — so a capability with no
/// capability_skill rows mapped as-of $2 still lists every allocated engineer
/// rather than vanishing. Proficiency is the Phase 1 capability_rollup
/// weighted-average (Σ(level × weight) / Σ(weight) over the capability's mapped
/// skills, scoped to the one engineer) computed in a LATERAL subquery so it
/// never collapses the outer row; a NULL rollup (no mapped skills, or no
/// assessment against any of them) coalesces to 0, numeric so squirrel decodes
/// it via pog.numeric_decoder() (a Float on the read side). An engineer covered
/// by a leave fact on $2 is excluded (NOT EXISTS), matching the project-detail
/// team card and the board: on leave means not working the project on the
/// date. All temporal joins as-of $2. Ordered by capability then proficiency
/// descending, so the strongest covering engineers list first.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn capability_coverage(
  db: pog.Connection,
  project_capability_project_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(CapabilityCoverageRow), pog.QueryError) {
  let decoder = {
    use capability_id <- decode.field(0, decode.int)
    use engineer_id <- decode.field(1, decode.int)
    use name <- decode.field(2, decode.string)
    use fraction <- decode.field(3, pog.numeric_decoder())
    use proficiency <- decode.field(4, pog.numeric_decoder())
    decode.success(CapabilityCoverageRow(
      capability_id:,
      engineer_id:,
      name:,
      fraction:,
      proficiency:,
    ))
  }

  "-- capability_coverage.sql — for one project's required capabilities as-of $2, every
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
"
  |> pog.query
  |> pog.parameter(pog.int(project_capability_project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_capabilities` query
/// defined in `./src/tempo/server/project_capability/sql/project_capabilities.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectCapabilitiesRow {
  ProjectCapabilitiesRow(
    capability_id: Int,
    name: String,
    target_level: Int,
    quantity: Float,
    valid_from: Date,
    valid_to: Date,
    ongoing: Bool,
  )
}

/// project_capabilities.sql — one project's capability-requirement lines (demand)
/// as-of $2, for the project-detail Capability coverage tab. Params: $1 =
/// project_id, $2 = as-of date.
///
/// Joined through capability_profile as-of $2 for the capability's display name.
/// Range column decomposed via the lower/coalesce(upper)/upper_inf trio: a
/// requirement can be open-ended ([start, ∞)), so upper(required_during) is NULL —
/// valid_to coalesces to valid_from so the column stays a non-null date the
/// boundary can decode, and `ongoing` reports the open-endedness. Ordered by
/// capability name for a stable list.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_capabilities(
  db: pog.Connection,
  project_capability_project_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(ProjectCapabilitiesRow), pog.QueryError) {
  let decoder = {
    use capability_id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use target_level <- decode.field(2, decode.int)
    use quantity <- decode.field(3, pog.numeric_decoder())
    use valid_from <- decode.field(4, pog.calendar_date_decoder())
    use valid_to <- decode.field(5, pog.calendar_date_decoder())
    use ongoing <- decode.field(6, decode.bool)
    decode.success(ProjectCapabilitiesRow(
      capability_id:,
      name:,
      target_level:,
      quantity:,
      valid_from:,
      valid_to:,
      ongoing:,
    ))
  }

  "-- project_capabilities.sql — one project's capability-requirement lines (demand)
-- as-of $2, for the project-detail Capability coverage tab. Params: $1 =
-- project_id, $2 = as-of date.
--
-- Joined through capability_profile as-of $2 for the capability's display name.
-- Range column decomposed via the lower/coalesce(upper)/upper_inf trio: a
-- requirement can be open-ended ([start, ∞)), so upper(required_during) is NULL —
-- valid_to coalesces to valid_from so the column stays a non-null date the
-- boundary can decode, and `ongoing` reports the open-endedness. Ordered by
-- capability name for a stable list.
SELECT
  project_capability.capability_id,
  capability_profile.name,
  project_capability.target_level,
  project_capability.quantity,
  lower(project_capability.required_during) AS valid_from,
  coalesce(upper(project_capability.required_during), lower(project_capability.required_during))
    AS valid_to,
  upper_inf(project_capability.required_during) AS ongoing
FROM project_capability
JOIN capability_profile
  ON capability_profile.capability_id = project_capability.capability_id
 AND capability_profile.defined_during @> $2::date
WHERE project_capability.project_id = $1
  AND project_capability.required_during @> $2::date
ORDER BY capability_profile.name;
"
  |> pog.query
  |> pog.parameter(pog.int(project_capability_project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_capability_clear.sql — step 1 of the FOR-PORTION-OF set. DELETE FOR
/// PORTION OF carves the target window [$2, $3) out of whatever (project, capability)
/// rows cover any part of it, re-inserting the before/after remainders at their
/// original target_level/quantity (keeping their original audit_id). Step 2
/// (project_capability_set.sql) then inserts the new line over the now-vacant
/// window.
///
/// `ON CONFLICT` cannot target the WITHOUT OVERLAPS PK (a GiST exclusion constraint),
/// so the set is delete-then-insert run in ONE transaction by the handler. A first
/// set over a vacant window deletes 0 rows (a harmless no-op); never branch on the
/// affected-row count. $1 = project_id, $2 = from, $3 = to, $4 = capability_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_capability_clear(
  db: pog.Connection,
  project_id: Int,
  arg_2: Date,
  arg_3: Date,
  arg_4: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_capability_clear.sql — step 1 of the FOR-PORTION-OF set. DELETE FOR
-- PORTION OF carves the target window [$2, $3) out of whatever (project, capability)
-- rows cover any part of it, re-inserting the before/after remainders at their
-- original target_level/quantity (keeping their original audit_id). Step 2
-- (project_capability_set.sql) then inserts the new line over the now-vacant
-- window.
--
-- `ON CONFLICT` cannot target the WITHOUT OVERLAPS PK (a GiST exclusion constraint),
-- so the set is delete-then-insert run in ONE transaction by the handler. A first
-- set over a vacant window deletes 0 rows (a harmless no-op); never branch on the
-- affected-row count. $1 = project_id, $2 = from, $3 = to, $4 = capability_id.
DELETE FROM project_capability
   FOR PORTION OF required_during FROM $2::date TO $3::date
 WHERE project_id = $1 AND capability_id = $4;
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_capability_set.sql — step 2 of the FOR-PORTION-OF set: insert the demand
/// line over the window [$2, $3) that project_capability_clear.sql just vacated. The
/// PERIOD-FK `project_capability_within_run` rejects (→ ContainmentViolated) a window
/// not wholly contained by the project's run; the target_level/quantity CHECKs reject
/// out-of-range values (→ InvalidValue). $1 = project_id, $2 = from, $3 = to,
/// $4 = capability_id, $5 = target_level, $6 = quantity, $7 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_capability_set(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
  arg_3: Date,
  arg_4: Int,
  arg_5: Int,
  arg_6: Float,
  arg_7: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_capability_set.sql — step 2 of the FOR-PORTION-OF set: insert the demand
-- line over the window [$2, $3) that project_capability_clear.sql just vacated. The
-- PERIOD-FK `project_capability_within_run` rejects (→ ContainmentViolated) a window
-- not wholly contained by the project's run; the target_level/quantity CHECKs reject
-- out-of-range values (→ InvalidValue). $1 = project_id, $2 = from, $3 = to,
-- $4 = capability_id, $5 = target_level, $6 = quantity, $7 = audit_id.
INSERT INTO project_capability
  (project_id, capability_id, target_level, quantity, required_during, audit_id)
VALUES
  ($1, $4, $5, $6, daterange($2::date, $3::date, '[)'), $7);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.parameter(pog.float(arg_6))
  |> pog.parameter(pog.int(arg_7))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `recommendation_candidates` query
/// defined in `./src/tempo/server/project_capability/sql/recommendation_candidates.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RecommendationCandidatesRow {
  RecommendationCandidatesRow(
    capability_id: Int,
    engineer_id: Int,
    name: String,
    level: Int,
    proficiency: Float,
    free: Float,
  )
}

/// recommendation_candidates.sql — for one project's required capabilities as-of
/// $2, every candidate engineer NOT currently on the project, with their rolled-up
/// proficiency in that capability and their free fraction across all allocations
/// (the assignment recommender, #40 Phase 3). Params: $1 = project_id, $2 = as-of
/// date.
///
/// The candidate pool (qualifier CTE, rooted at employment like
/// schedule_candidates.sql) is every engineer employed as-of $2 who is NOT on
/// leave as-of $2 (NOT EXISTS, the house leave-suppression pattern) and NOT
/// allocated to $1 as-of $2 (NOT EXISTS). One row per (required capability × pool
/// candidate), built by CROSS JOINing the pool against the project's required
/// capabilities so a candidate with zero fit still lists (the view filters).
/// Proficiency is the Phase 1 capability_rollup weighted average (same LATERAL
/// shape as capability_coverage.sql, coalesced to 0 when nothing is mapped or
/// assessed). Free is `greatest(0, 1 - sum(fraction))` over ALL of the
/// candidate's allocations as-of $2 (not just this project), coalescing an
/// unallocated candidate to fully free (1.0). Ranking (the capped-fit tie-break,
/// ready-now vs growth split) happens in Gleam, so the ORDER BY here is only for
/// a stable read.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn recommendation_candidates(
  db: pog.Connection,
  allocation_project_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(RecommendationCandidatesRow), pog.QueryError) {
  let decoder = {
    use capability_id <- decode.field(0, decode.int)
    use engineer_id <- decode.field(1, decode.int)
    use name <- decode.field(2, decode.string)
    use level <- decode.field(3, decode.int)
    use proficiency <- decode.field(4, pog.numeric_decoder())
    use free <- decode.field(5, pog.numeric_decoder())
    decode.success(RecommendationCandidatesRow(
      capability_id:,
      engineer_id:,
      name:,
      level:,
      proficiency:,
      free:,
    ))
  }

  "-- recommendation_candidates.sql — for one project's required capabilities as-of
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
"
  |> pog.query
  |> pog.parameter(pog.int(allocation_project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `recommendation_pairings` query
/// defined in `./src/tempo/server/project_capability/sql/recommendation_pairings.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RecommendationPairingsRow {
  RecommendationPairingsRow(
    capability_id: Int,
    learner_id: Int,
    skill_id: Int,
    skill_name: String,
    weight: Int,
    teacher_id: Int,
    teacher_name: String,
  )
}

/// recommendation_pairings.sql — for one project's required capabilities as-of
/// $2, every qualifying growth pairing: a candidate learner below the target
/// (level 1 or 2 on one of the capability's weight >= 2 skills) matched to an
/// on-team level-4 teacher on that same skill (the assignment recommender, #40
/// Phase 3). Params: $1 = project_id, $2 = as-of date.
///
/// Learner pool (same shape as recommendation_candidates.sql's qualifier): every
/// engineer employed as-of $2, not on leave as-of $2, not already allocated to
/// $1 as-of $2. Team pool: every engineer allocated to $1 as-of $2, employed as-of
/// $2, not on leave as-of $2 — the "current team" a learner could shadow. A
/// pairing row exists only where a learner's level 1/2 skill (weight >= 2 within
/// the required capability, as-of $2) is matched by a team member's level-4
/// assessment on that exact skill as-of $2 — so every returned row already has a
/// real teacher; picking ONE pairing per learner (highest weight, then skill
/// name, then teacher name) happens in Gleam.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn recommendation_pairings(
  db: pog.Connection,
  allocation_project_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(RecommendationPairingsRow), pog.QueryError) {
  let decoder = {
    use capability_id <- decode.field(0, decode.int)
    use learner_id <- decode.field(1, decode.int)
    use skill_id <- decode.field(2, decode.int)
    use skill_name <- decode.field(3, decode.string)
    use weight <- decode.field(4, decode.int)
    use teacher_id <- decode.field(5, decode.int)
    use teacher_name <- decode.field(6, decode.string)
    decode.success(RecommendationPairingsRow(
      capability_id:,
      learner_id:,
      skill_id:,
      skill_name:,
      weight:,
      teacher_id:,
      teacher_name:,
    ))
  }

  "-- recommendation_pairings.sql — for one project's required capabilities as-of
-- $2, every qualifying growth pairing: a candidate learner below the target
-- (level 1 or 2 on one of the capability's weight >= 2 skills) matched to an
-- on-team level-4 teacher on that same skill (the assignment recommender, #40
-- Phase 3). Params: $1 = project_id, $2 = as-of date.
--
-- Learner pool (same shape as recommendation_candidates.sql's qualifier): every
-- engineer employed as-of $2, not on leave as-of $2, not already allocated to
-- $1 as-of $2. Team pool: every engineer allocated to $1 as-of $2, employed as-of
-- $2, not on leave as-of $2 — the \"current team\" a learner could shadow. A
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
"
  |> pog.query
  |> pog.parameter(pog.int(allocation_project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
