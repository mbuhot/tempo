//// The generic data table's rendering: the filter rail (per-column chips with
//// anchored popovers and the filter widgets), the columns manager, the scrolling
//// row grid with disclosure/detail rows, the exhaustive cell renderer
//// (`render_cell`), and the footer. State and `update` live in `client/table`;
//// this module only emits its `Msg`s.

import client/table.{
  type Msg, type State, ActionInvoked, BoolPicked, Closed, ColumnToggled,
  ColumnsButtonClicked, ColumnsPanel, DateBoundPicked, DragEnded, DragOver,
  DragStarted, Dropped, FilterButtonClicked, FilterCleared, FilterPanel, From,
  HeaderClicked, LayoutReset, Max, Min, NumberBoundTyped, PanelDismissed,
  ResetAll, RowClicked, RowExpandToggled, ScrolledNearBottom, SelectToggled,
  TextTyped, To,
}
import client/time
import client/ui/atoms
import client/ui/format
import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import shared/money
import shared/table/cell.{
  type Action, type Cell, type Chip, type Swatch, ActionsCell, BoolCell,
  Category, ChipsCell, DateCell, EntityCell, EnumCell, Level, MoneyCell,
  NumberCell, PercentCell, PersonCell, Placeholder, SignedMoneyCell, TextCell,
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
  type Applied, BoolValue, DateRange, NumberRange, SelectValue, TextValue,
}
import shared/table/response.{type Footer, type Row}
import shared/table/sort.{Asc, Desc, Sort}

/// How close to the bottom of the scroll viewport (px) before the next page loads.
const scroll_threshold = 160.0

// --- view -------------------------------------------------------------------

/// Render the whole table: the filter rail (each filterable column a chip with an
/// anchored popover), the scrolling rows (infinite scroll when `has_more`), and the
/// footer. `has_more` reflects the host page's `next_cursor`.
pub fn view(
  schema: Schema,
  rows: List(Row),
  state: State,
  has_more: Bool,
  table_footer: Option(Footer),
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
    table(schema, rows, state, has_more, table_footer),
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
    html.span(
      [
        attribute.class("dt-rail__label"),
        attribute.attribute("aria-label", "Filter"),
        attribute.attribute("title", "Filter"),
      ],
      [funnel_icon()],
    ),
    html.div([attribute.class("dt-rail__chips")], chips),
    html.div([attribute.class("dt-rail__spacer")], []),
    reset,
    columns_chip(schema, state),
  ])
}

/// The funnel glyph that labels the filter rail — the familiar filter affordance.
fn funnel_icon() -> Element(Msg) {
  svg.svg(
    [
      attribute.attribute("viewBox", "0 0 24 24"),
      attribute.attribute("width", "15"),
      attribute.attribute("height", "15"),
      attribute.attribute("fill", "none"),
      attribute.attribute("stroke", "currentColor"),
      attribute.attribute("stroke-width", "2"),
      attribute.attribute("stroke-linecap", "round"),
      attribute.attribute("stroke-linejoin", "round"),
      attribute.attribute("aria-hidden", "true"),
    ],
    [
      svg.path([
        attribute.attribute(
          "d",
          "M22 3 L2 3 L10 12.46 L10 19 L14 21 L14 12.46 Z",
        ),
      ]),
    ],
  )
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
    bound_input("Min", option.unwrap(min, ""), NumberBoundTyped(key, Min, _)),
    html.span([attribute.class("dt-range__sep")], [html.text("–")]),
    bound_input("Max", option.unwrap(max, ""), NumberBoundTyped(key, Max, _)),
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
      attribute.type_("text"),
      attribute.attribute("inputmode", "decimal"),
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
  table_footer: Option(Footer),
) -> Element(Msg) {
  let columns = visible_columns(schema, state)
  let scroll_listener = case has_more {
    True -> [event.on("scroll", scroll_decoder()) |> event.throttle(150)]
    False -> []
  }
  html.div(
    [
      attribute.class("dt-scroll"),
      attribute.role("group"),
      attribute.aria_label(
        string.capitalise(schema.table_id) <> " table scroll",
      ),
      ..scroll_listener
    ],
    [
      html.table([], [
        html.thead([], [
          html.tr([], list.map(columns, fn(column) { header(column, state) })),
        ]),
        html.tbody([], body_rows(columns, rows, state.expanded)),
        foot_row(columns, table_footer),
      ]),
    ],
  )
}

/// The summary `<tfoot>` row, when the response carries a footer. The first visible
/// column shows the footer's `label`; each later column shows its typed cell (via the
/// same `render_cell` as the body, with the column's numeric alignment) when the
/// footer carries one for that key, else an empty cell. No disclosure, no row click.
fn foot_row(
  columns: List(Column),
  table_footer: Option(Footer),
) -> Element(Msg) {
  case table_footer {
    None -> element.none()
    Some(footer) ->
      html.tfoot([], [
        html.tr(
          [attribute.class("dt-foot-row")],
          list.index_map(columns, fn(column, index) {
            case index == 0 {
              True ->
                html.td([attribute.class("dt-foot-row__label")], [
                  html.text(footer.label),
                ])
              False -> {
                let numeric = case column.align {
                  NumericEnd -> [attribute.class("num")]
                  _ -> []
                }
                let content = case dict.get(footer.cells, column.key) {
                  Ok(value) -> [render_cell(value)]
                  Error(Nil) -> []
                }
                html.td(numeric, content)
              }
            }
          }),
        ),
      ])
  }
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
            atoms.empty_state(message: "No rows match these filters."),
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
      html.span([attribute.class("mono")], [html.text(format.pct(value))])
    MoneyCell(value) ->
      html.span([attribute.class("mono")], [
        html.text(format.money(money.to_float(value))),
      ])
    SignedMoneyCell(amount:, tone:) ->
      html.span(
        [attribute.class("mono dt-money dt-money--" <> tone_class(tone))],
        [
          html.text(format.money(money.to_float(amount))),
        ],
      )
    DateCell(value) ->
      html.span([attribute.class("mono")], [
        html.text(case value {
          Some(date) -> time.format_month(date)
          None -> "—"
        }),
      ])
    BoolCell(value) ->
      html.text(case value {
        True -> "Yes"
        False -> "No"
      })
    EnumCell(label:, tone:) ->
      html.span([attribute.class("pill pill--" <> tone_class(tone))], [
        html.text(label),
      ])
    EntityCell(label:, sub:, swatch:) ->
      html.span([attribute.class("cell-name")], [
        html.span(
          [
            attribute.class("swatch swatch--inline"),
            attribute.style("background", swatch_color(swatch)),
          ],
          [],
        ),
        html.span([attribute.class("cell-name__text")], [
          html.span([attribute.class("cell-name__name")], [html.text(label)]),
          person_sub(sub),
        ]),
      ])
    PersonCell(name:, sub:, initials:, category:) ->
      html.span([attribute.class("cell-name")], [
        html.span(
          [
            attribute.class("avatar"),
            attribute.style("background", atoms.cat_color(category)),
          ],
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
  case chip.initials {
    Some(initials) ->
      html.span(
        [
          attribute.class("avatar avatar--chip"),
          attribute.style("background", atoms.cat_color(index)),
        ],
        [html.text(initials)],
      )
    None ->
      html.span([attribute.class("chip chip--neutral")], [html.text(chip.label)])
  }
}

/// The CSS token a swatch resolves to: a categorical id buckets to the `--cat-N`
/// ramp, a level indexes the `--lvl-N` seniority ramp, a placeholder takes the
/// neutral border token. Exhaustive on `Swatch`.
fn swatch_color(swatch: Swatch) -> String {
  case swatch {
    Category(id) -> atoms.cat_color(id)
    Level(level) -> atoms.lvl_color(level)
    Placeholder -> "var(--color-border)"
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
