//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog

/// allocation_assign.sql — Assert: allocation insert over a period.
///
/// Records that an engineer is allocated to a project at `fraction` of their time,
/// over [$3, $5) (`daterange($3::date, $5::date, '[)')`). The function only ever
/// sees scalar `date` params; the range is built in SQL.
///
/// The PERIOD FKs to `employment` and `project` are the backstop: an allocation not
/// contained by both a live employment and an active project is rejected — so the
/// allocated period must stay within both the engineer's employment and the
/// project's active run. The WITHOUT OVERLAPS primary key rejects a second
/// overlapping allocation for the same engineer+project. $1 = engineer_id,
/// $2 = project_id, $3 = start day, $4 = fraction, $5 = end day.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn allocation_assign(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: Date,
  arg_4: Float,
  arg_5: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- allocation_assign.sql — Assert: allocation insert over a period.
--
-- Records that an engineer is allocated to a project at `fraction` of their time,
-- over [$3, $5) (`daterange($3::date, $5::date, '[)')`). The function only ever
-- sees scalar `date` params; the range is built in SQL.
--
-- The PERIOD FKs to `employment` and `project` are the backstop: an allocation not
-- contained by both a live employment and an active project is rejected — so the
-- allocated period must stay within both the engineer's employment and the
-- project's active run. The WITHOUT OVERLAPS primary key rejects a second
-- overlapping allocation for the same engineer+project. $1 = engineer_id,
-- $2 = project_id, $3 = start day, $4 = fraction, $5 = end day.
INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during)
VALUES ($1, $2, $4, daterange($3::date, $5::date, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.parameter(pog.calendar_date(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// allocation_change_fraction.sql — Change: re-fraction from a date onward.
///
/// Sets a new `fraction` from `$3` to the end of time. `WHERE … @> $3` matches only
/// the allocation version in effect at $3; `FOR PORTION OF allocated_during FROM $3
/// TO NULL` then intersects [$3, ∞) with that row's own period, so the change lands
/// on [$3, row.upper) and Postgres re-inserts the [row.lower, $3) leftover at the
/// old fraction. A separately scheduled future version doesn't contain $3, so the
/// @> filter excludes it and TO NULL cannot clobber it.
///
/// Boundaries are scalar `date` params cast in SQL. $1 = engineer_id,
/// $2 = project_id, $3 = effective day, $4 = new fraction.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn allocation_change_fraction(
  db: pog.Connection,
  engineer_id: Int,
  project_id: Int,
  arg_3: Date,
  fraction: Float,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- allocation_change_fraction.sql — Change: re-fraction from a date onward.
--
-- Sets a new `fraction` from `$3` to the end of time. `WHERE … @> $3` matches only
-- the allocation version in effect at $3; `FOR PORTION OF allocated_during FROM $3
-- TO NULL` then intersects [$3, ∞) with that row's own period, so the change lands
-- on [$3, row.upper) and Postgres re-inserts the [row.lower, $3) leftover at the
-- old fraction. A separately scheduled future version doesn't contain $3, so the
-- @> filter excludes it and TO NULL cannot clobber it.
--
-- Boundaries are scalar `date` params cast in SQL. $1 = engineer_id,
-- $2 = project_id, $3 = effective day, $4 = new fraction.
UPDATE allocation
   FOR PORTION OF allocated_during FROM $3::date TO NULL
   SET fraction = $4
 WHERE engineer_id = $1 AND project_id = $2 AND allocated_during @> $3::date;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.float(fraction))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// allocation_close.sql — Close: cap one allocation at an end date.
///
/// Used by `roll_off`. `DELETE … FOR PORTION OF allocated_during FROM $3 TO NULL`
/// removes the [$3, ∞) tail of the matching allocation: a spanning row is capped to
/// [row.lower, $3) (Postgres re-inserts the before-leftover) and a fully-future row
/// is dropped outright. Keyed to a single engineer+project — no @> filter, so it
/// closes whatever future portion exists from $3 onward.
///
/// $1 = engineer_id, $2 = project_id, $3 = end day (scalar date, cast in SQL).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn allocation_close(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Int,
  arg_3: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- allocation_close.sql — Close: cap one allocation at an end date.
--
-- Used by `roll_off`. `DELETE … FOR PORTION OF allocated_during FROM $3 TO NULL`
-- removes the [$3, ∞) tail of the matching allocation: a spanning row is capped to
-- [row.lower, $3) (Postgres re-inserts the before-leftover) and a fully-future row
-- is dropped outright. Keyed to a single engineer+project — no @> filter, so it
-- closes whatever future portion exists from $3 onward.
--
-- $1 = engineer_id, $2 = project_id, $3 = end day (scalar date, cast in SQL).
DELETE FROM allocation
   FOR PORTION OF allocated_during FROM $3::date TO NULL
 WHERE engineer_id = $1 AND project_id = $2;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// allocation_close_all.sql — Cascade: cap ALL of an engineer's allocations.
///
/// Used by `terminate_employment` as the allocation step of the child-first cascade.
/// `DELETE … FOR PORTION OF allocated_during FROM $2 TO NULL` wipes every future
/// allocation fact for the engineer from $2 onward: spanning rows are capped to
/// [row.lower, $2) and fully-future rows are dropped. The omitted @> filter is
/// deliberate — terminate is intentionally broad across all projects.
///
/// $1 = engineer_id, $2 = end day (scalar date, cast in SQL).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn allocation_close_all(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- allocation_close_all.sql — Cascade: cap ALL of an engineer's allocations.
--
-- Used by `terminate_employment` as the allocation step of the child-first cascade.
-- `DELETE … FOR PORTION OF allocated_during FROM $2 TO NULL` wipes every future
-- allocation fact for the engineer from $2 onward: spanning rows are capped to
-- [row.lower, $2) and fully-future rows are dropped. The omitted @> filter is
-- deliberate — terminate is intentionally broad across all projects.
--
-- $1 = engineer_id, $2 = end day (scalar date, cast in SQL).
DELETE FROM allocation
   FOR PORTION OF allocated_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `board_engaged` query
/// defined in `./src/tempo/server/sql/board_engaged.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type BoardEngagedRow {
  BoardEngagedRow(
    engineer: String,
    level: Int,
    project: String,
    client: String,
    fraction: Float,
    day_rate: Float,
    valid_from: Date,
    valid_to: Date,
  )
}

/// board_engaged.sql — engineers ALLOCATED to a project on the date ($1::date).
/// One row per (engineer × project).
///
/// This is the "engaged" slice of the board; it returns only fully-engaged rows
/// (INNER JOINs throughout), so every column is non-null. Two companion queries
/// complete the board so every employed engineer is represented exactly once per
/// engagement:
/// * board_unassigned.sql — employed, not on leave, with no allocation
/// * board_leave.sql       — covered by a leave fact (leave overrides)
/// Engineers with a covering leave fact are suppressed here (NOT EXISTS) and
/// surfaced by board_leave.sql instead.
///
/// Charge rate is resolved from engineer_role × rate_card on the date (the
/// two-hop temporal join). It is exposed as a plain `day_rate` value on the row.
///
/// Range columns are decomposed to plain `date`s at the boundary: the engagement
/// window is `lower(allocation.allocated_during)`/`upper(allocation.allocated_during)` AS
/// valid_from/valid_to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn board_engaged(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(BoardEngagedRow), pog.QueryError) {
  let decoder = {
    use engineer <- decode.field(0, decode.string)
    use level <- decode.field(1, decode.int)
    use project <- decode.field(2, decode.string)
    use client <- decode.field(3, decode.string)
    use fraction <- decode.field(4, pog.numeric_decoder())
    use day_rate <- decode.field(5, pog.numeric_decoder())
    use valid_from <- decode.field(6, pog.calendar_date_decoder())
    use valid_to <- decode.field(7, pog.calendar_date_decoder())
    decode.success(BoardEngagedRow(
      engineer:,
      level:,
      project:,
      client:,
      fraction:,
      day_rate:,
      valid_from:,
      valid_to:,
    ))
  }

  "-- board_engaged.sql — engineers ALLOCATED to a project on the date ($1::date).
-- One row per (engineer × project).
--
-- This is the \"engaged\" slice of the board; it returns only fully-engaged rows
-- (INNER JOINs throughout), so every column is non-null. Two companion queries
-- complete the board so every employed engineer is represented exactly once per
-- engagement:
--   * board_unassigned.sql — employed, not on leave, with no allocation
--   * board_leave.sql       — covered by a leave fact (leave overrides)
-- Engineers with a covering leave fact are suppressed here (NOT EXISTS) and
-- surfaced by board_leave.sql instead.
--
-- Charge rate is resolved from engineer_role × rate_card on the date (the
-- two-hop temporal join). It is exposed as a plain `day_rate` value on the row.
--
-- Range columns are decomposed to plain `date`s at the boundary: the engagement
-- window is `lower(allocation.allocated_during)`/`upper(allocation.allocated_during)` AS
-- valid_from/valid_to.
SELECT
  engineer.name AS engineer,
  engineer_role.level,
  project.name AS project,
  client.name AS client,
  allocation.fraction,
  rate_card.day_rate,
  lower(allocation.allocated_during) AS valid_from,
  upper(allocation.allocated_during) AS valid_to
FROM employment
JOIN engineer       ON engineer.id = employment.engineer_id
JOIN engineer_role  ON engineer_role.engineer_id = engineer.id  AND engineer_role.held_during @> $1::date
JOIN rate_card      ON rate_card.level = engineer_role.level    AND rate_card.effective_during @> $1::date
JOIN allocation     ON allocation.engineer_id = engineer.id     AND allocation.allocated_during @> $1::date
JOIN project        ON project.id = allocation.project_id       AND project.active_during @> $1::date
JOIN contract       ON contract.id = project.contract_id        AND contract.term @> $1::date
JOIN client         ON client.id = contract.client_id
WHERE employment.employed_during @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM leave
    WHERE leave.engineer_id = engineer.id AND leave.on_leave_during @> $1::date
  )
ORDER BY engineer.name, project.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `board_leave` query
/// defined in `./src/tempo/server/sql/board_leave.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type BoardLeaveRow {
  BoardLeaveRow(
    engineer: String,
    level: Option(Int),
    kind: String,
    valid_from: Date,
    valid_to: Date,
  )
}

/// board_leave.sql — engineers on leave on the date.
/// The companion to board_engaged.sql: that query suppresses anyone with a covering
/// `leave` fact; this one selects exactly those engineers so the board can render
/// them as "On leave: <kind>".
///
/// Their underlying allocation still exists; it is deliberately not joined here —
/// leave overrides the engagement in the read model. The level (and hence the
/// charge story) is still resolved so the row stays informative.
///
/// Ranges decomposed to plain `date`s at the boundary: valid_from/valid_to are
/// the leave period's `lower()/upper()`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn board_leave(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(BoardLeaveRow), pog.QueryError) {
  let decoder = {
    use engineer <- decode.field(0, decode.string)
    use level <- decode.field(1, decode.optional(decode.int))
    use kind <- decode.field(2, decode.string)
    use valid_from <- decode.field(3, pog.calendar_date_decoder())
    use valid_to <- decode.field(4, pog.calendar_date_decoder())
    decode.success(BoardLeaveRow(
      engineer:,
      level:,
      kind:,
      valid_from:,
      valid_to:,
    ))
  }

  "-- board_leave.sql — engineers on leave on the date.
-- The companion to board_engaged.sql: that query suppresses anyone with a covering
-- `leave` fact; this one selects exactly those engineers so the board can render
-- them as \"On leave: <kind>\".
--
-- Their underlying allocation still exists; it is deliberately not joined here —
-- leave overrides the engagement in the read model. The level (and hence the
-- charge story) is still resolved so the row stays informative.
--
-- Ranges decomposed to plain `date`s at the boundary: valid_from/valid_to are
-- the leave period's `lower()/upper()`.
SELECT
  engineer.name AS engineer,
  engineer_role.level,
  leave.kind,
  lower(leave.on_leave_during) AS valid_from,
  upper(leave.on_leave_during) AS valid_to
FROM leave
JOIN engineer            ON engineer.id = leave.engineer_id
LEFT JOIN engineer_role  ON engineer_role.engineer_id = engineer.id AND engineer_role.held_during @> $1::date
WHERE leave.on_leave_during @> $1::date
ORDER BY engineer.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `board_unassigned` query
/// defined in `./src/tempo/server/sql/board_unassigned.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type BoardUnassignedRow {
  BoardUnassignedRow(engineer: String, level: Int)
}

/// board_unassigned.sql — employed engineers who are NOT allocated and NOT
/// on leave on the date ($1::date). The third board slice alongside
/// board_engaged (engaged) and board_leave (on leave); the client renders
/// these as "Unassigned".
///
/// INNER JOIN engineer_role so `level` is non-null: an employed engineer always
/// has a role in the seed (engineer_role spans employment). All columns non-null,
/// so the row decodes without Option plumbing.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn board_unassigned(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(BoardUnassignedRow), pog.QueryError) {
  let decoder = {
    use engineer <- decode.field(0, decode.string)
    use level <- decode.field(1, decode.int)
    decode.success(BoardUnassignedRow(engineer:, level:))
  }

  "-- board_unassigned.sql — employed engineers who are NOT allocated and NOT
-- on leave on the date ($1::date). The third board slice alongside
-- board_engaged (engaged) and board_leave (on leave); the client renders
-- these as \"Unassigned\".
--
-- INNER JOIN engineer_role so `level` is non-null: an employed engineer always
-- has a role in the seed (engineer_role spans employment). All columns non-null,
-- so the row decodes without Option plumbing.
SELECT
  engineer.name AS engineer,
  engineer_role.level
FROM employment
JOIN engineer       ON engineer.id = employment.engineer_id
JOIN engineer_role  ON engineer_role.engineer_id = engineer.id AND engineer_role.held_during @> $1::date
WHERE employment.employed_during @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM allocation
    WHERE allocation.engineer_id = engineer.id AND allocation.allocated_during @> $1::date
  )
  AND NOT EXISTS (
    SELECT 1 FROM leave
    WHERE leave.engineer_id = engineer.id AND leave.on_leave_during @> $1::date
  )
ORDER BY engineer.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `contract_create` query
/// defined in `./src/tempo/server/sql/contract_create.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ContractCreateRow {
  ContractCreateRow(id: Int)
}

/// contract_create.sql — assert a new client engagement (sign_contract).
///
/// A plain INSERT (write pattern 1). The contract id is NOT generated: it is an
/// entity id reused across period-rows, so we mint a fresh one with
/// coalesce(max(id),0)+1. The command carries the client by NAME, resolved to
/// client_id via a subquery. term = daterange($2, $3, '[)') is the engagement
/// window; $3 may be NULL for an open-ended term.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn contract_create(
  db: pog.Connection,
  arg_1: String,
  arg_2: Date,
  arg_3: Date,
) -> Result(pog.Returned(ContractCreateRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(ContractCreateRow(id:))
  }

  "-- contract_create.sql — assert a new client engagement (sign_contract).
--
-- A plain INSERT (write pattern 1). The contract id is NOT generated: it is an
-- entity id reused across period-rows, so we mint a fresh one with
-- coalesce(max(id),0)+1. The command carries the client by NAME, resolved to
-- client_id via a subquery. term = daterange($2, $3, '[)') is the engagement
-- window; $3 may be NULL for an open-ended term.
INSERT INTO contract (id, client_id, term)
VALUES (
  (SELECT coalesce(max(id), 0) + 1 FROM contract),
  (SELECT id FROM client WHERE name = $1),
  daterange($2::date, $3::date, '[)')
)
RETURNING id;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

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

/// employment_open.sql — assert ongoing employment (open-ended).
///
/// Step 2 of onboarding. The fact is ongoing, so `employed_during` runs from the
/// start date to NULL ("the end of time"): daterange($2::date, NULL, '[)'). Only
/// scalar `date` params cross the Squirrel boundary; the range is built in SQL.
/// $1 = engineer_id, $2 = start date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn employment_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- employment_open.sql — assert ongoing employment (open-ended).
--
-- Step 2 of onboarding. The fact is ongoing, so `employed_during` runs from the
-- start date to NULL (\"the end of time\"): daterange($2::date, NULL, '[)'). Only
-- scalar `date` params cross the Squirrel boundary; the range is built in SQL.
-- $1 = engineer_id, $2 = start date.
INSERT INTO employment (engineer_id, employed_during)
VALUES ($1, daterange($2::date, NULL, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_create` query
/// defined in `./src/tempo/server/sql/engineer_create.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerCreateRow {
  EngineerCreateRow(id: Int)
}

/// engineer_create.sql — mint a new engineer identity.
///
/// Step 1 of onboarding (identity → employment → role, each contained in the
/// last by its PERIOD FK). `engineer.id` is GENERATED ALWAYS AS IDENTITY, so the
/// caller never supplies it; RETURNING hands back the minted id to thread into
/// the employment and role inserts. $1 = name.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_create(
  db: pog.Connection,
  arg_1: String,
) -> Result(pog.Returned(EngineerCreateRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(EngineerCreateRow(id:))
  }

  "-- engineer_create.sql — mint a new engineer identity.
--
-- Step 1 of onboarding (identity → employment → role, each contained in the
-- last by its PERIOD FK). `engineer.id` is GENERATED ALWAYS AS IDENTITY, so the
-- caller never supplies it; RETURNING hands back the minted id to thread into
-- the employment and role inserts. $1 = name.
INSERT INTO engineer (name)
VALUES ($1)
RETURNING id;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_role_change.sql — promote/change an engineer's level from a date onward.
///
/// Change pattern (one statement, no read). FOR PORTION OF intersects [effective,
/// ∞) with the role version in effect, so the new level lands on [effective,
/// row.upper) and PG re-inserts the [row.lower, effective) leftover at the old
/// level. The `held_during @> $3::date` filter confines the edit to the version
/// in effect at `effective`; a separately scheduled future version doesn't
/// contain `effective`, so WHERE excludes it and TO NULL cannot clobber it.
/// $1 = engineer_id, $2 = new level, $3 = effective date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_role_change(
  db: pog.Connection,
  engineer_id: Int,
  level: Int,
  arg_3: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_role_change.sql — promote/change an engineer's level from a date onward.
--
-- Change pattern (one statement, no read). FOR PORTION OF intersects [effective,
-- ∞) with the role version in effect, so the new level lands on [effective,
-- row.upper) and PG re-inserts the [row.lower, effective) leftover at the old
-- level. The `held_during @> $3::date` filter confines the edit to the version
-- in effect at `effective`; a separately scheduled future version doesn't
-- contain `effective`, so WHERE excludes it and TO NULL cannot clobber it.
-- $1 = engineer_id, $2 = new level, $3 = effective date.
UPDATE engineer_role
   FOR PORTION OF held_during FROM $3::date TO NULL
   SET level = $2
 WHERE engineer_id = $1 AND held_during @> $3::date;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.int(level))
  |> pog.parameter(pog.calendar_date(arg_3))
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

/// engineer_role_open.sql — assert an ongoing engineer role (open-ended).
///
/// Step 3 of onboarding. `held_during` runs from the start date to NULL. The
/// PERIOD FK engineer_role_within_employment is the backstop: the role can only
/// be held while the engineer is employed. The range is built in SQL so only
/// scalar params cross the boundary.
/// $1 = engineer_id, $2 = level, $3 = start date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_role_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_role_open.sql — assert an ongoing engineer role (open-ended).
--
-- Step 3 of onboarding. `held_during` runs from the start date to NULL. The
-- PERIOD FK engineer_role_within_employment is the backstop: the role can only
-- be held while the engineer is employed. The range is built in SQL so only
-- scalar params cross the boundary.
-- $1 = engineer_id, $2 = level, $3 = start date.
INSERT INTO engineer_role (engineer_id, level, held_during)
VALUES ($1, $2, daterange($3::date, NULL, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `event_log_append` query
/// defined in `./src/tempo/server/sql/event_log_append.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EventLogAppendRow {
  EventLogAppendRow(id: Int)
}

/// event_log_append.sql — append one provenance row (§5a, §4, ADR-021).
///
/// `dispatch` writes exactly one of these per applied command, in the same
/// transaction as the temporal fact writes, so facts and journal commit together
/// or not at all. `occurred_at` defaults to now() (SYSTEM time); `id` is returned
/// as the order applied. The command is re-encoded via the shared codecs as
/// `payload`, cast to jsonb at the boundary.
/// $1 = actor, $2 = operation tag, $3 = summary, $4 = payload (json text).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn event_log_append(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: String,
  arg_4: Json,
) -> Result(pog.Returned(EventLogAppendRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(EventLogAppendRow(id:))
  }

  "-- event_log_append.sql — append one provenance row (§5a, §4, ADR-021).
--
-- `dispatch` writes exactly one of these per applied command, in the same
-- transaction as the temporal fact writes, so facts and journal commit together
-- or not at all. `occurred_at` defaults to now() (SYSTEM time); `id` is returned
-- as the order applied. The command is re-encoded via the shared codecs as
-- `payload`, cast to jsonb at the boundary.
-- $1 = actor, $2 = operation tag, $3 = summary, $4 = payload (json text).
INSERT INTO event_log (actor, operation, summary, payload)
VALUES ($1, $2, $3, $4::jsonb)
RETURNING id;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(json.to_string(arg_4)))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `event_log_list` query
/// defined in `./src/tempo/server/sql/event_log_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EventLogListRow {
  EventLogListRow(
    id: Int,
    occurred_at: String,
    actor: String,
    operation: String,
    summary: String,
    payload: String,
  )
}

/// event_log_list.sql — read the journal newest-first (§5a; GET /api/events).
///
/// The full provenance feed for the operations console. `occurred_at` and
/// `payload` are rendered to `text` at the boundary (timestamptz / jsonb don't
/// need a Squirrel type mapping); the client parses `payload` back through the
/// shared codecs. `id` doubles as the order applied, so DESC is newest-first.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn event_log_list(
  db: pog.Connection,
) -> Result(pog.Returned(EventLogListRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use occurred_at <- decode.field(1, decode.string)
    use actor <- decode.field(2, decode.string)
    use operation <- decode.field(3, decode.string)
    use summary <- decode.field(4, decode.string)
    use payload <- decode.field(5, decode.string)
    decode.success(EventLogListRow(
      id:,
      occurred_at:,
      actor:,
      operation:,
      summary:,
      payload:,
    ))
  }

  "-- event_log_list.sql — read the journal newest-first (§5a; GET /api/events).
--
-- The full provenance feed for the operations console. `occurred_at` and
-- `payload` are rendered to `text` at the boundary (timestamptz / jsonb don't
-- need a Squirrel type mapping); the client parses `payload` back through the
-- shared codecs. `id` doubles as the order applied, so DESC is newest-first.
SELECT
  id,
  occurred_at::text,
  actor,
  operation,
  summary,
  payload::text
FROM event_log
ORDER BY id DESC;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// leave_close_all.sql — cap all of an engineer's leave from a date (§5a, pattern 4).
///
/// DELETE … FOR PORTION OF over `[end, ∞)` with no `@>` filter: intentionally
/// broad so it caps every spanning leave row to `[lo, end)` and drops the
/// fully-future ones. Invoked by `terminate_employment` as the children-first
/// cascade reaches `leave` (before `engineer_role` / `employment`).
/// $1 = engineer_id, $2 = end.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_close_all(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- leave_close_all.sql — cap all of an engineer's leave from a date (§5a, pattern 4).
--
-- DELETE … FOR PORTION OF over `[end, ∞)` with no `@>` filter: intentionally
-- broad so it caps every spanning leave row to `[lo, end)` and drops the
-- fully-future ones. Invoked by `terminate_employment` as the children-first
-- cascade reaches `leave` (before `engineer_role` / `employment`).
-- $1 = engineer_id, $2 = end.
DELETE FROM leave
   FOR PORTION OF on_leave_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// leave_take.sql — assert an engineer's leave (§5a, pattern 1: Assert).
///
/// Plain INSERT of a bounded leave fact. The `on_leave_during` range is built in
/// SQL as `daterange($3::date, $4::date, '[)')` so only scalar `date` params cross
/// the Squirrel boundary. The PERIOD FK to `employment` (leave_within_employment)
/// backstops it: leave outside the engineer's employment is rejected.
/// $1 = engineer_id, $2 = kind, $3 = from, $4 = to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_take(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
  arg_4: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- leave_take.sql — assert an engineer's leave (§5a, pattern 1: Assert).
--
-- Plain INSERT of a bounded leave fact. The `on_leave_during` range is built in
-- SQL as `daterange($3::date, $4::date, '[)')` so only scalar `date` params cross
-- the Squirrel boundary. The PERIOD FK to `employment` (leave_within_employment)
-- backstops it: leave outside the engineer's employment is rejected.
-- $1 = engineer_id, $2 = kind, $3 = from, $4 = to.
INSERT INTO leave (engineer_id, kind, on_leave_during)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_create` query
/// defined in `./src/tempo/server/sql/project_create.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectCreateRow {
  ProjectCreateRow(id: Int)
}

/// project_create.sql — assert a new project under a contract (start_project).
///
/// A plain INSERT (write pattern 1). The project id is NOT generated: it is an
/// entity id reused across period-rows, so we mint a fresh one with
/// coalesce(max(id),0)+1. The project runs under an existing contract_id ($1)
/// and is contained by it via the project_within_contract PERIOD FK.
/// active_during = daterange($3, $4, '[)'); $4 may be NULL for an open run.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_create(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
  arg_4: Date,
) -> Result(pog.Returned(ProjectCreateRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(ProjectCreateRow(id:))
  }

  "-- project_create.sql — assert a new project under a contract (start_project).
--
-- A plain INSERT (write pattern 1). The project id is NOT generated: it is an
-- entity id reused across period-rows, so we mint a fresh one with
-- coalesce(max(id),0)+1. The project runs under an existing contract_id ($1)
-- and is contained by it via the project_within_contract PERIOD FK.
-- active_during = daterange($3, $4, '[)'); $4 may be NULL for an open run.
INSERT INTO project (id, contract_id, name, active_during)
VALUES (
  (SELECT coalesce(max(id), 0) + 1 FROM project),
  $1,
  $2,
  daterange($3::date, $4::date, '[)')
)
RETURNING id;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// rate_card_for_portion_of.sql — surgical charge-rate edit.
///
/// Bump a level's day_rate for PART of its validity via FOR PORTION OF: PG splits
/// the covering rate_card row, changing only the [$1, $2) sub-period and carving
/// off the unchanged before/after remainder as their own rows. The boundaries are
/// plain `date` params cast in SQL; $3 is the new rate, $4 the level.
///
/// PG reports `UPDATE 1` even when it produces extra rows, so never infer a split
/// from the affected-row count — read the rows back instead.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn rate_card_for_portion_of(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Date,
  day_rate: Float,
  arg_4: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- rate_card_for_portion_of.sql — surgical charge-rate edit.
--
-- Bump a level's day_rate for PART of its validity via FOR PORTION OF: PG splits
-- the covering rate_card row, changing only the [$1, $2) sub-period and carving
-- off the unchanged before/after remainder as their own rows. The boundaries are
-- plain `date` params cast in SQL; $3 is the new rate, $4 the level.
--
-- PG reports `UPDATE 1` even when it produces extra rows, so never infer a split
-- from the affected-row count — read the rows back instead.
UPDATE rate_card
   FOR PORTION OF effective_during FROM $1::date TO $2::date
   SET day_rate = $3
 WHERE level = $4;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.float(day_rate))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// rate_card_revise.sql — change a level's day_rate from $1 onward.
///
/// CHANGE write: re-rate the version of a level in effect on $1 for the open
/// span [$1, ∞) via FOR PORTION OF. The `@>` guard confines the update to the
/// single rate_card row covering $1, so a separately-scheduled future version of
/// the same level stays untouched; PG carves off the unchanged [start, $1)
/// remainder as its own row. $1 is the effective date, $2 the new rate, $3 the
/// level.
///
/// PG reports `UPDATE 1` even when it produces an extra remainder row, so never
/// infer a split from the affected-row count — read the rows back instead.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn rate_card_revise(
  db: pog.Connection,
  arg_1: Date,
  day_rate: Float,
  level: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- rate_card_revise.sql — change a level's day_rate from $1 onward.
--
-- CHANGE write: re-rate the version of a level in effect on $1 for the open
-- span [$1, ∞) via FOR PORTION OF. The `@>` guard confines the update to the
-- single rate_card row covering $1, so a separately-scheduled future version of
-- the same level stays untouched; PG carves off the unchanged [start, $1)
-- remainder as its own row. $1 is the effective date, $2 the new rate, $3 the
-- level.
--
-- PG reports `UPDATE 1` even when it produces an extra remainder row, so never
-- infer a split from the affected-row count — read the rows back instead.
UPDATE rate_card
   FOR PORTION OF effective_during FROM $1::date TO NULL
   SET day_rate = $2
 WHERE level = $3
   AND effective_during @> $1::date;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.float(day_rate))
  |> pog.parameter(pog.int(level))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// timesheet_delete.sql — step 1 of the temporal upsert.
///
/// `ON CONFLICT` cannot target the WITHOUT OVERLAPS PK (it is a GiST exclusion
/// constraint, not a plain unique index), so re-entry is delete-then-insert run in
/// ONE transaction by the handler (see timesheet_write.sql). This removes whatever
/// row *covers* the day, using the same `@> $3::date` containment the PK enforces,
/// so it is correct regardless of the stored range's exact bounds.
///
/// First entry deletes 0 rows (a harmless no-op); re-entry deletes 1. Never branch
/// on the affected-row count. $1 = engineer_id, $2 = project_id, $3 = the day.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn timesheet_delete(
  db: pog.Connection,
  engineer_id: Int,
  project_id: Int,
  arg_3: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- timesheet_delete.sql — step 1 of the temporal upsert.
--
-- `ON CONFLICT` cannot target the WITHOUT OVERLAPS PK (it is a GiST exclusion
-- constraint, not a plain unique index), so re-entry is delete-then-insert run in
-- ONE transaction by the handler (see timesheet_write.sql). This removes whatever
-- row *covers* the day, using the same `@> $3::date` containment the PK enforces,
-- so it is correct regardless of the stored range's exact bounds.
--
-- First entry deletes 0 rows (a harmless no-op); re-entry deletes 1. Never branch
-- on the affected-row count. $1 = engineer_id, $2 = project_id, $3 = the day.
DELETE FROM timesheet
WHERE engineer_id = $1
  AND project_id  = $2
  AND work_day @> $3::date;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `timesheet_form` query
/// defined in `./src/tempo/server/sql/timesheet_form.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type TimesheetFormRow {
  TimesheetFormRow(
    project_id: Int,
    project: String,
    fraction: Float,
    hours: Float,
    valid_from: Date,
    valid_to: Date,
  )
}

/// timesheet_form.sql — my allocations as of a day, with any hours already logged.
/// Only projects the engineer is actually on as of $2::date
/// are returned; on a day covered by leave the result is empty, so the form offers
/// nothing (leave takes precedence over an allocation). A project the engineer has
/// rolled off is simply absent — the negative case the PERIOD FK also backstops on
/// write.
///
/// $1 = engineer_id, $2 = the day. `hours` is COALESCEd to 0 for an un-logged
/// project so the form always has a value to render. Ranges are decomposed to
/// plain `date`s at the boundary: valid_from/valid_to are the allocation
/// engagement window.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn timesheet_form(
  db: pog.Connection,
  allocation_engineer_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(TimesheetFormRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use project <- decode.field(1, decode.string)
    use fraction <- decode.field(2, pog.numeric_decoder())
    use hours <- decode.field(3, pog.numeric_decoder())
    use valid_from <- decode.field(4, pog.calendar_date_decoder())
    use valid_to <- decode.field(5, pog.calendar_date_decoder())
    decode.success(TimesheetFormRow(
      project_id:,
      project:,
      fraction:,
      hours:,
      valid_from:,
      valid_to:,
    ))
  }

  "-- timesheet_form.sql — my allocations as of a day, with any hours already logged.
-- Only projects the engineer is actually on as of $2::date
-- are returned; on a day covered by leave the result is empty, so the form offers
-- nothing (leave takes precedence over an allocation). A project the engineer has
-- rolled off is simply absent — the negative case the PERIOD FK also backstops on
-- write.
--
-- $1 = engineer_id, $2 = the day. `hours` is COALESCEd to 0 for an un-logged
-- project so the form always has a value to render. Ranges are decomposed to
-- plain `date`s at the boundary: valid_from/valid_to are the allocation
-- engagement window.
SELECT
  project.id AS project_id,
  project.name AS project,
  allocation.fraction,
  COALESCE(timesheet.hours, 0) AS hours,
  lower(allocation.allocated_during) AS valid_from,
  upper(allocation.allocated_during) AS valid_to
FROM allocation
JOIN project ON project.id = allocation.project_id AND project.active_during @> $2::date
LEFT JOIN timesheet
  ON timesheet.engineer_id = allocation.engineer_id
 AND timesheet.project_id  = allocation.project_id
 AND timesheet.work_day @> $2::date
WHERE allocation.engineer_id = $1 AND allocation.allocated_during @> $2::date
  AND NOT EXISTS (
    SELECT 1 FROM leave
    WHERE leave.engineer_id = $1 AND leave.on_leave_during @> $2::date
  )
ORDER BY project.name;
"
  |> pog.query
  |> pog.parameter(pog.int(allocation_engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// timesheet_write.sql — step 2 of the temporal upsert.
///
/// Insert a single-day timesheet row. The `work_day` range is built in SQL as
/// `daterange($3::date, $3::date + 1, '[)')` so the function only ever sees scalar
/// `date` params — no daterange type crosses the Squirrel boundary.
///
/// The PERIOD FK to `allocation` is the backstop: a day with no covering allocation
/// is rejected. The handler runs timesheet_delete.sql then this INSERT in one
/// transaction, so a rejected insert rolls back the delete and the prior row
/// survives intact. $1 = engineer_id, $2 = project_id, $3 = the day, $4 = hours.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn timesheet_write(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: Date,
  arg_4: Float,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- timesheet_write.sql — step 2 of the temporal upsert.
--
-- Insert a single-day timesheet row. The `work_day` range is built in SQL as
-- `daterange($3::date, $3::date + 1, '[)')` so the function only ever sees scalar
-- `date` params — no daterange type crosses the Squirrel boundary.
--
-- The PERIOD FK to `allocation` is the backstop: a day with no covering allocation
-- is rejected. The handler runs timesheet_delete.sql then this INSERT in one
-- transaction, so a rejected insert rolls back the delete and the prior row
-- survives intact. $1 = engineer_id, $2 = project_id, $3 = the day, $4 = hours.
INSERT INTO timesheet (engineer_id, project_id, work_day, hours)
VALUES ($1, $2, daterange($3::date, $3::date + 1, '[)'), $4);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
