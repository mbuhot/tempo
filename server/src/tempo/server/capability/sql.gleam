//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/capability/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `capability_catalog` query
/// defined in `./src/tempo/server/capability/sql/capability_catalog.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type CapabilityCatalogRow {
  CapabilityCatalogRow(id: Int, name: String, summary: String)
}

/// capability_catalog.sql — every capability + summary in force as-of $1, for the
/// taxonomy snapshot. $1 = as_of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn capability_catalog(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(CapabilityCatalogRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use summary <- decode.field(2, decode.string)
    decode.success(CapabilityCatalogRow(id:, name:, summary:))
  }

  "-- capability_catalog.sql — every capability + summary in force as-of $1, for the
-- taxonomy snapshot. $1 = as_of date.
SELECT capability_id AS id, name, summary
  FROM capability_profile
 WHERE defined_during @> $1::date
 ORDER BY name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// capability_create.sql — insert the capability identity (ID-ONLY anchor) at a
/// reserved id.
///
/// The id is reserved up-front from capability_id_seq (capability_next_id) and
/// supplied as $1, so this is a plain insert with no RETURNING. The capability's
/// name/summary live in a separate capability_profile fact recorded alongside,
/// NOT a column here.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn capability_create(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- capability_create.sql — insert the capability identity (ID-ONLY anchor) at a
-- reserved id.
--
-- The id is reserved up-front from capability_id_seq (capability_next_id) and
-- supplied as $1, so this is a plain insert with no RETURNING. The capability's
-- name/summary live in a separate capability_profile fact recorded alongside,
-- NOT a column here.
INSERT INTO capability (id) VALUES ($1);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `capability_next_id` query
/// defined in `./src/tempo/server/capability/sql/capability_next_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type CapabilityNextIdRow {
  CapabilityNextIdRow(id: Int)
}

/// capability_next_id.sql — reserve the next capability id from its sequence.
///
/// Called before create_capability records the anchor: the handler threads this id
/// into the capability anchor and its capability_profile fact in one transaction,
/// so nothing is read back.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn capability_next_id(
  db: pog.Connection,
) -> Result(pog.Returned(CapabilityNextIdRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(CapabilityNextIdRow(id:))
  }

  "-- capability_next_id.sql — reserve the next capability id from its sequence.
--
-- Called before create_capability records the anchor: the handler threads this id
-- into the capability anchor and its capability_profile fact in one transaction,
-- so nothing is read back.
SELECT nextval('capability_id_seq')::int AS id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// capability_profile_close.sql — cap a capability's profile at the effective date
/// (RetireCapability): cap the defined period at the effective date (DELETE FOR
/// PORTION OF), leaving the history [start, effective) intact for audit.
/// $1 = capability_id, $2 = effective date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn capability_profile_close(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- capability_profile_close.sql — cap a capability's profile at the effective date
-- (RetireCapability): cap the defined period at the effective date (DELETE FOR
-- PORTION OF), leaving the history [start, effective) intact for audit.
-- $1 = capability_id, $2 = effective date.
DELETE FROM capability_profile
   FOR PORTION OF defined_during FROM $2::date TO NULL
 WHERE capability_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// capability_profile_upsert.sql — record a capability profile from $2 onward
/// (delete-then-insert semantics). The temporal DELETE clips the row covering $2 to
/// [start, $2) and removes any rows that start at or after $2, then inserts
/// [$2, NULL) with the new name/summary. The founding CreateCapability write and a
/// later DefineCapability are the SAME fact, so this one query serves both.
/// $1 = capability_id, $2 = effective, $3 = name, $4 = summary, $5 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn capability_profile_upsert(
  db: pog.Connection,
  capability_id: Int,
  arg_2: Date,
  arg_3: String,
  arg_4: String,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- capability_profile_upsert.sql — record a capability profile from $2 onward
-- (delete-then-insert semantics). The temporal DELETE clips the row covering $2 to
-- [start, $2) and removes any rows that start at or after $2, then inserts
-- [$2, NULL) with the new name/summary. The founding CreateCapability write and a
-- later DefineCapability are the SAME fact, so this one query serves both.
-- $1 = capability_id, $2 = effective, $3 = name, $4 = summary, $5 = audit_id.
WITH deleted AS (
  DELETE FROM capability_profile
     FOR PORTION OF defined_during FROM $2::date TO NULL
   WHERE capability_id = $1
)
INSERT INTO capability_profile (capability_id, name, summary, defined_during, audit_id)
VALUES ($1, $3, $4, daterange($2::date, NULL, '[)'), $5);
"
  |> pog.query
  |> pog.parameter(pog.int(capability_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// capability_skill_close_for_capability.sql — cap all of a capability's skill
/// mappings from a date (retire cascade, part of RetireCapability).
///
/// Close/cascade pattern, mirroring engineer_role_close_all: DELETE FOR PORTION OF
/// intersects [$end, ∞) with each mapping row: a row wholly after $end is dropped,
/// a row straddling $end keeps its [row.lower, $end) leftover. No @> filter — this
/// is intentionally broad, ending every skill mapped to the capability.
/// $1 = capability_id, $2 = end date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn capability_skill_close_for_capability(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- capability_skill_close_for_capability.sql — cap all of a capability's skill
-- mappings from a date (retire cascade, part of RetireCapability).
--
-- Close/cascade pattern, mirroring engineer_role_close_all: DELETE FOR PORTION OF
-- intersects [$end, ∞) with each mapping row: a row wholly after $end is dropped,
-- a row straddling $end keeps its [row.lower, $end) leftover. No @> filter — this
-- is intentionally broad, ending every skill mapped to the capability.
-- $1 = capability_id, $2 = end date.
DELETE FROM capability_skill
   FOR PORTION OF mapped_during FROM $2::date TO NULL
 WHERE capability_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `capability_skill_matrix` query
/// defined in `./src/tempo/server/capability/sql/capability_skill_matrix.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type CapabilitySkillMatrixRow {
  CapabilitySkillMatrixRow(capability_id: Int, skill_id: Int, weight: Int)
}

/// capability_skill_matrix.sql — every (capability, skill, weight) mapping in
/// force as-of $1, for the taxonomy snapshot's composition matrix. $1 = as_of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn capability_skill_matrix(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(CapabilitySkillMatrixRow), pog.QueryError) {
  let decoder = {
    use capability_id <- decode.field(0, decode.int)
    use skill_id <- decode.field(1, decode.int)
    use weight <- decode.field(2, decode.int)
    decode.success(CapabilitySkillMatrixRow(capability_id:, skill_id:, weight:))
  }

  "-- capability_skill_matrix.sql — every (capability, skill, weight) mapping in
-- force as-of $1, for the taxonomy snapshot's composition matrix. $1 = as_of date.
SELECT capability_id, skill_id, weight
  FROM capability_skill
 WHERE mapped_during @> $1::date
 ORDER BY capability_id, skill_id;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// capability_skill_remove.sql — remove a skill from a capability's composition
/// from the effective date (RemoveCapabilitySkill): cap the mapped period at the
/// effective date (DELETE FOR PORTION OF), leaving the history [start, effective)
/// intact for audit. $1 = capability_id, $2 = skill_id, $3 = effective date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn capability_skill_remove(
  db: pog.Connection,
  capability_id: Int,
  arg_2: Int,
  arg_3: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- capability_skill_remove.sql — remove a skill from a capability's composition
-- from the effective date (RemoveCapabilitySkill): cap the mapped period at the
-- effective date (DELETE FOR PORTION OF), leaving the history [start, effective)
-- intact for audit. $1 = capability_id, $2 = skill_id, $3 = effective date.
DELETE FROM capability_skill
   FOR PORTION OF mapped_during FROM $3::date TO NULL
 WHERE capability_id = $1 AND skill_id = $2;
"
  |> pog.query
  |> pog.parameter(pog.int(capability_id))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// capability_skill_upsert.sql — set the weight a skill contributes to a capability
/// from $3 onward (delete-then-insert semantics), mirroring user_role_grant: caps
/// any current period at the effective date then opens a fresh [effective, ∞), so
/// a re-weight is idempotent — the DEFERRABLE PK covers the close-then-open over
/// an open span. $1 = capability_id, $2 = skill_id, $3 = effective, $4 = weight,
/// $5 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn capability_skill_upsert(
  db: pog.Connection,
  capability_id: Int,
  skill_id: Int,
  arg_3: Date,
  arg_4: Int,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- capability_skill_upsert.sql — set the weight a skill contributes to a capability
-- from $3 onward (delete-then-insert semantics), mirroring user_role_grant: caps
-- any current period at the effective date then opens a fresh [effective, ∞), so
-- a re-weight is idempotent — the DEFERRABLE PK covers the close-then-open over
-- an open span. $1 = capability_id, $2 = skill_id, $3 = effective, $4 = weight,
-- $5 = audit_id.
WITH capped AS (
  DELETE FROM capability_skill
     FOR PORTION OF mapped_during FROM $3::date TO NULL
   WHERE capability_id = $1 AND skill_id = $2
)
INSERT INTO capability_skill (capability_id, skill_id, weight, mapped_during, audit_id)
VALUES ($1, $2, $4, daterange($3::date, NULL, '[)'), $5);
"
  |> pog.query
  |> pog.parameter(pog.int(capability_id))
  |> pog.parameter(pog.int(skill_id))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `skill_catalog` query
/// defined in `./src/tempo/server/capability/sql/skill_catalog.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type SkillCatalogRow {
  SkillCatalogRow(id: Int, name: String, summary: String)
}

/// skill_catalog.sql — every skill + summary in force as-of $1, for the taxonomy
/// snapshot. $1 = as_of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn skill_catalog(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(SkillCatalogRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use summary <- decode.field(2, decode.string)
    decode.success(SkillCatalogRow(id:, name:, summary:))
  }

  "-- skill_catalog.sql — every skill + summary in force as-of $1, for the taxonomy
-- snapshot. $1 = as_of date.
SELECT skill_id AS id, name, summary
  FROM skill_profile
 WHERE defined_during @> $1::date
 ORDER BY name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
