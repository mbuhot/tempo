//// The People list's roster table (FR-PE*), split out of `client/page/people` so
//// the roster presentation lives apart from the list page's chrome (the page head
//// and the contextual op modal, which stay in the page). It raises one user action
//// — opening a person — handed in as a labelled callback, so `panel` is generic
//// over the host page's `msg`.

import client/ui
import gleam/int
import gleam/list
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/types.{
  type PersonRow, type RosterStatus, PersonRow, RosterOnLeave, RosterOnProjects,
  RosterUnassigned,
}

/// The roster panel: a table of everyone employed on the date (engineer, level,
/// status, allocation, leave balance, day rate), or an empty-state when none are.
/// `on_open(engineer_id)` is raised when a row is clicked.
pub fn panel(
  people: List(PersonRow),
  on_open on_open: fn(Int) -> msg,
) -> Element(msg) {
  let rows = list.map(people, fn(person) { roster_row(person, on_open) })
  let body = case people {
    [] -> [ui.empty_state("No engineers employed on this date.")]
    _ -> [
      ui.data_table(
        headers: [
          #("Engineer", False),
          #("Level", False),
          #("Status", False),
          #("Allocated", True),
          #("Annual lv.", True),
          #("Day rate", True),
        ],
        rows:,
      ),
    ]
  }
  ui.panel(
    title: "Roster",
    count: int.to_string(list.length(people)),
    right: [],
    body:,
  )
}

fn roster_row(person: PersonRow, on_open: fn(Int) -> msg) -> Element(msg) {
  let PersonRow(
    engineer_id:,
    name:,
    email:,
    level:,
    status:,
    allocated_fraction:,
    annual_balance:,
    day_rate:,
  ) = person
  let #(variant, label) = status_pill(status)
  let allocated = case status {
    RosterOnProjects(..) -> ui.fraction(allocated_fraction)
    _ -> "—"
  }
  html.tr([attribute.class("clickable"), event.on_click(on_open(engineer_id))], [
    html.td([], [name_cell(engineer_id, name, email)]),
    html.td([], [
      html.span([attribute.class("level-pill")], [
        html.text(ui.level_band(level)),
      ]),
    ]),
    html.td([], [ui.pill(variant:, label:)]),
    html.td([attribute.class("num")], [html.text(allocated)]),
    html.td([attribute.class("num")], [html.text(ui.days(annual_balance))]),
    html.td([attribute.class("num")], [html.text(ui.money(day_rate))]),
  ])
}

fn name_cell(engineer_id: Int, name: String, email: String) -> Element(msg) {
  html.div([attribute.class("cell-name")], [
    ui.avatar(name:, category: engineer_id, class: "avatar"),
    html.div([], [
      html.div([attribute.class("cell-name__name")], [html.text(name)]),
      html.div([attribute.class("cell-sub")], [html.text(email)]),
    ]),
  ])
}

/// The pill variant and label for a roster status: on-projects is "active" with
/// the project titles, on-leave is "issued" (the amber pill) with the leave
/// kind, unassigned is "ended". Mirrors the prototype's status classes.
fn status_pill(status: RosterStatus) -> #(String, String) {
  case status {
    RosterOnProjects(projects:) -> #("active", join_titles(projects))
    RosterOnLeave(kind:) -> #("issued", "On " <> kind <> " leave")
    RosterUnassigned -> #("ended", "Unassigned")
  }
}

fn join_titles(titles: List(String)) -> String {
  case titles {
    [] -> "On projects"
    _ -> string.join(titles, ", ")
  }
}
