//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/engineer/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog

/// employment_close.sql — terminate an engineer's employment from a date.
///
/// Close/cascade pattern. DELETE FOR PORTION OF intersects [$end, ∞) with the
/// employment row, capping the open-ended period at $end (PG keeps the
/// [row.lower, $end) leftover). The contained facts (roles/allocations/leave)
/// must already be capped to $end or the PERIOD FKs would block this. No @>
/// filter — intentionally broad across the engineer's employment.
/// $1 = engineer_id, $2 = end date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn employment_close(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- employment_close.sql — terminate an engineer's employment from a date.
--
-- Close/cascade pattern. DELETE FOR PORTION OF intersects [$end, ∞) with the
-- employment row, capping the open-ended period at $end (PG keeps the
-- [row.lower, $end) leftover). The contained facts (roles/allocations/leave)
-- must already be capped to $end or the PERIOD FKs would block this. No @>
-- filter — intentionally broad across the engineer's employment.
-- $1 = engineer_id, $2 = end date.
DELETE FROM employment
   FOR PORTION OF employed_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// employment_open.sql — assert ongoing employment (open-ended). The last param is
/// the audit_id (the event_log id of the command recording this fact).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn employment_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
  arg_3: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- employment_open.sql — assert ongoing employment (open-ended). The last param is
-- the audit_id (the event_log id of the command recording this fact).
INSERT INTO employment (engineer_id, employed_during, audit_id)
VALUES ($1, daterange($2::date, NULL, '[)'), $3);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.int(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_allocations` query
/// defined in `./src/tempo/server/engineer/sql/engineer_allocations.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerAllocationsRow {
  EngineerAllocationsRow(
    project_id: Int,
    project: String,
    fraction: Float,
    valid_from: Date,
    valid_to: Date,
    active: Bool,
  )
}

/// engineer_allocations.sql — one engineer's full allocation timeline for the detail
/// read model (GET /api/engineers/:id; the AllocationRow list). Params:
/// $1 = engineer_id, $2 = as-of (for the active flag only).
///
/// Every allocation period-row for the engineer joined to project_current for the
/// title (and to the project anchor for the clickable project_id). Range columns are
/// decomposed to plain dates: lower(allocated_during) AS valid_from,
/// upper(allocated_during) AS valid_to (non-null for every seed row). `active` is
/// (allocated_during @> $2) — the as-of marks each row active/ended per FR-PE4
/// without hiding it, so the whole history is returned regardless of $2. Ordered
/// oldest-first then by title for a stable list.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_allocations(
  db: pog.Connection,
  allocation_engineer_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(EngineerAllocationsRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use project <- decode.field(1, decode.string)
    use fraction <- decode.field(2, pog.numeric_decoder())
    use valid_from <- decode.field(3, pog.calendar_date_decoder())
    use valid_to <- decode.field(4, pog.calendar_date_decoder())
    use active <- decode.field(5, decode.bool)
    decode.success(EngineerAllocationsRow(
      project_id:,
      project:,
      fraction:,
      valid_from:,
      valid_to:,
      active:,
    ))
  }

  "-- engineer_allocations.sql — one engineer's full allocation timeline for the detail
-- read model (GET /api/engineers/:id; the AllocationRow list). Params:
-- $1 = engineer_id, $2 = as-of (for the active flag only).
--
-- Every allocation period-row for the engineer joined to project_current for the
-- title (and to the project anchor for the clickable project_id). Range columns are
-- decomposed to plain dates: lower(allocated_during) AS valid_from,
-- upper(allocated_during) AS valid_to (non-null for every seed row). `active` is
-- (allocated_during @> $2) — the as-of marks each row active/ended per FR-PE4
-- without hiding it, so the whole history is returned regardless of $2. Ordered
-- oldest-first then by title for a stable list.
SELECT
  allocation.project_id,
  coalesce(project_current.title, '') AS project,
  allocation.fraction,
  lower(allocation.allocated_during) AS valid_from,
  upper(allocation.allocated_during) AS valid_to,
  (allocation.allocated_during @> $2::date) AS active
FROM allocation
JOIN project_current ON project_current.id = allocation.project_id
WHERE allocation.engineer_id = $1
ORDER BY lower(allocation.allocated_during), project;
"
  |> pog.query
  |> pog.parameter(pog.int(allocation_engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_banking_current` query
/// defined in `./src/tempo/server/engineer/sql/engineer_banking_current.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerBankingCurrentRow {
  EngineerBankingCurrentRow(
    engineer_id: Int,
    bank: String,
    branch: String,
    account_no: String,
    account_name: String,
  )
}

/// engineer_banking_current.sql — an engineer's CURRENT banking (latest read).
///
/// The most-recently-effective engineer_banking row: DISTINCT ON ordered by the
/// start of recorded_during descending (append-only + WITHOUT OVERLAPS → greatest
/// start is in force). Scalar columns only. $1 = engineer_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_banking_current(
  db: pog.Connection,
  engineer_id: Int,
) -> Result(pog.Returned(EngineerBankingCurrentRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use bank <- decode.field(1, decode.string)
    use branch <- decode.field(2, decode.string)
    use account_no <- decode.field(3, decode.string)
    use account_name <- decode.field(4, decode.string)
    decode.success(EngineerBankingCurrentRow(
      engineer_id:,
      bank:,
      branch:,
      account_no:,
      account_name:,
    ))
  }

  "-- engineer_banking_current.sql — an engineer's CURRENT banking (latest read).
--
-- The most-recently-effective engineer_banking row: DISTINCT ON ordered by the
-- start of recorded_during descending (append-only + WITHOUT OVERLAPS → greatest
-- start is in force). Scalar columns only. $1 = engineer_id.
SELECT DISTINCT ON (engineer_id)
  engineer_id,
  bank,
  branch,
  account_no,
  account_name
FROM engineer_banking
WHERE engineer_id = $1
ORDER BY engineer_id, lower(recorded_during) DESC;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_banking_upsert.sql — record banking details from $2 onward (delete-then-insert
/// semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
/// rows that start at or after $2, then inserts [$2, NULL) with the new values. Passing NULL
/// as the upper bound asserts the new details hold to infinity, superseding any scheduled
/// future versions. $1 = engineer_id, $2 = effective, $3 = bank, $4 = branch,
/// $5 = account_no, $6 = account_name, $7 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_banking_upsert(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Date,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: String,
  arg_7: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_banking_upsert.sql — record banking details from $2 onward (delete-then-insert
-- semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
-- rows that start at or after $2, then inserts [$2, NULL) with the new values. Passing NULL
-- as the upper bound asserts the new details hold to infinity, superseding any scheduled
-- future versions. $1 = engineer_id, $2 = effective, $3 = bank, $4 = branch,
-- $5 = account_no, $6 = account_name, $7 = audit_id.
WITH deleted AS (
  DELETE FROM engineer_banking
     FOR PORTION OF recorded_during FROM $2::date TO NULL
   WHERE engineer_id = $1
)
INSERT INTO engineer_banking
  (engineer_id, bank, branch, account_no, account_name, recorded_during, audit_id)
VALUES ($1, $3, $4, $5, $6, daterange($2::date, NULL, '[)'), $7);
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.int(arg_7))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_contact_current` query
/// defined in `./src/tempo/server/engineer/sql/engineer_contact_current.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerContactCurrentRow {
  EngineerContactCurrentRow(
    engineer_id: Option(Int),
    name: Option(String),
    email: Option(String),
    phone: Option(String),
    postal_address: Option(String),
  )
}

/// engineer_contact_current.sql — an engineer's CURRENT contact (name + contact
/// details) from the engineer_current view, which already exposes the
/// latest-version columns. $1 = engineer_id; an empty result means no such
/// engineer (the detail handler answers 404). Scalar columns only.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_contact_current(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(EngineerContactCurrentRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.optional(decode.int))
    use name <- decode.field(1, decode.optional(decode.string))
    use email <- decode.field(2, decode.optional(decode.string))
    use phone <- decode.field(3, decode.optional(decode.string))
    use postal_address <- decode.field(4, decode.optional(decode.string))
    decode.success(EngineerContactCurrentRow(
      engineer_id:,
      name:,
      email:,
      phone:,
      postal_address:,
    ))
  }

  "-- engineer_contact_current.sql — an engineer's CURRENT contact (name + contact
-- details) from the engineer_current view, which already exposes the
-- latest-version columns. $1 = engineer_id; an empty result means no such
-- engineer (the detail handler answers 404). Scalar columns only.
SELECT
  id AS engineer_id,
  name,
  email,
  phone,
  postal_address
FROM engineer_current
WHERE id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_contact_upsert.sql — record contact details from $2 onward (delete-then-insert
/// semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
/// rows that start at or after $2, then inserts [$2, NULL) with the new values. Passing NULL
/// as the upper bound asserts the new details hold to infinity, superseding any scheduled
/// future versions. $1 = engineer_id, $2 = effective, $3 = name, $4 = email, $5 = phone,
/// $6 = postal, $7 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_contact_upsert(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Date,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: String,
  arg_7: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_contact_upsert.sql — record contact details from $2 onward (delete-then-insert
-- semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
-- rows that start at or after $2, then inserts [$2, NULL) with the new values. Passing NULL
-- as the upper bound asserts the new details hold to infinity, superseding any scheduled
-- future versions. $1 = engineer_id, $2 = effective, $3 = name, $4 = email, $5 = phone,
-- $6 = postal, $7 = audit_id.
WITH deleted AS (
  DELETE FROM engineer_contact
     FOR PORTION OF recorded_during FROM $2::date TO NULL
   WHERE engineer_id = $1
)
INSERT INTO engineer_contact
  (engineer_id, name, email, phone, postal_address, recorded_during, audit_id)
VALUES ($1, $3, $4, $5, $6, daterange($2::date, NULL, '[)'), $7);
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.int(arg_7))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_create.sql — insert the engineer identity (ID-ONLY anchor) at a reserved id.
///
/// Step 1 of onboarding. The id is reserved up-front from engineer_id_seq
/// (engineer_next_id) and supplied as $1, so this is a plain insert with no
/// RETURNING. The engineer's NAME lives in a separate engineer_contact fact recorded
/// alongside, NOT a column here.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_create(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_create.sql — insert the engineer identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of onboarding. The id is reserved up-front from engineer_id_seq
-- (engineer_next_id) and supplied as $1, so this is a plain insert with no
-- RETURNING. The engineer's NAME lives in a separate engineer_contact fact recorded
-- alongside, NOT a column here.
INSERT INTO engineer (id) VALUES ($1);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_emergency_current` query
/// defined in `./src/tempo/server/engineer/sql/engineer_emergency_current.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerEmergencyCurrentRow {
  EngineerEmergencyCurrentRow(
    engineer_id: Int,
    relation: String,
    name: String,
    phone: String,
    email: String,
  )
}

/// engineer_emergency_current.sql — an engineer's CURRENT emergency contact
/// (latest read).
///
/// The most-recently-effective engineer_emergency row: DISTINCT ON ordered by the
/// start of recorded_during descending. Scalar columns only. $1 = engineer_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_emergency_current(
  db: pog.Connection,
  engineer_id: Int,
) -> Result(pog.Returned(EngineerEmergencyCurrentRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use relation <- decode.field(1, decode.string)
    use name <- decode.field(2, decode.string)
    use phone <- decode.field(3, decode.string)
    use email <- decode.field(4, decode.string)
    decode.success(EngineerEmergencyCurrentRow(
      engineer_id:,
      relation:,
      name:,
      phone:,
      email:,
    ))
  }

  "-- engineer_emergency_current.sql — an engineer's CURRENT emergency contact
-- (latest read).
--
-- The most-recently-effective engineer_emergency row: DISTINCT ON ordered by the
-- start of recorded_during descending. Scalar columns only. $1 = engineer_id.
SELECT DISTINCT ON (engineer_id)
  engineer_id,
  relation,
  name,
  phone,
  email
FROM engineer_emergency
WHERE engineer_id = $1
ORDER BY engineer_id, lower(recorded_during) DESC;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_emergency_upsert.sql — record an emergency contact from $2 onward
/// (delete-then-insert semantics). The temporal DELETE clips the row covering $2 to
/// [start, $2) and removes any rows that start at or after $2, then inserts [$2, NULL)
/// with the new values. Passing NULL as the upper bound asserts the new contact holds to
/// infinity, superseding any scheduled future versions. $1 = engineer_id, $2 = effective,
/// $3 = relation, $4 = name, $5 = phone, $6 = email, $7 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_emergency_upsert(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Date,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: String,
  arg_7: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_emergency_upsert.sql — record an emergency contact from $2 onward
-- (delete-then-insert semantics). The temporal DELETE clips the row covering $2 to
-- [start, $2) and removes any rows that start at or after $2, then inserts [$2, NULL)
-- with the new values. Passing NULL as the upper bound asserts the new contact holds to
-- infinity, superseding any scheduled future versions. $1 = engineer_id, $2 = effective,
-- $3 = relation, $4 = name, $5 = phone, $6 = email, $7 = audit_id.
WITH deleted AS (
  DELETE FROM engineer_emergency
     FOR PORTION OF recorded_during FROM $2::date TO NULL
   WHERE engineer_id = $1
)
INSERT INTO engineer_emergency
  (engineer_id, relation, name, phone, email, recorded_during, audit_id)
VALUES ($1, $3, $4, $5, $6, daterange($2::date, NULL, '[)'), $7);
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.int(arg_7))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_employment_asof` query
/// defined in `./src/tempo/server/engineer/sql/engineer_employment_asof.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerEmploymentAsofRow {
  EngineerEmploymentAsofRow(
    engineer_id: Int,
    started: Date,
    level: Int,
    monthly_salary: String,
  )
}

/// engineer_employment_asof.sql — one engineer's as-of employment snapshot for the
/// detail read model (GET /api/engineers/:id). Params: $1 = engineer_id, $2 = as-of.
///
/// The employment table is range-only (engineer_id, employed_during) — it carries
/// NEITHER level NOR salary. The as-of Employment row is assembled by a 3-way as-of
/// join: employment(@>$2) for the started date (lower(employed_during)), engineer_role
/// (@>$2) for the current level, and salary(level, effective_during @>$2) for the
/// monthly cost figure. All INNER joins — a row is returned only when the engineer is
/// employed AND has a role AND that level has a salary as of $2 (the seed guarantees
/// all three for every employed engineer); no row => the detail endpoint 404s.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_employment_asof(
  db: pog.Connection,
  employment_engineer_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(EngineerEmploymentAsofRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use started <- decode.field(1, pog.calendar_date_decoder())
    use level <- decode.field(2, decode.int)
    use monthly_salary <- decode.field(3, decode.string)
    decode.success(EngineerEmploymentAsofRow(
      engineer_id:,
      started:,
      level:,
      monthly_salary:,
    ))
  }

  "-- engineer_employment_asof.sql — one engineer's as-of employment snapshot for the
-- detail read model (GET /api/engineers/:id). Params: $1 = engineer_id, $2 = as-of.
--
-- The employment table is range-only (engineer_id, employed_during) — it carries
-- NEITHER level NOR salary. The as-of Employment row is assembled by a 3-way as-of
-- join: employment(@>$2) for the started date (lower(employed_during)), engineer_role
-- (@>$2) for the current level, and salary(level, effective_during @>$2) for the
-- monthly cost figure. All INNER joins — a row is returned only when the engineer is
-- employed AND has a role AND that level has a salary as of $2 (the seed guarantees
-- all three for every employed engineer); no row => the detail endpoint 404s.
SELECT
  employment.engineer_id,
  lower(employment.employed_during) AS started,
  engineer_role.level,
  salary.monthly_salary::text AS monthly_salary
FROM employment
JOIN engineer_role ON engineer_role.engineer_id = employment.engineer_id
                  AND engineer_role.held_during @> $2::date
JOIN salary ON salary.level = engineer_role.level
           AND salary.effective_during @> $2::date
WHERE employment.engineer_id = $1
  AND employment.employed_during @> $2::date;
"
  |> pog.query
  |> pog.parameter(pog.int(employment_engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_employment_during` query
/// defined in `./src/tempo/server/engineer/sql/engineer_employment_during.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerEmploymentDuringRow {
  EngineerEmploymentDuringRow(engineer_id: Int, name: String, level: Int)
}

/// engineer_employment_during.sql — confirm an engineer is employed (with a role
/// and contact on file) across a period; one row per role version overlapping it.
/// Selects only NOT-NULL columns so an open-ended employment (NULL upper bound)
/// decodes cleanly — the guard cares only that a row exists.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_employment_during(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Date,
  arg_3: Date,
) -> Result(pog.Returned(EngineerEmploymentDuringRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use level <- decode.field(2, decode.int)
    decode.success(EngineerEmploymentDuringRow(engineer_id:, name:, level:))
  }

  "-- engineer_employment_during.sql — confirm an engineer is employed (with a role
-- and contact on file) across a period; one row per role version overlapping it.
-- Selects only NOT-NULL columns so an open-ended employment (NULL upper bound)
-- decodes cleanly — the guard cares only that a row exists.
select
	engineer_id,
	name,
	level
from engineer
join employment on (id = engineer_id)
join engineer_contact using (engineer_id)
join engineer_role using (engineer_id)
where engineer.id = $1
	and (employed_during @> daterange($2::date, $3::date, '[)'))
	and engineer_contact.recorded_during @> $3::date
	and engineer_role.held_during && daterange($2::date, $3::date, '[)')
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_lock` query
/// defined in `./src/tempo/server/engineer/sql/engineer_lock.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerLockRow {
  EngineerLockRow(id: Int)
}

/// engineer_lock.sql — take a row lock on the engineer anchor before reading the
/// leave balance, so the take_leave read-modify-write is serialized per engineer.
///
/// Under READ COMMITTED two concurrent leave requests can otherwise both read the
/// same balance and both commit (issue #2: over-grant) — the leave invariant has no
/// database backstop. Locking the anchor with `FOR UPDATE` makes the second request
/// block until the first commits, then re-read the now-reduced balance and be
/// rejected as InsufficientLeaveBalance. $1 = engineer_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_lock(
  db: pog.Connection,
  id: Int,
) -> Result(pog.Returned(EngineerLockRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(EngineerLockRow(id:))
  }

  "-- engineer_lock.sql — take a row lock on the engineer anchor before reading the
-- leave balance, so the take_leave read-modify-write is serialized per engineer.
--
-- Under READ COMMITTED two concurrent leave requests can otherwise both read the
-- same balance and both commit (issue #2: over-grant) — the leave invariant has no
-- database backstop. Locking the anchor with `FOR UPDATE` makes the second request
-- block until the first commits, then re-read the now-reduced balance and be
-- rejected as InsufficientLeaveBalance. $1 = engineer_id.
SELECT id FROM engineer WHERE id = $1 FOR UPDATE;
"
  |> pog.query
  |> pog.parameter(pog.int(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_next_id` query
/// defined in `./src/tempo/server/engineer/sql/engineer_next_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerNextIdRow {
  EngineerNextIdRow(id: Int)
}

/// engineer_next_id.sql — reserve the next engineer id from its sequence.
///
/// Called before onboard records any engineer fact: the handler threads this id into
/// the Engineer anchor and every fact contained by it (employment, role, contact) in
/// one transaction, so nothing is read back.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_next_id(
  db: pog.Connection,
) -> Result(pog.Returned(EngineerNextIdRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(EngineerNextIdRow(id:))
  }

  "-- engineer_next_id.sql — reserve the next engineer id from its sequence.
--
-- Called before onboard records any engineer fact: the handler threads this id into
-- the Engineer anchor and every fact contained by it (employment, role, contact) in
-- one transaction, so nothing is read back.
SELECT nextval('engineer_id_seq')::int AS id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_role_close_all.sql — cap all of an engineer's roles from a date.
///
/// Close/cascade pattern. DELETE FOR PORTION OF intersects [$end, ∞) with each
/// role row: a row wholly after $end is dropped, a row straddling $end keeps its
/// [row.lower, $end) leftover. No @> filter — this is intentionally broad, ending
/// every role the engineer holds (part of terminating employment).
/// $1 = engineer_id, $2 = end date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_role_close_all(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_role_close_all.sql — cap all of an engineer's roles from a date.
--
-- Close/cascade pattern. DELETE FOR PORTION OF intersects [$end, ∞) with each
-- role row: a row wholly after $end is dropped, a row straddling $end keeps its
-- [row.lower, $end) leftover. No @> filter — this is intentionally broad, ending
-- every role the engineer holds (part of terminating employment).
-- $1 = engineer_id, $2 = end date.
DELETE FROM engineer_role
   FOR PORTION OF held_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_role_history` query
/// defined in `./src/tempo/server/engineer/sql/engineer_role_history.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerRoleHistoryRow {
  EngineerRoleHistoryRow(level: Int, valid_from: Date, valid_to: Date)
}

/// engineer_role_history.sql — one engineer's full role timeline for the detail read
/// model (GET /api/engineers/:id; the RoleVersion list). Param: $1 = engineer_id.
///
/// Every engineer_role period-row for the engineer, decomposed to plain dates at the
/// boundary (ADR-011): level, lower(held_during) AS valid_from,
/// upper(held_during) AS valid_to. Ordered oldest-first by the period start. This is
/// not as-of filtered — the detail page shows the whole promotion history (including
/// future-dated rows like Marcus's L5 from 2026-07-01). upper(held_during) is
/// non-null for every seed role row (all bounded at 2027-01-01).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_role_history(
  db: pog.Connection,
  engineer_role_engineer_id: Int,
) -> Result(pog.Returned(EngineerRoleHistoryRow), pog.QueryError) {
  let decoder = {
    use level <- decode.field(0, decode.int)
    use valid_from <- decode.field(1, pog.calendar_date_decoder())
    use valid_to <- decode.field(2, pog.calendar_date_decoder())
    decode.success(EngineerRoleHistoryRow(level:, valid_from:, valid_to:))
  }

  "-- engineer_role_history.sql — one engineer's full role timeline for the detail read
-- model (GET /api/engineers/:id; the RoleVersion list). Param: $1 = engineer_id.
--
-- Every engineer_role period-row for the engineer, decomposed to plain dates at the
-- boundary (ADR-011): level, lower(held_during) AS valid_from,
-- upper(held_during) AS valid_to. Ordered oldest-first by the period start. This is
-- not as-of filtered — the detail page shows the whole promotion history (including
-- future-dated rows like Marcus's L5 from 2026-07-01). upper(held_during) is
-- non-null for every seed role row (all bounded at 2027-01-01).
SELECT
  engineer_role.level,
  lower(engineer_role.held_during) AS valid_from,
  upper(engineer_role.held_during) AS valid_to
FROM engineer_role
WHERE engineer_role.engineer_id = $1
ORDER BY lower(engineer_role.held_during);
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_role_engineer_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_role_upsert.sql — record an engineer's level from $2 onward (delete-then-insert
/// semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
/// rows that start at or after $2, then inserts a new row bounded by employment's upper end.
/// This supersedes any scheduled future roles within employment while respecting the
/// engineer_role_within_employment PERIOD FK. $1 = engineer_id, $2 = effective,
/// $3 = level, $4 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_role_upsert(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Date,
  arg_3: Int,
  arg_4: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_role_upsert.sql — record an engineer's level from $2 onward (delete-then-insert
-- semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
-- rows that start at or after $2, then inserts a new row bounded by employment's upper end.
-- This supersedes any scheduled future roles within employment while respecting the
-- engineer_role_within_employment PERIOD FK. $1 = engineer_id, $2 = effective,
-- $3 = level, $4 = audit_id.
WITH deleted AS (
  DELETE FROM engineer_role
     FOR PORTION OF held_during FROM $2::date TO NULL
   WHERE engineer_id = $1
)
INSERT INTO engineer_role (engineer_id, level, held_during, audit_id)
SELECT $1, $3, daterange($2::date, upper(employed_during), '[)'), $4
FROM employment
WHERE engineer_id = $1
  AND employed_during @> $2::date;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.int(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
