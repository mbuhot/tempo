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
import gleam/time/calendar.{Date, January, July, June}
import shared/codecs
import shared/types.{
  AdjustRateForPortion, AssignToProject, BoardRow, BoardSnapshot,
  ChangeAllocationFraction, Event, LogTimesheet, OnLeave, OnProject,
  OnboardEngineer, OperationRequest, Promote, ReviseRateCard, RollOff,
  SignContract, StartProject, TakeLeave, TerminateEmployment, TimesheetDay,
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
  let original = Date(2026, June, 15)

  assert round_trip(original, codecs.encode_date, codecs.date_decoder())
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
      valid_from: Date(2024, January, 1),
      valid_to: Date(2026, July, 1),
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
      valid_from: Date(2026, June, 8),
      valid_to: Date(2026, June, 22),
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
        valid_from: Date(2025, June, 1),
        valid_to: Date(2026, July, 1),
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
        valid_from: Date(2026, June, 8),
        valid_to: Date(2026, June, 22),
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

// The whole board for the seed "now": a mix of on-project and on-leave rows,
// proving the list and every nested variant survive the round trip together.
pub fn board_snapshot_round_trips_test() {
  let original =
    BoardSnapshot(date: Date(2026, June, 15), rows: [
      BoardRow(
        engineer: "Marcus Chen",
        level: 4,
        engagement: OnProject(
          project: "Data Platform",
          client: "Globex Corporation",
          fraction: 1.0,
          day_rate: 1000.0,
          valid_from: Date(2025, January, 1),
          valid_to: Date(2026, July, 1),
        ),
      ),
      BoardRow(
        engineer: "Aisha Okafor",
        level: 6,
        engagement: OnLeave(
          kind: "annual",
          valid_from: Date(2026, June, 8),
          valid_to: Date(2026, June, 22),
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

// An empty board (no employed engineers on the date) still round-trips.
pub fn board_snapshot_empty_round_trips_test() {
  let original = BoardSnapshot(date: Date(2026, June, 15), rows: [])

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
      valid_from: Date(2025, June, 1),
      valid_to: Date(2026, July, 1),
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
      valid_from: Date(2024, January, 1),
      valid_to: Date(2026, July, 1),
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
    TimesheetDay(engineer_id: 1, date: Date(2026, June, 9), lines: [
      TimesheetLine(
        project_id: 200,
        project: "Inventory Sync",
        fraction: 0.5,
        hours: 4.0,
        valid_from: Date(2025, June, 1),
        valid_to: Date(2026, July, 1),
      ),
      TimesheetLine(
        project_id: 100,
        project: "Ledger Migration",
        fraction: 0.5,
        hours: 0.0,
        valid_from: Date(2024, January, 1),
        valid_to: Date(2026, July, 1),
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
    TimesheetDay(engineer_id: 3, date: Date(2026, June, 15), lines: [])

  assert round_trip(
      original,
      codecs.encode_timesheet_day,
      codecs.timesheet_day_decoder(),
    )
    == original
}

// --- Command ----------------------------------------------------------------
// One round-trip per operation in the write vocabulary. The same `encode_command`
// serves both the POST /api/operations body and the event_log payload, so the
// `op` tag must reconstruct the exact variant. Values are explicit and anchored
// to the seed frame (engineer/project ids, levels, rates from 003_seed.sql).

pub fn command_onboard_engineer_round_trips_test() {
  let original =
    OnboardEngineer(name: "Dev Patel", level: 3, effective: Date(2026, July, 1))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_sign_contract_round_trips_test() {
  let original =
    SignContract(
      client: "Northwind Trading",
      valid_from: Date(2026, July, 1),
      valid_to: Date(2027, January, 1),
    )

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_start_project_round_trips_test() {
  let original =
    StartProject(
      name: "Billing Revamp",
      contract_id: 10,
      valid_from: Date(2026, July, 1),
      valid_to: Date(2027, January, 1),
    )

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_assign_to_project_round_trips_test() {
  let original =
    AssignToProject(
      engineer_id: 1,
      project_id: 200,
      fraction: 0.5,
      valid_from: Date(2026, July, 1),
      valid_to: Date(2027, January, 1),
    )

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_take_leave_round_trips_test() {
  let original =
    TakeLeave(
      engineer_id: 3,
      kind: "annual",
      valid_from: Date(2026, June, 8),
      valid_to: Date(2026, June, 22),
    )

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_log_timesheet_round_trips_test() {
  let original =
    LogTimesheet(
      engineer_id: 1,
      project_id: 100,
      day: Date(2026, June, 9),
      hours: 4.0,
    )

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_promote_round_trips_test() {
  let original =
    Promote(engineer_id: 2, level: 5, effective: Date(2026, July, 1))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_change_allocation_fraction_round_trips_test() {
  let original =
    ChangeAllocationFraction(
      engineer_id: 1,
      project_id: 100,
      fraction: 1.0,
      effective: Date(2026, July, 1),
    )

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_revise_rate_card_round_trips_test() {
  let original =
    ReviseRateCard(level: 5, day_rate: 1400.0, effective: Date(2026, July, 1))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_adjust_rate_for_portion_round_trips_test() {
  let original =
    AdjustRateForPortion(
      level: 5,
      day_rate: 1500.0,
      valid_from: Date(2026, July, 1),
      valid_to: Date(2027, January, 1),
    )

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_roll_off_round_trips_test() {
  let original =
    RollOff(engineer_id: 1, project_id: 200, effective: Date(2026, July, 1))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_terminate_employment_round_trips_test() {
  let original =
    TerminateEmployment(engineer_id: 2, effective: Date(2026, July, 1))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

// --- OperationRequest --------------------------------------------------------

// The POST /api/operations envelope: the actor plus the nested `Command`. The
// `command` field must round-trip through the same tagged encoding, so the
// envelope reconstructs the exact variant it carried.
pub fn operation_request_round_trips_test() {
  let original =
    OperationRequest(
      actor: "mike@alembic.com.au",
      command: Promote(engineer_id: 2, level: 5, effective: Date(2026, July, 1)),
    )

  assert round_trip(
      original,
      codecs.encode_operation_request,
      codecs.operation_request_decoder(),
    )
    == original
}

// --- Event ------------------------------------------------------------------

// One provenance-journal row: `payload` is the command re-encoded as a raw JSON
// string, carried verbatim through the round trip (no re-decode of the variant).
pub fn event_round_trips_test() {
  let original =
    Event(
      id: 42,
      occurred_at: "2026-06-15T09:30:00Z",
      actor: "mike@alembic.com.au",
      operation: "promote",
      summary: "Promoted engineer 2 to L5 effective 2026-07-01",
      payload: "{\"op\":\"promote\",\"engineer_id\":2,\"level\":5,\"effective\":\"2026-07-01\"}",
    )

  assert round_trip(original, codecs.encode_event, codecs.event_decoder())
    == original
}
