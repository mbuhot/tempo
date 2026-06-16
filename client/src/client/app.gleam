//// Lustre SPA for the org board and timesheet: model / update / view.
////
//// A date slider selects an instant; the board and the selected engineer's
//// timesheet are fetched for it and re-rendered as of that date. The slider's
//// integer position maps to a fixed absolute calendar date (not the wall clock),
//// and that date is mirrored in the URL (?as_of=YYYY-MM-DD) so a shared link or a
//// reload opens on the same instant. Leave takes precedence over an allocation on
//// the board; the timesheet panel posts hours for a project and surfaces a
//// rejected write (a day not covered by an allocation) as a message, not a crash.
////
//// Imports shared/* only — the JSON contract types and codecs — never server/*.

import gleam/dict.{type Dict}
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
  type BoardRow, type BoardSnapshot, type Date, type Engagement,
  type TimesheetDay, type TimesheetLine, Date, OnLeave, OnProject, Unassigned,
}

/// The fixed seed "now" the board first renders as of (003_seed.sql). The slider
/// starts here so the served page is deterministic and never depends on the wall
/// clock; scrubbing moves it across the whole seed range.
pub const seed_now = Date(year: 2026, month: 6, day: 15)

/// Inclusive slider bounds, as FIXED absolute seed-range endpoints (003_seed.sql:
/// every fact lives within daterange('2024-01-01','2027-01-01')). The slider's
/// integer value is a unix-day index between these two days; the open upper bound
/// 2027-01-01 is exclusive, so the last selectable day is 2026-12-31.
const range_start = Date(year: 2024, month: 1, day: 1)

const range_end = Date(year: 2026, month: 12, day: 31)

/// Debounce window (ms) on slider input: coalesce a fast scrub into one fetch of
/// the final position rather than one request per intermediate pixel.
const slider_debounce_ms = 150

/// The engineers offered in the timesheet selector. Hardcoded to the deterministic
/// v1-wide seed (003_seed.sql) — the same fixed ids/names the board anchors to —
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

/// Lustre model: the day index the slider sits at, the instant it denotes, the
/// board rendered as of it, plus the timesheet panel — which engineer is selected,
/// their form for that day, the hours currently typed into each project's input
/// (keyed by project id), and the last save outcome.
pub type Model {
  Model(
    day_index: Int,
    as_of: Date,
    board: Board,
    engineer_id: Int,
    timesheet: Timesheet,
    hours_input: Dict(Int, String),
    save_state: SaveState,
  )
}

/// Messages the runtime feeds back to `update`.
pub type Message {
  /// The slider moved to a new day index (debounced `on_input`).
  SliderMoved(day_index: Int)
  /// A board fetch resolved; `as_of` tags which request it answers so a stale
  /// response from an earlier slider position can be discarded.
  ApiReturnedBoard(
    as_of: Date,
    result: Result(BoardSnapshot, rsvp.Error(String)),
  )
  /// The timesheet engineer selector changed to a new engineer id.
  EngineerSelected(engineer_id: Int)
  /// A timesheet form fetch resolved; `engineer_id` and `as_of` tag which request
  /// it answers so a response overtaken by a later scrub/selection is discarded.
  ApiReturnedTimesheet(
    engineer_id: Int,
    as_of: Date,
    result: Result(TimesheetDay, rsvp.Error(String)),
  )
  /// The user edited the hours input for one project.
  HoursEdited(project_id: Int, raw_hours: String)
  /// The user submitted hours for one project (the row's Save button).
  SubmittedHours(project_id: Int)
  /// A timesheet write resolved; `engineer_id`/`as_of` tag it for the same
  /// staleness check, and the body is either the refreshed form or the error.
  ApiSavedTimesheet(
    engineer_id: Int,
    as_of: Date,
    result: Result(TimesheetDay, rsvp.Error(String)),
  )
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
  // Open at the date in the URL (?as_of=YYYY-MM-DD) so a shared link or a reload
  // lands on that instant; absent or out of range, fall back to the seed "now".
  // The initial effect writes the resolved date back to the URL so it is explicit.
  let as_of = initial_as_of()
  let model =
    Model(
      day_index: as_of_to_day_index(as_of),
      as_of:,
      board: Loading,
      engineer_id:,
      timesheet: TimesheetLoading,
      hours_input: dict.new(),
      save_state: Unsaved,
    )
  #(
    model,
    effect.batch([
      fetch_board(as_of),
      fetch_timesheet(engineer_id, as_of),
      sync_url(as_of),
    ]),
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
      let as_of = day_index_to_as_of(day_index)
      // Stale-while-revalidate: keep the current board/timesheet on screen while the
      // new date's data is in flight, instead of dropping to a loading state on every
      // scrub (which flickers — blank "Loading…" then a snap back to data). The
      // staleness guard in the ApiReturned* handlers discards any response overtaken
      // by a later move, so the view only ever updates to the latest date's data.
      #(
        Model(..model, day_index:, as_of:, save_state: Unsaved),
        effect.batch([
          fetch_board(as_of),
          fetch_timesheet(model.engineer_id, as_of),
          sync_url(as_of),
        ]),
      )
    }

    ApiReturnedBoard(as_of:, result:) ->
      case as_of == model.as_of {
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
      fetch_timesheet(engineer_id, model.as_of),
    )

    ApiReturnedTimesheet(engineer_id:, as_of:, result:) ->
      case engineer_id == model.engineer_id && as_of == model.as_of {
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
          save_hours(model.engineer_id, model.as_of, project_id, hours),
        )
      }

    ApiSavedTimesheet(engineer_id:, as_of:, result:) ->
      case engineer_id == model.engineer_id && as_of == model.as_of {
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

/// Fetch `GET /api/board?as_of=<date>` and decode the snapshot via the shared
/// codec, tagging the outcome with the requested `as_of` so stale responses can be
/// dropped.
fn fetch_board(as_of: Date) -> Effect(Message) {
  let url = "/api/board?as_of=" <> iso_date(as_of)
  let handler =
    rsvp.expect_json(codecs.board_snapshot_decoder(), fn(result) {
      ApiReturnedBoard(as_of:, result:)
    })
  rsvp.get(url, handler)
}

/// Fetch `GET /api/timesheet?engineer=<id>&day=<date>` and decode the form,
/// tagging the outcome with the requested engineer/day so a response overtaken by
/// a later scrub or engineer change can be discarded.
fn fetch_timesheet(engineer_id: Int, as_of: Date) -> Effect(Message) {
  let url =
    "/api/timesheet?engineer="
    <> int.to_string(engineer_id)
    <> "&day="
    <> iso_date(as_of)
  let handler =
    rsvp.expect_json(codecs.timesheet_day_decoder(), fn(result) {
      ApiReturnedTimesheet(engineer_id:, as_of:, result:)
    })
  rsvp.get(url, handler)
}

/// POST `/api/timesheet` to log `hours` against `project_id` for the engineer on
/// the day. The server returns the refreshed form on success, so the same
/// timesheet decoder handles the body; a non-2xx (the PERIOD-FK 422) arrives as an
/// `HttpError` carrying the typed error body, surfaced as a friendly message.
fn save_hours(
  engineer_id: Int,
  as_of: Date,
  project_id: Int,
  hours: Float,
) -> Effect(Message) {
  let body = encode_write(engineer_id, as_of, project_id, hours)
  let handler =
    rsvp.expect_json(codecs.timesheet_day_decoder(), fn(result) {
      ApiSavedTimesheet(engineer_id:, as_of:, result:)
    })
  rsvp.post("/api/timesheet", body, handler)
}

fn encode_write(
  engineer_id: Int,
  as_of: Date,
  project_id: Int,
  hours: Float,
) -> Json {
  let Date(year:, month:, day:) = as_of
  codecs.encode_write_request(
    engineer_id:,
    project_id:,
    day: Date(year:, month:, day:),
    hours:,
  )
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

// --- URL <-> date -----------------------------------------------------------
// The selected date is mirrored in the query string (?as_of=YYYY-MM-DD) so the
// view is shareable, bookmarkable, and survives a reload. We `replace` rather than
// `push` so scrubbing does not flood the browser history with intermediate dates.

/// The date to open at: the URL's `?as_of` when present and valid, otherwise the
/// seed "now". A date outside the slider's bounds is clamped to them.
fn initial_as_of() -> Date {
  case modem.initial_uri() {
    Ok(uri) -> as_of_from_uri(uri)
    Error(Nil) -> seed_now
  }
}

fn as_of_from_uri(uri: Uri) -> Date {
  case uri.query {
    None -> seed_now
    Some(query) ->
      case uri.parse_query(query) {
        Ok(params) ->
          case list.key_find(params, "as_of") {
            Ok(value) ->
              parse_iso_as_of(value)
              |> result.map(clamp_as_of)
              |> result.unwrap(seed_now)
            Error(Nil) -> seed_now
          }
        Error(Nil) -> seed_now
      }
  }
}

/// Parse an ISO-8601 "YYYY-MM-DD" string into an as-of `Date`.
fn parse_iso_as_of(text: String) -> Result(Date, Nil) {
  case string.split(text, "-") {
    [year, month, day] -> {
      use year <- result.try(int.parse(year))
      use month <- result.try(int.parse(month))
      use day <- result.try(int.parse(day))
      Ok(Date(year:, month:, day:))
    }
    _ -> Error(Nil)
  }
}

/// Clamp an as-of `Date` to the slider's inclusive bounds via its day index, so a URL
/// date outside the seed range still lands on a valid slider position.
fn clamp_as_of(as_of: Date) -> Date {
  let low = as_of_to_day_index(range_start)
  let high = as_of_to_day_index(range_end)
  day_index_to_as_of(int.clamp(as_of_to_day_index(as_of), min: low, max: high))
}

/// Mirror the selected date into the URL query string, replacing the current
/// entry so a scrub does not add to the browser history.
fn sync_url(as_of: Date) -> Effect(Message) {
  modem.replace("/", Some("as_of=" <> iso_date(as_of)), None)
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
  ])
}

/// The date slider: a range input over the seed-range day indices, debounced so a
/// fast scrub fires one fetch of the final position. The selected date is shown as
/// a heading.
fn view_slider(model: Model) -> Element(Message) {
  html.div([attribute.class("slider")], [
    html.h2([], [html.text("As of " <> iso_date(model.as_of))]),
    html.input([
      attribute.type_("range"),
      attribute.min(int.to_string(as_of_to_day_index(range_start))),
      attribute.max(int.to_string(as_of_to_day_index(range_end))),
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
    Error(Nil) -> SliderMoved(day_index: as_of_to_day_index(seed_now))
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
    html.p([], [html.text("Logging for " <> iso_date(model.as_of))]),
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

// --- Slider date arithmetic -------------------------------------------------
// The slider value is a unix-day index; converting to/from a calendar date keeps
// every position a fixed absolute seed-range date, independent of the wall clock.

/// Days are 86_400 seconds; the index times this is the unix timestamp of midnight.
const seconds_per_day = 86_400

fn as_of_to_day_index(as_of: Date) -> Int {
  let Date(year:, month:, day:) = as_of
  let date = calendar.Date(year:, month: month_from_int(month), day:)
  let instant = timestamp.from_calendar(date, midnight(), calendar.utc_offset)
  float.round(timestamp.to_unix_seconds(instant)) / seconds_per_day
}

fn day_index_to_as_of(day_index: Int) -> Date {
  let instant = timestamp.from_unix_seconds(day_index * seconds_per_day)
  let #(date, _time) = timestamp.to_calendar(instant, calendar.utc_offset)
  Date(year: date.year, month: calendar.month_to_int(date.month), day: date.day)
}

fn midnight() -> calendar.TimeOfDay {
  calendar.TimeOfDay(hours: 0, minutes: 0, seconds: 0, nanoseconds: 0)
}

fn month_from_int(month: Int) -> calendar.Month {
  case calendar.month_from_int(month) {
    Ok(value) -> value
    Error(Nil) -> calendar.January
  }
}

// --- Date formatting --------------------------------------------------------

fn iso_date(as_of: Date) -> String {
  let Date(year:, month:, day:) = as_of
  pad4(year) <> "-" <> pad2(month) <> "-" <> pad2(day)
}

fn pad2(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 2, with: "0")
}

fn pad4(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 4, with: "0")
}
