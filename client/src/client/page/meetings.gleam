//// The Calendar page (Scheduling Phase C): every upcoming meeting as of the
//// global rail date, read from `GET /api/meetings?as_of=`. Each meeting renders
//// its canonical start time (in the meeting's own timezone) alongside every
//// attendee's local wall-clock time, computed client-side from the UTC offsets
//// the read model ships on the wire — no timezone library needed in the browser.
////
//// This module is the page FACADE, exposing the frozen
//// Model/Msg/init/update/view/refetch interface the shell consumes. The state
//// machine (model, messages, update, fetches, the bespoke create-form
//// command builder, and the local-time helpers) lives in `meetings/update`,
//// the table/attendee/create-form views in `meetings/view`, and the granular
//// contextual-operation modal in `meetings/op_form`.

import client/page.{type OutMsg}
import client/page/meetings/update as meetings_update
import client/page/meetings/view as meetings_view
import gleam/set.{type Set}
import gleam/time/calendar.{type Date}
import lustre/effect.{type Effect}
import lustre/element.{type Element}

pub type Model =
  meetings_update.Model

pub type Msg =
  meetings_update.Msg

pub fn init(route, as_of: Date, actor: String) -> #(Model, Effect(Msg)) {
  meetings_update.init(route, as_of, actor)
}

pub fn refetch(
  model: Model,
  as_of: Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  meetings_update.refetch(model, as_of, actor)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  meetings_update.update(model, msg)
}

pub fn view(
  model: Model,
  as_of: Date,
  permissions: Set(String),
) -> Element(Msg) {
  meetings_view.view(model, as_of, permissions)
}
