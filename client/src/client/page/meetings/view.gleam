//// The Meetings page's views: the page head with the "New meeting"/"Find a
//// time" actions, a dismissible booking-confirmation notice, the
//// upcoming-meetings table (canonical time plus each attendee's local
//// wall-clock time, the attendance-pill toggle, and the icon-button
//// Reschedule/Cancel/Add attendee/Remove attendee launchers), the granular
//// op-form modal, and the bespoke "Schedule meeting" create modal with its
//// attendee builder. The find-a-time wizard's own view lives in
//// `meetings/finder_view`.

import client/icons
import client/page/meetings/browser_time
import client/page/meetings/finder.{type Attendee, Attendee, roster_name}
import client/page/meetings/finder_view.{
  attendance_toggle_button, view_finder_modal,
}
import client/page/meetings/op_form.{view_op_modal}
import client/page/meetings/time_display.{
  type TimeDisplay, LocalTime, OriginTime, attendee_local_time, resolve_zone,
  when_line,
}
import client/page/meetings/update.{
  type CreateField, type CreateForm, type Model, type Msg, type State,
  AddAttendeeOpened, AttendanceSet, AttendanceToggled, AttendeeAdded,
  AttendeeQueryChanged, AttendeeRemoved, CancelOpened, CreateCancelled,
  CreateClientId, CreateDate, CreateDurationMinutes, CreateFieldEdited,
  CreateLocation, CreateOpened, CreateProjectId, CreateStartsAt, CreateSubmitted,
  CreateTimezone, CreateTitle, FinderOpened, MeetingsFailed, MeetingsLoaded,
  MeetingsLoading, NoticeDismissed, RemoveAttendeeOpened, RescheduleOpened,
  TimeDisplaySet,
}
import client/ui/atoms
import client/ui/ops
import gleam/list
import gleam/option.{type Option, None, Some}
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
    view_finder_modal(
      model.finder,
      model.roster,
      model.projects,
      model.time_display,
    ),
    atoms.list_page(
      title: "Meetings",
      blurb: "Every upcoming meeting as of the rail date, with each attendee's local wall-clock time.",
      actions: view_actions(permissions, model.time_display),
      body: html.div([], [
        view_notice(model.notice),
        view_body(model.state, permissions, model.time_display),
      ]),
    ),
  ])
}

/// A dismissible confirmation bar above the table — set by a successful
/// find-a-time booking, cleared by its own × or by any subsequent write.
fn view_notice(notice: Option(String)) -> Element(Msg) {
  case notice {
    None -> element.none()
    Some(message) ->
      html.div([attribute.class("notice notice--success")], [
        html.span([], [html.text(message)]),
        atoms.icon_button(
          label: "Dismiss",
          icon: icons.remove(),
          tone: atoms.IconPlain,
          on_press: NoticeDismissed,
        ),
      ])
  }
}

fn view_actions(
  permissions: Set(String),
  time_display: TimeDisplay,
) -> List(Element(Msg)) {
  [view_time_toggle(time_display), ..view_write_actions(permissions)]
}

fn view_write_actions(permissions: Set(String)) -> List(Element(Msg)) {
  case set.contains(permissions, perm.meeting_manage) {
    True -> [
      atoms.button(
        label: "New meeting",
        kind: atoms.Primary,
        size: atoms.Medium,
        on_press: CreateOpened,
      ),
      atoms.button(
        label: "Find a time",
        kind: atoms.Ghost,
        size: atoms.Medium,
        on_press: FinderOpened,
      ),
    ]
    False -> []
  }
}

/// The Origin time / Local time segmented toggle (#57): two mutually
/// exclusive `aria-pressed` buttons in a labelled group, the active one styled
/// as the primary `.btn`, the inactive one as `.btn--ghost`. Visible to every
/// viewer regardless of `meeting.manage` — it only changes how times render,
/// never what can be written.
fn view_time_toggle(time_display: TimeDisplay) -> Element(Msg) {
  html.div(
    [
      attribute.class("action-row"),
      attribute.role("group"),
      attribute.aria_label("Time display"),
    ],
    [
      view_time_toggle_button("Origin time", OriginTime, time_display),
      view_time_toggle_button("Local time", LocalTime, time_display),
    ],
  )
}

fn view_time_toggle_button(
  label: String,
  value: TimeDisplay,
  current: TimeDisplay,
) -> Element(Msg) {
  let active = value == current
  let class = case active {
    True -> "btn"
    False -> "btn btn--ghost"
  }
  html.button(
    [
      attribute.class(class),
      attribute.aria_pressed(case active {
        True -> "true"
        False -> "false"
      }),
      event.on_click(TimeDisplaySet(value)),
    ],
    [html.text(label)],
  )
}

fn view_body(
  state: State,
  permissions: Set(String),
  time_display: TimeDisplay,
) -> Element(Msg) {
  case state {
    MeetingsLoading -> atoms.empty_state(message: "Loading meetings…")
    MeetingsFailed(detail:) ->
      atoms.empty_state(message: "Could not load meetings: " <> detail)
    MeetingsLoaded(records:) -> view_table(records, permissions, time_display)
  }
}

fn view_table(
  records: List(MeetingRecord),
  permissions: Set(String),
  time_display: TimeDisplay,
) -> Element(Msg) {
  case records {
    [] -> atoms.empty_state(message: "No upcoming meetings.")
    _ ->
      html.div([attribute.class("mtg-table")], [
        atoms.data_table(
          headers: [
            #("Meeting", False),
            #("When", False),
            #("Attendees", False),
            #("", False),
          ],
          rows: list.map(records, view_row(_, permissions, time_display)),
        ),
      ])
  }
}

fn view_row(
  record: MeetingRecord,
  permissions: Set(String),
  time_display: TimeDisplay,
) -> Element(Msg) {
  let meeting_view.MeetingRecord(
    meeting_id:,
    title:,
    meeting_tz:,
    starts_at:,
    canonical_offset_minutes:,
    attendees:,
    ..,
  ) = record
  let browser_offset_minutes = browser_time.timezone_offset_minutes(starts_at)
  let browser_timezone = browser_time.browser_timezone()
  html.tr([], [
    html.td([attribute.class("mtg-title")], [html.text(title)]),
    html.td([attribute.class("mono")], [
      html.div([], [
        html.text(when_line(
          time_display,
          starts_at,
          canonical_offset_minutes,
          browser_offset_minutes,
        )),
      ]),
      html.div([attribute.class("cell-sub")], [
        html.text(
          "(" <> resolve_zone(time_display, meeting_tz, browser_timezone) <> ")",
        ),
      ]),
    ]),
    html.td([], [view_attendees(meeting_id, starts_at, attendees, permissions)]),
    html.td([], [view_meeting_actions(record, permissions)]),
  ])
}

/// The per-row "Reschedule"/"Cancel"/"Add attendee" icon-button launchers, each
/// gated by `meeting.manage` and opening the shared op-form modal pre-filled
/// with this meeting's id (reschedule also pre-fills its current
/// date/start/duration/tz).
fn view_meeting_actions(
  record: MeetingRecord,
  permissions: Set(String),
) -> Element(Msg) {
  let meeting_view.MeetingRecord(meeting_id:, ..) = record
  html.div([attribute.class("action-row")], [
    ops.launch_icon(
      ops.permit(permissions, own: False, kind: ops.OpRescheduleMeeting),
      to_msg: fn(granted) { RescheduleOpened(permit: granted, record:) },
      label: "Reschedule",
      icon: icons.reschedule(),
      tone: atoms.IconNeutral,
    ),
    ops.launch_icon(
      ops.permit(permissions, own: False, kind: ops.OpCancelMeeting),
      to_msg: fn(granted) { CancelOpened(permit: granted, meeting_id:) },
      label: "Cancel",
      icon: icons.cancel(),
      tone: atoms.IconDanger,
    ),
    ops.launch_icon(
      ops.permit(permissions, own: False, kind: ops.OpAddAttendee),
      to_msg: fn(granted) { AddAttendeeOpened(permit: granted, meeting_id:) },
      label: "Add attendee",
      icon: icons.person_add(),
      tone: atoms.IconNeutral,
    ),
  ])
}

fn view_attendees(
  meeting_id: Int,
  starts_at: String,
  attendees: List(AttendeeRecord),
  permissions: Set(String),
) -> Element(Msg) {
  html.div(
    [attribute.class("attendee-rows"), attribute.role("list")],
    list.map(attendees, view_attendee(meeting_id, starts_at, _, permissions)),
  )
}

/// One attendee row, one line: name + local time, the attendance pill (a
/// toggle button for a `meeting.manage` viewer, a plain pill otherwise), and a
/// name-scoped Remove icon button. `role="listitem"` + an aria-label naming
/// the attendee lets e2e scope a click to exactly one attendee's controls.
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
  html.div(
    [
      attribute.class("attendee-row"),
      attribute.role("listitem"),
      attribute.aria_label(name),
    ],
    [
      html.span([attribute.class("attendee-row__name")], [
        html.text(
          name <> ": " <> attendee_local_time(starts_at, local_offset_minutes),
        ),
      ]),
      view_attendance_control(meeting_id, engineer_id, attendance, permissions),
      ops.launch_icon(
        ops.permit(permissions, own: False, kind: ops.OpRemoveAttendee),
        to_msg: fn(granted) {
          RemoveAttendeeOpened(permit: granted, meeting_id:, engineer_id:)
        },
        label: "Remove " <> name,
        icon: icons.remove(),
        tone: atoms.IconPlain,
      ),
    ],
  )
}

fn attendance_chip(attendance: command.Attendance) -> Element(Msg) {
  case attendance {
    Required -> atoms.chip(label: "Required", tone: atoms.Neutral)
    Optional -> atoms.chip(label: "Optional", tone: atoms.Accent)
  }
}

/// The Required/Optional pill: a toggle button dispatching the flipped
/// `AddAttendee` when the viewer holds `meeting.manage` (the server insert is
/// an upsert, so re-adding with a new attendance simply re-marks it), a plain
/// inert pill otherwise.
fn view_attendance_control(
  meeting_id: Int,
  engineer_id: Int,
  attendance: command.Attendance,
  permissions: Set(String),
) -> Element(Msg) {
  case ops.permit(permissions, own: False, kind: ops.OpAddAttendee) {
    Ok(permit) ->
      attendance_toggle_button(
        fn(flipped) {
          AttendanceToggled(
            permit:,
            meeting_id:,
            engineer_id:,
            attendance: flipped,
          )
        },
        attendance,
      )
    Error(Nil) -> attendance_chip(attendance)
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
