//// Lustre SPA for the org board and timesheet: model / update / view.
////
//// A date slider selects an instant; the board and the selected engineer's
//// timesheet are fetched for it and re-rendered for that date. The slider's
//// integer position maps to a fixed absolute calendar date (not the wall clock),
//// and that date is mirrored in the URL (?date=YYYY-MM-DD) so a shared link or a
//// reload opens on the same instant. Leave takes precedence over an allocation on
//// the board; the timesheet panel posts hours for a project and surfaces a
//// rejected write (a day not covered by an allocation) as a message, not a crash.
////
//// Imports shared/* only — the JSON contract types and codecs — never server/*.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import gleam/uri.{type Uri}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem
import rsvp
import shared/codecs
import shared/types.{
  type BoardRow, type BoardSnapshot, type Command, type Engagement, type Event,
  type TimesheetDay, type TimesheetLine, AdjustRateForPortion, AssignToProject,
  OnLeave, OnProject, OnboardEngineer, OperationRequest, Promote, ReviseRateCard,
  RollOff, TakeLeave, TerminateEmployment, Unassigned,
}

/// The fixed seed "now" the board first renders as of (003_seed.sql). The slider
/// starts here so the served page is deterministic and never depends on the wall
/// clock; scrubbing moves it across the whole seed range.
pub const seed_now = calendar.Date(year: 2026, month: calendar.June, day: 15)

/// Inclusive slider bounds, as FIXED absolute seed-range endpoints (003_seed.sql:
/// every fact lives within daterange('2024-01-01','2027-01-01')). The slider's
/// integer value is a unix-day index between these two days; the open upper bound
/// 2027-01-01 is exclusive, so the last selectable day is 2026-12-31.
const range_start = calendar.Date(year: 2024, month: calendar.January, day: 1)

const range_end = calendar.Date(year: 2026, month: calendar.December, day: 31)

/// Debounce window (ms) on slider input: coalesce a fast scrub into one fetch of
/// the final position rather than one request per intermediate pixel.
const slider_debounce_ms = 150

/// The engineers offered in the timesheet selector. Hardcoded to the deterministic
/// seed (003_seed.sql) — the same fixed ids/names the board anchors to —
/// because the API has no engineer-directory endpoint and the roster is fixed.
/// Each pair is #(engineer_id, name).
pub const engineers = [
  #(1, "Priya Sharma"),
  #(2, "Marcus Chen"),
  #(3, "Aisha Okafor"),
]

/// What the client knows about the board: still loading, the decoded snapshot, or
/// a human-readable failure to show instead of a blank page.
pub type Board {
  Loading
  Loaded(BoardSnapshot)
  Failed(String)
}

/// What the client knows about the selected engineer's timesheet for the current
/// day: still loading, the decoded form, or a human-readable failure.
pub type Timesheet {
  TimesheetLoading
  TimesheetLoaded(TimesheetDay)
  TimesheetFailed(String)
}

/// The outcome of the most recent save attempt, shown as feedback under the form.
/// `Unsaved` is the resting state before any submission for the current view.
pub type SaveState {
  Unsaved
  Saving
  Saved
  SaveRejected(String)
}

/// The actor stamped on every operation the console submits. The console has no
/// auth, so the actor is a fixed nominal label that lands in the event log's
/// `actor` column (PRD FR-11).
const console_actor = "console"

/// Which command the operations console is composing. One variant per
/// demo-relevant `Command` (PRD §6, FR-9); the selected kind decides which fields
/// the form shows and which `Command` `build_command` assembles on submit.
pub type ConsoleKind {
  KindOnboardEngineer
  KindPromote
  KindAssignToProject
  KindRollOff
  KindReviseRateCard
  KindAdjustRateForPortion
  KindTakeLeave
  KindTerminateEmployment
}

/// The raw text typed into the console's input fields, shared across command
/// kinds (each kind reads only the fields it needs). Kept as strings so a
/// partially-typed or invalid number simply fails `build_command` with a prompt,
/// rather than forcing the model to hold half-parsed values.
pub type ConsoleForm {
  ConsoleForm(
    name: String,
    engineer_id: String,
    project_id: String,
    level: String,
    fraction: String,
    day_rate: String,
    kind: String,
    effective: String,
    valid_from: String,
    valid_to: String,
  )
}

/// The outcome of the most recent console operation, shown as feedback beneath
/// the console. `OperationIdle` is the resting state before any submission;
/// `OperationFailed` carries the server's `{error, detail}` rendered for the user.
pub type OperationState {
  OperationIdle
  OperationSubmitting
  OperationSucceeded(operation: String, summary: String)
  OperationFailed(String)
}

/// What the client knows about the provenance journal: still loading, the decoded
/// events (newest-first), or a human-readable failure.
pub type EventLog {
  EventLogLoading
  EventLogLoaded(List(Event))
  EventLogFailed(String)
}

/// Lustre model: the day index the slider sits at, the instant it denotes, the
/// board rendered as of it, plus the timesheet panel — which engineer is selected,
/// their form for that day, the hours currently typed into each project's input
/// (keyed by project id), and the last save outcome.
pub type Model {
  Model(
    day_index: Int,
    date: calendar.Date,
    board: Board,
    engineer_id: Int,
    timesheet: Timesheet,
    hours_input: Dict(Int, String),
    save_state: SaveState,
    console_kind: ConsoleKind,
    console_form: ConsoleForm,
    operation_state: OperationState,
    event_log: EventLog,
  )
}

/// Messages the runtime feeds back to `update`.
pub type Message {
  /// The slider moved to a new day index (debounced `on_input`).
  SliderMoved(day_index: Int)
  /// A board fetch resolved; `date` tags which request it answers so a stale
  /// response from an earlier slider position can be discarded.
  ApiReturnedBoard(
    date: calendar.Date,
    result: Result(BoardSnapshot, rsvp.Error(String)),
  )
  /// The timesheet engineer selector changed to a new engineer id.
  EngineerSelected(engineer_id: Int)
  /// A timesheet form fetch resolved; `engineer_id` and `date` tag which request
  /// it answers so a response overtaken by a later scrub/selection is discarded.
  ApiReturnedTimesheet(
    engineer_id: Int,
    date: calendar.Date,
    result: Result(TimesheetDay, rsvp.Error(String)),
  )
  /// The user edited the hours input for one project.
  HoursEdited(project_id: Int, raw_hours: String)
  /// The user submitted hours for one project (the row's Save button).
  SubmittedHours(project_id: Int)
  /// A timesheet write resolved; `engineer_id`/`date` tag it for the same
  /// staleness check, and the body is either the refreshed form or the error.
  ApiSavedTimesheet(
    engineer_id: Int,
    date: calendar.Date,
    result: Result(TimesheetDay, rsvp.Error(String)),
  )
  /// The operations console switched to composing a different command.
  ConsoleKindSelected(console_kind: ConsoleKind)
  /// A console form field was edited; `update_form` writes the raw text into the
  /// named slot of the shared `ConsoleForm`.
  ConsoleFieldEdited(field: ConsoleField, value: String)
  /// The console's Apply button was pressed: build the `Command` and POST it.
  ConsoleSubmitted
  /// A console operation resolved; `Ok` carries the created `Event`, `Error` the
  /// typed `{error, detail}` body the server returned for the rejection.
  ApiAppliedOperation(result: Result(Event, rsvp.Error(String)))
  /// An event-log fetch resolved with the journal (newest-first) or an error.
  ApiReturnedEvents(result: Result(List(Event), rsvp.Error(String)))
}

/// Names the `ConsoleForm` slot a `ConsoleFieldEdited` message targets, so one
/// message handles every text input without a message variant per field.
pub type ConsoleField {
  FieldName
  FieldEngineerId
  FieldProjectId
  FieldLevel
  FieldFraction
  FieldDayRate
  FieldKind
  FieldEffective
  FieldValidFrom
  FieldValidTo
}

/// Client entrypoint: start the Lustre application mounted on `#app`.
pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

/// Initial state: the slider at the seed "now", the first engineer selected, board
/// and timesheet loading, with both fetches in flight as the initial effect.
fn init(_arguments: Nil) -> #(Model, Effect(Message)) {
  let engineer_id = first_engineer_id()
  // Open at the date in the URL (?date=YYYY-MM-DD) so a shared link or a reload
  // lands on that instant; absent or out of range, fall back to the seed "now".
  // The initial effect writes the resolved date back to the URL so it is explicit.
  let date = initial_date()
  let model =
    Model(
      day_index: date_to_day_index(date),
      date:,
      board: Loading,
      engineer_id:,
      timesheet: TimesheetLoading,
      hours_input: dict.new(),
      save_state: Unsaved,
      console_kind: KindPromote,
      console_form: blank_console_form(date),
      operation_state: OperationIdle,
      event_log: EventLogLoading,
    )
  #(
    model,
    effect.batch([
      fetch_board(date),
      fetch_timesheet(engineer_id, date),
      fetch_events(),
      sync_url(date),
    ]),
  )
}

/// A fresh console form: text fields empty, every date field defaulting to
/// `date` (the slider's current day) so an operation lands on the visible instant
/// unless the presenter types another date.
fn blank_console_form(date: calendar.Date) -> ConsoleForm {
  let today = iso_date(date)
  ConsoleForm(
    name: "",
    engineer_id: "",
    project_id: "",
    level: "",
    fraction: "",
    day_rate: "",
    kind: "",
    effective: today,
    valid_from: today,
    valid_to: today,
  )
}

/// Fold a message into the model.
///
/// `SliderMoved` converts the new position to an absolute date and refetches both
/// the board and the timesheet for it. `EngineerSelected` refetches the timesheet
/// for the newly chosen engineer. The `ApiReturned*` messages store their result
/// only when it still answers the current view, dropping stale responses.
/// `HoursEdited` updates the typed value; `SubmittedHours` posts it.
fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    SliderMoved(day_index:) -> {
      let date = day_index_to_date(day_index)
      // Stale-while-revalidate: keep the current board/timesheet on screen while the
      // new date's data is in flight, instead of dropping to a loading state on every
      // scrub (which flickers — blank "Loading…" then a snap back to data). The
      // staleness guard in the ApiReturned* handlers discards any response overtaken
      // by a later move, so the view only ever updates to the latest date's data.
      #(
        Model(..model, day_index:, date:, save_state: Unsaved),
        effect.batch([
          fetch_board(date),
          fetch_timesheet(model.engineer_id, date),
          sync_url(date),
        ]),
      )
    }

    ApiReturnedBoard(date:, result:) ->
      case date == model.date {
        False -> #(model, effect.none())
        True ->
          case result {
            Ok(snapshot) -> #(
              Model(..model, board: Loaded(snapshot)),
              effect.none(),
            )
            Error(error) -> #(
              Model(..model, board: Failed(describe_board_error(error))),
              effect.none(),
            )
          }
      }

    EngineerSelected(engineer_id:) -> #(
      Model(
        ..model,
        engineer_id:,
        timesheet: TimesheetLoading,
        save_state: Unsaved,
      ),
      fetch_timesheet(engineer_id, model.date),
    )

    ApiReturnedTimesheet(engineer_id:, date:, result:) ->
      case engineer_id == model.engineer_id && date == model.date {
        False -> #(model, effect.none())
        True -> #(store_timesheet(model, result), effect.none())
      }

    HoursEdited(project_id:, raw_hours:) -> #(
      Model(
        ..model,
        hours_input: dict.insert(model.hours_input, project_id, raw_hours),
      ),
      effect.none(),
    )

    SubmittedHours(project_id:) ->
      case hours_for(model, project_id) {
        Error(Nil) -> #(
          Model(
            ..model,
            save_state: SaveRejected("Enter a number of hours before saving."),
          ),
          effect.none(),
        )
        Ok(hours) -> #(
          Model(..model, save_state: Saving),
          save_hours(model.engineer_id, model.date, project_id, hours),
        )
      }

    ApiSavedTimesheet(engineer_id:, date:, result:) ->
      case engineer_id == model.engineer_id && date == model.date {
        False -> #(model, effect.none())
        True ->
          case result {
            Ok(day) -> #(
              Model(..store_timesheet(model, Ok(day)), save_state: Saved),
              effect.none(),
            )
            Error(error) -> #(
              Model(
                ..model,
                save_state: SaveRejected(describe_save_error(error)),
              ),
              effect.none(),
            )
          }
      }

    ConsoleKindSelected(console_kind:) -> #(
      Model(..model, console_kind:, operation_state: OperationIdle),
      effect.none(),
    )

    ConsoleFieldEdited(field:, value:) -> #(
      Model(
        ..model,
        console_form: update_form(model.console_form, field, value),
      ),
      effect.none(),
    )

    ConsoleSubmitted ->
      case build_command(model.console_kind, model.console_form) {
        Error(prompt) -> #(
          Model(..model, operation_state: OperationFailed(prompt)),
          effect.none(),
        )
        Ok(command) -> #(
          Model(..model, operation_state: OperationSubmitting),
          submit_operation(command),
        )
      }

    ApiAppliedOperation(result:) ->
      case result {
        // The operation committed: stamp success feedback, then refetch the board
        // for the current slider date and the event log so both reflect the write.
        Ok(event) -> #(
          Model(
            ..model,
            operation_state: OperationSucceeded(
              operation: event.operation,
              summary: event.summary,
            ),
          ),
          effect.batch([fetch_board(model.date), fetch_events()]),
        )
        Error(error) -> #(
          Model(
            ..model,
            operation_state: OperationFailed(describe_operation_error(error)),
          ),
          effect.none(),
        )
      }

    ApiReturnedEvents(result:) ->
      case result {
        Ok(events) -> #(
          Model(..model, event_log: EventLogLoaded(events)),
          effect.none(),
        )
        Error(error) -> #(
          Model(..model, event_log: EventLogFailed(describe_board_error(error))),
          effect.none(),
        )
      }
  }
}

/// Write `value` into the `ConsoleForm` slot named by `field`. One place maps a
/// `ConsoleField` to its record update, so the view binds inputs by field name.
fn update_form(
  form: ConsoleForm,
  field: ConsoleField,
  value: String,
) -> ConsoleForm {
  case field {
    FieldName -> ConsoleForm(..form, name: value)
    FieldEngineerId -> ConsoleForm(..form, engineer_id: value)
    FieldProjectId -> ConsoleForm(..form, project_id: value)
    FieldLevel -> ConsoleForm(..form, level: value)
    FieldFraction -> ConsoleForm(..form, fraction: value)
    FieldDayRate -> ConsoleForm(..form, day_rate: value)
    FieldKind -> ConsoleForm(..form, kind: value)
    FieldEffective -> ConsoleForm(..form, effective: value)
    FieldValidFrom -> ConsoleForm(..form, valid_from: value)
    FieldValidTo -> ConsoleForm(..form, valid_to: value)
  }
}

// --- Console command assembly -----------------------------------------------
// Turn the selected kind + the raw form strings into a typed `Command`, or a
// human prompt naming the first field that didn't parse. Each field is read
// through `require_*`, which carries the field's label into the prompt so the
// presenter sees exactly what to fix.

/// Build the `Command` for the selected console kind from the form's text fields,
/// reading only the fields that kind needs. Returns `Error(prompt)` naming the
/// first missing or invalid field so the console can show why it could not apply.
fn build_command(
  console_kind: ConsoleKind,
  form: ConsoleForm,
) -> Result(Command, String) {
  case console_kind {
    KindOnboardEngineer -> {
      use name <- result.try(require_text(form.name, "name"))
      use level <- result.try(require_int(form.level, "level"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(OnboardEngineer(name:, level:, effective:))
    }
    KindPromote -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use level <- result.try(require_int(form.level, "level"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(Promote(engineer_id:, level:, effective:))
    }
    KindAssignToProject -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use fraction <- result.try(require_float(form.fraction, "fraction"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(AssignToProject(
        engineer_id:,
        project_id:,
        fraction:,
        valid_from:,
        valid_to:,
      ))
    }
    KindRollOff -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use project_id <- result.try(require_int(form.project_id, "project id"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(RollOff(engineer_id:, project_id:, effective:))
    }
    KindReviseRateCard -> {
      use level <- result.try(require_int(form.level, "level"))
      use day_rate <- result.try(require_float(form.day_rate, "day rate"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(ReviseRateCard(level:, day_rate:, effective:))
    }
    KindAdjustRateForPortion -> {
      use level <- result.try(require_int(form.level, "level"))
      use day_rate <- result.try(require_float(form.day_rate, "day rate"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(AdjustRateForPortion(level:, day_rate:, valid_from:, valid_to:))
    }
    KindTakeLeave -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use kind <- result.try(require_text(form.kind, "leave kind"))
      use valid_from <- result.try(require_date(form.valid_from, "valid from"))
      use valid_to <- result.try(require_date(form.valid_to, "valid to"))
      Ok(TakeLeave(engineer_id:, kind:, valid_from:, valid_to:))
    }
    KindTerminateEmployment -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use effective <- result.try(require_date(form.effective, "effective"))
      Ok(TerminateEmployment(engineer_id:, effective:))
    }
  }
}

/// A non-empty text field, or a prompt to fill it in.
fn require_text(raw: String, label: String) -> Result(String, String) {
  case string.trim(raw) {
    "" -> Error("Enter a " <> label <> ".")
    text -> Ok(text)
  }
}

/// Parse an integer field, or a prompt naming it.
fn require_int(raw: String, label: String) -> Result(Int, String) {
  case int.parse(string.trim(raw)) {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error("Enter a whole number for " <> label <> ".")
  }
}

/// Parse a numeric (int-or-decimal) field, or a prompt naming it.
fn require_float(raw: String, label: String) -> Result(Float, String) {
  case parse_hours(string.trim(raw)) {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error("Enter a number for " <> label <> ".")
  }
}

/// Parse an ISO-8601 date field, or a prompt naming it.
fn require_date(raw: String, label: String) -> Result(calendar.Date, String) {
  case parse_iso_date(string.trim(raw)) {
    Ok(date) -> Ok(date)
    Error(Nil) -> Error("Enter " <> label <> " as YYYY-MM-DD.")
  }
}

/// Store a fetched/refreshed timesheet form into the model, seeding the editable
/// hours inputs from the server's saved values so the form shows what is on
/// record. A failure becomes a human-readable `TimesheetFailed`.
fn store_timesheet(
  model: Model,
  result: Result(TimesheetDay, rsvp.Error(String)),
) -> Model {
  case result {
    Ok(day) ->
      Model(
        ..model,
        timesheet: TimesheetLoaded(day),
        hours_input: hours_input_from_day(day),
      )
    Error(error) ->
      Model(..model, timesheet: TimesheetFailed(describe_board_error(error)))
  }
}

/// Seed the editable inputs from a fetched form: each project maps to its logged
/// hours rendered as text (e.g. 4.0 -> "4").
fn hours_input_from_day(day: TimesheetDay) -> Dict(Int, String) {
  list.fold(day.lines, dict.new(), fn(acc, line) {
    dict.insert(acc, line.project_id, format_hours(line.hours))
  })
}

/// Parse the hours currently typed for a project, accepting an integer or decimal.
/// An absent or non-numeric value is an error so the submit handler can prompt.
fn hours_for(model: Model, project_id: Int) -> Result(Float, Nil) {
  case dict.get(model.hours_input, project_id) {
    Error(Nil) -> Error(Nil)
    Ok(raw_hours) -> parse_hours(raw_hours)
  }
}

fn parse_hours(raw_hours: String) -> Result(Float, Nil) {
  case float.parse(raw_hours) {
    Ok(value) -> Ok(value)
    Error(Nil) ->
      case int.parse(raw_hours) {
        Ok(value) -> Ok(int.to_float(value))
        Error(Nil) -> Error(Nil)
      }
  }
}

// --- effects ----------------------------------------------------------------

/// Fetch `GET /api/board?date=<date>` and decode the snapshot via the shared
/// codec, tagging the outcome with the requested `date` so stale responses can be
/// dropped.
fn fetch_board(date: calendar.Date) -> Effect(Message) {
  let url = "/api/board?date=" <> iso_date(date)
  let handler =
    rsvp.expect_json(codecs.board_snapshot_decoder(), fn(result) {
      ApiReturnedBoard(date:, result:)
    })
  rsvp.get(url, handler)
}

/// Fetch `GET /api/timesheet?engineer=<id>&day=<date>` and decode the form,
/// tagging the outcome with the requested engineer/day so a response overtaken by
/// a later scrub or engineer change can be discarded.
fn fetch_timesheet(engineer_id: Int, date: calendar.Date) -> Effect(Message) {
  let url =
    "/api/timesheet?engineer="
    <> int.to_string(engineer_id)
    <> "&day="
    <> iso_date(date)
  let handler =
    rsvp.expect_json(codecs.timesheet_day_decoder(), fn(result) {
      ApiReturnedTimesheet(engineer_id:, date:, result:)
    })
  rsvp.get(url, handler)
}

/// POST `/api/timesheet` to log `hours` against `project_id` for the engineer on
/// the day. The server returns the refreshed form on success, so the same
/// timesheet decoder handles the body; a non-2xx (the PERIOD-FK 422) arrives as an
/// `HttpError` carrying the typed error body, surfaced as a friendly message.
fn save_hours(
  engineer_id: Int,
  date: calendar.Date,
  project_id: Int,
  hours: Float,
) -> Effect(Message) {
  let body = encode_write(engineer_id, date, project_id, hours)
  let handler =
    rsvp.expect_json(codecs.timesheet_day_decoder(), fn(result) {
      ApiSavedTimesheet(engineer_id:, date:, result:)
    })
  rsvp.post("/api/timesheet", body, handler)
}

fn encode_write(
  engineer_id: Int,
  date: calendar.Date,
  project_id: Int,
  hours: Float,
) -> Json {
  codecs.encode_write_request(engineer_id:, project_id:, day: date, hours:)
}

/// POST `/api/operations` with the `{actor, command}` envelope. The server
/// returns the created `Event` on success (the journal row the dispatch appended)
/// and a typed `{error, detail}` body on a 4xx/5xx, which arrives as an
/// `HttpError` carrying that body — decoded into a friendly message by
/// `describe_operation_error`.
fn submit_operation(command: Command) -> Effect(Message) {
  let body =
    codecs.encode_operation_request(OperationRequest(
      actor: console_actor,
      command:,
    ))
  let handler =
    rsvp.expect_json(codecs.event_decoder(), fn(result) {
      ApiAppliedOperation(result:)
    })
  rsvp.post("/api/operations", body, handler)
}

/// Fetch `GET /api/events` and decode the journal (a JSON array of `Event`,
/// newest-first) via the shared codec.
fn fetch_events() -> Effect(Message) {
  let handler =
    rsvp.expect_json(decode.list(codecs.event_decoder()), fn(result) {
      ApiReturnedEvents(result:)
    })
  rsvp.get("/api/events", handler)
}

fn describe_board_error(error: rsvp.Error(String)) -> String {
  case error {
    rsvp.BadBody -> "the response body was malformed"
    rsvp.BadUrl(url) -> "the request URL was invalid: " <> url
    rsvp.HttpError(_) -> "the request returned an error status"
    rsvp.JsonError(_) -> "the response could not be decoded"
    rsvp.NetworkError -> "could not reach the API"
    rsvp.UnhandledResponse(_) -> "the response was not understood"
  }
}

/// Turn a save failure into the friendly sentence shown under the form. A 422
/// from the PERIOD-FK backstop arrives as `HttpError` carrying the typed
/// `{error, detail}` body; we pull out the `detail` so the user sees exactly why
/// the write was refused rather than a raw status.
fn describe_save_error(error: rsvp.Error(String)) -> String {
  case error {
    rsvp.HttpError(response) ->
      case codecs.decode_error_detail(response.body) {
        Ok(detail) -> "Could not save: " <> detail
        Error(Nil) -> "Could not save: the write was rejected."
      }
    _ -> "Could not save: " <> describe_board_error(error)
  }
}

/// Turn a rejected operation into the sentence shown under the console. A
/// classified 4xx/5xx (`ContainmentViolated`/`OverlappingFact`/`InvalidValue`)
/// arrives as `HttpError` carrying the typed `{error, detail}` body; we surface
/// the `detail` so the presenter sees exactly why the operation was refused
/// rather than a raw status.
fn describe_operation_error(error: rsvp.Error(String)) -> String {
  case error {
    rsvp.HttpError(response) ->
      case codecs.decode_error_detail(response.body) {
        Ok(detail) -> "Rejected: " <> detail
        Error(Nil) -> "Rejected: the operation was refused."
      }
    _ -> "Could not apply: " <> describe_board_error(error)
  }
}

// --- URL <-> date -----------------------------------------------------------
// The selected date is mirrored in the query string (?date=YYYY-MM-DD) so the
// view is shareable, bookmarkable, and survives a reload. We `replace` rather than
// `push` so scrubbing does not flood the browser history with intermediate dates.

/// The date to open at: the URL's `?date` when present and valid, otherwise the
/// seed "now". A date outside the slider's bounds is clamped to them.
fn initial_date() -> calendar.Date {
  case modem.initial_uri() {
    Ok(uri) -> date_from_uri(uri)
    Error(Nil) -> seed_now
  }
}

fn date_from_uri(uri: Uri) -> calendar.Date {
  case uri.query {
    None -> seed_now
    Some(query) ->
      case uri.parse_query(query) {
        Ok(params) ->
          case list.key_find(params, "date") {
            Ok(value) ->
              parse_iso_date(value)
              |> result.map(clamp_date)
              |> result.unwrap(seed_now)
            Error(Nil) -> seed_now
          }
        Error(Nil) -> seed_now
      }
  }
}

/// Parse an ISO-8601 "YYYY-MM-DD" string into a `Date`.
fn parse_iso_date(text: String) -> Result(calendar.Date, Nil) {
  case string.split(text, "-") {
    [year, month, day] -> {
      use year <- result.try(int.parse(year))
      use month <- result.try(int.parse(month))
      use month <- result.try(calendar.month_from_int(month))
      use day <- result.try(int.parse(day))
      Ok(calendar.Date(year:, month:, day:))
    }
    _ -> Error(Nil)
  }
}

/// Clamp a `Date` to the slider's inclusive bounds via its day index, so a URL
/// date outside the seed range still lands on a valid slider position.
fn clamp_date(date: calendar.Date) -> calendar.Date {
  let low = date_to_day_index(range_start)
  let high = date_to_day_index(range_end)
  day_index_to_date(int.clamp(date_to_day_index(date), min: low, max: high))
}

/// Mirror the selected date into the URL query string, replacing the current
/// entry so a scrub does not add to the browser history.
fn sync_url(date: calendar.Date) -> Effect(Message) {
  modem.replace("/", Some("date=" <> iso_date(date)), None)
}

// --- View -------------------------------------------------------------------

/// Render the current model: the time slider above the org board it controls, and
/// the my-timesheet panel for the selected engineer on the slider's day.
pub fn view(model: Model) -> Element(Message) {
  html.div([attribute.class("page")], [
    html.h1([], [html.text("Tempo")]),
    view_slider(model),
    view_board(model.board),
    view_timesheet(model),
    view_console(model),
    view_event_log(model.event_log),
  ])
}

/// The date slider: a range input over the seed-range day indices, debounced so a
/// fast scrub fires one fetch of the final position. The selected date is shown as
/// a heading.
fn view_slider(model: Model) -> Element(Message) {
  html.div([attribute.class("slider")], [
    html.h2([], [html.text("As of " <> iso_date(model.date))]),
    html.input([
      attribute.type_("range"),
      attribute.min(int.to_string(date_to_day_index(range_start))),
      attribute.max(int.to_string(date_to_day_index(range_end))),
      attribute.value(int.to_string(model.day_index)),
      attribute.attribute("aria-label", "Board date"),
      event.debounce(event.on_input(on_slider_input), slider_debounce_ms),
    ]),
    html.div([attribute.class("slider-bounds")], [
      html.span([], [html.text(iso_date(range_start))]),
      html.span([], [html.text(iso_date(range_end))]),
    ]),
  ])
}

/// Parse the range input's string value into a `SliderMoved`, ignoring a
/// non-integer value by holding the current position (range inputs never emit one).
fn on_slider_input(raw_value: String) -> Message {
  case int.parse(raw_value) {
    Ok(day_index) -> SliderMoved(day_index:)
    Error(Nil) -> SliderMoved(day_index: date_to_day_index(seed_now))
  }
}

fn view_board(board: Board) -> Element(Message) {
  case board {
    Loading -> html.p([], [html.text("Loading the board…")])
    Failed(detail) ->
      html.p([], [html.text("Could not load the board: " <> detail)])
    Loaded(snapshot) ->
      case snapshot.rows {
        [] -> html.p([], [html.text("No engineers employed as of this date.")])
        rows -> html.ul([attribute.class("board")], list.map(rows, view_row))
      }
  }
}

/// One board line: the engineer with their level and a sentence describing their
/// engagement as of the selected date. The row carries a state class
/// (`on-leave`/`unassigned`/`on-project`) derived from the engagement variant so
/// the stylesheet can colour leave and idle rows distinctly — purely visual, the
/// user-facing text is unchanged.
fn view_row(row: BoardRow) -> Element(Message) {
  html.li(
    [
      attribute.attribute("data-engineer", row.engineer),
      attribute.class("board-row " <> engagement_class(row.engagement)),
    ],
    [
      html.span([attribute.class("engineer")], [html.text(row.engineer)]),
      html.span([attribute.class("level")], [
        html.text("L" <> int.to_string(row.level)),
      ]),
      html.span([attribute.class("engagement")], [
        html.text(describe_engagement(row.engagement)),
      ]),
    ],
  )
}

/// The CSS state class for a board row, by engagement variant: on-leave and
/// unassigned rows are styled distinctly from an active project allocation.
fn engagement_class(engagement: Engagement) -> String {
  case engagement {
    OnProject(..) -> "on-project"
    OnLeave(..) -> "on-leave"
    Unassigned -> "unassigned"
  }
}

/// Render an engagement as the user-facing sentence the board shows for the row.
/// Each variant reads distinctly: an allocation names the project, client,
/// fraction and charge rate; leave is "On leave: <kind>"; an employed-but-idle
/// engineer is "Unassigned".
fn describe_engagement(engagement: Engagement) -> String {
  case engagement {
    OnProject(project:, client:, fraction:, day_rate:, ..) ->
      project
      <> " for "
      <> client
      <> " ("
      <> format_fraction(fraction)
      <> ", "
      <> format_rate(day_rate)
      <> "/day)"
    OnLeave(kind:, ..) -> "On leave: " <> kind
    Unassigned -> "Unassigned"
  }
}

// --- Timesheet panel --------------------------------------------------------

/// The my-timesheet panel: an engineer selector, the day it reads (the slider's
/// date), and the form for that engineer/day below.
fn view_timesheet(model: Model) -> Element(Message) {
  html.div([attribute.class("timesheet")], [
    html.h2([], [html.text("My timesheet")]),
    view_engineer_selector(model.engineer_id),
    html.p([], [html.text("Logging for " <> iso_date(model.date))]),
    view_timesheet_body(model),
  ])
}

/// The engineer dropdown: one option per seed engineer, the current one selected.
/// Changing it dispatches `EngineerSelected` with the chosen id.
fn view_engineer_selector(selected_id: Int) -> Element(Message) {
  html.label([], [
    html.text("Engineer "),
    html.select(
      [
        attribute.attribute("aria-label", "Engineer"),
        event.on_change(on_engineer_change),
      ],
      list.map(engineers, fn(engineer) {
        let #(id, name) = engineer
        html.option(
          [
            attribute.value(int.to_string(id)),
            attribute.selected(id == selected_id),
          ],
          name,
        )
      }),
    ),
  ])
}

/// Parse the selected option's value into an `EngineerSelected`, holding the first
/// engineer if the value is somehow not an integer (the options are all integers).
fn on_engineer_change(raw_value: String) -> Message {
  case int.parse(raw_value) {
    Ok(engineer_id) -> EngineerSelected(engineer_id:)
    Error(Nil) -> EngineerSelected(engineer_id: first_engineer_id())
  }
}

fn view_timesheet_body(model: Model) -> Element(Message) {
  case model.timesheet {
    TimesheetLoading -> html.p([], [html.text("Loading the timesheet…")])
    TimesheetFailed(detail) ->
      html.p([], [html.text("Could not load the timesheet: " <> detail)])
    TimesheetLoaded(day) ->
      case day.lines {
        [] -> html.p([], [html.text("On leave — nothing to log")])
        lines ->
          html.div([], [
            html.ul(
              [attribute.class("timesheet-lines")],
              list.map(lines, fn(line) { view_timesheet_line(model, line) }),
            ),
            view_save_feedback(model.save_state),
          ])
      }
  }
}

/// One timesheet row: the project (with its allocation fraction), an hours input
/// pre-filled with what is currently typed, and a Save button that posts it.
fn view_timesheet_line(model: Model, line: TimesheetLine) -> Element(Message) {
  let project_id = line.project_id
  let current = case dict.get(model.hours_input, project_id) {
    Ok(value) -> value
    Error(Nil) -> ""
  }
  html.li([attribute.attribute("data-project", line.project)], [
    html.label([], [
      html.span([attribute.class("project")], [
        html.text(line.project <> " (" <> format_fraction(line.fraction) <> ")"),
      ]),
      html.input([
        attribute.type_("number"),
        attribute.attribute("aria-label", "Hours for " <> line.project),
        attribute.value(current),
        attribute.step("0.5"),
        attribute.min("0"),
        event.on_input(fn(raw_hours) { HoursEdited(project_id:, raw_hours:) }),
      ]),
    ]),
    html.button([event.on_click(SubmittedHours(project_id:))], [
      html.text("Save " <> line.project),
    ]),
  ])
}

/// The save feedback line under the form: silent until a submission, then
/// "Saving…", a confirmation, or the friendly rejection message.
fn view_save_feedback(save_state: SaveState) -> Element(Message) {
  case save_state {
    Unsaved -> element.none()
    Saving -> html.p([attribute.class("save-state")], [html.text("Saving…")])
    Saved -> html.p([attribute.class("save-state")], [html.text("Saved.")])
    SaveRejected(detail) ->
      html.p([attribute.class("save-state")], [html.text(detail)])
  }
}

/// Format an allocation fraction as a percentage (0.5 -> "50%"): legible and
/// unambiguous about part-time splits.
fn format_fraction(fraction: Float) -> String {
  int.to_string(float.round(fraction *. 100.0)) <> "%"
}

/// Format a day rate as whole dollars ("$1,200"); rates are seeded as round
/// figures so no cents are shown.
fn format_rate(day_rate: Float) -> String {
  "$" <> int.to_string(float.round(day_rate))
}

/// Format logged hours as text for an input value: a whole number when integral
/// ("4"), otherwise one decimal place ("7.5").
fn format_hours(hours: Float) -> String {
  case hours == int.to_float(float.truncate(hours)) {
    True -> int.to_string(float.truncate(hours))
    False -> float.to_string(hours)
  }
}

fn first_engineer_id() -> Int {
  case engineers {
    [#(id, _name), ..] -> id
    [] -> 1
  }
}

// --- Operations console ------------------------------------------------------
// A write surface (PRD §6, FR-9): pick an operation, fill its fields, Apply. On
// success the model refetches the board (for the slider's date) and the event
// log; on rejection it shows the server's typed {error, detail}. The actor is a
// fixed "console" label (no auth), stamped on every event.

/// The eight demo-relevant command kinds the console offers, each with the label
/// shown in the operation selector.
const console_kinds = [
  #(KindOnboardEngineer, "Onboard engineer"),
  #(KindPromote, "Promote"),
  #(KindAssignToProject, "Assign to project"),
  #(KindRollOff, "Roll off project"),
  #(KindReviseRateCard, "Revise rate card"),
  #(KindAdjustRateForPortion, "Adjust rate for portion"),
  #(KindTakeLeave, "Take leave"),
  #(KindTerminateEmployment, "Terminate employment"),
]

/// The operations console: an operation selector, the fields the chosen
/// operation needs, an Apply button, and the outcome of the last submission.
fn view_console(model: Model) -> Element(Message) {
  html.div([attribute.class("console")], [
    html.h2([], [html.text("Operations console")]),
    view_console_selector(model.console_kind),
    html.div(
      [attribute.class("console-fields")],
      console_fields(model.console_kind, model.console_form),
    ),
    html.button(
      [attribute.class("console-apply"), event.on_click(ConsoleSubmitted)],
      [html.text("Apply operation")],
    ),
    view_operation_feedback(model.operation_state),
  ])
}

/// The operation dropdown: one option per console kind, the current one selected.
fn view_console_selector(selected: ConsoleKind) -> Element(Message) {
  html.label([], [
    html.text("Operation "),
    html.select(
      [
        attribute.attribute("aria-label", "Operation"),
        event.on_change(on_console_kind_change),
      ],
      list.map(console_kinds, fn(entry) {
        let #(console_kind, label) = entry
        html.option(
          [
            attribute.value(kind_to_value(console_kind)),
            attribute.selected(console_kind == selected),
          ],
          label,
        )
      }),
    ),
  ])
}

fn on_console_kind_change(raw_value: String) -> Message {
  ConsoleKindSelected(console_kind: kind_from_value(raw_value))
}

/// The string the selector carries for a kind (and parses back), keeping the
/// console fully typed through the round-trip rather than relying on order.
fn kind_to_value(console_kind: ConsoleKind) -> String {
  case console_kind {
    KindOnboardEngineer -> "onboard_engineer"
    KindPromote -> "promote"
    KindAssignToProject -> "assign_to_project"
    KindRollOff -> "roll_off"
    KindReviseRateCard -> "revise_rate_card"
    KindAdjustRateForPortion -> "adjust_rate_for_portion"
    KindTakeLeave -> "take_leave"
    KindTerminateEmployment -> "terminate_employment"
  }
}

fn kind_from_value(raw_value: String) -> ConsoleKind {
  case raw_value {
    "onboard_engineer" -> KindOnboardEngineer
    "promote" -> KindPromote
    "assign_to_project" -> KindAssignToProject
    "roll_off" -> KindRollOff
    "revise_rate_card" -> KindReviseRateCard
    "adjust_rate_for_portion" -> KindAdjustRateForPortion
    "take_leave" -> KindTakeLeave
    "terminate_employment" -> KindTerminateEmployment
    _ -> KindPromote
  }
}

/// The input fields the chosen operation needs, in argument order. Each kind
/// shows only the `Command` parameters it carries (§5a), so the presenter never
/// faces an irrelevant box.
fn console_fields(
  console_kind: ConsoleKind,
  form: ConsoleForm,
) -> List(Element(Message)) {
  case console_kind {
    KindOnboardEngineer -> [
      text_field("Name", FieldName, form.name),
      number_field("Level", FieldLevel, form.level),
      date_field("Effective", FieldEffective, form.effective),
    ]
    KindPromote -> [
      number_field("Engineer id", FieldEngineerId, form.engineer_id),
      number_field("Level", FieldLevel, form.level),
      date_field("Effective", FieldEffective, form.effective),
    ]
    KindAssignToProject -> [
      number_field("Engineer id", FieldEngineerId, form.engineer_id),
      number_field("Project id", FieldProjectId, form.project_id),
      number_field("Fraction", FieldFraction, form.fraction),
      date_field("Valid from", FieldValidFrom, form.valid_from),
      date_field("Valid to", FieldValidTo, form.valid_to),
    ]
    KindRollOff -> [
      number_field("Engineer id", FieldEngineerId, form.engineer_id),
      number_field("Project id", FieldProjectId, form.project_id),
      date_field("Effective", FieldEffective, form.effective),
    ]
    KindReviseRateCard -> [
      number_field("Level", FieldLevel, form.level),
      number_field("Day rate", FieldDayRate, form.day_rate),
      date_field("Effective", FieldEffective, form.effective),
    ]
    KindAdjustRateForPortion -> [
      number_field("Level", FieldLevel, form.level),
      number_field("Day rate", FieldDayRate, form.day_rate),
      date_field("Valid from", FieldValidFrom, form.valid_from),
      date_field("Valid to", FieldValidTo, form.valid_to),
    ]
    KindTakeLeave -> [
      number_field("Engineer id", FieldEngineerId, form.engineer_id),
      text_field("Leave kind", FieldKind, form.kind),
      date_field("Valid from", FieldValidFrom, form.valid_from),
      date_field("Valid to", FieldValidTo, form.valid_to),
    ]
    KindTerminateEmployment -> [
      number_field("Engineer id", FieldEngineerId, form.engineer_id),
      date_field("Effective", FieldEffective, form.effective),
    ]
  }
}

/// A labelled text input bound to a `ConsoleForm` slot; editing it dispatches a
/// `ConsoleFieldEdited` for that field.
fn text_field(
  label: String,
  field: ConsoleField,
  value: String,
) -> Element(Message) {
  console_input(label, field, value, "text")
}

/// A labelled numeric input (int or decimal) bound to a `ConsoleForm` slot.
fn number_field(
  label: String,
  field: ConsoleField,
  value: String,
) -> Element(Message) {
  console_input(label, field, value, "number")
}

/// A labelled date input bound to a `ConsoleForm` slot; the browser's date picker
/// emits the same ISO-8601 "YYYY-MM-DD" string the codec expects.
fn date_field(
  label: String,
  field: ConsoleField,
  value: String,
) -> Element(Message) {
  console_input(label, field, value, "date")
}

fn console_input(
  label: String,
  field: ConsoleField,
  value: String,
  input_type: String,
) -> Element(Message) {
  html.label([attribute.class("console-field")], [
    html.span([], [html.text(label)]),
    html.input([
      attribute.type_(input_type),
      attribute.attribute("aria-label", label),
      attribute.value(value),
      event.on_input(fn(value) { ConsoleFieldEdited(field:, value:) }),
    ]),
  ])
}

/// The console feedback line: silent until a submission, then "Applying…", a
/// confirmation naming the operation and its summary, or the rejection reason.
fn view_operation_feedback(state: OperationState) -> Element(Message) {
  case state {
    OperationIdle -> element.none()
    OperationSubmitting ->
      html.p([attribute.class("operation-state")], [html.text("Applying…")])
    OperationSucceeded(operation:, summary:) ->
      html.p([attribute.class("operation-state")], [
        html.text("Applied " <> operation <> ": " <> summary),
      ])
    OperationFailed(detail) ->
      html.p([attribute.class("operation-state")], [html.text(detail)])
  }
}

// --- Event log panel ---------------------------------------------------------
// The provenance journal (PRD §6, FR-11): one row per operation, newest-first,
// showing the operation tag, its human summary, the actor, and the system-time
// occurred_at. Refreshed after every console operation.

/// The event-log panel: the journal newest-first, or a loading/empty/failed line.
fn view_event_log(event_log: EventLog) -> Element(Message) {
  html.div([attribute.class("event-log")], [
    html.h2([], [html.text("Event log")]),
    view_event_log_body(event_log),
  ])
}

fn view_event_log_body(event_log: EventLog) -> Element(Message) {
  case event_log {
    EventLogLoading -> html.p([], [html.text("Loading the event log…")])
    EventLogFailed(detail) ->
      html.p([], [html.text("Could not load the event log: " <> detail)])
    EventLogLoaded([]) -> html.p([], [html.text("No operations recorded yet.")])
    EventLogLoaded(events) ->
      html.ul([attribute.class("event-list")], list.map(events, view_event))
  }
}

/// One journal row: the operation tag and its human summary, with the actor and
/// system-time `occurred_at` beneath.
fn view_event(event: Event) -> Element(Message) {
  html.li([attribute.class("event-row")], [
    html.span([attribute.class("event-operation")], [
      html.text(event.operation),
    ]),
    html.span([attribute.class("event-summary")], [html.text(event.summary)]),
    html.span([attribute.class("event-meta")], [
      html.text(event.actor <> " · " <> event.occurred_at),
    ]),
  ])
}

// --- Slider date arithmetic -------------------------------------------------
// The slider value is a unix-day index; converting to/from a calendar date keeps
// every position a fixed absolute seed-range date, independent of the wall clock.

/// Days are 86_400 seconds; the index times this is the unix timestamp of midnight.
const seconds_per_day = 86_400

fn date_to_day_index(date: calendar.Date) -> Int {
  let instant = timestamp.from_calendar(date, midnight(), calendar.utc_offset)
  float.round(timestamp.to_unix_seconds(instant)) / seconds_per_day
}

fn day_index_to_date(day_index: Int) -> calendar.Date {
  let instant = timestamp.from_unix_seconds(day_index * seconds_per_day)
  let #(date, _time) = timestamp.to_calendar(instant, calendar.utc_offset)
  date
}

fn midnight() -> calendar.TimeOfDay {
  calendar.TimeOfDay(hours: 0, minutes: 0, seconds: 0, nanoseconds: 0)
}

// --- Date formatting --------------------------------------------------------

fn iso_date(date: calendar.Date) -> String {
  let calendar.Date(year:, month:, day:) = date
  pad4(year) <> "-" <> pad2(calendar.month_to_int(month)) <> "-" <> pad2(day)
}

fn pad2(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 2, with: "0")
}

fn pad4(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 4, with: "0")
}
