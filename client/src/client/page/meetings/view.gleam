//// The Meetings page's views: the page head with the "New meeting"/"Find a
//// time" actions, the upcoming-meetings table (canonical time plus each
//// attendee's local wall-clock time, and the granular Reschedule/Cancel/Add
//// attendee/Remove attendee launchers), the granular op-form modal, the
//// bespoke "Schedule meeting" create modal with its attendee builder, and the
//// find-a-time wizard modal.

import client/page/meetings/op_form.{view_op_modal}
import client/page/meetings/update.{
  type Attendee, type CreateField, type CreateForm, type FinderField,
  type FinderForm, type Model, type Msg, type State, AddAttendeeOpened,
  AttendanceSet, Attendee, AttendeeAdded, AttendeeQueryChanged, AttendeeRemoved,
  CancelOpened, CreateCancelled, CreateClientId, CreateDate,
  CreateDurationMinutes, CreateFieldEdited, CreateLocation, CreateOpened,
  CreateProjectId, CreateStartsAt, CreateSubmitted, CreateTimezone, CreateTitle,
  FinderAllAdded, FinderAttendanceSet, FinderAttendeeAdded,
  FinderAttendeeQueryChanged, FinderAttendeeRemoved, FinderCancelled,
  FinderDurationMinutes, FinderFieldEdited, FinderFillFromProjectRequested,
  FinderFromDate, FinderOpened, FinderProjectChoice, FinderSearchRequested,
  FinderSlotBooked, FinderTimezone, FinderTitle, FinderToDate, Found,
  MeetingsFailed, MeetingsLoaded, MeetingsLoading, NotSearched,
  RemoveAttendeeOpened, RescheduleOpened, Searching, SlotTaken, local_time,
  located_roster, slot_local_start,
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
import shared/meeting/view.{
  type AttendeeRecord, type CandidateSlot, type MeetingRecord, type SlotAttendee,
} as meeting_view
import shared/roster/view.{type Ref} as roster_view

pub fn view(
  model: Model,
  as_of: Date,
  permissions: Set(String),
) -> Element(Msg) {
  let _ = as_of
  html.div([], [
    view_op_modal(model.op),
    view_create_modal(model.create, model.roster),
    view_finder_modal(model.finder, model.roster, model.projects),
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

// --- Find-a-time wizard ------------------------------------------------------

fn view_finder_modal(
  finder: Option(FinderForm),
  roster: List(EngineerLocation),
  projects: List(Ref),
) -> Element(Msg) {
  case finder {
    None -> element.none()
    Some(form) ->
      atoms.dialog(
        title: "Find a time",
        on_dismiss: FinderCancelled,
        body: html.div([attribute.class("finder")], [
          view_finder_criteria(form, roster, projects),
          html.div([attribute.class("finder__divider")], []),
          view_finder_results(form),
        ]),
      )
  }
}

fn view_finder_criteria(
  form: FinderForm,
  roster: List(EngineerLocation),
  projects: List(Ref),
) -> Element(Msg) {
  html.div([attribute.class("finder__criteria")], [
    finder_field("Title", FinderTitle, form.title, "text"),
    view_finder_attendee_builder(form, roster),
    view_finder_project_fill(form, projects),
    html.div([attribute.class("finder__row")], [
      finder_field("From", FinderFromDate, form.from_date, "date"),
      finder_field("To", FinderToDate, form.to_date, "date"),
    ]),
    finder_field(
      "Duration (minutes)",
      FinderDurationMinutes,
      form.duration_minutes,
      "text",
    ),
    finder_field("Timezone (IANA TZID)", FinderTimezone, form.timezone, "text"),
    finder_error(form.error),
    atoms.button(
      label: "Find windows",
      kind: atoms.Primary,
      size: atoms.Medium,
      on_press: FinderSearchRequested,
    ),
  ])
}

fn finder_field(
  label: String,
  field: FinderField,
  value: String,
  input_type: String,
) -> Element(Msg) {
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text(label)]),
    html.input([
      attribute.type_(input_type),
      attribute.attribute("aria-label", label),
      attribute.value(value),
      event.on_input(fn(value) { FinderFieldEdited(field, value) }),
    ]),
  ])
}

fn finder_error(error: Option(String)) -> Element(Msg) {
  case error {
    None -> element.none()
    Some(message) ->
      html.div([attribute.class("op-form__error")], [html.text(message)])
  }
}

/// The wizard's attendee builder: a name search plus "Add everyone" over the
/// LOCATED roster (an engineer with no location as-of the date can never
/// produce a slot, so none of the wizard's pickers ever offer one), and the
/// current attendee rows each with a required/optional select and a remove
/// button.
fn view_finder_attendee_builder(
  form: FinderForm,
  roster: List(EngineerLocation),
) -> Element(Msg) {
  let located = located_roster(roster)
  html.div([attribute.class("attendee-builder")], [
    html.div([attribute.class("finder__row")], [
      html.label([attribute.class("op-form__field")], [
        html.span([], [html.text("Search engineers")]),
        html.input([
          attribute.type_("text"),
          attribute.attribute("aria-label", "Search engineers"),
          attribute.value(form.query),
          event.on_input(FinderAttendeeQueryChanged),
        ]),
      ]),
      atoms.button(
        label: "Add everyone",
        kind: atoms.Ghost,
        size: atoms.Small,
        on_press: FinderAllAdded,
      ),
    ]),
    view_finder_roster_matches(form, located),
    view_finder_current_attendees(form.attendees, located),
  ])
}

fn view_finder_roster_matches(
  form: FinderForm,
  located: List(EngineerLocation),
) -> Element(Msg) {
  let query = string.trim(form.query) |> string.lowercase
  case query {
    "" -> element.none()
    _ ->
      html.div(
        [attribute.class("attendee-builder__matches"), attribute.role("list")],
        located
          |> list.filter(fn(entry) {
            !list.any(form.attendees, fn(attendee) {
              attendee.engineer_id == entry.engineer_id
            })
            && string.contains(string.lowercase(entry.name), query)
          })
          |> list.map(view_finder_roster_match),
      )
  }
}

fn view_finder_roster_match(entry: EngineerLocation) -> Element(Msg) {
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
        on_press: FinderAttendeeAdded(engineer_id),
      ),
    ],
  )
}

fn view_finder_current_attendees(
  attendees: List(Attendee),
  located: List(EngineerLocation),
) -> Element(Msg) {
  html.div(
    [attribute.class("attendee-builder__rows"), attribute.role("list")],
    list.map(attendees, view_finder_current_attendee(_, located)),
  )
}

fn view_finder_current_attendee(
  attendee: Attendee,
  located: List(EngineerLocation),
) -> Element(Msg) {
  let Attendee(engineer_id:, attendance:) = attendee
  let name = roster_name(located, engineer_id)
  html.div(
    [
      attribute.class("attendee-builder__row"),
      attribute.role("listitem"),
      attribute.aria_label(name),
    ],
    [
      html.span([], [html.text(name)]),
      finder_attendance_select(engineer_id, attendance),
      atoms.button(
        label: "Remove",
        kind: atoms.Ghost,
        size: atoms.Small,
        on_press: FinderAttendeeRemoved(engineer_id),
      ),
    ],
  )
}

fn finder_attendance_select(
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
        FinderAttendanceSet(engineer_id, attendance_from_string(value))
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

/// A project `<select>` plus the "Fill from project" button that fetches that
/// project's as-of team and adds it to the attendee list.
fn view_finder_project_fill(
  form: FinderForm,
  projects: List(Ref),
) -> Element(Msg) {
  html.div([attribute.class("finder__row")], [
    html.label([attribute.class("op-form__field")], [
      html.span([], [html.text("Fill from project")]),
      html.select(
        [
          attribute.attribute("aria-label", "Fill from project"),
          event.on_change(fn(value) {
            FinderFieldEdited(FinderProjectChoice, value)
          }),
        ],
        view_finder_project_options(form.project_choice, projects),
      ),
    ]),
    atoms.button(
      label: "Fill from project",
      kind: atoms.Ghost,
      size: atoms.Small,
      on_press: FinderFillFromProjectRequested,
    ),
  ])
}

fn view_finder_project_options(
  selected: String,
  projects: List(Ref),
) -> List(Element(Msg)) {
  case projects {
    [] -> [
      html.option([attribute.value(""), attribute.disabled(True)], "Loading…"),
    ]
    refs ->
      list.map(refs, fn(reference) {
        let roster_view.Ref(id:, name:) = reference
        let id_text = int.to_string(id)
        html.option(
          [attribute.value(id_text), attribute.selected(id_text == selected)],
          name,
        )
      })
  }
}

fn view_finder_results(form: FinderForm) -> Element(Msg) {
  html.div([attribute.class("finder__results")], case form.results {
    NotSearched -> [
      atoms.empty_state(message: "Search to see available windows."),
    ]
    Searching -> [atoms.empty_state(message: "Searching…")]
    Found(slots:) -> view_finder_slots(slots)
    SlotTaken(slots:) -> [
      html.p([attribute.class("finder__notice")], [
        html.text("That slot was just taken — here are fresh times."),
      ]),
      ..view_finder_slots(slots)
    ]
  })
}

fn view_finder_slots(slots: List(CandidateSlot)) -> List(Element(Msg)) {
  case slots {
    [] -> [atoms.empty_state(message: "No windows found for these criteria.")]
    _ -> list.map(slots, view_finder_slot)
  }
}

fn view_finder_slot(slot: CandidateSlot) -> Element(Msg) {
  let meeting_view.CandidateSlot(
    starts_at:,
    ends_at:,
    attendees:,
    viewer_offset_minutes:,
  ) = slot
  let #(date, starts_local) = slot_local_start(starts_at, viewer_offset_minutes)
  let ends_local = local_time(ends_at, viewer_offset_minutes)
  html.div([attribute.class("finder-slot")], [
    html.div([attribute.class("finder-slot__when")], [
      html.text(
        time.format_date(date) <> " " <> starts_local <> "–" <> ends_local,
      ),
    ]),
    html.div(
      [attribute.class("finder-slot__attendees")],
      list.map(attendees, view_finder_slot_attendee(starts_at, _)),
    ),
    atoms.button(
      label: "Book this slot",
      kind: atoms.Primary,
      size: atoms.Small,
      on_press: FinderSlotBooked(slot),
    ),
  ])
}

fn view_finder_slot_attendee(
  starts_at: String,
  attendee: SlotAttendee,
) -> Element(Msg) {
  let meeting_view.SlotAttendee(name:, offset_minutes:, ..) = attendee
  html.span([], [
    html.text(name <> ": " <> attendee_local_time(starts_at, offset_minutes)),
  ])
}
