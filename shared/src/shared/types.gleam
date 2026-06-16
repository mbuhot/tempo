//// Domain/API types shared by server and client. Must stay target-agnostic.
////
//// These are the API contract (ADR-005): the server maps Squirrel rows to them and
//// the client renders them, with `codecs.gleam` carrying the JSON between. They are
//// designed to be **stable across the v1-wide -> v2-split redesign** (ADR-013): the
//// charge rate is a plain value on the row, never "where it came from", so the shape
//// the user sees does not change when the rate source moves from a cached
//// `allocation.day_rate` to the derived `engineer_role × rate_card`.
//// Date fields are `gleam/time/calendar.Date` — the same type Squirrel rows decode
//// to and `pog` parameters expect, so dates flow from the DB through these types to
//// the wire (and back on the client) without a boundary conversion. The codecs
//// still serialise them as ISO-8601 "YYYY-MM-DD" strings, unchanged on the wire.

import gleam/time/calendar.{type Date}

/// An engineer's situation on the org board as of a date. Leave takes precedence
/// over an allocation in the read model: an engineer covered by a leave fact is
/// `OnLeave`, otherwise one `OnProject` per project they are allocated to. An
/// employed engineer with no allocation as of the date is `Unassigned`.
pub type Engagement {
  /// Allocated to a project. `day_rate` is the resolved charge rate as a plain
  /// value (ADR-013) — the same field whether v1 cached it or v2 derives it.
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

/// One line on the org board: an engineer, their level as of the date, and their
/// situation. Engaged engineers contribute one row per project; on-leave engineers
/// contribute a single `OnLeave` row.
pub type BoardRow {
  BoardRow(engineer: String, level: Int, engagement: Engagement)
}

/// The whole org board, as of a single instant.
pub type BoardSnapshot {
  BoardSnapshot(as_of: Date, rows: List(BoardRow))
}

/// One project an engineer may log time against on a given day: the project, the
/// allocation fraction, and the hours already logged (0.0 if none yet). The
/// allocation engagement window is carried as plain `date` bounds (ADR-011).
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
/// to as of `as_of`, each with any hours already logged. Empty when the engineer
/// is on leave that day (the form offers nothing).
pub type TimesheetDay {
  TimesheetDay(engineer_id: Int, as_of: Date, lines: List(TimesheetLine))
}
