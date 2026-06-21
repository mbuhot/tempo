//// The Activity page (FR-AC*): the provenance journal, read-only (no writes).
////
//// SYSTEM-TIME PAGE. Its date axis is transaction time (`occurred_at`), NOT the
//// valid-time global as-of rail. It owns its OWN from/to/operation/actor filter
//// state and the feed query ignores the `as_of` parameter entirely. Therefore
//// `refetch(_, as_of, _)` is a DELIBERATE NO-OP: a rail scrub must not refetch
//// the feed. Filters are page-model state; `view` receives `as_of` so the
//// optional one-click "jump to rail date" affordance (Activity PRD §3) sets the
//// recorded-between window around the rail's date. (FR-AC3 "filters in the URL"
//// is not wired — the frozen `Route.Activity` carries no filter fields; see
//// `apply_filters`.)
////
//// The feed is fetched from GET /api/events?from=&to=&operation=&actor= (all
//// optional, omitted when absent). Each fetch result carries the filter window it
//// answers; `update` drops a result whose window no longer matches the model's
//// current filters (stale-while-revalidate). Rows expand to the raw JSON payload
//// via a `.activity__payload--open` toggle.

import client/api
import client/route
import client/time
import client/ui
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import gleam/time/calendar
import gleam/uri
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/codecs
import shared/types.{type Event}

/// The four filters the feed reads, all optional. `from`/`to` is the half-open
/// system-time window (recorded between); `operation`/`actor` narrow to a single
/// operation or actor. An absent filter is omitted from the query string.
pub type Filters {
  Filters(
    from: Option(calendar.Date),
    to: Option(calendar.Date),
    operation: Option(String),
    actor: Option(String),
  )
}

/// The page's state. `filters` and `expanded` (the set of expanded payload row
/// ids) live alongside the load state so a refetch never drops a filter choice or
/// a toggled-open payload. `Loaded` carries the `Filters` its events answer so a
/// stale result (one whose window no longer matches) can be dropped.
pub type Model {
  Loading(filters: Filters, expanded: Set(Int))
  Loaded(filters: Filters, expanded: Set(Int), events: List(Event))
  Failed(filters: Filters, expanded: Set(Int), reason: String)
}

/// The page's messages, wrapped by the shell as `ActivityMsg(activity.Msg)`.
pub type Msg {
  GotEvents(filters: Filters, result: Result(List(Event), rsvp.Error(String)))
  PresetPicked(from: Option(calendar.Date), to: Option(calendar.Date))
  FromChanged(value: String)
  ToChanged(value: String)
  OperationPicked(value: String)
  ActorPicked(value: String)
  JumpedToRail(as_of: calendar.Date)
  PayloadToggled(id: Int)
}

/// The cross-page effects a page can raise (the ONLY shell coupling, frozen in
/// step 5): navigate to a route, or signal a write committed. Identical across all
/// 7 pages. Activity is read-only and self-contained, so in practice it raises
/// neither — but the variants stay to match the frozen interface.
pub type OutMsg {
  Navigate(route.Route)
  OperationCommitted
}

/// The default window: the 30 days up to (and including) the seed "now", as a
/// half-open `[from, to)` system-time range. Activity opens on this so a reload
/// shows recent activity without the rail driving it.
fn default_filters() -> Filters {
  let to = time.seed_now
  let from = time.day_index_to_date(time.date_to_day_index(to) - 30)
  Filters(
    from: Some(from),
    to: Some(next_day(to)),
    operation: None,
    actor: None,
  )
}

/// The day after `date`, as the exclusive upper bound of an inclusive window (the
/// `/api/events` `to` param is a half-open `< to`, so "up to and including X" is
/// expressed as `to = X + 1 day`). Day-index arithmetic keeps month/year rollover
/// correct.
fn next_day(date: calendar.Date) -> calendar.Date {
  time.day_index_to_date(time.date_to_day_index(date) + 1)
}

/// Build the page's initial state and kick off the feed fetch over the default
/// 30-day window. `route` and `as_of` are unused: Activity has no detail sub-view
/// and the feed is system-time, not rail-driven.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let _ = route
  let _ = as_of
  let _ = actor
  let filters = default_filters()
  #(Loading(filters:, expanded: set.new()), fetch(filters))
}

/// Fetch the feed for `filters`, omitting any absent param from the query string.
/// The result is tagged with the `filters` it answers so a stale response can be
/// dropped.
fn fetch(filters: Filters) -> Effect(Msg) {
  api.get(events_url(filters), decode.list(codecs.event_decoder()), fn(result) {
    GotEvents(filters:, result:)
  })
}

/// The /api/events URL for `filters`: each present filter appended to the query,
/// absent ones omitted. Dates are ISO via `time.iso_date`; the free-text
/// operation/actor values are percent-encoded so a value with a space or other
/// special character is safe in the query string.
fn events_url(filters: Filters) -> String {
  let params =
    [
      filters.from |> option.map(fn(date) { #("from", time.iso_date(date)) }),
      filters.to |> option.map(fn(date) { #("to", time.iso_date(date)) }),
      filters.operation |> option.map(fn(value) { #("operation", value) }),
      filters.actor |> option.map(fn(value) { #("actor", value) }),
    ]
    |> option.values
  case params {
    [] -> "/api/events"
    pairs ->
      "/api/events?"
      <> {
        pairs
        |> list.map(fn(pair) { pair.0 <> "=" <> uri.percent_encode(pair.1) })
        |> string.join("&")
      }
  }
}

/// Fold a message into the model. A fetch result for filters that no longer match
/// the model's current filters is DROPPED (stale-while-revalidate). A filter
/// change goes to `Loading` and refetches (see `apply_filters` for the FR-AC3
/// URL caveat). Payload toggles are pure local view state.
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    GotEvents(filters:, result:) ->
      case filters == current_filters(model) {
        False -> #(model, effect.none(), [])
        True ->
          case result {
            Ok(events) -> #(
              Loaded(filters:, expanded: current_expanded(model), events:),
              effect.none(),
              [],
            )
            Error(error) -> #(
              Failed(
                filters:,
                expanded: current_expanded(model),
                reason: api.describe_error(error),
              ),
              effect.none(),
              [],
            )
          }
      }

    PresetPicked(from:, to:) ->
      apply_filters(model, Filters(..current_filters(model), from:, to:))

    FromChanged(value:) -> {
      let from = case time.parse_iso_date(value) {
        Ok(date) -> Some(date)
        Error(Nil) -> None
      }
      apply_filters(model, Filters(..current_filters(model), from:))
    }

    ToChanged(value:) -> {
      let to = case time.parse_iso_date(value) {
        Ok(date) -> Some(date)
        Error(Nil) -> None
      }
      apply_filters(model, Filters(..current_filters(model), to:))
    }

    OperationPicked(value:) ->
      apply_filters(
        model,
        Filters(..current_filters(model), operation: nonempty(value)),
      )

    ActorPicked(value:) ->
      apply_filters(
        model,
        Filters(..current_filters(model), actor: nonempty(value)),
      )

    JumpedToRail(as_of:) ->
      apply_filters(
        model,
        Filters(
          ..current_filters(model),
          from: Some(as_of),
          to: Some(next_day(as_of)),
        ),
      )

    PayloadToggled(id:) -> #(
      with_expanded(model, toggle(current_expanded(model), id)),
      effect.none(),
      [],
    )
  }
}

/// Apply a new filter set: go to `Loading` and refetch. Expanded payloads are
/// preserved across the refetch.
///
/// FR-AC3 (filters in the URL) is intentionally NOT wired through `Navigate`: the
/// frozen `OutMsg`/`route.Route` contract can only carry `route.Activity`, which
/// serializes (via the shell's `route.to_path`) to a bare `/activity` with no
/// filter query — `route.activity_path` returns a `String` the `Route` cannot
/// hold. Raising `Navigate(route.Activity)` would push a history entry that drops
/// the filters, giving no shareability benefit, so the filters live as page-model
/// state instead. Carrying activity filters in the URL would need a filter-bearing
/// `Route.Activity` (a shell/route change outside this page's scope).
fn apply_filters(
  model: Model,
  filters: Filters,
) -> #(Model, Effect(Msg), List(OutMsg)) {
  let expanded = current_expanded(model)
  #(Loading(filters:, expanded:), fetch(filters), [])
}

fn current_filters(model: Model) -> Filters {
  case model {
    Loading(filters:, ..) -> filters
    Loaded(filters:, ..) -> filters
    Failed(filters:, ..) -> filters
  }
}

fn current_expanded(model: Model) -> Set(Int) {
  case model {
    Loading(expanded:, ..) -> expanded
    Loaded(expanded:, ..) -> expanded
    Failed(expanded:, ..) -> expanded
  }
}

fn with_expanded(model: Model, expanded: Set(Int)) -> Model {
  case model {
    Loading(filters:, ..) -> Loading(filters:, expanded:)
    Loaded(filters:, events:, ..) -> Loaded(filters:, expanded:, events:)
    Failed(filters:, reason:, ..) -> Failed(filters:, expanded:, reason:)
  }
}

fn toggle(expanded: Set(Int), id: Int) -> Set(Int) {
  case set.contains(expanded, id) {
    True -> set.delete(expanded, id)
    False -> set.insert(expanded, id)
  }
}

fn nonempty(value: String) -> Option(String) {
  case string.trim(value) {
    "" -> None
    text -> Some(text)
  }
}

/// Render the page: the header with filter controls, then the feed panel. `as_of`
/// drives the optional "jump to rail date" affordance, which sets the window
/// around the rail's date (FR-AC3 / Activity PRD §3).
pub fn view(model: Model, as_of: calendar.Date) -> Element(Msg) {
  let filters = current_filters(model)
  let events = case model {
    Loaded(events:, ..) -> events
    _ -> []
  }
  html.div([], [
    ui.page_head(
      title: "Activity",
      blurb: "Every change recorded against the workspace, newest first. This feed is on system time — what was recorded when, independent of the rail.",
      actions: [view_filters(filters, events, as_of)],
    ),
    view_body(model),
  ])
}

/// The filter controls: the quick presets, explicit from/to date inputs, the
/// operation and actor selects (their option lists derived from the loaded
/// events), and the jump-to-rail button. Mirrors the prototype's `.filters`.
fn view_filters(
  filters: Filters,
  events: List(Event),
  as_of: calendar.Date,
) -> Element(Msg) {
  html.div([attribute.class("filters")], [
    preset_select(filters),
    date_input("from", iso_or_blank(filters.from), FromChanged),
    date_input("to", iso_or_blank(filters.to), ToChanged),
    operation_select(filters, events),
    actor_select(filters, events),
    html.button(
      [
        attribute.class("btn btn--ghost btn--sm"),
        event.on_click(JumpedToRail(as_of)),
      ],
      [html.text("Jump to " <> time.iso_date(as_of))],
    ),
  ])
}

/// The quick-preset select: Today / Last 7 / Last 30 / This month / All time.
/// Each maps to a `[from, to)` window anchored at the seed "now"; "All time"
/// clears the window. Selecting one raises `PresetPicked`.
fn preset_select(filters: Filters) -> Element(Msg) {
  let now = time.seed_now
  let window = fn(days) {
    PresetPicked(
      from: Some(time.day_index_to_date(time.date_to_day_index(now) - days)),
      to: Some(next_day(now)),
    )
  }
  let presets = [
    #("range", "Custom range", PresetPicked(filters.from, filters.to)),
    #("today", "Today", PresetPicked(Some(now), Some(next_day(now)))),
    #("7", "Last 7 days", window(7)),
    #("30", "Last 30 days", window(30)),
    #(
      "month",
      "This month",
      PresetPicked(
        from: Some(time.first_of_month(now)),
        to: Some(time.first_of_next_month(now)),
      ),
    ),
    #("all", "All time", PresetPicked(from: None, to: None)),
  ]
  html.select(
    [
      attribute.attribute("aria-label", "Quick range"),
      event.on_change(fn(value) {
        list.key_find(list.map(presets, fn(p) { #(p.0, p.2) }), value)
        |> result_or(PresetPicked(filters.from, filters.to))
      }),
    ],
    list.map(presets, fn(preset) {
      let #(key, label, _) = preset
      html.option([attribute.value(key)], label)
    }),
  )
}

fn result_or(result: Result(a, Nil), default: a) -> a {
  case result {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

/// A labelled ISO date input bound to `to_msg`. Empty when the bound filter is
/// absent.
fn date_input(
  label: String,
  value: String,
  to_msg: fn(String) -> Msg,
) -> Element(Msg) {
  html.input([
    attribute.type_("date"),
    attribute.attribute("aria-label", "Recorded " <> label),
    attribute.value(value),
    event.on_change(to_msg),
  ])
}

/// The operation filter `<select>`: "All operations" plus the distinct operations
/// in the loaded feed. The current filter is the selected option.
fn operation_select(filters: Filters, events: List(Event)) -> Element(Msg) {
  let operations = events |> list.map(fn(entry) { entry.operation }) |> distinct
  filter_select(
    "All operations",
    operations,
    option.unwrap(filters.operation, ""),
    OperationPicked,
  )
}

/// The actor filter `<select>`: "All people" plus the distinct actors in the
/// loaded feed.
fn actor_select(filters: Filters, events: List(Event)) -> Element(Msg) {
  let actors = events |> list.map(fn(entry) { entry.actor }) |> distinct
  filter_select(
    "All people",
    actors,
    option.unwrap(filters.actor, ""),
    ActorPicked,
  )
}

/// A `<select>` over a placeholder ("" = unfiltered) plus a list of option values,
/// the current `selected` value marked, raising `to_msg(value)` on change.
fn filter_select(
  placeholder: String,
  values: List(String),
  selected: String,
  to_msg: fn(String) -> Msg,
) -> Element(Msg) {
  let placeholder_option =
    html.option(
      [attribute.value(""), attribute.selected(selected == "")],
      placeholder,
    )
  let options =
    list.map(values, fn(value) {
      html.option(
        [attribute.value(value), attribute.selected(value == selected)],
        value,
      )
    })
  html.select(
    [
      attribute.attribute("aria-label", placeholder),
      event.on_change(to_msg),
    ],
    [placeholder_option, ..options],
  )
}

/// The feed panel: a spinner-free loading line, the error, or the rows (each
/// expandable to its payload). Mirrors the prototype's `.panel` wrapping rows.
fn view_body(model: Model) -> Element(Msg) {
  case model {
    Loading(..) ->
      ui.panel(title: "Journal", count: "", right: [], body: [
        ui.empty_state(message: "Loading activity…"),
      ])
    Failed(reason:, ..) ->
      ui.panel(title: "Journal", count: "", right: [], body: [
        ui.empty_state(message: "Could not load activity: " <> reason),
      ])
    Loaded(events:, expanded:, ..) ->
      case events {
        [] ->
          ui.panel(title: "Journal", count: "", right: [], body: [
            ui.empty_state(message: "No activity recorded in this window."),
          ])
        events ->
          ui.panel(
            title: "Journal",
            count: int.to_string(list.length(events)),
            right: [],
            body: list.flat_map(events, fn(entry) {
              view_event(entry, set.contains(expanded, entry.id))
            }),
          )
      }
  }
}

/// One feed entry: the clickable row (timestamp / operation / summary / actor with
/// avatar) followed by its payload block, shown only when `open`. Mirrors the
/// prototype's `.activity__row` + `.activity__payload(--open)` pair.
fn view_event(entry: Event, open: Bool) -> List(Element(Msg)) {
  let payload_class = case open {
    True -> "activity__payload activity__payload--open"
    False -> "activity__payload"
  }
  [
    html.div(
      [
        attribute.class("activity__row"),
        event.on_click(PayloadToggled(entry.id)),
      ],
      [
        html.span([attribute.class("activity__time")], [
          html.text(entry.occurred_at),
        ]),
        html.span([attribute.class("activity__op")], [
          html.text(entry.operation),
        ]),
        html.span([attribute.class("activity__summary")], [
          html.text(entry.summary),
        ]),
        html.span([attribute.class("activity__actor")], [
          ui.avatar(
            name: entry.actor,
            category: actor_category(entry.actor),
            class: "avatar",
          ),
          html.text(entry.actor),
        ]),
      ],
    ),
    html.div([attribute.class(payload_class)], [html.text(entry.payload)]),
  ]
}

/// A stable categorical index for an actor's avatar tint, derived from the name so
/// the same person always gets the same colour. (`ui.avatar` wraps it to 1..7.)
fn actor_category(actor: String) -> Int {
  string.to_utf_codepoints(actor)
  |> list.fold(0, fn(sum, codepoint) {
    sum + string.utf_codepoint_to_int(codepoint)
  })
}

fn distinct(values: List(String)) -> List(String) {
  values
  |> list.fold([], fn(seen, value) {
    case list.contains(seen, value) {
      True -> seen
      False -> [value, ..seen]
    }
  })
  |> list.reverse
}

fn iso_or_blank(date: Option(calendar.Date)) -> String {
  case date {
    Some(date) -> time.iso_date(date)
    None -> ""
  }
}

/// DELIBERATE NO-OP: the feed is system-time (transaction time), not driven by the
/// valid-time rail, so a rail scrub must NOT refetch it. Returns the model
/// unchanged with `effect.none()`.
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let _ = as_of
  let _ = actor
  #(model, effect.none())
}
