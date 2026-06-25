//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/timesheet/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

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
/// defined in `./src/tempo/server/timesheet/sql/timesheet_week.sql`.
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
