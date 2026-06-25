//// Domain: the timesheet aggregate — read (the weekly grid) and write.
//// `command.route` destructures `LogTimesheet` (one day) and `LogWeek` (a whole
//// week, atomically) and calls the matching operation here with its already-narrowed
//// fields; the operation returns the `EngineerWorkedHours` facts it records, and
//// `command.dispatch` records them (through `repository`, a per-day delete-then-
//// insert upsert; 0 hours clears the day) and persists the journal in ONE
//// transaction. No HTTP — never imports `wisp`.
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
import shared/command.{TimesheetCommand} as gateway
import shared/timesheet/command.{
  type TimesheetCommand, type TimesheetEntry, LogTimesheet, LogWeek,
  TimesheetEntry,
}
import shared/timesheet/view.{
  type TimesheetWeek, type TimesheetWeekRow, TimesheetCell, TimesheetWeek,
  TimesheetWeekRow,
}
import tempo/server/context.{type Context}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}
import tempo/server/timesheet/sql

// --- dispatch ---------------------------------------------------------------

/// Route a timesheet command to its operation, returning the audit entry and the
/// facts it records. Exhaustive over `TimesheetCommand`.
pub fn route(command: TimesheetCommand) -> Result(Recorded, OperationError) {
  case command {
    LogTimesheet(engineer_id:, project_id:, day:, hours:) ->
      log_timesheet(command, engineer_id:, project_id:, day:, hours:)
    LogWeek(engineer_id:, entries:) -> log_week(command, engineer_id:, entries:)
  }
}

/// Record one `EngineerWorkedHours` fact, with its journal entry. A day not covered
/// by an allocation trips the timesheet PERIOD FK, which `repository` classifies as
/// the unified `ContainmentViolated`.
pub fn log_timesheet(
  command: TimesheetCommand,
  engineer_id engineer_id: Int,
  project_id project_id: Int,
  day day: Date,
  hours hours: Float,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "log_timesheet",
        summary: "Log "
          <> float.to_string(hours)
          <> "h for engineer "
          <> int.to_string(engineer_id)
          <> " on project "
          <> int.to_string(project_id)
          <> " on "
          <> operation.iso(day),
        payload: gateway.encode_command(TimesheetCommand(command)),
      ),
      facts: [
        fact.EngineerWorkedHours(
          engineer_id: fact.EngineerId(engineer_id),
          project_id: fact.ProjectId(project_id),
          day:,
          hours:,
        ),
      ],
    ),
  )
}

/// Record a whole week's worked-hours facts, with one `log_week` journal entry.
/// `command.dispatch` records them in its single transaction (short-circuiting on
/// the first rejection), so every entry commits or none.
pub fn log_week(
  command: TimesheetCommand,
  engineer_id engineer_id: Int,
  entries entries: List(TimesheetEntry),
) -> Result(Recorded, OperationError) {
  let worked_hours =
    list.map(entries, fn(entry) {
      let TimesheetEntry(project_id:, day:, hours:) = entry
      fact.EngineerWorkedHours(
        engineer_id: fact.EngineerId(engineer_id),
        project_id: fact.ProjectId(project_id),
        day:,
        hours:,
      )
    })
  Ok(Recorded(
    entry: Event(
      operation: "log_week",
      summary: "Log timesheet week for engineer "
        <> int.to_string(engineer_id)
        <> " ("
        <> int.to_string(list.length(entries))
        <> " entries)",
      payload: gateway.encode_command(TimesheetCommand(command)),
    ),
    facts: worked_hours,
  ))
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
