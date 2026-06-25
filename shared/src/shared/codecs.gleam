//// Gleam/json encoders and gleam/dynamic/decode decoders
//// for the shared API types. Pure Gleam, no target-specific deps, so they compile and
//// round-trip on both ends of the JSON-over-HTTP boundary. Round-trip
//// identity (`encode |> decode == value`) is asserted by the layer-4 codec tests.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/result
import gleam/time/calendar.{type Date}
import shared/codecs/allocation as allocation_codec
import shared/codecs/base
import shared/codecs/client_details as client_details_codec
import shared/codecs/engagement as engagement_codec
import shared/codecs/engineer as engineer_codec
import shared/codecs/engineer_details as engineer_details_codec
import shared/codecs/invoice as invoice_codec
import shared/codecs/leave as leave_codec
import shared/codecs/payroll as payroll_codec
import shared/codecs/project_details as project_details_codec
import shared/codecs/project_requirement as project_requirement_codec
import shared/codecs/rate_card as rate_card_codec
import shared/codecs/salary as salary_codec
import shared/codecs/timesheet as timesheet_codec
import shared/types.{
  type AllocationRow, type BoardRow, type BoardSnapshot, type ClientDetail,
  type ClientList, type ClientListRow, type ClientProfile, type ClientProjectRow,
  type Command, type ContractRow, type Employment, type Engagement,
  type EngineerBanking, type EngineerContact, type EngineerDetail,
  type EngineerEmergency, type Event, type Forecast, type ForecastMonth,
  type Invoice, type InvoiceDetail, type InvoiceLine, type LeaveBalance,
  type LeavePolicyRow, type LeaveRecord, type OperationRequest, type Payroll,
  type PayrollLine, type PayrollRunInfo, type PeopleList, type PersonRow,
  type Pnl, type PnlRow, type ProjectDetail, type ProjectList,
  type ProjectListRow, type ProjectPlan, type ProjectProfile,
  type ProjectRequirement, type RateCardRow, type Ref, type RoleVersion,
  type Roster, type RosterStatus, type SalaryRow, type Settings, type TeamMember,
  type TimesheetCell, type TimesheetWeek, type TimesheetWeekRow,
  type UnstaffedProject, type WriteRequest, AllocationCommand, AllocationRow,
  BoardRow, BoardSnapshot, ClientDetail, ClientDetailsCommand, ClientList,
  ClientListRow, ClientProfile, ClientProjectRow, ContractRow, Employment,
  EngagementCommand, EngineerBanking, EngineerCommand, EngineerContact,
  EngineerDetail, EngineerDetailsCommand, EngineerEmergency, Event, Forecast,
  ForecastMonth, Invoice, InvoiceCommand, InvoiceDetail, InvoiceLine,
  LeaveBalance, LeaveCommand, LeavePolicyRow, LeaveRecord, OnLeave, OnProject,
  OperationRequest, Payroll, PayrollCommand, PayrollLine, PayrollRunInfo,
  PeopleList, PersonRow, Pnl, PnlRow, ProjectDetail, ProjectDetailsCommand,
  ProjectList, ProjectListRow, ProjectPlan, ProjectProfile, ProjectRequirement,
  ProjectRequirementCommand, RateCardCommand, RateCardRow, Ref, RoleVersion,
  Roster, RosterOnLeave, RosterOnProjects, RosterUnassigned, SalaryCommand,
  SalaryRow, Settings, TeamMember, TerminateEmployment, TimesheetCell,
  TimesheetCommand, TimesheetWeek, TimesheetWeekRow, Unassigned,
  UnstaffedProject, WriteRequest,
}
import shared/wire

// --- Date -------------------------------------------------------------------
// Carried on the wire as an ISO-8601 "YYYY-MM-DD" string: unambiguous, compact,
// and exactly round-trippable. The shared types hold `calendar.Date`, whose `month`
// is the `Month` enum, so encoding maps it to its 1-12 number and decoding parses
// the number back to a `Month`.

/// Encode a `Date` as an ISO-8601 "YYYY-MM-DD" string (re-exports `shared/wire`).
pub fn encode_date(date: Date) -> Json {
  wire.encode_date(date)
}

/// Decode an ISO-8601 "YYYY-MM-DD" string into a `Date` (re-exports `shared/wire`).
pub fn date_decoder() -> Decoder(Date) {
  wire.date_decoder()
}

/// Parse an ISO-8601 "YYYY-MM-DD" string into a `Date` (re-exports `shared/wire`).
pub fn parse_iso_date(text: String) -> Result(Date, Nil) {
  wire.parse_iso_date(text)
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
  wire.lenient_float_decoder()
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
  let BoardSnapshot(date:, rows:, balances:, unstaffed:) = snapshot
  json.object([
    #("date", encode_date(date)),
    #("rows", json.array(rows, encode_board_row)),
    #("balances", json.array(balances, encode_leave_balance)),
    #("unstaffed", json.array(unstaffed, encode_unstaffed_project)),
  ])
}

/// Decode a board snapshot from a JSON-derived dynamic value.
pub fn board_snapshot_decoder() -> Decoder(BoardSnapshot) {
  use date <- decode.field("date", date_decoder())
  use rows <- decode.field("rows", decode.list(board_row_decoder()))
  use balances <- decode.field("balances", decode.list(leave_balance_decoder()))
  use unstaffed <- decode.field(
    "unstaffed",
    decode.list(unstaffed_project_decoder()),
  )
  decode.success(BoardSnapshot(date:, rows:, balances:, unstaffed:))
}

// --- UnstaffedProject -------------------------------------------------------

/// Encode an `UnstaffedProject` (one unstaffed-lane entry) as a JSON object.
pub fn encode_unstaffed_project(project: UnstaffedProject) -> Json {
  let UnstaffedProject(project_id:, title:, client:) = project
  json.object([
    #("project_id", json.int(project_id)),
    #("title", json.string(title)),
    #("client", json.string(client)),
  ])
}

/// Decode an `UnstaffedProject` from a JSON object.
pub fn unstaffed_project_decoder() -> Decoder(UnstaffedProject) {
  use project_id <- decode.field("project_id", decode.int)
  use title <- decode.field("title", decode.string)
  use client <- decode.field("client", decode.string)
  decode.success(UnstaffedProject(project_id:, title:, client:))
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
    EngineerCommand(command) -> engineer_codec.encode(command)
    AllocationCommand(command) -> allocation_codec.encode(command)
    EngagementCommand(command) -> engagement_codec.encode(command)
    LeaveCommand(command) -> leave_codec.encode(command)
    TimesheetCommand(command) -> timesheet_codec.encode(command)
    EngineerDetailsCommand(command) -> engineer_details_codec.encode(command)
    ClientDetailsCommand(command) -> client_details_codec.encode(command)
    ProjectDetailsCommand(command) -> project_details_codec.encode(command)
    RateCardCommand(command) -> rate_card_codec.encode(command)
    SalaryCommand(command) -> salary_codec.encode(command)
    InvoiceCommand(command) -> invoice_codec.encode(command)
    PayrollCommand(command) -> payroll_codec.encode(command)
    ProjectRequirementCommand(command) ->
      project_requirement_codec.encode(command)
  }
}

/// Try each per-handler command codec in turn for `op`, wrapping its decoder into
/// the `Command` union; `Error(Nil)` when no aggregate owns the op. Every command is
/// owned by a per-aggregate codec, so this is the whole dispatch — one
/// `use <- try_group(...)` line per aggregate.
fn grouped_command_decoder(op: String) -> Result(Decoder(Command), Nil) {
  use <- try_group(engineer_codec.decoder(op), EngineerCommand)
  use <- try_group(allocation_codec.decoder(op), AllocationCommand)
  use <- try_group(engagement_codec.decoder(op), EngagementCommand)
  use <- try_group(leave_codec.decoder(op), LeaveCommand)
  use <- try_group(timesheet_codec.decoder(op), TimesheetCommand)
  use <- try_group(engineer_details_codec.decoder(op), EngineerDetailsCommand)
  use <- try_group(client_details_codec.decoder(op), ClientDetailsCommand)
  use <- try_group(project_details_codec.decoder(op), ProjectDetailsCommand)
  use <- try_group(rate_card_codec.decoder(op), RateCardCommand)
  use <- try_group(salary_codec.decoder(op), SalaryCommand)
  use <- try_group(invoice_codec.decoder(op), InvoiceCommand)
  use <- try_group(payroll_codec.decoder(op), PayrollCommand)
  use <- try_group(
    project_requirement_codec.decoder(op),
    ProjectRequirementCommand,
  )
  Error(Nil)
}

/// If `result` is a sub-codec decoder, wrap it into `Command` via `wrap`; otherwise
/// run `otherwise` (the next group, or the flat fallback).
fn try_group(
  result: Result(Decoder(a), Nil),
  wrap: fn(a) -> Command,
  otherwise: fn() -> Result(Decoder(Command), Nil),
) -> Result(Decoder(Command), Nil) {
  case result {
    Ok(decoder) -> Ok(decode.map(decoder, wrap))
    Error(Nil) -> otherwise()
  }
}

/// Decode a `Command` from its tagged JSON object. Pairs with `encode_command`:
/// the `op` field selects the variant, and the remaining fields are read with the
/// matching types (`Float`s leniently, since a JS client may serialise a whole
/// `Float` as an integer-looking number).
pub fn command_decoder() -> Decoder(Command) {
  use op <- decode.field("op", decode.string)
  case grouped_command_decoder(op) {
    Ok(decoder) -> decoder
    Error(Nil) ->
      decode.failure(
        EngineerCommand(TerminateEmployment(
          engineer_id: 0,
          effective: base.zero_date(),
        )),
        "Command",
      )
  }
}

// --- OperationRequest --------------------------------------------------------
// The POST /api/operations envelope: `{command}`. The client encodes it and the
// server decodes it before dispatching. The `actor` is NO LONGER on the wire — the
// server derives it from the authenticated session (issue #6). The nested
// `command` reuses the same tagged `Command` encoding (`op` + parameters) used for
// the event_log payload, so one codec serves the wire body and the journal.

/// Encode an `OperationRequest` as `{command}` for POST /api/operations.
pub fn encode_operation_request(request: OperationRequest) -> Json {
  let OperationRequest(command:) = request
  json.object([#("command", encode_command(command))])
}

/// Decode an `OperationRequest` from the POST /api/operations body. Pairs with
/// `encode_operation_request`: `command` is read through `command_decoder`.
pub fn operation_request_decoder() -> Decoder(OperationRequest) {
  use command <- decode.field("command", command_decoder())
  decode.success(OperationRequest(command:))
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
// `issued_at`/`paid_at` are nullable ISO dates (null until that transition).

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
    issued_at:,
    paid_at:,
  ) = invoice
  json.object([
    #("id", json.int(id)),
    #("project", json.string(project)),
    #("client", json.string(client)),
    #("billing_from", encode_date(billing_from)),
    #("billing_to", encode_date(billing_to)),
    #("status", json.string(status)),
    #("total", json.float(total)),
    #("issued_at", wire.encode_option_date(issued_at)),
    #("paid_at", wire.encode_option_date(paid_at)),
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
  use issued_at <- decode.field("issued_at", wire.option_date_decoder())
  use paid_at <- decode.field("paid_at", wire.option_date_decoder())
  decode.success(Invoice(
    id:,
    project:,
    client:,
    billing_from:,
    billing_to:,
    status:,
    total:,
    issued_at:,
    paid_at:,
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

/// Encode a `PayrollLine` (live preview plus the materialized paid values) as a
/// JSON object. `paid_amount`/`paid_days` are `null` until a run exists.
pub fn encode_payroll_line(line: PayrollLine) -> Json {
  let PayrollLine(
    engineer:,
    preview_amount:,
    preview_days:,
    paid_amount:,
    paid_days:,
  ) = line
  json.object([
    #("engineer", json.string(engineer)),
    #("preview_amount", json.float(preview_amount)),
    #("preview_days", json.float(preview_days)),
    #("paid_amount", json.nullable(paid_amount, json.float)),
    #("paid_days", json.nullable(paid_days, json.float)),
  ])
}

/// Decode a `PayrollLine` from a JSON object.
pub fn payroll_line_decoder() -> Decoder(PayrollLine) {
  use engineer <- decode.field("engineer", decode.string)
  use preview_amount <- decode.field("preview_amount", lenient_float_decoder())
  use preview_days <- decode.field("preview_days", lenient_float_decoder())
  use paid_amount <- decode.field(
    "paid_amount",
    decode.optional(lenient_float_decoder()),
  )
  use paid_days <- decode.field(
    "paid_days",
    decode.optional(lenient_float_decoder()),
  )
  decode.success(PayrollLine(
    engineer:,
    preview_amount:,
    preview_days:,
    paid_amount:,
    paid_days:,
  ))
}

// --- PayrollRunInfo ----------------------------------------------------------

/// Encode a `PayrollRunInfo` (the materialized run's id) as a JSON object.
pub fn encode_payroll_run_info(run: PayrollRunInfo) -> Json {
  let PayrollRunInfo(run_id:) = run
  json.object([#("run_id", json.int(run_id))])
}

/// Decode a `PayrollRunInfo` from a JSON object.
pub fn payroll_run_info_decoder() -> Decoder(PayrollRunInfo) {
  use run_id <- decode.field("run_id", decode.int)
  decode.success(PayrollRunInfo(run_id:))
}

// --- Payroll -----------------------------------------------------------------

/// Encode a `Payroll` month read model (period, optional run, lines) to JSON.
pub fn encode_payroll(payroll: Payroll) -> Json {
  let Payroll(period_from:, period_to:, run:, lines:) = payroll
  json.object([
    #("period_from", encode_date(period_from)),
    #("period_to", encode_date(period_to)),
    #("run", json.nullable(run, encode_payroll_run_info)),
    #("lines", json.array(lines, encode_payroll_line)),
  ])
}

/// Decode a `Payroll` month read model from JSON.
pub fn payroll_decoder() -> Decoder(Payroll) {
  use period_from <- decode.field("period_from", date_decoder())
  use period_to <- decode.field("period_to", date_decoder())
  use run <- decode.field("run", decode.optional(payroll_run_info_decoder()))
  use lines <- decode.field("lines", decode.list(payroll_line_decoder()))
  decode.success(Payroll(period_from:, period_to:, run:, lines:))
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

// --- RosterStatus ------------------------------------------------------------
// A tagged object: `status` discriminates the three situations; the remaining
// fields belong to the active variant (mirrors `Engagement`).

/// Encode a `RosterStatus` as a tagged JSON object keyed by `status`.
pub fn encode_roster_status(status: RosterStatus) -> Json {
  case status {
    RosterOnLeave(kind:) ->
      json.object([
        #("status", json.string("on_leave")),
        #("kind", json.string(kind)),
      ])
    RosterOnProjects(projects:) ->
      json.object([
        #("status", json.string("on_projects")),
        #("projects", json.array(projects, json.string)),
      ])
    RosterUnassigned -> json.object([#("status", json.string("unassigned"))])
  }
}

/// Decode a `RosterStatus` from its tagged JSON object.
pub fn roster_status_decoder() -> Decoder(RosterStatus) {
  use status <- decode.field("status", decode.string)
  case status {
    "on_leave" -> {
      use kind <- decode.field("kind", decode.string)
      decode.success(RosterOnLeave(kind:))
    }
    "on_projects" -> {
      use projects <- decode.field("projects", decode.list(decode.string))
      decode.success(RosterOnProjects(projects:))
    }
    "unassigned" -> decode.success(RosterUnassigned)
    _ -> decode.failure(RosterUnassigned, "RosterStatus")
  }
}

// --- PersonRow ---------------------------------------------------------------

/// Encode a `PersonRow` (one people-list row) as a JSON object.
pub fn encode_person_row(person: PersonRow) -> Json {
  let PersonRow(
    engineer_id:,
    name:,
    email:,
    level:,
    status:,
    allocated_fraction:,
    annual_balance:,
    day_rate:,
  ) = person
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("email", json.string(email)),
    #("level", json.int(level)),
    #("status", encode_roster_status(status)),
    #("allocated_fraction", json.float(allocated_fraction)),
    #("annual_balance", json.float(annual_balance)),
    #("day_rate", json.float(day_rate)),
  ])
}

/// Decode a `PersonRow` from a JSON object.
pub fn person_row_decoder() -> Decoder(PersonRow) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  use level <- decode.field("level", decode.int)
  use status <- decode.field("status", roster_status_decoder())
  use allocated_fraction <- decode.field(
    "allocated_fraction",
    lenient_float_decoder(),
  )
  use annual_balance <- decode.field("annual_balance", lenient_float_decoder())
  use day_rate <- decode.field("day_rate", lenient_float_decoder())
  decode.success(PersonRow(
    engineer_id:,
    name:,
    email:,
    level:,
    status:,
    allocated_fraction:,
    annual_balance:,
    day_rate:,
  ))
}

// --- PeopleList --------------------------------------------------------------

/// Encode a `PeopleList` (the people list for a date) to JSON.
pub fn encode_people_list(list: PeopleList) -> Json {
  let PeopleList(date:, people:) = list
  json.object([
    #("date", encode_date(date)),
    #("people", json.array(people, encode_person_row)),
  ])
}

/// Decode a `PeopleList` from JSON.
pub fn people_list_decoder() -> Decoder(PeopleList) {
  use date <- decode.field("date", date_decoder())
  use people <- decode.field("people", decode.list(person_row_decoder()))
  decode.success(PeopleList(date:, people:))
}

// --- Employment --------------------------------------------------------------

/// Encode an `Employment` (an engineer's as-of employment fact) as a JSON object.
pub fn encode_employment(employment: Employment) -> Json {
  let Employment(engineer_id:, started:, level:, monthly_salary:) = employment
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("started", encode_date(started)),
    #("level", json.int(level)),
    #("monthly_salary", json.float(monthly_salary)),
  ])
}

/// Decode an `Employment` from a JSON object.
pub fn employment_decoder() -> Decoder(Employment) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use started <- decode.field("started", date_decoder())
  use level <- decode.field("level", decode.int)
  use monthly_salary <- decode.field("monthly_salary", lenient_float_decoder())
  decode.success(Employment(engineer_id:, started:, level:, monthly_salary:))
}

// --- RoleVersion -------------------------------------------------------------

/// Encode a `RoleVersion` (one role-history version) as a JSON object.
pub fn encode_role_version(role: RoleVersion) -> Json {
  let RoleVersion(level:, valid_from:, valid_to:) = role
  json.object([
    #("level", json.int(level)),
    #("valid_from", encode_date(valid_from)),
    #("valid_to", encode_date(valid_to)),
  ])
}

/// Decode a `RoleVersion` from a JSON object.
pub fn role_version_decoder() -> Decoder(RoleVersion) {
  use level <- decode.field("level", decode.int)
  use valid_from <- decode.field("valid_from", date_decoder())
  use valid_to <- decode.field("valid_to", date_decoder())
  decode.success(RoleVersion(level:, valid_from:, valid_to:))
}

// --- AllocationRow -----------------------------------------------------------

/// Encode an `AllocationRow` (one allocation-history row) as a JSON object.
pub fn encode_allocation_row(allocation: AllocationRow) -> Json {
  let AllocationRow(
    project_id:,
    project:,
    fraction:,
    valid_from:,
    valid_to:,
    active:,
  ) = allocation
  json.object([
    #("project_id", json.int(project_id)),
    #("project", json.string(project)),
    #("fraction", json.float(fraction)),
    #("valid_from", encode_date(valid_from)),
    #("valid_to", encode_date(valid_to)),
    #("active", json.bool(active)),
  ])
}

/// Decode an `AllocationRow` from a JSON object.
pub fn allocation_row_decoder() -> Decoder(AllocationRow) {
  use project_id <- decode.field("project_id", decode.int)
  use project <- decode.field("project", decode.string)
  use fraction <- decode.field("fraction", lenient_float_decoder())
  use valid_from <- decode.field("valid_from", date_decoder())
  use valid_to <- decode.field("valid_to", date_decoder())
  use active <- decode.field("active", decode.bool)
  decode.success(AllocationRow(
    project_id:,
    project:,
    fraction:,
    valid_from:,
    valid_to:,
    active:,
  ))
}

// --- LeaveRecord -------------------------------------------------------------

/// Encode a `LeaveRecord` (one leave-history row) as a JSON object.
pub fn encode_leave_record(record: LeaveRecord) -> Json {
  let LeaveRecord(kind:, valid_from:, valid_to:) = record
  json.object([
    #("kind", json.string(kind)),
    #("valid_from", encode_date(valid_from)),
    #("valid_to", encode_date(valid_to)),
  ])
}

/// Decode a `LeaveRecord` from a JSON object.
pub fn leave_record_decoder() -> Decoder(LeaveRecord) {
  use kind <- decode.field("kind", decode.string)
  use valid_from <- decode.field("valid_from", date_decoder())
  use valid_to <- decode.field("valid_to", date_decoder())
  decode.success(LeaveRecord(kind:, valid_from:, valid_to:))
}

// --- EngineerDetail ----------------------------------------------------------
// A bundle codec (like `InvoiceDetail`): each field delegates to its component
// codec; the date-decomposed history lists go through the lenient list decoders.

/// Encode an `EngineerDetail` (the engineer-detail read model) to JSON.
pub fn encode_engineer_detail(detail: EngineerDetail) -> Json {
  let EngineerDetail(
    engineer_id:,
    name:,
    level:,
    contact:,
    banking:,
    emergency:,
    employment:,
    roles:,
    allocations:,
    balance:,
    leave_history:,
  ) = detail
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("level", json.int(level)),
    #("contact", encode_engineer_contact(contact)),
    #("banking", encode_engineer_banking(banking)),
    #("emergency", encode_engineer_emergency(emergency)),
    #("employment", encode_employment(employment)),
    #("roles", json.array(roles, encode_role_version)),
    #("allocations", json.array(allocations, encode_allocation_row)),
    #("balance", encode_leave_balance(balance)),
    #("leave_history", json.array(leave_history, encode_leave_record)),
  ])
}

/// Decode an `EngineerDetail` from JSON.
pub fn engineer_detail_decoder() -> Decoder(EngineerDetail) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use level <- decode.field("level", decode.int)
  use contact <- decode.field("contact", engineer_contact_decoder())
  use banking <- decode.field("banking", engineer_banking_decoder())
  use emergency <- decode.field("emergency", engineer_emergency_decoder())
  use employment <- decode.field("employment", employment_decoder())
  use roles <- decode.field("roles", decode.list(role_version_decoder()))
  use allocations <- decode.field(
    "allocations",
    decode.list(allocation_row_decoder()),
  )
  use balance <- decode.field("balance", leave_balance_decoder())
  use leave_history <- decode.field(
    "leave_history",
    decode.list(leave_record_decoder()),
  )
  decode.success(EngineerDetail(
    engineer_id:,
    name:,
    level:,
    contact:,
    banking:,
    emergency:,
    employment:,
    roles:,
    allocations:,
    balance:,
    leave_history:,
  ))
}

// --- ContractRow -------------------------------------------------------------

/// Encode a `ContractRow` (one client contract term) as a JSON object.
pub fn encode_contract_row(contract: ContractRow) -> Json {
  let ContractRow(contract_id:, valid_from:, valid_to:, active:) = contract
  json.object([
    #("contract_id", json.int(contract_id)),
    #("valid_from", encode_date(valid_from)),
    #("valid_to", encode_date(valid_to)),
    #("active", json.bool(active)),
  ])
}

/// Decode a `ContractRow` from a JSON object.
pub fn contract_row_decoder() -> Decoder(ContractRow) {
  use contract_id <- decode.field("contract_id", decode.int)
  use valid_from <- decode.field("valid_from", date_decoder())
  use valid_to <- decode.field("valid_to", date_decoder())
  use active <- decode.field("active", decode.bool)
  decode.success(ContractRow(contract_id:, valid_from:, valid_to:, active:))
}

// --- ClientProjectRow --------------------------------------------------------

/// Encode a `ClientProjectRow` (one of a client's projects) as a JSON object.
pub fn encode_client_project_row(project: ClientProjectRow) -> Json {
  let ClientProjectRow(
    project_id:,
    title:,
    budget:,
    target_completion:,
    valid_from:,
    valid_to:,
    active:,
  ) = project
  json.object([
    #("project_id", json.int(project_id)),
    #("title", json.string(title)),
    #("budget", json.float(budget)),
    #("target_completion", encode_date(target_completion)),
    #("valid_from", encode_date(valid_from)),
    #("valid_to", encode_date(valid_to)),
    #("active", json.bool(active)),
  ])
}

/// Decode a `ClientProjectRow` from a JSON object.
pub fn client_project_row_decoder() -> Decoder(ClientProjectRow) {
  use project_id <- decode.field("project_id", decode.int)
  use title <- decode.field("title", decode.string)
  use budget <- decode.field("budget", lenient_float_decoder())
  use target_completion <- decode.field("target_completion", date_decoder())
  use valid_from <- decode.field("valid_from", date_decoder())
  use valid_to <- decode.field("valid_to", date_decoder())
  use active <- decode.field("active", decode.bool)
  decode.success(ClientProjectRow(
    project_id:,
    title:,
    budget:,
    target_completion:,
    valid_from:,
    valid_to:,
    active:,
  ))
}

// --- ClientDetail ------------------------------------------------------------
// A bundle codec: `profile` delegates to the client-profile codec, `since` is a
// nullable date, and the contract/project lists go through their row codecs.

/// Encode a `ClientDetail` (the client-detail read model) to JSON.
pub fn encode_client_detail(detail: ClientDetail) -> Json {
  let ClientDetail(profile:, since:, contracts:, projects:) = detail
  json.object([
    #("profile", encode_client_profile(profile)),
    #("since", wire.encode_option_date(since)),
    #("contracts", json.array(contracts, encode_contract_row)),
    #("projects", json.array(projects, encode_client_project_row)),
  ])
}

/// Decode a `ClientDetail` from JSON.
pub fn client_detail_decoder() -> Decoder(ClientDetail) {
  use profile <- decode.field("profile", client_profile_decoder())
  use since <- decode.field("since", wire.option_date_decoder())
  use contracts <- decode.field(
    "contracts",
    decode.list(contract_row_decoder()),
  )
  use projects <- decode.field(
    "projects",
    decode.list(client_project_row_decoder()),
  )
  decode.success(ClientDetail(profile:, since:, contracts:, projects:))
}

// --- ClientListRow -----------------------------------------------------------

/// Encode a `ClientListRow` (one clients-list row) as a JSON object.
pub fn encode_client_list_row(client: ClientListRow) -> Json {
  let ClientListRow(client_id:, name:, since:, project_count:, active:) = client
  json.object([
    #("client_id", json.int(client_id)),
    #("name", json.string(name)),
    #("since", wire.encode_option_date(since)),
    #("project_count", json.int(project_count)),
    #("active", json.bool(active)),
  ])
}

/// Decode a `ClientListRow` from a JSON object.
pub fn client_list_row_decoder() -> Decoder(ClientListRow) {
  use client_id <- decode.field("client_id", decode.int)
  use name <- decode.field("name", decode.string)
  use since <- decode.field("since", wire.option_date_decoder())
  use project_count <- decode.field("project_count", decode.int)
  use active <- decode.field("active", decode.bool)
  decode.success(ClientListRow(
    client_id:,
    name:,
    since:,
    project_count:,
    active:,
  ))
}

// --- ClientList --------------------------------------------------------------

/// Encode a `ClientList` (the clients list for a date) to JSON.
pub fn encode_client_list(list: ClientList) -> Json {
  let ClientList(date:, clients:) = list
  json.object([
    #("date", encode_date(date)),
    #("clients", json.array(clients, encode_client_list_row)),
  ])
}

/// Decode a `ClientList` from JSON.
pub fn client_list_decoder() -> Decoder(ClientList) {
  use date <- decode.field("date", date_decoder())
  use clients <- decode.field("clients", decode.list(client_list_row_decoder()))
  decode.success(ClientList(date:, clients:))
}

// --- ProjectListRow ----------------------------------------------------------

/// Encode a `ProjectListRow` (one projects-list row) as a JSON object.
pub fn encode_project_list_row(project: ProjectListRow) -> Json {
  let ProjectListRow(
    project_id:,
    title:,
    client:,
    budget:,
    target_completion:,
    team_size:,
    active:,
  ) = project
  json.object([
    #("project_id", json.int(project_id)),
    #("title", json.string(title)),
    #("client", json.string(client)),
    #("budget", json.float(budget)),
    #("target_completion", encode_date(target_completion)),
    #("team_size", json.int(team_size)),
    #("active", json.bool(active)),
  ])
}

/// Decode a `ProjectListRow` from a JSON object.
pub fn project_list_row_decoder() -> Decoder(ProjectListRow) {
  use project_id <- decode.field("project_id", decode.int)
  use title <- decode.field("title", decode.string)
  use client <- decode.field("client", decode.string)
  use budget <- decode.field("budget", lenient_float_decoder())
  use target_completion <- decode.field("target_completion", date_decoder())
  use team_size <- decode.field("team_size", decode.int)
  use active <- decode.field("active", decode.bool)
  decode.success(ProjectListRow(
    project_id:,
    title:,
    client:,
    budget:,
    target_completion:,
    team_size:,
    active:,
  ))
}

// --- ProjectList -------------------------------------------------------------

/// Encode a `ProjectList` (the projects list for a date) to JSON.
pub fn encode_project_list(list: ProjectList) -> Json {
  let ProjectList(date:, projects:) = list
  json.object([
    #("date", encode_date(date)),
    #("projects", json.array(projects, encode_project_list_row)),
  ])
}

/// Decode a `ProjectList` from JSON.
pub fn project_list_decoder() -> Decoder(ProjectList) {
  use date <- decode.field("date", date_decoder())
  use projects <- decode.field(
    "projects",
    decode.list(project_list_row_decoder()),
  )
  decode.success(ProjectList(date:, projects:))
}

// --- TeamMember --------------------------------------------------------------

/// Encode a `TeamMember` (one project-team member) as a JSON object.
pub fn encode_team_member(member: TeamMember) -> Json {
  let TeamMember(engineer_id:, name:, level:, fraction:, day_rate:) = member
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("level", json.int(level)),
    #("fraction", json.float(fraction)),
    #("day_rate", json.float(day_rate)),
  ])
}

/// Decode a `TeamMember` from a JSON object.
pub fn team_member_decoder() -> Decoder(TeamMember) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use level <- decode.field("level", decode.int)
  use fraction <- decode.field("fraction", lenient_float_decoder())
  use day_rate <- decode.field("day_rate", lenient_float_decoder())
  decode.success(TeamMember(engineer_id:, name:, level:, fraction:, day_rate:))
}

// --- ProjectRequirement ------------------------------------------------------
// One capacity requirement (demand) on the project-detail read model: `quantity`
// FTE at a `level` over `[valid_from, valid_to)`. `quantity` decodes through the
// lenient decoder (a JS client may serialise a whole `Float` as an integer-looking
// number).

/// Encode a `ProjectRequirement` (one capacity-requirement line) as a JSON object.
pub fn encode_project_requirement(requirement: ProjectRequirement) -> Json {
  let ProjectRequirement(project_id:, level:, quantity:, valid_from:, valid_to:) =
    requirement
  json.object([
    #("project_id", json.int(project_id)),
    #("level", json.int(level)),
    #("quantity", json.float(quantity)),
    #("valid_from", encode_date(valid_from)),
    #("valid_to", encode_date(valid_to)),
  ])
}

/// Decode a `ProjectRequirement` from a JSON object.
pub fn project_requirement_decoder() -> Decoder(ProjectRequirement) {
  use project_id <- decode.field("project_id", decode.int)
  use level <- decode.field("level", decode.int)
  use quantity <- decode.field("quantity", lenient_float_decoder())
  use valid_from <- decode.field("valid_from", date_decoder())
  use valid_to <- decode.field("valid_to", date_decoder())
  decode.success(ProjectRequirement(
    project_id:,
    level:,
    quantity:,
    valid_from:,
    valid_to:,
  ))
}

// --- ForecastMonth -----------------------------------------------------------
// One month of the forecast: the first-of-`month` Date plus the projected
// revenue/cost/profit/margin from committed demand. The money/margin fields
// decode through the lenient decoder.

/// Encode a `ForecastMonth` (one month of the forecast) as a JSON object.
pub fn encode_forecast_month(month: ForecastMonth) -> Json {
  let ForecastMonth(month:, revenue:, cost:, profit:, margin_pct:) = month
  json.object([
    #("month", encode_date(month)),
    #("revenue", json.float(revenue)),
    #("cost", json.float(cost)),
    #("profit", json.float(profit)),
    #("margin_pct", json.float(margin_pct)),
  ])
}

/// Decode a `ForecastMonth` from a JSON object.
pub fn forecast_month_decoder() -> Decoder(ForecastMonth) {
  use month <- decode.field("month", date_decoder())
  use revenue <- decode.field("revenue", lenient_float_decoder())
  use cost <- decode.field("cost", lenient_float_decoder())
  use profit <- decode.field("profit", lenient_float_decoder())
  use margin_pct <- decode.field("margin_pct", lenient_float_decoder())
  decode.success(ForecastMonth(month:, revenue:, cost:, profit:, margin_pct:))
}

// --- Forecast ----------------------------------------------------------------

/// Encode a `Forecast` (the forecast read model) to JSON.
pub fn encode_forecast(forecast: Forecast) -> Json {
  let Forecast(months:) = forecast
  json.object([#("months", json.array(months, encode_forecast_month))])
}

/// Decode a `Forecast` from JSON.
pub fn forecast_decoder() -> Decoder(Forecast) {
  use months <- decode.field("months", decode.list(forecast_month_decoder()))
  decode.success(Forecast(months:))
}

// --- ProjectDetail -----------------------------------------------------------
// A bundle codec: `profile`/`plan` delegate to their component codecs, the run
// period decomposes to plain dates + an `active` flag, and
// `team`/`requirements`/`invoices` go through their row codecs.

/// Encode a `ProjectDetail` (the project-detail read model) to JSON.
pub fn encode_project_detail(detail: ProjectDetail) -> Json {
  let ProjectDetail(
    profile:,
    client:,
    plan:,
    valid_from:,
    valid_to:,
    active:,
    team:,
    requirements:,
    invoices:,
  ) = detail
  json.object([
    #("profile", encode_project_profile(profile)),
    #("client", json.string(client)),
    #("plan", encode_project_plan(plan)),
    #("valid_from", encode_date(valid_from)),
    #("valid_to", encode_date(valid_to)),
    #("active", json.bool(active)),
    #("team", json.array(team, encode_team_member)),
    #("requirements", json.array(requirements, encode_project_requirement)),
    #("invoices", json.array(invoices, encode_invoice)),
  ])
}

/// Decode a `ProjectDetail` from JSON.
pub fn project_detail_decoder() -> Decoder(ProjectDetail) {
  use profile <- decode.field("profile", project_profile_decoder())
  use client <- decode.field("client", decode.string)
  use plan <- decode.field("plan", project_plan_decoder())
  use valid_from <- decode.field("valid_from", date_decoder())
  use valid_to <- decode.field("valid_to", date_decoder())
  use active <- decode.field("active", decode.bool)
  use team <- decode.field("team", decode.list(team_member_decoder()))
  use requirements <- decode.field(
    "requirements",
    decode.list(project_requirement_decoder()),
  )
  use invoices <- decode.field("invoices", decode.list(invoice_decoder()))
  decode.success(ProjectDetail(
    profile:,
    client:,
    plan:,
    valid_from:,
    valid_to:,
    active:,
    team:,
    requirements:,
    invoices:,
  ))
}

// --- RateCardRow -------------------------------------------------------------

/// Encode a `RateCardRow` (one rate-card row) as a JSON object.
pub fn encode_rate_card_row(rate: RateCardRow) -> Json {
  let RateCardRow(level:, day_rate:) = rate
  json.object([
    #("level", json.int(level)),
    #("day_rate", json.float(day_rate)),
  ])
}

/// Decode a `RateCardRow` from a JSON object.
pub fn rate_card_row_decoder() -> Decoder(RateCardRow) {
  use level <- decode.field("level", decode.int)
  use day_rate <- decode.field("day_rate", lenient_float_decoder())
  decode.success(RateCardRow(level:, day_rate:))
}

// --- SalaryRow ---------------------------------------------------------------

/// Encode a `SalaryRow` (one salary-table row) as a JSON object.
pub fn encode_salary_row(salary: SalaryRow) -> Json {
  let SalaryRow(level:, monthly_salary:) = salary
  json.object([
    #("level", json.int(level)),
    #("monthly_salary", json.float(monthly_salary)),
  ])
}

/// Decode a `SalaryRow` from a JSON object.
pub fn salary_row_decoder() -> Decoder(SalaryRow) {
  use level <- decode.field("level", decode.int)
  use monthly_salary <- decode.field("monthly_salary", lenient_float_decoder())
  decode.success(SalaryRow(level:, monthly_salary:))
}

// --- LeavePolicyRow ----------------------------------------------------------

/// Encode a `LeavePolicyRow` (one leave-policy row) as a JSON object.
pub fn encode_leave_policy_row(policy: LeavePolicyRow) -> Json {
  let LeavePolicyRow(kind:, level:, days_per_year:) = policy
  json.object([
    #("kind", json.string(kind)),
    #("level", json.int(level)),
    #("days_per_year", json.float(days_per_year)),
  ])
}

/// Decode a `LeavePolicyRow` from a JSON object.
pub fn leave_policy_row_decoder() -> Decoder(LeavePolicyRow) {
  use kind <- decode.field("kind", decode.string)
  use level <- decode.field("level", decode.int)
  use days_per_year <- decode.field("days_per_year", lenient_float_decoder())
  decode.success(LeavePolicyRow(kind:, level:, days_per_year:))
}

// --- Settings ----------------------------------------------------------------
// A bundle codec: the `date` plus the three policy lists, each through its row
// codec.

/// Encode a `Settings` (the settings read model) to JSON.
pub fn encode_settings(settings: Settings) -> Json {
  let Settings(date:, rate_card:, salaries:, leave_policy:) = settings
  json.object([
    #("date", encode_date(date)),
    #("rate_card", json.array(rate_card, encode_rate_card_row)),
    #("salaries", json.array(salaries, encode_salary_row)),
    #("leave_policy", json.array(leave_policy, encode_leave_policy_row)),
  ])
}

/// Decode a `Settings` from JSON.
pub fn settings_decoder() -> Decoder(Settings) {
  use date <- decode.field("date", date_decoder())
  use rate_card <- decode.field(
    "rate_card",
    decode.list(rate_card_row_decoder()),
  )
  use salaries <- decode.field("salaries", decode.list(salary_row_decoder()))
  use leave_policy <- decode.field(
    "leave_policy",
    decode.list(leave_policy_row_decoder()),
  )
  decode.success(Settings(date:, rate_card:, salaries:, leave_policy:))
}
