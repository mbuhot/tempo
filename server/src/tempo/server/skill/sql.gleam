//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/skill/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

/// capability_skill_close_for_skill.sql — cap all capability mappings of a skill
/// from a date (retire cascade, part of RetireSkill).
///
/// Close/cascade pattern, mirroring engineer_role_close_all: DELETE FOR PORTION OF
/// intersects [$end, ∞) with each mapping row: a row wholly after $end is dropped,
/// a row straddling $end keeps its [row.lower, $end) leftover. No @> filter — this
/// is intentionally broad, ending every capability the skill is mapped to.
/// $1 = skill_id, $2 = end date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn capability_skill_close_for_skill(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- capability_skill_close_for_skill.sql — cap all capability mappings of a skill
-- from a date (retire cascade, part of RetireSkill).
--
-- Close/cascade pattern, mirroring engineer_role_close_all: DELETE FOR PORTION OF
-- intersects [$end, ∞) with each mapping row: a row wholly after $end is dropped,
-- a row straddling $end keeps its [row.lower, $end) leftover. No @> filter — this
-- is intentionally broad, ending every capability the skill is mapped to.
-- $1 = skill_id, $2 = end date.
DELETE FROM capability_skill
   FOR PORTION OF mapped_during FROM $2::date TO NULL
 WHERE skill_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// skill_create.sql — insert the skill identity (ID-ONLY anchor) at a reserved id.
///
/// The id is reserved up-front from skill_id_seq (skill_next_id) and supplied as
/// $1, so this is a plain insert with no RETURNING. The skill's name/summary live
/// in a separate skill_profile fact recorded alongside, NOT a column here.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn skill_create(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- skill_create.sql — insert the skill identity (ID-ONLY anchor) at a reserved id.
--
-- The id is reserved up-front from skill_id_seq (skill_next_id) and supplied as
-- $1, so this is a plain insert with no RETURNING. The skill's name/summary live
-- in a separate skill_profile fact recorded alongside, NOT a column here.
INSERT INTO skill (id) VALUES ($1);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `skill_next_id` query
/// defined in `./src/tempo/server/skill/sql/skill_next_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type SkillNextIdRow {
  SkillNextIdRow(id: Int)
}

/// skill_next_id.sql — reserve the next skill id from its sequence.
///
/// Called before create_skill records the anchor: the handler threads this id
/// into the skill anchor and its skill_profile fact in one transaction, so
/// nothing is read back.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn skill_next_id(
  db: pog.Connection,
) -> Result(pog.Returned(SkillNextIdRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(SkillNextIdRow(id:))
  }

  "-- skill_next_id.sql — reserve the next skill id from its sequence.
--
-- Called before create_skill records the anchor: the handler threads this id
-- into the skill anchor and its skill_profile fact in one transaction, so
-- nothing is read back.
SELECT nextval('skill_id_seq')::int AS id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// skill_profile_close.sql — cap a skill's profile at the effective date
/// (RetireSkill): cap the defined period at the effective date (DELETE FOR
/// PORTION OF), leaving the history [start, effective) intact for audit.
/// $1 = skill_id, $2 = effective date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn skill_profile_close(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- skill_profile_close.sql — cap a skill's profile at the effective date
-- (RetireSkill): cap the defined period at the effective date (DELETE FOR
-- PORTION OF), leaving the history [start, effective) intact for audit.
-- $1 = skill_id, $2 = effective date.
DELETE FROM skill_profile
   FOR PORTION OF defined_during FROM $2::date TO NULL
 WHERE skill_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// skill_profile_upsert.sql — record a skill profile from $2 onward (delete-then-
/// insert semantics). The temporal DELETE clips the row covering $2 to [start, $2)
/// and removes any rows that start at or after $2, then inserts [$2, NULL) with
/// the new name/summary. The founding CreateSkill write and a later DefineSkill
/// are the SAME fact, so this one query serves both.
/// $1 = skill_id, $2 = effective, $3 = name, $4 = summary, $5 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn skill_profile_upsert(
  db: pog.Connection,
  skill_id: Int,
  arg_2: Date,
  arg_3: String,
  arg_4: String,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- skill_profile_upsert.sql — record a skill profile from $2 onward (delete-then-
-- insert semantics). The temporal DELETE clips the row covering $2 to [start, $2)
-- and removes any rows that start at or after $2, then inserts [$2, NULL) with
-- the new name/summary. The founding CreateSkill write and a later DefineSkill
-- are the SAME fact, so this one query serves both.
-- $1 = skill_id, $2 = effective, $3 = name, $4 = summary, $5 = audit_id.
WITH deleted AS (
  DELETE FROM skill_profile
     FOR PORTION OF defined_during FROM $2::date TO NULL
   WHERE skill_id = $1
)
INSERT INTO skill_profile (skill_id, name, summary, defined_during, audit_id)
VALUES ($1, $3, $4, daterange($2::date, NULL, '[)'), $5);
"
  |> pog.query
  |> pog.parameter(pog.int(skill_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
