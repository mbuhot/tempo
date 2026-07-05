//// Schedule — the allocation timeline: every active project's engineer lanes
//// over 12 weekly columns with per-requirement gap rows, a portfolio stats
//// strip, and the project inspector + what-if scenario preview/apply.
////
//// This module is the page FACADE, exposing the frozen
//// Model/Msg/init/update/view/refetch interface the shell consumes. The state
//// machine (model, messages, update, the scenario drafting/preview logic) lives
//// in `schedule/scenario`, the grid and stats views in `schedule/timeline`, and
//// the project inspector in `schedule/inspector`.

import client/page.{type OutMsg}
import client/page/schedule/inspector.{view_inspector}
import client/page/schedule/scenario.{Failed, Loaded, Loading}
import client/page/schedule/timeline.{view_project, view_stats}
import client/route.{type Route}
import gleam/list
import gleam/set.{type Set}
import gleam/time/calendar.{type Date}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import shared/schedule/view as schedule_view

pub type Model =
  scenario.Model

pub type Msg =
  scenario.Msg

pub fn init(route: Route, as_of: Date, actor: String) -> #(Model, Effect(Msg)) {
  scenario.init(route, as_of, actor)
}

pub fn refetch(
  model: Model,
  as_of: Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  scenario.refetch(model, as_of, actor)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  scenario.update(model, msg)
}

pub fn view(
  model: Model,
  _as_of: Date,
  permissions: Set(String),
) -> Element(Msg) {
  case model.state {
    Loading -> html.div([attribute.class("schedule schedule--loading")], [])
    Failed(detail:) ->
      html.div([attribute.class("schedule schedule--failed")], [
        html.text(detail),
      ])
    Loaded(schedule) -> view_loaded(model, schedule, permissions)
  }
}

fn view_loaded(
  model: Model,
  schedule: schedule_view.Schedule,
  permissions: Set(String),
) -> Element(Msg) {
  let schedule_view.Schedule(weeks:, projects:, ..) = schedule
  html.div([attribute.class("schedule")], [
    view_stats(model, projects, permissions),
    html.div([attribute.class("detail-grid")], [
      html.div(
        [attribute.class("schedule-projects")],
        list.map(projects, view_project(model, weeks, _)),
      ),
      view_inspector(model, weeks, projects, permissions),
    ]),
  ])
}
