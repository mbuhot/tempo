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

/// allocation_assign.sql — assert a fractional allocation over a bounded period,
/// contained by both employment and the project run via PERIOD FKs. Last param is the
/// audit_id. $1 = engineer_id, $2 = project_id, $3 = from, $4 = fraction, $5 = to.
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
  arg_6: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- allocation_assign.sql — assert a fractional allocation over a bounded period,
-- contained by both employment and the project run via PERIOD FKs. Last param is the
-- audit_id. $1 = engineer_id, $2 = project_id, $3 = from, $4 = fraction, $5 = to.
INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during, audit_id)
VALUES ($1, $2, $4, daterange($3::date, $5::date, '[)'), $6);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.parameter(pog.calendar_date(arg_5))
  |> pog.parameter(pog.int(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// allocation_change_fraction.sql — Change: re-fraction from a date onward. FOR
/// PORTION OF sets the new fraction + audit_id on [$3, row.upper); PG re-inserts the
/// [row.lower, $3) leftover at the old fraction keeping its original audit_id. The
/// `@> $3` filter excludes a scheduled future version. $1 = engineer_id,
/// $2 = project_id, $3 = effective, $4 = new fraction, $5 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn allocation_change_fraction(
  db: pog.Connection,
  engineer_id: Int,
  project_id: Int,
  arg_3: Date,
  arg_4: Float,
  audit_id: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- allocation_change_fraction.sql — Change: re-fraction from a date onward. FOR
-- PORTION OF sets the new fraction + audit_id on [$3, row.upper); PG re-inserts the
-- [row.lower, $3) leftover at the old fraction keeping its original audit_id. The
-- `@> $3` filter excludes a scheduled future version. $1 = engineer_id,
-- $2 = project_id, $3 = effective, $4 = new fraction, $5 = audit_id.
UPDATE allocation
   FOR PORTION OF allocated_during FROM $3::date TO NULL
   SET fraction = $4, audit_id = $5
 WHERE engineer_id = $1 AND project_id = $2 AND allocated_during @> $3::date;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.parameter(pog.int(audit_id))
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

/// A row you get from running the `board_unstaffed` query
/// defined in `./src/tempo/server/sql/board_unstaffed.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type BoardUnstaffedRow {
  BoardUnstaffedRow(project_id: Int, title: String, client: String)
}

/// board_unstaffed.sql — active projects with ZERO allocations on the date
/// ($1::date). The project-keyed companion to board_unassigned (which is keyed
/// on the engineer); the client renders these as the board's "Unstaffed" lane.
///
/// A project is active when its run covers $1 (project_run.active_during @> $1).
/// It is unstaffed when NO allocation covers $1 (NOT EXISTS). Counting allocations
/// (not engagements) means a project staffed only by an on-leave engineer is NOT
/// unstaffed — the allocation still covers the date — consistent with team_size.
/// Title comes from project_current; the owning client name through the run's
/// contract to client_current. All columns non-null, so the row decodes plainly.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn board_unstaffed(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(BoardUnstaffedRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use client <- decode.field(2, decode.string)
    decode.success(BoardUnstaffedRow(project_id:, title:, client:))
  }

  "-- board_unstaffed.sql — active projects with ZERO allocations on the date
-- ($1::date). The project-keyed companion to board_unassigned (which is keyed
-- on the engineer); the client renders these as the board's \"Unstaffed\" lane.
--
-- A project is active when its run covers $1 (project_run.active_during @> $1).
-- It is unstaffed when NO allocation covers $1 (NOT EXISTS). Counting allocations
-- (not engagements) means a project staffed only by an on-leave engineer is NOT
-- unstaffed — the allocation still covers the date — consistent with team_size.
-- Title comes from project_current; the owning client name through the run's
-- contract to client_current. All columns non-null, so the row decodes plainly.
SELECT
  project_run.project_id,
  coalesce(project_current.title, '') AS title,
  coalesce(client_current.name, '') AS client
FROM project_run
JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id AND contract_terms.term @> $1::date
JOIN client_current ON client_current.id = contract_terms.client_id
JOIN project_current ON project_current.id = project_run.project_id
WHERE project_run.active_during @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM allocation
    WHERE allocation.project_id = project_run.project_id
      AND allocation.allocated_during @> $1::date
  )
ORDER BY title;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `client_contracts` query
/// defined in `./src/tempo/server/sql/client_contracts.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ClientContractsRow {
  ClientContractsRow(
    contract_id: Int,
    valid_from: Date,
    valid_to: Date,
    active: Bool,
  )
}

/// client_contracts.sql — one client's contract terms for the detail read model
/// (GET /api/clients/:id; the ContractRow list). Params: $1 = client_id,
/// $2 = as-of (for the active flag only).
///
/// Every contract_terms period-row for the client, decomposed to plain dates:
/// contract_id, lower(term) AS valid_from, upper(term) AS valid_to (non-null for
/// every seed row — all bounded at 2027-01-01). `active` is (term @> $2): the as-of
/// marks each contract active/ended per FR-CP1 without hiding it, so the whole list
/// is returned regardless of $2. Ordered oldest-first then by contract_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn client_contracts(
  db: pog.Connection,
  contract_terms_client_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(ClientContractsRow), pog.QueryError) {
  let decoder = {
    use contract_id <- decode.field(0, decode.int)
    use valid_from <- decode.field(1, pog.calendar_date_decoder())
    use valid_to <- decode.field(2, pog.calendar_date_decoder())
    use active <- decode.field(3, decode.bool)
    decode.success(ClientContractsRow(
      contract_id:,
      valid_from:,
      valid_to:,
      active:,
    ))
  }

  "-- client_contracts.sql — one client's contract terms for the detail read model
-- (GET /api/clients/:id; the ContractRow list). Params: $1 = client_id,
-- $2 = as-of (for the active flag only).
--
-- Every contract_terms period-row for the client, decomposed to plain dates:
-- contract_id, lower(term) AS valid_from, upper(term) AS valid_to (non-null for
-- every seed row — all bounded at 2027-01-01). `active` is (term @> $2): the as-of
-- marks each contract active/ended per FR-CP1 without hiding it, so the whole list
-- is returned regardless of $2. Ordered oldest-first then by contract_id.
SELECT
  contract_terms.contract_id,
  lower(contract_terms.term) AS valid_from,
  upper(contract_terms.term) AS valid_to,
  (contract_terms.term @> $2::date) AS active
FROM contract_terms
WHERE contract_terms.client_id = $1
ORDER BY lower(contract_terms.term), contract_terms.contract_id;
"
  |> pog.query
  |> pog.parameter(pog.int(contract_terms_client_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `client_list` query
/// defined in `./src/tempo/server/sql/client_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ClientListRow {
  ClientListRow(
    client_id: Int,
    name: String,
    since: Option(Date),
    project_count: Int,
    active: Bool,
  )
}

/// client_list.sql — the clients-directory read model (GET /api/clients?as_of=$1;
/// mirrors project_list's as-of existence). One row per client that has COME INTO
/// EXISTENCE by $1 — i.e. has a contract whose term STARTS on or before $1: name, the
/// earliest contract start (since), the count of distinct projects ever run for the
/// client, and whether any contract covers $1 (active). Param: $1 = the as-of date.
///
/// EXISTENCE. A client whose first contract starts AFTER $1 is absent, not rendered as
/// 'ended' (the WHERE EXISTS lower(term) <= $1) — the timeline-scrub mirror of
/// project_list (#19). A client that HAS started but whose contracts have all ended by
/// $1 still lists, with active=false → the 'ended' pill, which is now shown only for a
/// genuinely-ended client.
///
/// name from the client_current latest-read view (INNER join — every seeded client has
/// a profile). `since` is min(lower(term)) over the client's contracts (always <= $1
/// for a listed client). The `"since?"` alias forces the generated column to
/// Option(Date) (the schema does not guarantee >=1 contract), matching the shared
/// ClientListRow.since. `active` is a correlated bool_or(term @> $1) coalesced to
/// false. The project count is a correlated count of distinct project ids reachable
/// through the client's contracts' runs. Ordered by name for a stable directory.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn client_list(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(ClientListRow), pog.QueryError) {
  let decoder = {
    use client_id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use since <- decode.field(2, decode.optional(pog.calendar_date_decoder()))
    use project_count <- decode.field(3, decode.int)
    use active <- decode.field(4, decode.bool)
    decode.success(ClientListRow(
      client_id:,
      name:,
      since:,
      project_count:,
      active:,
    ))
  }

  "-- client_list.sql — the clients-directory read model (GET /api/clients?as_of=$1;
-- mirrors project_list's as-of existence). One row per client that has COME INTO
-- EXISTENCE by $1 — i.e. has a contract whose term STARTS on or before $1: name, the
-- earliest contract start (since), the count of distinct projects ever run for the
-- client, and whether any contract covers $1 (active). Param: $1 = the as-of date.
--
-- EXISTENCE. A client whose first contract starts AFTER $1 is absent, not rendered as
-- 'ended' (the WHERE EXISTS lower(term) <= $1) — the timeline-scrub mirror of
-- project_list (#19). A client that HAS started but whose contracts have all ended by
-- $1 still lists, with active=false → the 'ended' pill, which is now shown only for a
-- genuinely-ended client.
--
-- name from the client_current latest-read view (INNER join — every seeded client has
-- a profile). `since` is min(lower(term)) over the client's contracts (always <= $1
-- for a listed client). The `\"since?\"` alias forces the generated column to
-- Option(Date) (the schema does not guarantee >=1 contract), matching the shared
-- ClientListRow.since. `active` is a correlated bool_or(term @> $1) coalesced to
-- false. The project count is a correlated count of distinct project ids reachable
-- through the client's contracts' runs. Ordered by name for a stable directory.
SELECT
  client.id AS client_id,
  coalesce(client_current.name, '') AS name,
  (
    SELECT min(lower(contract_terms.term))
      FROM contract_terms
     WHERE contract_terms.client_id = client.id
  ) AS \"since?\",
  (
    SELECT count(DISTINCT project_run.project_id)
      FROM contract_terms
      JOIN project_run ON project_run.contract_id = contract_terms.contract_id
     WHERE contract_terms.client_id = client.id
  )::int AS project_count,
  coalesce((
    SELECT bool_or(contract_terms.term @> $1::date)
      FROM contract_terms
     WHERE contract_terms.client_id = client.id
  ), false) AS active
FROM client
JOIN client_current ON client_current.id = client.id
WHERE EXISTS (
  SELECT 1
    FROM contract_terms
   WHERE contract_terms.client_id = client.id
     AND lower(contract_terms.term) <= $1::date
)
ORDER BY name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// client_profile_upsert.sql — record a client profile (the NAME) from $2 onward in one
/// statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
/// sets the new name + audit_id on the [$2, NULL) portion of the covering version, and
/// PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id. If
/// no version covers $2 (the founding write) the Change touches nothing, so the guarded
/// INSERT opens the first [$2, NULL) span instead. $1 = client_id, $2 = effective,
/// $3 = name, $4 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn client_profile_upsert(
  db: pog.Connection,
  client_id: Int,
  arg_2: Date,
  arg_3: String,
  audit_id: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- client_profile_upsert.sql — record a client profile (the NAME) from $2 onward in one
-- statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
-- sets the new name + audit_id on the [$2, NULL) portion of the covering version, and
-- PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id. If
-- no version covers $2 (the founding write) the Change touches nothing, so the guarded
-- INSERT opens the first [$2, NULL) span instead. $1 = client_id, $2 = effective,
-- $3 = name, $4 = audit_id.
WITH changed AS (
  UPDATE client_profile
     FOR PORTION OF recorded_during FROM $2::date TO NULL
     SET name = $3, audit_id = $4
   WHERE client_id = $1
     AND recorded_during @> $2::date
  RETURNING 1
)
INSERT INTO client_profile
  (client_id, name, recorded_during, audit_id)
SELECT $1, $3, daterange($2::date, NULL, '[)'), $4
WHERE NOT EXISTS (SELECT 1 FROM changed);
"
  |> pog.query
  |> pog.parameter(pog.int(client_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.int(audit_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `client_projects` query
/// defined in `./src/tempo/server/sql/client_projects.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ClientProjectsRow {
  ClientProjectsRow(
    project_id: Int,
    title: String,
    budget: Float,
    target_completion: Date,
    valid_from: Date,
    valid_to: Date,
    active: Bool,
  )
}

/// client_projects.sql — one client's projects for the detail read model (GET
/// /api/clients/:id; the ClientProjectRow list; FR-CP1). Params: $1 = client_id,
/// $2 = as-of (for the active flag only).
///
/// A multi-hop temporal join from the client's contracts out to its projects:
/// contract_terms (the client's contracts) → project_run (each contract's project
/// runs) → project_current for the title and a LATERAL latest-read project_plan for
/// the budget/target. The run window is decomposed to plain dates: lower/upper
/// active_during AS valid_from/valid_to (non-null for every seed run, bounded at
/// 2027-01-01). `active` is (active_during @> $2) — the as-of marks each project
/// active/ended without hiding it, so the whole list is returned regardless of $2.
/// The plan is the most-recently-effective project_plan row (DISTINCT ON by start
/// desc, like project_plan_current) so budget/target are scalar; a project with no
/// plan yet coalesces budget to 0 and falls back to the run end for target. Ordered
/// by run start then title.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn client_projects(
  db: pog.Connection,
  contract_terms_client_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(ClientProjectsRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use budget <- decode.field(2, pog.numeric_decoder())
    use target_completion <- decode.field(3, pog.calendar_date_decoder())
    use valid_from <- decode.field(4, pog.calendar_date_decoder())
    use valid_to <- decode.field(5, pog.calendar_date_decoder())
    use active <- decode.field(6, decode.bool)
    decode.success(ClientProjectsRow(
      project_id:,
      title:,
      budget:,
      target_completion:,
      valid_from:,
      valid_to:,
      active:,
    ))
  }

  "-- client_projects.sql — one client's projects for the detail read model (GET
-- /api/clients/:id; the ClientProjectRow list; FR-CP1). Params: $1 = client_id,
-- $2 = as-of (for the active flag only).
--
-- A multi-hop temporal join from the client's contracts out to its projects:
-- contract_terms (the client's contracts) → project_run (each contract's project
-- runs) → project_current for the title and a LATERAL latest-read project_plan for
-- the budget/target. The run window is decomposed to plain dates: lower/upper
-- active_during AS valid_from/valid_to (non-null for every seed run, bounded at
-- 2027-01-01). `active` is (active_during @> $2) — the as-of marks each project
-- active/ended without hiding it, so the whole list is returned regardless of $2.
-- The plan is the most-recently-effective project_plan row (DISTINCT ON by start
-- desc, like project_plan_current) so budget/target are scalar; a project with no
-- plan yet coalesces budget to 0 and falls back to the run end for target. Ordered
-- by run start then title.
SELECT
  project_run.project_id,
  coalesce(project_current.title, '') AS title,
  coalesce(plan.budget, 0)::numeric AS budget,
  coalesce(plan.target_completion, upper(project_run.active_during)) AS target_completion,
  lower(project_run.active_during) AS valid_from,
  upper(project_run.active_during) AS valid_to,
  (project_run.active_during @> $2::date) AS active
FROM contract_terms
JOIN project_run ON project_run.contract_id = contract_terms.contract_id
JOIN project_current ON project_current.id = project_run.project_id
LEFT JOIN LATERAL (
  SELECT project_plan.budget, project_plan.target_completion
    FROM project_plan
   WHERE project_plan.project_id = project_run.project_id
   ORDER BY lower(project_plan.planned_during) DESC
   LIMIT 1
) plan ON true
WHERE contract_terms.client_id = $1
ORDER BY lower(project_run.active_during), title;
"
  |> pog.query
  |> pog.parameter(pog.int(contract_terms_client_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// contract_create.sql — insert the contract identity (ID-ONLY anchor) at a reserved id.
///
/// Step 1 of sign_contract. The id is reserved up-front from contract_id_seq
/// (contract_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
/// The engagement term lives in a separate contract_terms fact recorded alongside.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn contract_create(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- contract_create.sql — insert the contract identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of sign_contract. The id is reserved up-front from contract_id_seq
-- (contract_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
-- The engagement term lives in a separate contract_terms fact recorded alongside.
INSERT INTO contract (id) VALUES ($1);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `contract_next_id` query
/// defined in `./src/tempo/server/sql/contract_next_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ContractNextIdRow {
  ContractNextIdRow(id: Int)
}

/// contract_next_id.sql — reserve the next contract id from its sequence.
///
/// Called before sign_contract records any contract fact: the handler threads this id
/// into the Contract anchor and its terms in one transaction, so nothing is read back.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn contract_next_id(
  db: pog.Connection,
) -> Result(pog.Returned(ContractNextIdRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(ContractNextIdRow(id:))
  }

  "-- contract_next_id.sql — reserve the next contract id from its sequence.
--
-- Called before sign_contract records any contract fact: the handler threads this id
-- into the Contract anchor and its terms in one transaction, so nothing is read back.
SELECT nextval('contract_id_seq')::int AS id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// contract_terms_open.sql — open a contract's term (resolving the client by name to
/// its id). Last param is the audit_id. $1 = contract_id, $2 = client name,
/// $3 = from, $4 = to.
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
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- contract_terms_open.sql — open a contract's term (resolving the client by name to
-- its id). Last param is the audit_id. $1 = contract_id, $2 = client name,
-- $3 = from, $4 = to.
INSERT INTO contract_terms (contract_id, client_id, term, audit_id)
VALUES (
  $1,
  (SELECT id FROM client_current WHERE name = $2),
  daterange($3::date, $4::date, '[)'),
  $5
);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.parameter(pog.int(arg_5))
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
/// defined in `./src/tempo/server/sql/engineer_allocations.sql`.
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

/// engineer_banking_upsert.sql — record banking details from $2 onward in one
/// statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
/// sets the new values + audit_id on the [$2, NULL) portion of the covering version,
/// and PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id.
/// If no version covers $2 (the founding write) the Change touches nothing, so the
/// guarded INSERT opens the first [$2, NULL) span instead. $1 = engineer_id,
/// $2 = effective, $3 = bank, $4 = branch, $5 = account_no, $6 = account_name,
/// $7 = audit_id.
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
  audit_id: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_banking_upsert.sql — record banking details from $2 onward in one
-- statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
-- sets the new values + audit_id on the [$2, NULL) portion of the covering version,
-- and PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id.
-- If no version covers $2 (the founding write) the Change touches nothing, so the
-- guarded INSERT opens the first [$2, NULL) span instead. $1 = engineer_id,
-- $2 = effective, $3 = bank, $4 = branch, $5 = account_no, $6 = account_name,
-- $7 = audit_id.
WITH changed AS (
  UPDATE engineer_banking
     FOR PORTION OF recorded_during FROM $2::date TO NULL
     SET bank = $3, branch = $4, account_no = $5, account_name = $6, audit_id = $7
   WHERE engineer_id = $1
     AND recorded_during @> $2::date
  RETURNING 1
)
INSERT INTO engineer_banking
  (engineer_id, bank, branch, account_no, account_name, recorded_during, audit_id)
SELECT $1, $3, $4, $5, $6, daterange($2::date, NULL, '[)'), $7
WHERE NOT EXISTS (SELECT 1 FROM changed);
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.int(audit_id))
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

/// engineer_contact_upsert.sql — record contact details from $2 onward in one
/// statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
/// sets the new values + audit_id on the [$2, NULL) portion of the covering version,
/// and PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id.
/// If no version covers $2 (the founding write at onboard) the Change touches nothing,
/// so the guarded INSERT opens the first [$2, NULL) span instead. $1 = engineer_id,
/// $2 = effective, $3 = name, $4 = email, $5 = phone, $6 = postal, $7 = audit_id.
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
  audit_id: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_contact_upsert.sql — record contact details from $2 onward in one
-- statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
-- sets the new values + audit_id on the [$2, NULL) portion of the covering version,
-- and PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id.
-- If no version covers $2 (the founding write at onboard) the Change touches nothing,
-- so the guarded INSERT opens the first [$2, NULL) span instead. $1 = engineer_id,
-- $2 = effective, $3 = name, $4 = email, $5 = phone, $6 = postal, $7 = audit_id.
WITH changed AS (
  UPDATE engineer_contact
     FOR PORTION OF recorded_during FROM $2::date TO NULL
     SET name = $3, email = $4, phone = $5, postal_address = $6, audit_id = $7
   WHERE engineer_id = $1
     AND recorded_during @> $2::date
  RETURNING 1
)
INSERT INTO engineer_contact
  (engineer_id, name, email, phone, postal_address, recorded_during, audit_id)
SELECT $1, $3, $4, $5, $6, daterange($2::date, NULL, '[)'), $7
WHERE NOT EXISTS (SELECT 1 FROM changed);
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.int(audit_id))
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

/// engineer_emergency_upsert.sql — record an emergency contact from $2 onward in one
/// statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
/// sets the new values + audit_id on the [$2, NULL) portion of the covering version,
/// and PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id.
/// If no version covers $2 (the founding write) the Change touches nothing, so the
/// guarded INSERT opens the first [$2, NULL) span instead. $1 = engineer_id,
/// $2 = effective, $3 = relation, $4 = name, $5 = phone, $6 = email, $7 = audit_id.
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
  audit_id: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_emergency_upsert.sql — record an emergency contact from $2 onward in one
-- statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
-- sets the new values + audit_id on the [$2, NULL) portion of the covering version,
-- and PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id.
-- If no version covers $2 (the founding write) the Change touches nothing, so the
-- guarded INSERT opens the first [$2, NULL) span instead. $1 = engineer_id,
-- $2 = effective, $3 = relation, $4 = name, $5 = phone, $6 = email, $7 = audit_id.
WITH changed AS (
  UPDATE engineer_emergency
     FOR PORTION OF recorded_during FROM $2::date TO NULL
     SET relation = $3, name = $4, phone = $5, email = $6, audit_id = $7
   WHERE engineer_id = $1
     AND recorded_during @> $2::date
  RETURNING 1
)
INSERT INTO engineer_emergency
  (engineer_id, relation, name, phone, email, recorded_during, audit_id)
SELECT $1, $3, $4, $5, $6, daterange($2::date, NULL, '[)'), $7
WHERE NOT EXISTS (SELECT 1 FROM changed);
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.int(audit_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_employment_asof` query
/// defined in `./src/tempo/server/sql/engineer_employment_asof.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerEmploymentAsofRow {
  EngineerEmploymentAsofRow(
    engineer_id: Int,
    started: Date,
    level: Int,
    monthly_salary: Float,
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
    use monthly_salary <- decode.field(3, pog.numeric_decoder())
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
  salary.monthly_salary
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

/// A row you get from running the `engineer_lock` query
/// defined in `./src/tempo/server/sql/engineer_lock.sql`.
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
/// defined in `./src/tempo/server/sql/engineer_next_id.sql`.
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
/// defined in `./src/tempo/server/sql/engineer_role_history.sql`.
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

/// engineer_role_upsert.sql — record an engineer's level from $2 onward in one
/// statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
/// sets the new level + audit_id on the [$2, NULL) portion of the role in effect, and
/// PG re-inserts the [start, $2) leftover at the OLD level AND its original audit_id. If
/// no role covers $2 (the founding write at onboard) the Change touches nothing, so the
/// guarded INSERT opens the first [$2, NULL) span — contained by employment via the
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
  audit_id: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_role_upsert.sql — record an engineer's level from $2 onward in one
-- statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
-- sets the new level + audit_id on the [$2, NULL) portion of the role in effect, and
-- PG re-inserts the [start, $2) leftover at the OLD level AND its original audit_id. If
-- no role covers $2 (the founding write at onboard) the Change touches nothing, so the
-- guarded INSERT opens the first [$2, NULL) span — contained by employment via the
-- engineer_role_within_employment PERIOD FK. $1 = engineer_id, $2 = effective,
-- $3 = level, $4 = audit_id.
WITH changed AS (
  UPDATE engineer_role
     FOR PORTION OF held_during FROM $2::date TO NULL
     SET level = $3, audit_id = $4
   WHERE engineer_id = $1
     AND held_during @> $2::date
  RETURNING 1
)
INSERT INTO engineer_role (engineer_id, level, held_during, audit_id)
SELECT $1, $3, daterange($2::date, NULL, '[)'), $4
WHERE NOT EXISTS (SELECT 1 FROM changed);
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.int(arg_3))
  |> pog.parameter(pog.int(audit_id))
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

/// event_log_list.sql — the provenance journal as a filterable, half-open window
/// (§5a; GET /api/events?from=&to=&operation=&actor=; the Activity feed). All four
/// params are OPTIONAL — a NULL param drops its filter, so no params returns the
/// whole journal newest-first.
///
/// This is SYSTEM time (occurred_at), NOT the valid-time as-of rail. The window is
/// half-open [from, to): $1 = from (inclusive lower, occurred_at::date >= $1),
/// $2 = to (exclusive upper, occurred_at::date < $2); $3 = operation, $4 = actor are
/// exact-match filters. Each param is guarded ($n IS NULL OR …) so an absent filter
/// matches every row. The explicit ::date / ::text casts let Squirrel infer the
/// nullable param types (Option(Date)/Option(String)).
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
  arg_2: Date,
  arg_3: String,
  arg_4: String,
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

  "-- event_log_list.sql — the provenance journal as a filterable, half-open window
-- (§5a; GET /api/events?from=&to=&operation=&actor=; the Activity feed). All four
-- params are OPTIONAL — a NULL param drops its filter, so no params returns the
-- whole journal newest-first.
--
-- This is SYSTEM time (occurred_at), NOT the valid-time as-of rail. The window is
-- half-open [from, to): $1 = from (inclusive lower, occurred_at::date >= $1),
-- $2 = to (exclusive upper, occurred_at::date < $2); $3 = operation, $4 = actor are
-- exact-match filters. Each param is guarded ($n IS NULL OR …) so an absent filter
-- matches every row. The explicit ::date / ::text casts let Squirrel infer the
-- nullable param types (Option(Date)/Option(String)).
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
WHERE ($1::date IS NULL OR occurred_at::date >= $1)
  AND ($2::date IS NULL OR occurred_at::date < $2)
  AND ($3::text IS NULL OR operation = $3)
  AND ($4::text IS NULL OR actor = $4)
ORDER BY id DESC;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
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

/// A row you get from running the `forecast` query
/// defined in `./src/tempo/server/sql/forecast.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ForecastRow {
  ForecastRow(month: Date, revenue: Float, cost: Float)
}

/// forecast.sql — the forward P&L from COMMITTED DEMAND (the demand-side mirror of
/// the capacity-based P&L in pnl_rows.sql). One row per calendar month from the
/// as-of month to the cliff, carrying the projected revenue and cost; the caller
/// derives profit and margin.
///
/// Param: $1 = as-of date. Only the scalar as-of crosses the Squirrel boundary; the
/// window and every sub-period range are built in SQL.
///
/// WINDOW. From the first of the as-of month to the CLIFF =
/// max(upper(required_during) over all project_requirement,
/// upper(allocated_during) over all allocation)
/// i.e. the last day any committed demand exists (a requirement's end or, where a
/// project forecasts off its allocations, the allocation's end). generate_series
/// steps month-by-month from the as-of month's first day up to (but not including)
/// the cliff, and each step's calendar month [first, first-of-next) is one bucket.
///
/// EFFECTIVE DEMAND per (project, month) — decision (b): if the project has ANY
/// requirement covering the month it forecasts off its REQUIREMENT lines
/// (level, quantity); otherwise off its ALLOCATIONS mapped to (level, fraction) via
/// engineer_role. Never both, so no double-count. The switch is the
/// EXISTS (requirement for this project overlapping the month)
/// predicate: requirement-bearing project-months take the `requirement_demand`
/// branch; the rest take the `allocation_demand` branch (its WHERE NOT EXISTS
/// excludes any project-month a requirement already covers). The two branches are
/// UNIONed into one demand stream of (project_id, month, level, quantity, sub_period)
/// where sub_period is the demand-line ∩ month — the slice that month sees.
///
/// REVENUE(month) = Σ quantity × rate_card[level].day_rate × days over each
/// demand ∩ rate_card-version ∩ month sub-period — the SAME rate/version splitting
/// as pnl_rows.rev (split on the rate_card version so a mid-month rate revision
/// bills day-accurate). quantity replaces the allocation fraction as the capacity
/// multiplier; for the allocation branch quantity IS the fraction, so a forecast
/// that falls through to allocations reproduces the capacity-based revenue.
///
/// COST(month) = Σ quantity × monthly_salary[level] × days / days-in-month over each
/// demand ∩ salary-version ∩ month sub-period — the expected cost to FULFIL the
/// demand at the standard salary for the level, INCLUDING roles that would have to
/// be hired (a requirement with no engineer behind it still costs salary[level]).
/// Same proration as payroll_amounts (days_in_subperiod / days_in_month), split on
/// the salary version.
///
/// A daterange's day count is upper - lower (integer days). days-in-month is
/// upper(month) - lower(month) (28..31). Empty intersections are dropped via NOT
/// isempty. revenue/cost attach to the month bucket via LEFT JOIN and coalesce to 0,
/// so a month inside the window with no covered demand still appears as a zero row
/// (the series is dense from the as-of month to the cliff).
///
/// Assumptions:
/// * The cliff is finite: every requirement and allocation period is bounded
/// above (true in the seed — runs/contracts are bounded). With no requirements
/// AND no allocations the cliff is NULL and the series is empty.
/// * rate_card / salary have a version covering each (level, day) the demand spans
/// (true in the seed: baselines open at/under the earliest run). An uncovered
/// day yields no sub-period and is silently unpriced — a seed/data gap.
/// * Cost for to-hire roles uses the standard salary[level] (no hiring ramp or
/// recruiting cost) — per the spec's out-of-scope note.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn forecast(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(ForecastRow), pog.QueryError) {
  let decoder = {
    use month <- decode.field(0, pog.calendar_date_decoder())
    use revenue <- decode.field(1, pog.numeric_decoder())
    use cost <- decode.field(2, pog.numeric_decoder())
    decode.success(ForecastRow(month:, revenue:, cost:))
  }

  "-- forecast.sql — the forward P&L from COMMITTED DEMAND (the demand-side mirror of
-- the capacity-based P&L in pnl_rows.sql). One row per calendar month from the
-- as-of month to the cliff, carrying the projected revenue and cost; the caller
-- derives profit and margin.
--
-- Param: $1 = as-of date. Only the scalar as-of crosses the Squirrel boundary; the
-- window and every sub-period range are built in SQL.
--
-- WINDOW. From the first of the as-of month to the CLIFF =
--   max(upper(required_during) over all project_requirement,
--       upper(allocated_during) over all allocation)
-- i.e. the last day any committed demand exists (a requirement's end or, where a
-- project forecasts off its allocations, the allocation's end). generate_series
-- steps month-by-month from the as-of month's first day up to (but not including)
-- the cliff, and each step's calendar month [first, first-of-next) is one bucket.
--
-- EFFECTIVE DEMAND per (project, month) — decision (b): if the project has ANY
-- requirement covering the month it forecasts off its REQUIREMENT lines
-- (level, quantity); otherwise off its ALLOCATIONS mapped to (level, fraction) via
-- engineer_role. Never both, so no double-count. The switch is the
--   EXISTS (requirement for this project overlapping the month)
-- predicate: requirement-bearing project-months take the `requirement_demand`
-- branch; the rest take the `allocation_demand` branch (its WHERE NOT EXISTS
-- excludes any project-month a requirement already covers). The two branches are
-- UNIONed into one demand stream of (project_id, month, level, quantity, sub_period)
-- where sub_period is the demand-line ∩ month — the slice that month sees.
--
-- REVENUE(month) = Σ quantity × rate_card[level].day_rate × days over each
--   demand ∩ rate_card-version ∩ month sub-period — the SAME rate/version splitting
--   as pnl_rows.rev (split on the rate_card version so a mid-month rate revision
--   bills day-accurate). quantity replaces the allocation fraction as the capacity
--   multiplier; for the allocation branch quantity IS the fraction, so a forecast
--   that falls through to allocations reproduces the capacity-based revenue.
--
-- COST(month) = Σ quantity × monthly_salary[level] × days / days-in-month over each
--   demand ∩ salary-version ∩ month sub-period — the expected cost to FULFIL the
--   demand at the standard salary for the level, INCLUDING roles that would have to
--   be hired (a requirement with no engineer behind it still costs salary[level]).
--   Same proration as payroll_amounts (days_in_subperiod / days_in_month), split on
--   the salary version.
--
-- A daterange's day count is upper - lower (integer days). days-in-month is
-- upper(month) - lower(month) (28..31). Empty intersections are dropped via NOT
-- isempty. revenue/cost attach to the month bucket via LEFT JOIN and coalesce to 0,
-- so a month inside the window with no covered demand still appears as a zero row
-- (the series is dense from the as-of month to the cliff).
--
-- Assumptions:
--   * The cliff is finite: every requirement and allocation period is bounded
--     above (true in the seed — runs/contracts are bounded). With no requirements
--     AND no allocations the cliff is NULL and the series is empty.
--   * rate_card / salary have a version covering each (level, day) the demand spans
--     (true in the seed: baselines open at/under the earliest run). An uncovered
--     day yields no sub-period and is silently unpriced — a seed/data gap.
--   * Cost for to-hire roles uses the standard salary[level] (no hiring ramp or
--     recruiting cost) — per the spec's out-of-scope note.
WITH cliff AS (
  SELECT greatest(
    (SELECT max(upper(required_during)) FROM project_requirement),
    (SELECT max(upper(allocated_during)) FROM allocation)
  ) AS at
),
months AS (
  -- one calendar-month bucket per step from the as-of month to the cliff
  SELECT
    month_start::date AS month,
    daterange(
      month_start::date,
      (month_start + interval '1 month')::date,
      '[)'
    ) AS span
  FROM cliff,
    generate_series(
      date_trunc('month', $1::date),
      date_trunc('month', cliff.at - 1),
      interval '1 month'
    ) AS month_start
),
requirement_demand AS (
  -- the requirement branch: a project's requirement lines, sliced to each month
  SELECT
    project_requirement.project_id,
    months.month,
    months.span,
    project_requirement.level,
    project_requirement.quantity,
    project_requirement.required_during * months.span AS sub_period
  FROM months
  JOIN project_requirement
    ON project_requirement.required_during && months.span
),
allocation_demand AS (
  -- the allocation fallback: a project's allocations mapped to (level, fraction)
  -- via engineer_role, but ONLY for project-months no requirement covers (the (b)
  -- switch). quantity = the allocation fraction.
  SELECT
    allocation.project_id,
    months.month,
    months.span,
    engineer_role.level,
    allocation.fraction AS quantity,
    allocation.allocated_during
      * engineer_role.held_during
      * months.span AS sub_period
  FROM months
  JOIN allocation
    ON allocation.allocated_during && months.span
  JOIN engineer_role
    ON engineer_role.engineer_id = allocation.engineer_id
   AND engineer_role.held_during && allocation.allocated_during
   AND engineer_role.held_during && months.span
  WHERE NOT EXISTS (
    SELECT 1 FROM project_requirement
     WHERE project_requirement.project_id = allocation.project_id
       AND project_requirement.required_during && months.span
  )
),
demand AS (
  SELECT project_id, month, span, level, quantity, sub_period
    FROM requirement_demand
  UNION ALL
  SELECT project_id, month, span, level, quantity, sub_period
    FROM allocation_demand
),
revenue AS (
  -- Σ quantity × day_rate × days over each demand ∩ rate_card-version ∩ month
  SELECT
    demand.month,
    sum(demand.quantity
        * recognized_revenue(
            rate_card.day_rate,
            demand.sub_period * rate_card.effective_during))::numeric
      AS revenue
  FROM demand
  JOIN rate_card ON rate_card.level = demand.level
                AND rate_card.effective_during && demand.sub_period
  WHERE NOT isempty(demand.sub_period * rate_card.effective_during)
  GROUP BY demand.month
),
cost AS (
  -- Σ quantity × monthly_salary × days / days-in-month over each demand ∩
  -- salary-version ∩ month
  SELECT
    demand.month,
    sum(demand.quantity
        * prorated_salary(
            salary.monthly_salary,
            demand.sub_period * salary.effective_during,
            demand.span))::numeric
      AS cost
  FROM demand
  JOIN salary ON salary.level = demand.level
             AND salary.effective_during && demand.sub_period
  WHERE NOT isempty(demand.sub_period * salary.effective_during)
  GROUP BY demand.month
)
SELECT
  months.month,
  coalesce(revenue.revenue, 0)::numeric AS revenue,
  coalesce(cost.cost, 0)::numeric AS cost
FROM months
LEFT JOIN revenue ON revenue.month = months.month
LEFT JOIN cost    ON cost.month = months.month
ORDER BY months.month;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
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

/// invoice_create.sql — insert the invoice identity (ID-ONLY anchor) at a reserved id.
///
/// Step 1 of draft_invoice. The id is reserved up-front from invoice_id_seq
/// (invoice_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
/// The subject/status/lines are separate facts recorded alongside.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_create(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_create.sql — insert the invoice identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of draft_invoice. The id is reserved up-front from invoice_id_seq
-- (invoice_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
-- The subject/status/lines are separate facts recorded alongside.
INSERT INTO invoice (id) VALUES ($1);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
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
    issued_at: Option(Date),
    paid_at: Option(Date),
  )
}

/// invoice_header.sql — one invoice's header for the detail read model
/// (GET /api/invoices/:id). Same projection as invoice_list (project + client
/// name, billing month, status AS OF $2, line total, issue/pay transition dates)
/// for a single invoice.
///
/// issued_at/paid_at. The lower bound of the issued/paid status span — the day the
/// issue_invoice/pay_invoice transition occurred — or NULL when that transition has
/// not happened as-of $2. The `?` alias suffix forces Squirrel to generate
/// Option(Date) rather than inferring non-null off the all-issued/all-paid seed.
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
    use issued_at <- decode.field(
      7,
      decode.optional(pog.calendar_date_decoder()),
    )
    use paid_at <- decode.field(8, decode.optional(pog.calendar_date_decoder()))
    decode.success(InvoiceHeaderRow(
      id:,
      project:,
      client:,
      billing_from:,
      billing_to:,
      status:,
      total:,
      issued_at:,
      paid_at:,
    ))
  }

  "-- invoice_header.sql — one invoice's header for the detail read model
-- (GET /api/invoices/:id). Same projection as invoice_list (project + client
-- name, billing month, status AS OF $2, line total, issue/pay transition dates)
-- for a single invoice.
--
-- issued_at/paid_at. The lower bound of the issued/paid status span — the day the
-- issue_invoice/pay_invoice transition occurred — or NULL when that transition has
-- not happened as-of $2. The `?` alias suffix forces Squirrel to generate
-- Option(Date) rather than inferring non-null off the all-issued/all-paid seed.
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
  ), 0)::numeric AS total,
  (
    SELECT lower(issued.status_during)
      FROM invoice_status issued
     WHERE issued.invoice_id = invoice.id
       AND issued.status = 'issued'
       AND lower(issued.status_during) <= $2::date
     LIMIT 1
  ) AS \"issued_at?\",
  (
    SELECT lower(paid.status_during)
      FROM invoice_status paid
     WHERE paid.invoice_id = invoice.id
       AND paid.status = 'paid'
       AND lower(paid.status_during) <= $2::date
     LIMIT 1
  ) AS \"paid_at?\"
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

/// invoice_line_insert.sql — one snapshotted billing line. Last param is the
/// audit_id. $1 = invoice_id, $2 = engineer_id, $3 = level, $4 = day_rate,
/// $5 = days, $6 = amount.
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
  arg_7: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_line_insert.sql — one snapshotted billing line. Last param is the
-- audit_id. $1 = invoice_id, $2 = engineer_id, $3 = level, $4 = day_rate,
-- $5 = days, $6 = amount.
INSERT INTO invoice_line (invoice_id, engineer_id, level, day_rate, days, amount, audit_id)
VALUES ($1, $2, $3, $4, $5, $6, $7);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.int(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.parameter(pog.float(arg_5))
  |> pog.parameter(pog.float(arg_6))
  |> pog.parameter(pog.int(arg_7))
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
    issued_at: Option(Date),
    paid_at: Option(Date),
  )
}

/// invoice_list.sql — the invoices-table read model (FR-F1/FR-F4). One row per
/// invoice: the durable subject (project + client name, billing month) plus its
/// status AS OF $1, its line total (Σ invoice_line.amount), and the issue/pay
/// transition dates.
///
/// issued_at/paid_at. The lower bound of the issued/paid status span — the day the
/// issue_invoice/pay_invoice transition occurred — or NULL when that transition has
/// not happened as-of $1 (the transition day is after the rail date, or never).
/// The `?` alias suffix forces Squirrel to generate Option(Date) (the seed has no
/// unissued/unpaid invoice, so it would otherwise infer non-null and decode-fail).
/// The as-of status above still resolves independently via @>.
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
    use issued_at <- decode.field(
      7,
      decode.optional(pog.calendar_date_decoder()),
    )
    use paid_at <- decode.field(8, decode.optional(pog.calendar_date_decoder()))
    decode.success(InvoiceListRow(
      id:,
      project:,
      client:,
      billing_from:,
      billing_to:,
      status:,
      total:,
      issued_at:,
      paid_at:,
    ))
  }

  "-- invoice_list.sql — the invoices-table read model (FR-F1/FR-F4). One row per
-- invoice: the durable subject (project + client name, billing month) plus its
-- status AS OF $1, its line total (Σ invoice_line.amount), and the issue/pay
-- transition dates.
--
-- issued_at/paid_at. The lower bound of the issued/paid status span — the day the
-- issue_invoice/pay_invoice transition occurred — or NULL when that transition has
-- not happened as-of $1 (the transition day is after the rail date, or never).
-- The `?` alias suffix forces Squirrel to generate Option(Date) (the seed has no
-- unissued/unpaid invoice, so it would otherwise infer non-null and decode-fail).
-- The as-of status above still resolves independently via @>.
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
  ), 0)::numeric AS total,
  (
    SELECT lower(issued.status_during)
      FROM invoice_status issued
     WHERE issued.invoice_id = invoice.id
       AND issued.status = 'issued'
       AND lower(issued.status_during) <= $1::date
     LIMIT 1
  ) AS \"issued_at?\",
  (
    SELECT lower(paid.status_during)
      FROM invoice_status paid
     WHERE paid.invoice_id = invoice.id
       AND paid.status = 'paid'
       AND lower(paid.status_during) <= $1::date
     LIMIT 1
  ) AS \"paid_at?\"
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

/// A row you get from running the `invoice_lock` query
/// defined in `./src/tempo/server/sql/invoice_lock.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceLockRow {
  InvoiceLockRow(id: Int)
}

/// invoice_lock.sql — take a row lock on the invoice anchor before reading its
/// status, so a status transition's read-modify-write is serialized per invoice.
///
/// Under READ COMMITTED two concurrent transitions can otherwise both read the same
/// pre-status and both commit (issue #2: double-pay). Locking the anchor with
/// `FOR UPDATE` makes the second transaction block until the first commits, then
/// re-read the now-changed status and fail the transition guard. $1 = invoice_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_lock(
  db: pog.Connection,
  id: Int,
) -> Result(pog.Returned(InvoiceLockRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(InvoiceLockRow(id:))
  }

  "-- invoice_lock.sql — take a row lock on the invoice anchor before reading its
-- status, so a status transition's read-modify-write is serialized per invoice.
--
-- Under READ COMMITTED two concurrent transitions can otherwise both read the same
-- pre-status and both commit (issue #2: double-pay). Locking the anchor with
-- `FOR UPDATE` makes the second transaction block until the first commits, then
-- re-read the now-changed status and fail the transition guard. $1 = invoice_id.
SELECT id FROM invoice WHERE id = $1 FOR UPDATE;
"
  |> pog.query
  |> pog.parameter(pog.int(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `invoice_next_id` query
/// defined in `./src/tempo/server/sql/invoice_next_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InvoiceNextIdRow {
  InvoiceNextIdRow(id: Int)
}

/// invoice_next_id.sql — reserve the next invoice id from its sequence.
///
/// Called before draft_invoice records any invoice fact: the handler threads this id
/// into the Invoice anchor, its subject, status, and lines in one transaction, so
/// nothing is read back.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_next_id(
  db: pog.Connection,
) -> Result(pog.Returned(InvoiceNextIdRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(InvoiceNextIdRow(id:))
  }

  "-- invoice_next_id.sql — reserve the next invoice id from its sequence.
--
-- Called before draft_invoice records any invoice fact: the handler threads this id
-- into the Invoice anchor, its subject, status, and lines in one transaction, so
-- nothing is read back.
SELECT nextval('invoice_id_seq')::int AS id;
"
  |> pog.query
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

/// invoice_status_open.sql — open a status span for an invoice from $3 onward. Last
/// param is the audit_id. $1 = invoice_id, $2 = status, $3 = from.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn invoice_status_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
  arg_4: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_status_open.sql — open a status span for an invoice from $3 onward. Last
-- param is the audit_id. $1 = invoice_id, $2 = status, $3 = from.
INSERT INTO invoice_status (invoice_id, status, status_during, audit_id)
VALUES ($1, $2, daterange($3::date, NULL, '[)'), $4);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// invoice_subject_insert.sql — the immutable 1:1 invoice subject (project + billing
/// month), contained by the project run. Last param is the audit_id. $1 = invoice_id,
/// $2 = project_id, $3 = billing_from, $4 = billing_to.
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
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- invoice_subject_insert.sql — the immutable 1:1 invoice subject (project + billing
-- month), contained by the project run. Last param is the audit_id. $1 = invoice_id,
-- $2 = project_id, $3 = billing_from, $4 = billing_to.
INSERT INTO invoice_subject (invoice_id, project_id, billing_period, audit_id)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'), $5);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `leave_balance` query
/// defined in `./src/tempo/server/sql/leave_balance.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type LeaveBalanceRow {
  LeaveBalanceRow(policied: Bool, balance: Float)
}

/// leave_balance.sql — an engineer's leave balance for a kind as of a date: days
/// accrued (employment ∩ role ∩ leave_policy[kind, level], leap-aware) minus days
/// taken, both up to as_of. `policied` is false when the kind has no policy at all —
/// then it is unlimited and the take_leave guard does not apply. The balance is a
/// pure calculation at any past or future date; nothing is stored.
/// $1 = engineer_id, $2 = kind, $3 = as_of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_balance(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
) -> Result(pog.Returned(LeaveBalanceRow), pog.QueryError) {
  let decoder = {
    use policied <- decode.field(0, decode.bool)
    use balance <- decode.field(1, pog.numeric_decoder())
    decode.success(LeaveBalanceRow(policied:, balance:))
  }

  "-- leave_balance.sql — an engineer's leave balance for a kind as of a date: days
-- accrued (employment ∩ role ∩ leave_policy[kind, level], leap-aware) minus days
-- taken, both up to as_of. `policied` is false when the kind has no policy at all —
-- then it is unlimited and the take_leave guard does not apply. The balance is a
-- pure calculation at any past or future date; nothing is stored.
-- $1 = engineer_id, $2 = kind, $3 = as_of date.
SELECT
  EXISTS (SELECT 1 FROM leave_policy WHERE kind = $2) AS policied,
  (accrued_leave($1, $2, $3::date) - taken_leave($1, $2, $3::date))::numeric AS balance;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `leave_balances` query
/// defined in `./src/tempo/server/sql/leave_balances.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type LeaveBalancesRow {
  LeaveBalancesRow(
    engineer_id: Int,
    engineer: String,
    annual: Float,
    sick: Float,
  )
}

/// leave_balances.sql — each engineer employed as of $1 with their annual and sick
/// leave balance (accrued − taken, rounded to one day) on that date, for the board
/// readout; it recomputes as the board's date moves. $1 = the as-of date.
///
/// engineer_id is emitted alongside the name so the people-roster read model can
/// join the annual balance to people_list.sql rows by id (the board readout keys by
/// name; /api/people keys by id).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_balances(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(LeaveBalancesRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use engineer <- decode.field(1, decode.string)
    use annual <- decode.field(2, pog.numeric_decoder())
    use sick <- decode.field(3, pog.numeric_decoder())
    decode.success(LeaveBalancesRow(engineer_id:, engineer:, annual:, sick:))
  }

  "-- leave_balances.sql — each engineer employed as of $1 with their annual and sick
-- leave balance (accrued − taken, rounded to one day) on that date, for the board
-- readout; it recomputes as the board's date moves. $1 = the as-of date.
--
-- engineer_id is emitted alongside the name so the people-roster read model can
-- join the annual balance to people_list.sql rows by id (the board readout keys by
-- name; /api/people keys by id).
SELECT
  engineer.id AS engineer_id,
  coalesce(engineer_current.name, '') AS engineer,
  round(accrued_leave(engineer.id, 'annual', $1::date)
        - taken_leave(engineer.id, 'annual', $1::date), 1)::numeric AS annual,
  round(accrued_leave(engineer.id, 'sick', $1::date)
        - taken_leave(engineer.id, 'sick', $1::date), 1)::numeric AS sick
FROM engineer
JOIN engineer_current ON engineer_current.id = engineer.id
WHERE EXISTS (
  SELECT 1 FROM employment
  WHERE employment.engineer_id = engineer.id
    AND employment.employed_during @> $1::date
)
ORDER BY engineer;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `leave_check` query
/// defined in `./src/tempo/server/sql/leave_check.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type LeaveCheckRow {
  LeaveCheckRow(policied: Bool, available: Float, requested: Float)
}

/// leave_check.sql — the take_leave guard input for a [valid_from, valid_to) leave:
/// `available` is the balance on return (accrued − taken as of valid_to, the new
/// leave not yet recorded), `requested` the calendar days (valid_to − valid_from), and
/// `policied` whether the kind has any policy (false ⇒ unlimited, no guard). The
/// handler rejects when policied AND available < requested.
/// $1 = engineer_id, $2 = kind, $3 = valid_from, $4 = valid_to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_check(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
  arg_4: Date,
) -> Result(pog.Returned(LeaveCheckRow), pog.QueryError) {
  let decoder = {
    use policied <- decode.field(0, decode.bool)
    use available <- decode.field(1, pog.numeric_decoder())
    use requested <- decode.field(2, pog.numeric_decoder())
    decode.success(LeaveCheckRow(policied:, available:, requested:))
  }

  "-- leave_check.sql — the take_leave guard input for a [valid_from, valid_to) leave:
-- `available` is the balance on return (accrued − taken as of valid_to, the new
-- leave not yet recorded), `requested` the calendar days (valid_to − valid_from), and
-- `policied` whether the kind has any policy (false ⇒ unlimited, no guard). The
-- handler rejects when policied AND available < requested.
-- $1 = engineer_id, $2 = kind, $3 = valid_from, $4 = valid_to.
SELECT
  EXISTS (SELECT 1 FROM leave_policy WHERE kind = $2) AS policied,
  (accrued_leave($1, $2, $4::date) - taken_leave($1, $2, $4::date))::numeric AS available,
  ($4::date - $3::date)::numeric AS requested;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
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

/// A row you get from running the `leave_history` query
/// defined in `./src/tempo/server/sql/leave_history.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type LeaveHistoryRow {
  LeaveHistoryRow(kind: String, valid_from: Date, valid_to: Date)
}

/// leave_history.sql — one engineer's full leave timeline for the detail read model
/// (GET /api/engineers/:id; the LeaveRecord list). Param: $1 = engineer_id.
///
/// Every leave period-row for the engineer, decomposed to plain dates: kind,
/// lower(on_leave_during) AS valid_from, upper(on_leave_during) AS valid_to. A leave
/// window always has an end, so upper(on_leave_during) is non-null for every seed
/// row. Not as-of filtered — the detail page lists all leave. Ordered oldest-first.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_history(
  db: pog.Connection,
  leave_engineer_id: Int,
) -> Result(pog.Returned(LeaveHistoryRow), pog.QueryError) {
  let decoder = {
    use kind <- decode.field(0, decode.string)
    use valid_from <- decode.field(1, pog.calendar_date_decoder())
    use valid_to <- decode.field(2, pog.calendar_date_decoder())
    decode.success(LeaveHistoryRow(kind:, valid_from:, valid_to:))
  }

  "-- leave_history.sql — one engineer's full leave timeline for the detail read model
-- (GET /api/engineers/:id; the LeaveRecord list). Param: $1 = engineer_id.
--
-- Every leave period-row for the engineer, decomposed to plain dates: kind,
-- lower(on_leave_during) AS valid_from, upper(on_leave_during) AS valid_to. A leave
-- window always has an end, so upper(on_leave_during) is non-null for every seed
-- row. Not as-of filtered — the detail page lists all leave. Ordered oldest-first.
SELECT
  leave.kind,
  lower(leave.on_leave_during) AS valid_from,
  upper(leave.on_leave_during) AS valid_to
FROM leave
WHERE leave.engineer_id = $1
ORDER BY lower(leave.on_leave_during);
"
  |> pog.query
  |> pog.parameter(pog.int(leave_engineer_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `leave_policy_list` query
/// defined in `./src/tempo/server/sql/leave_policy_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type LeavePolicyListRow {
  LeavePolicyListRow(kind: String, level: Int, days_per_year: Float)
}

/// leave_policy_list.sql — the leave-accrual policy in force as of $1 (GET
/// /api/settings?as_of=$1; the leave-policy table on the Settings page; FR-ST3). One
/// row per (kind, level) whose policy span covers $1: kind + level + days_per_year,
/// ordered by kind then level. A (kind, level) with no policy row covering $1 is
/// absent from the list and is treated as unlimited (the take_leave guard does not
/// fire for it). Param: $1 = the as-of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn leave_policy_list(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(LeavePolicyListRow), pog.QueryError) {
  let decoder = {
    use kind <- decode.field(0, decode.string)
    use level <- decode.field(1, decode.int)
    use days_per_year <- decode.field(2, pog.numeric_decoder())
    decode.success(LeavePolicyListRow(kind:, level:, days_per_year:))
  }

  "-- leave_policy_list.sql — the leave-accrual policy in force as of $1 (GET
-- /api/settings?as_of=$1; the leave-policy table on the Settings page; FR-ST3). One
-- row per (kind, level) whose policy span covers $1: kind + level + days_per_year,
-- ordered by kind then level. A (kind, level) with no policy row covering $1 is
-- absent from the list and is treated as unlimited (the take_leave guard does not
-- fire for it). Param: $1 = the as-of date.
SELECT
  leave_policy.kind,
  leave_policy.level,
  leave_policy.days_per_year
FROM leave_policy
WHERE leave_policy.effective_during @> $1::date
ORDER BY leave_policy.kind, leave_policy.level;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// leave_take.sql — assert an engineer on leave over a bounded period, contained by
/// employment (leave_within_employment PERIOD FK). Last param is the audit_id.
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
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- leave_take.sql — assert an engineer on leave over a bounded period, contained by
-- employment (leave_within_employment PERIOD FK). Last param is the audit_id.
-- $1 = engineer_id, $2 = kind, $3 = from, $4 = to.
INSERT INTO leave (engineer_id, kind, on_leave_during, audit_id)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'), $5);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.parameter(pog.int(arg_5))
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
  sum(prorated_salary(sub.monthly_salary, sub.sub_period, params.month))::numeric
    AS amount,
  sum(range_days(sub.sub_period))::numeric AS days
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

/// payroll_line_insert.sql — one prorated payroll line. Last param is the audit_id.
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
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- payroll_line_insert.sql — one prorated payroll line. Last param is the audit_id.
-- $1 = run_id, $2 = engineer_id, $3 = amount, $4 = days.
INSERT INTO payroll_line (run_id, engineer_id, amount, days, audit_id)
VALUES ($1, $2, $3, $4, $5);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.float(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.parameter(pog.int(arg_5))
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

/// payroll_period_insert.sql — the immutable 1:1 payroll period (one run per month).
/// Last param is the audit_id. $1 = run_id, $2 = from, $3 = to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_period_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
  arg_3: Date,
  arg_4: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- payroll_period_insert.sql — the immutable 1:1 payroll period (one run per month).
-- Last param is the audit_id. $1 = run_id, $2 = from, $3 = to.
INSERT INTO payroll_period (run_id, period, audit_id)
VALUES ($1, daterange($2::date, $3::date, '[)'), $4);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `payroll_reconciliation` query
/// defined in `./src/tempo/server/sql/payroll_reconciliation.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PayrollReconciliationRow {
  PayrollReconciliationRow(
    run_id: Option(Int),
    engineer: String,
    preview_amount: Float,
    preview_days: Float,
    paid_amount: Option(Float),
    paid_days: Option(Float),
  )
}

/// payroll_reconciliation.sql — the month's payroll panel: the LIVE recompute over
/// current facts side by side with the MATERIALIZED payroll_line frozen at run time
/// (FR-F5/FR-F6). One row per engineer present on EITHER side, so an employed
/// engineer not yet in the run (preview only) and an engineer in the run but no
/// longer employed (paid only) both surface.
///
/// Params: $1 = month start (date), $2 = month end (date, exclusive). The month
/// range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
/// Squirrel boundary.
///
/// The LIVE side (preview_amount/preview_days) reuses payroll_amounts' proration
/// CTE verbatim: each employment ∩ engineer_role(level) ∩ salary-version ∩ month
/// sub-period, summed at monthly_salary × days_in_subperiod / days_in_month. A
/// back-dated promotion or salary revision shifts these slices, so the preview is
/// "what should be paid now".
///
/// The PAID side (paid_amount/paid_days) reads the payroll_line a RunPayroll wrote,
/// via the run whose period OVERLAPS the month (payroll_period.period && month). It
/// is NULL until a run exists, and frozen once written, so it does NOT move when a
/// fact is back-dated. The variance preview − paid is the back-pay the correction
/// owes — the bitemporal payoff.
///
/// run_id (nullable) is the run for the month, carried on every row so the caller
/// knows whether a materialized run exists without a second query. FULL OUTER JOIN
/// on engineer_id unions the two sides; ordered by engineer name.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_reconciliation(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Date,
) -> Result(pog.Returned(PayrollReconciliationRow), pog.QueryError) {
  let decoder = {
    use run_id <- decode.field(0, decode.optional(decode.int))
    use engineer <- decode.field(1, decode.string)
    use preview_amount <- decode.field(2, pog.numeric_decoder())
    use preview_days <- decode.field(3, pog.numeric_decoder())
    use paid_amount <- decode.field(4, decode.optional(pog.numeric_decoder()))
    use paid_days <- decode.field(5, decode.optional(pog.numeric_decoder()))
    decode.success(PayrollReconciliationRow(
      run_id:,
      engineer:,
      preview_amount:,
      preview_days:,
      paid_amount:,
      paid_days:,
    ))
  }

  "-- payroll_reconciliation.sql — the month's payroll panel: the LIVE recompute over
-- current facts side by side with the MATERIALIZED payroll_line frozen at run time
-- (FR-F5/FR-F6). One row per engineer present on EITHER side, so an employed
-- engineer not yet in the run (preview only) and an engineer in the run but no
-- longer employed (paid only) both surface.
--
-- Params: $1 = month start (date), $2 = month end (date, exclusive). The month
-- range is built in SQL as daterange($1, $2, '[)'); only scalar dates cross the
-- Squirrel boundary.
--
-- The LIVE side (preview_amount/preview_days) reuses payroll_amounts' proration
-- CTE verbatim: each employment ∩ engineer_role(level) ∩ salary-version ∩ month
-- sub-period, summed at monthly_salary × days_in_subperiod / days_in_month. A
-- back-dated promotion or salary revision shifts these slices, so the preview is
-- \"what should be paid now\".
--
-- The PAID side (paid_amount/paid_days) reads the payroll_line a RunPayroll wrote,
-- via the run whose period OVERLAPS the month (payroll_period.period && month). It
-- is NULL until a run exists, and frozen once written, so it does NOT move when a
-- fact is back-dated. The variance preview − paid is the back-pay the correction
-- owes — the bitemporal payoff.
--
-- run_id (nullable) is the run for the month, carried on every row so the caller
-- knows whether a materialized run exists without a second query. FULL OUTER JOIN
-- on engineer_id unions the two sides; ordered by engineer name.
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
),
preview AS (
  SELECT
    sub.engineer_id,
    sum(prorated_salary(sub.monthly_salary, sub.sub_period, params.month))::numeric
      AS amount,
    sum(range_days(sub.sub_period))::numeric AS days
  FROM sub
  CROSS JOIN params
  WHERE NOT isempty(sub.sub_period)
  GROUP BY sub.engineer_id
),
run AS (
  SELECT payroll_period.run_id
  FROM params
  JOIN payroll_period ON payroll_period.period && params.month
),
paid AS (
  SELECT
    payroll_line.engineer_id,
    payroll_line.amount::numeric AS amount,
    payroll_line.days::numeric AS days
  FROM payroll_line
  JOIN run ON run.run_id = payroll_line.run_id
)
SELECT
  (SELECT run_id FROM run) AS \"run_id?\",
  coalesce(engineer.name, '') AS engineer,
  coalesce(preview.amount, 0)::numeric AS preview_amount,
  coalesce(preview.days, 0)::numeric AS preview_days,
  paid.amount AS \"paid_amount?\",
  paid.days AS \"paid_days?\"
FROM preview
FULL OUTER JOIN paid ON paid.engineer_id = preview.engineer_id
JOIN engineer_current engineer
  ON engineer.id = coalesce(preview.engineer_id, paid.engineer_id)
ORDER BY engineer.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// payroll_run_create.sql — insert the payroll run identity (ID-ONLY anchor) at a reserved id.
///
/// Step 1 of run_payroll. The id is reserved up-front from payroll_run_id_seq
/// (payroll_run_next_id) and supplied as $1, so this is a plain insert with no
/// RETURNING. The period/lines are separate facts recorded alongside.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_run_create(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- payroll_run_create.sql — insert the payroll run identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of run_payroll. The id is reserved up-front from payroll_run_id_seq
-- (payroll_run_next_id) and supplied as $1, so this is a plain insert with no
-- RETURNING. The period/lines are separate facts recorded alongside.
INSERT INTO payroll_run (id) VALUES ($1);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `payroll_run_next_id` query
/// defined in `./src/tempo/server/sql/payroll_run_next_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PayrollRunNextIdRow {
  PayrollRunNextIdRow(id: Int)
}

/// payroll_run_next_id.sql — reserve the next payroll run id from its sequence.
///
/// Called before run_payroll records any payroll fact: the handler threads this id
/// into the PayrollRun anchor, its period, and lines in one transaction, so nothing is
/// read back.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn payroll_run_next_id(
  db: pog.Connection,
) -> Result(pog.Returned(PayrollRunNextIdRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(PayrollRunNextIdRow(id:))
  }

  "-- payroll_run_next_id.sql — reserve the next payroll run id from its sequence.
--
-- Called before run_payroll records any payroll fact: the handler threads this id
-- into the PayrollRun anchor, its period, and lines in one transaction, so nothing is
-- read back.
SELECT nextval('payroll_run_id_seq')::int AS id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `people_list` query
/// defined in `./src/tempo/server/sql/people_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PeopleListRow {
  PeopleListRow(
    engineer_id: Int,
    name: String,
    email: String,
    level: Int,
    day_rate: Float,
    allocated_fraction: Float,
    projects: String,
    leave_kind: Option(String),
  )
}

/// people_list.sql — the people-roster read model (GET /api/people?as_of=$1). One
/// row per EMPLOYED engineer as of $1, carrying everything the roster table needs
/// that the org board cannot supply: the engineer_id and email (BoardRow has
/// neither), the as-of level and resolved day_rate (present for EVERY employed
/// engineer, not just allocated ones — board day_rate lives only on engaged rows),
/// the summed allocation fraction across all the engineer's projects, the covering
/// leave kind if any, and a comma-joined list of the project titles the engineer is
/// allocated to on the date.
///
/// Param: $1 = the as-of date.
///
/// Identity + level + rate. employment(@>$1) anchors the employed set; the name and
/// email come from the engineer_current latest-read view; the as-of level from
/// engineer_role(@>$1); the charge rate from rate_card(level, effective_during @>$1)
/// (the same two-hop role x rate_card join the board uses). These are INNER joins —
/// an employed engineer always has a role and a rate, so day_rate is non-null.
///
/// Allocation rollup. A correlated LATERAL aggregates the engineer's allocations
/// covering $1 (joined to project_current for the titles): SUM(fraction) coalesced
/// to 0 for a bench/leave engineer, and string_agg of distinct project titles. The
/// titles are joined in one comma-separated string (the domain layer splits it back
/// into a list); an engineer with no covering allocation gets '' which the domain
/// reads as the empty project list.
///
/// Leave. A LEFT JOIN LATERAL returns the covering leave fact's kind (NULL when not
/// on leave — the lateral join makes Squirrel infer leave_kind as Option(String)
/// rather than a non-null String that would decode-fail off the road); the domain
/// layer collapses status to RosterOnLeave(kind) when present, else
/// RosterOnProjects(titles) when allocated, else RosterUnassigned. The annual leave
/// balance is NOT joined here — the domain joins leave_balances.sql by engineer_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn people_list(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(PeopleListRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    use level <- decode.field(3, decode.int)
    use day_rate <- decode.field(4, pog.numeric_decoder())
    use allocated_fraction <- decode.field(5, pog.numeric_decoder())
    use projects <- decode.field(6, decode.string)
    use leave_kind <- decode.field(7, decode.optional(decode.string))
    decode.success(PeopleListRow(
      engineer_id:,
      name:,
      email:,
      level:,
      day_rate:,
      allocated_fraction:,
      projects:,
      leave_kind:,
    ))
  }

  "-- people_list.sql — the people-roster read model (GET /api/people?as_of=$1). One
-- row per EMPLOYED engineer as of $1, carrying everything the roster table needs
-- that the org board cannot supply: the engineer_id and email (BoardRow has
-- neither), the as-of level and resolved day_rate (present for EVERY employed
-- engineer, not just allocated ones — board day_rate lives only on engaged rows),
-- the summed allocation fraction across all the engineer's projects, the covering
-- leave kind if any, and a comma-joined list of the project titles the engineer is
-- allocated to on the date.
--
-- Param: $1 = the as-of date.
--
-- Identity + level + rate. employment(@>$1) anchors the employed set; the name and
-- email come from the engineer_current latest-read view; the as-of level from
-- engineer_role(@>$1); the charge rate from rate_card(level, effective_during @>$1)
-- (the same two-hop role x rate_card join the board uses). These are INNER joins —
-- an employed engineer always has a role and a rate, so day_rate is non-null.
--
-- Allocation rollup. A correlated LATERAL aggregates the engineer's allocations
-- covering $1 (joined to project_current for the titles): SUM(fraction) coalesced
-- to 0 for a bench/leave engineer, and string_agg of distinct project titles. The
-- titles are joined in one comma-separated string (the domain layer splits it back
-- into a list); an engineer with no covering allocation gets '' which the domain
-- reads as the empty project list.
--
-- Leave. A LEFT JOIN LATERAL returns the covering leave fact's kind (NULL when not
-- on leave — the lateral join makes Squirrel infer leave_kind as Option(String)
-- rather than a non-null String that would decode-fail off the road); the domain
-- layer collapses status to RosterOnLeave(kind) when present, else
-- RosterOnProjects(titles) when allocated, else RosterUnassigned. The annual leave
-- balance is NOT joined here — the domain joins leave_balances.sql by engineer_id.
SELECT
  engineer.id AS engineer_id,
  coalesce(engineer_current.name, '') AS name,
  coalesce(engineer_current.email, '') AS email,
  engineer_role.level,
  rate_card.day_rate,
  coalesce(alloc.allocated_fraction, 0)::numeric AS allocated_fraction,
  coalesce(alloc.projects, '') AS projects,
  on_leave.kind AS leave_kind
FROM employment
JOIN engineer ON engineer.id = employment.engineer_id
JOIN engineer_current ON engineer_current.id = engineer.id
JOIN engineer_role ON engineer_role.engineer_id = engineer.id
                  AND engineer_role.held_during @> $1::date
JOIN rate_card ON rate_card.level = engineer_role.level
              AND rate_card.effective_during @> $1::date
LEFT JOIN LATERAL (
  SELECT leave.kind FROM leave
   WHERE leave.engineer_id = engineer.id
     AND leave.on_leave_during @> $1::date
   LIMIT 1
) on_leave ON true
LEFT JOIN LATERAL (
  SELECT sum(allocation.fraction) AS allocated_fraction,
         string_agg(DISTINCT coalesce(project_current.title, ''), ', '
                    ORDER BY coalesce(project_current.title, '')) AS projects
    FROM allocation
    JOIN project_run ON project_run.project_id = allocation.project_id
                    AND project_run.active_during @> $1::date
    JOIN project_current ON project_current.id = allocation.project_id
   WHERE allocation.engineer_id = engineer.id
     AND allocation.allocated_during @> $1::date
) alloc ON true
WHERE employment.employed_during @> $1::date
ORDER BY name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
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
/// Params: $1 = period start (date), $2 = period end (date, exclusive) — the period
/// range daterange($1, $2, '[)'). Only scalar dates cross the boundary.
///
/// Returned components (caller computes the rest):
/// revenue          — Σ fraction × day_rate × days over each allocation ∩
/// engineer_role(level) ∩ rate_card-version ∩ period sub-period
/// (ACCRUAL, capacity-based): the billable value of the capacity
/// worked, recognized as the work is performed — the SAME basis
/// as utilization and cost, independent of invoicing. Leave does
/// not reduce it.
/// cost             — settled MONTH BY MONTH over the (month-aligned) period: the
/// SNAPSHOT Σ payroll_line.amount where a payroll run covers the
/// month (actuals, carrying any back-dated variance), the EXPECTED
/// salary per employed engineer (the payroll_amounts proration)
/// where no run covers it yet — so a not-yet-run/future month
/// shows its expected cost rather than $0. Summed across months.
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
/// * Revenue is recomputed from the capacity facts (allocation × role × rate_card)
/// clipped to the period, so it reflects the work performed regardless of the
/// invoice lifecycle; it equals the billed amount once a month is invoiced at the
/// agreed rates, but does not wait on (or require) an invoice.
/// * Cost is settled MONTH BY MONTH over the (month-aligned) window. A month with a
/// payroll run contributes its SNAPSHOT payroll_line (what was paid — NOT a
/// recomputation, so a back-dated variance shows; PRD §8). A month with no run yet
/// contributes the EXPECTED salary (the payroll_amounts proration), so a future /
/// not-yet-run month reads its expected cost, not $0 — the cost-side mirror of the
/// capacity revenue. The two are mutually exclusive per month (NOT EXISTS), so
/// they never double-count. The caller's windows are month-aligned (month / YTD).
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
-- Params: $1 = period start (date), $2 = period end (date, exclusive) — the period
-- range daterange($1, $2, '[)'). Only scalar dates cross the boundary.
--
-- Returned components (caller computes the rest):
--   revenue          — Σ fraction × day_rate × days over each allocation ∩
--                      engineer_role(level) ∩ rate_card-version ∩ period sub-period
--                      (ACCRUAL, capacity-based): the billable value of the capacity
--                      worked, recognized as the work is performed — the SAME basis
--                      as utilization and cost, independent of invoicing. Leave does
--                      not reduce it.
--   cost             — settled MONTH BY MONTH over the (month-aligned) period: the
--                      SNAPSHOT Σ payroll_line.amount where a payroll run covers the
--                      month (actuals, carrying any back-dated variance), the EXPECTED
--                      salary per employed engineer (the payroll_amounts proration)
--                      where no run covers it yet — so a not-yet-run/future month
--                      shows its expected cost rather than $0. Summed across months.
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
--   * Revenue is recomputed from the capacity facts (allocation × role × rate_card)
--     clipped to the period, so it reflects the work performed regardless of the
--     invoice lifecycle; it equals the billed amount once a month is invoiced at the
--     agreed rates, but does not wait on (or require) an invoice.
--   * Cost is settled MONTH BY MONTH over the (month-aligned) window. A month with a
--     payroll run contributes its SNAPSHOT payroll_line (what was paid — NOT a
--     recomputation, so a back-dated variance shows; PRD §8). A month with no run yet
--     contributes the EXPECTED salary (the payroll_amounts proration), so a future /
--     not-yet-run month reads its expected cost, not $0 — the cost-side mirror of the
--     capacity revenue. The two are mutually exclusive per month (NOT EXISTS), so
--     they never double-count. The caller's windows are month-aligned (month / YTD).
WITH params AS (
  SELECT daterange($1::date, $2::date, '[)') AS period
),
months AS (
  -- one calendar-month bucket per month in the period. The period is month-aligned
  -- (the caller passes first-of-month .. first-of-next-month, or first-of-year ..
  -- first-of-next-month), so cost can be settled per month: actuals where a payroll
  -- run covers the month, an estimate where none does yet.
  SELECT
    daterange(
      month_start::date,
      (month_start + interval '1 month')::date,
      '[)'
    ) AS span
  FROM params,
    generate_series(
      date_trunc('month', lower(params.period)),
      date_trunc('month', upper(params.period) - 1),
      interval '1 month'
    ) AS month_start
),
emp AS (
  -- employed days in the period per engineer (employment ∩ period)
  SELECT
    employment.engineer_id,
    sum(range_days(employment.employed_during * params.period))::numeric
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
        * range_days(allocation.allocated_during * employment.employed_during
                     * params.period))::numeric AS utilization_days
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
  -- revenue (ACCRUAL, capacity-based): the billable value of the capacity each
  -- engineer worked in the period — Σ fraction × day_rate × days over each
  -- allocation ∩ engineer_role(level) ∩ rate_card-version ∩ period sub-period.
  -- Recognized as the work is performed, on the SAME capacity basis as utilization
  -- and cost, independent of whether/when an invoice is drafted or issued (the
  -- invoice lifecycle governs billing/cash, not P&L revenue — ADR-043). Splitting on
  -- the role version AND the rate_card version bills a mid-period promotion or rate
  -- revision day-accurate at each level's rate. Leave does NOT reduce it (capacity,
  -- not hours) — symmetric with utilization_days.
  SELECT
    allocation.engineer_id,
    sum(allocation.fraction
        * recognized_revenue(
            rate_card.day_rate,
            allocation.allocated_during * engineer_role.held_during
              * rate_card.effective_during * params.period))::numeric
      AS revenue
  FROM params
  JOIN allocation    ON allocation.allocated_during && params.period
  JOIN engineer_role ON engineer_role.engineer_id = allocation.engineer_id
                    AND engineer_role.held_during && allocation.allocated_during
                    AND engineer_role.held_during && params.period
  JOIN rate_card     ON rate_card.level = engineer_role.level
                    AND rate_card.effective_during && engineer_role.held_during
                    AND rate_card.effective_during && params.period
  WHERE NOT isempty(allocation.allocated_during * engineer_role.held_during
                    * rate_card.effective_during * params.period)
  GROUP BY allocation.engineer_id
),
actual_cost AS (
  -- months WITH a payroll run: the SNAPSHOT amount paid each engineer (what was
  -- actually paid, carrying any back-dated variance).
  SELECT
    payroll_line.engineer_id,
    sum(payroll_line.amount)::numeric AS cost
  FROM months
  JOIN payroll_period ON payroll_period.period && months.span
  JOIN payroll_line   ON payroll_line.run_id = payroll_period.run_id
  GROUP BY payroll_line.engineer_id
),
estimated_cost AS (
  -- months with NO payroll run yet (a future / not-yet-run month, or a gap): the
  -- EXPECTED salary per employed engineer — the SAME proration as payroll_amounts
  -- (employment ∩ role-version ∩ salary-version ∩ month, full salary, leave-blind),
  -- so the estimate equals the run that later materializes the month. The NOT EXISTS
  -- excludes any month a run already covers, so actual and estimate never double-count.
  SELECT
    employment.engineer_id,
    sum(prorated_salary(
          salary.monthly_salary,
          employment.employed_during * engineer_role.held_during
            * salary.effective_during * months.span,
          months.span))::numeric AS cost
  FROM months
  JOIN employment    ON employment.employed_during && months.span
  JOIN engineer_role ON engineer_role.engineer_id = employment.engineer_id
                    AND engineer_role.held_during && employment.employed_during
                    AND engineer_role.held_during && months.span
  JOIN salary        ON salary.level = engineer_role.level
                    AND salary.effective_during && engineer_role.held_during
                    AND salary.effective_during && months.span
  WHERE NOT EXISTS (
    SELECT 1 FROM payroll_period WHERE payroll_period.period && months.span
  )
  AND NOT isempty(employment.employed_during * engineer_role.held_during
                  * salary.effective_during * months.span)
  GROUP BY employment.engineer_id
),
cost AS (
  -- per engineer: actuals for run-covered months + estimates for the rest
  SELECT engineer_id, sum(cost)::numeric AS cost
  FROM (
    SELECT engineer_id, cost FROM actual_cost
    UNION ALL
    SELECT engineer_id, cost FROM estimated_cost
  ) per_engineer
  GROUP BY engineer_id
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

/// project_create.sql — insert the project identity (ID-ONLY anchor) at a reserved id.
///
/// Step 1 of start_project. The id is reserved up-front from project_id_seq
/// (project_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
/// The run/profile/plan are separate facts recorded alongside.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_create(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_create.sql — insert the project identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of start_project. The id is reserved up-front from project_id_seq
-- (project_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
-- The run/profile/plan are separate facts recorded alongside.
INSERT INTO project (id) VALUES ($1);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_invoices` query
/// defined in `./src/tempo/server/sql/project_invoices.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectInvoicesRow {
  ProjectInvoicesRow(
    id: Int,
    project: String,
    client: String,
    billing_from: Date,
    billing_to: Date,
    status: String,
    total: Float,
    issued_at: Option(Date),
    paid_at: Option(Date),
  )
}

/// project_invoices.sql — one project's invoices for the detail read model (GET
/// /api/projects/:id; FR-CP7). Params: $1 = project_id, $2 = as-of.
///
/// invoice_list scoped to a single project: same columns and shape as invoice_list
/// (so it decodes through the reused Invoice codec) but filtered to
/// invoice_subject.project_id = $1. The status shown is the row covering $2 via `@>`,
/// so scrubbing the rail back shows a draft before its issue date (FR-F4); an invoice
/// with no status covering $2 is dropped (the status JOIN is INNER). The project name
/// is THIS project's title; the client name is reached through the project's run to
/// its contract's client (correlated LIMIT-1 so a multi-period project does not
/// multiply rows). Total is coalesce(Σ amount, 0) over the snapshot lines. Ordered by
/// billing month then id.
///
/// issued_at/paid_at. The lower bound of the issued/paid status span — the day the
/// issue_invoice/pay_invoice transition occurred — or NULL when that transition has
/// not happened as-of $2. The `?` alias suffix forces Squirrel to generate
/// Option(Date) rather than inferring non-null off the all-issued/all-paid seed.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_invoices(
  db: pog.Connection,
  invoice_subject_project_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(ProjectInvoicesRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use project <- decode.field(1, decode.string)
    use client <- decode.field(2, decode.string)
    use billing_from <- decode.field(3, pog.calendar_date_decoder())
    use billing_to <- decode.field(4, pog.calendar_date_decoder())
    use status <- decode.field(5, decode.string)
    use total <- decode.field(6, pog.numeric_decoder())
    use issued_at <- decode.field(
      7,
      decode.optional(pog.calendar_date_decoder()),
    )
    use paid_at <- decode.field(8, decode.optional(pog.calendar_date_decoder()))
    decode.success(ProjectInvoicesRow(
      id:,
      project:,
      client:,
      billing_from:,
      billing_to:,
      status:,
      total:,
      issued_at:,
      paid_at:,
    ))
  }

  "-- project_invoices.sql — one project's invoices for the detail read model (GET
-- /api/projects/:id; FR-CP7). Params: $1 = project_id, $2 = as-of.
--
-- invoice_list scoped to a single project: same columns and shape as invoice_list
-- (so it decodes through the reused Invoice codec) but filtered to
-- invoice_subject.project_id = $1. The status shown is the row covering $2 via `@>`,
-- so scrubbing the rail back shows a draft before its issue date (FR-F4); an invoice
-- with no status covering $2 is dropped (the status JOIN is INNER). The project name
-- is THIS project's title; the client name is reached through the project's run to
-- its contract's client (correlated LIMIT-1 so a multi-period project does not
-- multiply rows). Total is coalesce(Σ amount, 0) over the snapshot lines. Ordered by
-- billing month then id.
--
-- issued_at/paid_at. The lower bound of the issued/paid status span — the day the
-- issue_invoice/pay_invoice transition occurred — or NULL when that transition has
-- not happened as-of $2. The `?` alias suffix forces Squirrel to generate
-- Option(Date) rather than inferring non-null off the all-issued/all-paid seed.
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
  ), 0)::numeric AS total,
  (
    SELECT lower(issued.status_during)
      FROM invoice_status issued
     WHERE issued.invoice_id = invoice.id
       AND issued.status = 'issued'
       AND lower(issued.status_during) <= $2::date
     LIMIT 1
  ) AS \"issued_at?\",
  (
    SELECT lower(paid.status_during)
      FROM invoice_status paid
     WHERE paid.invoice_id = invoice.id
       AND paid.status = 'paid'
       AND lower(paid.status_during) <= $2::date
     LIMIT 1
  ) AS \"paid_at?\"
FROM invoice
JOIN invoice_subject ON invoice_subject.invoice_id = invoice.id
                    AND invoice_subject.project_id = $1
JOIN invoice_status ON invoice_status.invoice_id = invoice.id
                   AND invoice_status.status_during @> $2::date
ORDER BY lower(invoice_subject.billing_period), invoice.id;
"
  |> pog.query
  |> pog.parameter(pog.int(invoice_subject_project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_list` query
/// defined in `./src/tempo/server/sql/project_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectListRow {
  ProjectListRow(
    project_id: Int,
    title: String,
    client: String,
    budget: Float,
    target_completion: Date,
    team_size: Int,
    active: Bool,
  )
}

/// project_list.sql — the projects-directory read model (GET /api/projects?as_of=$1;
/// FR-CP5). One row per project that has a run: title, owning client, budget, target,
/// the team size on $1, and whether the run covers $1 (active). Param: $1 = as-of.
///
/// project_run anchors the project (every listed project has a run). A project may
/// have several historical runs, so DISTINCT ON (project_id) keeps the run covering
/// $1 (sorted first), falling back to the latest-started run for an ended project so
/// it still lists with active=false — a started project is marked active/ended, never
/// hidden. A run that has NOT started by $1 is excluded (lower(active_during) <= $1),
/// so a project dormant before its start is absent, not rendered as 'ended'.
/// The title comes from project_current, the client name through the run's contract
/// to client_current, and budget/target from a LATERAL latest-read project_plan
/// (DISTINCT ON by start desc, like project_plan_current; coalesced for a planless
/// project). team_size is a correlated count of DISTINCT engineers whose allocation
/// to this project covers $1 (0 for a dormant project). The inner DISTINCT ON picks
/// one run per project; the outer query orders the directory by title.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_list(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(ProjectListRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use client <- decode.field(2, decode.string)
    use budget <- decode.field(3, pog.numeric_decoder())
    use target_completion <- decode.field(4, pog.calendar_date_decoder())
    use team_size <- decode.field(5, decode.int)
    use active <- decode.field(6, decode.bool)
    decode.success(ProjectListRow(
      project_id:,
      title:,
      client:,
      budget:,
      target_completion:,
      team_size:,
      active:,
    ))
  }

  "-- project_list.sql — the projects-directory read model (GET /api/projects?as_of=$1;
-- FR-CP5). One row per project that has a run: title, owning client, budget, target,
-- the team size on $1, and whether the run covers $1 (active). Param: $1 = as-of.
--
-- project_run anchors the project (every listed project has a run). A project may
-- have several historical runs, so DISTINCT ON (project_id) keeps the run covering
-- $1 (sorted first), falling back to the latest-started run for an ended project so
-- it still lists with active=false — a started project is marked active/ended, never
-- hidden. A run that has NOT started by $1 is excluded (lower(active_during) <= $1),
-- so a project dormant before its start is absent, not rendered as 'ended'.
-- The title comes from project_current, the client name through the run's contract
-- to client_current, and budget/target from a LATERAL latest-read project_plan
-- (DISTINCT ON by start desc, like project_plan_current; coalesced for a planless
-- project). team_size is a correlated count of DISTINCT engineers whose allocation
-- to this project covers $1 (0 for a dormant project). The inner DISTINCT ON picks
-- one run per project; the outer query orders the directory by title.
SELECT project_id, title, client, budget, target_completion, team_size, active
FROM (
  SELECT DISTINCT ON (project_run.project_id)
    project_run.project_id,
    coalesce(project_current.title, '') AS title,
    coalesce(client_current.name, '') AS client,
    coalesce(plan.budget, 0)::numeric AS budget,
    coalesce(plan.target_completion, upper(project_run.active_during)) AS target_completion,
    (
      SELECT count(DISTINCT allocation.engineer_id)
        FROM allocation
       WHERE allocation.project_id = project_run.project_id
         AND allocation.allocated_during @> $1::date
    )::int AS team_size,
    (project_run.active_during @> $1::date) AS active
  FROM project_run
  JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
  JOIN client_current ON client_current.id = contract_terms.client_id
  JOIN project_current ON project_current.id = project_run.project_id
  LEFT JOIN LATERAL (
    SELECT project_plan.budget, project_plan.target_completion
      FROM project_plan
     WHERE project_plan.project_id = project_run.project_id
     ORDER BY lower(project_plan.planned_during) DESC
     LIMIT 1
  ) plan ON true
  WHERE lower(project_run.active_during) <= $1::date
  ORDER BY project_run.project_id,
           (project_run.active_during @> $1::date) DESC,
           lower(project_run.active_during) DESC
) ranked
ORDER BY title;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_next_id` query
/// defined in `./src/tempo/server/sql/project_next_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectNextIdRow {
  ProjectNextIdRow(id: Int)
}

/// project_next_id.sql — reserve the next project id from its sequence.
///
/// Called before start_project records any project fact: the handler threads this id
/// into the Project anchor, its run, profile, and plan in one transaction, so nothing
/// is read back.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_next_id(
  db: pog.Connection,
) -> Result(pog.Returned(ProjectNextIdRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(ProjectNextIdRow(id:))
  }

  "-- project_next_id.sql — reserve the next project id from its sequence.
--
-- Called before start_project records any project fact: the handler threads this id
-- into the Project anchor, its run, profile, and plan in one transaction, so nothing
-- is read back.
SELECT nextval('project_id_seq')::int AS id;
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

/// project_plan_upsert.sql — record a project plan from $2 onward in one statement (the
/// temporal upsert). The writable CTE runs the Change: FOR PORTION OF sets the new
/// values + audit_id on the [$2, NULL) portion of the covering version, and PG carves
/// off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id. If no version
/// covers $2 (the founding write at start_project) the Change touches nothing, so the
/// guarded INSERT opens the first [$2, NULL) span instead. $1 = project_id,
/// $2 = effective, $3 = budget, $4 = target_completion, $5 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_plan_upsert(
  db: pog.Connection,
  project_id: Int,
  arg_2: Date,
  arg_3: Float,
  arg_4: Date,
  audit_id: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_plan_upsert.sql — record a project plan from $2 onward in one statement (the
-- temporal upsert). The writable CTE runs the Change: FOR PORTION OF sets the new
-- values + audit_id on the [$2, NULL) portion of the covering version, and PG carves
-- off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id. If no version
-- covers $2 (the founding write at start_project) the Change touches nothing, so the
-- guarded INSERT opens the first [$2, NULL) span instead. $1 = project_id,
-- $2 = effective, $3 = budget, $4 = target_completion, $5 = audit_id.
WITH changed AS (
  UPDATE project_plan
     FOR PORTION OF planned_during FROM $2::date TO NULL
     SET budget = $3, target_completion = $4::date, audit_id = $5
   WHERE project_id = $1
     AND planned_during @> $2::date
  RETURNING 1
)
INSERT INTO project_plan
  (project_id, budget, target_completion, planned_during, audit_id)
SELECT $1, $3, $4::date, daterange($2::date, NULL, '[)'), $5
WHERE NOT EXISTS (SELECT 1 FROM changed);
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.float(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.parameter(pog.int(audit_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_profile_upsert.sql — record a project profile from $2 onward in one
/// statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
/// sets the new values + audit_id on the [$2, NULL) portion of the covering version,
/// and PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id.
/// If no version covers $2 (the founding write at start_project) the Change touches
/// nothing, so the guarded INSERT opens the first [$2, NULL) span instead.
/// $1 = project_id, $2 = effective, $3 = title, $4 = summary, $5 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_profile_upsert(
  db: pog.Connection,
  project_id: Int,
  arg_2: Date,
  arg_3: String,
  arg_4: String,
  audit_id: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_profile_upsert.sql — record a project profile from $2 onward in one
-- statement (the temporal upsert). The writable CTE runs the Change: FOR PORTION OF
-- sets the new values + audit_id on the [$2, NULL) portion of the covering version,
-- and PG carves off the unchanged [start, $2) remainder keeping its ORIGINAL audit_id.
-- If no version covers $2 (the founding write at start_project) the Change touches
-- nothing, so the guarded INSERT opens the first [$2, NULL) span instead.
-- $1 = project_id, $2 = effective, $3 = title, $4 = summary, $5 = audit_id.
WITH changed AS (
  UPDATE project_profile
     FOR PORTION OF recorded_during FROM $2::date TO NULL
     SET title = $3, summary = $4, audit_id = $5
   WHERE project_id = $1
     AND recorded_during @> $2::date
  RETURNING 1
)
INSERT INTO project_profile
  (project_id, title, summary, recorded_during, audit_id)
SELECT $1, $3, $4, daterange($2::date, NULL, '[)'), $5
WHERE NOT EXISTS (SELECT 1 FROM changed);
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.int(audit_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_requirement_clear.sql — step 1 of the FOR-PORTION-OF set. DELETE FOR
/// PORTION OF carves the target window [$2, $3) out of whatever (project, level) rows
/// cover any part of it, re-inserting the before/after remainders at their original
/// quantity (keeping their original audit_id). Step 2 (project_requirement_set.sql)
/// then inserts the new line over the now-vacant window.
///
/// `ON CONFLICT` cannot target the WITHOUT OVERLAPS PK (a GiST exclusion constraint),
/// so the set is delete-then-insert run in ONE transaction by the handler. A first
/// set over a vacant window deletes 0 rows (a harmless no-op); never branch on the
/// affected-row count. $1 = project_id, $2 = from, $3 = to, $4 = level.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_requirement_clear(
  db: pog.Connection,
  project_id: Int,
  arg_2: Date,
  arg_3: Date,
  arg_4: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_requirement_clear.sql — step 1 of the FOR-PORTION-OF set. DELETE FOR
-- PORTION OF carves the target window [$2, $3) out of whatever (project, level) rows
-- cover any part of it, re-inserting the before/after remainders at their original
-- quantity (keeping their original audit_id). Step 2 (project_requirement_set.sql)
-- then inserts the new line over the now-vacant window.
--
-- `ON CONFLICT` cannot target the WITHOUT OVERLAPS PK (a GiST exclusion constraint),
-- so the set is delete-then-insert run in ONE transaction by the handler. A first
-- set over a vacant window deletes 0 rows (a harmless no-op); never branch on the
-- affected-row count. $1 = project_id, $2 = from, $3 = to, $4 = level.
DELETE FROM project_requirement
   FOR PORTION OF required_during FROM $2::date TO $3::date
 WHERE project_id = $1 AND level = $4;
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_requirement_set.sql — step 2 of the FOR-PORTION-OF set: insert the demand
/// line over the window [$2, $3) that project_requirement_clear.sql just vacated. The
/// PERIOD-FK `requirement_within_project` rejects (→ ContainmentViolated) a window not
/// wholly contained by the project's run; the level/quantity CHECKs reject out-of-range
/// values (→ InvalidValue). $1 = project_id, $2 = from, $3 = to, $4 = level,
/// $5 = quantity, $6 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_requirement_set(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
  arg_3: Date,
  arg_4: Int,
  arg_5: Float,
  arg_6: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_requirement_set.sql — step 2 of the FOR-PORTION-OF set: insert the demand
-- line over the window [$2, $3) that project_requirement_clear.sql just vacated. The
-- PERIOD-FK `requirement_within_project` rejects (→ ContainmentViolated) a window not
-- wholly contained by the project's run; the level/quantity CHECKs reject out-of-range
-- values (→ InvalidValue). $1 = project_id, $2 = from, $3 = to, $4 = level,
-- $5 = quantity, $6 = audit_id.
INSERT INTO project_requirement
  (project_id, level, quantity, required_during, audit_id)
VALUES
  ($1, $4, $5, daterange($2::date, $3::date, '[)'), $6);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.parameter(pog.float(arg_5))
  |> pog.parameter(pog.int(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_requirements` query
/// defined in `./src/tempo/server/sql/project_requirements.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectRequirementsRow {
  ProjectRequirementsRow(
    project_id: Int,
    level: Int,
    quantity: Float,
    valid_from: Date,
    valid_to: Date,
  )
}

/// project_requirements.sql — one project's capacity-requirement lines (demand) for
/// the project-detail read model (GET /api/projects/:id; FR-CP). Param: $1 =
/// project_id.
///
/// Every requirement period-row for the project. Range columns are decomposed to
/// plain dates: lower(required_during) AS valid_from, upper(required_during) AS
/// valid_to (non-null for every row). One line per (project, level) over
/// non-overlapping periods. The detail is as-of-independent — the whole demand
/// timeline is returned regardless of the slider date — so unlike team/invoices this
/// read takes no as-of. Ordered by level then valid_from for a stable list.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_requirements(
  db: pog.Connection,
  project_requirement_project_id: Int,
) -> Result(pog.Returned(ProjectRequirementsRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use level <- decode.field(1, decode.int)
    use quantity <- decode.field(2, pog.numeric_decoder())
    use valid_from <- decode.field(3, pog.calendar_date_decoder())
    use valid_to <- decode.field(4, pog.calendar_date_decoder())
    decode.success(ProjectRequirementsRow(
      project_id:,
      level:,
      quantity:,
      valid_from:,
      valid_to:,
    ))
  }

  "-- project_requirements.sql — one project's capacity-requirement lines (demand) for
-- the project-detail read model (GET /api/projects/:id; FR-CP). Param: $1 =
-- project_id.
--
-- Every requirement period-row for the project. Range columns are decomposed to
-- plain dates: lower(required_during) AS valid_from, upper(required_during) AS
-- valid_to (non-null for every row). One line per (project, level) over
-- non-overlapping periods. The detail is as-of-independent — the whole demand
-- timeline is returned regardless of the slider date — so unlike team/invoices this
-- read takes no as-of. Ordered by level then valid_from for a stable list.
SELECT
  project_requirement.project_id,
  project_requirement.level,
  project_requirement.quantity,
  lower(project_requirement.required_during) AS valid_from,
  upper(project_requirement.required_during) AS valid_to
FROM project_requirement
WHERE project_requirement.project_id = $1
ORDER BY project_requirement.level, lower(project_requirement.required_during);
"
  |> pog.query
  |> pog.parameter(pog.int(project_requirement_project_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_run_open.sql — open a project's run (existence/contract window), contained
/// by its contract via project_within_contract. Last param is the audit_id.
/// $1 = project_id, $2 = contract_id, $3 = from, $4 = to.
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
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_run_open.sql — open a project's run (existence/contract window), contained
-- by its contract via project_within_contract. Last param is the audit_id.
-- $1 = project_id, $2 = contract_id, $3 = from, $4 = to.
INSERT INTO project_run (project_id, contract_id, active_during, audit_id)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'), $5);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_run_period` query
/// defined in `./src/tempo/server/sql/project_run_period.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectRunPeriodRow {
  ProjectRunPeriodRow(
    valid_from: Date,
    valid_to: Date,
    active: Bool,
    client: String,
  )
}

/// project_run_period.sql — one project's run window and owning client for the
/// detail read model (GET /api/projects/:id). Params: $1 = project_id, $2 = as-of
/// (for the active flag only).
///
/// The run is the project's existence/contract window (project_run). Its bounds are
/// decomposed to plain dates: lower(active_during) AS valid_from,
/// upper(active_during) AS valid_to (non-null for every seed run — all bounded at
/// 2027-01-01). `active` is (active_during @> $2): the as-of marks the run
/// active/ended without hiding it. The client name is reached through the run's
/// contract (contract_terms) to the client_current latest-read view; the contract is
/// joined on the same as-of so the name read matches the run window. A project may
/// have multiple historical runs — DISTINCT ON keeps the one whose window covers $2
/// (ordered so a covering run sorts first), falling back to the latest-started run
/// when none covers $2 so the detail page still renders an ended project. No row =>
/// the detail endpoint 404s.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_run_period(
  db: pog.Connection,
  project_run_project_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(ProjectRunPeriodRow), pog.QueryError) {
  let decoder = {
    use valid_from <- decode.field(0, pog.calendar_date_decoder())
    use valid_to <- decode.field(1, pog.calendar_date_decoder())
    use active <- decode.field(2, decode.bool)
    use client <- decode.field(3, decode.string)
    decode.success(ProjectRunPeriodRow(valid_from:, valid_to:, active:, client:))
  }

  "-- project_run_period.sql — one project's run window and owning client for the
-- detail read model (GET /api/projects/:id). Params: $1 = project_id, $2 = as-of
-- (for the active flag only).
--
-- The run is the project's existence/contract window (project_run). Its bounds are
-- decomposed to plain dates: lower(active_during) AS valid_from,
-- upper(active_during) AS valid_to (non-null for every seed run — all bounded at
-- 2027-01-01). `active` is (active_during @> $2): the as-of marks the run
-- active/ended without hiding it. The client name is reached through the run's
-- contract (contract_terms) to the client_current latest-read view; the contract is
-- joined on the same as-of so the name read matches the run window. A project may
-- have multiple historical runs — DISTINCT ON keeps the one whose window covers $2
-- (ordered so a covering run sorts first), falling back to the latest-started run
-- when none covers $2 so the detail page still renders an ended project. No row =>
-- the detail endpoint 404s.
SELECT DISTINCT ON (project_run.project_id)
  lower(project_run.active_during) AS valid_from,
  upper(project_run.active_during) AS valid_to,
  (project_run.active_during @> $2::date) AS active,
  coalesce(client_current.name, '') AS client
FROM project_run
JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
JOIN client_current ON client_current.id = contract_terms.client_id
WHERE project_run.project_id = $1
ORDER BY project_run.project_id,
         (project_run.active_during @> $2::date) DESC,
         lower(project_run.active_during) DESC;
"
  |> pog.query
  |> pog.parameter(pog.int(project_run_project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_team` query
/// defined in `./src/tempo/server/sql/project_team.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectTeamRow {
  ProjectTeamRow(
    engineer_id: Int,
    name: String,
    level: Int,
    fraction: Float,
    day_rate: Float,
  )
}

/// project_team.sql — the engineers engaged on one project as of $2, for the project
/// detail team card (GET /api/projects/:id; FR-CP6). Params: $1 = project_id,
/// $2 = as-of.
///
/// The board_engaged temporal join scoped to a single project: employment(@>$2)
/// anchors the employed engineer, engineer_role(@>$2) gives the as-of level,
/// rate_card(level, @>$2) the charge rate (the two-hop role × rate_card join), and
/// allocation(@>$2) ties the engineer to THIS project on the date. All INNER joins,
/// so every column is non-null. Unlike the board, the team card carries engineer_id
/// (so a card can click through to /people/:id) and omits the project/client/period
/// columns the board needs. An engineer covered by a leave fact on $2 is suppressed
/// (NOT EXISTS) exactly as on the board — the team is who is actually working the
/// project on the date. Ordered by name for a stable card list.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_team(
  db: pog.Connection,
  allocation_project_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(ProjectTeamRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use level <- decode.field(2, decode.int)
    use fraction <- decode.field(3, pog.numeric_decoder())
    use day_rate <- decode.field(4, pog.numeric_decoder())
    decode.success(ProjectTeamRow(
      engineer_id:,
      name:,
      level:,
      fraction:,
      day_rate:,
    ))
  }

  "-- project_team.sql — the engineers engaged on one project as of $2, for the project
-- detail team card (GET /api/projects/:id; FR-CP6). Params: $1 = project_id,
-- $2 = as-of.
--
-- The board_engaged temporal join scoped to a single project: employment(@>$2)
-- anchors the employed engineer, engineer_role(@>$2) gives the as-of level,
-- rate_card(level, @>$2) the charge rate (the two-hop role × rate_card join), and
-- allocation(@>$2) ties the engineer to THIS project on the date. All INNER joins,
-- so every column is non-null. Unlike the board, the team card carries engineer_id
-- (so a card can click through to /people/:id) and omits the project/client/period
-- columns the board needs. An engineer covered by a leave fact on $2 is suppressed
-- (NOT EXISTS) exactly as on the board — the team is who is actually working the
-- project on the date. Ordered by name for a stable card list.
SELECT
  engineer.id AS engineer_id,
  coalesce(engineer_current.name, '') AS name,
  engineer_role.level,
  allocation.fraction,
  rate_card.day_rate
FROM employment
JOIN engineer ON engineer.id = employment.engineer_id
JOIN engineer_current ON engineer_current.id = engineer.id
JOIN engineer_role ON engineer_role.engineer_id = engineer.id
                  AND engineer_role.held_during @> $2::date
JOIN rate_card ON rate_card.level = engineer_role.level
              AND rate_card.effective_during @> $2::date
JOIN allocation ON allocation.engineer_id = engineer.id
               AND allocation.project_id = $1
               AND allocation.allocated_during @> $2::date
WHERE employment.employed_during @> $2::date
  AND NOT EXISTS (
    SELECT 1 FROM leave
     WHERE leave.engineer_id = engineer.id
       AND leave.on_leave_during @> $2::date
  )
ORDER BY name;
"
  |> pog.query
  |> pog.parameter(pog.int(allocation_project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// rate_card_for_portion_of.sql — surgical charge-rate edit. FOR PORTION OF splits the
/// covering rate_card row, setting day_rate + audit_id only on [$1, $2) and carving
/// off the unchanged before/after remainders keeping their original audit_id.
/// $1 = from, $2 = to, $3 = new rate, $4 = level, $5 = audit_id.
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
  arg_3: Float,
  arg_4: Int,
  audit_id: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- rate_card_for_portion_of.sql — surgical charge-rate edit. FOR PORTION OF splits the
-- covering rate_card row, setting day_rate + audit_id only on [$1, $2) and carving
-- off the unchanged before/after remainders keeping their original audit_id.
-- $1 = from, $2 = to, $3 = new rate, $4 = level, $5 = audit_id.
--
-- PG reports `UPDATE 1` even when it produces extra rows, so never infer a split
-- from the affected-row count — read the rows back instead.
UPDATE rate_card
   FOR PORTION OF effective_during FROM $1::date TO $2::date
   SET day_rate = $3, audit_id = $5
 WHERE level = $4;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.float(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.parameter(pog.int(audit_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `rate_card_list` query
/// defined in `./src/tempo/server/sql/rate_card_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RateCardListRow {
  RateCardListRow(level: Int, day_rate: Float)
}

/// rate_card_list.sql — the current charge rate per level as of $1 (GET
/// /api/settings?as_of=$1; the rate-card table on the Settings page; FR-ST1). One
/// row per level whose rate_card span covers $1: level + day_rate, ordered by level.
/// A level with no rate covering $1 is simply absent. Param: $1 = the as-of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn rate_card_list(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(RateCardListRow), pog.QueryError) {
  let decoder = {
    use level <- decode.field(0, decode.int)
    use day_rate <- decode.field(1, pog.numeric_decoder())
    decode.success(RateCardListRow(level:, day_rate:))
  }

  "-- rate_card_list.sql — the current charge rate per level as of $1 (GET
-- /api/settings?as_of=$1; the rate-card table on the Settings page; FR-ST1). One
-- row per level whose rate_card span covers $1: level + day_rate, ordered by level.
-- A level with no rate covering $1 is simply absent. Param: $1 = the as-of date.
SELECT
  rate_card.level,
  rate_card.day_rate
FROM rate_card
WHERE rate_card.effective_during @> $1::date
ORDER BY rate_card.level;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `rate_card_revise` query
/// defined in `./src/tempo/server/sql/rate_card_revise.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RateCardReviseRow {
  RateCardReviseRow(revised: Int)
}

/// rate_card_revise.sql — change a level's day_rate from $1 onward (Change). FOR
/// PORTION OF re-rates [$1, ∞) of the covering row, setting day_rate + audit_id; PG
/// carves off the unchanged [start, $1) remainder keeping its original audit_id. The
/// `@>` guard leaves a scheduled future version untouched. $1 = effective,
/// $2 = new rate, $3 = level, $4 = audit_id.
///
/// PG reports `UPDATE 1` even when it produces an extra remainder row, so never
/// infer a split from the affected-row count — read the rows back instead. With no
/// covering version the UPDATE matches nothing and RETURNING yields zero rows; the
/// repository rejects that (NoSuchVersion) rather than journalling a silent no-op.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn rate_card_revise(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Float,
  level: Int,
  audit_id: Int,
) -> Result(pog.Returned(RateCardReviseRow), pog.QueryError) {
  let decoder = {
    use revised <- decode.field(0, decode.int)
    decode.success(RateCardReviseRow(revised:))
  }

  "-- rate_card_revise.sql — change a level's day_rate from $1 onward (Change). FOR
-- PORTION OF re-rates [$1, ∞) of the covering row, setting day_rate + audit_id; PG
-- carves off the unchanged [start, $1) remainder keeping its original audit_id. The
-- `@>` guard leaves a scheduled future version untouched. $1 = effective,
-- $2 = new rate, $3 = level, $4 = audit_id.
--
-- PG reports `UPDATE 1` even when it produces an extra remainder row, so never
-- infer a split from the affected-row count — read the rows back instead. With no
-- covering version the UPDATE matches nothing and RETURNING yields zero rows; the
-- repository rejects that (NoSuchVersion) rather than journalling a silent no-op.
UPDATE rate_card
   FOR PORTION OF effective_during FROM $1::date TO NULL
   SET day_rate = $2, audit_id = $4
 WHERE level = $3
   AND effective_during @> $1::date
RETURNING 1 AS revised;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.float(arg_2))
  |> pog.parameter(pog.int(level))
  |> pog.parameter(pog.int(audit_id))
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

/// A row you get from running the `salary_list` query
/// defined in `./src/tempo/server/sql/salary_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type SalaryListRow {
  SalaryListRow(level: Int, monthly_salary: Float)
}

/// salary_list.sql — the current monthly salary per level as of $1 (GET
/// /api/settings?as_of=$1; the salaries table on the Settings page; FR-ST2). One row
/// per level whose salary span covers $1: level + monthly_salary, ordered by level. A
/// level with no salary covering $1 is simply absent. Param: $1 = the as-of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn salary_list(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(SalaryListRow), pog.QueryError) {
  let decoder = {
    use level <- decode.field(0, decode.int)
    use monthly_salary <- decode.field(1, pog.numeric_decoder())
    decode.success(SalaryListRow(level:, monthly_salary:))
  }

  "-- salary_list.sql — the current monthly salary per level as of $1 (GET
-- /api/settings?as_of=$1; the salaries table on the Settings page; FR-ST2). One row
-- per level whose salary span covers $1: level + monthly_salary, ordered by level. A
-- level with no salary covering $1 is simply absent. Param: $1 = the as-of date.
SELECT
  salary.level,
  salary.monthly_salary
FROM salary
WHERE salary.effective_during @> $1::date
ORDER BY salary.level;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `salary_revise` query
/// defined in `./src/tempo/server/sql/salary_revise.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type SalaryReviseRow {
  SalaryReviseRow(revised: Int)
}

/// salary_revise.sql — change a level's monthly_salary from $1 onward (Change). FOR
/// PORTION OF re-rates [$1, ∞) of the covering row, setting monthly_salary + audit_id;
/// PG carves off the unchanged [start, $1) remainder keeping its original audit_id.
/// The `@>` guard leaves a scheduled future version untouched. $1 = effective,
/// $2 = new monthly salary, $3 = level, $4 = audit_id.
///
/// PG reports `UPDATE 1` even when it produces an extra remainder row, so never
/// infer a split from the affected-row count — read the rows back instead. With no
/// covering version the UPDATE matches nothing and RETURNING yields zero rows; the
/// repository rejects that (NoSuchVersion) rather than journalling a silent no-op.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn salary_revise(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Float,
  level: Int,
  audit_id: Int,
) -> Result(pog.Returned(SalaryReviseRow), pog.QueryError) {
  let decoder = {
    use revised <- decode.field(0, decode.int)
    decode.success(SalaryReviseRow(revised:))
  }

  "-- salary_revise.sql — change a level's monthly_salary from $1 onward (Change). FOR
-- PORTION OF re-rates [$1, ∞) of the covering row, setting monthly_salary + audit_id;
-- PG carves off the unchanged [start, $1) remainder keeping its original audit_id.
-- The `@>` guard leaves a scheduled future version untouched. $1 = effective,
-- $2 = new monthly salary, $3 = level, $4 = audit_id.
--
-- PG reports `UPDATE 1` even when it produces an extra remainder row, so never
-- infer a split from the affected-row count — read the rows back instead. With no
-- covering version the UPDATE matches nothing and RETURNING yields zero rows; the
-- repository rejects that (NoSuchVersion) rather than journalling a silent no-op.
UPDATE salary
   FOR PORTION OF effective_during FROM $1::date TO NULL
   SET monthly_salary = $2, audit_id = $4
 WHERE level = $3
   AND effective_during @> $1::date
RETURNING 1 AS revised;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.float(arg_2))
  |> pog.parameter(pog.int(level))
  |> pog.parameter(pog.int(audit_id))
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

/// timesheet_write.sql — record hours for one (engineer, project, day), contained by
/// an allocation via timesheet_within_allocation. The day is the [d, d+1) range. Last
/// param is the audit_id. $1 = engineer_id, $2 = project_id, $3 = day, $4 = hours.
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
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- timesheet_write.sql — record hours for one (engineer, project, day), contained by
-- an allocation via timesheet_within_allocation. The day is the [d, d+1) range. Last
-- param is the audit_id. $1 = engineer_id, $2 = project_id, $3 = day, $4 = hours.
INSERT INTO timesheet (engineer_id, project_id, work_day, hours, audit_id)
VALUES ($1, $2, daterange($3::date, $3::date + 1, '[)'), $4, $5);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
