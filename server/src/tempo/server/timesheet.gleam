//// Domain: the timesheet aggregate — read (the weekly grid) and write (the
//// PERIOD-FK-backed temporal upsert). `handle` routes `LogTimesheet` (one day) and
//// `LogWeek` (a whole week, atomically) to their named operations, which run the
//// upsert through the shared `log_in` core and map its `WriteError` into the unified
//// `OperationError`; `command.dispatch` owns the transaction and persists the journal
//// event `handle` returns. No HTTP — this layer never imports `wisp`.
////
//// `form_week` maps `timesheet_week` rows into the shared `TimesheetWeek` grid: one
//// `TimesheetWeekRow` per project (cells Mon..Sun), dropping a project with no
//// loggable day that week (e.g. on leave). `log_in` is the delete-then-insert
//// temporal upsert: the `WITHOUT OVERLAPS` PK cannot be an `ON CONFLICT` target, so
//// re-entry deletes the covering row then inserts, both in one transaction. The
//// `PERIOD` FK to `allocation` is the backstop — logging against a project the
//// engineer is not allocated to that day is rejected by the database. That rejection
//// (SQLSTATE 23503) is classified as `NotAllocated`, which the log operations
//// re-classify as the unified `ContainmentViolated`.

import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{
  type Command, type TimesheetWeek, type TimesheetWeekRow, type WriteRequest,
  LogTimesheet, LogWeek, TimesheetCell, TimesheetEntry, TimesheetWeek,
  TimesheetWeekRow, WriteRequest,
}
import tempo/server/context.{type Context}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Why a timesheet write was refused. `NotAllocated` is the domain rejection the
/// `PERIOD` FK enforces (the project is not covered by an allocation that day);
/// `DatabaseError` is any other failure.
pub type WriteError {
  NotAllocated
  DatabaseError(pog.QueryError)
}

/// The timesheet PERIOD foreign-key constraint. A violation of *this* constraint
/// is the domain rejection (the logged day is not covered by an allocation); pog
/// reports it as `ConstraintViolated` carrying this name.
const timesheet_period_fk = "timesheet_within_allocation"

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

/// Log hours against a project for a day via the `log_in` temporal upsert, then
/// return its journal event. A `NotAllocated` rejection (the timesheet PERIOD FK
/// firing) re-classifies as the unified
/// `ContainmentViolated("timesheet_within_allocation")` — the same classification
/// every other containment FK gets — and any other query error maps through
/// `operation.classify`.
fn log_timesheet(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert LogTimesheet(engineer_id:, project_id:, day:, hours:) = command
  use _ <- result.try(
    case log_in(conn, WriteRequest(engineer_id:, project_id:, day:, hours:)) {
      Ok(Nil) -> Ok(Nil)
      Error(NotAllocated) ->
        Error(operation.ContainmentViolated(timesheet_period_fk))
      Error(DatabaseError(query_error)) ->
        Error(operation.classify(query_error))
    },
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

/// Log a whole week's hours atomically: each entry sets one (project, day) cell
/// for the engineer. An hours of `0.0` clears that cell (a `timesheet_delete`);
/// otherwise the entry runs through the shared `log_in` core, whose `NotAllocated`
/// rejection re-classifies as the unified `ContainmentViolated` exactly as
/// `log_timesheet` does. `list.try_map` short-circuits on the first failure, so the
/// caller's single transaction commits every entry or none. On success a single
/// `log_week` journal event carries the whole command.
fn log_week(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert LogWeek(engineer_id:, entries:) = command
  use _ <- result.try(
    list.try_map(entries, fn(entry) {
      let TimesheetEntry(project_id:, day:, hours:) = entry
      case hours == 0.0 {
        True ->
          sql.timesheet_delete(conn, engineer_id, project_id, day)
          |> result.replace(Nil)
          |> result.map_error(operation.classify)
        False ->
          case
            log_in(conn, WriteRequest(engineer_id:, project_id:, day:, hours:))
          {
            Ok(Nil) -> Ok(Nil)
            Error(NotAllocated) ->
              Error(operation.ContainmentViolated(timesheet_period_fk))
            Error(DatabaseError(query_error)) ->
              Error(operation.classify(query_error))
          }
      }
    }),
  )
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

// --- write ------------------------------------------------------------------

/// The delete-then-insert temporal upsert on an already-open connection: the
/// reusable core driven by `log_timesheet`. The caller owns the transaction, so the
/// command `dispatch` seam runs this and appends its `event_log` row in the SAME
/// transaction (facts + journal commit together). On a PERIOD-FK rejection the
/// caller's transaction rolls back the delete, leaving the prior row intact.
pub fn log_in(
  conn: pog.Connection,
  write: WriteRequest,
) -> Result(Nil, WriteError) {
  let WriteRequest(engineer_id:, project_id:, day:, hours:) = write
  let outcome = {
    use _ <- result.try(sql.timesheet_delete(conn, engineer_id, project_id, day))
    sql.timesheet_write(conn, engineer_id, project_id, day, hours)
  }
  case outcome {
    Ok(_) -> Ok(Nil)
    Error(query_error) -> Error(classify(query_error))
  }
}

/// Classify a query error: a violation of the timesheet PERIOD FK is the
/// backstop firing (the day is not covered by an allocation), surfaced as
/// `NotAllocated`; anything else is an opaque `DatabaseError`.
fn classify(error: pog.QueryError) -> WriteError {
  case error {
    pog.ConstraintViolated(constraint:, ..)
      if constraint == timesheet_period_fk
    -> NotAllocated
    _ -> DatabaseError(error)
  }
}
