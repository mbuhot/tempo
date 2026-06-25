//// The command/write model: the `Command` union over every aggregate's command
//// type, its JSON codec, and the wire envelopes that carry it. The same tagged
//// encoding (`op` + parameters) serves both the POST /api/operations request body
//// and the `event_log` payload (§5a), so it is total and self-describing. Each
//// variant wraps the command type owned by its aggregate (`shared/<concept>/command`),
//// and `command_decoder` dispatches by `op` through the per-aggregate `decoder`s.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/result
import shared/allocation/command as allocation_command
import shared/client_details/command as client_details_command
import shared/engagement/command as engagement_command
import shared/engineer/command as engineer_command
import shared/engineer_details/command as engineer_details_command
import shared/invoice/command as invoice_command
import shared/leave/command as leave_command
import shared/payroll/command as payroll_command
import shared/project_details/command as project_details_command
import shared/project_requirement/command as project_requirement_command
import shared/rate_card/command as rate_card_command
import shared/salary/command as salary_command
import shared/pagination
import shared/timesheet/command as timesheet_command
import shared/wire

/// The typed command vocabulary (the write model). One variant per business
/// aggregate, each wrapping that aggregate's command type: the client encodes a
/// `Command`, the server decodes the same value and dispatches it to the matching
/// temporal write, then re-encodes it as the `event_log` payload. Defined in
/// `shared` so both ends agree on the contract.
///
/// The aggregate command variants group into the four write patterns:
///   * Assert — `OnboardEngineer`, `SignContract`, `StartProject`,
///     `AssignToProject`, `TakeLeave`, `LogTimesheet`, `DraftInvoice`,
///     `RunPayroll`: plain inserts (the financial pair also compute their lines).
///   * Change — `Promote`, `ChangeAllocationFraction`, `ReviseRateCard`,
///     `SetSalary`, `IssueInvoice`, `PayInvoice`: "publish a new version effective
///     from a date" (`FOR PORTION OF … TO NULL`); the invoice transitions cap the
///     current status row and assert the next.
///   * Surgical — `AdjustRateForPortion`: bump a level's rate for a bounded
///     window (`FOR PORTION OF … FROM a TO b`).
///   * Close / cascade — `RollOff`, `TerminateEmployment`:
///     `DELETE … FOR PORTION OF`.
pub type Command {
  EngineerCommand(engineer_command.EngineerCommand)
  AllocationCommand(allocation_command.AllocationCommand)
  EngagementCommand(engagement_command.EngagementCommand)
  LeaveCommand(leave_command.LeaveCommand)
  TimesheetCommand(timesheet_command.TimesheetCommand)
  EngineerDetailsCommand(engineer_details_command.EngineerDetailsCommand)
  ClientDetailsCommand(client_details_command.ClientDetailsCommand)
  ProjectDetailsCommand(project_details_command.ProjectDetailsCommand)
  RateCardCommand(rate_card_command.RateCardCommand)
  SalaryCommand(salary_command.SalaryCommand)
  InvoiceCommand(invoice_command.InvoiceCommand)
  PayrollCommand(payroll_command.PayrollCommand)
  ProjectRequirementCommand(
    project_requirement_command.ProjectRequirementCommand,
  )
}

/// Encode a `Command` as a tagged JSON object keyed by `op`, delegating to the
/// per-aggregate codec for the wrapped command.
pub fn encode_command(command: Command) -> Json {
  case command {
    EngineerCommand(command) -> engineer_command.encode(command)
    AllocationCommand(command) -> allocation_command.encode(command)
    EngagementCommand(command) -> engagement_command.encode(command)
    LeaveCommand(command) -> leave_command.encode(command)
    TimesheetCommand(command) -> timesheet_command.encode(command)
    EngineerDetailsCommand(command) -> engineer_details_command.encode(command)
    ClientDetailsCommand(command) -> client_details_command.encode(command)
    ProjectDetailsCommand(command) -> project_details_command.encode(command)
    RateCardCommand(command) -> rate_card_command.encode(command)
    SalaryCommand(command) -> salary_command.encode(command)
    InvoiceCommand(command) -> invoice_command.encode(command)
    PayrollCommand(command) -> payroll_command.encode(command)
    ProjectRequirementCommand(command) ->
      project_requirement_command.encode(command)
  }
}

/// Try each per-aggregate command codec in turn for `op`, wrapping its decoder into
/// the `Command` union; `Error(Nil)` when no aggregate owns the op. Every command is
/// owned by a per-aggregate codec, so this is the whole dispatch — one
/// `use <- try_group(...)` line per aggregate.
fn grouped_command_decoder(op: String) -> Result(Decoder(Command), Nil) {
  use <- try_group(engineer_command.decoder(op), EngineerCommand)
  use <- try_group(allocation_command.decoder(op), AllocationCommand)
  use <- try_group(engagement_command.decoder(op), EngagementCommand)
  use <- try_group(leave_command.decoder(op), LeaveCommand)
  use <- try_group(timesheet_command.decoder(op), TimesheetCommand)
  use <- try_group(engineer_details_command.decoder(op), EngineerDetailsCommand)
  use <- try_group(client_details_command.decoder(op), ClientDetailsCommand)
  use <- try_group(project_details_command.decoder(op), ProjectDetailsCommand)
  use <- try_group(rate_card_command.decoder(op), RateCardCommand)
  use <- try_group(salary_command.decoder(op), SalaryCommand)
  use <- try_group(invoice_command.decoder(op), InvoiceCommand)
  use <- try_group(payroll_command.decoder(op), PayrollCommand)
  use <- try_group(
    project_requirement_command.decoder(op),
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
        EngineerCommand(engineer_command.TerminateEmployment(
          engineer_id: 0,
          effective: wire.zero_date(),
        )),
        "Command",
      )
  }
}

/// The POST /api/operations request body: just the `Command` to apply. The
/// `actor` is NO LONGER carried here — it would be forgeable (issue #6). The
/// server derives the actor from the authenticated session (a signed cookie) and
/// stamps it on the journal, so the body cannot dictate who a change is
/// attributed to. Defined in `shared` so both ends agree on the contract.
pub type OperationRequest {
  OperationRequest(command: Command)
}

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

/// One row of the provenance journal read model. The server appends an `Event`
/// per dispatched `Command` (the `operation` tag, a human `summary`, and the
/// command re-encoded as `payload`); the client renders the journal. `payload`
/// is carried as a raw JSON string so the journal view can show it verbatim
/// without re-decoding the original `Command` variant. Lives with the write model
/// because it is the command's journal provenance.
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

/// One keyset page of the provenance journal (`GET /api/events`): the page's
/// `events` (item shape unchanged) plus the opaque `next_cursor` to fetch the
/// following page (`None` on the last page). Issue #12.
pub type EventPage {
  EventPage(events: List(Event), next_cursor: Option(String))
}

/// Encode an `EventPage` (one keyset page of the journal) to JSON.
pub fn encode_event_page(page: EventPage) -> Json {
  let EventPage(events:, next_cursor:) = page
  json.object([
    #("events", json.array(events, encode_event)),
    #("next_cursor", pagination.encode_next_cursor(next_cursor)),
  ])
}

/// Decode an `EventPage` from JSON.
pub fn event_page_decoder() -> Decoder(EventPage) {
  use events <- decode.field("events", decode.list(event_decoder()))
  use next_cursor <- decode.field(
    "next_cursor",
    pagination.next_cursor_decoder(),
  )
  decode.success(EventPage(events:, next_cursor:))
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
