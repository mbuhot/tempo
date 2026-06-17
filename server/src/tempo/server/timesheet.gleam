//// Domain: the timesheet aggregate — read (the form for a day) and write (the
//// PERIOD-FK-backed temporal upsert). `handle` matches the `LogTimesheet`
//// command, runs the upsert through the shared `log_in` core, maps its
//// `WriteError` into the unified `OperationError`, and returns the journal event;
//// `command.dispatch` owns the transaction and persists it. No HTTP — this layer
//// never imports `wisp`.
////
//// `form` maps `timesheet_form` rows to the shared `TimesheetDay`. `log_in` is the
//// delete-then-insert temporal upsert: the `WITHOUT OVERLAPS` PK cannot be an
//// `ON CONFLICT` target, so re-entry deletes the covering row then inserts, both
//// in one transaction. The `PERIOD` FK to `allocation` is the backstop — logging
//// against a project the engineer is not allocated to that day is rejected by the
//// database. That rejection (SQLSTATE 23503) is classified as `NotAllocated`,
//// which `handle` re-classifies as the unified `ContainmentViolated`.

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

/// Apply the `LogTimesheet` command: run the delete-then-insert temporal upsert
/// through the shared `log_in` core on the in-transaction connection, and on
/// success return the single journal event it produced. The domain's
/// `NotAllocated` (the timesheet PERIOD FK firing) re-classifies as the unified
/// `ContainmentViolated("timesheet_within_allocation")` — the same classification
/// every other containment FK gets — and any other query error maps through
/// `operation.classify`. Only `LogTimesheet` reaches here (the dispatch `route`
/// guarantees it); any other variant is a no-op.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  case command {
    LogTimesheet(engineer_id:, project_id:, day:, hours:) ->
      case log_in(conn, WriteRequest(engineer_id:, project_id:, day:, hours:)) {
        Ok(Nil) -> Ok(events(command))
        Error(NotAllocated) ->
          Error(operation.ContainmentViolated(timesheet_period_fk))
        Error(DatabaseError(query_error)) ->
          Error(operation.classify(query_error))
      }
    _ -> Ok([])
  }
}

/// The journal event(s) an applied timesheet command produces.
fn events(command: Command) -> List(Event) {
  case command {
    LogTimesheet(engineer_id:, project_id:, day:, hours:) -> [
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
    ]
    _ -> []
  }
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
/// reusable core driven by `handle`. The caller owns the transaction, so the
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
