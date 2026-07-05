//// The People detail (FR-PE*), a self-contained sub-component MVU: the page's
//// DETAIL mode (deep link /people/:id) — one engineer's full record. This module
//// is the mode's FACADE, exposing the frozen Model/Msg/init/update/view/refetch
//// interface `page/people` composes. The state machine (model, messages, update,
//// fetches, op-form seeding) lives in `detail/update`, the panels and tabs in
//// `detail/view`, and the contextual-operation modal in `detail/op_form`; the
//// weekly timesheet grid stays in `page/people/timesheet`.

import client/page.{type OutMsg}
import client/page/people/detail/update as detail_update
import client/page/people/detail/view as detail_view
import gleam/option.{type Option}
import gleam/set.{type Set}
import gleam/time/calendar
import lustre/effect.{type Effect}
import lustre/element.{type Element}

pub type Model =
  detail_update.Model

pub type Msg =
  detail_update.Msg

pub fn init(as_of: calendar.Date, engineer_id: Int) -> #(Model, Effect(Msg)) {
  detail_update.init(as_of, engineer_id)
}

pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  detail_update.refetch(model, as_of)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  detail_update.update(model, msg)
}

pub fn view(
  model: Model,
  permissions: Set(String),
  viewer_engineer_id: Option(Int),
) -> Element(Msg) {
  detail_view.view(model, permissions, viewer_engineer_id)
}
