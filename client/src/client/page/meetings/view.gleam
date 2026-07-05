//// The Meetings page's views: the page head with the "New meeting" action,
//// the upcoming-meetings table (canonical time plus each attendee's local
//// wall-clock time, and the granular Reschedule/Cancel/Add attendee/Remove
//// attendee launchers), the granular op-form modal, and the bespoke
//// "Schedule meeting" create modal with its attendee builder.

import client/page/meetings/op_form.{view_op_modal}
import client/page/meetings/update.{
  type Attendee, type CreateField, type CreateForm, type Model, type Msg,
  type State, AddAttendeeOpened, AttendanceSet, Attendee, AttendeeAdded,
  AttendeeQueryChanged, AttendeeRemoved, CancelOpened, CreateCancelled,
  CreateClientId, CreateDate, CreateDurationMinutes, CreateFieldEdited,
  CreateLocation, CreateOpened, CreateProjectId, CreateStartsAt, CreateSubmitted,
  CreateTimezone, CreateTitle, MeetingsFailed, MeetingsLoaded, MeetingsLoading,
  RemoveAttendeeOpened, RescheduleOpened, local_time,
}
import client/time
import client/ui/atoms
import client/ui/ops
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam/time/calendar.{type Date}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/access as perm
import shared/location/view.{type EngineerLocation} as location_view
import shared/meeting/command.{Optional, Required}
import shared/meeting/view.{type AttendeeRecord, type MeetingRecord} as meeting_view

pub fn view(
  model: Model,
  as_of: Date,
  permissions: Set(String),
) -> Element(Msg) {
  let _ = as_of
  html.div([], [
    view_op_modal(model.op),
    view_create_modal(model.create, model.roster),
    atoms.list_page(
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
      atoms.button(
        label: "New meeting",
        kind: atoms.Primary,
        size: atoms.Medium,
        on_press: CreateOpened,
      ),
    ]
    False -> []
  }
}

fn view_body(state: State, permissions: Set(String)) -> Element(Msg) {
  case state {
    MeetingsLoading -> atoms.empty_state(message: "Loading meetings…")
    MeetingsFailed(detail:) ->
      atoms.empty_state(message: "Could not load meetings: " <> detail)
    MeetingsLoaded(records:) -> view_table(records, permissions)
  }
}

fn view_table(
  records: List(MeetingRecord),
  permissions: Set(String),
) -> Element(Msg) {
  case records {
    [] -> atoms.empty_state(message: "No upcoming meetings.")
    _ ->
      atoms.data_table(
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
    ops.launch(
      ops.permit(permissions, own: False, kind: ops.OpRescheduleMeeting),
      to_msg: fn(granted) { RescheduleOpened(permit: granted, record:) },
      label: "Reschedule",
      kind: atoms.Ghost,
      size: atoms.Small,
    ),
    ops.launch(
      ops.permit(permissions, own: False, kind: ops.OpCancelMeeting),
      to_msg: fn(granted) { CancelOpened(permit: granted, meeting_id:) },
      label: "Cancel",
      kind: atoms.Ghost,
      size: atoms.Small,
    ),
    ops.launch(
      ops.permit(permissions, own: False, kind: ops.OpAddAttendee),
      to_msg: fn(granted) { AddAttendeeOpened(permit: granted, meeting_id:) },
      label: "Add attendee",
      kind: atoms.Ghost,
      size: atoms.Small,
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
    ops.launch(
      ops.permit(permissions, own: False, kind: ops.OpRemoveAttendee),
      to_msg: fn(granted) {
        RemoveAttendeeOpened(permit: granted, meeting_id:, engineer_id:)
      },
      label: "Remove",
      kind: atoms.Ghost,
      size: atoms.Small,
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
    Required -> atoms.chip(label: "Required", tone: atoms.Neutral)
    Optional -> atoms.chip(label: "Optional", tone: atoms.Accent)
  }
}

// --- Create form ------------------------------------------------------------

fn view_create_modal(
  create: Option(CreateForm),
  roster: List(EngineerLocation),
) -> Element(Msg) {
  case create {
    None -> element.none()
    Some(form) ->
      atoms.modal(
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
        [attribute.class("attendee-builder__matches"), attribute.role("list")],
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
  html.div(
    [
      attribute.class("attendee-builder__match"),
      attribute.role("listitem"),
      attribute.aria_label(name),
    ],
    [
      html.span([], [html.text(name)]),
      atoms.button(
        label: "Add",
        kind: atoms.Ghost,
        size: atoms.Small,
        on_press: AttendeeAdded(engineer_id),
      ),
    ],
  )
}

fn view_current_attendees(
  attendees: List(Attendee),
  roster: List(EngineerLocation),
) -> Element(Msg) {
  html.div(
    [attribute.class("attendee-builder__rows"), attribute.role("list")],
    list.map(attendees, view_current_attendee(_, roster)),
  )
}

fn view_current_attendee(
  attendee: Attendee,
  roster: List(EngineerLocation),
) -> Element(Msg) {
  let Attendee(engineer_id:, attendance:) = attendee
  let name = roster_name(roster, engineer_id)
  html.div(
    [
      attribute.class("attendee-builder__row"),
      attribute.role("listitem"),
      attribute.aria_label(name),
    ],
    [
      html.span([], [html.text(name)]),
      create_attendance_select(engineer_id, attendance),
      atoms.button(
        label: "Remove",
        kind: atoms.Ghost,
        size: atoms.Small,
        on_press: AttendeeRemoved(engineer_id),
      ),
    ],
  )
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
