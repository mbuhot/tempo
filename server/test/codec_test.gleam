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
import gleam/option.{None, Some}
import gleam/result
import gleam/time/calendar.{August, Date, January, July, June, May, September}
import shared/codecs
import shared/types.{
  AdjustRateForPortion, AllocationCommand, AssignToProject, BoardRow,
  BoardSnapshot, ChangeAllocationFraction, ClientDetailsCommand, ClientProfile,
  DraftInvoice, EngagementCommand, EngineerBanking, EngineerCommand,
  EngineerContact, EngineerDetailsCommand, EngineerEmergency, Event, Forecast,
  ForecastMonth, Invoice, InvoiceCommand, InvoiceDetail, InvoiceLine,
  IssueInvoice, LeaveBalance, LeaveCommand, LogTimesheet, LogWeek, OnLeave,
  OnProject, OnboardEngineer, OperationRequest, PayInvoice, Payroll, PayrollLine,
  PayrollRunInfo, Pnl, PnlRow, ProjectRequirement, Promote, RateCardCommand, Ref,
  ReviseRateCard, RollOff, Roster, RunPayroll, SalaryCommand,
  SetProjectRequirement, SetSalary, SignContract, StartProject, TakeLeave,
  TerminateEmployment, TimesheetCell, TimesheetCommand, TimesheetEntry,
  TimesheetWeek, TimesheetWeekRow, Unassigned, UnstaffedProject,
  UpdateBankingDetails, UpdateClientProfile, UpdateContactDetails,
  UpdateEmergencyContact,
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

/// Decode an ISO date string straight through `date_decoder` (skipping any
/// encode step, so we can feed strings no encoder would ever produce).
fn decode_iso(text: String) -> Result(calendar.Date, Nil) {
  json.parse(json.to_string(json.string(text)), codecs.date_decoder())
  |> result.replace_error(Nil)
}

// February only has 28 days in 2026 (not a leap year): the 31st is rejected.
pub fn date_rejects_february_31_test() {
  assert decode_iso("2026-02-31") == Error(Nil)
}

// A day past the end of June (30 days) is rejected.
pub fn date_rejects_june_99_test() {
  assert decode_iso("2026-06-99") == Error(Nil)
}

// Day numbers below 1 are rejected.
pub fn date_rejects_day_below_one_test() {
  assert decode_iso("2026-06-00") == Error(Nil)
}

// A valid leap-day still decodes (2024 is a leap year): the guard rejects only
// the impossible dates, not the calendar-legal edge.
pub fn date_accepts_leap_day_test() {
  assert decode_iso("2024-02-29") == Ok(Date(2024, calendar.February, 29))
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
    BoardSnapshot(
      date: Date(2026, June, 15),
      rows: [
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
      ],
      balances: [
        LeaveBalance(engineer: "Marcus Chen", annual: 40.7, sick: 20.4),
        LeaveBalance(engineer: "Aisha Okafor", annual: 29.3, sick: 14.5),
      ],
      unstaffed: [
        UnstaffedProject(
          project_id: 400,
          title: "Ledger Migration",
          client: "Northwind Trading",
        ),
      ],
    )

  assert round_trip(
      original,
      codecs.encode_board_snapshot,
      codecs.board_snapshot_decoder(),
    )
    == original
}

// An empty board (no employed engineers on the date) still round-trips.
pub fn board_snapshot_empty_round_trips_test() {
  let original =
    BoardSnapshot(
      date: Date(2026, June, 15),
      rows: [],
      balances: [],
      unstaffed: [],
    )

  assert round_trip(
      original,
      codecs.encode_board_snapshot,
      codecs.board_snapshot_decoder(),
    )
    == original
}

// --- TimesheetCell ----------------------------------------------------------

// One grid cell: an allocated day carrying logged hours. The 4.0 must survive
// the JSON float round trip, and `allocated` round-trips as a JSON bool.
pub fn timesheet_cell_round_trips_test() {
  let original =
    TimesheetCell(date: Date(2026, June, 9), allocated: True, hours: 4.0)

  assert round_trip(
      original,
      codecs.encode_timesheet_cell,
      codecs.timesheet_cell_decoder(),
    )
    == original
}

// Edge case: a disabled (not-allocated) cell with zero hours — the grid renders
// it non-editable. Both False and 0.0 must survive the round trip.
pub fn timesheet_cell_disabled_round_trips_test() {
  let original =
    TimesheetCell(date: Date(2025, May, 26), allocated: False, hours: 0.0)

  assert round_trip(
      original,
      codecs.encode_timesheet_cell,
      codecs.timesheet_cell_decoder(),
    )
    == original
}

// --- TimesheetWeekRow -------------------------------------------------------

// One project's row of cells. A short two-cell row is enough to prove the nested
// cell list round-trips inside its container.
pub fn timesheet_week_row_round_trips_test() {
  let original =
    TimesheetWeekRow(project_id: 100, project: "Ledger Migration", cells: [
      TimesheetCell(date: Date(2026, June, 8), allocated: True, hours: 0.0),
      TimesheetCell(date: Date(2026, June, 9), allocated: True, hours: 4.0),
    ])

  assert round_trip(
      original,
      codecs.encode_timesheet_week_row,
      codecs.timesheet_week_row_decoder(),
    )
    == original
}

// --- TimesheetWeek ----------------------------------------------------------

// The whole weekly grid: the column dates plus the per-project rows, proving the
// `days` list and every nested row and cell survive the round trip together.
pub fn timesheet_week_round_trips_test() {
  let original =
    TimesheetWeek(
      engineer_id: 1,
      week_start: Date(2026, June, 8),
      days: [Date(2026, June, 8), Date(2026, June, 9)],
      rows: [
        TimesheetWeekRow(project_id: 100, project: "Ledger Migration", cells: [
          TimesheetCell(date: Date(2026, June, 8), allocated: True, hours: 0.0),
          TimesheetCell(date: Date(2026, June, 9), allocated: True, hours: 4.0),
        ]),
        TimesheetWeekRow(project_id: 200, project: "Inventory Sync", cells: [
          TimesheetCell(date: Date(2026, June, 8), allocated: True, hours: 0.0),
          TimesheetCell(date: Date(2026, June, 9), allocated: True, hours: 4.0),
        ]),
      ],
    )

  assert round_trip(
      original,
      codecs.encode_timesheet_week,
      codecs.timesheet_week_decoder(),
    )
    == original
}

// An empty week — the grid a leave-all-week engineer produces (no rows, no
// column dates) — round-trips to the same empty grid.
pub fn timesheet_week_empty_round_trips_test() {
  let original =
    TimesheetWeek(
      engineer_id: 3,
      week_start: Date(2026, June, 15),
      days: [],
      rows: [],
    )

  assert round_trip(
      original,
      codecs.encode_timesheet_week,
      codecs.timesheet_week_decoder(),
    )
    == original
}

// --- Ref ---------------------------------------------------------------------
// A directory entry the operations console renders as a `<select>` option:
// id (the option value) paired with name (the visible text).

pub fn ref_round_trips_test() {
  let original = Ref(id: 1, name: "Priya Sharma")

  assert round_trip(original, codecs.encode_ref, codecs.ref_decoder())
    == original
}

// --- Roster ------------------------------------------------------------------
// The operations-console directory as-of a date: the employed engineers, the
// active projects, and every client, anchored to the seed frame (003_seed.sql:
// at 2026-06-15 all three engineers are employed and all three projects active).
pub fn roster_round_trips_test() {
  let original =
    Roster(
      engineers: [
        Ref(id: 3, name: "Aisha Okafor"),
        Ref(id: 2, name: "Marcus Chen"),
        Ref(id: 1, name: "Priya Sharma"),
      ],
      projects: [
        Ref(id: 300, name: "Data Platform"),
        Ref(id: 200, name: "Inventory Sync"),
        Ref(id: 100, name: "Ledger Migration"),
      ],
      clients: [
        Ref(id: 2, name: "Globex Corporation"),
        Ref(id: 1, name: "Northwind Trading"),
      ],
    )

  assert round_trip(original, codecs.encode_roster, codecs.roster_decoder())
    == original
}

// An empty roster (a date before anyone is employed and no project active)
// round-trips to the same empty directory.
pub fn roster_empty_round_trips_test() {
  let original = Roster(engineers: [], projects: [], clients: [])

  assert round_trip(original, codecs.encode_roster, codecs.roster_decoder())
    == original
}

// --- Command ----------------------------------------------------------------
// One round-trip per operation in the write vocabulary. The same `encode_command`
// serves both the POST /api/operations body and the event_log payload, so the
// `op` tag must reconstruct the exact variant. Values are explicit and anchored
// to the seed frame (engineer/project ids, levels, rates from 003_seed.sql).

pub fn command_onboard_engineer_round_trips_test() {
  let original =
    EngineerCommand(OnboardEngineer(
      name: "Dev Patel",
      level: 3,
      effective: Date(2026, July, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_sign_contract_round_trips_test() {
  let original =
    EngagementCommand(SignContract(
      client: "Northwind Trading",
      valid_from: Date(2026, July, 1),
      valid_to: Date(2027, January, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_start_project_round_trips_test() {
  let original =
    EngagementCommand(StartProject(
      name: "Billing Revamp",
      contract_id: 10,
      valid_from: Date(2026, July, 1),
      valid_to: Date(2027, January, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_assign_to_project_round_trips_test() {
  let original =
    AllocationCommand(AssignToProject(
      engineer_id: 1,
      project_id: 200,
      fraction: 0.5,
      valid_from: Date(2026, July, 1),
      valid_to: Date(2027, January, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_take_leave_round_trips_test() {
  let original =
    LeaveCommand(TakeLeave(
      engineer_id: 3,
      kind: "annual",
      valid_from: Date(2026, June, 8),
      valid_to: Date(2026, June, 22),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_log_timesheet_round_trips_test() {
  let original =
    TimesheetCommand(LogTimesheet(
      engineer_id: 1,
      project_id: 100,
      day: Date(2026, June, 9),
      hours: 4.0,
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

// The whole-week atomic write: an engineer plus a couple of (project, day) cell
// entries. The `op` tag must reconstruct the variant and the nested entry list.
pub fn command_log_week_round_trips_test() {
  let original =
    TimesheetCommand(
      LogWeek(engineer_id: 1, entries: [
        TimesheetEntry(project_id: 100, day: Date(2026, June, 8), hours: 5.0),
        TimesheetEntry(project_id: 200, day: Date(2026, June, 9), hours: 0.0),
      ]),
    )

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_promote_round_trips_test() {
  let original =
    EngineerCommand(Promote(
      engineer_id: 2,
      level: 5,
      effective: Date(2026, July, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_change_allocation_fraction_round_trips_test() {
  let original =
    AllocationCommand(ChangeAllocationFraction(
      engineer_id: 1,
      project_id: 100,
      fraction: 1.0,
      effective: Date(2026, July, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_revise_rate_card_round_trips_test() {
  let original =
    RateCardCommand(ReviseRateCard(
      level: 5,
      day_rate: 1400.0,
      effective: Date(2026, July, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_adjust_rate_for_portion_round_trips_test() {
  let original =
    RateCardCommand(AdjustRateForPortion(
      level: 5,
      day_rate: 1500.0,
      valid_from: Date(2026, July, 1),
      valid_to: Date(2027, January, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_roll_off_round_trips_test() {
  let original =
    AllocationCommand(RollOff(
      engineer_id: 1,
      project_id: 200,
      effective: Date(2026, July, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_terminate_employment_round_trips_test() {
  let original =
    EngineerCommand(TerminateEmployment(
      engineer_id: 2,
      effective: Date(2026, July, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

// --- Engineer-detail commands ------------------------------------------------
// The three append-only edit-grouped facts (contact / banking / emergency),
// each a temporal CHANGE keyed by `effective`. The `op` tag must reconstruct the
// exact variant and every text field, including `account_no` whose leading zeros
// must survive as a String (it is text, never numeric).

pub fn command_update_contact_details_round_trips_test() {
  let original =
    EngineerDetailsCommand(UpdateContactDetails(
      engineer_id: 1,
      name: "Priya Sharma",
      email: "priya.sharma@alembic.com.au",
      phone: "+61 400 000 001",
      postal_address: "1 Demo St, Brisbane",
      effective: Date(2026, July, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_update_banking_details_round_trips_test() {
  let original =
    EngineerDetailsCommand(UpdateBankingDetails(
      engineer_id: 2,
      bank: "Big Bank",
      branch: "062",
      account_no: "00123452",
      account_name: "Marcus Chen",
      effective: Date(2026, July, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_update_emergency_contact_round_trips_test() {
  let original =
    EngineerDetailsCommand(UpdateEmergencyContact(
      engineer_id: 3,
      relation: "spouse",
      name: "Sam Okafor",
      phone: "+61 400 999 003",
      email: "sam.okafor@example.com",
      effective: Date(2026, July, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

// The client-profile edit: a temporal CHANGE keyed by `effective`, carrying the
// single text field (the client's name). The `op` tag must reconstruct the exact
// variant and field.
pub fn command_update_client_profile_round_trips_test() {
  let original =
    ClientDetailsCommand(UpdateClientProfile(
      client_id: 1,
      name: "Northwind Trading",
      effective: Date(2026, July, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

// --- Financial commands ------------------------------------------------------
// The five new write operations (PRD-financials §5), anchored to the seed frame:
// salary by level, the invoice draft/issue/pay lifecycle, and a payroll run.

pub fn command_set_salary_round_trips_test() {
  let original =
    SalaryCommand(SetSalary(
      level: 5,
      monthly_salary: 10_000.0,
      effective: Date(2026, July, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_draft_invoice_round_trips_test() {
  let original =
    InvoiceCommand(DraftInvoice(
      project_id: 200,
      billing_from: Date(2026, June, 1),
      billing_to: Date(2026, July, 1),
    ))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_issue_invoice_round_trips_test() {
  let original =
    InvoiceCommand(IssueInvoice(invoice_id: 7, at: Date(2026, June, 30)))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_pay_invoice_round_trips_test() {
  let original =
    InvoiceCommand(PayInvoice(invoice_id: 7, at: Date(2026, July, 15)))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

pub fn command_run_payroll_round_trips_test() {
  let original =
    RunPayroll(period_from: Date(2026, June, 1), period_to: Date(2026, July, 1))

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

// --- OperationRequest --------------------------------------------------------

// The POST /api/operations envelope: the nested `Command` (the actor is no longer
// on the wire — it is derived from the session, issue #6). The `command` field
// must round-trip through the same tagged encoding, so the envelope reconstructs
// the exact variant it carried.
pub fn operation_request_round_trips_test() {
  let original =
    OperationRequest(
      command: EngineerCommand(Promote(
        engineer_id: 2,
        level: 5,
        effective: Date(2026, July, 1),
      )),
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

// --- Invoice -----------------------------------------------------------------
// The invoices-table read model (PRD-financials FR-F1/FR-F4): the durable subject,
// its status as-of the selected date, and its line total.

pub fn invoice_round_trips_test() {
  let original =
    Invoice(
      id: 7,
      project: "Inventory Sync",
      client: "Northwind Trading",
      billing_from: Date(2026, June, 1),
      billing_to: Date(2026, July, 1),
      status: "issued",
      total: 26_400.0,
      issued_at: Some(Date(2026, July, 5)),
      paid_at: None,
    )

  assert round_trip(original, codecs.encode_invoice, codecs.invoice_decoder())
    == original
}

// A still-draft invoice with no lines yet computed sums to a zero total — the
// 0.0 must survive the JSON float round trip.
pub fn invoice_draft_zero_total_round_trips_test() {
  let original =
    Invoice(
      id: 8,
      project: "Ledger Migration",
      client: "Globex Corporation",
      billing_from: Date(2026, June, 1),
      billing_to: Date(2026, July, 1),
      status: "draft",
      total: 0.0,
      issued_at: None,
      paid_at: None,
    )

  assert round_trip(original, codecs.encode_invoice, codecs.invoice_decoder())
    == original
}

// --- InvoiceLine -------------------------------------------------------------

pub fn invoice_line_round_trips_test() {
  let original =
    InvoiceLine(
      engineer: "Priya Sharma",
      level: 5,
      day_rate: 1200.0,
      days: 11.0,
      amount: 13_200.0,
    )

  assert round_trip(
      original,
      codecs.encode_invoice_line,
      codecs.invoice_line_decoder(),
    )
    == original
}

// --- InvoiceDetail -----------------------------------------------------------

// The invoice-detail read model: the header plus its computed lines, proving the
// nested invoice and the line list round-trip inside their container.
pub fn invoice_detail_round_trips_test() {
  let original =
    InvoiceDetail(
      invoice: Invoice(
        id: 7,
        project: "Inventory Sync",
        client: "Northwind Trading",
        billing_from: Date(2026, June, 1),
        billing_to: Date(2026, July, 1),
        status: "issued",
        total: 26_400.0,
        issued_at: Some(Date(2026, July, 5)),
        paid_at: None,
      ),
      lines: [
        InvoiceLine(
          engineer: "Priya Sharma",
          level: 5,
          day_rate: 1200.0,
          days: 11.0,
          amount: 13_200.0,
        ),
        InvoiceLine(
          engineer: "Marcus Chen",
          level: 4,
          day_rate: 1000.0,
          days: 13.2,
          amount: 13_200.0,
        ),
      ],
    )

  assert round_trip(
      original,
      codecs.encode_invoice_detail,
      codecs.invoice_detail_decoder(),
    )
    == original
}

// An invoice with no lines (no engineer worked the project that month) still
// round-trips to the same empty detail.
pub fn invoice_detail_empty_round_trips_test() {
  let original =
    InvoiceDetail(
      invoice: Invoice(
        id: 8,
        project: "Ledger Migration",
        client: "Globex Corporation",
        billing_from: Date(2026, June, 1),
        billing_to: Date(2026, July, 1),
        status: "draft",
        total: 0.0,
        issued_at: None,
        paid_at: None,
      ),
      lines: [],
    )

  assert round_trip(
      original,
      codecs.encode_invoice_detail,
      codecs.invoice_detail_decoder(),
    )
    == original
}

// --- PayrollLine -------------------------------------------------------------

pub fn payroll_line_round_trips_test() {
  let original =
    PayrollLine(
      engineer: "Marcus Chen",
      preview_amount: 8000.0,
      preview_days: 30.0,
      paid_amount: Some(8000.0),
      paid_days: Some(30.0),
    )

  assert round_trip(
      original,
      codecs.encode_payroll_line,
      codecs.payroll_line_decoder(),
    )
    == original
}

// --- Payroll -----------------------------------------------------------------

// A payroll run for the seed month: a full-month line and a mid-month-hire line
// (prorated days), proving the month bounds and the line list round-trip together.
pub fn payroll_round_trips_test() {
  let original =
    Payroll(
      period_from: Date(2026, June, 1),
      period_to: Date(2026, July, 1),
      run: Some(PayrollRunInfo(run_id: 7)),
      lines: [
        PayrollLine(
          engineer: "Marcus Chen",
          preview_amount: 8000.0,
          preview_days: 30.0,
          paid_amount: Some(8000.0),
          paid_days: Some(30.0),
        ),
        PayrollLine(
          engineer: "Priya Sharma",
          preview_amount: 5000.0,
          preview_days: 15.0,
          paid_amount: None,
          paid_days: None,
        ),
      ],
    )

  assert round_trip(original, codecs.encode_payroll, codecs.payroll_decoder())
    == original
}

// An empty payroll run (no employed engineers in the period) round-trips.
pub fn payroll_empty_round_trips_test() {
  let original =
    Payroll(
      period_from: Date(2026, June, 1),
      period_to: Date(2026, July, 1),
      run: None,
      lines: [],
    )

  assert round_trip(original, codecs.encode_payroll, codecs.payroll_decoder())
    == original
}

// --- PnlRow ------------------------------------------------------------------

pub fn pnl_row_round_trips_test() {
  let original =
    PnlRow(
      engineer: "Priya Sharma",
      revenue: 13_200.0,
      cost: 10_000.0,
      profit: 3200.0,
      margin_pct: 24.24,
      utilization_pct: 50.0,
    )

  assert round_trip(original, codecs.encode_pnl_row, codecs.pnl_row_decoder())
    == original
}

// --- Pnl ---------------------------------------------------------------------

// The P&L statement: month and YTD totals plus per-employee rows (FR-F7/FR-F8),
// proving the totals and the nested row list round-trip together.
pub fn pnl_round_trips_test() {
  let original =
    Pnl(
      month_revenue: 26_400.0,
      month_cost: 18_000.0,
      month_profit: 8400.0,
      ytd_revenue: 158_400.0,
      ytd_cost: 108_000.0,
      ytd_profit: 50_400.0,
      rows: [
        PnlRow(
          engineer: "Priya Sharma",
          revenue: 13_200.0,
          cost: 10_000.0,
          profit: 3200.0,
          margin_pct: 24.24,
          utilization_pct: 50.0,
        ),
        PnlRow(
          engineer: "Marcus Chen",
          revenue: 13_200.0,
          cost: 8000.0,
          profit: 5200.0,
          margin_pct: 39.39,
          utilization_pct: 100.0,
        ),
      ],
    )

  assert round_trip(original, codecs.encode_pnl, codecs.pnl_decoder())
    == original
}

// A P&L with no per-employee rows (the period has no facts yet) round-trips with
// zero totals.
pub fn pnl_empty_round_trips_test() {
  let original =
    Pnl(
      month_revenue: 0.0,
      month_cost: 0.0,
      month_profit: 0.0,
      ytd_revenue: 0.0,
      ytd_cost: 0.0,
      ytd_profit: 0.0,
      rows: [],
    )

  assert round_trip(original, codecs.encode_pnl, codecs.pnl_decoder())
    == original
}

// --- EngineerContact ---------------------------------------------------------
// The latest-read contact fact (scalar projection, no period bounds exposed).

pub fn engineer_contact_round_trips_test() {
  let original =
    EngineerContact(
      engineer_id: 1,
      name: "Priya Sharma",
      email: "priya.sharma@alembic.com.au",
      phone: "+61 400 000 001",
      postal_address: "1 Demo St, Brisbane",
    )

  assert round_trip(
      original,
      codecs.encode_engineer_contact,
      codecs.engineer_contact_decoder(),
    )
    == original
}

// --- ClientProfile -----------------------------------------------------------
// The latest-read client profile fact (scalar projection, just the name; no
// period bounds exposed).

pub fn client_profile_round_trips_test() {
  let original = ClientProfile(client_id: 1, name: "Northwind Trading")

  assert round_trip(
      original,
      codecs.encode_client_profile,
      codecs.client_profile_decoder(),
    )
    == original
}

// --- EngineerBanking ---------------------------------------------------------

// `account_no` is text: its leading zeros must survive the round trip intact.
pub fn engineer_banking_round_trips_test() {
  let original =
    EngineerBanking(
      engineer_id: 2,
      bank: "Big Bank",
      branch: "062",
      account_no: "00123452",
      account_name: "Marcus Chen",
    )

  assert round_trip(
      original,
      codecs.encode_engineer_banking,
      codecs.engineer_banking_decoder(),
    )
    == original
}

// --- EngineerEmergency -------------------------------------------------------

pub fn engineer_emergency_round_trips_test() {
  let original =
    EngineerEmergency(
      engineer_id: 3,
      relation: "spouse",
      name: "Sam Okafor",
      phone: "+61 400 999 003",
      email: "sam.okafor@example.com",
    )

  assert round_trip(
      original,
      codecs.encode_engineer_emergency,
      codecs.engineer_emergency_decoder(),
    )
    == original
}

// --- SetProjectRequirement (Command) -----------------------------------------
// The demand-side write (ADR-044): a FOR-PORTION-OF set of a project's capacity
// requirement at a level over a bounded window. The `op` tag must reconstruct the
// exact variant and the fractional FTE `quantity`.

pub fn command_set_project_requirement_round_trips_test() {
  let original =
    SetProjectRequirement(
      project_id: 500,
      level: 3,
      quantity: 2.0,
      valid_from: Date(2026, August, 1),
      valid_to: Date(2027, January, 1),
    )

  assert round_trip(original, codecs.encode_command, codecs.command_decoder())
    == original
}

// --- ProjectRequirement ------------------------------------------------------
// One capacity-requirement fact on the project-detail read model. A fractional
// FTE (0.5) must survive the JSON float round trip.

pub fn project_requirement_round_trips_test() {
  let original =
    ProjectRequirement(
      project_id: 500,
      level: 5,
      quantity: 0.5,
      valid_from: Date(2026, August, 1),
      valid_to: Date(2027, January, 1),
    )

  assert round_trip(
      original,
      codecs.encode_project_requirement,
      codecs.project_requirement_decoder(),
    )
    == original
}

// --- ForecastMonth -----------------------------------------------------------
// One month of the forecast read model: the first-of-month Date plus the
// projected revenue/cost/profit/margin from committed demand.

pub fn forecast_month_round_trips_test() {
  let original =
    ForecastMonth(
      month: Date(2026, August, 1),
      revenue: 102_300.0,
      cost: 40_000.0,
      profit: 62_300.0,
      margin_pct: 60.9,
    )

  assert round_trip(
      original,
      codecs.encode_forecast_month,
      codecs.forecast_month_decoder(),
    )
    == original
}

// --- Forecast ----------------------------------------------------------------
// The forecast statement: one ForecastMonth per calendar month to the cliff,
// proving the nested month list round-trips inside its container.

pub fn forecast_round_trips_test() {
  let original =
    Forecast(months: [
      ForecastMonth(
        month: Date(2026, August, 1),
        revenue: 102_300.0,
        cost: 40_000.0,
        profit: 62_300.0,
        margin_pct: 60.9,
      ),
      ForecastMonth(
        month: Date(2026, September, 1),
        revenue: 102_300.0,
        cost: 40_000.0,
        profit: 62_300.0,
        margin_pct: 60.9,
      ),
    ])

  assert round_trip(original, codecs.encode_forecast, codecs.forecast_decoder())
    == original
}

// An empty forecast (the as-of date is past the cliff — no committed demand
// ahead) round-trips to the same empty statement.
pub fn forecast_empty_round_trips_test() {
  let original = Forecast(months: [])

  assert round_trip(original, codecs.encode_forecast, codecs.forecast_decoder())
    == original
}
