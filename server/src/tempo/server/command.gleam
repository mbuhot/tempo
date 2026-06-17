//// Domain: the write-model dispatch seam. Every business change is a typed
//// `Command` (defined in `shared`, so the client encodes it and the server
//// decodes the same value), applied through ONE transaction here. No HTTP — this
//// layer never imports `wisp`.
////
//// `dispatch` opens one `pog.transaction`, routes the command to its aggregate
//// function, then appends exactly one `event_log` row (the operation tag,
//// `summarize(command)`, and the command re-encoded as the JSON payload) — so the
//// facts and their provenance commit together or not at all. `dispatch_in` is the
//// transaction-free core: it runs on an already-open connection so a test can
//// drive it inside its own rolled-back transaction.
////
//// Errors are constraints, not code: the domain issues the write and lets the
//// database reject a violation, then `classify` translates the rejection — by the
//// explicit constraint name carried with PG's SQLSTATE — into a typed
//// `OperationError`. A containment PERIOD FK (`*_within_*`) is
//// `ContainmentViolated`; a `WITHOUT OVERLAPS` exclusion (`*_no_overlap`) is
//// `OverlappingFact`; a `CHECK` (`*_check`, on fraction/level/hours) is
//// `InvalidValue`; anything else is an opaque `DatabaseError`.

import gleam/float
import gleam/int
import gleam/list
import gleam/string
import gleam/time/calendar.{type Date, Date}
import pog
import shared/codecs
import shared/types.{
  type Command, AdjustRateForPortion, AssignToProject, ChangeAllocationFraction,
  LogTimesheet, OnboardEngineer, Promote, ReviseRateCard, RollOff, SignContract,
  StartProject, TakeLeave, TerminateEmployment, WriteRequest,
}
import tempo/server/allocation
import tempo/server/context.{type Context}
import tempo/server/engagement
import tempo/server/engineer
import tempo/server/event
import tempo/server/leave
import tempo/server/rate_card
import tempo/server/timesheet

/// Why an operation was refused, classified from the database's rejection
/// (ADR-022). Maps at the web layer to: `ContainmentViolated`/`OverlappingFact`
/// → 409, `InvalidValue` → 422, `DatabaseError` → 500.
pub type OperationError {
  /// A containment PERIOD FK fired: a fact would dangle outside the one that
  /// contains it (e.g. an allocation past its employment, a timesheet outliving
  /// its allocation). `which` is the violated constraint name.
  ContainmentViolated(which: String)
  /// A `WITHOUT OVERLAPS` exclusion fired: a second fact overlaps an existing one
  /// for the same key (e.g. two allocations for the same engineer+project).
  OverlappingFact
  /// A `CHECK` fired: a value is out of range (fraction, level, or hours).
  InvalidValue
  /// Any other database failure — surfaced opaquely.
  DatabaseError(pog.QueryError)
}

// --- dispatch ---------------------------------------------------------------

/// Apply a command: open one transaction, route to the aggregate, and append the
/// matching `event_log` row — facts and journal commit together or roll back
/// together. A database rejection is classified into a typed `OperationError`.
pub fn dispatch(
  context: Context,
  actor actor: String,
  command command: Command,
) -> Result(Nil, OperationError) {
  let outcome =
    pog.transaction(context.db, fn(conn) { dispatch_in(conn, actor, command) })
  case outcome {
    Ok(Nil) -> Ok(Nil)
    Error(pog.TransactionQueryError(query_error)) ->
      Error(classify(query_error))
    Error(pog.TransactionRolledBack(operation_error)) -> Error(operation_error)
  }
}

/// The transaction-free core of `dispatch`: route the command to its aggregate on
/// the given (already-open) connection, then append exactly one `event_log` row
/// in the SAME connection. The caller owns the transaction — production wraps it
/// in `dispatch`; a test drives it inside its own rolled-back transaction. A
/// database rejection is classified into a typed `OperationError`.
pub fn dispatch_in(
  conn: pog.Connection,
  actor: String,
  command: Command,
) -> Result(Nil, OperationError) {
  case route(conn, command) {
    Error(query_error) -> Error(classify(query_error))
    Ok(Nil) ->
      case
        event.append(
          conn,
          actor:,
          operation: operation_tag(command),
          summary: summarize(command),
          payload: codecs.encode_command(command),
        )
      {
        Ok(_id) -> Ok(Nil)
        Error(query_error) -> Error(classify(query_error))
      }
  }
}

/// Route a command to its aggregate function (the temporal writes only — the
/// `event_log` row is `dispatch`'s job).
fn route(
  conn: pog.Connection,
  command: Command,
) -> Result(Nil, pog.QueryError) {
  case command {
    // --- engineer aggregate ---
    OnboardEngineer(name:, level:, effective:) ->
      engineer.onboard_engineer(conn, name, level, effective)
    Promote(engineer_id:, level:, effective:) ->
      engineer.promote(conn, engineer_id, level, effective)
    TerminateEmployment(engineer_id:, effective:) ->
      engineer.terminate_employment(conn, engineer_id, effective)

    // --- allocation aggregate ---
    AssignToProject(
      engineer_id:,
      project_id:,
      fraction:,
      valid_from:,
      valid_to:,
    ) ->
      allocation.assign_to_project(
        conn,
        engineer_id,
        project_id,
        fraction,
        valid_from,
        valid_to,
      )
    ChangeAllocationFraction(engineer_id:, project_id:, fraction:, effective:) ->
      allocation.change_allocation_fraction(
        conn,
        engineer_id,
        project_id,
        fraction,
        effective,
      )
    RollOff(engineer_id:, project_id:, effective:) ->
      allocation.roll_off(conn, engineer_id, project_id, effective)

    // --- timesheet aggregate (reuse the existing temporal-upsert core) ---
    LogTimesheet(engineer_id:, project_id:, day:, hours:) ->
      log_timesheet(conn, engineer_id, project_id, day, hours)

    // --- engagement aggregate ---
    SignContract(client:, valid_from:, valid_to:) ->
      engagement.sign_contract(conn, client, valid_from, valid_to)
    StartProject(name:, contract_id:, valid_from:, valid_to:) ->
      engagement.start_project(conn, name, contract_id, valid_from, valid_to)

    // --- rate-card aggregate ---
    ReviseRateCard(level:, day_rate:, effective:) ->
      rate_card.revise_rate_card(conn, level, day_rate, effective)
    AdjustRateForPortion(level:, day_rate:, valid_from:, valid_to:) ->
      rate_card.adjust_rate_for_portion(
        conn,
        level,
        day_rate,
        valid_from,
        valid_to,
      )

    // --- leave aggregate ---
    TakeLeave(engineer_id:, kind:, valid_from:, valid_to:) ->
      leave.take_leave(conn, engineer_id, kind, valid_from, valid_to)
  }
}

/// Log a timesheet day by reusing the existing temporal-upsert core
/// (`timesheet.log_in`). Its `WriteError` is re-surfaced as a `pog.QueryError` so
/// the unified `classify` maps the PERIOD-FK rejection like any other containment
/// violation (`timesheet_within_allocation` → `ContainmentViolated`).
fn log_timesheet(
  conn: pog.Connection,
  engineer_id: Int,
  project_id: Int,
  day: Date,
  hours: Float,
) -> Result(Nil, pog.QueryError) {
  case
    timesheet.log_in(
      conn,
      WriteRequest(engineer_id:, project_id:, day:, hours:),
    )
  {
    Ok(Nil) -> Ok(Nil)
    Error(timesheet.DatabaseError(query_error)) -> Error(query_error)
    Error(timesheet.NotAllocated) ->
      Error(pog.ConstraintViolated(
        message: "timesheet not covered by an allocation",
        constraint: "timesheet_within_allocation",
        detail: "",
      ))
  }
}

// --- classification ---------------------------------------------------------

/// Translate a database rejection into a typed `OperationError` by the explicit
/// constraint name (ADR-022, §4). PG19 populates the `constraint` field for FK,
/// exclusion, and check violations, so they arrive as `pog.ConstraintViolated`;
/// the `PostgresqlError` arm is the defensive fallback for an FK error that names
/// the constraint only in its message.
pub fn classify(error: pog.QueryError) -> OperationError {
  case error {
    pog.ConstraintViolated(constraint:, ..) -> classify_constraint(constraint)
    pog.PostgresqlError(message:, ..) ->
      classify_constraint(extract_constraint(message))
    _ -> DatabaseError(error)
  }
}

/// Classify by the constraint name's role: `*_within_*` is a containment PERIOD
/// FK, `*_no_overlap` a `WITHOUT OVERLAPS` exclusion, `*_check` a `CHECK`. An
/// unrecognised name stays an opaque `DatabaseError`.
fn classify_constraint(constraint: String) -> OperationError {
  case
    string.contains(constraint, "_within_"),
    string.ends_with(constraint, "_no_overlap"),
    string.ends_with(constraint, "_check")
  {
    True, _, _ -> ContainmentViolated(which: constraint)
    _, True, _ -> OverlappingFact
    _, _, True -> InvalidValue
    False, False, False ->
      DatabaseError(pog.ConstraintViolated(
        message: "unclassified constraint",
        constraint:,
        detail: "",
      ))
  }
}

/// Pull the quoted constraint name out of `… violates … constraint "<name>"` when
/// PG reports it only in the message (the `PostgresqlError` fallback).
fn extract_constraint(message: String) -> String {
  case list.last(string.split(message, "constraint \"")) {
    Ok(tail) ->
      case list.first(string.split(tail, "\"")) {
        Ok(name) -> name
        Error(Nil) -> message
      }
    Error(Nil) -> message
  }
}

// --- summarize + operation tag ----------------------------------------------

/// The command's `event_log` operation tag — the same discriminator the shared
/// codec uses on the wire, so the journal's `operation` and `payload.op` agree.
pub fn operation_tag(command: Command) -> String {
  case command {
    OnboardEngineer(..) -> "onboard_engineer"
    SignContract(..) -> "sign_contract"
    StartProject(..) -> "start_project"
    AssignToProject(..) -> "assign_to_project"
    TakeLeave(..) -> "take_leave"
    LogTimesheet(..) -> "log_timesheet"
    Promote(..) -> "promote"
    ChangeAllocationFraction(..) -> "change_allocation_fraction"
    ReviseRateCard(..) -> "revise_rate_card"
    AdjustRateForPortion(..) -> "adjust_rate_for_portion"
    RollOff(..) -> "roll_off"
    TerminateEmployment(..) -> "terminate_employment"
  }
}

/// A terse, precise human line for the journal's `summary` (ids and values are
/// fine — the journal is operational, not a public surface).
pub fn summarize(command: Command) -> String {
  case command {
    OnboardEngineer(name:, level:, effective:) ->
      "Onboard "
      <> name
      <> " at L"
      <> int.to_string(level)
      <> " from "
      <> iso(effective)
    SignContract(client:, valid_from:, valid_to:) ->
      "Sign contract for " <> client <> " over " <> span(valid_from, valid_to)
    StartProject(name:, contract_id:, valid_from:, valid_to:) ->
      "Start project "
      <> name
      <> " under contract "
      <> int.to_string(contract_id)
      <> " over "
      <> span(valid_from, valid_to)
    AssignToProject(
      engineer_id:,
      project_id:,
      fraction:,
      valid_from:,
      valid_to:,
    ) ->
      "Assign engineer "
      <> int.to_string(engineer_id)
      <> " to project "
      <> int.to_string(project_id)
      <> " at "
      <> float.to_string(fraction)
      <> " over "
      <> span(valid_from, valid_to)
    TakeLeave(engineer_id:, kind:, valid_from:, valid_to:) ->
      "Engineer "
      <> int.to_string(engineer_id)
      <> " on "
      <> kind
      <> " leave over "
      <> span(valid_from, valid_to)
    LogTimesheet(engineer_id:, project_id:, day:, hours:) ->
      "Log "
      <> float.to_string(hours)
      <> "h for engineer "
      <> int.to_string(engineer_id)
      <> " on project "
      <> int.to_string(project_id)
      <> " on "
      <> iso(day)
    Promote(engineer_id:, level:, effective:) ->
      "Promote engineer "
      <> int.to_string(engineer_id)
      <> " to L"
      <> int.to_string(level)
      <> " from "
      <> iso(effective)
    ChangeAllocationFraction(engineer_id:, project_id:, fraction:, effective:) ->
      "Change engineer "
      <> int.to_string(engineer_id)
      <> " allocation on project "
      <> int.to_string(project_id)
      <> " to "
      <> float.to_string(fraction)
      <> " from "
      <> iso(effective)
    ReviseRateCard(level:, day_rate:, effective:) ->
      "Revise L"
      <> int.to_string(level)
      <> " rate to "
      <> float.to_string(day_rate)
      <> " from "
      <> iso(effective)
    AdjustRateForPortion(level:, day_rate:, valid_from:, valid_to:) ->
      "Adjust L"
      <> int.to_string(level)
      <> " rate to "
      <> float.to_string(day_rate)
      <> " over "
      <> span(valid_from, valid_to)
    RollOff(engineer_id:, project_id:, effective:) ->
      "Roll engineer "
      <> int.to_string(engineer_id)
      <> " off project "
      <> int.to_string(project_id)
      <> " from "
      <> iso(effective)
    TerminateEmployment(engineer_id:, effective:) ->
      "Terminate engineer "
      <> int.to_string(engineer_id)
      <> " employment from "
      <> iso(effective)
  }
}

fn span(from: Date, to: Date) -> String {
  iso(from) <> ".." <> iso(to)
}

/// Render a `Date` as ISO-8601 "YYYY-MM-DD", matching the codec wire format.
fn iso(date: Date) -> String {
  let Date(year:, month:, day:) = date
  pad(year, 4)
  <> "-"
  <> pad(calendar.month_to_int(month), 2)
  <> "-"
  <> pad(day, 2)
}

fn pad(value: Int, width: Int) -> String {
  int.to_string(value) |> string.pad_start(to: width, with: "0")
}
