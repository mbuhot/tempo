//// Layer-4 codec round-trip tests (ARCHITECTURE.md §10.4): `encode |> decode`
//// is identity for every shared API type. Pure Gleam, no DB, runs unchanged on
//// both targets (Erlang + JS) — the same property that lets `shared/codecs`
//// carry the contract across the JSON-over-HTTP boundary (ADR-005).
////
//// Each test serialises a value to a JSON string, parses it back through the
//// matching decoder, and asserts exact equality. Values are explicit and
//// deterministic (no factory sequences): the dates mirror the seed's
//// "now" = 2026-06-15 frame. Edge cases covered per the task spec: the on-leave
//// engagement (project/client absent), the `Unassigned` engagement, and a
//// zero-hours timesheet line.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import tempo/shared/codecs
import tempo/shared/types.{
  AsOf, BoardRow, BoardSnapshot, Date, OnLeave, OnProject, TimesheetDay,
  TimesheetLine, Unassigned,
}

/// Encode `value`, serialise to a JSON string, then parse it back through
/// `decoder` — the full wire round-trip both targets perform. Returns the
/// decoded value (or panics, surfacing the failure as a test error).
fn round_trip(value: a, encode: fn(a) -> Json, decoder: Decoder(a)) -> a {
  let assert Ok(decoded) =
    value
    |> encode
    |> json.to_string
    |> json.parse(decoder)
  decoded
}

// --- Date -------------------------------------------------------------------

pub fn date_round_trips_test() {
  let original = Date(2026, 6, 15)

  assert round_trip(original, codecs.encode_date, codecs.date_decoder())
    == original
}

// --- AsOf -------------------------------------------------------------------

pub fn as_of_round_trips_test() {
  let original = AsOf(2026, 6, 15)

  assert round_trip(original, codecs.encode_as_of, codecs.as_of_decoder())
    == original
}

// --- Engagement -------------------------------------------------------------

pub fn engagement_on_project_round_trips_test() {
  let original =
    OnProject(
      project: "Ledger Migration",
      client: "Northwind Trading",
      fraction: 0.5,
      day_rate: 1200.0,
      valid_from: Date(2024, 1, 1),
      valid_to: Date(2026, 7, 1),
    )

  assert round_trip(
      original,
      codecs.encode_engagement,
      codecs.engagement_decoder(),
    )
    == original
}

// Edge case: on-leave row — project and client are absent (PRD FR-4). The
// tagged decoder must reconstruct `OnLeave` from `status` alone.
pub fn engagement_on_leave_round_trips_test() {
  let original =
    OnLeave(
      kind: "annual",
      valid_from: Date(2026, 6, 8),
      valid_to: Date(2026, 6, 22),
    )

  assert round_trip(
      original,
      codecs.encode_engagement,
      codecs.engagement_decoder(),
    )
    == original
}

// Edge case: employed but unallocated — a payload-free variant.
pub fn engagement_unassigned_round_trips_test() {
  let original = Unassigned

  assert round_trip(
      original,
      codecs.encode_engagement,
      codecs.engagement_decoder(),
    )
    == original
}

// --- BoardRow ---------------------------------------------------------------

pub fn board_row_round_trips_test() {
  let original =
    BoardRow(
      engineer: "Priya Sharma",
      level: 5,
      engagement: OnProject(
        project: "Inventory Sync",
        client: "Northwind Trading",
        fraction: 0.5,
        day_rate: 1200.0,
        valid_from: Date(2025, 6, 1),
        valid_to: Date(2026, 7, 1),
      ),
    )

  assert round_trip(
      original,
      codecs.encode_board_row,
      codecs.board_row_decoder(),
    )
    == original
}

// A board row carrying the on-leave engagement, so the nested tagged variant
// round-trips inside its container.
pub fn board_row_on_leave_round_trips_test() {
  let original =
    BoardRow(
      engineer: "Aisha Okafor",
      level: 6,
      engagement: OnLeave(
        kind: "annual",
        valid_from: Date(2026, 6, 8),
        valid_to: Date(2026, 6, 22),
      ),
    )

  assert round_trip(
      original,
      codecs.encode_board_row,
      codecs.board_row_decoder(),
    )
    == original
}

// --- BoardSnapshot ----------------------------------------------------------

// The whole board as of the seed "now": a mix of on-project and on-leave rows,
// proving the list and every nested variant survive the round trip together.
pub fn board_snapshot_round_trips_test() {
  let original =
    BoardSnapshot(as_of: AsOf(2026, 6, 15), rows: [
      BoardRow(
        engineer: "Marcus Chen",
        level: 4,
        engagement: OnProject(
          project: "Data Platform",
          client: "Globex Corporation",
          fraction: 1.0,
          day_rate: 1000.0,
          valid_from: Date(2025, 1, 1),
          valid_to: Date(2026, 7, 1),
        ),
      ),
      BoardRow(
        engineer: "Aisha Okafor",
        level: 6,
        engagement: OnLeave(
          kind: "annual",
          valid_from: Date(2026, 6, 8),
          valid_to: Date(2026, 6, 22),
        ),
      ),
    ])

  assert round_trip(
      original,
      codecs.encode_board_snapshot,
      codecs.board_snapshot_decoder(),
    )
    == original
}

// An empty board (no employed engineers as of the date) still round-trips.
pub fn board_snapshot_empty_round_trips_test() {
  let original = BoardSnapshot(as_of: AsOf(2026, 6, 15), rows: [])

  assert round_trip(
      original,
      codecs.encode_board_snapshot,
      codecs.board_snapshot_decoder(),
    )
    == original
}

// --- TimesheetLine ----------------------------------------------------------

pub fn timesheet_line_round_trips_test() {
  let original =
    TimesheetLine(
      project_id: 200,
      project: "Inventory Sync",
      fraction: 0.5,
      hours: 4.0,
      valid_from: Date(2025, 6, 1),
      valid_to: Date(2026, 7, 1),
    )

  assert round_trip(
      original,
      codecs.encode_timesheet_line,
      codecs.timesheet_line_decoder(),
    )
    == original
}

// Edge case: zero-hours line — a project offered for the day with nothing
// logged yet (the form's COALESCE(hours, 0) default). 0.0 must survive the
// JSON float round trip.
pub fn timesheet_line_zero_hours_round_trips_test() {
  let original =
    TimesheetLine(
      project_id: 100,
      project: "Ledger Migration",
      fraction: 0.5,
      hours: 0.0,
      valid_from: Date(2024, 1, 1),
      valid_to: Date(2026, 7, 1),
    )

  assert round_trip(
      original,
      codecs.encode_timesheet_line,
      codecs.timesheet_line_decoder(),
    )
    == original
}

// --- TimesheetDay -----------------------------------------------------------

pub fn timesheet_day_round_trips_test() {
  let original =
    TimesheetDay(engineer_id: 1, as_of: AsOf(2026, 6, 9), lines: [
      TimesheetLine(
        project_id: 200,
        project: "Inventory Sync",
        fraction: 0.5,
        hours: 4.0,
        valid_from: Date(2025, 6, 1),
        valid_to: Date(2026, 7, 1),
      ),
      TimesheetLine(
        project_id: 100,
        project: "Ledger Migration",
        fraction: 0.5,
        hours: 0.0,
        valid_from: Date(2024, 1, 1),
        valid_to: Date(2026, 7, 1),
      ),
    ])

  assert round_trip(
      original,
      codecs.encode_timesheet_day,
      codecs.timesheet_day_decoder(),
    )
    == original
}

// An empty timesheet day — the form a leave day produces (no projects offered,
// PRD FR-4/FR-5) — round-trips to the same empty form.
pub fn timesheet_day_on_leave_empty_round_trips_test() {
  let original =
    TimesheetDay(engineer_id: 3, as_of: AsOf(2026, 6, 15), lines: [])

  assert round_trip(
      original,
      codecs.encode_timesheet_day,
      codecs.timesheet_day_decoder(),
    )
    == original
}
