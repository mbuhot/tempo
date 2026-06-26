//// The People page (FR-PE*): the roster as of the global rail date (list) and a
//// single engineer's detail (deep link /people/:id) hosting the timesheet grid.
////
//// Since issue #15 the page's two modes are each a self-contained sub-component
//// MVU: the LIST mode lives in `client/page/people/roster` (the roster table, the
//// Onboard op, the as-of directory) and the DETAIL mode in
//// `client/page/people/detail` (the engineer bundle, the side panels, the editable
//// timesheet grid, and the detail ops). This page is the COMPOSITION shell: its
//// `Model` is the list-vs-detail sum holding one sub-component model per mode; its
//// `Msg` wraps each sub-component's `Msg`; its `update` delegates to the active
//// mode and re-wraps the effect via `effect.map`; its `view` lifts the mode's view
//// with `element.map`. `init` selects the mode from the route (`People(Some(id))`
//// opens the detail; any other route opens the list).
////
//// The actor is no longer threaded through the page — issue #6 moved it to the
//// server session — so `init`/`refetch` accept it for interface stability and
//// discard it. Each mode owns its own stale-while-revalidate as-of guards.

import client/page.{type OutMsg}
import client/page/people/detail as detail_mode
import client/page/people/roster as roster_mode
import client/route
import gleam/option.{type Option, Some}
import gleam/set.{type Set}
import gleam/time/calendar
import lustre/effect.{type Effect}
import lustre/element.{type Element}

// --- Model ------------------------------------------------------------------

/// The People page is either showing the roster list or one engineer's detail, each
/// a self-contained sub-component model.
pub type Model {
  ListView(roster_mode.Model)
  DetailView(detail_mode.Model)
}

// --- Messages ---------------------------------------------------------------

/// The page's messages, wrapped by the shell as `PeopleMsg(people.Msg)`: each mode's
/// `Msg` in its own constructor.
pub type Msg {
  RosterMsg(roster_mode.Msg)
  DetailMsg(detail_mode.Msg)
}

// --- Init / refetch ---------------------------------------------------------

/// Build the page's initial state for `route` at `as_of`. `People(Some(id))` opens
/// that engineer's detail (so a cold deep link to `/people/:id` lands on the
/// detail); any other route opens the roster list. The actor is discarded — the
/// server derives it from the session cookie (issue #6).
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let _ = actor
  case route {
    route.People(id: Some(engineer_id)) -> {
      let #(model, eff) = detail_mode.init(as_of, engineer_id)
      #(DetailView(model), effect.map(eff, DetailMsg))
    }
    _ -> {
      let #(model, eff) = roster_mode.init(as_of)
      #(ListView(model), effect.map(eff, RosterMsg))
    }
  }
}

/// Re-fetch the active mode for a new `as_of` without dropping any open op form
/// (stale-while-revalidate).
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let _ = actor
  case model {
    ListView(mode) -> {
      let #(next, eff) = roster_mode.refetch(mode, as_of)
      #(ListView(next), effect.map(eff, RosterMsg))
    }
    DetailView(mode) -> {
      let #(next, eff) = detail_mode.refetch(mode, as_of)
      #(DetailView(next), effect.map(eff, DetailMsg))
    }
  }
}

// --- Update -----------------------------------------------------------------

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model, msg {
    ListView(mode), RosterMsg(mode_msg) -> {
      let #(next, eff, outs) = roster_mode.update(mode, mode_msg)
      #(ListView(next), effect.map(eff, RosterMsg), outs)
    }
    DetailView(mode), DetailMsg(mode_msg) -> {
      let #(next, eff, outs) = detail_mode.update(mode, mode_msg)
      #(DetailView(next), effect.map(eff, DetailMsg), outs)
    }
    _, _ -> #(model, effect.none(), [])
  }
}

// --- View -------------------------------------------------------------------

pub fn view(
  model: Model,
  as_of: calendar.Date,
  permissions: Set(String),
  viewer_engineer_id: Option(Int),
) -> Element(Msg) {
  let _ = as_of
  case model {
    ListView(mode) ->
      element.map(roster_mode.view(mode, permissions), RosterMsg)
    DetailView(mode) ->
      element.map(
        detail_mode.view(mode, permissions, viewer_engineer_id),
        DetailMsg,
      )
  }
}
