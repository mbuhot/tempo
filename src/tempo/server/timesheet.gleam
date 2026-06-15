//// Target: Erlang only — timesheet read (my allocations as-of a day) and write (PERIOD-FK-backed insert) handlers.
////
//// Read maps `timesheet_form` rows (ARCHITECTURE.md §5) to the shared
//// `TimesheetDay`. Write is the delete-then-insert temporal upsert (P1-T04): the
//// `WITHOUT OVERLAPS` PK cannot be an `ON CONFLICT` target, so re-entry deletes
//// the covering row then inserts, both in one transaction. The `PERIOD` FK to
//// `allocation` is the backstop — logging against a project the engineer is not
//// allocated to that day is rejected by the database (PRD FR-5). That rejection
//// (SQLSTATE 23503) is surfaced as a clean 422 typed error, never a 500.

import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import pog
import tempo/server/context.{type Context}
import tempo/server/date
import tempo/server/sql
import tempo/shared/codecs
import tempo/shared/types.{
  type AsOf, type Date, type TimesheetDay, type TimesheetLine, AsOf,
  TimesheetDay, TimesheetLine,
}
import wisp

/// A validated timesheet write request: which engineer logs how many hours
/// against which project on which day. Parsed from the POST JSON body.
pub type WriteRequest {
  WriteRequest(engineer_id: Int, project_id: Int, day: Date, hours: Float)
}

/// Why a timesheet write was refused. `NotAllocated` is the domain rejection the
/// `PERIOD` FK enforces (the project is not covered by an allocation that day);
/// it maps to a 4xx. `DatabaseError` is any other failure and maps to a 500.
pub type WriteError {
  NotAllocated
  DatabaseError(pog.QueryError)
}

/// The timesheet PERIOD foreign-key constraint. A violation of *this* constraint
/// is the domain rejection (the logged day is not covered by an allocation, PRD
/// FR-5); pog reports it as `ConstraintViolated` carrying this name.
const timesheet_period_fk = "timesheet_engineer_id_project_id_work_day_fkey"

// --- read -------------------------------------------------------------------

/// Handle GET /api/timesheet?engineer=ID&day=YYYY-MM-DD — my allocations as of a
/// day, with any logged hours. Missing/malformed params are a 400; a DB failure
/// is a 500.
pub fn handle_read(request: wisp.Request, context: Context) -> wisp.Response {
  use <- wisp.require_method(request, http.Get)
  case read_params(request) {
    Error(detail) -> wisp.bad_request(detail)
    Ok(#(engineer_id, as_of)) ->
      case form(context, engineer_id, as_of) {
        Ok(day) ->
          day
          |> codecs.encode_timesheet_day
          |> json.to_string
          |> wisp.json_response(200)
        Error(_) -> wisp.internal_server_error()
      }
  }
}

/// Compute the timesheet form for an engineer as of a day: run `timesheet_form`
/// and map each row to the shared `TimesheetLine` (empty on a leave day).
pub fn form(
  context: Context,
  engineer_id: Int,
  as_of: AsOf,
) -> Result(TimesheetDay, pog.QueryError) {
  let day = date.as_of_to_calendar(as_of)
  use returned <- result.map(sql.timesheet_form(context.db, engineer_id, day))
  let lines = list.map(returned.rows, form_row_to_shared)
  TimesheetDay(engineer_id:, as_of:, lines:)
}

fn form_row_to_shared(row: sql.TimesheetFormRow) -> TimesheetLine {
  TimesheetLine(
    project_id: row.project_id,
    project: row.project,
    fraction: row.fraction,
    hours: row.hours,
    valid_from: date.from_calendar(row.valid_from),
    valid_to: date.from_calendar(row.valid_to),
  )
}

fn read_params(request: wisp.Request) -> Result(#(Int, AsOf), String) {
  use engineer_id <- result.try(int_param(request, "engineer"))
  use as_of <- result.map(date.as_of_from_query(request, "day"))
  #(engineer_id, as_of)
}

fn int_param(request: wisp.Request, name: String) -> Result(Int, String) {
  case list.key_find(wisp.get_query(request), name) {
    Error(Nil) -> Error("missing query parameter '" <> name <> "'")
    Ok(text) ->
      int.parse(text)
      |> result.replace_error(
        "invalid integer '" <> text <> "' for '" <> name <> "'",
      )
  }
}

// --- write ------------------------------------------------------------------

/// Handle POST /api/timesheet — log hours for a project on a day. The JSON body
/// is `{engineer_id, project_id, day, hours}`. A malformed body is a 400; a day
/// with no covering allocation (PERIOD-FK violation) is a clean 422 with a typed
/// error body; any other DB failure is a 500. On success returns the refreshed
/// timesheet form for that engineer/day so the client can re-render.
pub fn handle_write(request: wisp.Request, context: Context) -> wisp.Response {
  use <- wisp.require_method(request, http.Post)
  use body <- wisp.require_json(request)
  case decode.run(body, write_request_decoder()) {
    Error(_) ->
      error_response(
        400,
        "invalid_body",
        "expected {engineer_id, project_id, day, hours}",
      )
    Ok(write) ->
      case upsert(context, write) {
        Ok(Nil) -> read_form_response(context, write.engineer_id, write.day)
        Error(NotAllocated) ->
          error_response(
            422,
            "not_allocated",
            "the engineer is not allocated to that project on that day",
          )
        Error(DatabaseError(_)) -> wisp.internal_server_error()
      }
  }
}

/// Run the delete-then-insert temporal upsert in one transaction (P1-T04). A
/// PERIOD-FK rejection rolls back the delete (the prior row survives) and is
/// classified as `NotAllocated`; any other query error becomes `DatabaseError`.
pub fn upsert(
  context: Context,
  write: WriteRequest,
) -> Result(Nil, WriteError) {
  let WriteRequest(engineer_id:, project_id:, day:, hours:) = write
  let calendar_day = date.to_calendar(day)
  let outcome =
    pog.transaction(context.db, fn(conn) {
      use _ <- result.try(sql.timesheet_delete(
        conn,
        engineer_id,
        project_id,
        calendar_day,
      ))
      sql.timesheet_write(conn, engineer_id, project_id, calendar_day, hours)
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

fn read_form_response(
  context: Context,
  engineer_id: Int,
  work_day: Date,
) -> wisp.Response {
  case form(context, engineer_id, as_of_from_date(work_day)) {
    Ok(form) ->
      form
      |> codecs.encode_timesheet_day
      |> json.to_string
      |> wisp.json_response(200)
    Error(_) -> wisp.internal_server_error()
  }
}

fn as_of_from_date(work_day: Date) -> AsOf {
  let types.Date(year:, month:, day:) = work_day
  AsOf(year:, month:, day:)
}

fn write_request_decoder() -> decode.Decoder(WriteRequest) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use project_id <- decode.field("project_id", decode.int)
  use day <- decode.field("day", codecs.date_decoder())
  use hours <- decode.field("hours", decode.float)
  decode.success(WriteRequest(engineer_id:, project_id:, day:, hours:))
}

/// A small typed error body: `{error: <code>, detail: <message>}`.
fn error_response(status: Int, code: String, detail: String) -> wisp.Response {
  json.object([
    #("error", json.string(code)),
    #("detail", json.string(detail)),
  ])
  |> json.to_string
  |> wisp.json_response(status)
}
