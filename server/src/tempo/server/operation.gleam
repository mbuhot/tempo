//// Domain leaf: the journal `Event` an aggregate handler emits, the typed
//// `OperationError` a rejected operation classifies into, and the small shared
//// helpers (constraint classification, date rendering) the handlers need to build
//// their summaries. No HTTP and — deliberately — no dependency on the aggregate or
//// `command` modules, so it sits below them in the import graph (avoids a cycle).
////
//// Errors are constraints, not code: an aggregate issues the write and lets the
//// database reject a violation, then `classify` translates the rejection — by the
//// explicit constraint name carried with PG's SQLSTATE — into a typed
//// `OperationError`. A containment PERIOD FK (`*_within_*`) is
//// `ContainmentViolated`; a `WITHOUT OVERLAPS` exclusion (`*_no_overlap`) is
//// `OverlappingFact`; a `CHECK` (`*_check`, on fraction/level/hours) is
//// `InvalidValue`; anything else is an opaque `DatabaseError`.

import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date, Date}
import pog

/// The flat journal event an aggregate handler emits: the operation tag, a terse
/// human summary, and the command re-encoded as the JSON payload. It carries no
/// `id`/`occurred_at`/`actor` — those are assigned when the event is persisted
/// (`event.append`).
pub type Event {
  Event(operation: String, summary: String, payload: Json)
}

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
  /// A leave request exceeds the engineer's accrued-minus-taken balance for that
  /// kind on return (the `take_leave` guard, not a database constraint). `available`
  /// is the balance on return, `requested` the days asked for.
  InsufficientLeaveBalance(kind: String, available: Float, requested: Float)
  /// An allocation was requested for an engineer who is not employed for the WHOLE
  /// `[valid_from, valid_to)` window (the `assign_to_project` guard, checked before
  /// the write). Caught here for a clear domain error rather than left to the
  /// `allocation_within_employment` containment FK.
  EngineerNotEmployed(engineer_id: Int, valid_from: Date, valid_to: Date)
  /// An allocation was requested against a project whose run does not cover the
  /// WHOLE `[valid_from, valid_to)` window (the `assign_to_project` guard). The
  /// project-side analogue of `EngineerNotEmployed`, ahead of the
  /// `allocation_within_project` containment FK.
  ProjectNotRunning(project_id: Int, valid_from: Date, valid_to: Date)
  /// A revise (`salary`/`rate_card`) targeted a level/date with no covering
  /// version: the `FOR PORTION OF` UPDATE matched zero rows, so there was nothing
  /// to re-rate. Rejected rather than journalled as a no-op (the audit log must
  /// not record a money change that never happened).
  NoSuchVersion
  /// The authenticated principal is not permitted to run this command (issue #6):
  /// the authorization gate refused it BEFORE any transaction opened. `actor` is
  /// the principal that was refused and `command` names the command. Maps to a 403.
  Unauthorized(actor: String, command: String)
  /// Any other database failure — surfaced opaquely.
  DatabaseError(pog.QueryError)
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

// --- result helper ----------------------------------------------------------

/// Run a database call, classifying any rejection into a typed `OperationError`,
/// then continue with its value. Encapsulates the
/// `result.try(… |> result.map_error(classify))` an aggregate repeats for every
/// temporal write, so a handler body reads as a sequence of
/// `use _ <- operation.try(sql.…)`.
pub fn try(
  result: Result(a, pog.QueryError),
  apply: fn(a) -> Result(b, OperationError),
) -> Result(b, OperationError) {
  result
  |> result.map_error(classify)
  |> result.try(apply)
}

/// Run a single terminal database write (or a `list.try_map` of writes):
/// discard the empty returned value and classify any rejection into an
/// `OperationError`. Use this where there is nothing to thread into a next step;
/// `try` is for chaining.
pub fn run(result: Result(a, pog.QueryError)) -> Result(Nil, OperationError) {
  result
  |> result.replace(Nil)
  |> result.map_error(classify)
}

// --- date rendering ---------------------------------------------------------
// Shared by the aggregate handlers when they build the journal `summary`.

/// Render a `[from, to)` span as `from..to`, each ISO-8601 "YYYY-MM-DD".
pub fn span(from: Date, to: Date) -> String {
  iso(from) <> ".." <> iso(to)
}

/// Render a `Date` as ISO-8601 "YYYY-MM-DD", matching the codec wire format.
pub fn iso(date: Date) -> String {
  let Date(year:, month:, day:) = date
  pad(year, 4)
  <> "-"
  <> pad(calendar.month_to_int(month), 2)
  <> "-"
  <> pad(day, 2)
}

/// Left-pad an integer to `width` with leading zeros (e.g. month 3 -> "03").
pub fn pad(value: Int, width: Int) -> String {
  int.to_string(value) |> string.pad_start(to: width, with: "0")
}
