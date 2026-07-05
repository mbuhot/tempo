//// The Calendar page (Scheduling Phase C): every upcoming meeting as of the
//// global rail date, read from `GET /api/meetings?as_of=`. Each meeting renders
//// its canonical start time (in the meeting's own timezone) alongside every
//// attendee's local wall-clock time, computed client-side from the UTC offsets
//// the read model ships on the wire — no timezone library needed in the browser.
////
//// Follows the frozen page interface (init/update/view/refetch + OutMsg). Every
//// row carries the four granular edit launchers (Reschedule/Cancel/Add
//// attendee/Remove attendee) built on the shared `ui` op-form engine (Task 6);
//// the bespoke `ScheduleMeeting` create form is a later task.

import client/api
import client/page.{type OutMsg, OperationCommitted}
import client/time
import client/ui
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import gleam/time/calendar.{type Date}
import gleam/time/duration
import gleam/time/timestamp
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
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
  RescheduleOpened(permit: ui.Permit, record: MeetingRecord)
  CancelOpened(permit: ui.Permit, meeting_id: Int)
  AddAttendeeOpened(permit: ui.Permit, meeting_id: Int)
  RemoveAttendeeOpened(permit: ui.Permit, meeting_id: Int, engineer_id: Int)
  OpCancelled
  OpFieldEdited(field: ui.OpField, value: String)
  OpSubmitted
  OperationReturned(result: Result(Nil, rsvp.Error(String)))
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

    RescheduleOpened(permit:, record:) -> {
      let kind = ui.permit_kind(permit)
      let meeting_view.MeetingRecord(
        meeting_id:,
        meeting_tz:,
        starts_at:,
        ends_at:,
        canonical_offset_minutes:,
        ..,
      ) = record
      let form =
        ui.blank_op_form(kind, model.as_of)
        |> ui.update_op_form(ui.FMeetingId, int.to_string(meeting_id))
        |> ui.update_op_form(
          ui.FEffective,
          time.iso_date(local_date(starts_at, canonical_offset_minutes)),
        )
        |> ui.update_op_form(
          ui.FStartsAt,
          local_time(starts_at, canonical_offset_minutes),
        )
        |> ui.update_op_form(
          ui.FDurationMinutes,
          int.to_string(minutes_between(starts_at, ends_at)),
        )
        |> ui.update_op_form(ui.FTimezone, meeting_tz)
      #(
        Model(..model, op: Some(ui.OpState(kind:, form:, error: None))),
        effect.none(),
        [],
      )
    }

    CancelOpened(permit:, meeting_id:) -> #(
      open_op(model, permit, meeting_id),
      effect.none(),
      [],
    )

    AddAttendeeOpened(permit:, meeting_id:) -> #(
      open_op(model, permit, meeting_id),
      effect.none(),
      [],
    )

    RemoveAttendeeOpened(permit:, meeting_id:, engineer_id:) -> {
      let kind = ui.permit_kind(permit)
      let form =
        ui.blank_op_form(kind, model.as_of)
        |> ui.update_op_form(ui.FMeetingId, int.to_string(meeting_id))
        |> ui.update_op_form(ui.FEngineerId, int.to_string(engineer_id))
      #(
        Model(..model, op: Some(ui.OpState(kind:, form:, error: None))),
        effect.none(),
        [],
      )
    }

    OpCancelled -> #(Model(..model, op: None), effect.none(), [])

    OpFieldEdited(field:, value:) ->
      case model.op {
        Some(ui.OpState(kind:, form:, ..)) -> #(
          Model(
            ..model,
            op: Some(ui.OpState(
              kind:,
              form: ui.update_op_form(form, field, value),
              error: None,
            )),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    OpSubmitted ->
      case model.op {
        Some(ui.OpState(kind:, form:, ..)) ->
          case ui.build_command(kind, form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OperationReturned),
              [],
            )
            Error(prompt) -> #(
              Model(
                ..model,
                op: Some(ui.OpState(kind:, form:, error: Some(prompt))),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    OperationReturned(result:) ->
      case result {
        Ok(_events) -> {
          let #(refreshed, fetch_effect) =
            refetch(Model(..model, op: None), model.as_of, model.actor)
          #(refreshed, fetch_effect, [OperationCommitted])
        }
        Error(error) -> #(
          set_op_error(model, api.describe_error(error)),
          effect.none(),
          [],
        )
      }
  }
}

/// Open `permit`'s op with a form pre-filled with `meeting_id` only — the shape
/// shared by cancel and add-attendee, which need no other prefill.
fn open_op(model: Model, permit: ui.Permit, meeting_id: Int) -> Model {
  let kind = ui.permit_kind(permit)
  let form =
    ui.blank_op_form(kind, model.as_of)
    |> ui.update_op_form(ui.FMeetingId, int.to_string(meeting_id))
  Model(..model, op: Some(ui.OpState(kind:, form:, error: None)))
}

/// Surface a rejection on the open op form, leaving its typed fields intact.
fn set_op_error(model: Model, message: String) -> Model {
  case model.op {
    Some(ui.OpState(kind:, form:, ..)) ->
      Model(..model, op: Some(ui.OpState(kind:, form:, error: Some(message))))
    None -> model
  }
}

// --- Time formatting ---------------------------------------------------------

/// An ISO-8601 UTC instant shifted by `offset_minutes` (minutes east of UTC)
/// and split into its local calendar date and wall-clock time — the shared
/// arithmetic behind `local_time`, `local_date`, and the reschedule prefill.
fn shift_local(
  starts_at_iso: String,
  offset_minutes: Int,
) -> #(Date, calendar.TimeOfDay) {
  let assert Ok(instant) = timestamp.parse_rfc3339(starts_at_iso)
  let shifted = timestamp.add(instant, duration.minutes(offset_minutes))
  timestamp.to_calendar(shifted, calendar.utc_offset)
}

/// The wall-clock "HH:MM" for `starts_at` (an ISO-8601 UTC instant) shifted by
/// `offset_minutes` (minutes east of UTC), so the caller can render a meeting's
/// canonical time or any attendee's local time from the same wire instant.
pub fn local_time(starts_at_iso: String, offset_minutes: Int) -> String {
  let #(_date, time_of_day) = shift_local(starts_at_iso, offset_minutes)
  pad2(time_of_day.hours) <> ":" <> pad2(time_of_day.minutes)
}

/// The local calendar date for `starts_at` shifted by `offset_minutes` — used to
/// pre-fill the reschedule form's date field from a meeting's own timezone.
fn local_date(starts_at_iso: String, offset_minutes: Int) -> Date {
  let #(date, _time_of_day) = shift_local(starts_at_iso, offset_minutes)
  date
}

/// The whole-minute span between two ISO-8601 UTC instants — used to pre-fill
/// the reschedule form's duration field from a meeting's `starts_at`/`ends_at`.
fn minutes_between(starts_at_iso: String, ends_at_iso: String) -> Int {
  let assert Ok(starts_at) = timestamp.parse_rfc3339(starts_at_iso)
  let assert Ok(ends_at) = timestamp.parse_rfc3339(ends_at_iso)
  float.round(
    duration.to_seconds(timestamp.difference(starts_at, ends_at)) /. 60.0,
  )
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
  html.div([], [
    view_op_modal(model.op),
    ui.list_page(
      title: "Meetings",
      blurb: "Every upcoming meeting as of the rail date, with each attendee's local wall-clock time.",
      actions: [],
      body: view_body(model.state, permissions),
    ),
  ])
}

fn view_body(state: State, permissions: Set(String)) -> Element(Msg) {
  case state {
    MeetingsLoading -> ui.empty_state(message: "Loading meetings…")
    MeetingsFailed(detail:) ->
      ui.empty_state(message: "Could not load meetings: " <> detail)
    MeetingsLoaded(records:) -> view_table(records, permissions)
  }
}

fn view_table(
  records: List(MeetingRecord),
  permissions: Set(String),
) -> Element(Msg) {
  case records {
    [] -> ui.empty_state(message: "No upcoming meetings.")
    _ ->
      ui.data_table(
        headers: [
          #("Meeting", False),
          #("When", False),
          #("Attendees", False),
          #("", False),
        ],
        rows: list.map(records, view_row(_, permissions)),
      )
  }
}

fn view_row(record: MeetingRecord, permissions: Set(String)) -> Element(Msg) {
  let meeting_view.MeetingRecord(
    meeting_id:,
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
    html.td([], [view_attendees(meeting_id, starts_at, attendees, permissions)]),
    html.td([], [view_meeting_actions(record, permissions)]),
  ])
}

/// The per-row "Reschedule"/"Cancel"/"Add attendee" launchers, each gated by
/// `meeting.manage` and opening the shared op-form modal pre-filled with this
/// meeting's id (reschedule also pre-fills its current date/start/duration/tz).
fn view_meeting_actions(
  record: MeetingRecord,
  permissions: Set(String),
) -> Element(Msg) {
  let meeting_view.MeetingRecord(meeting_id:, ..) = record
  html.div([attribute.class("action-row")], [
    ui.launch(
      ui.permit(permissions, own: False, kind: ui.OpRescheduleMeeting),
      to_msg: fn(granted) { RescheduleOpened(permit: granted, record:) },
      label: "Reschedule",
      kind: ui.Ghost,
      size: ui.Small,
    ),
    ui.launch(
      ui.permit(permissions, own: False, kind: ui.OpCancelMeeting),
      to_msg: fn(granted) { CancelOpened(permit: granted, meeting_id:) },
      label: "Cancel",
      kind: ui.Ghost,
      size: ui.Small,
    ),
    ui.launch(
      ui.permit(permissions, own: False, kind: ui.OpAddAttendee),
      to_msg: fn(granted) { AddAttendeeOpened(permit: granted, meeting_id:) },
      label: "Add attendee",
      kind: ui.Ghost,
      size: ui.Small,
    ),
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
  meeting_id: Int,
  starts_at: String,
  attendees: List(AttendeeRecord),
  permissions: Set(String),
) -> Element(Msg) {
  html.div(
    [],
    list.map(attendees, view_attendee(meeting_id, starts_at, _, permissions)),
  )
}

fn view_attendee(
  meeting_id: Int,
  starts_at: String,
  attendee: AttendeeRecord,
  permissions: Set(String),
) -> Element(Msg) {
  let meeting_view.AttendeeRecord(
    engineer_id:,
    name:,
    attendance:,
    local_offset_minutes:,
    ..,
  ) = attendee
  html.div([], [
    html.span([], [
      html.text(
        name <> ": " <> attendee_local_time(starts_at, local_offset_minutes),
      ),
    ]),
    html.text(" "),
    attendance_chip(attendance),
    html.text(" "),
    ui.launch(
      ui.permit(permissions, own: False, kind: ui.OpRemoveAttendee),
      to_msg: fn(granted) {
        RemoveAttendeeOpened(permit: granted, meeting_id:, engineer_id:)
      },
      label: "Remove",
      kind: ui.Ghost,
      size: ui.Small,
    ),
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

// --- Op form --------------------------------------------------------------

fn view_op_modal(op: Option(ui.OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(ui.OpState(kind:, form:, error:)) ->
      ui.modal(
        title: op_title(kind),
        error: option.unwrap(error, ""),
        body: op_fields(kind, form),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: op_title(kind),
      )
  }
}

fn op_title(kind: ui.OpKind) -> String {
  case kind {
    ui.OpRescheduleMeeting -> "Reschedule meeting"
    ui.OpCancelMeeting -> "Cancel meeting"
    ui.OpAddAttendee -> "Add attendee"
    ui.OpRemoveAttendee -> "Remove attendee"
    _ -> ""
  }
}

fn op_fields(kind: ui.OpKind, form: ui.OpForm) -> List(Element(Msg)) {
  case kind {
    ui.OpRescheduleMeeting -> [
      date_field("Date", ui.FEffective, form.effective),
      text_field("Start (HH:MM)", ui.FStartsAt, form.starts_at),
      text_field(
        "Duration (minutes)",
        ui.FDurationMinutes,
        form.duration_minutes,
      ),
      text_field("Timezone (IANA TZID)", ui.FTimezone, form.timezone),
    ]
    ui.OpCancelMeeting -> [
      html.p([], [html.text("Cancel meeting #" <> form.meeting_id <> "?")]),
    ]
    ui.OpAddAttendee -> [
      text_field("Engineer id", ui.FEngineerId, form.engineer_id),
      attendance_select(form.attendance),
    ]
    ui.OpRemoveAttendee -> [
      html.p([], [
        html.text(
          "Remove engineer #"
          <> form.engineer_id
          <> " from meeting #"
          <> form.meeting_id
          <> "?",
        ),
      ]),
    ]
    _ -> []
  }
}

fn text_field(label: String, field: ui.OpField, value: String) -> Element(Msg) {
  ui.op_field(
    label:,
    field:,
    value:,
    input_type: "text",
    to_msg: fn(field, value) { OpFieldEdited(field:, value:) },
  )
}

fn date_field(label: String, field: ui.OpField, value: String) -> Element(Msg) {
  ui.op_field(
    label:,
    field:,
    value:,
    input_type: "date",
    to_msg: fn(field, value) { OpFieldEdited(field:, value:) },
  )
}

/// A labelled `<select>` over the two `Attendance` values, bound to the
/// `FAttendance` slot.
fn attendance_select(selected: String) -> Element(Msg) {
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Attendance")]),
    html.select(
      [
        attribute.attribute("aria-label", "Attendance"),
        event.on_change(fn(value) { OpFieldEdited(ui.FAttendance, value) }),
      ],
      [
        html.option(
          [
            attribute.value("required"),
            attribute.selected(selected == "required"),
          ],
          "Required",
        ),
        html.option(
          [
            attribute.value("optional"),
            attribute.selected(selected == "optional"),
          ],
          "Optional",
        ),
      ],
    ),
  ])
}
