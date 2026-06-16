//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `board_as_of` query
/// defined in `./src/tempo/server/sql/board_as_of.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type BoardAsOfRow {
  BoardAsOfRow(
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

/// board_as_of.sql — the as-of org board: engineers ALLOCATED to a project as of
/// $1::date (ARCHITECTURE.md §5). One row per (engineer × project).
///
/// This is the "engaged" slice of the board; it returns only fully-engaged rows
/// (INNER JOINs throughout), so every column is non-null. Two companion queries
/// complete the board so every employed engineer is represented exactly once per
/// engagement:
/// * board_unassigned_as_of.sql — employed, not on leave, with no allocation
/// * board_leave_as_of.sql       — covered by a leave fact (leave overrides)
/// Engineers with a covering leave fact are suppressed here (NOT EXISTS) and
/// surfaced by board_leave_as_of.sql instead.
///
/// Charge rate is resolved from engineer_role × rate_card as of the date (the
/// two-hop temporal join, ADR-009). It is exposed as a plain `day_rate` value on
/// the row — never "where it came from" — so the same shared BoardRow holds
/// across the v1-wide -> v2-split redesign (ADR-013).
///
/// Range columns are decomposed to plain `date`s at the boundary (ADR-011): the
/// engagement window is `lower(al.valid_at)`/`upper(al.valid_at)` AS
/// valid_from/valid_to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn board_as_of(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(BoardAsOfRow), pog.QueryError) {
  let decoder = {
    use engineer <- decode.field(0, decode.string)
    use level <- decode.field(1, decode.int)
    use project <- decode.field(2, decode.string)
    use client <- decode.field(3, decode.string)
    use fraction <- decode.field(4, pog.numeric_decoder())
    use day_rate <- decode.field(5, pog.numeric_decoder())
    use valid_from <- decode.field(6, pog.calendar_date_decoder())
    use valid_to <- decode.field(7, pog.calendar_date_decoder())
    decode.success(BoardAsOfRow(
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

  "-- board_as_of.sql — the as-of org board: engineers ALLOCATED to a project as of
-- $1::date (ARCHITECTURE.md §5). One row per (engineer × project).
--
-- This is the \"engaged\" slice of the board; it returns only fully-engaged rows
-- (INNER JOINs throughout), so every column is non-null. Two companion queries
-- complete the board so every employed engineer is represented exactly once per
-- engagement:
--   * board_unassigned_as_of.sql — employed, not on leave, with no allocation
--   * board_leave_as_of.sql       — covered by a leave fact (leave overrides)
-- Engineers with a covering leave fact are suppressed here (NOT EXISTS) and
-- surfaced by board_leave_as_of.sql instead.
--
-- Charge rate is resolved from engineer_role × rate_card as of the date (the
-- two-hop temporal join, ADR-009). It is exposed as a plain `day_rate` value on
-- the row — never \"where it came from\" — so the same shared BoardRow holds
-- across the v1-wide -> v2-split redesign (ADR-013).
--
-- Range columns are decomposed to plain `date`s at the boundary (ADR-011): the
-- engagement window is `lower(al.valid_at)`/`upper(al.valid_at)` AS
-- valid_from/valid_to.
SELECT
  e.name AS engineer,
  rl.level,
  pr.name AS project,
  cl.name AS client,
  al.fraction,
  rc.day_rate,
  lower(al.valid_at) AS valid_from,
  upper(al.valid_at) AS valid_to
FROM employment emp
JOIN engineer e       ON e.id = emp.engineer_id
JOIN engineer_role rl ON rl.engineer_id = e.id  AND rl.valid_at @> $1::date
JOIN rate_card rc     ON rc.level = rl.level     AND rc.valid_at @> $1::date
JOIN allocation al    ON al.engineer_id = e.id   AND al.valid_at @> $1::date
JOIN project pr       ON pr.id = al.project_id   AND pr.valid_at @> $1::date
JOIN contract ct      ON ct.id = pr.contract_id  AND ct.valid_at @> $1::date
JOIN client cl        ON cl.id = ct.client_id
WHERE emp.valid_at @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM leave lv
    WHERE lv.engineer_id = e.id AND lv.valid_at @> $1::date
  )
ORDER BY e.name, pr.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `board_leave_as_of` query
/// defined in `./src/tempo/server/sql/board_leave_as_of.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type BoardLeaveAsOfRow {
  BoardLeaveAsOfRow(
    engineer: String,
    level: Option(Int),
    kind: String,
    valid_from: Date,
    valid_to: Date,
  )
}

/// board_leave_as_of.sql — engineers on leave as of a date (ARCHITECTURE.md §5).
/// The companion to board_as_of.sql: that query suppresses anyone with a covering
/// `leave` fact; this one selects exactly those engineers so the board can render
/// them as "On leave: <kind>".
///
/// Their underlying allocation still exists; it is deliberately not joined here —
/// leave overrides the engagement in the read model. The level (and hence the
/// charge story) is still resolved so the row stays informative.
///
/// Ranges decomposed to plain `date`s at the boundary (ADR-011): valid_from/
/// valid_to are the leave period's `lower()/upper()`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn board_leave_as_of(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(BoardLeaveAsOfRow), pog.QueryError) {
  let decoder = {
    use engineer <- decode.field(0, decode.string)
    use level <- decode.field(1, decode.optional(decode.int))
    use kind <- decode.field(2, decode.string)
    use valid_from <- decode.field(3, pog.calendar_date_decoder())
    use valid_to <- decode.field(4, pog.calendar_date_decoder())
    decode.success(BoardLeaveAsOfRow(
      engineer:,
      level:,
      kind:,
      valid_from:,
      valid_to:,
    ))
  }

  "-- board_leave_as_of.sql — engineers on leave as of a date (ARCHITECTURE.md §5).
-- The companion to board_as_of.sql: that query suppresses anyone with a covering
-- `leave` fact; this one selects exactly those engineers so the board can render
-- them as \"On leave: <kind>\".
--
-- Their underlying allocation still exists; it is deliberately not joined here —
-- leave overrides the engagement in the read model. The level (and hence the
-- charge story) is still resolved so the row stays informative.
--
-- Ranges decomposed to plain `date`s at the boundary (ADR-011): valid_from/
-- valid_to are the leave period's `lower()/upper()`.
SELECT
  e.name AS engineer,
  rl.level,
  lv.kind,
  lower(lv.valid_at) AS valid_from,
  upper(lv.valid_at) AS valid_to
FROM leave lv
JOIN engineer e            ON e.id = lv.engineer_id
LEFT JOIN engineer_role rl ON rl.engineer_id = e.id AND rl.valid_at @> $1::date
WHERE lv.valid_at @> $1::date
ORDER BY e.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `board_unassigned_as_of` query
/// defined in `./src/tempo/server/sql/board_unassigned_as_of.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type BoardUnassignedAsOfRow {
  BoardUnassignedAsOfRow(engineer: String, level: Int)
}

/// board_unassigned_as_of.sql — employed engineers who are NOT allocated and NOT
/// on leave as of $1::date (ARCHITECTURE.md §5). The third board slice alongside
/// board_as_of (engaged) and board_leave_as_of (on leave); the client renders
/// these as "Unassigned".
///
/// INNER JOIN engineer_role so `level` is non-null: an employed engineer always
/// has a role in the seed (engineer_role spans employment). All columns non-null,
/// so the row decodes without Option plumbing.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn board_unassigned_as_of(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(BoardUnassignedAsOfRow), pog.QueryError) {
  let decoder = {
    use engineer <- decode.field(0, decode.string)
    use level <- decode.field(1, decode.int)
    decode.success(BoardUnassignedAsOfRow(engineer:, level:))
  }

  "-- board_unassigned_as_of.sql — employed engineers who are NOT allocated and NOT
-- on leave as of $1::date (ARCHITECTURE.md §5). The third board slice alongside
-- board_as_of (engaged) and board_leave_as_of (on leave); the client renders
-- these as \"Unassigned\".
--
-- INNER JOIN engineer_role so `level` is non-null: an employed engineer always
-- has a role in the seed (engineer_role spans employment). All columns non-null,
-- so the row decodes without Option plumbing.
SELECT
  e.name AS engineer,
  rl.level
FROM employment emp
JOIN engineer e       ON e.id = emp.engineer_id
JOIN engineer_role rl ON rl.engineer_id = e.id AND rl.valid_at @> $1::date
WHERE emp.valid_at @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM allocation al
    WHERE al.engineer_id = e.id AND al.valid_at @> $1::date
  )
  AND NOT EXISTS (
    SELECT 1 FROM leave lv
    WHERE lv.engineer_id = e.id AND lv.valid_at @> $1::date
  )
ORDER BY e.name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// rate_card_for_portion_of.sql — surgical charge-rate edit.
///
/// Bump a level's day_rate for PART of its validity via FOR PORTION OF: PG splits
/// the covering rate_card row, changing only the [$1, $2) sub-period and carving
/// off the unchanged before/after remainder as their own rows. The boundaries are
/// plain `date` params cast in SQL (ADR-011); $3 is the new rate, $4 the level.
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
-- plain `date` params cast in SQL (ADR-011); $3 is the new rate, $4 the level.
--
-- PG reports `UPDATE 1` even when it produces extra rows, so never infer a split
-- from the affected-row count — read the rows back instead.
UPDATE rate_card
   FOR PORTION OF valid_at FROM $1::date TO $2::date
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

/// timesheet_form.sql — my allocations as of a day, with any hours already logged
/// (ARCHITECTURE.md §5). Only projects the engineer is actually on as of $2::date
/// are returned; on a day covered by leave the result is empty, so the form offers
/// nothing (leave takes precedence over an allocation). A project the engineer has
/// rolled off is simply absent — the negative case the PERIOD FK also backstops on
/// write.
///
/// $1 = engineer_id, $2 = the day. `hours` is COALESCEd to 0 for an un-logged
/// project so the form always has a value to render. Ranges are decomposed to
/// plain `date`s at the boundary (ADR-011): valid_from/valid_to are the
/// allocation engagement window.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn timesheet_form(
  db: pog.Connection,
  al_engineer_id: Int,
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

  "-- timesheet_form.sql — my allocations as of a day, with any hours already logged
-- (ARCHITECTURE.md §5). Only projects the engineer is actually on as of $2::date
-- are returned; on a day covered by leave the result is empty, so the form offers
-- nothing (leave takes precedence over an allocation). A project the engineer has
-- rolled off is simply absent — the negative case the PERIOD FK also backstops on
-- write.
--
-- $1 = engineer_id, $2 = the day. `hours` is COALESCEd to 0 for an un-logged
-- project so the form always has a value to render. Ranges are decomposed to
-- plain `date`s at the boundary (ADR-011): valid_from/valid_to are the
-- allocation engagement window.
SELECT
  pr.id AS project_id,
  pr.name AS project,
  al.fraction,
  COALESCE(ts.hours, 0) AS hours,
  lower(al.valid_at) AS valid_from,
  upper(al.valid_at) AS valid_to
FROM allocation al
JOIN project pr ON pr.id = al.project_id AND pr.valid_at @> $2::date
LEFT JOIN timesheet ts
  ON ts.engineer_id = al.engineer_id
 AND ts.project_id  = al.project_id
 AND ts.work_day @> $2::date
WHERE al.engineer_id = $1 AND al.valid_at @> $2::date
  AND NOT EXISTS (
    SELECT 1 FROM leave lv
    WHERE lv.engineer_id = $1 AND lv.valid_at @> $2::date
  )
ORDER BY pr.name;
"
  |> pog.query
  |> pog.parameter(pog.int(al_engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// timesheet_write.sql — step 2 of the temporal upsert (ARCHITECTURE.md §5).
///
/// Insert a single-day timesheet row. The `work_day` range is built in SQL as
/// `daterange($3::date, $3::date + 1, '[)')` so the function only ever sees scalar
/// `date` params (ADR-011) — no daterange type crosses the Squirrel boundary.
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

  "-- timesheet_write.sql — step 2 of the temporal upsert (ARCHITECTURE.md §5).
--
-- Insert a single-day timesheet row. The `work_day` range is built in SQL as
-- `daterange($3::date, $3::date + 1, '[)')` so the function only ever sees scalar
-- `date` params (ADR-011) — no daterange type crosses the Squirrel boundary.
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
