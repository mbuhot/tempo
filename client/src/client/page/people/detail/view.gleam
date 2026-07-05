//// The People detail's views: the header with its action row, the
//// Overview/Skills tabs, the allocations/location/availability/timesheet
//// panels (and the availability panel's bespoke weekly-hours editor modal),
//// the skill matrix with capability rollups and recent assessments, and the
//// contact/banking/employment side panels.

import client/page/people/detail/op_form.{op_launch, view_op_modal}
import client/page/people/detail/update.{
  type AvailabilityData, type DayEdit, type LocationData, type Model, type Msg,
  type SkillsData, type Tab, type TimesheetData, type WeekForm,
  AvailabilityFailed, AvailabilityLoaded, AvailabilityLoading, BackClicked,
  CellEdited, DayEdit, DetailFailed, DetailLoaded, DetailLoading,
  FocusBlockRemoveOpened, LocationFailed, LocationLoaded, LocationLoading,
  Overview, Skills, SkillsFailed, SkillsLoaded, SkillsLoading, TabClicked,
  TimesheetFailed, TimesheetLoaded, TimesheetLoading, TimesheetSubmitted,
  WeekCancelled, WeekDayToggled, WeekEffectiveEdited, WeekEndsEdited, WeekOpened,
  WeekStartsEdited, WeekSubmitted, covering_location, covers_as_of, weekday_name,
}
import client/page/people/timesheet as timesheet_grid
import client/time
import client/ui/atoms
import client/ui/format
import client/ui/ops
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/allocation/view.{AllocationRow} as allocation_view
import shared/availability/view.{
  type DaySlot, type EngineerHoliday, type FocusBlockRecord, DaySlot,
  EngineerHoliday, FocusBlockRecord,
}
import shared/engineer/view.{
  type EngineerDetail, Employment, EngineerBanking, EngineerContact,
  EngineerDetail, EngineerEmergency,
} as engineer_view
import shared/leave/view.{LeaveBalance} as leave_view
import shared/location/view as location_view
import shared/money
import shared/skill/view as skill_view

// --- View -------------------------------------------------------------------

pub fn view(
  model: Model,
  permissions: Set(String),
  viewer_engineer_id: Option(Int),
) -> Element(Msg) {
  let back =
    html.a([attribute.class("back-link"), event.on_click(BackClicked)], [
      html.text("‹ All engineers"),
    ])
  case model.detail {
    DetailLoading -> column([back, atoms.empty_state("Loading engineer…")])
    DetailFailed(message:) ->
      column([
        back,
        atoms.empty_state("Could not load this engineer: " <> message),
      ])
    DetailLoaded(detail:) -> {
      let own = viewer_engineer_id == Some(detail.engineer_id)
      column([
        back,
        detail_head(detail, permissions, own),
        view_op_modal(model, model.op),
        view_tabs(model.tab),
        subpage(
          model.tab == Overview,
          detail_grid(
            detail,
            model.timesheet,
            model.location,
            model.availability,
            model.week_form,
            model.as_of,
            permissions,
            own,
          ),
        ),
        subpage(model.tab == Skills, skills_grid(model.skills, model.as_of)),
      ])
    }
  }
}

fn column(children: List(Element(Msg))) -> Element(Msg) {
  html.div([], children)
}

fn detail_head(
  detail: EngineerDetail,
  permissions: Set(String),
  own: Bool,
) -> Element(Msg) {
  let EngineerDetail(engineer_id:, name:, level:, allocations:, ..) = detail
  html.div([attribute.class("page-head")], [
    html.div([], [
      html.h1([attribute.class("detail__title")], [
        atoms.avatar(name:, category: engineer_id, class: "avatar"),
        html.text(name),
      ]),
      html.div([attribute.class("detail__subtitle")], [
        html.text(format.level_band(level)),
      ]),
      html.p([], [html.text(situation(allocations))]),
    ]),
    html.div([attribute.class("action-row")], [
      op_launch(permissions, own, ops.OpAssessSkill, "Assess skill", False),
      op_launch(permissions, own, ops.OpTakeLeave, "Take leave", True),
      op_launch(permissions, own, ops.OpRollOff, "Roll off", True),
      op_launch(permissions, own, ops.OpTerminateEmployment, "Terminate", True),
      op_launch(permissions, own, ops.OpPromote, "Promote", False),
    ]),
  ])
}

fn view_tabs(active: Tab) -> Element(Msg) {
  html.div([attribute.class("tabs")], [
    tab_button("Overview", Overview, active),
    tab_button("Skills", Skills, active),
  ])
}

fn tab_button(label: String, tab: Tab, active: Tab) -> Element(Msg) {
  let class = case tab == active {
    True -> "tabs__tab tabs__tab--active"
    False -> "tabs__tab"
  }
  html.button([attribute.class(class), event.on_click(TabClicked(tab))], [
    html.text(label),
  ])
}

fn subpage(active: Bool, body: Element(Msg)) -> Element(Msg) {
  let class = case active {
    True -> "subpage subpage--active"
    False -> "subpage"
  }
  html.div([attribute.class(class)], [body])
}

/// A one-line situation for the detail header: allocated to the active project(s)
/// or currently unassigned, derived from the allocations the server already flagged
/// `active` for the detail's as-of. The bundle carries no leave active-flag, so
/// leave is reflected only on the roster list.
fn situation(allocations: List(allocation_view.AllocationRow)) -> String {
  let active_projects =
    list.filter_map(allocations, fn(allocation) {
      case allocation {
        AllocationRow(project:, active: True, ..) -> Ok(project)
        _ -> Error(Nil)
      }
    })
  case active_projects {
    [] -> "Currently unassigned."
    titles -> "Allocated to " <> string_join(titles, " & ") <> "."
  }
}

fn detail_grid(
  detail: EngineerDetail,
  timesheet: TimesheetData,
  location: LocationData,
  availability: AvailabilityData,
  week_form: Option(WeekForm),
  as_of: calendar.Date,
  permissions: Set(String),
  own: Bool,
) -> Element(Msg) {
  html.div([attribute.class("detail-grid")], [
    html.div([], [
      allocations_panel(detail.allocations),
      timesheet_panel(timesheet, permissions, own),
    ]),
    html.div([], [
      location_panel(location, as_of, permissions, own),
      availability_panel(availability, permissions, own),
      view_week_modal(week_form),
      balance_panel(detail.balance),
      contact_panel(detail.contact, permissions, own),
      banking_panel(detail.banking, permissions, own),
      employment_panel(
        detail.employment,
        detail.level,
        detail.emergency,
        permissions,
        own,
      ),
    ]),
  ])
}

fn allocations_panel(
  allocations: List(allocation_view.AllocationRow),
) -> Element(Msg) {
  let rows = list.map(allocations, allocation_row)
  let body = case allocations {
    [] -> [atoms.empty_state("No allocations on record.")]
    _ -> [
      atoms.data_table(
        headers: [
          #("Project", False),
          #("Fraction", True),
          #("Period", False),
          #("State", False),
        ],
        rows:,
      ),
    ]
  }
  atoms.panel(title: "Allocations", count: "", right: [], body:)
}

fn allocation_row(allocation: allocation_view.AllocationRow) -> Element(Msg) {
  let AllocationRow(
    project_id:,
    project:,
    fraction:,
    valid_from:,
    valid_to:,
    active:,
  ) = allocation
  let #(variant, label) = case active {
    True -> #("active", "active")
    False -> #("ended", "ended")
  }
  html.tr([], [
    html.td([], [
      atoms.swatch(category: project_id, inline: True),
      html.text(project),
    ]),
    html.td([attribute.class("num")], [html.text(format.fraction(fraction))]),
    html.td([attribute.class("mono muted")], [
      html.text(time.iso_date(valid_from) <> " → " <> period_end(valid_to)),
    ]),
    html.td([], [atoms.pill(variant:, label:)]),
  ])
}

/// A period's end date, or "present" when it is open-ended (no upper bound).
fn period_end(valid_to: Option(calendar.Date)) -> String {
  case valid_to {
    Some(date) -> time.iso_date(date)
    None -> "present"
  }
}

// --- Location panel ----------------------------------------------------

/// The "Location & timezone" current card plus the "Location history" timeline,
/// stacked in the Overview grid's side column.
fn location_panel(
  location: LocationData,
  as_of: calendar.Date,
  permissions: Set(String),
  own: Bool,
) -> Element(Msg) {
  html.div([], [
    current_location_panel(location, as_of, permissions, own),
    location_history_panel(location, as_of),
  ])
}

fn current_location_panel(
  location: LocationData,
  as_of: calendar.Date,
  permissions: Set(String),
  own: Bool,
) -> Element(Msg) {
  let launcher = [
    op_launch(permissions, own, ops.OpSetLocation, "Set location", True),
  ]
  let body = case location {
    LocationLoading -> [atoms.empty_state("Loading location…")]
    LocationFailed(message:) -> [
      atoms.empty_state("Could not load the location: " <> message),
    ]
    LocationLoaded(records:) ->
      case covering_location(records, as_of) {
        Some(record) -> [current_location_body(record)]
        None -> [
          atoms.empty_state("No location set as of " <> time.format_date(as_of)),
        ]
      }
  }
  atoms.panel(title: "Location & timezone", count: "", right: launcher, body:)
}

fn current_location_body(record: location_view.LocationRecord) -> Element(Msg) {
  let location_view.LocationRecord(
    country:,
    region:,
    timezone:,
    utc_offset_minutes:,
    ..,
  ) = record
  let region_row = case region {
    Some(text) -> [atoms.kv(key: "Region", value: text, mono: False)]
    None -> []
  }
  let rows =
    [atoms.kv(key: "Country", value: country, mono: False)]
    |> list.append(region_row)
    |> list.append([
      atoms.kv(key: "Timezone", value: timezone, mono: True),
      atoms.kv(
        key: "Offset as-of",
        value: time.utc_offset(utc_offset_minutes),
        mono: True,
      ),
    ])
  html.div([attribute.class("pad-detail")], [
    html.div([attribute.class("kv")], rows),
  ])
}

fn location_history_panel(
  location: LocationData,
  as_of: calendar.Date,
) -> Element(Msg) {
  case location {
    LocationLoading ->
      atoms.panel(title: "Location history", count: "", right: [], body: [
        atoms.empty_state("Loading location history…"),
      ])
    LocationFailed(message:) ->
      atoms.panel(title: "Location history", count: "", right: [], body: [
        atoms.empty_state("Could not load location history: " <> message),
      ])
    LocationLoaded(records:) -> {
      let body = case records {
        [] -> [atoms.empty_state("No location history on record.")]
        _ -> [
          atoms.data_table(
            headers: [
              #("Location", False),
              #("Timezone", False),
              #("Period", False),
              #("", False),
            ],
            rows: list.map(list.reverse(records), location_history_row(_, as_of)),
          ),
        ]
      }
      atoms.panel(
        title: "Location history",
        count: int.to_string(list.length(records)),
        right: [],
        body:,
      )
    }
  }
}

fn location_history_row(
  record: location_view.LocationRecord,
  as_of: calendar.Date,
) -> Element(Msg) {
  let location_view.LocationRecord(
    country:,
    region:,
    timezone:,
    valid_from:,
    valid_to:,
    ..,
  ) = record
  let flag = case covers_as_of(valid_from, valid_to, as_of) {
    True -> atoms.pill(variant: "active", label: "as-of")
    False -> element.none()
  }
  html.tr([], [
    html.td([], [
      html.text(country <> ", " <> option.unwrap(region, country)),
    ]),
    html.td([attribute.class("mono")], [html.text(timezone)]),
    html.td([attribute.class("mono muted")], [
      html.text(time.iso_date(valid_from) <> " → " <> period_end(valid_to)),
    ]),
    html.td([], [flag]),
  ])
}

// --- Availability panel ------------------------------------------------

/// The "Availability" panel: the as-of weekly working-hours grid, upcoming
/// focus blocks (in the engineer's local time when an offset is known), and
/// upcoming regional holidays, plus the "Edit hours" launcher that opens the
/// bespoke weekly editor.
fn availability_panel(
  availability: AvailabilityData,
  permissions: Set(String),
  own: Bool,
) -> Element(Msg) {
  let edit_hours =
    ops.when_permitted(
      ops.permit(permissions, own:, kind: ops.OpAddFocusBlock),
      fn(_granted) {
        atoms.button(
          label: "Edit hours",
          kind: atoms.Ghost,
          size: atoms.Small,
          on_press: WeekOpened,
        )
      },
    )
  let launcher = [
    edit_hours,
    op_launch(permissions, own, ops.OpAddFocusBlock, "Add focus block", True),
  ]
  let body = case availability {
    AvailabilityLoading -> [atoms.empty_state("Loading availability…")]
    AvailabilityFailed(message:) -> [
      atoms.empty_state("Could not load availability: " <> message),
    ]
    AvailabilityLoaded(record:) -> [
      week_grid(record.week),
      focus_block_list(record.focus_blocks, permissions, own),
      holiday_strip(record.holidays),
    ]
  }
  atoms.panel(title: "Availability", count: "", right: launcher, body:)
}

fn week_grid(week: List(DaySlot)) -> Element(Msg) {
  html.div(
    [attribute.class("pad-detail kv")],
    list.map(week, fn(slot) {
      let DaySlot(weekday:, starts:, ends:) = slot
      atoms.kv(
        key: weekday_name(weekday),
        value: day_slot_label(starts, ends),
        mono: True,
      )
    }),
  )
}

fn day_slot_label(starts: Option(String), ends: Option(String)) -> String {
  case starts, ends {
    Some(starts), Some(ends) -> starts <> "–" <> ends
    _, _ -> "—"
  }
}

fn focus_block_list(
  focus_blocks: List(FocusBlockRecord),
  permissions: Set(String),
  own: Bool,
) -> Element(Msg) {
  case focus_blocks {
    [] -> element.none()
    blocks ->
      html.div([attribute.class("pad-block kv")], [
        html.span([attribute.class("eyebrow")], [html.text("Focus blocks")]),
        ..list.map(blocks, focus_block_row(_, permissions, own))
      ])
  }
}

fn focus_block_row(
  record: FocusBlockRecord,
  permissions: Set(String),
  own: Bool,
) -> Element(Msg) {
  let FocusBlockRecord(id:, title:, starts_at:, offset_minutes:, ..) = record
  let time_label = case offset_minutes {
    Some(offset) -> local_time(starts_at, offset)
    None -> starts_at
  }
  html.div([attribute.class("list-row")], [
    atoms.kv(key: title, value: time_label, mono: True),
    ops.when_permitted(
      ops.permit(permissions, own:, kind: ops.OpRemoveFocusBlock),
      fn(granted) {
        atoms.button(
          label: "Remove",
          kind: atoms.Ghost,
          size: atoms.Small,
          on_press: FocusBlockRemoveOpened(permit: granted, focus_block_id: id),
        )
      },
    ),
  ])
}

fn holiday_strip(holidays: List(EngineerHoliday)) -> Element(Msg) {
  case holidays {
    [] -> element.none()
    rows ->
      html.div([attribute.class("pad-block kv")], [
        html.span([attribute.class("eyebrow")], [html.text("Holidays")]),
        ..list.map(rows, holiday_row)
      ])
  }
}

fn holiday_row(holiday: EngineerHoliday) -> Element(Msg) {
  let EngineerHoliday(holiday_on:, name:) = holiday
  atoms.kv(key: name, value: time.format_date(holiday_on), mono: True)
}

/// An ISO-8601 UTC instant's wall-clock "HH:MM" shifted by `offset_minutes`
/// (minutes east of UTC), mirroring `page/meetings`'s `local_time`.
fn local_time(starts_at_iso: String, offset_minutes: Int) -> String {
  let assert Ok(instant) = timestamp.parse_rfc3339(starts_at_iso)
  let shifted = timestamp.add(instant, duration.minutes(offset_minutes))
  let #(_date, time_of_day) =
    timestamp.to_calendar(shifted, calendar.utc_offset)
  pad2(time_of_day.hours) <> ":" <> pad2(time_of_day.minutes)
}

fn pad2(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}

/// The bespoke weekly-hours editor as a centred modal — shown only while
/// `week_form` is `Some`. Mirrors `atoms.modal`'s chrome but hosts a 7-row grid
/// of checkbox + start/end fields instead of the generic `OpField` slots.
fn view_week_modal(week_form: Option(WeekForm)) -> Element(Msg) {
  case week_form {
    None -> element.none()
    Some(form) ->
      atoms.modal(
        title: "Edit weekly hours",
        error: option.unwrap(form.error, ""),
        body: week_form_fields(form),
        on_cancel: WeekCancelled,
        on_confirm: WeekSubmitted,
        confirm_label: "Save hours",
      )
  }
}

fn week_form_fields(form: WeekForm) -> List(Element(Msg)) {
  [
    html.label([attribute.class("op-form__field")], [
      html.span([], [html.text("Effective")]),
      html.input([
        attribute.type_("date"),
        attribute.attribute("aria-label", "Effective"),
        attribute.value(form.effective),
        event.on_input(WeekEffectiveEdited),
      ]),
    ]),
    html.div(
      [attribute.class("pad-block")],
      list.index_map(form.days, week_day_row),
    ),
  ]
}

fn week_day_row(day: DayEdit, weekday: Int) -> Element(Msg) {
  let DayEdit(working:, starts:, ends:) = day
  html.div([attribute.class("op-form__field")], [
    html.label([], [
      html.input([
        attribute.type_("checkbox"),
        attribute.checked(working),
        event.on_check(fn(_checked) { WeekDayToggled(weekday) }),
      ]),
      html.text(" " <> weekday_name(weekday)),
    ]),
    html.input([
      attribute.type_("text"),
      attribute.attribute("aria-label", weekday_name(weekday) <> " starts"),
      attribute.value(starts),
      attribute.placeholder("09:00"),
      event.on_input(fn(value) { WeekStartsEdited(weekday, value) }),
    ]),
    html.input([
      attribute.type_("text"),
      attribute.attribute("aria-label", weekday_name(weekday) <> " ends"),
      attribute.value(ends),
      attribute.placeholder("17:00"),
      event.on_input(fn(value) { WeekEndsEdited(weekday, value) }),
    ]),
  ])
}

// --- Timesheet grid ---------------------------------------------------------

/// The detail's timesheet panel: its Loading/Failed guards, delegating the loaded
/// week's grid to the self-contained `page/people/timesheet` module. The grid's two
/// actions (submit the week, edit a cell) are wired from this module's `Msg`.
fn timesheet_panel(
  timesheet: TimesheetData,
  permissions: Set(String),
  own: Bool,
) -> Element(Msg) {
  case timesheet {
    TimesheetLoading ->
      atoms.panel(title: "Timesheet", count: "", right: [], body: [
        atoms.empty_state("Loading week…"),
      ])
    TimesheetFailed(message:) ->
      atoms.panel(title: "Timesheet", count: "", right: [], body: [
        atoms.empty_state("Could not load the timesheet: " <> message),
      ])
    TimesheetLoaded(week:, edits:) ->
      timesheet_grid.view(
        week,
        edits,
        on_submit: TimesheetSubmitted,
        on_cell_edit: fn(project_id, day, value) {
          CellEdited(project_id:, day:, value:)
        },
        permit: ops.permit(permissions, own:, kind: ops.OpLogWeek),
      )
  }
}

// --- Skills tab ---------------------------------------------------------

/// The Skills tab: its Loading/Failed guards, otherwise the skill-matrix panel
/// beside the capability rollup and recent-assessments panels.
fn skills_grid(skills: SkillsData, as_of: calendar.Date) -> Element(Msg) {
  case skills {
    SkillsLoading ->
      atoms.panel(title: "Skill matrix", count: "", right: [], body: [
        atoms.empty_state("Loading skills…"),
      ])
    SkillsFailed(message:) ->
      atoms.panel(title: "Skill matrix", count: "", right: [], body: [
        atoms.empty_state("Could not load the skill matrix: " <> message),
      ])
    SkillsLoaded(skills: skill_view.EngineerSkills(matrix:, rollups:, recent:)) ->
      html.div([attribute.class("detail-grid")], [
        html.div([], [skill_matrix_panel(matrix, as_of)]),
        html.div([], [rollup_panel(rollups), recent_panel(recent)]),
      ])
  }
}

fn skill_matrix_panel(
  matrix: List(skill_view.SkillAssessment),
  as_of: calendar.Date,
) -> Element(Msg) {
  let note =
    html.span([attribute.class("note")], [
      html.text("as of " <> time.format_date(as_of)),
    ])
  let body = case matrix {
    [] -> [atoms.empty_state("No skills in the taxonomy yet.")]
    rows -> [
      html.div(
        [attribute.class("skill-matrix"), attribute.role("list")],
        list.map(rows, skill_matrix_row),
      ),
      legend(),
    ]
  }
  atoms.panel(
    title: "Skill matrix",
    count: int.to_string(list.length(matrix)) <> " skills",
    right: [note],
    body:,
  )
}

fn skill_matrix_row(assessment: skill_view.SkillAssessment) -> Element(Msg) {
  let skill_view.SkillAssessment(name:, level:, capability_names:, ..) =
    assessment
  html.div(
    [
      attribute.class("skill-matrix__row"),
      attribute.role("listitem"),
      attribute.aria_label(name),
    ],
    [
      html.div([], [
        html.div([attribute.class("skill-matrix__name")], [html.text(name)]),
        html.div(
          [attribute.class("skill-matrix__caps")],
          list.map(capability_names, fn(capability) {
            atoms.chip(label: capability, tone: atoms.Neutral)
          }),
        ),
      ]),
      lvl_badge(level),
      html.div([attribute.class("skill-matrix__meaning")], [
        html.text(level_meaning(level)),
      ]),
    ],
  )
}

/// A skill's level badge: 0 renders the muted `lvl-badge--0` variant labelled
/// "0", levels 1..4 render "L<n>" tinted by the seniority-ramp step the design
/// assigns that level (1→2, 2→3, 3→5, 4→7).
fn lvl_badge(level: Int) -> Element(Msg) {
  case level {
    0 ->
      html.span([attribute.class("lvl-badge lvl-badge--0")], [html.text("0")])
    _ ->
      html.span(
        [
          attribute.class("lvl-badge"),
          attribute.style("background", atoms.lvl_color(badge_step(level))),
        ],
        [html.text("L" <> int.to_string(level))],
      )
  }
}

fn badge_step(level: Int) -> Int {
  case level {
    1 -> 2
    2 -> 3
    3 -> 5
    4 -> 7
    _ -> 1
  }
}

/// The human meaning of a skill level, shown beside its badge in the matrix row.
fn level_meaning(level: Int) -> String {
  case level {
    0 -> "none"
    1 -> "learning"
    2 -> "with supervision"
    3 -> "independently capable"
    4 -> "expert · can teach"
    _ -> ""
  }
}

/// The fixed scale legend beneath the skill matrix, one entry per level 0..4.
fn legend() -> Element(Msg) {
  html.div([attribute.class("legend")], [
    html.span([attribute.class("eyebrow")], [html.text("Scale")]),
    legend_item("0", "none", None),
    legend_item("1", "learning", Some(2)),
    legend_item("2", "with supervision", Some(3)),
    legend_item("3", "independent", Some(5)),
    legend_item("4", "expert · can teach", Some(7)),
  ])
}

fn legend_item(
  label: String,
  meaning: String,
  step: Option(Int),
) -> Element(Msg) {
  let badge = case step {
    None ->
      html.span([attribute.class("lvl-badge lvl-badge--0")], [
        html.text(label),
      ])
    Some(step) ->
      html.span(
        [
          attribute.class("lvl-badge"),
          attribute.style("background", atoms.lvl_color(step)),
        ],
        [html.text(label)],
      )
  }
  html.span([attribute.class("legend__item")], [
    badge,
    html.text(" " <> meaning),
  ])
}

fn rollup_panel(rollups: List(skill_view.CapabilityRollup)) -> Element(Msg) {
  atoms.panel(title: "Capability rollup", count: "", right: [], body: [
    html.div([attribute.class("pad-detail note")], [
      html.text("weighted average of constituent skills"),
    ]),
    html.div([attribute.role("list")], list.map(rollups, rollup_row)),
  ])
}

fn rollup_row(rollup: skill_view.CapabilityRollup) -> Element(Msg) {
  let skill_view.CapabilityRollup(name:, proficiency:, ..) = rollup
  let fill_pct =
    int.clamp(float_round(proficiency /. 4.0 *. 100.0), min: 0, max: 100)
  let rounded_level = int.clamp(float_round(proficiency), min: 0, max: 4)
  let ramp_step = badge_step(rounded_level)
  html.div(
    [
      attribute.class("rollup"),
      attribute.role("listitem"),
      attribute.aria_label(name),
    ],
    [
      html.div([attribute.class("rollup__name")], [html.text(name)]),
      html.div([attribute.class("rollup__value")], [
        html.text(one_decimal(proficiency)),
      ]),
      html.div([attribute.class("rollup__track")], [
        html.div(
          [
            attribute.class("rollup__fill"),
            attribute.style("width", int.to_string(fill_pct) <> "%"),
            attribute.style("background", atoms.lvl_color(ramp_step)),
          ],
          [],
        ),
      ]),
    ],
  )
}

fn recent_panel(recent: List(skill_view.AssessmentVersion)) -> Element(Msg) {
  let body = case recent {
    [] -> [atoms.empty_state("No assessments on record.")]
    versions -> [
      html.div(
        [attribute.class("pad-block kv")],
        list.map(versions, recent_row),
      ),
    ]
  }
  atoms.panel(title: "Recent assessments", count: "", right: [], body:)
}

fn recent_row(version: skill_view.AssessmentVersion) -> Element(Msg) {
  let skill_view.AssessmentVersion(skill_name:, level:, valid_from:, ..) =
    version
  atoms.kv(
    key: skill_name <> " → L" <> int.to_string(level),
    value: time.format_date(valid_from),
    mono: True,
  )
}

// --- Side panels ------------------------------------------------------------

fn balance_panel(balance: leave_view.LeaveBalance) -> Element(Msg) {
  let LeaveBalance(annual:, sick:, ..) = balance
  atoms.panel(title: "Leave balance", count: "", right: [], body: [
    html.div([attribute.class("pad-block")], [
      balance_bar("Annual", annual, 20.0),
      balance_bar("Sick", sick, 10.0),
    ]),
  ])
}

fn balance_bar(label: String, value: Float, max: Float) -> Element(Msg) {
  let pct = int.min(float_round(value /. max *. 100.0), 100)
  html.div([attribute.class("balance")], [
    html.div([attribute.class("balance__head")], [
      html.span([attribute.class("eyebrow")], [html.text(label)]),
      html.span([attribute.class("balance__value")], [
        html.text(format.days(value) <> " days"),
      ]),
    ]),
    html.div([attribute.class("spark spark--lg")], [
      html.i([attribute.style("width", int.to_string(pct) <> "%")], []),
    ]),
  ])
}

fn contact_panel(
  contact: engineer_view.EngineerContact,
  permissions: Set(String),
  own: Bool,
) -> Element(Msg) {
  let EngineerContact(name:, email:, phone:, postal_address:, ..) = contact
  let _ = name
  atoms.panel(
    title: "Contact",
    count: "",
    right: [op_launch(permissions, own, ops.OpUpdateContact, "Edit", True)],
    body: [
      html.div([attribute.class("pad-detail")], [
        html.div([attribute.class("kv")], [
          atoms.kv(key: "Email", value: email, mono: False),
          atoms.kv(key: "Phone", value: phone, mono: True),
          atoms.kv(key: "Address", value: postal_address, mono: False),
        ]),
      ]),
    ],
  )
}

fn banking_panel(
  banking: engineer_view.EngineerBanking,
  permissions: Set(String),
  own: Bool,
) -> Element(Msg) {
  let EngineerBanking(bank:, branch:, account_no:, account_name:, ..) = banking
  atoms.panel(
    title: "Banking",
    count: "",
    right: [op_launch(permissions, own, ops.OpUpdateBanking, "Edit", True)],
    body: [
      html.div([attribute.class("pad-detail")], [
        html.div([attribute.class("kv")], [
          atoms.kv(key: "Bank", value: bank, mono: False),
          atoms.kv(key: "BSB", value: branch, mono: True),
          atoms.kv(key: "Account", value: account_no, mono: True),
          atoms.kv(key: "Name", value: account_name, mono: False),
        ]),
      ]),
    ],
  )
}

fn employment_panel(
  employment: engineer_view.Employment,
  level: Int,
  emergency: Option(engineer_view.EngineerEmergency),
  permissions: Set(String),
  own: Bool,
) -> Element(Msg) {
  let Employment(started:, monthly_salary:, ..) = employment
  let emergency_line = case emergency {
    Some(EngineerEmergency(relation:, name:, phone:, ..)) ->
      name <> " (" <> relation <> ", " <> phone <> ")"
    None -> "Not on record"
  }
  atoms.panel(
    title: "Employment",
    count: "",
    right: [
      op_launch(permissions, own, ops.OpUpdateEmergency, "Emergency", True),
    ],
    body: [
      html.div([attribute.class("pad-detail")], [
        html.div([attribute.class("kv")], [
          atoms.kv(key: "Started", value: time.iso_date(started), mono: True),
          atoms.kv(key: "Level", value: format.level_band(level), mono: False),
          atoms.kv(
            key: "Monthly salary",
            value: format.money(money.to_float(monthly_salary)),
            mono: True,
          ),
          atoms.kv(key: "Emergency", value: emergency_line, mono: False),
        ]),
      ]),
    ],
  )
}

// --- Small helpers ----------------------------------------------------------

fn float_round(value: Float) -> Int {
  float.round(value)
}

fn string_join(parts: List(String), with separator: String) -> String {
  string.join(parts, separator)
}

/// A float rounded to one decimal place ("3.75" -> "3.8"), for the rollup panel's
/// proficiency figure.
fn one_decimal(value: Float) -> String {
  float.to_string(float.to_precision(value, 1))
}
