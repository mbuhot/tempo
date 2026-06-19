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
  coalesce(engineer.name, '') AS engineer,
  engineer_role.level,
  coalesce(project.title, '') AS project,
  coalesce(client.name, '') AS client,
  allocation.fraction,
  rate_card.day_rate,
  lower(allocation.allocated_during) AS valid_from,
  upper(allocation.allocated_during) AS valid_to
FROM employment
JOIN engineer_current engineer ON engineer.id = employment.engineer_id
JOIN engineer_role  ON engineer_role.engineer_id = engineer.id  AND engineer_role.held_during @> $1::date
JOIN rate_card      ON rate_card.level = engineer_role.level    AND rate_card.effective_during @> $1::date
JOIN allocation     ON allocation.engineer_id = engineer.id     AND allocation.allocated_during @> $1::date
JOIN project_run    ON project_run.project_id = allocation.project_id  AND project_run.active_during @> $1::date
JOIN project_current project ON project.id = project_run.project_id
JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id  AND contract_terms.term @> $1::date
JOIN client_current client ON client.id = contract_terms.client_id
WHERE employment.employed_during @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM leave
    WHERE leave.engineer_id = engineer.id AND leave.on_leave_during @> $1::date
  )
ORDER BY engineer.name, project.title;
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
  coalesce(engineer.name, '') AS engineer,
  engineer_role.level,
  leave.kind,
  lower(leave.on_leave_during) AS valid_from,
  upper(leave.on_leave_during) AS valid_to
FROM leave
JOIN engineer_current engineer ON engineer.id = leave.engineer_id
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
  coalesce(engineer.name, '') AS engineer,
  engineer_role.level
FROM employment
JOIN engineer_current engineer ON engineer.id = employment.engineer_id
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

/// A row you get from running the `client_profile_current` query
/// defined in `./src/tempo/server/sql/client_profile_current.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ClientProfileCurrentRow {
  ClientProfileCurrentRow(client_id: Int, name: String)
}

/// client_profile_current.sql — a client's CURRENT profile (latest read).
///
/// The most-recently-effective client_profile row for one client: DISTINCT ON
/// ordered by the start of recorded_during descending. Append-only + WITHOUT
/// OVERLAPS means the row with the greatest start is the one whose [effective,
/// NULL) span is in force. Scalar columns only — recorded_during bounds are not
/// exposed (the read record is scalar-only). $1 = client_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn client_profile_current(
  db: pog.Connection,
  client_id: Int,
) -> Result(pog.Returned(ClientProfileCurrentRow), pog.QueryError) {
  let decoder = {
    use client_id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(ClientProfileCurrentRow(client_id:, name:))
  }

  "-- client_profile_current.sql — a client's CURRENT profile (latest read).
--
-- The most-recently-effective client_profile row for one client: DISTINCT ON
-- ordered by the start of recorded_during descending. Append-only + WITHOUT
-- OVERLAPS means the row with the greatest start is the one whose [effective,
-- NULL) span is in force. Scalar columns only — recorded_during bounds are not
-- exposed (the read record is scalar-only). $1 = client_id.
SELECT DISTINCT ON (client_id)
  client_id,
  name
FROM client_profile
WHERE client_id = $1
ORDER BY client_id, lower(recorded_during) DESC;
"
  |> pog.query
  |> pog.parameter(pog.int(client_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// client_profile_open.sql — step 2 of the profile Change (and the row the seed
/// writes).
///
/// Insert the new full profile row over [$3, NULL): daterange($3::date, NULL,
/// '[)'), so only scalar params cross the Squirrel boundary. Run after
/// client_profile_close has carved [$3, NULL) out of the covering row, so the
/// WITHOUT OVERLAPS PK is satisfied. $1 = client_id, $2 = name, $3 = effective date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn client_profile_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- client_profile_open.sql — step 2 of the profile Change (and the row the seed
-- writes).
--
-- Insert the new full profile row over [$3, NULL): daterange($3::date, NULL,
-- '[)'), so only scalar params cross the Squirrel boundary. Run after
-- client_profile_close has carved [$3, NULL) out of the covering row, so the
-- WITHOUT OVERLAPS PK is satisfied. $1 = client_id, $2 = name, $3 = effective date.
INSERT INTO client_profile
  (client_id, name, recorded_during)
VALUES ($1, $2, daterange($3::date, NULL, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// client_profile_revise.sql — record a new client profile from $2 onward in ONE
/// statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
/// value on the [$2, NULL) portion of the row covering $2; PG carves off the
/// unchanged [start, $2) remainder as its own row. The `@>` guard confines it to the
/// single covering row. $1 = client_id, $2 = effective date, $3 = name.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn client_profile_revise(
  db: pog.Connection,
  client_id: Int,
  arg_2: Date,
  name: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- client_profile_revise.sql — record a new client profile from $2 onward in ONE
-- statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
-- value on the [$2, NULL) portion of the row covering $2; PG carves off the
-- unchanged [start, $2) remainder as its own row. The `@>` guard confines it to the
-- single covering row. $1 = client_id, $2 = effective date, $3 = name.
UPDATE client_profile
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET name = $3
 WHERE client_id = $1
   AND recorded_during @> $2::date;
"
  |> pog.query
  |> pog.parameter(pog.int(client_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(name))
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

/// contract_create.sql — mint a new contract identity (ID-ONLY anchor).
///
/// Step 1 of sign_contract (anchor → terms). The contract id is an entity id reused
/// across the contract_terms period-rows; there is no IDENTITY on the anchor, so we
/// mint a fresh one with coalesce(max(id),0)+1 and RETURNING hands it back to thread
/// into the terms insert.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn contract_create(
  db: pog.Connection,
) -> Result(pog.Returned(ContractCreateRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(ContractCreateRow(id:))
  }

  "-- contract_create.sql — mint a new contract identity (ID-ONLY anchor).
--
-- Step 1 of sign_contract (anchor → terms). The contract id is an entity id reused
-- across the contract_terms period-rows; there is no IDENTITY on the anchor, so we
-- mint a fresh one with coalesce(max(id),0)+1 and RETURNING hands it back to thread
-- into the terms insert.
INSERT INTO contract (id)
VALUES ((SELECT coalesce(max(id), 0) + 1 FROM contract))
RETURNING id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// contract_terms_open.sql — open a contract's term (the engagement window).
///
/// Step 2 of sign_contract: insert the contract_terms row over [$3, $4) for contract
/// $1, resolving the client by NAME to its id. The NAME left the `client` anchor for
/// the edit-grouped client_profile fact, so the resolver reads it through the
/// `client_current` view (latest profile per client). term = daterange($3, $4, '[)')
/// is the engagement window; $4 may be NULL for an open-ended term. $1 = contract_id,
/// $2 = client name, $3 = valid_from, $4 = valid_to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn contract_terms_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
  arg_4: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- contract_terms_open.sql — open a contract's term (the engagement window).
--
-- Step 2 of sign_contract: insert the contract_terms row over [$3, $4) for contract
-- $1, resolving the client by NAME to its id. The NAME left the `client` anchor for
-- the edit-grouped client_profile fact, so the resolver reads it through the
-- `client_current` view (latest profile per client). term = daterange($3, $4, '[)')
-- is the engagement window; $4 may be NULL for an open-ended term. $1 = contract_id,
-- $2 = client name, $3 = valid_from, $4 = valid_to.
INSERT INTO contract_terms (contract_id, client_id, term)
VALUES (
  $1,
  (SELECT id FROM client_current WHERE name = $2),
  daterange($3::date, $4::date, '[)')
);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
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

/// A row you get from running the `engineer_banking_current` query
/// defined in `./src/tempo/server/sql/engineer_banking_current.sql`.
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

/// engineer_banking_open.sql — step 2 of the banking Change.
///
/// Insert the new full banking row over [$6, NULL). account_no is text (leading
/// zeros preserved). Only scalar params cross the boundary; the range is built in
/// SQL. $1 = engineer_id, $2 = bank, $3 = branch, $4 = account_no,
/// $5 = account_name, $6 = effective date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_banking_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_banking_open.sql — step 2 of the banking Change.
--
-- Insert the new full banking row over [$6, NULL). account_no is text (leading
-- zeros preserved). Only scalar params cross the boundary; the range is built in
-- SQL. $1 = engineer_id, $2 = bank, $3 = branch, $4 = account_no,
-- $5 = account_name, $6 = effective date.
INSERT INTO engineer_banking
  (engineer_id, bank, branch, account_no, account_name, recorded_during)
VALUES ($1, $2, $3, $4, $5, daterange($6::date, NULL, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.calendar_date(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_banking_revise.sql — record new banking details from $2 onward in ONE
/// statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
/// values on the [$2, NULL) portion of the row covering $2; PG carves off the
/// unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
/// $1 = engineer_id, $2 = effective, $3 = bank, $4 = branch, $5 = account_no,
/// $6 = account_name.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_banking_revise(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Date,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  account_name: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_banking_revise.sql — record new banking details from $2 onward in ONE
-- statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
-- values on the [$2, NULL) portion of the row covering $2; PG carves off the
-- unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
-- $1 = engineer_id, $2 = effective, $3 = bank, $4 = branch, $5 = account_no,
-- $6 = account_name.
UPDATE engineer_banking
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET bank = $3, branch = $4, account_no = $5, account_name = $6
 WHERE engineer_id = $1
   AND recorded_during @> $2::date;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(account_name))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_contact_current` query
/// defined in `./src/tempo/server/sql/engineer_contact_current.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerContactCurrentRow {
  EngineerContactCurrentRow(
    engineer_id: Int,
    name: String,
    email: String,
    phone: String,
    postal_address: String,
  )
}

/// engineer_contact_current.sql — an engineer's CURRENT contact (latest read).
///
/// The most-recently-effective engineer_contact row for one engineer: DISTINCT ON
/// ordered by the start of recorded_during descending. Append-only + WITHOUT
/// OVERLAPS means the row with the greatest start is the one whose [effective,
/// NULL) span is in force. Scalar columns only — recorded_during bounds are not
/// exposed (the read record is scalar-only). $1 = engineer_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_contact_current(
  db: pog.Connection,
  engineer_id: Int,
) -> Result(pog.Returned(EngineerContactCurrentRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    use phone <- decode.field(3, decode.string)
    use postal_address <- decode.field(4, decode.string)
    decode.success(EngineerContactCurrentRow(
      engineer_id:,
      name:,
      email:,
      phone:,
      postal_address:,
    ))
  }

  "-- engineer_contact_current.sql — an engineer's CURRENT contact (latest read).
--
-- The most-recently-effective engineer_contact row for one engineer: DISTINCT ON
-- ordered by the start of recorded_during descending. Append-only + WITHOUT
-- OVERLAPS means the row with the greatest start is the one whose [effective,
-- NULL) span is in force. Scalar columns only — recorded_during bounds are not
-- exposed (the read record is scalar-only). $1 = engineer_id.
SELECT DISTINCT ON (engineer_id)
  engineer_id,
  name,
  email,
  phone,
  postal_address
FROM engineer_contact
WHERE engineer_id = $1
ORDER BY engineer_id, lower(recorded_during) DESC;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_contact_open.sql — step 2 of the contact Change (and the row Onboard
/// writes).
///
/// Insert the new full contact row over [$6, NULL): daterange($6::date, NULL,
/// '[)'), so only scalar params cross the Squirrel boundary. Run after
/// engineer_contact_close has carved [$6, NULL) out of the covering row, so the
/// WITHOUT OVERLAPS PK is satisfied. $1 = engineer_id, $2 = name, $3 = email,
/// $4 = phone, $5 = postal_address, $6 = effective date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_contact_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_contact_open.sql — step 2 of the contact Change (and the row Onboard
-- writes).
--
-- Insert the new full contact row over [$6, NULL): daterange($6::date, NULL,
-- '[)'), so only scalar params cross the Squirrel boundary. Run after
-- engineer_contact_close has carved [$6, NULL) out of the covering row, so the
-- WITHOUT OVERLAPS PK is satisfied. $1 = engineer_id, $2 = name, $3 = email,
-- $4 = phone, $5 = postal_address, $6 = effective date.
INSERT INTO engineer_contact
  (engineer_id, name, email, phone, postal_address, recorded_during)
VALUES ($1, $2, $3, $4, $5, daterange($6::date, NULL, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.calendar_date(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_contact_revise.sql — record new contact details from $2 onward in ONE
/// statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
/// values on the [$2, NULL) portion of the row covering $2; PG carves off the
/// unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
/// $1 = engineer_id, $2 = effective, $3 = name, $4 = email, $5 = phone, $6 = postal.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_contact_revise(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Date,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  postal_address: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_contact_revise.sql — record new contact details from $2 onward in ONE
-- statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
-- values on the [$2, NULL) portion of the row covering $2; PG carves off the
-- unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
-- $1 = engineer_id, $2 = effective, $3 = name, $4 = email, $5 = phone, $6 = postal.
UPDATE engineer_contact
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET name = $3, email = $4, phone = $5, postal_address = $6
 WHERE engineer_id = $1
   AND recorded_during @> $2::date;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(postal_address))
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

/// engineer_create.sql — mint a new engineer identity (ID-ONLY anchor).
///
/// Step 1 of onboarding (identity → employment → role, each contained in the last
/// by its PERIOD FK; the engineer's NAME is now a separate engineer_contact fact,
/// written alongside, NOT a column here). `engineer.id` is GENERATED ALWAYS AS
/// IDENTITY, so the caller supplies nothing; RETURNING hands back the minted id to
/// thread into the employment, role, and contact inserts.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_create(
  db: pog.Connection,
) -> Result(pog.Returned(EngineerCreateRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(EngineerCreateRow(id:))
  }

  "-- engineer_create.sql — mint a new engineer identity (ID-ONLY anchor).
--
-- Step 1 of onboarding (identity → employment → role, each contained in the last
-- by its PERIOD FK; the engineer's NAME is now a separate engineer_contact fact,
-- written alongside, NOT a column here). `engineer.id` is GENERATED ALWAYS AS
-- IDENTITY, so the caller supplies nothing; RETURNING hands back the minted id to
-- thread into the employment, role, and contact inserts.
INSERT INTO engineer DEFAULT VALUES
RETURNING id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_emergency_current` query
/// defined in `./src/tempo/server/sql/engineer_emergency_current.sql`.
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

/// engineer_emergency_open.sql — step 2 of the emergency Change.
///
/// Insert the new full emergency row over [$6, NULL). Only scalar params cross the
/// boundary; the range is built in SQL. $1 = engineer_id, $2 = relation,
/// $3 = name, $4 = phone, $5 = email, $6 = effective date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_emergency_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_emergency_open.sql — step 2 of the emergency Change.
--
-- Insert the new full emergency row over [$6, NULL). Only scalar params cross the
-- boundary; the range is built in SQL. $1 = engineer_id, $2 = relation,
-- $3 = name, $4 = phone, $5 = email, $6 = effective date.
INSERT INTO engineer_emergency
  (engineer_id, relation, name, phone, email, recorded_during)
VALUES ($1, $2, $3, $4, $5, daterange($6::date, NULL, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.calendar_date(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_emergency_revise.sql — record a new emergency contact from $2 onward in
/// ONE statement (the Change pattern, like salary_revise). FOR PORTION OF sets the
/// new values on the [$2, NULL) portion of the row covering $2; PG carves off the
/// unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
/// $1 = engineer_id, $2 = effective, $3 = relation, $4 = name, $5 = phone, $6 = email.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_emergency_revise(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Date,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  email: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_emergency_revise.sql — record a new emergency contact from $2 onward in
-- ONE statement (the Change pattern, like salary_revise). FOR PORTION OF sets the
-- new values on the [$2, NULL) portion of the row covering $2; PG carves off the
-- unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
-- $1 = engineer_id, $2 = effective, $3 = relation, $4 = name, $5 = phone, $6 = email.
UPDATE engineer_emergency
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET relation = $3, name = $4, phone = $5, email = $6
 WHERE engineer_id = $1
   AND recorded_during @> $2::date;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(email))
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
  EventLogAppendRow(
    id: Int,
    occurred_at: String,
    actor: String,
    operation: String,
    summary: String,
    payload: String,
  )
}

/// event_log_append.sql — append one provenance row (§5a, §4, ADR-021).
///
/// `dispatch` writes exactly one of these per applied command, in the same
/// transaction as the temporal fact writes, so facts and journal commit together
/// or not at all. `occurred_at` defaults to now() (SYSTEM time). The whole row is
/// returned (id doubles as the order applied; occurred_at/payload rendered to text
/// at the boundary) so the caller maps it straight to the shared read Event —
/// never a guessed "newest row". The command is re-encoded via the shared codecs
/// as `payload`, cast to jsonb at the boundary.
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
    use occurred_at <- decode.field(1, decode.string)
    use actor <- decode.field(2, decode.string)
    use operation <- decode.field(3, decode.string)
    use summary <- decode.field(4, decode.string)
    use payload <- decode.field(5, decode.string)
    decode.success(EventLogAppendRow(
      id:,
      occurred_at:,
      actor:,
      operation:,
      summary:,
      payload:,
    ))
  }

  "-- event_log_append.sql — append one provenance row (§5a, §4, ADR-021).
--
-- `dispatch` writes exactly one of these per applied command, in the same
-- transaction as the temporal fact writes, so facts and journal commit together
-- or not at all. `occurred_at` defaults to now() (SYSTEM time). The whole row is
-- returned (id doubles as the order applied; occurred_at/payload rendered to text
-- at the boundary) so the caller maps it straight to the shared read Event —
-- never a guessed \"newest row\". The command is re-encoded via the shared codecs
-- as `payload`, cast to jsonb at the boundary.
-- $1 = actor, $2 = operation tag, $3 = summary, $4 = payload (json text).
INSERT INTO event_log (actor, operation, summary, payload)
VALUES ($1, $2, $3, $4::jsonb)
RETURNING id, occurred_at::text, actor, operation, summary, payload::text;
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

/// event_log_list.sql — the provenance journal up to an as-of date, newest first
/// (§5a; GET /api/events; the operations console feed).
///
/// Param: $1 = the as-of date (the slider). `occurred_at` is SYSTEM time — when the
/// operation was recorded. The demo seed stamps each operation with the date it
/// would naturally have been entered (timesheets at the end of their week, invoices
/// and payroll at month end; see tempo/seed_financials), so the journal reads as a
/// realistic timeline and scrubbing the slider shows only what had been recorded by
/// that date — anything recorded after $1 is hidden, rewinding the feed with the
/// rest of the UI.
///
/// `occurred_at` and `payload` are rendered to `text` at the boundary (timestamptz /
/// jsonb don't need a Squirrel type mapping); the client parses `payload` back
/// through the shared codecs. `id` doubles as the order applied, so DESC is
/// newest-first.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn event_log_list(
  db: pog.Connection,
  arg_1: Date,
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

  "-- event_log_list.sql — the provenance journal up to an as-of date, newest first
-- (§5a; GET /api/events; the operations console feed).
--
-- Param: $1 = the as-of date (the slider). `occurred_at` is SYSTEM time — when the
-- operation was recorded. The demo seed stamps each operation with the date it
-- would naturally have been entered (timesheets at the end of their week, invoices
-- and payroll at month end; see tempo/seed_financials), so the journal reads as a
-- realistic timeline and scrubbing the slider shows only what had been recorded by
-- that date — anything recorded after $1 is hidden, rewinding the feed with the
-- rest of the UI.
--
-- `occurred_at` and `payload` are rendered to `text` at the boundary (timestamptz /
-- jsonb don't need a Squirrel type mapping); the client parses `payload` back
-- through the shared codecs. `id` doubles as the order applied, so DESC is
-- newest-first.
SELECT
  id,
  occurred_at::text,
  actor,
  operation,
  summary,
  payload::text
FROM event_log
WHERE occurred_at::date <= $1::date
ORDER BY id DESC;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// event_log_set_occurred_at.sql — backdate one journal row's occurred_at to a
/// simulated entry date. Used ONLY by the demo seed (tempo/seed_financials) to give
/// the journal a realistic timeline: each operation recorded when it would naturally
/// have been entered (timesheets at the end of their week, invoices and payroll at
/// month end) rather than all at the instant the seed ran. Production records
/// occurred_at as the real wall clock (event_log_append.sql) and never calls this.
///
/// $1 = event id, $2 = the date to record it as (set to midnight of that day).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn event_log_set_occurred_at(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- event_log_set_occurred_at.sql — backdate one journal row's occurred_at to a
-- simulated entry date. Used ONLY by the demo seed (tempo/seed_financials) to give
-- the journal a realistic timeline: each operation recorded when it would naturally
-- have been entered (timesheets at the end of their week, invoices and payroll at
-- month end) rather than all at the instant the seed ran. Production records
-- occurred_at as the real wall clock (event_log_append.sql) and never calls this.
--
-- $1 = event id, $2 = the date to record it as (set to midnight of that day).
UPDATE event_log SET occurred_at = $2::date WHERE id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_billing_lines` query
/// defined in `./src/tempo/server/sql/invoice_billing_lines.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceBillingLinesRow {
  InvoiceBillingLinesRow(
    engineer_id: Int,
    engineer: String,
    level: Int,
    day_rate: Float,
    days: Float,
    amount: Float,
  )
}

/// invoice_billing_lines.sql — the contract-agreed billable lines for a project
/// over a month (FR-F1, FR-F2: the temporal centerpiece). One row per (engineer,
/// level) who worked the project during the month, at the rate the CONTRACT agreed.
///
/// Params: $1 = project_id (entity id), $2 = month start (date), $3 = month end
/// (date, exclusive). The month range is built in SQL as daterange($2, $3, '[)'),
/// so only scalar dates cross the Squirrel boundary.
///
/// The agreed rate (FR-F2). The day_rate is rate_card[level] AS OF
/// lower(contract.term) — the contract's signing date — NOT as-of the billing
/// month. If the rate card has been revised since the contract was signed, the
/// invoice still bills the older agreed rate. `agreed_date` is computed once from
/// the contract active over the month (project ⊂ contract, both overlapping the
/// month) and pinned for every line.
///
/// Day counting. A daterange's day count is upper - lower (integer days; PG returns
/// e.g. 30 for a June [1st, next-1st) range). The billable sub-period for a line is
/// the THREE-way intersection (the * operator) of the allocation, the engineer_role
/// (level) version, and the month — so a mid-month promotion splits the work into
/// one sub-period per level, each billed at that level's agreed rate. Empty
/// intersections (a role version that does not actually overlap the allocation
/// within the month) are dropped via NOT isempty.
///
/// days   = Σ over sub-periods of  fraction × (upper - lower)
/// amount = Σ over sub-periods of  fraction × (upper - lower) × day_rate
///
/// Aggregated per (engineer, level): a single allocation under one level yields one
/// row; a promotion mid-month yields two rows (one per level) for that engineer.
///
/// Assumptions:
/// * Exactly one contract is active over the month for the project (project ⊂
/// contract by construction); LIMIT 1 pins the agreed date if the schema ever
/// admits more.
/// * Leave does NOT reduce billing (billing is allocation-fraction-weighted
/// working days; leave is a payroll concern, paid in full — FR-F6).
/// * Calendar days, not business days: "working days in the month" is the day
/// width of the intersection, matching the day-count convention used elsewhere.
/// * rate_card has a version covering agreed_date for every billed level (true in
/// the seed: the baseline rate card opens at the earliest contract date).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_billing_lines(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
  arg_3: Date,
) -> Result(pog.Returned(InvoiceBillingLinesRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use engineer <- decode.field(1, decode.string)
    use level <- decode.field(2, decode.int)
    use day_rate <- decode.field(3, pog.numeric_decoder())
    use days <- decode.field(4, pog.numeric_decoder())
    use amount <- decode.field(5, pog.numeric_decoder())
    decode.success(InvoiceBillingLinesRow(
      engineer_id:,
      engineer:,
      level:,
      day_rate:,
      days:,
      amount:,
    ))
  }

  "-- invoice_billing_lines.sql — the contract-agreed billable lines for a project
-- over a month (FR-F1, FR-F2: the temporal centerpiece). One row per (engineer,
-- level) who worked the project during the month, at the rate the CONTRACT agreed.
--
-- Params: $1 = project_id (entity id), $2 = month start (date), $3 = month end
-- (date, exclusive). The month range is built in SQL as daterange($2, $3, '[)'),
-- so only scalar dates cross the Squirrel boundary.
--
-- The agreed rate (FR-F2). The day_rate is rate_card[level] AS OF
-- lower(contract.term) — the contract's signing date — NOT as-of the billing
-- month. If the rate card has been revised since the contract was signed, the
-- invoice still bills the older agreed rate. `agreed_date` is computed once from
-- the contract active over the month (project ⊂ contract, both overlapping the
-- month) and pinned for every line.
--
-- Day counting. A daterange's day count is upper - lower (integer days; PG returns
-- e.g. 30 for a June [1st, next-1st) range). The billable sub-period for a line is
-- the THREE-way intersection (the * operator) of the allocation, the engineer_role
-- (level) version, and the month — so a mid-month promotion splits the work into
-- one sub-period per level, each billed at that level's agreed rate. Empty
-- intersections (a role version that does not actually overlap the allocation
-- within the month) are dropped via NOT isempty.
--
--   days   = Σ over sub-periods of  fraction × (upper - lower)
--   amount = Σ over sub-periods of  fraction × (upper - lower) × day_rate
--
-- Aggregated per (engineer, level): a single allocation under one level yields one
-- row; a promotion mid-month yields two rows (one per level) for that engineer.
--
-- Assumptions:
--   * Exactly one contract is active over the month for the project (project ⊂
--     contract by construction); LIMIT 1 pins the agreed date if the schema ever
--     admits more.
--   * Leave does NOT reduce billing (billing is allocation-fraction-weighted
--     working days; leave is a payroll concern, paid in full — FR-F6).
--   * Calendar days, not business days: \"working days in the month\" is the day
--     width of the intersection, matching the day-count convention used elsewhere.
--   * rate_card has a version covering agreed_date for every billed level (true in
--     the seed: the baseline rate card opens at the earliest contract date).
WITH params AS (
  SELECT
    $1::int AS project_id,
    daterange($2::date, $3::date, '[)') AS month
),
agreed AS (
  -- the contract active over the month, and its agreed date = lower(term)
  SELECT lower(contract_terms.term) AS agreed_date
  FROM params
  JOIN project_run    ON project_run.project_id = params.project_id
                     AND project_run.active_during && params.month
  JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
                     AND contract_terms.term && params.month
  LIMIT 1
),
sub AS (
  -- each allocation ∩ engineer_role(level) ∩ month sub-period for the project
  SELECT
    allocation.engineer_id,
    engineer_role.level,
    allocation.fraction,
    allocation.allocated_during * engineer_role.held_during * params.month
      AS sub_period
  FROM params
  JOIN allocation    ON allocation.project_id = params.project_id
                    AND allocation.allocated_during && params.month
  JOIN engineer_role ON engineer_role.engineer_id = allocation.engineer_id
                    AND engineer_role.held_during && allocation.allocated_during
                    AND engineer_role.held_during && params.month
)
SELECT
  sub.engineer_id,
  coalesce(engineer.name, '') AS engineer,
  sub.level,
  rate_card.day_rate::numeric AS day_rate,
  sum(sub.fraction * (upper(sub.sub_period) - lower(sub.sub_period)))::numeric
    AS days,
  sum(sub.fraction * (upper(sub.sub_period) - lower(sub.sub_period))
      * rate_card.day_rate)::numeric AS amount
FROM sub
CROSS JOIN agreed
JOIN engineer_current engineer ON engineer.id = sub.engineer_id
JOIN rate_card ON rate_card.level = sub.level
              AND rate_card.effective_during @> agreed.agreed_date
WHERE NOT isempty(sub.sub_period)
GROUP BY sub.engineer_id, engineer.name, sub.level, rate_card.day_rate
ORDER BY engineer.name, sub.level;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_create` query
/// defined in `./src/tempo/server/sql/invoice_create.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceCreateRow {
  InvoiceCreateRow(id: Int)
}

/// invoice_create.sql — mint a new invoice identity (ID-ONLY anchor).
///
/// Step 1 of draft_invoice (anchor → subject → status → lines). `invoice.id` is
/// GENERATED ALWAYS AS IDENTITY, so the caller supplies nothing; RETURNING hands
/// back the minted id to thread into the invoice_subject, status, and line inserts.
/// The durable subject (project_id, billing_period) is written separately into the
/// 1:1 immutable invoice_subject fact by invoice_subject_insert.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_create(
  db: pog.Connection,
) -> Result(pog.Returned(InvoiceCreateRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(InvoiceCreateRow(id:))
  }

  "-- invoice_create.sql — mint a new invoice identity (ID-ONLY anchor).
--
-- Step 1 of draft_invoice (anchor → subject → status → lines). `invoice.id` is
-- GENERATED ALWAYS AS IDENTITY, so the caller supplies nothing; RETURNING hands
-- back the minted id to thread into the invoice_subject, status, and line inserts.
-- The durable subject (project_id, billing_period) is written separately into the
-- 1:1 immutable invoice_subject fact by invoice_subject_insert.
INSERT INTO invoice DEFAULT VALUES
RETURNING id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_header` query
/// defined in `./src/tempo/server/sql/invoice_header.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceHeaderRow {
  InvoiceHeaderRow(
    id: Int,
    project: String,
    client: String,
    billing_from: Date,
    billing_to: Date,
    status: String,
    total: Float,
  )
}

/// invoice_header.sql — one invoice's header for the detail read model
/// (GET /api/invoices/:id). Same projection as invoice_list (project + client
/// name, billing month, status AS OF $2, line total) for a single invoice.
///
/// Params: $1 = invoice_id, $2 = as-of date. The status shown is the row covering
/// $2 (FR-F4). Unlike the list, the status JOIN is LEFT so the header still
/// returns for an as-of date with no covering status (status NULL), letting the
/// detail endpoint distinguish "no such invoice" (no row) from "exists but no
/// status as of this date" (a row with NULL status). The caller coalesces a NULL
/// status to "" before mapping to the shared read type.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_header(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(InvoiceHeaderRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use project <- decode.field(1, decode.string)
    use client <- decode.field(2, decode.string)
    use billing_from <- decode.field(3, pog.calendar_date_decoder())
    use billing_to <- decode.field(4, pog.calendar_date_decoder())
    use status <- decode.field(5, decode.string)
    use total <- decode.field(6, pog.numeric_decoder())
    decode.success(InvoiceHeaderRow(
      id:,
      project:,
      client:,
      billing_from:,
      billing_to:,
      status:,
      total:,
    ))
  }

  "-- invoice_header.sql — one invoice's header for the detail read model
-- (GET /api/invoices/:id). Same projection as invoice_list (project + client
-- name, billing month, status AS OF $2, line total) for a single invoice.
--
-- Params: $1 = invoice_id, $2 = as-of date. The status shown is the row covering
-- $2 (FR-F4). Unlike the list, the status JOIN is LEFT so the header still
-- returns for an as-of date with no covering status (status NULL), letting the
-- detail endpoint distinguish \"no such invoice\" (no row) from \"exists but no
-- status as of this date\" (a row with NULL status). The caller coalesces a NULL
-- status to \"\" before mapping to the shared read type.
SELECT
  invoice.id,
  coalesce((
    SELECT project.title FROM project_current project
     WHERE project.id = invoice_subject.project_id
     LIMIT 1
  ), '') AS project,
  coalesce((
    SELECT client.name
      FROM project_run
      JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
      JOIN client_current client ON client.id = contract_terms.client_id
     WHERE project_run.project_id = invoice_subject.project_id
     LIMIT 1
  ), '') AS client,
  lower(invoice_subject.billing_period) AS billing_from,
  upper(invoice_subject.billing_period) AS billing_to,
  coalesce((
    SELECT invoice_status.status FROM invoice_status
     WHERE invoice_status.invoice_id = invoice.id
       AND invoice_status.status_during @> $2::date
  ), '') AS status,
  coalesce((
    SELECT sum(invoice_line.amount)
      FROM invoice_line
     WHERE invoice_line.invoice_id = invoice.id
  ), 0)::numeric AS total
FROM invoice
JOIN invoice_subject ON invoice_subject.invoice_id = invoice.id
WHERE invoice.id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// invoice_line_insert.sql — append one billed line to an invoice.
///
/// A plain INSERT (write pattern 1). The line is pre-computed by the command: the
/// day_rate is resolved from rate_card for the engineer's level AS OF the
/// contract term's lower bound (FR-F2), not the invoice month. $1 = invoice_id,
/// $2 = engineer_id, $3 = level, $4 = day_rate, $5 = days, $6 = amount.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_line_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: Int,
  arg_4: Float,
  arg_5: Float,
  arg_6: Float,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_line_insert.sql — append one billed line to an invoice.
--
-- A plain INSERT (write pattern 1). The line is pre-computed by the command: the
-- day_rate is resolved from rate_card for the engineer's level AS OF the
-- contract term's lower bound (FR-F2), not the invoice month. $1 = invoice_id,
-- $2 = engineer_id, $3 = level, $4 = day_rate, $5 = days, $6 = amount.
INSERT INTO invoice_line (invoice_id, engineer_id, level, day_rate, days, amount)
VALUES ($1, $2, $3, $4, $5, $6);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.int(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.parameter(pog.float(arg_5))
  |> pog.parameter(pog.float(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_lines` query
/// defined in `./src/tempo/server/sql/invoice_lines.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceLinesRow {
  InvoiceLinesRow(
    engineer: String,
    level: Int,
    day_rate: Float,
    days: Float,
    amount: Float,
  )
}

/// invoice_lines.sql — an invoice's snapshot lines for the detail read model
/// (GET /api/invoices/:id). The plain rows computed when the invoice was drafted
/// (invoice_line), joined to the engineer name; not a recomputation (PRD §8: an
/// issued invoice's lines do not change).
///
/// Param: $1 = invoice_id. Ordered as the billing query emitted them (engineer,
/// level) so a promotion's two lines stay adjacent and the wire order is
/// deterministic for the client and tests.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_lines(
  db: pog.Connection,
  invoice_line_invoice_id: Int,
) -> Result(pog.Returned(InvoiceLinesRow), pog.QueryError) {
  let decoder = {
    use engineer <- decode.field(0, decode.string)
    use level <- decode.field(1, decode.int)
    use day_rate <- decode.field(2, pog.numeric_decoder())
    use days <- decode.field(3, pog.numeric_decoder())
    use amount <- decode.field(4, pog.numeric_decoder())
    decode.success(InvoiceLinesRow(engineer:, level:, day_rate:, days:, amount:))
  }

  "-- invoice_lines.sql — an invoice's snapshot lines for the detail read model
-- (GET /api/invoices/:id). The plain rows computed when the invoice was drafted
-- (invoice_line), joined to the engineer name; not a recomputation (PRD §8: an
-- issued invoice's lines do not change).
--
-- Param: $1 = invoice_id. Ordered as the billing query emitted them (engineer,
-- level) so a promotion's two lines stay adjacent and the wire order is
-- deterministic for the client and tests.
SELECT
  coalesce(engineer.name, '') AS engineer,
  invoice_line.level,
  invoice_line.day_rate::numeric AS day_rate,
  invoice_line.days::numeric AS days,
  invoice_line.amount::numeric AS amount
FROM invoice_line
JOIN engineer_current engineer ON engineer.id = invoice_line.engineer_id
WHERE invoice_line.invoice_id = $1
ORDER BY engineer.name, invoice_line.level;
"
  |> pog.query
  |> pog.parameter(pog.int(invoice_line_invoice_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_list` query
/// defined in `./src/tempo/server/sql/invoice_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceListRow {
  InvoiceListRow(
    id: Int,
    project: String,
    client: String,
    billing_from: Date,
    billing_to: Date,
    status: String,
    total: Float,
  )
}

/// invoice_list.sql — the invoices-table read model (FR-F1/FR-F4). One row per
/// invoice: the durable subject (project + client name, billing month) plus its
/// status AS OF $1 and its line total (Σ invoice_line.amount).
///
/// Param: $1 = as-of date. The status shown is the row covering $1 via `@>`, so
/// scrubbing the slider back shows a `draft` before its issue date (FR-F4). An
/// invoice with no status covering $1 (e.g. as-of before the billing month) is
/// dropped — the status JOIN is not a LEFT JOIN, so only invoices that "exist as
/// of $1" are listed.
///
/// Name resolution. The durable subject (project_id, billing_period) lives in the
/// 1:1 immutable invoice_subject fact, INNER JOINed here. `project_id` is a project
/// ENTITY id whose names are stable across its period-rows in the seed, so a
/// correlated LIMIT-1 subquery picks one name without multiplying the row by every
/// period version. An invoice whose project entity has no project row at all yields
/// NULL names (coalesced to '').
///
/// Total. coalesce(Σ amount, 0) over the snapshot lines — an invoice drafted with
/// no billable lines totals 0 rather than vanishing.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_list(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(InvoiceListRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use project <- decode.field(1, decode.string)
    use client <- decode.field(2, decode.string)
    use billing_from <- decode.field(3, pog.calendar_date_decoder())
    use billing_to <- decode.field(4, pog.calendar_date_decoder())
    use status <- decode.field(5, decode.string)
    use total <- decode.field(6, pog.numeric_decoder())
    decode.success(InvoiceListRow(
      id:,
      project:,
      client:,
      billing_from:,
      billing_to:,
      status:,
      total:,
    ))
  }

  "-- invoice_list.sql — the invoices-table read model (FR-F1/FR-F4). One row per
-- invoice: the durable subject (project + client name, billing month) plus its
-- status AS OF $1 and its line total (Σ invoice_line.amount).
--
-- Param: $1 = as-of date. The status shown is the row covering $1 via `@>`, so
-- scrubbing the slider back shows a `draft` before its issue date (FR-F4). An
-- invoice with no status covering $1 (e.g. as-of before the billing month) is
-- dropped — the status JOIN is not a LEFT JOIN, so only invoices that \"exist as
-- of $1\" are listed.
--
-- Name resolution. The durable subject (project_id, billing_period) lives in the
-- 1:1 immutable invoice_subject fact, INNER JOINed here. `project_id` is a project
-- ENTITY id whose names are stable across its period-rows in the seed, so a
-- correlated LIMIT-1 subquery picks one name without multiplying the row by every
-- period version. An invoice whose project entity has no project row at all yields
-- NULL names (coalesced to '').
--
-- Total. coalesce(Σ amount, 0) over the snapshot lines — an invoice drafted with
-- no billable lines totals 0 rather than vanishing.
SELECT
  invoice.id,
  coalesce((
    SELECT project.title FROM project_current project
     WHERE project.id = invoice_subject.project_id
     LIMIT 1
  ), '') AS project,
  coalesce((
    SELECT client.name
      FROM project_run
      JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
      JOIN client_current client ON client.id = contract_terms.client_id
     WHERE project_run.project_id = invoice_subject.project_id
     LIMIT 1
  ), '') AS client,
  lower(invoice_subject.billing_period) AS billing_from,
  upper(invoice_subject.billing_period) AS billing_to,
  invoice_status.status,
  coalesce((
    SELECT sum(invoice_line.amount)
      FROM invoice_line
     WHERE invoice_line.invoice_id = invoice.id
  ), 0)::numeric AS total
FROM invoice
JOIN invoice_subject ON invoice_subject.invoice_id = invoice.id
JOIN invoice_status ON invoice_status.invoice_id = invoice.id
                   AND invoice_status.status_during @> $1::date
ORDER BY lower(invoice_subject.billing_period), invoice.id;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// invoice_status_close.sql — cap an invoice's current status at $2.
///
/// Close half of a status transition: `DELETE … FOR PORTION OF status_during
/// FROM $2 TO NULL` removes the [$2, ∞) tail of the open status, capping the
/// spanning row to [row.lower, $2) (Postgres re-inserts the before-leftover).
/// The caller then runs invoice_status_open to start the new status at $2.
/// Keyed to the invoice — the open span is the only one covering $2.
///
/// $1 = invoice_id, $2 = transition day (scalar date, cast in SQL).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_status_close(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_status_close.sql — cap an invoice's current status at $2.
--
-- Close half of a status transition: `DELETE … FOR PORTION OF status_during
-- FROM $2 TO NULL` removes the [$2, ∞) tail of the open status, capping the
-- spanning row to [row.lower, $2) (Postgres re-inserts the before-leftover).
-- The caller then runs invoice_status_open to start the new status at $2.
-- Keyed to the invoice — the open span is the only one covering $2.
--
-- $1 = invoice_id, $2 = transition day (scalar date, cast in SQL).
DELETE FROM invoice_status
   FOR PORTION OF status_during FROM $2::date TO NULL
 WHERE invoice_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_status_current` query
/// defined in `./src/tempo/server/sql/invoice_status_current.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceStatusCurrentRow {
  InvoiceStatusCurrentRow(status: String)
}

/// invoice_status_current.sql — the status of an invoice AS OF $2.
///
/// The transition guard: reads the single status row covering $2 via `@>` so the
/// command can validate the from-state before opening a new status. $1 is the
/// invoice_id, $2 the as-of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_status_current(
  db: pog.Connection,
  invoice_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(InvoiceStatusCurrentRow), pog.QueryError) {
  let decoder = {
    use status <- decode.field(0, decode.string)
    decode.success(InvoiceStatusCurrentRow(status:))
  }

  "-- invoice_status_current.sql — the status of an invoice AS OF $2.
--
-- The transition guard: reads the single status row covering $2 via `@>` so the
-- command can validate the from-state before opening a new status. $1 is the
-- invoice_id, $2 the as-of date.
SELECT status
  FROM invoice_status
 WHERE invoice_id = $1
   AND status_during @> $2::date;
"
  |> pog.query
  |> pog.parameter(pog.int(invoice_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// invoice_status_open.sql — open a status span for an invoice from $3 onward.
///
/// A plain INSERT (write pattern 1) starting an open-ended [$3, ∞) status
/// period. Used both to seed the initial status and, after invoice_status_close
/// caps the prior one, to open the new status during a transition. $1 is the
/// invoice_id, $2 the status, $3 the effective date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_status_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_status_open.sql — open a status span for an invoice from $3 onward.
--
-- A plain INSERT (write pattern 1) starting an open-ended [$3, ∞) status
-- period. Used both to seed the initial status and, after invoice_status_close
-- caps the prior one, to open the new status during a transition. $1 is the
-- invoice_id, $2 the status, $3 the effective date.
INSERT INTO invoice_status (invoice_id, status, status_during)
VALUES ($1, $2, daterange($3::date, NULL, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// invoice_subject_insert.sql — record an invoice's immutable subject (1:1 fact).
///
/// A plain INSERT (write pattern 1) into the 1:1 invoice_subject fact, keyed by the
/// minted invoice anchor id. The subject is set once at draft and never changed:
/// $1 = invoice_id, $2/$3 = the half-open [from, to) billing-month bounds, built
/// into a daterange in SQL. The invoice_subject_within_project PERIOD FK enforces
/// the billing month ⊂ the project's active run.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_subject_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: Date,
  arg_4: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_subject_insert.sql — record an invoice's immutable subject (1:1 fact).
--
-- A plain INSERT (write pattern 1) into the 1:1 invoice_subject fact, keyed by the
-- minted invoice anchor id. The subject is set once at draft and never changed:
-- $1 = invoice_id, $2/$3 = the half-open [from, to) billing-month bounds, built
-- into a daterange in SQL. The invoice_subject_within_project PERIOD FK enforces
-- the billing month ⊂ the project's active run.
INSERT INTO invoice_subject (invoice_id, project_id, billing_period)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
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

/// A row you get from running the `payroll_amounts` query
/// defined in `./src/tempo/server/sql/payroll_amounts.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PayrollAmountsRow {
  PayrollAmountsRow(
    engineer_id: Int,
    engineer: String,
    amount: Float,
    days: Float,
  )
}

/// payroll_amounts.sql — the prorated salary owed per employed engineer for a month
/// (FR-F5, FR-F6). One row per engineer employed at any point in the month.
///
/// Params: $1 = month start (date), $2 = month end (date, exclusive). The month
/// range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
/// Squirrel boundary.
///
/// Proration by day, split by level (FR-F6). The paid period is the intersection
/// (the * operator) of employment, the engineer_role (level) version, the salary
/// version, and the month. Splitting on BOTH the role version and the salary
/// version means a mid-month promotion is paid partly at each level's salary, and a
/// mid-month salary revision is honoured day-accurate within a level. A daterange's
/// day count is upper - lower (integer days; e.g. 30 for June). Days in the month
/// is likewise upper(month) - lower(month) (28..31), so the divisor is the actual
/// calendar length of the billed month.
///
/// amount = Σ over sub-periods of  monthly_salary[level] × days_in_subperiod
/// / days_in_month
/// days   = Σ over sub-periods of  days_in_subperiod   (the employed days in month)
///
/// Leave is IGNORED — full pay (FR-F6). The leave table is not consulted: a leave
/// period is paid at full salary, so payroll prorates only over employment, not over
/// "employment minus leave". A hire or termination mid-month clips the paid period
/// to the employed days (employment ∩ month); a promotion splits it.
///
/// Assumptions:
/// * salary has a version covering every (level, day) an engineer is employed in
/// the month (true in the seed: the baseline salary opens at the earliest
/// employment date). An employed day with no salary version yields no
/// sub-period and is silently unpaid — a seed/data gap, not a modelled state.
/// * engineer_role spans employment (every employed engineer has a level), so
/// every employed day is attributed to exactly one level via the intersection.
/// * Calendar days, not business days; full-month salary = monthly_salary when the
/// engineer is employed the whole month at one level.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_amounts(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Date,
) -> Result(pog.Returned(PayrollAmountsRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use engineer <- decode.field(1, decode.string)
    use amount <- decode.field(2, pog.numeric_decoder())
    use days <- decode.field(3, pog.numeric_decoder())
    decode.success(PayrollAmountsRow(engineer_id:, engineer:, amount:, days:))
  }

  "-- payroll_amounts.sql — the prorated salary owed per employed engineer for a month
-- (FR-F5, FR-F6). One row per engineer employed at any point in the month.
--
-- Params: $1 = month start (date), $2 = month end (date, exclusive). The month
-- range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
-- Squirrel boundary.
--
-- Proration by day, split by level (FR-F6). The paid period is the intersection
-- (the * operator) of employment, the engineer_role (level) version, the salary
-- version, and the month. Splitting on BOTH the role version and the salary
-- version means a mid-month promotion is paid partly at each level's salary, and a
-- mid-month salary revision is honoured day-accurate within a level. A daterange's
-- day count is upper - lower (integer days; e.g. 30 for June). Days in the month
-- is likewise upper(month) - lower(month) (28..31), so the divisor is the actual
-- calendar length of the billed month.
--
--   amount = Σ over sub-periods of  monthly_salary[level] × days_in_subperiod
--                                                          / days_in_month
--   days   = Σ over sub-periods of  days_in_subperiod   (the employed days in month)
--
-- Leave is IGNORED — full pay (FR-F6). The leave table is not consulted: a leave
-- period is paid at full salary, so payroll prorates only over employment, not over
-- \"employment minus leave\". A hire or termination mid-month clips the paid period
-- to the employed days (employment ∩ month); a promotion splits it.
--
-- Assumptions:
--   * salary has a version covering every (level, day) an engineer is employed in
--     the month (true in the seed: the baseline salary opens at the earliest
--     employment date). An employed day with no salary version yields no
--     sub-period and is silently unpaid — a seed/data gap, not a modelled state.
--   * engineer_role spans employment (every employed engineer has a level), so
--     every employed day is attributed to exactly one level via the intersection.
--   * Calendar days, not business days; full-month salary = monthly_salary when the
--     engineer is employed the whole month at one level.
WITH params AS (
  SELECT daterange($1::date, $2::date, '[)') AS month
),
sub AS (
  -- each employment ∩ engineer_role(level) ∩ salary-version ∩ month sub-period
  SELECT
    employment.engineer_id,
    salary.monthly_salary,
    employment.employed_during
      * engineer_role.held_during
      * salary.effective_during
      * params.month AS sub_period
  FROM params
  JOIN employment    ON employment.employed_during && params.month
  JOIN engineer_role ON engineer_role.engineer_id = employment.engineer_id
                    AND engineer_role.held_during && employment.employed_during
                    AND engineer_role.held_during && params.month
  JOIN salary        ON salary.level = engineer_role.level
                    AND salary.effective_during && engineer_role.held_during
                    AND salary.effective_during && params.month
)
SELECT
  sub.engineer_id,
  coalesce(engineer.name, '') AS engineer,
  sum(sub.monthly_salary * (upper(sub.sub_period) - lower(sub.sub_period))
      / (upper(params.month) - lower(params.month)))::numeric AS amount,
  sum(upper(sub.sub_period) - lower(sub.sub_period))::numeric AS days
FROM sub
CROSS JOIN params
JOIN engineer_current engineer ON engineer.id = sub.engineer_id
WHERE NOT isempty(sub.sub_period)
GROUP BY sub.engineer_id, engineer.name
ORDER BY engineer.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// payroll_line_insert.sql — append one engineer's line to a payroll run.
///
/// A plain INSERT (write pattern 1). The amount and days are pre-computed by the
/// command from salary and the engineer's worked/employed days in the run period.
/// $1 = run_id, $2 = engineer_id, $3 = amount, $4 = days.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_line_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: Float,
  arg_4: Float,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- payroll_line_insert.sql — append one engineer's line to a payroll run.
--
-- A plain INSERT (write pattern 1). The amount and days are pre-computed by the
-- command from salary and the engineer's worked/employed days in the run period.
-- $1 = run_id, $2 = engineer_id, $3 = amount, $4 = days.
INSERT INTO payroll_line (run_id, engineer_id, amount, days)
VALUES ($1, $2, $3, $4);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.float(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `payroll_lines` query
/// defined in `./src/tempo/server/sql/payroll_lines.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PayrollLinesRow {
  PayrollLinesRow(engineer: String, amount: Float, days: Float)
}

/// payroll_lines.sql — the persisted payroll lines for a period (GET /api/payroll).
/// Reads the SNAPSHOT lines a RunPayroll produced (payroll_line), joined to the
/// engineer name — not a recomputation (the read returns what was paid, the
/// write-time analogue of payroll_amounts).
///
/// Params: $1 = period start (date), $2 = period end (date, exclusive). The period
/// range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
/// Squirrel boundary. Lines for every run whose period OVERLAPS the window are
/// returned (the caller queries month-aligned windows, so in practice exactly the
/// one run for that month). Ordered by engineer name for a deterministic wire
/// order; an engineer with lines in two overlapping runs would appear twice (not
/// expected for month-aligned windows).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_lines(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Date,
) -> Result(pog.Returned(PayrollLinesRow), pog.QueryError) {
  let decoder = {
    use engineer <- decode.field(0, decode.string)
    use amount <- decode.field(1, pog.numeric_decoder())
    use days <- decode.field(2, pog.numeric_decoder())
    decode.success(PayrollLinesRow(engineer:, amount:, days:))
  }

  "-- payroll_lines.sql — the persisted payroll lines for a period (GET /api/payroll).
-- Reads the SNAPSHOT lines a RunPayroll produced (payroll_line), joined to the
-- engineer name — not a recomputation (the read returns what was paid, the
-- write-time analogue of payroll_amounts).
--
-- Params: $1 = period start (date), $2 = period end (date, exclusive). The period
-- range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
-- Squirrel boundary. Lines for every run whose period OVERLAPS the window are
-- returned (the caller queries month-aligned windows, so in practice exactly the
-- one run for that month). Ordered by engineer name for a deterministic wire
-- order; an engineer with lines in two overlapping runs would appear twice (not
-- expected for month-aligned windows).
WITH params AS (
  SELECT daterange($1::date, $2::date, '[)') AS period
)
SELECT
  coalesce(engineer.name, '') AS engineer,
  payroll_line.amount::numeric AS amount,
  payroll_line.days::numeric AS days
FROM params
JOIN payroll_period ON payroll_period.period && params.period
JOIN payroll_line   ON payroll_line.run_id = payroll_period.run_id
JOIN engineer_current engineer ON engineer.id = payroll_line.engineer_id
ORDER BY engineer.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// payroll_period_insert.sql — record a payroll run's immutable period (1:1 fact).
///
/// A plain INSERT (write pattern 1) into the 1:1 payroll_period fact, keyed by the
/// minted payroll_run anchor id. The period is set once at run and never changed:
/// $1 = run_id, $2/$3 = the half-open [from, to) month bounds, built into a daterange
/// in SQL. The payroll_period_no_overlap GiST exclusion forbids two runs whose
/// periods overlap.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_period_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
  arg_3: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- payroll_period_insert.sql — record a payroll run's immutable period (1:1 fact).
--
-- A plain INSERT (write pattern 1) into the 1:1 payroll_period fact, keyed by the
-- minted payroll_run anchor id. The period is set once at run and never changed:
-- $1 = run_id, $2/$3 = the half-open [from, to) month bounds, built into a daterange
-- in SQL. The payroll_period_no_overlap GiST exclusion forbids two runs whose
-- periods overlap.
INSERT INTO payroll_period (run_id, period)
VALUES ($1, daterange($2::date, $3::date, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `payroll_run_create` query
/// defined in `./src/tempo/server/sql/payroll_run_create.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PayrollRunCreateRow {
  PayrollRunCreateRow(id: Int)
}

/// payroll_run_create.sql — mint a new payroll run identity (ID-ONLY anchor).
///
/// Step 1 of run_payroll (anchor → period → lines). `payroll_run.id` is GENERATED
/// ALWAYS AS IDENTITY, so the caller supplies nothing; RETURNING hands back the
/// minted id to thread into the payroll_period and line inserts. The run's period is
/// written separately into the 1:1 immutable payroll_period fact by
/// payroll_period_insert.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_run_create(
  db: pog.Connection,
) -> Result(pog.Returned(PayrollRunCreateRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(PayrollRunCreateRow(id:))
  }

  "-- payroll_run_create.sql — mint a new payroll run identity (ID-ONLY anchor).
--
-- Step 1 of run_payroll (anchor → period → lines). `payroll_run.id` is GENERATED
-- ALWAYS AS IDENTITY, so the caller supplies nothing; RETURNING hands back the
-- minted id to thread into the payroll_period and line inserts. The run's period is
-- written separately into the 1:1 immutable payroll_period fact by
-- payroll_period_insert.
INSERT INTO payroll_run DEFAULT VALUES
RETURNING id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `pnl_rows` query
/// defined in `./src/tempo/server/sql/pnl_rows.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PnlRowsRow {
  PnlRowsRow(
    engineer_id: Int,
    engineer: String,
    revenue: Float,
    cost: Float,
    utilization_days: Float,
    employed_days: Float,
  )
}

/// pnl_rows.sql — the per-engineer P&L over a period (FR-F7, FR-F8). One row per
/// engineer employed at any point in the period, carrying the raw components the
/// caller turns into profit / margin % / utilization %.
///
/// Params: $1 = period start (date), $2 = period end (date, exclusive). The same
/// two dates serve as the period range (daterange($1, $2, '[)')) AND $2 is the
/// as-of instant for invoice status (the period's exclusive upper bound — "the
/// state at the close of the period"). Only scalar dates cross the boundary.
///
/// Returned components (caller computes the rest):
/// revenue          — Σ invoice_line.amount over invoices whose billing_period
/// OVERLAPS the period AND whose status AS OF $2 is issued or
/// paid. Revenue is recognized on issue (PRD §8), and the
/// as-of predicate (status_during @> $2) means scrubbing the
/// period end back before an issue date drops that revenue
/// (FR-F4 carried into the P&L).
/// cost             — Σ payroll_line.amount over payroll_runs whose period
/// OVERLAPS the period.
/// utilization_days — Σ allocation.fraction × days in (allocation ∩ employment ∩
/// period). Capacity-share numerator (PRD §8: capacity-based,
/// not hours-based — the timesheet is not consulted; leave does
/// not reduce it).
/// employed_days    — days in (employment ∩ period); the utilization denominator.
/// Caller computes utilization_pct = utilization_days /
/// employed_days, profit = revenue - cost, margin_pct =
/// profit / revenue.
///
/// A daterange's day count is upper - lower (integer days). The employed/util day
/// counts use the intersection (the * operator) of the relevant facts with the
/// period; empty intersections are dropped via NOT isempty.
///
/// The driving set is engineers EMPLOYED in the period (employed_days > 0): an
/// engineer with revenue or cost but no employment overlap is out of scope for the
/// period and would have a zero denominator. Revenue/cost/util attach via LEFT JOIN
/// and coalesce to 0, so an employed engineer with no invoices, no payroll, or no
/// allocation still appears (zeros), and the per-engineer rows sum to the statement
/// totals.
///
/// Assumptions:
/// * "Overlaps the period" (&&) for invoices/payroll, NOT containment: a billing
/// month or run period that straddles the P&L window contributes in full
/// (consistent with month-grained invoicing/payroll; the caller chooses
/// month/YTD windows aligned to month boundaries so straddling does not occur
/// in practice).
/// * An invoice has at most one status covering $2 (WITHOUT OVERLAPS guarantees
/// it); EXISTS over {issued, paid} is the recognition gate.
/// * revenue/cost are summed from the SNAPSHOT lines (invoice_line, payroll_line),
/// so they reflect what was billed/paid, not a recomputation (PRD §8).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn pnl_rows(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Date,
) -> Result(pog.Returned(PnlRowsRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use engineer <- decode.field(1, decode.string)
    use revenue <- decode.field(2, pog.numeric_decoder())
    use cost <- decode.field(3, pog.numeric_decoder())
    use utilization_days <- decode.field(4, pog.numeric_decoder())
    use employed_days <- decode.field(5, pog.numeric_decoder())
    decode.success(PnlRowsRow(
      engineer_id:,
      engineer:,
      revenue:,
      cost:,
      utilization_days:,
      employed_days:,
    ))
  }

  "-- pnl_rows.sql — the per-engineer P&L over a period (FR-F7, FR-F8). One row per
-- engineer employed at any point in the period, carrying the raw components the
-- caller turns into profit / margin % / utilization %.
--
-- Params: $1 = period start (date), $2 = period end (date, exclusive). The same
-- two dates serve as the period range (daterange($1, $2, '[)')) AND $2 is the
-- as-of instant for invoice status (the period's exclusive upper bound — \"the
-- state at the close of the period\"). Only scalar dates cross the boundary.
--
-- Returned components (caller computes the rest):
--   revenue          — Σ invoice_line.amount over invoices whose billing_period
--                      OVERLAPS the period AND whose status AS OF $2 is issued or
--                      paid. Revenue is recognized on issue (PRD §8), and the
--                      as-of predicate (status_during @> $2) means scrubbing the
--                      period end back before an issue date drops that revenue
--                      (FR-F4 carried into the P&L).
--   cost             — Σ payroll_line.amount over payroll_runs whose period
--                      OVERLAPS the period.
--   utilization_days — Σ allocation.fraction × days in (allocation ∩ employment ∩
--                      period). Capacity-share numerator (PRD §8: capacity-based,
--                      not hours-based — the timesheet is not consulted; leave does
--                      not reduce it).
--   employed_days    — days in (employment ∩ period); the utilization denominator.
--                      Caller computes utilization_pct = utilization_days /
--                      employed_days, profit = revenue - cost, margin_pct =
--                      profit / revenue.
--
-- A daterange's day count is upper - lower (integer days). The employed/util day
-- counts use the intersection (the * operator) of the relevant facts with the
-- period; empty intersections are dropped via NOT isempty.
--
-- The driving set is engineers EMPLOYED in the period (employed_days > 0): an
-- engineer with revenue or cost but no employment overlap is out of scope for the
-- period and would have a zero denominator. Revenue/cost/util attach via LEFT JOIN
-- and coalesce to 0, so an employed engineer with no invoices, no payroll, or no
-- allocation still appears (zeros), and the per-engineer rows sum to the statement
-- totals.
--
-- Assumptions:
--   * \"Overlaps the period\" (&&) for invoices/payroll, NOT containment: a billing
--     month or run period that straddles the P&L window contributes in full
--     (consistent with month-grained invoicing/payroll; the caller chooses
--     month/YTD windows aligned to month boundaries so straddling does not occur
--     in practice).
--   * An invoice has at most one status covering $2 (WITHOUT OVERLAPS guarantees
--     it); EXISTS over {issued, paid} is the recognition gate.
--   * revenue/cost are summed from the SNAPSHOT lines (invoice_line, payroll_line),
--     so they reflect what was billed/paid, not a recomputation (PRD §8).
WITH params AS (
  SELECT
    daterange($1::date, $2::date, '[)') AS period,
    $2::date AS as_of
),
emp AS (
  -- employed days in the period per engineer (employment ∩ period)
  SELECT
    employment.engineer_id,
    sum(upper(employment.employed_during * params.period)
        - lower(employment.employed_during * params.period))::numeric
      AS employed_days
  FROM params
  JOIN employment ON employment.employed_during && params.period
  GROUP BY employment.engineer_id
),
util AS (
  -- Σ fraction × days in allocation ∩ employment ∩ period (capacity share)
  SELECT
    allocation.engineer_id,
    sum(allocation.fraction
        * (upper(allocation.allocated_during * employment.employed_during
                 * params.period)
           - lower(allocation.allocated_during * employment.employed_during
                   * params.period)))::numeric AS utilization_days
  FROM params
  JOIN allocation ON allocation.allocated_during && params.period
  JOIN employment ON employment.engineer_id = allocation.engineer_id
                 AND employment.employed_during && allocation.allocated_during
                 AND employment.employed_during && params.period
  WHERE NOT isempty(allocation.allocated_during * employment.employed_during
                    * params.period)
  GROUP BY allocation.engineer_id
),
rev AS (
  -- revenue: invoice_line.amount for invoices overlapping the period whose status
  -- AS OF $2 (period end) is issued or paid
  SELECT
    invoice_line.engineer_id,
    sum(invoice_line.amount)::numeric AS revenue
  FROM params
  JOIN invoice_subject ON invoice_subject.billing_period && params.period
  JOIN invoice_line    ON invoice_line.invoice_id = invoice_subject.invoice_id
  WHERE EXISTS (
    SELECT 1 FROM invoice_status
    WHERE invoice_status.invoice_id = invoice_subject.invoice_id
      AND invoice_status.status_during @> params.as_of
      AND invoice_status.status IN ('issued', 'paid')
  )
  GROUP BY invoice_line.engineer_id
),
cost AS (
  -- cost: payroll_line.amount for payroll runs overlapping the period
  SELECT
    payroll_line.engineer_id,
    sum(payroll_line.amount)::numeric AS cost
  FROM params
  JOIN payroll_period ON payroll_period.period && params.period
  JOIN payroll_line   ON payroll_line.run_id = payroll_period.run_id
  GROUP BY payroll_line.engineer_id
)
SELECT
  emp.engineer_id,
  coalesce(engineer.name, '') AS engineer,
  coalesce(rev.revenue, 0)::numeric AS revenue,
  coalesce(cost.cost, 0)::numeric AS cost,
  coalesce(util.utilization_days, 0)::numeric AS utilization_days,
  emp.employed_days
FROM emp
JOIN engineer_current engineer ON engineer.id = emp.engineer_id
LEFT JOIN util ON util.engineer_id = emp.engineer_id
LEFT JOIN rev  ON rev.engineer_id = emp.engineer_id
LEFT JOIN cost ON cost.engineer_id = emp.engineer_id
ORDER BY engineer.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
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

/// project_create.sql — mint a new project identity (ID-ONLY anchor).
///
/// Step 1 of start_project (anchor → run → profile → plan, the run contained in its
/// contract by the project_within_contract PERIOD FK; the project's NAME is now a
/// project_profile fact and its budget/target a project_plan fact, both written
/// alongside, NOT columns here). The project id is an entity id reused across the
/// run/profile/plan period-rows; there is no IDENTITY on the anchor, so we mint a
/// fresh one with coalesce(max(id),0)+1 and RETURNING hands it back to thread into
/// the run, profile, and plan inserts.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_create(
  db: pog.Connection,
) -> Result(pog.Returned(ProjectCreateRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(ProjectCreateRow(id:))
  }

  "-- project_create.sql — mint a new project identity (ID-ONLY anchor).
--
-- Step 1 of start_project (anchor → run → profile → plan, the run contained in its
-- contract by the project_within_contract PERIOD FK; the project's NAME is now a
-- project_profile fact and its budget/target a project_plan fact, both written
-- alongside, NOT columns here). The project id is an entity id reused across the
-- run/profile/plan period-rows; there is no IDENTITY on the anchor, so we mint a
-- fresh one with coalesce(max(id),0)+1 and RETURNING hands it back to thread into
-- the run, profile, and plan inserts.
INSERT INTO project (id)
VALUES ((SELECT coalesce(max(id), 0) + 1 FROM project))
RETURNING id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_plan_current` query
/// defined in `./src/tempo/server/sql/project_plan_current.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectPlanCurrentRow {
  ProjectPlanCurrentRow(project_id: Int, budget: Float, target_completion: Date)
}

/// project_plan_current.sql — a project's CURRENT plan (latest read).
///
/// The most-recently-effective project_plan row for one project: DISTINCT ON ordered
/// by the start of planned_during descending. Append-only + WITHOUT OVERLAPS means
/// the row with the greatest start is the one whose [effective, NULL) span is in
/// force. Scalar columns only — planned_during bounds are not exposed (the read
/// record is scalar-only). $1 = project_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_plan_current(
  db: pog.Connection,
  project_id: Int,
) -> Result(pog.Returned(ProjectPlanCurrentRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use budget <- decode.field(1, pog.numeric_decoder())
    use target_completion <- decode.field(2, pog.calendar_date_decoder())
    decode.success(ProjectPlanCurrentRow(
      project_id:,
      budget:,
      target_completion:,
    ))
  }

  "-- project_plan_current.sql — a project's CURRENT plan (latest read).
--
-- The most-recently-effective project_plan row for one project: DISTINCT ON ordered
-- by the start of planned_during descending. Append-only + WITHOUT OVERLAPS means
-- the row with the greatest start is the one whose [effective, NULL) span is in
-- force. Scalar columns only — planned_during bounds are not exposed (the read
-- record is scalar-only). $1 = project_id.
SELECT DISTINCT ON (project_id)
  project_id,
  budget,
  target_completion
FROM project_plan
WHERE project_id = $1
ORDER BY project_id, lower(planned_during) DESC;
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_plan_open.sql — step 2 of the plan Change (and the row StartProject
/// writes).
///
/// Insert the new full plan row over [$4, NULL): daterange($4::date, NULL, '[)'), so
/// only scalar params cross the Squirrel boundary. Run after project_plan_close has
/// carved [$4, NULL) out of the covering row, so the WITHOUT OVERLAPS PK is
/// satisfied. $1 = project_id, $2 = budget, $3 = target_completion date, $4 =
/// effective date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_plan_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Float,
  arg_3: Date,
  arg_4: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_plan_open.sql — step 2 of the plan Change (and the row StartProject
-- writes).
--
-- Insert the new full plan row over [$4, NULL): daterange($4::date, NULL, '[)'), so
-- only scalar params cross the Squirrel boundary. Run after project_plan_close has
-- carved [$4, NULL) out of the covering row, so the WITHOUT OVERLAPS PK is
-- satisfied. $1 = project_id, $2 = budget, $3 = target_completion date, $4 =
-- effective date.
INSERT INTO project_plan
  (project_id, budget, target_completion, planned_during)
VALUES ($1, $2, $3::date, daterange($4::date, NULL, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.float(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_plan_revise.sql — record a new project plan from $2 onward in ONE
/// statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
/// values on the [$2, NULL) portion of the row covering $2; PG carves off the
/// unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
/// $1 = project_id, $2 = effective, $3 = budget, $4 = target_completion.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_plan_revise(
  db: pog.Connection,
  project_id: Int,
  arg_2: Date,
  arg_3: Float,
  arg_4: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_plan_revise.sql — record a new project plan from $2 onward in ONE
-- statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
-- values on the [$2, NULL) portion of the row covering $2; PG carves off the
-- unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
-- $1 = project_id, $2 = effective, $3 = budget, $4 = target_completion.
UPDATE project_plan
   FOR PORTION OF planned_during FROM $2::date TO NULL
   SET budget = $3, target_completion = $4::date
 WHERE project_id = $1
   AND planned_during @> $2::date;
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.float(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_profile_current` query
/// defined in `./src/tempo/server/sql/project_profile_current.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectProfileCurrentRow {
  ProjectProfileCurrentRow(project_id: Int, title: String, summary: String)
}

/// project_profile_current.sql — a project's CURRENT profile (latest read).
///
/// The most-recently-effective project_profile row for one project: DISTINCT ON
/// ordered by the start of recorded_during descending. Append-only + WITHOUT
/// OVERLAPS means the row with the greatest start is the one whose [effective, NULL)
/// span is in force. Scalar columns only — recorded_during bounds are not exposed
/// (the read record is scalar-only). $1 = project_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_profile_current(
  db: pog.Connection,
  project_id: Int,
) -> Result(pog.Returned(ProjectProfileCurrentRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use summary <- decode.field(2, decode.string)
    decode.success(ProjectProfileCurrentRow(project_id:, title:, summary:))
  }

  "-- project_profile_current.sql — a project's CURRENT profile (latest read).
--
-- The most-recently-effective project_profile row for one project: DISTINCT ON
-- ordered by the start of recorded_during descending. Append-only + WITHOUT
-- OVERLAPS means the row with the greatest start is the one whose [effective, NULL)
-- span is in force. Scalar columns only — recorded_during bounds are not exposed
-- (the read record is scalar-only). $1 = project_id.
SELECT DISTINCT ON (project_id)
  project_id,
  title,
  summary
FROM project_profile
WHERE project_id = $1
ORDER BY project_id, lower(recorded_during) DESC;
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_profile_open.sql — step 2 of the profile Change (and the row StartProject
/// writes).
///
/// Insert the new full profile row over [$4, NULL): daterange($4::date, NULL, '[)'),
/// so only scalar params cross the Squirrel boundary. Run after project_profile_close
/// has carved [$4, NULL) out of the covering row, so the WITHOUT OVERLAPS PK is
/// satisfied. $1 = project_id, $2 = title, $3 = summary, $4 = effective date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_profile_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: String,
  arg_4: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_profile_open.sql — step 2 of the profile Change (and the row StartProject
-- writes).
--
-- Insert the new full profile row over [$4, NULL): daterange($4::date, NULL, '[)'),
-- so only scalar params cross the Squirrel boundary. Run after project_profile_close
-- has carved [$4, NULL) out of the covering row, so the WITHOUT OVERLAPS PK is
-- satisfied. $1 = project_id, $2 = title, $3 = summary, $4 = effective date.
INSERT INTO project_profile
  (project_id, title, summary, recorded_during)
VALUES ($1, $2, $3, daterange($4::date, NULL, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_profile_revise.sql — record a new project profile from $2 onward in ONE
/// statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
/// values on the [$2, NULL) portion of the row covering $2; PG carves off the
/// unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
/// $1 = project_id, $2 = effective, $3 = title, $4 = summary.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_profile_revise(
  db: pog.Connection,
  project_id: Int,
  arg_2: Date,
  arg_3: String,
  summary: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_profile_revise.sql — record a new project profile from $2 onward in ONE
-- statement (the Change pattern, like salary_revise). FOR PORTION OF sets the new
-- values on the [$2, NULL) portion of the row covering $2; PG carves off the
-- unchanged [start, $2) remainder. The `@>` guard confines it to the covering row.
-- $1 = project_id, $2 = effective, $3 = title, $4 = summary.
UPDATE project_profile
   FOR PORTION OF recorded_during FROM $2::date TO NULL
   SET title = $3, summary = $4
 WHERE project_id = $1
   AND recorded_during @> $2::date;
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(summary))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_run_open.sql — open a project's run (existence/contract window).
///
/// Step 2 of start_project: insert the project_run row over [$3, $4) under contract
/// $2, contained by the contract's term via the project_within_contract PERIOD FK —
/// a run whose active period falls outside the contract's term is rejected by the
/// database. active_during = daterange($3, $4, '[)'); $4 may be NULL for an open run.
/// $1 = project_id, $2 = contract_id, $3 = valid_from, $4 = valid_to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_run_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: Date,
  arg_4: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_run_open.sql — open a project's run (existence/contract window).
--
-- Step 2 of start_project: insert the project_run row over [$3, $4) under contract
-- $2, contained by the contract's term via the project_within_contract PERIOD FK —
-- a run whose active period falls outside the contract's term is rejected by the
-- database. active_during = daterange($3, $4, '[)'); $4 may be NULL for an open run.
-- $1 = project_id, $2 = contract_id, $3 = valid_from, $4 = valid_to.
INSERT INTO project_run (project_id, contract_id, active_during)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'));
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
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

/// A row you get from running the `roster_clients` query
/// defined in `./src/tempo/server/sql/roster_clients.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RosterClientsRow {
  RosterClientsRow(id: Int, name: String)
}

/// roster_clients.sql — every client, by name.
///
/// The client-directory slice the operations console offers as a name <select>
/// (SignContract carries the client by NAME). A client is a durable identity —
/// it has no validity window — so this is NOT date-filtered: every client is
/// always selectable, id + name, ordered by name for a stable dropdown.
///
/// The id comes from the `client` ANCHOR (provably NOT NULL); the NAME, which left
/// the anchor for the edit-grouped client_profile fact, is read through the
/// `client_current` view (latest profile per client). The INNER JOIN means a
/// client with no profile row is omitted (every seeded client has one). coalesce
/// keeps the name column NOT NULL through the view boundary; it is never actually
/// null (the join is on a NOT NULL profile column).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn roster_clients(
  db: pog.Connection,
) -> Result(pog.Returned(RosterClientsRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(RosterClientsRow(id:, name:))
  }

  "-- roster_clients.sql — every client, by name.
--
-- The client-directory slice the operations console offers as a name <select>
-- (SignContract carries the client by NAME). A client is a durable identity —
-- it has no validity window — so this is NOT date-filtered: every client is
-- always selectable, id + name, ordered by name for a stable dropdown.
--
-- The id comes from the `client` ANCHOR (provably NOT NULL); the NAME, which left
-- the anchor for the edit-grouped client_profile fact, is read through the
-- `client_current` view (latest profile per client). The INNER JOIN means a
-- client with no profile row is omitted (every seeded client has one). coalesce
-- keeps the name column NOT NULL through the view boundary; it is never actually
-- null (the join is on a NOT NULL profile column).
SELECT client.id, coalesce(cc.name, '') AS name
FROM client
JOIN client_current cc ON cc.id = client.id
ORDER BY name;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `roster_engineers` query
/// defined in `./src/tempo/server/sql/roster_engineers.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RosterEngineersRow {
  RosterEngineersRow(id: Int, name: String)
}

/// roster_engineers.sql — engineers EMPLOYED as-of the date ($1::date).
///
/// The engineer-directory slice the operations console offers as a name <select>:
/// only engineers whose employment window covers the slider's as-of date, so the
/// console can never name an engineer who is not on the books on that date. One
/// row per engineer (employment has at most one row covering a date), id + name,
/// ordered by name for a stable, alphabetised dropdown.
///
/// The id comes from the `engineer` ANCHOR (provably NOT NULL); the NAME, which
/// left the anchor for the edit-grouped contact fact, is read through the
/// `engineer_current` view (latest contact per engineer). The INNER JOIN means an
/// engineer with no contact row is omitted (every seeded/onboarded engineer has
/// one). coalesce keeps the name column NOT NULL through the view boundary; it is
/// never actually null (the join is on a NOT NULL contact column).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn roster_engineers(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(RosterEngineersRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(RosterEngineersRow(id:, name:))
  }

  "-- roster_engineers.sql — engineers EMPLOYED as-of the date ($1::date).
--
-- The engineer-directory slice the operations console offers as a name <select>:
-- only engineers whose employment window covers the slider's as-of date, so the
-- console can never name an engineer who is not on the books on that date. One
-- row per engineer (employment has at most one row covering a date), id + name,
-- ordered by name for a stable, alphabetised dropdown.
--
-- The id comes from the `engineer` ANCHOR (provably NOT NULL); the NAME, which
-- left the anchor for the edit-grouped contact fact, is read through the
-- `engineer_current` view (latest contact per engineer). The INNER JOIN means an
-- engineer with no contact row is omitted (every seeded/onboarded engineer has
-- one). coalesce keeps the name column NOT NULL through the view boundary; it is
-- never actually null (the join is on a NOT NULL contact column).
SELECT e.id, coalesce(ec.name, '') AS name
FROM engineer e
JOIN employment emp
  ON emp.engineer_id = e.id AND emp.employed_during @> $1::date
JOIN engineer_current ec ON ec.id = e.id
ORDER BY name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `roster_projects` query
/// defined in `./src/tempo/server/sql/roster_projects.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RosterProjectsRow {
  RosterProjectsRow(id: Int, name: String)
}

/// roster_projects.sql — projects ACTIVE as-of the date ($1::date).
///
/// The project-directory slice the operations console offers as a name <select>:
/// only projects whose active window covers the slider's as-of date. The run's
/// `active_during` WITHOUT OVERLAPS constraint guarantees at most one project_run
/// row per project id per date, so this returns one row per active project, id +
/// name, ordered by name for a stable, alphabetised dropdown. The NAME left the
/// project anchor for the project_profile fact, so the title is read through the
/// `project_current` view (latest profile per project) and coalesced to keep the
/// String contract past Squirrel's nullable-view inference.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn roster_projects(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(RosterProjectsRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(RosterProjectsRow(id:, name:))
  }

  "-- roster_projects.sql — projects ACTIVE as-of the date ($1::date).
--
-- The project-directory slice the operations console offers as a name <select>:
-- only projects whose active window covers the slider's as-of date. The run's
-- `active_during` WITHOUT OVERLAPS constraint guarantees at most one project_run
-- row per project id per date, so this returns one row per active project, id +
-- name, ordered by name for a stable, alphabetised dropdown. The NAME left the
-- project anchor for the project_profile fact, so the title is read through the
-- `project_current` view (latest profile per project) and coalesced to keep the
-- String contract past Squirrel's nullable-view inference.
SELECT project_run.project_id AS id, coalesce(project_current.title, '') AS name
FROM project_run
JOIN project_current ON project_current.id = project_run.project_id
WHERE project_run.active_during @> $1::date
ORDER BY name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// salary_revise.sql — change a level's monthly_salary from $1 onward.
///
/// CHANGE write: re-rate the version of a level in effect on $1 for the open
/// span [$1, ∞) via FOR PORTION OF. The `@>` guard confines the update to the
/// single salary row covering $1, so a separately-scheduled future version of
/// the same level stays untouched; PG carves off the unchanged [start, $1)
/// remainder as its own row. $1 is the effective date, $2 the new monthly
/// salary, $3 the level.
///
/// PG reports `UPDATE 1` even when it produces an extra remainder row, so never
/// infer a split from the affected-row count — read the rows back instead.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn salary_revise(
  db: pog.Connection,
  arg_1: Date,
  monthly_salary: Float,
  level: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- salary_revise.sql — change a level's monthly_salary from $1 onward.
--
-- CHANGE write: re-rate the version of a level in effect on $1 for the open
-- span [$1, ∞) via FOR PORTION OF. The `@>` guard confines the update to the
-- single salary row covering $1, so a separately-scheduled future version of
-- the same level stays untouched; PG carves off the unchanged [start, $1)
-- remainder as its own row. $1 is the effective date, $2 the new monthly
-- salary, $3 the level.
--
-- PG reports `UPDATE 1` even when it produces an extra remainder row, so never
-- infer a split from the affected-row count — read the rows back instead.
UPDATE salary
   FOR PORTION OF effective_during FROM $1::date TO NULL
   SET monthly_salary = $2
 WHERE level = $3
   AND effective_during @> $1::date;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.float(monthly_salary))
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

/// A row you get from running the `timesheet_week` query
/// defined in `./src/tempo/server/sql/timesheet_week.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type TimesheetWeekRow {
  TimesheetWeekRow(
    project_id: Int,
    project: String,
    day: Date,
    allocated: Bool,
    hours: Float,
  )
}

/// timesheet_week.sql -- an engineer's whole Mon-Sun week: every project allocated on
/// ANY day of the week, with each day's allocation coverage and any hours logged. One
/// row per (project, day). $1 = engineer_id, $2 = the Monday of the week; the week is
/// the half-open range [$2, $2 + 7). 'allocated' is the cell's editability: an
/// allocation to this project covers that day AND the engineer is not on leave that day
/// (leave takes precedence, as on the old single-day form). The grid disables a cell
/// where it is false; the timesheet_within_allocation PERIOD FK backstops the same rule
/// on write.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn timesheet_week(
  db: pog.Connection,
  allocation_engineer_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(TimesheetWeekRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use project <- decode.field(1, decode.string)
    use day <- decode.field(2, pog.calendar_date_decoder())
    use allocated <- decode.field(3, decode.bool)
    use hours <- decode.field(4, pog.numeric_decoder())
    decode.success(TimesheetWeekRow(
      project_id:,
      project:,
      day:,
      allocated:,
      hours:,
    ))
  }

  "-- timesheet_week.sql -- an engineer's whole Mon-Sun week: every project allocated on
-- ANY day of the week, with each day's allocation coverage and any hours logged. One
-- row per (project, day). $1 = engineer_id, $2 = the Monday of the week; the week is
-- the half-open range [$2, $2 + 7). 'allocated' is the cell's editability: an
-- allocation to this project covers that day AND the engineer is not on leave that day
-- (leave takes precedence, as on the old single-day form). The grid disables a cell
-- where it is false; the timesheet_within_allocation PERIOD FK backstops the same rule
-- on write.
WITH week AS (
  SELECT daterange($2::date, ($2::date + 7), '[)') AS span
),
days AS (
  SELECT generate_series($2::date, $2::date + 6, interval '1 day')::date AS day
),
week_projects AS (
  SELECT DISTINCT allocation.project_id,
                  coalesce(project_current.title, '') AS project
  FROM allocation
  JOIN project_run ON project_run.project_id = allocation.project_id
  JOIN project_current ON project_current.id = allocation.project_id
  CROSS JOIN week
  WHERE allocation.engineer_id = $1
    AND allocation.allocated_during && week.span
    AND project_run.active_during && week.span
)
SELECT
  week_projects.project_id,
  week_projects.project,
  days.day,
  (
    EXISTS (
      SELECT 1 FROM allocation a
      WHERE a.engineer_id = $1
        AND a.project_id = week_projects.project_id
        AND a.allocated_during @> days.day
    )
    AND NOT EXISTS (
      SELECT 1 FROM leave l
      WHERE l.engineer_id = $1 AND l.on_leave_during @> days.day
    )
  ) AS allocated,
  COALESCE(timesheet.hours, 0) AS hours
FROM week_projects
CROSS JOIN days
LEFT JOIN timesheet
  ON timesheet.engineer_id = $1
 AND timesheet.project_id = week_projects.project_id
 AND timesheet.work_day @> days.day
ORDER BY week_projects.project, days.day;
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
