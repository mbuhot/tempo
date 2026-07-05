//// The Calendar page (Scheduling Phase C): every upcoming meeting as of the
//// global rail date, read from `GET /api/meetings?as_of=`. Each meeting renders
//// its canonical start time (in the meeting's own timezone) alongside every
//// attendee's local wall-clock time, computed client-side from the UTC offsets
//// the read model ships on the wire — no timezone library needed in the browser.
////
//// Follows the frozen page interface (init/update/view/refetch + OutMsg). No
//// write ops yet (Task 6/7 add reschedule/cancel/attendee edits and the
//// bespoke ScheduleMeeting create form); `op` is carried now so those tasks
//// need no Model shape change.

import client/api
import client/page.{type OutMsg}
import client/time
import client/ui
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/set.{type Set}
import gleam/string
import gleam/time/calendar.{type Date}
import gleam/time/duration
import gleam/time/timestamp
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import rsvp
import shared/meeting/command.{Optional, Required}
import shared/meeting/view.{
  type AttendeeRecord, type MeetingRecord, meeting_record_decoder,
} as meeting_view

pub type State {
  MeetingsLoading
  MeetingsLoaded(records: List(MeetingRecord))
  MeetingsFailed(detail: String)
}

pub type Model {
  Model(as_of: Date, actor: String, state: State, op: Option(ui.OpState))
}

pub type Msg {
  Fetched(as_of: Date, result: Result(List(MeetingRecord), rsvp.Error(String)))
}

pub fn init(_route, as_of: Date, actor: String) -> #(Model, Effect(Msg)) {
  #(Model(as_of:, actor:, state: MeetingsLoading, op: None), fetch(as_of))
}

pub fn refetch(
  model: Model,
  as_of: Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  #(Model(..model, as_of:, actor:), fetch(as_of))
}

fn fetch(as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/meetings?as_of=" <> time.iso_date(as_of),
    decode.list(meeting_record_decoder()),
    fn(result) { Fetched(as_of:, result:) },
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    Fetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let state = case result {
            Ok(records) -> MeetingsLoaded(records:)
            Error(error) -> MeetingsFailed(detail: api.describe_error(error))
          }
          #(Model(..model, state:), effect.none(), [])
        }
      }
  }
}

// --- Time formatting ---------------------------------------------------------

/// The wall-clock "HH:MM" for `starts_at` (an ISO-8601 UTC instant) shifted by
/// `offset_minutes` (minutes east of UTC), so the caller can render a meeting's
/// canonical time or any attendee's local time from the same wire instant.
pub fn local_time(starts_at_iso: String, offset_minutes: Int) -> String {
  let assert Ok(instant) = timestamp.parse_rfc3339(starts_at_iso)
  let shifted = timestamp.add(instant, duration.minutes(offset_minutes))
  let #(_date, time_of_day) =
    timestamp.to_calendar(shifted, calendar.utc_offset)
  pad2(time_of_day.hours) <> ":" <> pad2(time_of_day.minutes)
}

fn pad2(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 2, with: "0")
}

// --- View ---------------------------------------------------------------

pub fn view(
  model: Model,
  as_of: Date,
  permissions: Set(String),
) -> Element(Msg) {
  let _ = as_of
  let _ = permissions
  ui.list_page(
    title: "Meetings",
    blurb: "Every upcoming meeting as of the rail date, with each attendee's local wall-clock time.",
    actions: [],
    body: view_body(model.state),
  )
}

fn view_body(state: State) -> Element(Msg) {
  case state {
    MeetingsLoading -> ui.empty_state(message: "Loading meetings…")
    MeetingsFailed(detail:) ->
      ui.empty_state(message: "Could not load meetings: " <> detail)
    MeetingsLoaded(records:) -> view_table(records)
  }
}

fn view_table(records: List(MeetingRecord)) -> Element(Msg) {
  case records {
    [] -> ui.empty_state(message: "No upcoming meetings.")
    _ ->
      ui.data_table(
        headers: [#("Meeting", False), #("When", False), #("Attendees", False)],
        rows: list.map(records, view_row),
      )
  }
}

fn view_row(record: MeetingRecord) -> Element(Msg) {
  let meeting_view.MeetingRecord(
    title:,
    meeting_tz:,
    starts_at:,
    canonical_offset_minutes:,
    attendees:,
    ..,
  ) = record
  html.tr([], [
    html.td([], [html.text(title)]),
    html.td([attribute.class("mono")], [
      html.text(canonical_time(starts_at, canonical_offset_minutes, meeting_tz)),
    ]),
    html.td([], [view_attendees(starts_at, attendees)]),
  ])
}

fn canonical_time(
  starts_at: String,
  canonical_offset_minutes: Int,
  meeting_tz: String,
) -> String {
  local_time(starts_at, canonical_offset_minutes)
  <> " "
  <> time.utc_offset(canonical_offset_minutes)
  <> " ("
  <> meeting_tz
  <> ")"
}

fn view_attendees(
  starts_at: String,
  attendees: List(AttendeeRecord),
) -> Element(Msg) {
  html.div([], list.map(attendees, view_attendee(starts_at, _)))
}

fn view_attendee(starts_at: String, attendee: AttendeeRecord) -> Element(Msg) {
  let meeting_view.AttendeeRecord(name:, attendance:, local_offset_minutes:, ..) =
    attendee
  html.div([], [
    html.span([], [
      html.text(
        name <> ": " <> attendee_local_time(starts_at, local_offset_minutes),
      ),
    ]),
    html.text(" "),
    attendance_chip(attendance),
  ])
}

fn attendee_local_time(
  starts_at: String,
  local_offset_minutes: Option(Int),
) -> String {
  case local_offset_minutes {
    option.Some(offset) -> local_time(starts_at, offset)
    None -> "no location"
  }
}

fn attendance_chip(attendance: command.Attendance) -> Element(Msg) {
  case attendance {
    Required -> ui.chip(label: "Required", tone: ui.Neutral)
    Optional -> ui.chip(label: "Optional", tone: ui.Accent)
  }
}
