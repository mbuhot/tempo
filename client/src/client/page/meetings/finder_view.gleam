//// The Meetings page's find-a-time wizard view: the dialog's guided criteria
//// column (Title/Attendees/Dates/Duration/Timezone sections, the wizard's own
//// attendee builder and "Fill from project" picker), the results panel and its
//// candidate-slot list, and the attendance chip-toggle button shared with the
//// main table's attendee rows.

import client/icons
import client/page/meetings/browser_time
import client/page/meetings/finder.{
  type Attendee, type FinderField, type FinderForm, FinderDurationMinutes,
  FinderFromDate, FinderProjectChoice, FinderTimezone, FinderTitle, FinderToDate,
  Found, NotSearched, Searching, SlotTaken, finder_timezone_options,
  located_roster, roster_name,
}
import client/page/meetings/time_display.{
  type TimeDisplay, LocalTime, OriginTime, attendee_local_time, resolve_offset,
  slot_local_start,
}
import client/page/meetings/update.{
  type Msg, FinderAllAdded, FinderAttendanceSet, FinderAttendeeAdded,
  FinderAttendeeQueryChanged, FinderAttendeeRemoved, FinderCancelled,
  FinderFieldEdited, FinderFillFromProjectRequested, FinderSearchRequested,
  FinderSlotBooked,
}
import client/time
import client/ui/atoms
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/location/view.{type EngineerLocation} as location_view
import shared/meeting/command.{Optional, Required}
import shared/meeting/view.{type CandidateSlot, type SlotAttendee} as meeting_view
import shared/roster/view.{type Ref} as roster_view

pub fn view_finder_modal(
  finder: Option(FinderForm),
  roster: List(EngineerLocation),
  projects: List(Ref),
  time_display: TimeDisplay,
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
          view_finder_results(form, time_display),
        ]),
      )
  }
}

/// The criteria column grouped under guided section headings (Title/Attendees/
/// Dates/Duration/Timezone) mirroring the app's `wizard__card` section style. A
/// single-field section drops that field's own micro-label (the heading above
/// already names it, via `finder_bare_field`); a multi-field section keeps each
/// field's own label to tell its fields apart (Dates' From/To).
fn view_finder_criteria(
  form: FinderForm,
  roster: List(EngineerLocation),
  projects: List(Ref),
) -> Element(Msg) {
  html.div([attribute.class("finder__criteria")], [
    finder_section("Title", [
      finder_bare_field(FinderTitle, form.title, "text", "Title"),
    ]),
    finder_section("Attendees", [
      view_finder_attendee_builder(form, roster),
      view_finder_project_fill(form, projects),
    ]),
    finder_section("Dates", [
      html.div([attribute.class("finder__row")], [
        finder_field("From", FinderFromDate, form.from_date, "date"),
        finder_field("To", FinderToDate, form.to_date, "date"),
      ]),
    ]),
    finder_section("Duration", [
      finder_bare_field(
        FinderDurationMinutes,
        form.duration_minutes,
        "text",
        "Duration (minutes)",
      ),
    ]),
    finder_section("Timezone", [view_finder_timezone(form, roster)]),
    finder_error(form.error),
    atoms.button(
      label: "Find windows",
      kind: atoms.Primary,
      size: atoms.Medium,
      on_press: FinderSearchRequested,
    ),
  ])
}

fn finder_section(title: String, body: List(Element(Msg))) -> Element(Msg) {
  html.section([attribute.class("wizard__card")], [
    html.h3([attribute.class("wizard__card-title")], [html.text(title)]),
    ..body
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

/// A `finder_field` without its own visible micro-label — for a section whose
/// heading already names its one field; `aria_label` still carries the
/// accessible name so `getByLabel` keeps resolving it.
fn finder_bare_field(
  field: FinderField,
  value: String,
  input_type: String,
  aria_label: String,
) -> Element(Msg) {
  html.label([attribute.class("op-form__field")], [
    html.input([
      attribute.type_(input_type),
      attribute.attribute("aria-label", aria_label),
      attribute.value(value),
      event.on_input(fn(value) { FinderFieldEdited(field, value) }),
    ]),
  ])
}

/// The `Timezone` select: options are `finder_timezone_options` (the selected
/// attendees' deduped zones plus `UTC` last); no visible micro-label since the
/// `Timezone` section heading already names it.
fn view_finder_timezone(
  form: FinderForm,
  roster: List(EngineerLocation),
) -> Element(Msg) {
  let options = finder_timezone_options(form.attendees, roster)
  html.label([attribute.class("op-form__field")], [
    html.select(
      [
        attribute.attribute("aria-label", "Timezone"),
        event.on_change(fn(value) { FinderFieldEdited(FinderTimezone, value) }),
      ],
      list.map(options, fn(timezone) {
        html.option(
          [
            attribute.value(timezone),
            attribute.selected(timezone == form.timezone),
          ],
          timezone,
        )
      }),
    ),
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

/// One attendee row, mirroring the meetings table's one-line shape: name, the
/// attendance pill toggle (pure `FinderForm` state — no command dispatched
/// until the wizard books), and a name-scoped Remove icon button.
fn view_finder_current_attendee(
  attendee: Attendee,
  located: List(EngineerLocation),
) -> Element(Msg) {
  let finder.Attendee(engineer_id:, attendance:) = attendee
  let name = roster_name(located, engineer_id)
  html.div(
    [
      attribute.class("attendee-row"),
      attribute.role("listitem"),
      attribute.aria_label(name),
    ],
    [
      html.span([attribute.class("attendee-row__name")], [html.text(name)]),
      attendance_toggle_button(
        fn(flipped) { FinderAttendanceSet(engineer_id, flipped) },
        attendance,
      ),
      atoms.icon_button(
        label: "Remove " <> name,
        icon: icons.remove(),
        tone: atoms.IconPlain,
        on_press: FinderAttendeeRemoved(engineer_id),
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

fn view_finder_results(
  form: FinderForm,
  time_display: TimeDisplay,
) -> Element(Msg) {
  html.div([attribute.class("finder__results")], case form.results {
    NotSearched -> [
      atoms.empty_state(message: "Search to see available windows."),
    ]
    Searching -> [atoms.empty_state(message: "Searching…")]
    Found(slots:) -> [view_finder_slots(slots, time_display)]
    SlotTaken(slots:) -> [
      html.p([attribute.class("finder__notice")], [
        html.text("That slot was just taken — here are fresh times."),
      ]),
      view_finder_slots(slots, time_display),
    ]
  })
}

/// The candidate-slot list: `role="list"` over a named region ("Available
/// windows") so e2e can scope past the criteria column's own attendee
/// `role="list"`s, or the empty-state message when the search returned none.
fn view_finder_slots(
  slots: List(CandidateSlot),
  time_display: TimeDisplay,
) -> Element(Msg) {
  case slots {
    [] -> atoms.empty_state(message: "No windows found for these criteria.")
    _ ->
      html.div(
        [
          attribute.class("finder__slots"),
          attribute.role("list"),
          attribute.aria_label("Available windows"),
        ],
        list.map(slots, view_finder_slot(_, time_display)),
      )
  }
}

/// One candidate slot: `role="listitem"` with an accessible name naming its
/// start/end (the same "date HH:MM–HH:MM" the slot's own header renders) so
/// e2e can locate one slot without depending on `.finder-slot`. `OriginTime`
/// renders the start/end in the searched zone (`viewer_offset_minutes` —
/// today's rendering, no zone name since the Timezone select already names
/// it); `LocalTime` renders them in the browser's own zone, with that zone
/// named beneath so it reads as distinct from the searched zone above it.
fn view_finder_slot(
  slot: CandidateSlot,
  time_display: TimeDisplay,
) -> Element(Msg) {
  let meeting_view.CandidateSlot(
    starts_at:,
    ends_at:,
    attendees:,
    viewer_offset_minutes:,
  ) = slot
  let browser_offset_minutes = browser_time.timezone_offset_minutes(starts_at)
  let offset =
    resolve_offset(time_display, viewer_offset_minutes, browser_offset_minutes)
  let #(date, starts_local) = slot_local_start(starts_at, offset)
  let ends_local = time_display.local_time(ends_at, offset)
  let when = time.format_date(date) <> " " <> starts_local <> "–" <> ends_local
  html.div(
    [
      attribute.class("finder-slot"),
      attribute.role("listitem"),
      attribute.aria_label(when),
    ],
    [
      html.div([attribute.class("finder-slot__when")], [
        html.div([], [html.text(when)]),
        view_finder_slot_zone(time_display),
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
    ],
  )
}

/// The slot header's own zone sub-line — `LocalTime` mode only, naming the
/// browser zone the start/end above it were just rendered in; `OriginTime`
/// shows none (the searched zone is already named by the wizard's own
/// Timezone select).
fn view_finder_slot_zone(time_display: TimeDisplay) -> Element(Msg) {
  case time_display {
    OriginTime -> element.none()
    LocalTime ->
      html.div([attribute.class("cell-sub")], [
        html.text("(" <> browser_time.browser_timezone() <> ")"),
      ])
  }
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

/// The chip-button shared by the table's attendance toggle and the finder's
/// attendee-row pill toggle: the flipped `Attendance` plus its caption/label/
/// tone, handed to `to_msg` to become each caller's own message.
pub fn attendance_toggle_button(
  to_msg: fn(command.Attendance) -> Msg,
  attendance: command.Attendance,
) -> Element(Msg) {
  let #(flipped, text, toggle_label, tone) = case attendance {
    Required -> #(Optional, "Required", "Make optional", atoms.Neutral)
    Optional -> #(Required, "Optional", "Make required", atoms.Accent)
  }
  atoms.chip_button(
    label: toggle_label,
    text:,
    tone:,
    on_press: to_msg(flipped),
  )
}
