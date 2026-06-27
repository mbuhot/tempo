//// The People detail's editable weekly timesheet grid (FR-PE*), split out of
//// `client/page/people` so this self-contained sub-feature owns its own rendering.
//// It raises two user actions — editing a cell and submitting the week — handed in
//// as labelled callbacks, so `view` is generic over the host page's `msg` and
//// never needs the page's `Msg` type.
////
//// The page owns the load state (Loading/Failed) and the timesheet edits map; this
//// module renders one LOADED week: the project-by-day grid with per-cell inputs
//// (disabled where the engineer is not allocated) and the "Log week" submit.

import client/time
import client/ui
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/time/calendar
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/timesheet/view.{
  type TimesheetCell, type TimesheetWeek, type TimesheetWeekRow, TimesheetCell,
  TimesheetWeekRow,
}

/// Render a loaded `week` with its in-progress `edits`: the submit button and the
/// project/day grid. `on_submit` logs the week; `on_cell_edit(project_id, day,
/// value)` records a typed cell value.
pub fn view(
  week: TimesheetWeek,
  edits: Dict(#(Int, Int), String),
  on_submit on_submit: fn(ui.Permit) -> msg,
  on_cell_edit on_cell_edit: fn(Int, calendar.Date, String) -> msg,
  permit permit: Result(ui.Permit, Nil),
) -> Element(msg) {
  let permitted = result.is_ok(permit)
  ui.panel(
    title: "Timesheet",
    count: "week of " <> time.iso_date(week.week_start),
    right: [submit_week_button(week, on_submit, permit)],
    body: [
      html.div([attribute.class("pad-block")], [
        grid(week, edits, on_cell_edit, permitted),
      ]),
    ],
  )
}

fn submit_week_button(
  week: TimesheetWeek,
  on_submit: fn(ui.Permit) -> msg,
  permit: Result(ui.Permit, Nil),
) -> Element(msg) {
  case week.rows {
    [] -> element.none()
    _ ->
      ui.when_permitted(permit, fn(granted) {
        ui.button(
          label: "Log week",
          kind: ui.Primary,
          size: ui.Small,
          on_press: on_submit(granted),
        )
      })
  }
}

fn grid(
  week: TimesheetWeek,
  edits: Dict(#(Int, Int), String),
  on_cell_edit: fn(Int, calendar.Date, String) -> msg,
  permitted: Bool,
) -> Element(msg) {
  let header =
    html.tr([], [
      html.th([], [html.text("Project")]),
      ..list.map(week.days, day_header)
    ])
  let body = case week.rows {
    [] -> [
      html.tr([], [
        html.td([attribute.attribute("colspan", "8")], [
          ui.empty_state("Nothing to log this week."),
        ]),
      ]),
    ]
    rows ->
      list.map(rows, fn(row) { row_view(row, edits, on_cell_edit, permitted) })
  }
  html.table([attribute.class("timesheet")], [
    html.thead([], [header]),
    html.tbody([], body),
  ])
}

fn day_header(date: calendar.Date) -> Element(msg) {
  let weekday = day_of_week(date)
  let class = case weekday >= 5 {
    True -> "timesheet__weekend"
    False -> ""
  }
  html.th([attribute.class(class)], [
    html.text(weekday_label(weekday)),
    html.br([]),
    html.span([attribute.class("timesheet__daynum")], [
      html.text(int.to_string(date.day)),
    ]),
  ])
}

fn row_view(
  row: TimesheetWeekRow,
  edits: Dict(#(Int, Int), String),
  on_cell_edit: fn(Int, calendar.Date, String) -> msg,
  permitted: Bool,
) -> Element(msg) {
  let TimesheetWeekRow(project_id:, project:, cells:) = row
  html.tr([], [
    html.td([], [
      ui.swatch(category: project_id, inline: True),
      html.text(project),
    ]),
    ..list.map(cells, fn(cell) {
      cell_view(project_id, cell, edits, on_cell_edit, permitted)
    })
  ])
}

fn cell_view(
  project_id: Int,
  cell: TimesheetCell,
  edits: Dict(#(Int, Int), String),
  on_cell_edit: fn(Int, calendar.Date, String) -> msg,
  permitted: Bool,
) -> Element(msg) {
  let TimesheetCell(date:, allocated:, hours:) = cell
  let key = #(project_id, time.date_to_day_index(date))
  let value = case dict.get(edits, key) {
    Ok(typed) -> typed
    Error(Nil) -> hours_display(hours)
  }
  let #(class, disabled) = case allocated && permitted {
    True -> #("timesheet__cell", False)
    False -> #("timesheet__cell timesheet__cell--disabled", True)
  }
  html.td([attribute.class(class)], [
    html.input([
      attribute.value(value),
      attribute.disabled(disabled),
      attribute.attribute("aria-label", "Hours"),
      event.on_input(fn(value) { on_cell_edit(project_id, date, value) }),
    ]),
  ])
}

/// A logged-hours value for display in a grid cell: empty when zero (so an
/// unlogged cell shows blank, matching the prototype), otherwise the number.
fn hours_display(hours: Float) -> String {
  case hours == 0.0 {
    True -> ""
    False -> ui.days(hours)
  }
}

/// The Monday-relative weekday index of a date (0 = Mon … 6 = Sun); unix-day 0 is
/// a Thursday (ISO weekday 4), so `(index + 3) mod 7` puts Monday at 0.
fn day_of_week(date: calendar.Date) -> Int {
  let index = time.date_to_day_index(date)
  int.modulo(index + 3, 7) |> result.unwrap(0)
}

fn weekday_label(weekday: Int) -> String {
  case weekday {
    0 -> "Mon"
    1 -> "Tue"
    2 -> "Wed"
    3 -> "Thu"
    4 -> "Fri"
    5 -> "Sat"
    _ -> "Sun"
  }
}
