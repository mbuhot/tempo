//// Domain: the timesheet aggregate — read (the weekly grid) and write. `handle`
//// routes `LogTimesheet` (one day) and `LogWeek` (a whole week, atomically) to their
//// named operations, which record `EngineerWorkedHours` facts through `repository`
//// (a per-day delete-then-insert upsert; 0 hours clears the day) and return the
//// journal event `command.dispatch` persists in the same transaction. No HTTP —
//// never imports `wisp`.
////
//// `form_week` maps `timesheet_week` rows into the shared `TimesheetWeek` grid: one
//// `TimesheetWeekRow` per project (cells Mon..Sun), dropping a project with no
//// loggable day that week (e.g. on leave). The `PERIOD` FK to `allocation`
//// (`timesheet_within_allocation`) is the backstop — logging a day not covered by an
//// allocation is rejected by the database and classified as `ContainmentViolated`.

import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{
  type Command, type TimesheetWeek, type TimesheetWeekRow, LogTimesheet, LogWeek,
  TimesheetCell, TimesheetEntry, TimesheetWeek, TimesheetWeekRow,
}
import tempo/server/context.{type Context}
import tempo/server/fact
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/repository
import tempo/server/sql

// --- dispatch ---------------------------------------------------------------

/// Apply a timesheet-aggregate command: route it to its named operation, which does
/// its temporal write and returns the journal event(s) it produced. The dispatch
/// `route` only ever sends timesheet commands here, so any other variant is a routing
/// bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  case command {
    LogTimesheet(..) -> log_timesheet(conn, command)
    LogWeek(..) -> log_week(conn, command)
    _ ->
      panic as "timesheet.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Record one `EngineerWorkedHours` fact (via `repository`) and return its journal
/// event. A day not covered by an allocation trips the timesheet PERIOD FK, which
/// `repository` classifies as the unified `ContainmentViolated`.
fn log_timesheet(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert LogTimesheet(engineer_id:, project_id:, day:, hours:) = command
  use _ <- result.try(
    repository.record_facts(conn, [
      fact.EngineerWorkedHours(engineer_id:, project_id:, day:, hours:),
    ]),
  )
  Ok([
    Event(
      operation: "log_timesheet",
      summary: "Log "
        <> float.to_string(hours)
        <> "h for engineer "
        <> int.to_string(engineer_id)
        <> " on project "
        <> int.to_string(project_id)
        <> " on "
        <> operation.iso(day),
      payload: codecs.encode_command(command),
    ),
  ])
}

/// Log a whole week atomically: map every entry to an `EngineerWorkedHours` fact
/// and record them through `repository` in the caller's single transaction (it
/// short-circuits on the first rejection, so every entry commits or none). On
/// success a single `log_week` journal event carries the whole command.
fn log_week(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert LogWeek(engineer_id:, entries:) = command
  let facts =
    list.map(entries, fn(entry) {
      let TimesheetEntry(project_id:, day:, hours:) = entry
      fact.EngineerWorkedHours(engineer_id:, project_id:, day:, hours:)
    })
  use _ <- result.try(repository.record_facts(conn, facts))
  Ok([
    Event(
      operation: "log_week",
      summary: "Log timesheet week for engineer "
        <> int.to_string(engineer_id)
        <> " ("
        <> int.to_string(list.length(entries))
        <> " entries)",
      payload: codecs.encode_command(command),
    ),
  ])
}

// --- read -------------------------------------------------------------------

/// Compute the weekly timesheet grid for an engineer: run `timesheet_week` and
/// group its `(project, day)`-ordered rows into one `TimesheetWeekRow` per project
/// (preserving project order), each row's cells in day order. A project with no
/// loggable day that week — every cell un-allocated (e.g. the engineer is on leave
/// all week) — is dropped, so a fully-blocked week yields no rows and the UI shows
/// "nothing to log". `days` is the column dates taken from the first remaining row's
/// cells, or `[]` when there are no rows.
pub fn form_week(
  context: Context,
  engineer_id: Int,
  week_start: Date,
) -> Result(TimesheetWeek, pog.QueryError) {
  use returned <- result.map(sql.timesheet_week(
    context.db,
    engineer_id,
    week_start,
  ))
  let rows =
    group_rows(returned.rows)
    |> list.filter(fn(row) { list.any(row.cells, fn(cell) { cell.allocated }) })
  let days = case rows {
    [first, ..] -> list.map(first.cells, fn(cell) { cell.date })
    [] -> []
  }
  TimesheetWeek(engineer_id:, week_start:, days:, rows:)
}

/// Group `(project, day)`-ordered SQL rows into per-project `TimesheetWeekRow`s.
/// Rows arrive sorted by project then day, so a fold that opens a new row whenever
/// the `project_id` changes preserves project order and day order within each row.
fn group_rows(rows: List(sql.TimesheetWeekRow)) -> List(TimesheetWeekRow) {
  rows
  |> list.fold([], fn(acc: List(TimesheetWeekRow), row) {
    let cell =
      TimesheetCell(date: row.day, allocated: row.allocated, hours: row.hours)
    case acc {
      [current, ..rest] if current.project_id == row.project_id -> [
        TimesheetWeekRow(..current, cells: [cell, ..current.cells]),
        ..rest
      ]
      _ -> [
        TimesheetWeekRow(
          project_id: row.project_id,
          project: row.project,
          cells: [cell],
        ),
        ..acc
      ]
    }
  })
  |> list.reverse
  |> list.map(fn(row) {
    TimesheetWeekRow(..row, cells: list.reverse(row.cells))
  })
}
