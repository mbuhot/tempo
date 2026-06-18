//// Domain: the timesheet aggregate — read (the form for a day) and write (the
//// PERIOD-FK-backed temporal upsert). `handle` routes the `LogTimesheet` command to
//// the named `log_timesheet` operation, which runs the upsert through the shared
//// `log_in` core and maps its `WriteError` into the unified `OperationError`;
//// `command.dispatch` owns the transaction and persists the journal event `handle`
//// returns. No HTTP — this layer never imports `wisp`.
////
//// `form` maps `timesheet_form` rows to the shared `TimesheetDay`. `log_in` is the
//// delete-then-insert temporal upsert: the `WITHOUT OVERLAPS` PK cannot be an
//// `ON CONFLICT` target, so re-entry deletes the covering row then inserts, both
//// in one transaction. The `PERIOD` FK to `allocation` is the backstop — logging
//// against a project the engineer is not allocated to that day is rejected by the
//// database. That rejection (SQLSTATE 23503) is classified as `NotAllocated`,
//// which `log_timesheet` re-classifies as the unified `ContainmentViolated`.

import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{
  type Command, type TimesheetDay, type TimesheetLine, type WriteRequest,
  LogTimesheet, TimesheetDay, TimesheetLine, WriteRequest,
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

// --- read -------------------------------------------------------------------

/// Compute the timesheet form for an engineer on a day: run `timesheet_form`
/// and map each row to the shared `TimesheetLine` (empty on a leave day).
pub fn form(
  context: Context,
  engineer_id: Int,
  day: Date,
) -> Result(TimesheetDay, pog.QueryError) {
  use returned <- result.map(sql.timesheet_form(context.db, engineer_id, day))
  let lines = list.map(returned.rows, form_row_to_shared)
  TimesheetDay(engineer_id:, date: day, lines:)
}

fn form_row_to_shared(row: sql.TimesheetFormRow) -> TimesheetLine {
  TimesheetLine(
    project_id: row.project_id,
    project: row.project,
    fraction: row.fraction,
    hours: row.hours,
    valid_from: row.valid_from,
    valid_to: row.valid_to,
  )
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
