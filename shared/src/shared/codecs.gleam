//// Gleam/json encoders and gleam/dynamic/decode decoders
//// for the shared API types. Pure Gleam, no target-specific deps, so they compile and
//// round-trip on both ends of the JSON-over-HTTP boundary. Round-trip
//// identity (`encode |> decode == value`) is asserted by the layer-4 codec tests.

import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date, Date}
import shared/types.{
  type BoardRow, type BoardSnapshot, type Command, type Engagement, type Event,
  type Invoice, type InvoiceDetail, type InvoiceLine, type OperationRequest,
  type Payroll, type PayrollLine, type Pnl, type PnlRow, type Ref, type Roster,
  type TimesheetDay, type TimesheetLine, type WriteRequest, AdjustRateForPortion,
  AssignToProject, BoardRow, BoardSnapshot, ChangeAllocationFraction,
  DraftInvoice, Event, Invoice, InvoiceDetail, InvoiceLine, IssueInvoice,
  LogTimesheet, OnLeave, OnProject, OnboardEngineer, OperationRequest,
  PayInvoice, Payroll, PayrollLine, Pnl, PnlRow, Promote, Ref, ReviseRateCard,
  RollOff, Roster, RunPayroll, SetSalary, SignContract, StartProject, TakeLeave,
  TerminateEmployment, TimesheetDay, TimesheetLine, Unassigned, WriteRequest,
}

// --- Date -------------------------------------------------------------------
// Carried on the wire as an ISO-8601 "YYYY-MM-DD" string: unambiguous, compact,
// and exactly round-trippable. The shared types hold `calendar.Date`, whose `month`
// is the `Month` enum, so encoding maps it to its 1-12 number and decoding parses
// the number back to a `Month`.

/// Encode a `Date` as an ISO-8601 "YYYY-MM-DD" string.
pub fn encode_date(date: Date) -> Json {
  let Date(year:, month:, day:) = date
  json.string(
    pad4(year) <> "-" <> pad2(calendar.month_to_int(month)) <> "-" <> pad2(day),
  )
}

/// Decode an ISO-8601 "YYYY-MM-DD" string into a `Date`.
pub fn date_decoder() -> Decoder(Date) {
  use text <- decode.then(decode.string)
  case parse_iso_date(text) {
    Ok(date) -> decode.success(date)
    Error(Nil) -> decode.failure(Date(0, calendar.January, 1), "Date")
  }
}

fn parse_iso_date(text: String) -> Result(Date, Nil) {
  case string.split(text, "-") {
    [year, month, day] -> {
      use year <- result.try(int.parse(year))
      use month <- result.try(int.parse(month))
      use month <- result.try(calendar.month_from_int(month))
      use day <- result.try(int.parse(day))
      Ok(Date(year:, month:, day:))
    }
    _ -> Error(Nil)
  }
}

fn pad2(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 2, with: "0")
}

fn pad4(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 4, with: "0")
}

// --- Engagement -------------------------------------------------------------
// A tagged object: `status` discriminates the three situations; the remaining
// fields belong to the active variant.

/// Encode an `Engagement` as a tagged JSON object keyed by `status`.
pub fn encode_engagement(engagement: Engagement) -> Json {
  case engagement {
    OnProject(project:, client:, fraction:, day_rate:, valid_from:, valid_to:) ->
      json.object([
        #("status", json.string("on_project")),
        #("project", json.string(project)),
        #("client", json.string(client)),
        #("fraction", json.float(fraction)),
        #("day_rate", json.float(day_rate)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
    OnLeave(kind:, valid_from:, valid_to:) ->
      json.object([
        #("status", json.string("on_leave")),
        #("kind", json.string(kind)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
    Unassigned -> json.object([#("status", json.string("unassigned"))])
  }
}

/// Decode a JSON number as a `Float`, accepting an integer-valued number too.
///
/// JSON has a single number type, and JavaScript serialises a whole `Float`
/// (e.g. `4.0`) as the integer-looking `4`, whereas Erlang emits `4.0`. A strict
/// `decode.float` then rejects the JS-encoded whole number — which is exactly how
/// a Float fails to cross the JS client -> Erlang server boundary (e.g. timesheet
/// `hours` of `4`). Decoding every Float through this tolerant decoder makes the
/// contract symmetric regardless of which target encoded the value.
pub fn lenient_float_decoder() -> Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}

/// Decode an `Engagement` from its tagged JSON object.
pub fn engagement_decoder() -> Decoder(Engagement) {
  use status <- decode.field("status", decode.string)
  case status {
    "on_project" -> {
      use project <- decode.field("project", decode.string)
      use client <- decode.field("client", decode.string)
      use fraction <- decode.field("fraction", lenient_float_decoder())
      use day_rate <- decode.field("day_rate", lenient_float_decoder())
      use valid_from <- decode.field("valid_from", date_decoder())
      use valid_to <- decode.field("valid_to", date_decoder())
      decode.success(OnProject(
        project:,
        client:,
        fraction:,
        day_rate:,
        valid_from:,
        valid_to:,
      ))
    }
    "on_leave" -> {
      use kind <- decode.field("kind", decode.string)
      use valid_from <- decode.field("valid_from", date_decoder())
      use valid_to <- decode.field("valid_to", date_decoder())
      decode.success(OnLeave(kind:, valid_from:, valid_to:))
    }
    "unassigned" -> decode.success(Unassigned)
    _ -> decode.failure(Unassigned, "Engagement")
  }
}

// --- BoardRow ---------------------------------------------------------------

/// Encode a `BoardRow` as a JSON object.
pub fn encode_board_row(row: BoardRow) -> Json {
  let BoardRow(engineer:, level:, engagement:) = row
  json.object([
    #("engineer", json.string(engineer)),
    #("level", json.int(level)),
    #("engagement", encode_engagement(engagement)),
  ])
}

/// Decode a `BoardRow` from a JSON object.
pub fn board_row_decoder() -> Decoder(BoardRow) {
  use engineer <- decode.field("engineer", decode.string)
  use level <- decode.field("level", decode.int)
  use engagement <- decode.field("engagement", engagement_decoder())
  decode.success(BoardRow(engineer:, level:, engagement:))
}

// --- BoardSnapshot ----------------------------------------------------------

/// Encode a board snapshot to JSON for the HTTP API.
pub fn encode_board_snapshot(snapshot: BoardSnapshot) -> Json {
  let BoardSnapshot(date:, rows:) = snapshot
  json.object([
    #("date", encode_date(date)),
    #("rows", json.array(rows, encode_board_row)),
  ])
}

/// Decode a board snapshot from a JSON-derived dynamic value.
pub fn board_snapshot_decoder() -> Decoder(BoardSnapshot) {
  use date <- decode.field("date", date_decoder())
  use rows <- decode.field("rows", decode.list(board_row_decoder()))
  decode.success(BoardSnapshot(date:, rows:))
}

// --- TimesheetLine ----------------------------------------------------------

/// Encode a `TimesheetLine` as a JSON object.
pub fn encode_timesheet_line(line: TimesheetLine) -> Json {
  let TimesheetLine(
    project_id:,
    project:,
    fraction:,
    hours:,
    valid_from:,
    valid_to:,
  ) = line
  json.object([
    #("project_id", json.int(project_id)),
    #("project", json.string(project)),
    #("fraction", json.float(fraction)),
    #("hours", json.float(hours)),
    #("valid_from", encode_date(valid_from)),
    #("valid_to", encode_date(valid_to)),
  ])
}

/// Decode a `TimesheetLine` from a JSON object.
pub fn timesheet_line_decoder() -> Decoder(TimesheetLine) {
  use project_id <- decode.field("project_id", decode.int)
  use project <- decode.field("project", decode.string)
  use fraction <- decode.field("fraction", lenient_float_decoder())
  use hours <- decode.field("hours", lenient_float_decoder())
  use valid_from <- decode.field("valid_from", date_decoder())
  use valid_to <- decode.field("valid_to", date_decoder())
  decode.success(TimesheetLine(
    project_id:,
    project:,
    fraction:,
    hours:,
    valid_from:,
    valid_to:,
  ))
}

// --- TimesheetDay -----------------------------------------------------------

/// Encode a `TimesheetDay` (the timesheet form for one day) to JSON.
pub fn encode_timesheet_day(day: TimesheetDay) -> Json {
  let TimesheetDay(engineer_id:, date:, lines:) = day
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("date", encode_date(date)),
    #("lines", json.array(lines, encode_timesheet_line)),
  ])
}

/// Decode a `TimesheetDay` from JSON.
pub fn timesheet_day_decoder() -> Decoder(TimesheetDay) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use date <- decode.field("date", date_decoder())
  use lines <- decode.field("lines", decode.list(timesheet_line_decoder()))
  decode.success(TimesheetDay(engineer_id:, date:, lines:))
}

// --- Ref ---------------------------------------------------------------------
// A directory entry the console renders as a `<select>` option: id + name.

/// Encode a `Ref` (one directory entry) as a JSON object.
pub fn encode_ref(reference: Ref) -> Json {
  let Ref(id:, name:) = reference
  json.object([#("id", json.int(id)), #("name", json.string(name))])
}

/// Decode a `Ref` from a JSON object.
pub fn ref_decoder() -> Decoder(Ref) {
  use id <- decode.field("id", decode.int)
  use name <- decode.field("name", decode.string)
  decode.success(Ref(id:, name:))
}

// --- Roster ------------------------------------------------------------------
// The operations-console directory as-of a date: the employed engineers, the
// active projects, and every client, each a list of `Ref`.

/// Encode a `Roster` (the console directory) as a JSON object.
pub fn encode_roster(roster: Roster) -> Json {
  let Roster(engineers:, projects:, clients:) = roster
  json.object([
    #("engineers", json.array(engineers, encode_ref)),
    #("projects", json.array(projects, encode_ref)),
    #("clients", json.array(clients, encode_ref)),
  ])
}

/// Decode a `Roster` from a JSON object.
pub fn roster_decoder() -> Decoder(Roster) {
  use engineers <- decode.field("engineers", decode.list(ref_decoder()))
  use projects <- decode.field("projects", decode.list(ref_decoder()))
  use clients <- decode.field("clients", decode.list(ref_decoder()))
  decode.success(Roster(engineers:, projects:, clients:))
}

// --- Timesheet write --------------------------------------------------------
// The POST /api/timesheet request body and the typed error body the handler
// returns on rejection. Kept here so the client and server share one contract:
// the client encodes the request with `encode_write_request` and the server's
// `write_request_decoder` reads exactly these keys.

/// Encode a timesheet write request `{engineer_id, project_id, day, hours}` for
/// POST /api/timesheet, with `day` as an ISO-8601 "YYYY-MM-DD" string.
pub fn encode_write_request(
  engineer_id engineer_id: Int,
  project_id project_id: Int,
  day day: Date,
  hours hours: Float,
) -> Json {
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("project_id", json.int(project_id)),
    #("day", encode_date(day)),
    #("hours", json.float(hours)),
  ])
}

/// Decode a timesheet write request `{engineer_id, project_id, day, hours}` from
/// the POST /api/timesheet body. Pairs with `encode_write_request`: `day` is an
/// ISO-8601 "YYYY-MM-DD" string and `hours` is read leniently (a JS client may
/// serialise a whole `Float` as an integer-looking number).
pub fn write_request_decoder() -> Decoder(WriteRequest) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use project_id <- decode.field("project_id", decode.int)
  use day <- decode.field("day", date_decoder())
  use hours <- decode.field("hours", lenient_float_decoder())
  decode.success(WriteRequest(engineer_id:, project_id:, day:, hours:))
}

/// Pull the human-readable `detail` out of the handler's typed error body
/// (`{error, detail}`), e.g. the PERIOD-FK rejection reason. Returns `Error(Nil)`
/// if the body is not that shape.
pub fn decode_error_detail(body: String) -> Result(String, Nil) {
  let detail_decoder = {
    use detail <- decode.field("detail", decode.string)
    decode.success(detail)
  }
  json.parse(body, detail_decoder)
  |> result.replace_error(Nil)
}

// --- Command ----------------------------------------------------------------
// A tagged object: `op` discriminates the operation; the remaining fields belong
// to the active variant. The same encoding serves both the POST /api/operations
// request body and the `event_log` payload (§5a), so it is total and
// self-describing — every variant carries its `op` tag and all its parameters.

/// Encode a `Command` as a tagged JSON object keyed by `op`.
pub fn encode_command(command: Command) -> Json {
  case command {
    OnboardEngineer(name:, level:, effective:) ->
      json.object([
        #("op", json.string("onboard_engineer")),
        #("name", json.string(name)),
        #("level", json.int(level)),
        #("effective", encode_date(effective)),
      ])
    SignContract(client:, valid_from:, valid_to:) ->
      json.object([
        #("op", json.string("sign_contract")),
        #("client", json.string(client)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
    StartProject(name:, contract_id:, valid_from:, valid_to:) ->
      json.object([
        #("op", json.string("start_project")),
        #("name", json.string(name)),
        #("contract_id", json.int(contract_id)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
    AssignToProject(
      engineer_id:,
      project_id:,
      fraction:,
      valid_from:,
      valid_to:,
    ) ->
      json.object([
        #("op", json.string("assign_to_project")),
        #("engineer_id", json.int(engineer_id)),
        #("project_id", json.int(project_id)),
        #("fraction", json.float(fraction)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
    TakeLeave(engineer_id:, kind:, valid_from:, valid_to:) ->
      json.object([
        #("op", json.string("take_leave")),
        #("engineer_id", json.int(engineer_id)),
        #("kind", json.string(kind)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
    LogTimesheet(engineer_id:, project_id:, day:, hours:) ->
      json.object([
        #("op", json.string("log_timesheet")),
        #("engineer_id", json.int(engineer_id)),
        #("project_id", json.int(project_id)),
        #("day", encode_date(day)),
        #("hours", json.float(hours)),
      ])
    Promote(engineer_id:, level:, effective:) ->
      json.object([
        #("op", json.string("promote")),
        #("engineer_id", json.int(engineer_id)),
        #("level", json.int(level)),
        #("effective", encode_date(effective)),
      ])
    ChangeAllocationFraction(engineer_id:, project_id:, fraction:, effective:) ->
      json.object([
        #("op", json.string("change_allocation_fraction")),
        #("engineer_id", json.int(engineer_id)),
        #("project_id", json.int(project_id)),
        #("fraction", json.float(fraction)),
        #("effective", encode_date(effective)),
      ])
    ReviseRateCard(level:, day_rate:, effective:) ->
      json.object([
        #("op", json.string("revise_rate_card")),
        #("level", json.int(level)),
        #("day_rate", json.float(day_rate)),
        #("effective", encode_date(effective)),
      ])
    AdjustRateForPortion(level:, day_rate:, valid_from:, valid_to:) ->
      json.object([
        #("op", json.string("adjust_rate_for_portion")),
        #("level", json.int(level)),
        #("day_rate", json.float(day_rate)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
    RollOff(engineer_id:, project_id:, effective:) ->
      json.object([
        #("op", json.string("roll_off")),
        #("engineer_id", json.int(engineer_id)),
        #("project_id", json.int(project_id)),
        #("effective", encode_date(effective)),
      ])
    TerminateEmployment(engineer_id:, effective:) ->
      json.object([
        #("op", json.string("terminate_employment")),
        #("engineer_id", json.int(engineer_id)),
        #("effective", encode_date(effective)),
      ])
    SetSalary(level:, monthly_salary:, effective:) ->
      json.object([
        #("op", json.string("set_salary")),
        #("level", json.int(level)),
        #("monthly_salary", json.float(monthly_salary)),
        #("effective", encode_date(effective)),
      ])
    DraftInvoice(project_id:, billing_from:, billing_to:) ->
      json.object([
        #("op", json.string("draft_invoice")),
        #("project_id", json.int(project_id)),
        #("billing_from", encode_date(billing_from)),
        #("billing_to", encode_date(billing_to)),
      ])
    IssueInvoice(invoice_id:, at:) ->
      json.object([
        #("op", json.string("issue_invoice")),
        #("invoice_id", json.int(invoice_id)),
        #("at", encode_date(at)),
      ])
    PayInvoice(invoice_id:, at:) ->
      json.object([
        #("op", json.string("pay_invoice")),
        #("invoice_id", json.int(invoice_id)),
        #("at", encode_date(at)),
      ])
    RunPayroll(period_from:, period_to:) ->
      json.object([
        #("op", json.string("run_payroll")),
        #("period_from", encode_date(period_from)),
        #("period_to", encode_date(period_to)),
      ])
  }
}

/// Decode a `Command` from its tagged JSON object. Pairs with `encode_command`:
/// the `op` field selects the variant, and the remaining fields are read with the
/// matching types (`Float`s leniently, since a JS client may serialise a whole
/// `Float` as an integer-looking number).
pub fn command_decoder() -> Decoder(Command) {
  use op <- decode.field("op", decode.string)
  case op {
    "onboard_engineer" -> {
      use name <- decode.field("name", decode.string)
      use level <- decode.field("level", decode.int)
      use effective <- decode.field("effective", date_decoder())
      decode.success(OnboardEngineer(name:, level:, effective:))
    }
    "sign_contract" -> {
      use client <- decode.field("client", decode.string)
      use valid_from <- decode.field("valid_from", date_decoder())
      use valid_to <- decode.field("valid_to", date_decoder())
      decode.success(SignContract(client:, valid_from:, valid_to:))
    }
    "start_project" -> {
      use name <- decode.field("name", decode.string)
      use contract_id <- decode.field("contract_id", decode.int)
      use valid_from <- decode.field("valid_from", date_decoder())
      use valid_to <- decode.field("valid_to", date_decoder())
      decode.success(StartProject(name:, contract_id:, valid_from:, valid_to:))
    }
    "assign_to_project" -> {
      use engineer_id <- decode.field("engineer_id", decode.int)
      use project_id <- decode.field("project_id", decode.int)
      use fraction <- decode.field("fraction", lenient_float_decoder())
      use valid_from <- decode.field("valid_from", date_decoder())
      use valid_to <- decode.field("valid_to", date_decoder())
      decode.success(AssignToProject(
        engineer_id:,
        project_id:,
        fraction:,
        valid_from:,
        valid_to:,
      ))
    }
    "take_leave" -> {
      use engineer_id <- decode.field("engineer_id", decode.int)
      use kind <- decode.field("kind", decode.string)
      use valid_from <- decode.field("valid_from", date_decoder())
      use valid_to <- decode.field("valid_to", date_decoder())
      decode.success(TakeLeave(engineer_id:, kind:, valid_from:, valid_to:))
    }
    "log_timesheet" -> {
      use engineer_id <- decode.field("engineer_id", decode.int)
      use project_id <- decode.field("project_id", decode.int)
      use day <- decode.field("day", date_decoder())
      use hours <- decode.field("hours", lenient_float_decoder())
      decode.success(LogTimesheet(engineer_id:, project_id:, day:, hours:))
    }
    "promote" -> {
      use engineer_id <- decode.field("engineer_id", decode.int)
      use level <- decode.field("level", decode.int)
      use effective <- decode.field("effective", date_decoder())
      decode.success(Promote(engineer_id:, level:, effective:))
    }
    "change_allocation_fraction" -> {
      use engineer_id <- decode.field("engineer_id", decode.int)
      use project_id <- decode.field("project_id", decode.int)
      use fraction <- decode.field("fraction", lenient_float_decoder())
      use effective <- decode.field("effective", date_decoder())
      decode.success(ChangeAllocationFraction(
        engineer_id:,
        project_id:,
        fraction:,
        effective:,
      ))
    }
    "revise_rate_card" -> {
      use level <- decode.field("level", decode.int)
      use day_rate <- decode.field("day_rate", lenient_float_decoder())
      use effective <- decode.field("effective", date_decoder())
      decode.success(ReviseRateCard(level:, day_rate:, effective:))
    }
    "adjust_rate_for_portion" -> {
      use level <- decode.field("level", decode.int)
      use day_rate <- decode.field("day_rate", lenient_float_decoder())
      use valid_from <- decode.field("valid_from", date_decoder())
      use valid_to <- decode.field("valid_to", date_decoder())
      decode.success(AdjustRateForPortion(
        level:,
        day_rate:,
        valid_from:,
        valid_to:,
      ))
    }
    "roll_off" -> {
      use engineer_id <- decode.field("engineer_id", decode.int)
      use project_id <- decode.field("project_id", decode.int)
      use effective <- decode.field("effective", date_decoder())
      decode.success(RollOff(engineer_id:, project_id:, effective:))
    }
    "terminate_employment" -> {
      use engineer_id <- decode.field("engineer_id", decode.int)
      use effective <- decode.field("effective", date_decoder())
      decode.success(TerminateEmployment(engineer_id:, effective:))
    }
    "set_salary" -> {
      use level <- decode.field("level", decode.int)
      use monthly_salary <- decode.field(
        "monthly_salary",
        lenient_float_decoder(),
      )
      use effective <- decode.field("effective", date_decoder())
      decode.success(SetSalary(level:, monthly_salary:, effective:))
    }
    "draft_invoice" -> {
      use project_id <- decode.field("project_id", decode.int)
      use billing_from <- decode.field("billing_from", date_decoder())
      use billing_to <- decode.field("billing_to", date_decoder())
      decode.success(DraftInvoice(project_id:, billing_from:, billing_to:))
    }
    "issue_invoice" -> {
      use invoice_id <- decode.field("invoice_id", decode.int)
      use at <- decode.field("at", date_decoder())
      decode.success(IssueInvoice(invoice_id:, at:))
    }
    "pay_invoice" -> {
      use invoice_id <- decode.field("invoice_id", decode.int)
      use at <- decode.field("at", date_decoder())
      decode.success(PayInvoice(invoice_id:, at:))
    }
    "run_payroll" -> {
      use period_from <- decode.field("period_from", date_decoder())
      use period_to <- decode.field("period_to", date_decoder())
      decode.success(RunPayroll(period_from:, period_to:))
    }
    _ ->
      decode.failure(
        TerminateEmployment(engineer_id: 0, effective: zero_date()),
        "Command",
      )
  }
}

fn zero_date() -> Date {
  Date(0, calendar.January, 1)
}

// --- OperationRequest --------------------------------------------------------
// The POST /api/operations envelope: `{actor, command}`. The client encodes it
// and the server decodes it before dispatching. The nested `command` reuses the
// same tagged `Command` encoding (`op` + parameters) used for the event_log
// payload, so one codec serves the wire body and the journal.

/// Encode an `OperationRequest` as `{actor, command}` for POST /api/operations.
pub fn encode_operation_request(request: OperationRequest) -> Json {
  let OperationRequest(actor:, command:) = request
  json.object([
    #("actor", json.string(actor)),
    #("command", encode_command(command)),
  ])
}

/// Decode an `OperationRequest` from the POST /api/operations body. Pairs with
/// `encode_operation_request`: `command` is read through `command_decoder`.
pub fn operation_request_decoder() -> Decoder(OperationRequest) {
  use actor <- decode.field("actor", decode.string)
  use command <- decode.field("command", command_decoder())
  decode.success(OperationRequest(actor:, command:))
}

// --- Event ------------------------------------------------------------------
// One row of the provenance journal. `payload` is a raw JSON string, carried
// verbatim through `json.string` / `decode.string` so the journal view shows the
// original command encoding without re-decoding its variant.

/// Encode an `Event` (one journal row) as a JSON object.
pub fn encode_event(event: Event) -> Json {
  let Event(id:, occurred_at:, actor:, operation:, summary:, payload:) = event
  json.object([
    #("id", json.int(id)),
    #("occurred_at", json.string(occurred_at)),
    #("actor", json.string(actor)),
    #("operation", json.string(operation)),
    #("summary", json.string(summary)),
    #("payload", json.string(payload)),
  ])
}

/// Decode an `Event` from a JSON object.
pub fn event_decoder() -> Decoder(Event) {
  use id <- decode.field("id", decode.int)
  use occurred_at <- decode.field("occurred_at", decode.string)
  use actor <- decode.field("actor", decode.string)
  use operation <- decode.field("operation", decode.string)
  use summary <- decode.field("summary", decode.string)
  use payload <- decode.field("payload", decode.string)
  decode.success(Event(
    id:,
    occurred_at:,
    actor:,
    operation:,
    summary:,
    payload:,
  ))
}

// --- Invoice -----------------------------------------------------------------
// One row of the invoices-table read model: the durable subject plus its status
// as-of the selected date and its line total. Dates are ISO strings, money a
// lenient Float (a whole amount may arrive integer-looking from the JS client).

/// Encode an `Invoice` (one invoices-table row) as a JSON object.
pub fn encode_invoice(invoice: Invoice) -> Json {
  let Invoice(
    id:,
    project:,
    client:,
    billing_from:,
    billing_to:,
    status:,
    total:,
  ) = invoice
  json.object([
    #("id", json.int(id)),
    #("project", json.string(project)),
    #("client", json.string(client)),
    #("billing_from", encode_date(billing_from)),
    #("billing_to", encode_date(billing_to)),
    #("status", json.string(status)),
    #("total", json.float(total)),
  ])
}

/// Decode an `Invoice` from a JSON object.
pub fn invoice_decoder() -> Decoder(Invoice) {
  use id <- decode.field("id", decode.int)
  use project <- decode.field("project", decode.string)
  use client <- decode.field("client", decode.string)
  use billing_from <- decode.field("billing_from", date_decoder())
  use billing_to <- decode.field("billing_to", date_decoder())
  use status <- decode.field("status", decode.string)
  use total <- decode.field("total", lenient_float_decoder())
  decode.success(Invoice(
    id:,
    project:,
    client:,
    billing_from:,
    billing_to:,
    status:,
    total:,
  ))
}

// --- InvoiceLine -------------------------------------------------------------

/// Encode an `InvoiceLine` (one snapshot line) as a JSON object.
pub fn encode_invoice_line(line: InvoiceLine) -> Json {
  let InvoiceLine(engineer:, level:, day_rate:, days:, amount:) = line
  json.object([
    #("engineer", json.string(engineer)),
    #("level", json.int(level)),
    #("day_rate", json.float(day_rate)),
    #("days", json.float(days)),
    #("amount", json.float(amount)),
  ])
}

/// Decode an `InvoiceLine` from a JSON object.
pub fn invoice_line_decoder() -> Decoder(InvoiceLine) {
  use engineer <- decode.field("engineer", decode.string)
  use level <- decode.field("level", decode.int)
  use day_rate <- decode.field("day_rate", lenient_float_decoder())
  use days <- decode.field("days", lenient_float_decoder())
  use amount <- decode.field("amount", lenient_float_decoder())
  decode.success(InvoiceLine(engineer:, level:, day_rate:, days:, amount:))
}

// --- InvoiceDetail -----------------------------------------------------------

/// Encode an `InvoiceDetail` (the header plus its computed lines) to JSON.
pub fn encode_invoice_detail(detail: InvoiceDetail) -> Json {
  let InvoiceDetail(invoice:, lines:) = detail
  json.object([
    #("invoice", encode_invoice(invoice)),
    #("lines", json.array(lines, encode_invoice_line)),
  ])
}

/// Decode an `InvoiceDetail` from JSON.
pub fn invoice_detail_decoder() -> Decoder(InvoiceDetail) {
  use invoice <- decode.field("invoice", invoice_decoder())
  use lines <- decode.field("lines", decode.list(invoice_line_decoder()))
  decode.success(InvoiceDetail(invoice:, lines:))
}

// --- PayrollLine -------------------------------------------------------------

/// Encode a `PayrollLine` (one engineer's prorated payment) as a JSON object.
pub fn encode_payroll_line(line: PayrollLine) -> Json {
  let PayrollLine(engineer:, amount:, days:) = line
  json.object([
    #("engineer", json.string(engineer)),
    #("amount", json.float(amount)),
    #("days", json.float(days)),
  ])
}

/// Decode a `PayrollLine` from a JSON object.
pub fn payroll_line_decoder() -> Decoder(PayrollLine) {
  use engineer <- decode.field("engineer", decode.string)
  use amount <- decode.field("amount", lenient_float_decoder())
  use days <- decode.field("days", lenient_float_decoder())
  decode.success(PayrollLine(engineer:, amount:, days:))
}

// --- Payroll -----------------------------------------------------------------

/// Encode a `Payroll` run (the month plus its lines) to JSON.
pub fn encode_payroll(payroll: Payroll) -> Json {
  let Payroll(period_from:, period_to:, lines:) = payroll
  json.object([
    #("period_from", encode_date(period_from)),
    #("period_to", encode_date(period_to)),
    #("lines", json.array(lines, encode_payroll_line)),
  ])
}

/// Decode a `Payroll` run from JSON.
pub fn payroll_decoder() -> Decoder(Payroll) {
  use period_from <- decode.field("period_from", date_decoder())
  use period_to <- decode.field("period_to", date_decoder())
  use lines <- decode.field("lines", decode.list(payroll_line_decoder()))
  decode.success(Payroll(period_from:, period_to:, lines:))
}

// --- PnlRow ------------------------------------------------------------------

/// Encode a `PnlRow` (one per-employee P&L breakdown) as a JSON object.
pub fn encode_pnl_row(row: PnlRow) -> Json {
  let PnlRow(engineer:, revenue:, cost:, profit:, margin_pct:, utilization_pct:) =
    row
  json.object([
    #("engineer", json.string(engineer)),
    #("revenue", json.float(revenue)),
    #("cost", json.float(cost)),
    #("profit", json.float(profit)),
    #("margin_pct", json.float(margin_pct)),
    #("utilization_pct", json.float(utilization_pct)),
  ])
}

/// Decode a `PnlRow` from a JSON object.
pub fn pnl_row_decoder() -> Decoder(PnlRow) {
  use engineer <- decode.field("engineer", decode.string)
  use revenue <- decode.field("revenue", lenient_float_decoder())
  use cost <- decode.field("cost", lenient_float_decoder())
  use profit <- decode.field("profit", lenient_float_decoder())
  use margin_pct <- decode.field("margin_pct", lenient_float_decoder())
  use utilization_pct <- decode.field(
    "utilization_pct",
    lenient_float_decoder(),
  )
  decode.success(PnlRow(
    engineer:,
    revenue:,
    cost:,
    profit:,
    margin_pct:,
    utilization_pct:,
  ))
}

// --- Pnl ---------------------------------------------------------------------

/// Encode a `Pnl` statement (month/YTD totals plus per-employee rows) to JSON.
pub fn encode_pnl(pnl: Pnl) -> Json {
  let Pnl(
    month_revenue:,
    month_cost:,
    month_profit:,
    ytd_revenue:,
    ytd_cost:,
    ytd_profit:,
    rows:,
  ) = pnl
  json.object([
    #("month_revenue", json.float(month_revenue)),
    #("month_cost", json.float(month_cost)),
    #("month_profit", json.float(month_profit)),
    #("ytd_revenue", json.float(ytd_revenue)),
    #("ytd_cost", json.float(ytd_cost)),
    #("ytd_profit", json.float(ytd_profit)),
    #("rows", json.array(rows, encode_pnl_row)),
  ])
}

/// Decode a `Pnl` statement from JSON.
pub fn pnl_decoder() -> Decoder(Pnl) {
  use month_revenue <- decode.field("month_revenue", lenient_float_decoder())
  use month_cost <- decode.field("month_cost", lenient_float_decoder())
  use month_profit <- decode.field("month_profit", lenient_float_decoder())
  use ytd_revenue <- decode.field("ytd_revenue", lenient_float_decoder())
  use ytd_cost <- decode.field("ytd_cost", lenient_float_decoder())
  use ytd_profit <- decode.field("ytd_profit", lenient_float_decoder())
  use rows <- decode.field("rows", decode.list(pnl_row_decoder()))
  decode.success(Pnl(
    month_revenue:,
    month_cost:,
    month_profit:,
    ytd_revenue:,
    ytd_cost:,
    ytd_profit:,
    rows:,
  ))
}
