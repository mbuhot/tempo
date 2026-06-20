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
  type BoardRow, type BoardSnapshot, type ClientProfile, type Command,
  type Engagement, type EngineerBanking, type EngineerContact,
  type EngineerEmergency, type Event, type Invoice, type InvoiceDetail,
  type InvoiceLine, type LeaveBalance, type OperationRequest, type Payroll,
  type PayrollLine, type Pnl, type PnlRow, type ProjectPlan, type ProjectProfile,
  type Ref, type Roster, type TimesheetCell, type TimesheetEntry,
  type TimesheetWeek, type TimesheetWeekRow, type WriteRequest,
  AdjustRateForPortion, AssignToProject, BoardRow, BoardSnapshot,
  ChangeAllocationFraction, ClientProfile, DraftInvoice, EngineerBanking,
  EngineerContact, EngineerEmergency, Event, Invoice, InvoiceDetail, InvoiceLine,
  IssueInvoice, LeaveBalance, LogTimesheet, LogWeek, OnLeave, OnProject,
  OnboardEngineer, OperationRequest, PayInvoice, Payroll, PayrollLine, Pnl,
  PnlRow, ProjectPlan, ProjectProfile, Promote, Ref, ReviseRateCard, RollOff,
  Roster, RunPayroll, SetSalary, SignContract, StartProject, TakeLeave,
  TerminateEmployment, TimesheetCell, TimesheetEntry, TimesheetWeek,
  TimesheetWeekRow, Unassigned, UpdateBankingDetails, UpdateClientProfile,
  UpdateContactDetails, UpdateEmergencyContact, UpdateProjectPlan,
  UpdateProjectProfile, WriteRequest,
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

// --- LeaveBalance -----------------------------------------------------------

/// Encode a `LeaveBalance` as a JSON object.
pub fn encode_leave_balance(balance: LeaveBalance) -> Json {
  let LeaveBalance(engineer:, annual:, sick:) = balance
  json.object([
    #("engineer", json.string(engineer)),
    #("annual", json.float(annual)),
    #("sick", json.float(sick)),
  ])
}

/// Decode a `LeaveBalance` from a JSON object.
pub fn leave_balance_decoder() -> Decoder(LeaveBalance) {
  use engineer <- decode.field("engineer", decode.string)
  use annual <- decode.field("annual", decode.float)
  use sick <- decode.field("sick", decode.float)
  decode.success(LeaveBalance(engineer:, annual:, sick:))
}

// --- BoardSnapshot ----------------------------------------------------------

/// Encode a board snapshot to JSON for the HTTP API.
pub fn encode_board_snapshot(snapshot: BoardSnapshot) -> Json {
  let BoardSnapshot(date:, rows:, balances:) = snapshot
  json.object([
    #("date", encode_date(date)),
    #("rows", json.array(rows, encode_board_row)),
    #("balances", json.array(balances, encode_leave_balance)),
  ])
}

/// Decode a board snapshot from a JSON-derived dynamic value.
pub fn board_snapshot_decoder() -> Decoder(BoardSnapshot) {
  use date <- decode.field("date", date_decoder())
  use rows <- decode.field("rows", decode.list(board_row_decoder()))
  use balances <- decode.field("balances", decode.list(leave_balance_decoder()))
  decode.success(BoardSnapshot(date:, rows:, balances:))
}

// --- TimesheetCell ----------------------------------------------------------

/// Encode a `TimesheetCell` (one grid cell) as a JSON object.
pub fn encode_timesheet_cell(cell: TimesheetCell) -> Json {
  let TimesheetCell(date:, allocated:, hours:) = cell
  json.object([
    #("date", encode_date(date)),
    #("allocated", json.bool(allocated)),
    #("hours", json.float(hours)),
  ])
}

/// Decode a `TimesheetCell` from a JSON object. `hours` is read leniently (a JS
/// client may serialise a whole `Float` as an integer-looking number).
pub fn timesheet_cell_decoder() -> Decoder(TimesheetCell) {
  use date <- decode.field("date", date_decoder())
  use allocated <- decode.field("allocated", decode.bool)
  use hours <- decode.field("hours", lenient_float_decoder())
  decode.success(TimesheetCell(date:, allocated:, hours:))
}

// --- TimesheetWeekRow -------------------------------------------------------

/// Encode a `TimesheetWeekRow` (one project's row of cells) as a JSON object.
pub fn encode_timesheet_week_row(row: TimesheetWeekRow) -> Json {
  let TimesheetWeekRow(project_id:, project:, cells:) = row
  json.object([
    #("project_id", json.int(project_id)),
    #("project", json.string(project)),
    #("cells", json.array(cells, encode_timesheet_cell)),
  ])
}

/// Decode a `TimesheetWeekRow` from a JSON object.
pub fn timesheet_week_row_decoder() -> Decoder(TimesheetWeekRow) {
  use project_id <- decode.field("project_id", decode.int)
  use project <- decode.field("project", decode.string)
  use cells <- decode.field("cells", decode.list(timesheet_cell_decoder()))
  decode.success(TimesheetWeekRow(project_id:, project:, cells:))
}

// --- TimesheetWeek ----------------------------------------------------------

/// Encode a `TimesheetWeek` (the weekly timesheet grid) to JSON.
pub fn encode_timesheet_week(week: TimesheetWeek) -> Json {
  let TimesheetWeek(engineer_id:, week_start:, days:, rows:) = week
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("week_start", encode_date(week_start)),
    #("days", json.array(days, encode_date)),
    #("rows", json.array(rows, encode_timesheet_week_row)),
  ])
}

/// Decode a `TimesheetWeek` from JSON.
pub fn timesheet_week_decoder() -> Decoder(TimesheetWeek) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use week_start <- decode.field("week_start", date_decoder())
  use days <- decode.field("days", decode.list(date_decoder()))
  use rows <- decode.field("rows", decode.list(timesheet_week_row_decoder()))
  decode.success(TimesheetWeek(engineer_id:, week_start:, days:, rows:))
}

// --- TimesheetEntry ---------------------------------------------------------
// One (project, day) cell of a `LogWeek` submission.

/// Encode a `TimesheetEntry` (one cell of a week submission) as a JSON object.
pub fn encode_timesheet_entry(entry: TimesheetEntry) -> Json {
  let TimesheetEntry(project_id:, day:, hours:) = entry
  json.object([
    #("project_id", json.int(project_id)),
    #("day", encode_date(day)),
    #("hours", json.float(hours)),
  ])
}

/// Decode a `TimesheetEntry` from a JSON object. `hours` is read leniently (a JS
/// client may serialise a whole `Float` as an integer-looking number).
pub fn timesheet_entry_decoder() -> Decoder(TimesheetEntry) {
  use project_id <- decode.field("project_id", decode.int)
  use day <- decode.field("day", date_decoder())
  use hours <- decode.field("hours", lenient_float_decoder())
  decode.success(TimesheetEntry(project_id:, day:, hours:))
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

// --- EngineerContact ---------------------------------------------------------
// The most-recently-recorded contact fact for an engineer (the LATEST read of
// the append-only `engineer_contact` table): scalar fields only, no
// transaction-time bounds.

/// Encode an `EngineerContact` (the engineer's current contact fact) as a JSON
/// object.
pub fn encode_engineer_contact(contact: EngineerContact) -> Json {
  let EngineerContact(engineer_id:, name:, email:, phone:, postal_address:) =
    contact
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("email", json.string(email)),
    #("phone", json.string(phone)),
    #("postal_address", json.string(postal_address)),
  ])
}

/// Decode an `EngineerContact` from a JSON object.
pub fn engineer_contact_decoder() -> Decoder(EngineerContact) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  use phone <- decode.field("phone", decode.string)
  use postal_address <- decode.field("postal_address", decode.string)
  decode.success(EngineerContact(
    engineer_id:,
    name:,
    email:,
    phone:,
    postal_address:,
  ))
}

// --- EngineerBanking ---------------------------------------------------------
// The most-recently-recorded banking fact for an engineer (LATEST read of the
// append-only `engineer_banking` table). `account_no` is a String, never
// numeric — it may carry leading zeros.

/// Encode an `EngineerBanking` (the engineer's current banking fact) as a JSON
/// object.
pub fn encode_engineer_banking(banking: EngineerBanking) -> Json {
  let EngineerBanking(engineer_id:, bank:, branch:, account_no:, account_name:) =
    banking
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("bank", json.string(bank)),
    #("branch", json.string(branch)),
    #("account_no", json.string(account_no)),
    #("account_name", json.string(account_name)),
  ])
}

/// Decode an `EngineerBanking` from a JSON object.
pub fn engineer_banking_decoder() -> Decoder(EngineerBanking) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use bank <- decode.field("bank", decode.string)
  use branch <- decode.field("branch", decode.string)
  use account_no <- decode.field("account_no", decode.string)
  use account_name <- decode.field("account_name", decode.string)
  decode.success(EngineerBanking(
    engineer_id:,
    bank:,
    branch:,
    account_no:,
    account_name:,
  ))
}

// --- EngineerEmergency -------------------------------------------------------
// The most-recently-recorded emergency-contact fact for an engineer (LATEST
// read of the append-only `engineer_emergency` table).

/// Encode an `EngineerEmergency` (the engineer's current emergency contact) as
/// a JSON object.
pub fn encode_engineer_emergency(emergency: EngineerEmergency) -> Json {
  let EngineerEmergency(engineer_id:, relation:, name:, phone:, email:) =
    emergency
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("relation", json.string(relation)),
    #("name", json.string(name)),
    #("phone", json.string(phone)),
    #("email", json.string(email)),
  ])
}

/// Decode an `EngineerEmergency` from a JSON object.
pub fn engineer_emergency_decoder() -> Decoder(EngineerEmergency) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use relation <- decode.field("relation", decode.string)
  use name <- decode.field("name", decode.string)
  use phone <- decode.field("phone", decode.string)
  use email <- decode.field("email", decode.string)
  decode.success(EngineerEmergency(
    engineer_id:,
    relation:,
    name:,
    phone:,
    email:,
  ))
}

// --- ClientProfile -----------------------------------------------------------
// The most-recently-recorded profile fact for a client (the LATEST read of the
// append-only `client_profile` table): scalar fields only (just the name), no
// transaction-time bounds.

/// Encode a `ClientProfile` (the client's current profile fact) as a JSON
/// object.
pub fn encode_client_profile(profile: ClientProfile) -> Json {
  let ClientProfile(client_id:, name:) = profile
  json.object([
    #("client_id", json.int(client_id)),
    #("name", json.string(name)),
  ])
}

/// Decode a `ClientProfile` from a JSON object.
pub fn client_profile_decoder() -> Decoder(ClientProfile) {
  use client_id <- decode.field("client_id", decode.int)
  use name <- decode.field("name", decode.string)
  decode.success(ClientProfile(client_id:, name:))
}

// --- ProjectProfile ----------------------------------------------------------
// The most-recently-recorded profile fact for a project (the LATEST read of the
// append-only `project_profile` table): scalar fields only (`title`/`summary`),
// no transaction-time bounds.

/// Encode a `ProjectProfile` (the project's current profile fact) as a JSON
/// object.
pub fn encode_project_profile(profile: ProjectProfile) -> Json {
  let ProjectProfile(project_id:, title:, summary:) = profile
  json.object([
    #("project_id", json.int(project_id)),
    #("title", json.string(title)),
    #("summary", json.string(summary)),
  ])
}

/// Decode a `ProjectProfile` from a JSON object.
pub fn project_profile_decoder() -> Decoder(ProjectProfile) {
  use project_id <- decode.field("project_id", decode.int)
  use title <- decode.field("title", decode.string)
  use summary <- decode.field("summary", decode.string)
  decode.success(ProjectProfile(project_id:, title:, summary:))
}

// --- ProjectPlan -------------------------------------------------------------
// The most-recently-recorded plan fact for a project (the LATEST read of the
// append-only `project_plan` table): scalar fields only (`budget`, a money
// amount; `target_completion`, a date), no transaction-time bounds. `budget`
// decodes through the lenient decoder (the JS client may serialise a whole
// `Float` as an integer-looking number).

/// Encode a `ProjectPlan` (the project's current plan fact) as a JSON object.
pub fn encode_project_plan(plan: ProjectPlan) -> Json {
  let ProjectPlan(project_id:, budget:, target_completion:) = plan
  json.object([
    #("project_id", json.int(project_id)),
    #("budget", json.float(budget)),
    #("target_completion", encode_date(target_completion)),
  ])
}

/// Decode a `ProjectPlan` from a JSON object.
pub fn project_plan_decoder() -> Decoder(ProjectPlan) {
  use project_id <- decode.field("project_id", decode.int)
  use budget <- decode.field("budget", lenient_float_decoder())
  use target_completion <- decode.field("target_completion", date_decoder())
  decode.success(ProjectPlan(project_id:, budget:, target_completion:))
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
    UpdateContactDetails(
      engineer_id:,
      name:,
      email:,
      phone:,
      postal_address:,
      effective:,
    ) ->
      json.object([
        #("op", json.string("update_contact_details")),
        #("engineer_id", json.int(engineer_id)),
        #("name", json.string(name)),
        #("email", json.string(email)),
        #("phone", json.string(phone)),
        #("postal_address", json.string(postal_address)),
        #("effective", encode_date(effective)),
      ])
    UpdateBankingDetails(
      engineer_id:,
      bank:,
      branch:,
      account_no:,
      account_name:,
      effective:,
    ) ->
      json.object([
        #("op", json.string("update_banking_details")),
        #("engineer_id", json.int(engineer_id)),
        #("bank", json.string(bank)),
        #("branch", json.string(branch)),
        #("account_no", json.string(account_no)),
        #("account_name", json.string(account_name)),
        #("effective", encode_date(effective)),
      ])
    UpdateEmergencyContact(
      engineer_id:,
      relation:,
      name:,
      phone:,
      email:,
      effective:,
    ) ->
      json.object([
        #("op", json.string("update_emergency_contact")),
        #("engineer_id", json.int(engineer_id)),
        #("relation", json.string(relation)),
        #("name", json.string(name)),
        #("phone", json.string(phone)),
        #("email", json.string(email)),
        #("effective", encode_date(effective)),
      ])
    UpdateClientProfile(client_id:, name:, effective:) ->
      json.object([
        #("op", json.string("update_client_profile")),
        #("client_id", json.int(client_id)),
        #("name", json.string(name)),
        #("effective", encode_date(effective)),
      ])
    UpdateProjectProfile(project_id:, title:, summary:, effective:) ->
      json.object([
        #("op", json.string("update_project_profile")),
        #("project_id", json.int(project_id)),
        #("title", json.string(title)),
        #("summary", json.string(summary)),
        #("effective", encode_date(effective)),
      ])
    UpdateProjectPlan(project_id:, budget:, target_completion:, effective:) ->
      json.object([
        #("op", json.string("update_project_plan")),
        #("project_id", json.int(project_id)),
        #("budget", json.float(budget)),
        #("target_completion", encode_date(target_completion)),
        #("effective", encode_date(effective)),
      ])
    LogWeek(engineer_id:, entries:) ->
      json.object([
        #("op", json.string("log_week")),
        #("engineer_id", json.int(engineer_id)),
        #("entries", json.array(entries, encode_timesheet_entry)),
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
    "update_contact_details" -> {
      use engineer_id <- decode.field("engineer_id", decode.int)
      use name <- decode.field("name", decode.string)
      use email <- decode.field("email", decode.string)
      use phone <- decode.field("phone", decode.string)
      use postal_address <- decode.field("postal_address", decode.string)
      use effective <- decode.field("effective", date_decoder())
      decode.success(UpdateContactDetails(
        engineer_id:,
        name:,
        email:,
        phone:,
        postal_address:,
        effective:,
      ))
    }
    "update_banking_details" -> {
      use engineer_id <- decode.field("engineer_id", decode.int)
      use bank <- decode.field("bank", decode.string)
      use branch <- decode.field("branch", decode.string)
      use account_no <- decode.field("account_no", decode.string)
      use account_name <- decode.field("account_name", decode.string)
      use effective <- decode.field("effective", date_decoder())
      decode.success(UpdateBankingDetails(
        engineer_id:,
        bank:,
        branch:,
        account_no:,
        account_name:,
        effective:,
      ))
    }
    "update_emergency_contact" -> {
      use engineer_id <- decode.field("engineer_id", decode.int)
      use relation <- decode.field("relation", decode.string)
      use name <- decode.field("name", decode.string)
      use phone <- decode.field("phone", decode.string)
      use email <- decode.field("email", decode.string)
      use effective <- decode.field("effective", date_decoder())
      decode.success(UpdateEmergencyContact(
        engineer_id:,
        relation:,
        name:,
        phone:,
        email:,
        effective:,
      ))
    }
    "update_client_profile" -> {
      use client_id <- decode.field("client_id", decode.int)
      use name <- decode.field("name", decode.string)
      use effective <- decode.field("effective", date_decoder())
      decode.success(UpdateClientProfile(client_id:, name:, effective:))
    }
    "update_project_profile" -> {
      use project_id <- decode.field("project_id", decode.int)
      use title <- decode.field("title", decode.string)
      use summary <- decode.field("summary", decode.string)
      use effective <- decode.field("effective", date_decoder())
      decode.success(UpdateProjectProfile(
        project_id:,
        title:,
        summary:,
        effective:,
      ))
    }
    "update_project_plan" -> {
      use project_id <- decode.field("project_id", decode.int)
      use budget <- decode.field("budget", lenient_float_decoder())
      use target_completion <- decode.field("target_completion", date_decoder())
      use effective <- decode.field("effective", date_decoder())
      decode.success(UpdateProjectPlan(
        project_id:,
        budget:,
        target_completion:,
        effective:,
      ))
    }
    "log_week" -> {
      use engineer_id <- decode.field("engineer_id", decode.int)
      use entries <- decode.field(
        "entries",
        decode.list(timesheet_entry_decoder()),
      )
      decode.success(LogWeek(engineer_id:, entries:))
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
