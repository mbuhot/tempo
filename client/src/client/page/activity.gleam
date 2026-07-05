//// The Activity page (FR-AC*): the provenance journal, read-only (no writes).
////
//// SYSTEM-TIME PAGE. Its date axis is transaction time (`occurred_at`), NOT the
//// valid-time global as-of rail. The feed is rendered through the generic data table
//// (`table_host`) reading `GET /api/events/table` — three columns (When · Actor ·
//// Event) where each row expands to its full JSON payload — with NO as-of base param
//// (`base: []`). The operation/actor/recorded-between filters are SCHEMA-LEVEL
//// filters the server advertises, rendered in the table rail automatically; the page
//// no longer owns a bespoke filter record.
////
//// `refetch(_, as_of, _)` is a DELIBERATE NO-OP: a rail scrub must not refetch the
//// system-time feed.

import client/page.{type OutMsg}
import client/route
import client/table_host
import client/ui/atoms
import gleam/time/calendar
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html

/// The page's state: the as-of its host carries (only so a stale reply is dropped —
/// the feed itself is system-time and ignores it) and the journal table host.
pub type Model {
  Model(as_of: calendar.Date, host: table_host.Host)
}

/// The page's messages, wrapped by the shell as `ActivityMsg(activity.Msg)`.
pub type Msg {
  TableHostMsg(sub: table_host.Msg)
}

/// Build the page's initial state and kick off the journal table fetch. `route` and
/// `actor` are unused: Activity has no detail sub-view and the feed needs no actor.
/// The host carries no as-of base param (`base: []`) — the journal is system-time.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let _ = route
  let _ = actor
  let #(host, host_effect) =
    table_host.init_with("/api/events/table", [], as_of)
  #(Model(as_of:, host:), effect.map(host_effect, TableHostMsg))
}

/// Fold a message into the model. The only messages are the table host's; the host
/// owns the load state, infinite scroll, debounce, and the schema-level filters.
/// Activity raises no navigation and no operations, so the host's outcomes are all
/// no-ops here.
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    TableHostMsg(sub:) -> {
      let #(host, host_effect, out) =
        table_host.update(model.host, sub, model.as_of)
      let model = Model(..model, host:)
      let effect = effect.map(host_effect, TableHostMsg)
      case out {
        table_host.Stay -> #(model, effect, [])
        table_host.Activated(..) -> #(model, effect, [])
        table_host.ActionInvoked(..) -> #(model, effect, [])
      }
    }
  }
}

/// Render the page: the header, then the journal table (rendered via the host, which
/// owns the loading / failed guards and surfaces the schema-level filters in the
/// rail). `as_of` is unused — the feed is system-time.
pub fn view(model: Model, as_of: calendar.Date) -> Element(Msg) {
  let _ = as_of
  html.div([], [
    atoms.page_head(
      title: "Activity",
      blurb: "Every change recorded against the workspace, newest first. This feed is on system time — what was recorded when, independent of the rail. Expand a row for its full payload.",
      actions: [],
    ),
    atoms.panel(title: "Journal", count: "", right: [], body: [
      element.map(
        table_host.view(model.host, "Loading activity…"),
        TableHostMsg,
      ),
    ]),
  ])
}

/// DELIBERATE NO-OP: the feed is system-time (transaction time), not driven by the
/// valid-time rail, so a rail scrub must NOT refetch it. Returns the model unchanged.
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let _ = as_of
  let _ = actor
  #(model, effect.none())
}
