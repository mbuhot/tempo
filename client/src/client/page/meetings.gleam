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
import gleam/result
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
import shared/access as perm
import shared/command as gateway
import shared/location/view.{type EngineerLocation, engineer_location_decoder} as location_view
import shared/meeting/command.{Optional, Required}
import shared/meeting/view.{
  type AttendeeRecord, type MeetingRecord, meeting_record_decoder,
} as meeting_view

pub type State {
  MeetingsLoading
  MeetingsLoaded(records: List(MeetingRecord))
  MeetingsFailed(detail: String)
}

/// One row of the create form's attendee list: an engineer plus the
/// `Attendance` they are invited with.
pub type Attendee {
  Attendee(engineer_id: Int, attendance: command.Attendance)
}

/// Names a slot of the bespoke `CreateForm` — the create form's own field
/// enum, distinct from `ui.OpField` since `ScheduleMeeting` is built directly
/// rather than through the scalar op-form engine.
pub type CreateField {
  CreateTitle
  CreateTimezone
  CreateDate
  CreateStartsAt
  CreateDurationMinutes
  CreateLocation
  CreateClientId
  CreateProjectId
}

/// The "Schedule meeting" create form: scalar fields plus a repeated
/// attendee list built by searching the engineer roster.
pub type CreateForm {
  CreateForm(
    title: String,
    timezone: String,
    date: String,
    starts_at: String,
    duration_minutes: String,
    location: String,
    client_id: String,
    project_id: String,
    attendees: List(Attendee),
    query: String,
    error: Option(String),
  )
}

pub type Model {
  Model(
    as_of: Date,
    actor: String,
    state: State,
    op: Option(ui.OpState),
    roster: List(EngineerLocation),
    create: Option(CreateForm),
  )
}

pub type Msg {
  Fetched(as_of: Date, result: Result(List(MeetingRecord), rsvp.Error(String)))
  RosterFetched(result: Result(List(EngineerLocation), rsvp.Error(String)))
  RescheduleOpened(permit: ui.Permit, record: MeetingRecord)
  CancelOpened(permit: ui.Permit, meeting_id: Int)
  AddAttendeeOpened(permit: ui.Permit, meeting_id: Int)
  RemoveAttendeeOpened(permit: ui.Permit, meeting_id: Int, engineer_id: Int)
  OpCancelled
  OpFieldEdited(field: ui.OpField, value: String)
  OpSubmitted
  OperationReturned(result: Result(Nil, rsvp.Error(String)))
  CreateOpened
  CreateCancelled
  CreateFieldEdited(field: CreateField, value: String)
  AttendeeQueryChanged(query: String)
  AttendeeAdded(engineer_id: Int)
  AttendeeRemoved(engineer_id: Int)
  AttendanceSet(engineer_id: Int, attendance: command.Attendance)
  CreateSubmitted
}

pub fn init(_route, as_of: Date, actor: String) -> #(Model, Effect(Msg)) {
  #(
    Model(
      as_of:,
      actor:,
      state: MeetingsLoading,
      op: None,
      roster: [],
      create: None,
    ),
    effect.batch([fetch(as_of), fetch_roster(as_of)]),
  )
}

pub fn refetch(
  model: Model,
  as_of: Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  #(
    Model(..model, as_of:, actor:),
    effect.batch([fetch(as_of), fetch_roster(as_of)]),
  )
}

fn fetch(as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/meetings?as_of=" <> time.iso_date(as_of),
    decode.list(meeting_record_decoder()),
    fn(result) { Fetched(as_of:, result:) },
  )
}

/// The engineer roster (every engineer plus their location as-of `as_of`) the
/// create form's attendee search filters over.
fn fetch_roster(as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/locations?as_of=" <> time.iso_date(as_of),
    decode.list(engineer_location_decoder()),
    RosterFetched,
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

    RosterFetched(result:) -> {
      let roster = result |> result.unwrap([])
      #(Model(..model, roster:), effect.none(), [])
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
            refetch(
              Model(..model, op: None, create: None),
              model.as_of,
              model.actor,
            )
          #(refreshed, fetch_effect, [OperationCommitted])
        }
        Error(error) -> #(
          set_error(model, api.describe_error(error)),
          effect.none(),
          [],
        )
      }

    CreateOpened -> #(
      Model(..model, create: Some(blank_create_form())),
      effect.none(),
      [],
    )

    CreateCancelled -> #(Model(..model, create: None), effect.none(), [])

    CreateFieldEdited(field:, value:) ->
      case model.create {
        Some(form) -> #(
          Model(
            ..model,
            create: Some(
              CreateForm(..update_create_field(form, field, value), error: None),
            ),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    AttendeeQueryChanged(query:) ->
      case model.create {
        Some(form) -> #(
          Model(..model, create: Some(CreateForm(..form, query:))),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    AttendeeAdded(engineer_id:) ->
      case model.create {
        Some(form) -> #(
          Model(..model, create: Some(add_attendee(form, engineer_id))),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    AttendeeRemoved(engineer_id:) ->
      case model.create {
        Some(form) -> #(
          Model(..model, create: Some(remove_attendee(form, engineer_id))),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    AttendanceSet(engineer_id:, attendance:) ->
      case model.create {
        Some(form) -> #(
          Model(
            ..model,
            create: Some(set_attendance(form, engineer_id, attendance)),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    CreateSubmitted ->
      case model.create {
        Some(form) ->
          case build_schedule_command(form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OperationReturned),
              [],
            )
            Error(message) -> #(
              Model(
                ..model,
                create: Some(CreateForm(..form, error: Some(message))),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
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

/// Surface a rejection on whichever modal is open — the bespoke create form
/// takes priority since it and the granular op-form modal are never open
/// together.
fn set_error(model: Model, message: String) -> Model {
  case model.create {
    Some(form) ->
      Model(..model, create: Some(CreateForm(..form, error: Some(message))))
    None -> set_op_error(model, message)
  }
}

/// Surface a rejection on the open op form, leaving its typed fields intact.
fn set_op_error(model: Model, message: String) -> Model {
  case model.op {
    Some(ui.OpState(kind:, form:, ..)) ->
      Model(..model, op: Some(ui.OpState(kind:, form:, error: Some(message))))
    None -> model
  }
}

// --- Create form --------------------------------------------------------

/// A blank "Schedule meeting" form, opened by the "New meeting" launcher.
fn blank_create_form() -> CreateForm {
  CreateForm(
    title: "",
    timezone: "",
    date: "",
    starts_at: "",
    duration_minutes: "",
    location: "",
    client_id: "",
    project_id: "",
    attendees: [],
    query: "",
    error: None,
  )
}

/// Fold a `CreateFieldEdited` edit into the matching `CreateForm` slot.
fn update_create_field(
  form: CreateForm,
  field: CreateField,
  value: String,
) -> CreateForm {
  case field {
    CreateTitle -> CreateForm(..form, title: value)
    CreateTimezone -> CreateForm(..form, timezone: value)
    CreateDate -> CreateForm(..form, date: value)
    CreateStartsAt -> CreateForm(..form, starts_at: value)
    CreateDurationMinutes -> CreateForm(..form, duration_minutes: value)
    CreateLocation -> CreateForm(..form, location: value)
    CreateClientId -> CreateForm(..form, client_id: value)
    CreateProjectId -> CreateForm(..form, project_id: value)
  }
}

/// Append `engineer_id` as a `Required` attendee, unless already present.
fn add_attendee(form: CreateForm, engineer_id: Int) -> CreateForm {
  case
    list.any(form.attendees, fn(attendee) {
      attendee.engineer_id == engineer_id
    })
  {
    True -> form
    False ->
      CreateForm(
        ..form,
        attendees: list.append(form.attendees, [
          Attendee(engineer_id:, attendance: Required),
        ]),
        query: "",
      )
  }
}

/// Drop `engineer_id` from the attendee list.
fn remove_attendee(form: CreateForm, engineer_id: Int) -> CreateForm {
  CreateForm(
    ..form,
    attendees: list.filter(form.attendees, fn(attendee) {
      attendee.engineer_id != engineer_id
    }),
  )
}

/// Set `engineer_id`'s `Attendance`, leaving every other row untouched.
fn set_attendance(
  form: CreateForm,
  engineer_id: Int,
  attendance: command.Attendance,
) -> CreateForm {
  CreateForm(
    ..form,
    attendees: list.map(form.attendees, fn(attendee) {
      case attendee.engineer_id == engineer_id {
        True -> Attendee(..attendee, attendance:)
        False -> attendee
      }
    }),
  )
}

/// The pure, testable heart of the create form: validate + assemble a
/// `ScheduleMeeting` command, or report the first thing missing.
pub fn build_schedule_command(
  form: CreateForm,
) -> Result(gateway.Command, String) {
  use duration <- result.try(
    int.parse(form.duration_minutes)
    |> result.replace_error("duration must be a number"),
  )
  use date <- result.try(parse_date(form.date))
  case form.title, form.timezone, form.attendees {
    "", _, _ -> Error("title is required")
    _, "", _ -> Error("timezone is required")
    _, _, [] -> Error("add at least one attendee")
    title, timezone, attendees ->
      Ok(
        gateway.MeetingCommand(command.ScheduleMeeting(
          title:,
          timezone:,
          date:,
          starts_at: form.starts_at,
          duration_minutes: duration,
          location: optional_text(form.location),
          client_id: optional_int(form.client_id),
          project_id: optional_int(form.project_id),
          attendees: list.map(attendees, fn(attendee) {
            #(attendee.engineer_id, attendee.attendance)
          }),
        )),
      )
  }
}

/// `""` (after trimming) becomes `None`; anything else is `Some(trimmed)`.
fn optional_text(raw: String) -> Option(String) {
  case string.trim(raw) {
    "" -> None
    trimmed -> Some(trimmed)
  }
}

/// `""` (after trimming) becomes `None`; a non-numeric value also becomes
/// `None` — the surrounding form leaves this field blank rather than reject.
fn optional_int(raw: String) -> Option(Int) {
  case string.trim(raw) {
    "" -> None
    trimmed -> int.parse(trimmed) |> option.from_result
  }
}

/// Parse a `YYYY-MM-DD` field into a `calendar.Date`, or a message naming the
/// expected shape.
fn parse_date(raw: String) -> Result(Date, String) {
  time.parse_iso_date(string.trim(raw))
  |> result.replace_error("date must be YYYY-MM-DD")
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
    view_create_modal(model.create, model.roster),
    ui.list_page(
      title: "Meetings",
      blurb: "Every upcoming meeting as of the rail date, with each attendee's local wall-clock time.",
      actions: view_actions(permissions),
      body: view_body(model.state, permissions),
    ),
  ])
}

fn view_actions(permissions: Set(String)) -> List(Element(Msg)) {
  case set.contains(permissions, perm.meeting_manage) {
    True -> [
      ui.button(
        label: "New meeting",
        kind: ui.Primary,
        size: ui.Medium,
        on_press: CreateOpened,
      ),
    ]
    False -> []
  }
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
    Some(offset) -> local_time(starts_at, offset)
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
        confirm_label: op_verb(kind),
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

/// The confirm-button verb for an operation kind — the action the presenter is
/// committing, not a generic "Confirm".
fn op_verb(kind: ui.OpKind) -> String {
  case kind {
    ui.OpRescheduleMeeting -> "Reschedule"
    ui.OpCancelMeeting -> "Cancel meeting"
    ui.OpAddAttendee -> "Add"
    ui.OpRemoveAttendee -> "Remove"
    _ -> "Confirm"
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

// --- Create form ------------------------------------------------------------

fn view_create_modal(
  create: Option(CreateForm),
  roster: List(EngineerLocation),
) -> Element(Msg) {
  case create {
    None -> element.none()
    Some(form) ->
      ui.modal(
        title: "Schedule meeting",
        error: option.unwrap(form.error, ""),
        body: view_create_fields(form, roster),
        on_cancel: CreateCancelled,
        on_confirm: CreateSubmitted,
        confirm_label: "Schedule",
      )
  }
}

fn view_create_fields(
  form: CreateForm,
  roster: List(EngineerLocation),
) -> List(Element(Msg)) {
  [
    create_field("Title", CreateTitle, form.title, "text"),
    create_field("Timezone (IANA TZID)", CreateTimezone, form.timezone, "text"),
    create_field("Date", CreateDate, form.date, "date"),
    create_field("Start (HH:MM)", CreateStartsAt, form.starts_at, "text"),
    create_field(
      "Duration (minutes)",
      CreateDurationMinutes,
      form.duration_minutes,
      "text",
    ),
    create_field("Location (optional)", CreateLocation, form.location, "text"),
    create_field("Client id (optional)", CreateClientId, form.client_id, "text"),
    create_field(
      "Project id (optional)",
      CreateProjectId,
      form.project_id,
      "text",
    ),
    view_attendee_builder(form, roster),
  ]
}

fn create_field(
  label: String,
  field: CreateField,
  value: String,
  input_type: String,
) -> Element(Msg) {
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text(label)]),
    html.input([
      attribute.type_(input_type),
      attribute.attribute("aria-label", label),
      attribute.value(value),
      event.on_input(fn(value) { CreateFieldEdited(field, value) }),
    ]),
  ])
}

/// The repeated-attendee builder: a name search over the roster, an "Add"
/// control per match not already on the list, and the current attendee rows
/// each with a required/optional select and a remove button.
fn view_attendee_builder(
  form: CreateForm,
  roster: List(EngineerLocation),
) -> Element(Msg) {
  html.div([attribute.class("attendee-builder")], [
    html.label([attribute.class("op-form__field")], [
      html.span([], [html.text("Search engineers")]),
      html.input([
        attribute.type_("text"),
        attribute.attribute("aria-label", "Search engineers"),
        attribute.value(form.query),
        event.on_input(AttendeeQueryChanged),
      ]),
    ]),
    view_roster_matches(form, roster),
    view_current_attendees(form.attendees, roster),
  ])
}

fn view_roster_matches(
  form: CreateForm,
  roster: List(EngineerLocation),
) -> Element(Msg) {
  let query = string.trim(form.query) |> string.lowercase
  case query {
    "" -> element.none()
    _ ->
      html.div(
        [attribute.class("attendee-builder__matches")],
        roster
          |> list.filter(fn(entry) {
            !list.any(form.attendees, fn(attendee) {
              attendee.engineer_id == entry.engineer_id
            })
            && string.contains(string.lowercase(entry.name), query)
          })
          |> list.map(view_roster_match),
      )
  }
}

fn view_roster_match(entry: EngineerLocation) -> Element(Msg) {
  let location_view.EngineerLocation(engineer_id:, name:, ..) = entry
  html.div([attribute.class("attendee-builder__match")], [
    html.span([], [html.text(name)]),
    ui.button(
      label: "Add",
      kind: ui.Ghost,
      size: ui.Small,
      on_press: AttendeeAdded(engineer_id),
    ),
  ])
}

fn view_current_attendees(
  attendees: List(Attendee),
  roster: List(EngineerLocation),
) -> Element(Msg) {
  html.div(
    [attribute.class("attendee-builder__rows")],
    list.map(attendees, view_current_attendee(_, roster)),
  )
}

fn view_current_attendee(
  attendee: Attendee,
  roster: List(EngineerLocation),
) -> Element(Msg) {
  let Attendee(engineer_id:, attendance:) = attendee
  html.div([attribute.class("attendee-builder__row")], [
    html.span([], [html.text(roster_name(roster, engineer_id))]),
    create_attendance_select(engineer_id, attendance),
    ui.button(
      label: "Remove",
      kind: ui.Ghost,
      size: ui.Small,
      on_press: AttendeeRemoved(engineer_id),
    ),
  ])
}

fn roster_name(roster: List(EngineerLocation), engineer_id: Int) -> String {
  roster
  |> list.find(fn(entry) { entry.engineer_id == engineer_id })
  |> result.map(fn(entry) { entry.name })
  |> result.unwrap("Engineer #" <> int.to_string(engineer_id))
}

fn create_attendance_select(
  engineer_id: Int,
  selected: command.Attendance,
) -> Element(Msg) {
  let selected_value = case selected {
    Required -> "required"
    Optional -> "optional"
  }
  html.select(
    [
      attribute.attribute("aria-label", "Attendance"),
      event.on_change(fn(value) {
        AttendanceSet(engineer_id, attendance_from_string(value))
      }),
    ],
    [
      html.option(
        [
          attribute.value("required"),
          attribute.selected(selected_value == "required"),
        ],
        "Required",
      ),
      html.option(
        [
          attribute.value("optional"),
          attribute.selected(selected_value == "optional"),
        ],
        "Optional",
      ),
    ],
  )
}

fn attendance_from_string(raw: String) -> command.Attendance {
  case raw {
    "optional" -> Optional
    _ -> Required
  }
}
