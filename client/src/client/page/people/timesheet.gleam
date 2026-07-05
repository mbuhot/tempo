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
import client/ui/atoms
import client/ui/format
import client/ui/ops
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
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
  on_submit on_submit: fn(ops.Permit) -> msg,
  on_cell_edit on_cell_edit: fn(Int, calendar.Date, String) -> msg,
  permit permit: Result(ops.Permit, Nil),
) -> Element(msg) {
  let permitted = result.is_ok(permit)
  atoms.panel(
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
  on_submit: fn(ops.Permit) -> msg,
  permit: Result(ops.Permit, Nil),
) -> Element(msg) {
  case week.rows {
    [] -> element.none()
    _ ->
      ops.when_permitted(permit, fn(granted) {
        atoms.button(
          label: "Log week",
          kind: atoms.Primary,
          size: atoms.Small,
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
    html.tr(
      [],
      list.flatten([
        [html.th([], [html.text("Project")])],
        list.map(week.days, day_header),
        [html.th([], [html.text("Total")])],
      ]),
    )
  case week.rows {
    [] ->
      html.table([attribute.class("timesheet")], [
        html.thead([], [header]),
        html.tbody([], [
          html.tr([], [
            html.td([attribute.attribute("colspan", "9")], [
              atoms.empty_state("Nothing to log this week."),
            ]),
          ]),
        ]),
      ])
    rows ->
      html.table([attribute.class("timesheet")], [
        html.thead([], [header]),
        html.tbody(
          [],
          list.map(rows, fn(row) {
            row_view(row, edits, on_cell_edit, permitted)
          }),
        ),
        html.tfoot([], [totals_row(week, edits)]),
      ])
  }
}

/// The footer row: the per-day column totals (each project's hours summed down the
/// day) and the overall week total, all over the LIVE edited values.
fn totals_row(
  week: TimesheetWeek,
  edits: Dict(#(Int, Int), String),
) -> Element(msg) {
  let day_totals = column_totals(week, edits)
  html.tr(
    [],
    list.flatten([
      [html.td([], [html.text("Total")])],
      list.map(day_totals, fn(total) {
        html.td([attribute.class("timesheet__total")], [
          html.text(format.days(total)),
        ])
      }),
      [
        html.td([attribute.class("timesheet__total")], [
          html.text(format.days(float.sum(day_totals))),
        ]),
      ],
    ]),
  )
}

/// The hours in effect for a cell — the in-progress edit if one is typed, else the
/// persisted value — so the totals track what the user is currently entering.
fn cell_hours(
  project_id: Int,
  cell: TimesheetCell,
  edits: Dict(#(Int, Int), String),
) -> Float {
  let key = #(project_id, time.date_to_day_index(cell.date))
  case dict.get(edits, key) {
    Ok(typed) -> parse_hours(typed)
    Error(Nil) -> cell.hours
  }
}

/// Parse a cell's hours leniently: a plain integer ("8"), a decimal ("4.5"), or
/// anything else (blank / mid-edit) as zero.
fn parse_hours(text: String) -> Float {
  case float.parse(text) {
    Ok(hours) -> hours
    Error(Nil) ->
      case int.parse(text) {
        Ok(whole) -> int.to_float(whole)
        Error(Nil) -> 0.0
      }
  }
}

/// One total per day, summed down every project row (the columns line up with
/// `week.days`, so transpose the per-row cell hours and sum each column).
fn column_totals(
  week: TimesheetWeek,
  edits: Dict(#(Int, Int), String),
) -> List(Float) {
  week.rows
  |> list.map(fn(row) {
    list.map(row.cells, fn(cell) { cell_hours(row.project_id, cell, edits) })
  })
  |> list.transpose
  |> list.map(float.sum)
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
  html.tr(
    [],
    list.flatten([
      [
        html.td([], [
          atoms.swatch(category: project_id, inline: True),
          html.text(project),
        ]),
      ],
      list.map(cells, fn(cell) {
        cell_view(project_id, cell, edits, on_cell_edit, permitted)
      }),
      [
        html.td([attribute.class("timesheet__total")], [
          html.text(format.days(row_total(row, edits))),
        ]),
      ],
    ]),
  )
}

/// An engineer's total hours on one project across the week (over the live edited
/// values).
fn row_total(row: TimesheetWeekRow, edits: Dict(#(Int, Int), String)) -> Float {
  list.fold(row.cells, 0.0, fn(total, cell) {
    total +. cell_hours(row.project_id, cell, edits)
  })
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
      attribute.attribute("inputmode", "decimal"),
      event.on_input(fn(typed) {
        on_cell_edit(project_id, date, accept_hours(typed, value))
      }),
    ]),
  ])
}

/// Sanitize a typed cell value against the current one: strip every non-numeric
/// character (so the textbox accepts only digits and a single decimal point — no
/// `type=number` spinner) and reject a value over 24 hours by keeping the prior
/// value. A partial entry (empty, "2.", ".5") passes through so typing can
/// continue; the controlled input re-renders to whatever this returns, so a
/// rejected keystroke never sticks.
fn accept_hours(typed: String, current: String) -> String {
  let cleaned = keep_numeric(typed)
  case parse_hours_opt(cleaned) {
    Ok(hours) ->
      case hours <=. 24.0 {
        True -> cleaned
        False -> current
      }
    Error(Nil) -> cleaned
  }
}

/// Keep only digits and a single decimal point, dropping everything else.
fn keep_numeric(value: String) -> String {
  let kept =
    value
    |> string.to_graphemes
    |> list.filter(fn(char) { is_digit(char) || char == "." })
    |> string.concat
  case string.split(kept, ".") {
    [whole] -> whole
    [whole, frac, ..] -> whole <> "." <> frac
    [] -> ""
  }
}

fn is_digit(char: String) -> Bool {
  case char {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

/// Parse fully-numeric text to its hours; `Error` for empty or partial entries.
fn parse_hours_opt(text: String) -> Result(Float, Nil) {
  case float.parse(text) {
    Ok(hours) -> Ok(hours)
    Error(Nil) -> int.parse(text) |> result.map(int.to_float)
  }
}

/// A logged-hours value for display in a grid cell: empty when zero (so an
/// unlogged cell shows blank, matching the prototype), otherwise the number.
fn hours_display(hours: Float) -> String {
  case hours == 0.0 {
    True -> ""
    False -> format.days(hours)
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
