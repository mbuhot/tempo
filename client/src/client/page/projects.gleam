//// The Projects page (FR-CP5..): the project list as of the global rail date and
//// a single project's detail with its team, invoices, and capability coverage.
//// This module is the page FACADE, exposing the frozen
//// Model/Msg/init/update/view/refetch interface the shell consumes. The state
//// machine (model, messages, update, fetches, wizard wiring, op-form seeding)
//// lives in `projects/update`, the list and detail views in `projects/view`, and
//// the contextual-operation modal in `projects/op_form`.

import client/page.{type OutMsg}
import client/page/projects/update as projects_update
import client/page/projects/view as projects_view
import client/route
import gleam/set.{type Set}
import gleam/time/calendar
import lustre/effect.{type Effect}
import lustre/element.{type Element}

pub type Model =
  projects_update.Model

pub type Msg =
  projects_update.Msg

pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  projects_update.init(route, as_of, actor)
}

pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  projects_update.refetch(model, as_of, actor)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  projects_update.update(model, msg)
}

pub fn view(
  model: Model,
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  projects_view.view(model, as_of, permissions)
}
