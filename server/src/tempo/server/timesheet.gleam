//// Domain: timesheet read (the form as-of a day) and write (the PERIOD-FK-backed
//// temporal upsert). No HTTP — this layer never imports `wisp`.
////
//// `form` maps `timesheet_form` rows to the shared
//// `TimesheetDay`. `log` is the delete-then-insert temporal upsert: the
//// `WITHOUT OVERLAPS` PK cannot be an `ON CONFLICT` target, so re-entry deletes
//// the covering row then inserts, both in one transaction. The `PERIOD` FK to
//// `allocation` is the backstop — logging against a project the engineer is not
//// allocated to that day is rejected by the database. That rejection
//// (SQLSTATE 23503) is classified as `NotAllocated` (a clean 4xx at the web
//// layer), never an opaque database error.

import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/types.{
  type TimesheetDay, type TimesheetLine, type WriteRequest, TimesheetDay,
  TimesheetLine, WriteRequest,
}
import tempo/server/context.{type Context}
import tempo/server/sql

/// Why a timesheet write was refused. `NotAllocated` is the domain rejection the
/// `PERIOD` FK enforces (the project is not covered by an allocation that day);
/// it maps to a 4xx. `DatabaseError` is any other failure and maps to a 500.
pub type WriteError {
  NotAllocated
  DatabaseError(pog.QueryError)
}

/// The timesheet PERIOD foreign-key constraint. A violation of *this* constraint
/// is the domain rejection (the logged day is not covered by an allocation); pog
/// reports it as `ConstraintViolated` carrying this name.
const timesheet_period_fk = "timesheet_engineer_id_project_id_work_day_fkey"

// --- read -------------------------------------------------------------------

/// Compute the timesheet form for an engineer as of a day: run `timesheet_form`
/// and map each row to the shared `TimesheetLine` (empty on a leave day).
pub fn form(
  context: Context,
  engineer_id: Int,
  day: Date,
) -> Result(TimesheetDay, pog.QueryError) {
  use returned <- result.map(sql.timesheet_form(context.db, engineer_id, day))
  let lines = list.map(returned.rows, form_row_to_shared)
  TimesheetDay(engineer_id:, as_of: day, lines:)
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

/// Run the delete-then-insert temporal upsert in one transaction. A PERIOD-FK
/// rejection rolls back the delete (the prior row survives) and is classified as
/// `NotAllocated`; any other query error becomes `DatabaseError`.
pub fn log(context: Context, write: WriteRequest) -> Result(Nil, WriteError) {
  let WriteRequest(engineer_id:, project_id:, day:, hours:) = write
  let outcome =
    pog.transaction(context.db, fn(conn) {
      use _ <- result.try(sql.timesheet_delete(
        conn,
        engineer_id,
        project_id,
        day,
      ))
      sql.timesheet_write(conn, engineer_id, project_id, day, hours)
    })
  case outcome {
    Ok(_) -> Ok(Nil)
    Error(pog.TransactionQueryError(query_error)) ->
      Error(classify(query_error))
    Error(pog.TransactionRolledBack(query_error)) ->
      Error(classify(query_error))
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
