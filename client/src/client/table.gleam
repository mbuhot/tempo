//// The generic, schema-driven data table. One reusable MVU unit every list page
//// embeds: it renders rows by the column's data-type, offers the server-advertised
//// filter per column (anchored popover), sorts on header click, loads more rows as
//// the viewport scrolls (infinite scroll), and lets the user drag-reorder/hide
//// columns (saved locally). It owns no data fetching — `update` returns an `Outcome`
//// telling the host page what to do (re-query, append a page, persist the layout, or
//// schedule a debounce tick), so the page keeps the one `api.get`/effect seam.
////
//// The cell renderer (`render_cell`), the tone→pill mapping (`tone_class`), and the
//// filter-widget picker (`filter_widget`) each switch exhaustively with no `_` arm,
//// so a new `Cell`/`Tone`/`FilterKind` variant fails the build until handled here.

import client/time
import client/ui
import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/money
import shared/table/cell.{
  type Action, type Cell, type Chip, ActionsCell, BoolCell, ChipsCell, DateCell,
  EntityCell, EnumCell, MoneyCell, NumberCell, PercentCell, PersonCell,
  SignedMoneyCell, TextCell,
}
import shared/table/column.{
  type Column, type Schema, type Tone, Accent, Critical, Neutral, NumericEnd,
  Positive, Warning,
}
import shared/table/filter.{
  type FilterKind, BoolFilter, DateRangeFilter, NumberRangeFilter, SelectFilter,
  TextFilter,
}
import shared/table/query.{
  type Applied, type FilterValue, Applied, BoolValue, DateRange, NumberRange,
  SelectValue, TextValue,
}
import shared/table/response.{type Row}
import shared/table/sort.{Asc, Desc, Sort}

/// Debounce window (ms) for free-typing filter inputs, so a burst of keystrokes
/// collapses to one re-query. Discrete changes (select, date, sort, page) apply at
/// once.
pub const debounce_ms = 340

/// The table's view state the host page owns. `order`/`hidden` are the local layout
/// (persisted); `applied` is the server-bound filter/sort/page state; `open` tracks
/// which detail panel is showing; `filter_token` guards the debounce.
pub type State {
  State(
    table_id: String,
    default_order: List(String),
    order: List(String),
    hidden: Set(String),
    applied: Applied,
    open: Panel,
    filter_token: Int,
    loading_more: Bool,
    dragging: Option(String),
    drag_over: Option(String),
    expanded: Set(String),
  )
}

/// Which anchored popover is open: a column's filter, or the columns manager.
pub type Panel {
  Closed
  FilterPanel(key: String)
  ColumnsPanel
}

pub type Bound {
  Min
  Max
}

pub type DateBound {
  From
  To
}

pub type Msg {
  HeaderClicked(key: String)
  FilterButtonClicked(key: String)
  ColumnsButtonClicked
  PanelDismissed
  SelectToggled(key: String, value: String)
  TextTyped(key: String, value: String)
  NumberBoundTyped(key: String, bound: Bound, value: String)
  DateBoundPicked(key: String, bound: DateBound, value: String)
  BoolPicked(key: String, value: String)
  FilterCleared(key: String)
  ResetAll
  SettleFired(token: Int)
  ScrolledNearBottom
  ColumnToggled(key: String)
  DragStarted(key: String)
  DragOver(key: String)
  Dropped(key: String)
  DragEnded
  LayoutReset
  RowClicked(id: String)
  RowExpandToggled(id: String)
  ActionInvoked(action: String, row: String)
}

/// What `update` asks the host page to do. `Requery` replaces the rows (a fresh
/// filter/sort/page); `AppendPage` loads the next page and appends; `Persist` writes
/// the layout JSON to storage; `Schedule` asks the page to fire `SettleFired(token)`
/// after `debounce_ms`.
pub type Outcome {
  Idle
  Requery(params: List(#(String, String)))
  AppendPage(params: List(#(String, String)))
  Persist(layout: String)
  Schedule(token: Int)
  Activated(id: String)
  ActionRaised(action: String, row: String)
}

/// The page size the frontend requests — large enough to overflow the table's scroll
/// viewport so infinite scroll has room to trigger, small enough to keep each fetch
/// cheap. The user never picks this.
const default_page_size = 15

/// How close to the bottom of the scroll viewport (px) before the next page loads.
const scroll_threshold = 160.0

/// Start the table from a schema: columns in schema order, nothing hidden, the
/// schema's default sort applied.
pub fn init(schema: Schema) -> State {
  let order = list.map(schema.columns, fn(column) { column.key })
  State(
    table_id: schema.table_id,
    default_order: order,
    order:,
    hidden: set.new(),
    applied: Applied(
      filters: dict.new(),
      sort: schema.default_sort,
      page_size: default_page_size,
      cursor: None,
    ),
    open: Closed,
    filter_token: 0,
    loading_more: False,
    dragging: None,
    drag_over: None,
    expanded: set.new(),
  )
}

/// Reconcile the layout with a (possibly changed) schema: keep the saved order for
/// columns that still exist, append any new columns visibly, and forget hidden keys
/// the schema no longer sends. Also clears the in-flight `loading_more` guard, since
/// every fresh response (or appended page) settles the table.
pub fn reconcile(state: State, schema: Schema) -> State {
  let keys = list.map(schema.columns, fn(column) { column.key })
  let kept = list.filter(state.order, fn(key) { list.contains(keys, key) })
  let added = list.filter(keys, fn(key) { !list.contains(kept, key) })
  let hidden = set.filter(state.hidden, fn(key) { list.contains(keys, key) })
  State(
    ..state,
    default_order: keys,
    order: list.append(kept, added),
    hidden:,
    loading_more: False,
    expanded: set.new(),
  )
}

/// Apply a saved layout JSON (from storage) over the current state, then reconcile
/// against `schema` so a stale layout can never reference a dropped column.
pub fn with_layout(state: State, layout: String, schema: Schema) -> State {
  case decode_layout(layout) {
    Some(#(order, hidden)) -> reconcile(State(..state, order:, hidden:), schema)
    None -> reconcile(state, schema)
  }
}

/// The storage key for this table's layout preference.
pub fn layout_key(state: State) -> String {
  "tempo.table." <> state.table_id <> ".layout"
}

/// The current filter/sort/page state as request query params — the host page uses
/// this to re-fetch on an as-of change or after a write commits.
pub fn params(state: State) -> List(#(String, String)) {
  query.to_params(state.applied)
}

/// The params for a page's very first fetch, before any schema/state exists: just
/// the default page size, so the first response is a bounded page (the server
/// applies its own default sort).
pub fn initial_params() -> List(#(String, String)) {
  [#("page_size", int.to_string(default_page_size))]
}

// --- update -----------------------------------------------------------------

pub fn update(state: State, msg: Msg) -> #(State, Outcome) {
  case msg {
    HeaderClicked(key:) -> {
      let next = State(..state, applied: cycle_sort(state.applied, key))
      #(next, Requery(query.to_params(next.applied)))
    }
    FilterButtonClicked(key:) -> {
      let open = case state.open {
        FilterPanel(open_key) if open_key == key -> Closed
        _ -> FilterPanel(key)
      }
      #(State(..state, open:), Idle)
    }
    ColumnsButtonClicked -> {
      let open = case state.open {
        ColumnsPanel -> Closed
        _ -> ColumnsPanel
      }
      #(State(..state, open:), Idle)
    }
    PanelDismissed -> #(State(..state, open: Closed), Idle)
    SelectToggled(key:, value:) -> {
      let next =
        State(..state, applied: toggle_select(state.applied, key, value))
      #(next, Requery(query.to_params(next.applied)))
    }
    TextTyped(key:, value:) -> {
      let token = state.filter_token + 1
      let applied = set_filter(state.applied, key, text_value(value))
      #(State(..state, applied:, filter_token: token), Schedule(token))
    }
    NumberBoundTyped(key:, bound:, value:) -> {
      let token = state.filter_token + 1
      let applied = update_number(state.applied, key, bound, value)
      #(State(..state, applied:, filter_token: token), Schedule(token))
    }
    DateBoundPicked(key:, bound:, value:) -> {
      let next =
        State(..state, applied: update_date(state.applied, key, bound, value))
      #(next, Requery(query.to_params(next.applied)))
    }
    BoolPicked(key:, value:) -> {
      let next = State(..state, applied: update_bool(state.applied, key, value))
      #(next, Requery(query.to_params(next.applied)))
    }
    FilterCleared(key:) -> {
      let next = State(..state, applied: clear_filter(state.applied, key))
      #(next, Requery(query.to_params(next.applied)))
    }
    ResetAll -> {
      let applied = Applied(..state.applied, filters: dict.new())
      let next = State(..state, applied:, open: Closed)
      #(next, Requery(query.to_params(applied)))
    }
    SettleFired(token:) ->
      case token == state.filter_token {
        True -> #(state, Requery(query.to_params(state.applied)))
        False -> #(state, Idle)
      }
    ScrolledNearBottom ->
      case state.loading_more {
        True -> #(state, Idle)
        False -> #(
          State(..state, loading_more: True),
          AppendPage(query.to_params(state.applied)),
        )
      }
    ColumnToggled(key:) -> {
      let hidden = case set.contains(state.hidden, key) {
        True -> set.delete(state.hidden, key)
        False -> set.insert(state.hidden, key)
      }
      let next = State(..state, hidden:)
      #(next, Persist(encode_layout(next)))
    }
    DragStarted(key:) -> #(State(..state, dragging: Some(key)), Idle)
    DragOver(key:) ->
      case state.drag_over == Some(key) {
        True -> #(state, Idle)
        False -> #(State(..state, drag_over: Some(key)), Idle)
      }
    Dropped(key:) ->
      case state.dragging {
        Some(from) -> {
          let next =
            State(
              ..state,
              order: reorder(state.order, from, key),
              dragging: None,
              drag_over: None,
            )
          #(next, Persist(encode_layout(next)))
        }
        None -> #(State(..state, drag_over: None), Idle)
      }
    DragEnded -> #(State(..state, dragging: None, drag_over: None), Idle)
    LayoutReset -> {
      let next = State(..state, order: state.default_order, hidden: set.new())
      #(next, Persist(encode_layout(next)))
    }
    RowClicked(id:) -> #(state, Activated(id))
    RowExpandToggled(id:) -> {
      let expanded = case set.contains(state.expanded, id) {
        True -> set.delete(state.expanded, id)
        False -> set.insert(state.expanded, id)
      }
      #(State(..state, expanded:), Idle)
    }
    ActionInvoked(action:, row:) -> #(state, ActionRaised(action:, row:))
  }
}

fn cycle_sort(applied: Applied, key: String) -> Applied {
  let sort = case applied.sort {
    Some(Sort(current, Asc)) if current == key -> Some(Sort(key, Desc))
    Some(Sort(current, Desc)) if current == key -> None
    _ -> Some(Sort(key, Asc))
  }
  Applied(..applied, sort:)
}

fn toggle_select(applied: Applied, key: String, value: String) -> Applied {
  let current = case dict.get(applied.filters, key) {
    Ok(SelectValue(values)) -> values
    _ -> []
  }
  let next = case list.contains(current, value) {
    True -> list.filter(current, fn(item) { item != value })
    False -> list.append(current, [value])
  }
  case next {
    [] -> clear_filter(applied, key)
    _ -> set_filter(applied, key, SelectValue(next))
  }
}

fn update_number(
  applied: Applied,
  key: String,
  bound: Bound,
  value: String,
) -> Applied {
  let #(min, max) = case dict.get(applied.filters, key) {
    Ok(NumberRange(min:, max:)) -> #(min, max)
    _ -> #(None, None)
  }
  let parsed = option.from_result(float.parse(value))
  let #(min, max) = case bound {
    Min -> #(parsed, max)
    Max -> #(min, parsed)
  }
  case min, max {
    None, None -> clear_filter(applied, key)
    _, _ -> set_filter(applied, key, NumberRange(min:, max:))
  }
}

fn update_date(
  applied: Applied,
  key: String,
  bound: DateBound,
  value: String,
) -> Applied {
  let #(from, to) = case dict.get(applied.filters, key) {
    Ok(DateRange(from:, to:)) -> #(from, to)
    _ -> #(None, None)
  }
  let picked = case value {
    "" -> None
    _ -> Some(month_start(value))
  }
  let #(from, to) = case bound {
    From -> #(picked, to)
    To -> #(from, picked)
  }
  case from, to {
    None, None -> clear_filter(applied, key)
    _, _ -> set_filter(applied, key, DateRange(from:, to:))
  }
}

fn update_bool(applied: Applied, key: String, value: String) -> Applied {
  case value {
    "true" -> set_filter(applied, key, BoolValue(True))
    "false" -> set_filter(applied, key, BoolValue(False))
    _ -> clear_filter(applied, key)
  }
}

fn text_value(value: String) -> FilterValue {
  TextValue(string.trim(value))
}

fn set_filter(applied: Applied, key: String, value: FilterValue) -> Applied {
  Applied(..applied, filters: dict.insert(applied.filters, key, value))
}

fn clear_filter(applied: Applied, key: String) -> Applied {
  Applied(..applied, filters: dict.delete(applied.filters, key))
}

/// Move `from` to sit immediately before `to` in the order (drag-and-drop drop-on-
/// target semantics). A drop on itself is a no-op.
fn reorder(order: List(String), from: String, to: String) -> List(String) {
  case from == to {
    True -> order
    False ->
      list.filter(order, fn(key) { key != from })
      |> list.flat_map(fn(key) {
        case key == to {
          True -> [from, key]
          False -> [key]
        }
      })
  }
}

fn month_start(month: String) -> String {
  case string.length(month) {
    7 -> month <> "-01"
    _ -> month
  }
}

fn result_or(result: Result(a, b), fallback: a) -> a {
  case result {
    Ok(value) -> value
    Error(_) -> fallback
  }
}

// --- layout codec -----------------------------------------------------------

fn encode_layout(state: State) -> String {
  json.to_string(
    json.object([
      #("order", json.array(state.order, json.string)),
      #("hidden", json.array(set.to_list(state.hidden), json.string)),
    ]),
  )
}

fn decode_layout(text: String) -> Option(#(List(String), Set(String))) {
  let decoder = {
    use order <- decode.field("order", decode.list(decode.string))
    use hidden <- decode.field("hidden", decode.list(decode.string))
    decode.success(#(order, set.from_list(hidden)))
  }
  option.from_result(json.parse(text, decoder))
}

// --- view -------------------------------------------------------------------

/// Render the whole table: the filter rail (each filterable column a chip with an
/// anchored popover), the scrolling rows (infinite scroll when `has_more`), and the
/// footer. `has_more` reflects the host page's `next_cursor`.
pub fn view(
  schema: Schema,
  rows: List(Row),
  state: State,
  has_more: Bool,
) -> Element(Msg) {
  let backdrop = case state.open {
    Closed -> element.none()
    _ ->
      html.div(
        [attribute.class("dt-backdrop"), event.on_click(PanelDismissed)],
        [],
      )
  }
  html.div([attribute.class("dt")], [
    backdrop,
    rail(schema, state),
    table(schema, rows, state, has_more),
    footer(state),
  ])
}

fn rail(schema: Schema, state: State) -> Element(Msg) {
  let column_chips =
    schema.columns
    |> list.filter_map(fn(column) {
      case column.filter {
        Some(kind) -> Ok(filter_chip(column.key, column.label, kind, state))
        None -> Error(Nil)
      }
    })
  let standalone_chips =
    schema.filters
    |> list.map(fn(standalone) {
      filter_chip(standalone.key, standalone.label, standalone.kind, state)
    })
  let chips = list.append(column_chips, standalone_chips)
  let reset = case dict.size(state.applied.filters) {
    0 -> element.none()
    _ ->
      html.button([attribute.class("dt-reset"), event.on_click(ResetAll)], [
        html.text("Reset all"),
      ])
  }
  html.div([attribute.class("dt-rail")], [
    html.span([attribute.class("dt-rail__label")], [html.text("Filter")]),
    html.div([attribute.class("dt-rail__chips")], chips),
    html.div([attribute.class("dt-rail__spacer")], []),
    reset,
    columns_chip(schema, state),
  ])
}

/// A filter's rail chip (column filter or schema-level standalone filter): a toggle
/// button (label, active count badge, an inline clear when active) and — when open —
/// its filter popover anchored beneath. Keyed by the filter's `key` + `kind`, so a
/// standalone filter flows through the identical widget/applied/query path as a
/// column filter.
fn filter_chip(
  key: String,
  label: String,
  kind: FilterKind,
  state: State,
) -> Element(Msg) {
  let count = active_count(state.applied, key)
  let active_class = case count {
    0 -> "dt-fbtn"
    _ -> "dt-fbtn dt-fbtn--active"
  }
  let badge = case count {
    0 -> html.span([attribute.class("dt-fbtn__chev")], [html.text("▾")])
    _ ->
      html.span([], [
        html.span([attribute.class("dt-fbtn__badge")], [
          html.text(int.to_string(count)),
        ]),
        html.span(
          [
            attribute.class("dt-fbtn__clear"),
            event.on_click(FilterCleared(key)) |> event.stop_propagation,
          ],
          [html.text("✕")],
        ),
      ])
  }
  let pop = case state.open {
    FilterPanel(open_key) if open_key == key ->
      filter_pop(key, label, kind, state)
    _ -> element.none()
  }
  html.div([attribute.class("dt-fchip")], [
    html.button(
      [attribute.class(active_class), event.on_click(FilterButtonClicked(key))],
      [html.text(label), badge],
    ),
    pop,
  ])
}

/// The Columns manager chip: a button and, when open, the columns popover anchored
/// beneath (right-aligned, since it sits at the rail's end).
fn columns_chip(schema: Schema, state: State) -> Element(Msg) {
  let pop = case state.open {
    ColumnsPanel -> columns_panel(schema, state)
    _ -> element.none()
  }
  html.div([attribute.class("dt-fchip dt-fchip--right")], [
    html.button(
      [attribute.class("dt-fbtn"), event.on_click(ColumnsButtonClicked)],
      [html.text("Columns")],
    ),
    pop,
  ])
}

fn active_count(applied: Applied, key: String) -> Int {
  case dict.get(applied.filters, key) {
    Ok(SelectValue(values)) -> list.length(values)
    Ok(NumberRange(..)) -> 1
    Ok(DateRange(..)) -> 1
    Ok(TextValue(_)) -> 1
    Ok(BoolValue(_)) -> 1
    Error(Nil) -> 0
  }
}

fn filter_pop(
  key: String,
  label: String,
  kind: FilterKind,
  state: State,
) -> Element(Msg) {
  html.div([attribute.class("dt-pop")], [
    html.div([attribute.class("dt-pop__head")], [
      html.span([attribute.class("dt-pop__title")], [html.text(label)]),
      html.button(
        [attribute.class("dt-pop__clear"), event.on_click(FilterCleared(key))],
        [html.text("Clear")],
      ),
    ]),
    filter_widget(kind, key, state.applied),
  ])
}

/// The filter widget for a kind. Exhaustive on `FilterKind` — a new kind fails the
/// build here until it has a widget.
fn filter_widget(
  kind: FilterKind,
  key: String,
  applied: Applied,
) -> Element(Msg) {
  case kind {
    TextFilter -> text_widget(key, applied)
    SelectFilter(options:, ..) -> select_widget(key, options, applied)
    NumberRangeFilter -> number_widget(key, applied)
    DateRangeFilter(options:) -> date_widget(key, options, applied)
    BoolFilter -> bool_widget(key, applied)
  }
}

fn text_widget(key: String, applied: Applied) -> Element(Msg) {
  let current = case dict.get(applied.filters, key) {
    Ok(TextValue(value)) -> value
    _ -> ""
  }
  html.input([
    attribute.class("dt-input"),
    attribute.type_("text"),
    attribute.placeholder("Contains…"),
    attribute.value(current),
    event.on_input(TextTyped(key, _)),
  ])
}

fn select_widget(
  key: String,
  options: List(filter.FilterOption),
  applied: Applied,
) -> Element(Msg) {
  let selected = case dict.get(applied.filters, key) {
    Ok(SelectValue(values)) -> values
    _ -> []
  }
  html.div(
    [attribute.class("dt-options")],
    list.map(options, fn(option) {
      html.label([attribute.class("dt-option")], [
        html.input([
          attribute.type_("checkbox"),
          attribute.checked(list.contains(selected, option.value)),
          event.on_check(fn(_checked) { SelectToggled(key, option.value) }),
        ]),
        html.span([], [html.text(option.label)]),
      ])
    }),
  )
}

fn number_widget(key: String, applied: Applied) -> Element(Msg) {
  let #(min, max) = case dict.get(applied.filters, key) {
    Ok(NumberRange(min:, max:)) -> #(min, max)
    _ -> #(None, None)
  }
  html.div([attribute.class("dt-range")], [
    bound_input("Min", float_text(min), NumberBoundTyped(key, Min, _)),
    html.span([attribute.class("dt-range__sep")], [html.text("–")]),
    bound_input("Max", float_text(max), NumberBoundTyped(key, Max, _)),
  ])
}

fn date_widget(
  key: String,
  options: List(filter.FilterOption),
  applied: Applied,
) -> Element(Msg) {
  let #(from, to) = case dict.get(applied.filters, key) {
    Ok(DateRange(from:, to:)) -> #(from, to)
    _ -> #(None, None)
  }
  let field = case options {
    [] -> date_input
    _ -> fn(label, current, to_msg) {
      month_select(label, current, options, to_msg)
    }
  }
  html.div([attribute.class("dt-range")], [
    field("From", from, DateBoundPicked(key, From, _)),
    html.span([attribute.class("dt-range__sep")], [html.text("–")]),
    field("To", to, DateBoundPicked(key, To, _)),
  ])
}

/// A native date picker for a date-range bound, used when the filter advertises no
/// discrete options (a free date range, e.g. an event timestamp).
fn date_input(
  label: String,
  current: Option(String),
  to_msg: fn(String) -> Msg,
) -> Element(Msg) {
  html.label([attribute.class("dt-field")], [
    html.span([], [html.text(label)]),
    html.input([
      attribute.class("dt-input"),
      attribute.type_("date"),
      attribute.value(option.unwrap(current, "")),
      event.on_input(to_msg),
    ]),
  ])
}

fn month_select(
  label: String,
  current: Option(String),
  options: List(filter.FilterOption),
  to_msg: fn(String) -> Msg,
) -> Element(Msg) {
  let any =
    html.option(
      [attribute.value(""), attribute.selected(current == None)],
      "Any",
    )
  let choices =
    list.map(options, fn(option) {
      html.option(
        [
          attribute.value(option.value),
          attribute.selected(current == Some(option.value)),
        ],
        option.label,
      )
    })
  html.label([attribute.class("dt-field")], [
    html.span([], [html.text(label)]),
    html.select([attribute.class("dt-input"), event.on_change(to_msg)], [
      any,
      ..choices
    ]),
  ])
}

fn bool_widget(key: String, applied: Applied) -> Element(Msg) {
  let current = case dict.get(applied.filters, key) {
    Ok(BoolValue(True)) -> "true"
    Ok(BoolValue(False)) -> "false"
    _ -> "any"
  }
  html.div(
    [attribute.class("dt-options")],
    list.map([#("any", "Any"), #("true", "Yes"), #("false", "No")], fn(option) {
      let #(value, label) = option
      html.label([attribute.class("dt-option")], [
        html.input([
          attribute.type_("radio"),
          attribute.checked(value == current),
          event.on_check(fn(_checked) { BoolPicked(key, value) }),
        ]),
        html.span([], [html.text(label)]),
      ])
    }),
  )
}

fn bound_input(
  label: String,
  value: String,
  to_msg: fn(String) -> Msg,
) -> Element(Msg) {
  html.label([attribute.class("dt-field")], [
    html.span([], [html.text(label)]),
    html.input([
      attribute.class("dt-input"),
      attribute.type_("number"),
      attribute.value(value),
      event.on_input(to_msg),
    ]),
  ])
}

fn columns_panel(schema: Schema, state: State) -> Element(Msg) {
  let rows =
    list.map(state.order, fn(key) {
      case find_column(schema, key) {
        Some(column) -> columns_row(column, state)
        None -> element.none()
      }
    })
  html.div([attribute.class("dt-pop dt-cols")], [
    html.div([attribute.class("dt-pop__head")], [
      html.span([attribute.class("dt-pop__title")], [html.text("Columns")]),
      html.button(
        [attribute.class("dt-pop__clear"), event.on_click(LayoutReset)],
        [html.text("Reset layout")],
      ),
    ]),
    html.div([attribute.class("dt-cols__list")], rows),
  ])
}

fn columns_row(column: Column, state: State) -> Element(Msg) {
  let shown = !set.contains(state.hidden, column.key)
  let toggle = case column.hideable {
    True ->
      html.input([
        attribute.type_("checkbox"),
        attribute.attribute("aria-label", column.label),
        attribute.checked(shown),
        event.on_check(fn(_checked) { ColumnToggled(column.key) }),
      ])
    False ->
      html.span(
        [
          attribute.class("dt-cols__pinned"),
          attribute.attribute("title", "Pinned — this column can't be hidden"),
        ],
        [html.text("🔒")],
      )
  }
  let dragging_class = case state.dragging {
    Some(key) if key == column.key -> " dt-cols__row--dragging"
    _ -> ""
  }
  let over_class = case state.drag_over, state.dragging {
    Some(over), Some(drag) if over == column.key && drag != column.key ->
      " dt-cols__row--over"
    _, _ -> ""
  }
  html.div(
    [
      attribute.class("dt-cols__row" <> dragging_class <> over_class),
      attribute.attribute("draggable", "true"),
      event.on("dragstart", decode.success(DragStarted(column.key))),
      event.on("dragover", decode.success(DragOver(column.key)))
        |> event.prevent_default,
      event.on("drop", decode.success(Dropped(column.key)))
        |> event.prevent_default,
      event.on("dragend", decode.success(DragEnded)),
    ],
    [
      html.span([attribute.class("dt-cols__grip")], [html.text("⠿")]),
      toggle,
      html.span([attribute.class("dt-cols__label")], [html.text(column.label)]),
    ],
  )
}

fn table(
  schema: Schema,
  rows: List(Row),
  state: State,
  has_more: Bool,
) -> Element(Msg) {
  let columns = visible_columns(schema, state)
  let scroll_listener = case has_more {
    True -> [event.on("scroll", scroll_decoder()) |> event.throttle(150)]
    False -> []
  }
  html.div([attribute.class("dt-scroll"), ..scroll_listener], [
    html.table([], [
      html.thead([], [
        html.tr([], list.map(columns, fn(column) { header(column, state) })),
      ]),
      html.tbody([], body_rows(columns, rows, state.expanded)),
    ]),
  ])
}

/// Fire `ScrolledNearBottom` once the scroll viewport is within `scroll_threshold`
/// px of the end; otherwise the decoder fails and no message is dispatched.
fn scroll_decoder() -> Decoder(Msg) {
  use top <- decode.then(decode.at(["target", "scrollTop"], decode.float))
  use view_height <- decode.then(decode.at(
    ["target", "clientHeight"],
    decode.float,
  ))
  use full_height <- decode.then(decode.at(
    ["target", "scrollHeight"],
    decode.float,
  ))
  case top +. view_height +. scroll_threshold >=. full_height {
    True -> decode.success(ScrolledNearBottom)
    False -> decode.failure(ScrolledNearBottom, "not near bottom")
  }
}

fn body_rows(
  columns: List(Column),
  rows: List(Row),
  expanded: Set(String),
) -> List(Element(Msg)) {
  case rows {
    [] -> [
      html.tr([], [
        html.td(
          [attribute.attribute("colspan", int.to_string(list.length(columns)))],
          [
            ui.empty_state(message: "No rows match these filters."),
          ],
        ),
      ]),
    ]
    _ ->
      list.flat_map(rows, fn(row) {
        parent_with_children(columns, row, expanded)
      })
  }
}

/// A parent row, followed (when expanded) by either its child rows or — when the
/// row carries a `detail` payload — a single full-width detail panel. The first
/// column gets a disclosure toggle on an expandable row (one with children OR a
/// detail). Children render with the child class and are neither expandable nor
/// row-click navigable.
fn parent_with_children(
  columns: List(Column),
  row: Row,
  expanded: Set(String),
) -> List(Element(Msg)) {
  let is_expanded = set.contains(expanded, row.id)
  let parent = body_row(columns, row, is_expanded)
  case is_expanded {
    False -> [parent]
    True ->
      case row.children, row.detail {
        [], Some(detail) -> [parent, detail_panel(list.length(columns), detail)]
        [], None -> [parent]
        children, _ -> [parent, ..list.map(children, child_row(columns, _))]
      }
  }
}

/// A full-width detail panel row: one `<td>` spanning every visible column, holding
/// the pre-formatted `detail` text (e.g. a JSON payload) in a `<pre>` block.
fn detail_panel(span: Int, detail: String) -> Element(Msg) {
  html.tr([attribute.class("dt-row--detail")], [
    html.td([attribute.attribute("colspan", int.to_string(span))], [
      html.pre([attribute.class("dt-detail")], [html.text(detail)]),
    ]),
  ])
}

fn header(column: Column, state: State) -> Element(Msg) {
  let numeric = case column.align {
    NumericEnd -> "num "
    _ -> ""
  }
  let indicator = case column.sortable, state.applied.sort {
    True, Some(Sort(key, Asc)) if key == column.key -> " ▲"
    True, Some(Sort(key, Desc)) if key == column.key -> " ▼"
    _, _ -> ""
  }
  let attrs = case column.sortable {
    True -> [
      attribute.class(numeric <> "dt-th dt-th--sortable"),
      event.on_click(HeaderClicked(column.key)),
    ]
    False -> [attribute.class(numeric <> "dt-th")]
  }
  html.th(attrs, [html.text(column.label <> indicator)])
}

fn body_row(
  columns: List(Column),
  row: Row,
  is_expanded: Bool,
) -> Element(Msg) {
  let expandable = case row.children, row.detail {
    [], None -> False
    _, _ -> True
  }
  let on_row_click = case expandable {
    True -> RowExpandToggled(row.id)
    False -> RowClicked(row.id)
  }
  html.tr(
    [attribute.class("clickable"), event.on_click(on_row_click)],
    list.index_map(columns, fn(column, index) {
      let numeric = case column.align {
        NumericEnd -> [attribute.class("num")]
        _ -> []
      }
      let cell = case dict.get(row.cells, column.key) {
        Ok(ActionsCell(actions)) -> actions_cell(actions, row.id)
        Ok(value) -> render_cell(value)
        Error(Nil) -> element.none()
      }
      let content = case index == 0 && expandable {
        True -> [
          html.div([attribute.class("dt-cell-lead")], [
            disclosure(row.id, is_expanded),
            cell,
          ]),
        ]
        False -> [cell]
      }
      html.td(numeric, content)
    }),
  )
}

/// A child (nested) row: its cells via the normal renderer, marked with the child
/// class and the first cell indented. Children are not expandable and not row-click
/// navigable.
fn child_row(columns: List(Column), row: Row) -> Element(Msg) {
  html.tr(
    [attribute.class("dt-row--child")],
    list.index_map(columns, fn(column, index) {
      let numeric = case column.align {
        NumericEnd -> [attribute.class("num")]
        _ -> []
      }
      let indent = case index == 0 {
        True -> [attribute.class("dt-cell--indent")]
        False -> []
      }
      let content = case dict.get(row.cells, column.key) {
        Ok(ActionsCell(actions)) -> actions_cell(actions, row.id)
        Ok(value) -> render_cell(value)
        Error(Nil) -> element.none()
      }
      html.td(list.append(numeric, indent), [content])
    }),
  )
}

/// The expand/collapse disclosure control rendered in an expandable row's first
/// cell. Clicking toggles the row's `expanded` membership; the click stops
/// propagation so it does not also fire `RowClicked`.
fn disclosure(id: String, is_expanded: Bool) -> Element(Msg) {
  let glyph = case is_expanded {
    True -> "▾"
    False -> "▸"
  }
  html.button(
    [
      attribute.class("dt-disclosure"),
      event.on_click(RowExpandToggled(id)) |> event.stop_propagation,
    ],
    [html.text(glyph)],
  )
}

/// Render a cell by its variant. Exhaustive on `Cell` — a new variant fails the
/// build here until it can be drawn.
pub fn render_cell(cell: Cell) -> Element(msg) {
  case cell {
    TextCell(value) -> html.text(value)
    NumberCell(value) ->
      html.span([attribute.class("mono")], [html.text(number_text(value))])
    PercentCell(value) ->
      html.span([attribute.class("mono")], [html.text(ui.pct(value))])
    MoneyCell(value) ->
      html.span([attribute.class("mono")], [
        html.text(ui.money(money.to_float(value))),
      ])
    SignedMoneyCell(amount:, tone:) ->
      html.span(
        [attribute.class("mono dt-money dt-money--" <> tone_class(tone))],
        [
          html.text(ui.money(money.to_float(amount))),
        ],
      )
    DateCell(value) ->
      html.span([attribute.class("mono")], [html.text(time.format_month(value))])
    BoolCell(value) ->
      html.text(case value {
        True -> "Yes"
        False -> "No"
      })
    EnumCell(label:, tone:) ->
      html.span([attribute.class("pill pill--" <> tone_class(tone))], [
        html.text(label),
      ])
    EntityCell(label:, sub:, color:) ->
      html.span([attribute.class("cell-name")], [
        html.span(
          [
            attribute.class("swatch swatch--inline"),
            attribute.style("background", color),
          ],
          [],
        ),
        html.span([attribute.class("cell-name__text")], [
          html.span([attribute.class("cell-name__name")], [html.text(label)]),
          person_sub(sub),
        ]),
      ])
    PersonCell(name:, sub:, initials:, color:) ->
      html.span([attribute.class("cell-name")], [
        html.span(
          [attribute.class("avatar"), attribute.style("background", color)],
          [html.text(initials)],
        ),
        html.span([attribute.class("cell-name__text")], [
          html.span([attribute.class("cell-name__name")], [html.text(name)]),
          person_sub(sub),
        ]),
      ])
    ChipsCell(chips) -> {
      let shown = list.take(chips, 3)
      let extra = list.length(chips) - list.length(shown)
      let avatars = list.index_map(shown, render_chip)
      let more = case extra > 0 {
        True -> [
          html.span([attribute.class("chip chip--more")], [
            html.text("+" <> int.to_string(extra)),
          ]),
        ]
        False -> []
      }
      html.div([attribute.class("chips")], list.append(avatars, more))
    }
    ActionsCell(_) -> element.none()
  }
}

/// The action buttons for a row's `ActionsCell`. Rendered in the row builder
/// (not `render_cell`) so each button carries the row id alongside the action id,
/// dispatching `ActionInvoked(action.id, row_id)`. Clicks stop propagation so an
/// action does not also trigger the row's `RowClicked`.
fn actions_cell(actions: List(Action), row_id: String) -> Element(Msg) {
  html.div(
    [attribute.class("dt-actions")],
    list.map(actions, fn(action) {
      html.button(
        [
          attribute.class("dt-action"),
          event.on_click(ActionInvoked(action.id, row_id))
            |> event.stop_propagation,
        ],
        [html.text(action.label)],
      )
    }),
  )
}

fn person_sub(sub: Option(String)) -> Element(msg) {
  case sub {
    Some(text) -> html.span([attribute.class("cell-sub")], [html.text(text)])
    None -> element.none()
  }
}

fn render_chip(chip: Chip, index: Int) -> Element(msg) {
  let bucket = result_or(int.modulo(index, 7), 0) + 1
  let color = case chip.color {
    Some(value) -> value
    None -> "var(--cat-" <> int.to_string(bucket) <> ")"
  }
  case chip.initials {
    Some(initials) ->
      html.span(
        [
          attribute.class("avatar avatar--chip"),
          attribute.style("background", color),
        ],
        [html.text(initials)],
      )
    None ->
      html.span([attribute.class("chip chip--neutral")], [html.text(chip.label)])
  }
}

/// The pill modifier for a tone. Exhaustive on `Tone`.
pub fn tone_class(tone: Tone) -> String {
  case tone {
    Neutral -> "neutral"
    Accent -> "accent"
    Positive -> "positive"
    Warning -> "warning"
    Critical -> "critical"
  }
}

/// A footer shown only while the next page is loading (infinite scroll). The total
/// row count is not displayed — the server does not return it, so a loaded-so-far
/// count would be misleading.
fn footer(state: State) -> Element(Msg) {
  case state.loading_more {
    True ->
      html.div([attribute.class("dt-foot")], [
        html.span([attribute.class("dt-foot__loading")], [html.text("Loading…")]),
      ])
    False -> element.none()
  }
}

// --- helpers ----------------------------------------------------------------

fn visible_columns(schema: Schema, state: State) -> List(Column) {
  state.order
  |> list.filter_map(fn(key) { option_to_result(find_column(schema, key)) })
  |> list.filter(fn(column) { !set.contains(state.hidden, column.key) })
}

fn find_column(schema: Schema, key: String) -> Option(Column) {
  case list.find(schema.columns, fn(column) { column.key == key }) {
    Ok(column) -> Some(column)
    Error(Nil) -> None
  }
}

fn option_to_result(value: Option(a)) -> Result(a, Nil) {
  case value {
    Some(inner) -> Ok(inner)
    None -> Error(Nil)
  }
}

fn number_text(value: Float) -> String {
  case value == int.to_float(float.truncate(value)) {
    True -> int.to_string(float.truncate(value))
    False -> float.to_string(value)
  }
}

fn float_text(value: Option(Float)) -> String {
  case value {
    Some(number) -> number_text(number)
    None -> ""
  }
}
