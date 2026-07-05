//// The generic, schema-driven data table's STATE: the layout/filter/sort/page
//// state every list page's host owns, its `Msg` vocabulary, and the `update`
//// returning an `Outcome` telling the host page what to do (re-query, append a
//// page, persist the layout, or schedule a debounce tick), so the page keeps the
//// one `api.get`/effect seam. It owns no data fetching. Rendering lives in
//// `client/table/render`.

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import shared/table/column.{type Schema}
import shared/table/query.{
  type Applied, type FilterValue, Applied, BoolValue, DateRange, NumberRange,
  SelectValue, TextValue,
}
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

/// The storage key for this table's layout preference, scoped to the signed-in user
/// so two people sharing a browser don't clobber each other's column layouts.
pub fn layout_key(state: State, scope: String) -> String {
  "tempo." <> scope <> ".table." <> state.table_id <> ".layout"
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
  let typed = case value {
    "" -> None
    _ -> Some(value)
  }
  let #(min, max) = case bound {
    Min -> #(typed, max)
    Max -> #(min, typed)
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
