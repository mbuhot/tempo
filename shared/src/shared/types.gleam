//// Domain/API types shared by server and client. Must stay target-agnostic.
////
//// These are the API contract: the server maps Squirrel rows to them and the
//// client renders them, with `codecs.gleam` carrying the JSON between. The charge
//// rate is a plain value on the row, never "where it came from".
//// Date fields are `gleam/time/calendar.Date` — the same type Squirrel rows decode
//// to and `pog` parameters expect, so dates flow from the DB through these types to
//// the wire (and back on the client) without a boundary conversion. The codecs
//// still serialise them as ISO-8601 "YYYY-MM-DD" strings, unchanged on the wire.

import gleam/time/calendar.{type Date}

/// An engineer's situation on the org board for a date. Leave takes precedence
/// over an allocation in the read model: an engineer covered by a leave fact is
/// `OnLeave`, otherwise one `OnProject` per project they are allocated to. An
/// employed engineer with no allocation on the date is `Unassigned`.
pub type Engagement {
  /// Allocated to a project. `day_rate` is the resolved charge rate as a plain
  /// value.
  OnProject(
    project: String,
    client: String,
    fraction: Float,
    day_rate: Float,
    valid_from: Date,
    valid_to: Date,
  )
  /// Covered by a leave fact; the underlying allocation is suppressed. `kind` is
  /// the leave kind (annual | sick | parental | …); the period is the leave window.
  OnLeave(kind: String, valid_from: Date, valid_to: Date)
  /// Employed but not allocated (and not on leave) as of the date.
  Unassigned
}

/// One line on the org board: an engineer, their level on the date, and their
/// situation. Engaged engineers contribute one row per project; on-leave engineers
/// contribute a single `OnLeave` row.
pub type BoardRow {
  BoardRow(engineer: String, level: Int, engagement: Engagement)
}

/// The whole org board for a single date.
pub type BoardSnapshot {
  BoardSnapshot(date: Date, rows: List(BoardRow))
}

/// One project an engineer may log time against on a given day: the project, the
/// allocation fraction, and the hours already logged (0.0 if none yet). The
/// allocation engagement window is carried as plain `date` bounds.
pub type TimesheetLine {
  TimesheetLine(
    project_id: Int,
    project: String,
    fraction: Float,
    hours: Float,
    valid_from: Date,
    valid_to: Date,
  )
}

/// An engineer's timesheet form for one day: only the projects they are allocated
/// to on `date`, each with any hours already logged. Empty when the engineer
/// is on leave that day (the form offers nothing).
pub type TimesheetDay {
  TimesheetDay(engineer_id: Int, date: Date, lines: List(TimesheetLine))
}

/// A validated timesheet write request: which engineer logs how many hours
/// against which project on which day. This decoded payload IS the POST
/// /api/timesheet contract — the client encodes it, the server decodes it, and
/// the domain logs it.
pub type WriteRequest {
  WriteRequest(engineer_id: Int, project_id: Int, day: Date, hours: Float)
}

/// The typed command vocabulary (the write model). One variant per business
/// operation: the client encodes a `Command`, the server decodes the same value
/// and dispatches it to the matching temporal write, then re-encodes it as the
/// `event_log` payload. Defined in `shared` so both ends agree on the contract.
///
/// The variants group into the four write patterns:
///   * Assert — `OnboardEngineer`, `SignContract`, `StartProject`,
///     `AssignToProject`, `TakeLeave`, `LogTimesheet`: plain inserts.
///   * Change — `Promote`, `ChangeAllocationFraction`, `ReviseRateCard`:
///     "publish a new version effective from a date" (`FOR PORTION OF … TO NULL`).
///   * Surgical — `AdjustRateForPortion`: bump a level's rate for a bounded
///     window (`FOR PORTION OF … FROM a TO b`).
///   * Close / cascade — `RollOff`, `TerminateEmployment`:
///     `DELETE … FOR PORTION OF`.
///
/// Date fields carry domain meaning: `effective` is the open-ended "from here on"
/// pivot of a change/close; `valid_from`/`valid_to` bound an asserted or surgical
/// period. Levels and ids are `Int`, fraction/hours/rate are `Float`, and
/// name/kind/client are `String`.
pub type Command {
  /// Hire an engineer: create their identity, open-ended employment, and initial
  /// role, all from `effective`.
  OnboardEngineer(name: String, level: Int, effective: Date)
  /// Open a contract term for a client.
  SignContract(client: String, valid_from: Date, valid_to: Date)
  /// Start a project under a contract for a bounded active period.
  StartProject(name: String, contract_id: Int, valid_from: Date, valid_to: Date)
  /// Allocate an engineer to a project at a fraction for a period.
  AssignToProject(
    engineer_id: Int,
    project_id: Int,
    fraction: Float,
    valid_from: Date,
    valid_to: Date,
  )
  /// Put an engineer on leave of a kind for a period.
  TakeLeave(engineer_id: Int, kind: String, valid_from: Date, valid_to: Date)
  /// Log hours an engineer worked on a project on a day.
  LogTimesheet(engineer_id: Int, project_id: Int, day: Date, hours: Float)
  /// Promote an engineer to a new level effective from a date.
  Promote(engineer_id: Int, level: Int, effective: Date)
  /// Change an engineer's allocation fraction on a project effective from a date.
  ChangeAllocationFraction(
    engineer_id: Int,
    project_id: Int,
    fraction: Float,
    effective: Date,
  )
  /// Publish a new day rate for a level effective from a date.
  ReviseRateCard(level: Int, day_rate: Float, effective: Date)
  /// Bump a level's day rate for a bounded window, splitting the rate-card row
  /// into before/during/after.
  AdjustRateForPortion(
    level: Int,
    day_rate: Float,
    valid_from: Date,
    valid_to: Date,
  )
  /// Cap an engineer's allocation on a project from a date (roll off the project).
  RollOff(engineer_id: Int, project_id: Int, effective: Date)
  /// Terminate an engineer's employment from a date, capping every contained fact.
  TerminateEmployment(engineer_id: Int, effective: Date)
}

/// The POST /api/operations request body: an `actor` (who is applying the
/// operation — nominal, no auth) and the `Command` to apply. The client encodes
/// this envelope and the server decodes it, then dispatches the command on the
/// actor's behalf. Defined in `shared` so both ends agree on the contract.
pub type OperationRequest {
  OperationRequest(actor: String, command: Command)
}

/// One row of the provenance journal read model. The server appends an `Event`
/// per dispatched `Command` (the `operation` tag, a human `summary`, and the
/// command re-encoded as `payload`); the client renders the journal. `payload`
/// is carried as a raw JSON string so the journal view can show it verbatim
/// without re-decoding the original `Command` variant.
pub type Event {
  Event(
    id: Int,
    occurred_at: String,
    actor: String,
    operation: String,
    summary: String,
    payload: String,
  )
}
