//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/engineer_skill/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `capability_rollup` query
/// defined in `./src/tempo/server/engineer_skill/sql/capability_rollup.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type CapabilityRollupRow {
  CapabilityRollupRow(capability_id: Int, name: String, proficiency: Float)
}

/// capability_rollup.sql — one engineer's weighted-average proficiency per
/// capability as-of $2, for the people-detail Skills tab's rollup aside.
/// proficiency = Σ(level × weight) / Σ(weight) over the capability's mapped
/// skills, with an unassessed skill counting as level 0. numeric division so
/// squirrel decodes proficiency via pog.numeric_decoder() (a Float on the read
/// side). $1 = engineer_id, $2 = as_of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn capability_rollup(
  db: pog.Connection,
  engineer_skill_engineer_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(CapabilityRollupRow), pog.QueryError) {
  let decoder = {
    use capability_id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use proficiency <- decode.field(2, pog.numeric_decoder())
    decode.success(CapabilityRollupRow(capability_id:, name:, proficiency:))
  }

  "-- capability_rollup.sql — one engineer's weighted-average proficiency per
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
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_skill_engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_skill_close_all.sql — cap all of an engineer's skill assessments from
/// a date (termination cascade, part of record_departure).
///
/// Close/cascade pattern, mirroring engineer_role_close_all: DELETE FOR PORTION OF
/// intersects [$end, ∞) with each assessment row: a row wholly after $end is
/// dropped, a row straddling $end keeps its [row.lower, $end) leftover. No @>
/// filter — this is intentionally broad, ending every skill the engineer holds.
/// $1 = engineer_id, $2 = end date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_skill_close_all(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_skill_close_all.sql — cap all of an engineer's skill assessments from
-- a date (termination cascade, part of record_departure).
--
-- Close/cascade pattern, mirroring engineer_role_close_all: DELETE FOR PORTION OF
-- intersects [$end, ∞) with each assessment row: a row wholly after $end is
-- dropped, a row straddling $end keeps its [row.lower, $end) leftover. No @>
-- filter — this is intentionally broad, ending every skill the engineer holds.
-- $1 = engineer_id, $2 = end date.
DELETE FROM engineer_skill
   FOR PORTION OF assessed_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_skill_upsert.sql — record an engineer's assessed level for a skill
/// from $3 onward (delete-then-insert semantics), mirroring engineer_role_upsert.
/// The temporal DELETE clips the row covering $3 to [start, $3) and removes any
/// rows that start at or after $3, then inserts a new row bounded by employment's
/// upper end, respecting the engineer_skill_within_employment PERIOD FK. $1 =
/// engineer_id, $2 = skill_id, $3 = effective, $4 = level, $5 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_skill_upsert(
  db: pog.Connection,
  engineer_id: Int,
  skill_id: Int,
  arg_3: Date,
  arg_4: Int,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_skill_upsert.sql — record an engineer's assessed level for a skill
-- from $3 onward (delete-then-insert semantics), mirroring engineer_role_upsert.
-- The temporal DELETE clips the row covering $3 to [start, $3) and removes any
-- rows that start at or after $3, then inserts a new row bounded by employment's
-- upper end, respecting the engineer_skill_within_employment PERIOD FK. $1 =
-- engineer_id, $2 = skill_id, $3 = effective, $4 = level, $5 = audit_id.
WITH deleted AS (
  DELETE FROM engineer_skill
     FOR PORTION OF assessed_during FROM $3::date TO NULL
   WHERE engineer_id = $1 AND skill_id = $2
)
INSERT INTO engineer_skill (engineer_id, skill_id, level, assessed_during, audit_id)
SELECT $1, $2, $4, daterange($3::date, upper(employed_during), '[)'), $5
FROM employment
WHERE engineer_id = $1
  AND employed_during @> $3::date;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.int(skill_id))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `recent_assessments` query
/// defined in `./src/tempo/server/engineer_skill/sql/recent_assessments.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RecentAssessmentsRow {
  RecentAssessmentsRow(
    name: String,
    level: Int,
    valid_from: Date,
    valid_to: Date,
    ongoing: Bool,
  )
}

/// recent_assessments.sql — one engineer's full skill-assessment timeline for the
/// people-detail Skills tab's history panel. Param: $1 = engineer_id.
///
/// Decomposed to plain dates at the boundary: skill name, level, lower(assessed_
/// during) AS valid_from. A current assessment is OPEN ([start, employment's end)
/// for an active engineer), so upper(assessed_during) can be NULL only if
/// employment itself is open — `ongoing` reports whether this version still
/// holds, and `valid_to` coalesces to the start so the column stays a non-null
/// date the boundary can decode (the server maps ongoing -> None). Most recent
/// first.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn recent_assessments(
  db: pog.Connection,
  engineer_skill_engineer_id: Int,
) -> Result(pog.Returned(RecentAssessmentsRow), pog.QueryError) {
  let decoder = {
    use name <- decode.field(0, decode.string)
    use level <- decode.field(1, decode.int)
    use valid_from <- decode.field(2, pog.calendar_date_decoder())
    use valid_to <- decode.field(3, pog.calendar_date_decoder())
    use ongoing <- decode.field(4, decode.bool)
    decode.success(RecentAssessmentsRow(
      name:,
      level:,
      valid_from:,
      valid_to:,
      ongoing:,
    ))
  }

  "-- recent_assessments.sql — one engineer's full skill-assessment timeline for the
-- people-detail Skills tab's history panel. Param: $1 = engineer_id.
--
-- Decomposed to plain dates at the boundary: skill name, level, lower(assessed_
-- during) AS valid_from. A current assessment is OPEN ([start, employment's end)
-- for an active engineer), so upper(assessed_during) can be NULL only if
-- employment itself is open — `ongoing` reports whether this version still
-- holds, and `valid_to` coalesces to the start so the column stays a non-null
-- date the boundary can decode (the server maps ongoing -> None). Most recent
-- first.
SELECT
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
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_skill_engineer_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `skill_matrix` query
/// defined in `./src/tempo/server/engineer_skill/sql/skill_matrix.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type SkillMatrixRow {
  SkillMatrixRow(skill_id: Int, name: String, level: Int)
}

/// skill_matrix.sql — one engineer's level in every skill in force as-of $2 (0 for
/// a skill never assessed), for the people-detail Skills tab. Driven from
/// skill_profile (not engineer_skill) so a retired skill drops out of the matrix
/// automatically, joined through as-of $2 like every other taxonomy read.
/// $1 = engineer_id, $2 = as_of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn skill_matrix(
  db: pog.Connection,
  engineer_skill_engineer_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(SkillMatrixRow), pog.QueryError) {
  let decoder = {
    use skill_id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use level <- decode.field(2, decode.int)
    decode.success(SkillMatrixRow(skill_id:, name:, level:))
  }

  "-- skill_matrix.sql — one engineer's level in every skill in force as-of $2 (0 for
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
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_skill_engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
