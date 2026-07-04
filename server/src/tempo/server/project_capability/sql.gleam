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
/// project-detail Capability coverage tab (FR-CP §2, P2-D3). Params: $1 =
/// project_id, $2 = as-of date.
///
/// One row per (required capability × engineer allocated to the project as-of
/// $2). Proficiency reuses the Phase 1 capability_rollup weighted-average join
/// (Σ(level × weight) / Σ(weight) over the capability's mapped skills, scoped to
/// the one engineer), numeric division so squirrel decodes it via
/// pog.numeric_decoder() (a Float on the read side). An engineer with no
/// assessment against any of the capability's skills still appears, at
/// proficiency 0 (LEFT JOIN engineer_skill + coalesce). All temporal joins as-of
/// $2. Ordered by capability then proficiency descending, so the strongest
/// covering engineers list first.
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
