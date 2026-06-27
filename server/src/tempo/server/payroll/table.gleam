//// Domain: the payroll generic-table read (data-table system). Builds the table
//// `Schema` the client renders from and one filtered/sorted/paged slice of the
//// payroll panel, where each top-level row is an engineer total and its `children`
//// are the per-salary-level segment sub-rows.
////
//// The payroll panel has THREE modes the user switches between, passed as a `mode`
//// query param (preview / reconciled / variance); each advertises its own columns
//// and breaks each engineer total down into the matching segments:
////   * preview    — the LIVE recompute: Engineer · Days · Preview amount;
////   * reconciled — the FROZEN paid run: Engineer · Days · Paid amount;
////   * variance   — paid vs should-be with the per-line Δ: Engineer · Paid ·
////     Should be · Δ. A child segment carries no paid/Δ figure, so the Paid and Δ
////     columns hold a neutral zero (MoneyCell/SignedMoneyCell) on child rows — one
////     cell type per column, keeping the table contract intact.
////
//// The figures come from the canonical `payroll/view.payroll` read (the same model
//// the legacy panel rendered), so the table and the headline read can never drift.
//// Outer-row filtering (an engineer-name substring and an amount range) and sorting
//// (an allowlist over the outer columns) run in Gleam over the bounded engineer
//// list; the from/to window is fixed by the request, not part of the table state.

import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/money.{type Money}
import shared/pagination
import shared/payroll/view.{type PayrollLine, type PayrollSegment}
import shared/table/cell.{
  type Cell, MoneyCell, NumberCell, PersonCell, SignedMoneyCell, TextCell,
}
import shared/table/column.{
  type Column, type Schema, type Tone, Column, Critical, MoneyType, Neutral,
  NumberType, NumericEnd, PersonType, Positive, Schema, SignedMoneyType, Start,
  TextType,
}
import shared/table/filter.{NumberRangeFilter, TextFilter}
import shared/table/query.{
  type Applied, type FilterValue, NumberRange, TextValue,
}
import shared/table/response.{
  type Row, type TableResponse, Page, Row, TableResponse,
}
import shared/table/sort.{type Sort, Asc, Desc, Sort}
import tempo/server/context.{type Context}
import tempo/server/payroll/view as payroll_read

/// The payroll table mode: which columns and breakdown the panel shows.
pub type Mode {
  Preview
  Reconciled
  Variance
}

/// Parse the `mode` query param; defaults to `Preview` for an absent or unknown
/// value (the live recompute is the safe default before any run exists).
pub fn mode_from_string(text: Option(String)) -> Mode {
  case text {
    Some("reconciled") -> Reconciled
    Some("variance") -> Variance
    _ -> Preview
  }
}

const default_sort_key = "engineer"

/// One filtered/sorted/paged slice of the payroll table for `mode`, plus the schema
/// the client renders from. The engineer totals are the top-level rows; each row's
/// `children` are its per-level segment sub-rows.
pub fn payroll_table(
  context: Context,
  period_from: Date,
  period_to: Date,
  mode: Mode,
  applied: Applied,
) -> Result(TableResponse, pog.QueryError) {
  use payroll <- result.map(payroll_read.payroll(
    context,
    period_from,
    period_to,
  ))
  let schema = payroll_schema(mode)
  let rows =
    payroll.lines
    |> list.map(fn(line) { line_to_row(line, mode) })
    |> filter_rows(applied.filters)
    |> sort_rows(applied.sort)

  let offset = decode_offset(applied.cursor)
  let limit = applied.page_size
  let page_rows =
    rows
    |> list.drop(offset)
    |> list.take(limit)
    |> list.map(fn(built) { built.row })
  let next_cursor = case list.length(rows) > offset + limit {
    True -> Some(encode_offset(offset + limit))
    False -> None
  }
  TableResponse(schema:, rows: page_rows, page: Page(next_cursor:))
}

// --- schema -----------------------------------------------------------------

/// The payroll schema for `mode`. Preview/reconciled share the Engineer · Days ·
/// amount shape; variance shows Paid · Should be · Δ.
pub fn payroll_schema(mode: Mode) -> Schema {
  let engineer =
    Column(
      key: "engineer",
      label: "Engineer",
      column_type: PersonType,
      align: Start,
      sortable: True,
      hideable: False,
      filter: Some(TextFilter),
    )
  let columns = case mode {
    Preview -> [
      engineer,
      days_column,
      amount_column("amount", "Preview"),
    ]
    Reconciled -> [
      engineer,
      days_column,
      amount_column("amount", "Paid"),
    ]
    Variance -> [
      engineer,
      amount_column("paid", "Paid"),
      amount_column("should_be", "Should be"),
      delta_column,
    ]
  }
  Schema(
    table_id: "payroll-" <> mode_to_string(mode),
    default_sort: Some(Sort(key: default_sort_key, dir: Asc)),
    filters: [],
    columns:,
    child_columns: Some(child_columns(mode)),
  )
}

/// The nested (child-row) columns for `mode`. The first column shares the
/// `engineer` key with the outer column so child cells align beneath it, but its
/// type is `TextType`: a child row holds the segment label as a `TextCell`, while
/// the parent engineer row holds a `PersonCell`. The remaining columns carry the
/// same keys and types as the outer columns.
fn child_columns(mode: Mode) -> List(Column) {
  case mode {
    Preview | Reconciled -> [
      child_engineer_column,
      days_column,
      amount_column("amount", "Amount"),
    ]
    Variance -> [
      child_engineer_column,
      amount_column("paid", "Paid"),
      amount_column("should_be", "Should be"),
      delta_column,
    ]
  }
}

const child_engineer_column = Column(
  key: "engineer",
  label: "Engineer",
  column_type: TextType,
  align: Start,
  sortable: False,
  hideable: False,
  filter: None,
)

const days_column = Column(
  key: "days",
  label: "Days",
  column_type: NumberType,
  align: NumericEnd,
  sortable: True,
  hideable: True,
  filter: None,
)

const delta_column = Column(
  key: "delta",
  label: "Δ",
  column_type: SignedMoneyType,
  align: NumericEnd,
  sortable: True,
  hideable: True,
  filter: Some(NumberRangeFilter),
)

fn amount_column(key: String, label: String) -> Column {
  Column(
    key:,
    label:,
    column_type: MoneyType,
    align: NumericEnd,
    sortable: True,
    hideable: True,
    filter: Some(NumberRangeFilter),
  )
}

/// The schema the web boundary parses applied filters against. The filter KINDS are
/// all it needs, so this is just the mode's schema.
pub fn filter_schema(mode: Mode) -> Schema {
  payroll_schema(mode)
}

// --- rows -------------------------------------------------------------------

/// The amount a row is sorted/filtered by, and the segments used for its children,
/// depend on the mode. We keep both alongside the built `Row` so the filter/sort
/// passes can read the figure without re-deriving it from the cells.
type BuiltRow {
  BuiltRow(row: Row, engineer: String, amount: Money, delta: Money)
}

fn line_to_row(line: PayrollLine, mode: Mode) -> BuiltRow {
  case mode {
    Preview ->
      total_row(
        line,
        amount_key: "amount",
        amount: line.preview_amount,
        days: line.preview_days,
        segments: line.preview_segments,
      )
    Reconciled ->
      total_row(
        line,
        amount_key: "amount",
        amount: option.unwrap(line.paid_amount, money.zero()),
        days: option.unwrap(line.paid_days, 0.0),
        segments: line.paid_segments,
      )
    Variance -> variance_row(line)
  }
}

/// A preview/reconciled engineer total row: Engineer · Days · amount, with the
/// per-level segments as child rows.
fn total_row(
  line: PayrollLine,
  amount_key amount_key: String,
  amount amount: Money,
  days days: Float,
  segments segments: List(PayrollSegment),
) -> BuiltRow {
  let cells =
    dict.from_list([
      #("engineer", engineer_cell(line)),
      #("days", NumberCell(days)),
      #(amount_key, MoneyCell(amount)),
    ])
  let children = list.map(segments, fn(segment) { total_child(segment) })
  BuiltRow(
    row: Row(id: row_id(line), cells:, children:, detail: None),
    engineer: line.engineer,
    amount:,
    delta: money.zero(),
  )
}

fn total_child(segment: PayrollSegment) -> Row {
  Row(
    id: child_id(segment),
    cells: dict.from_list([
      #("engineer", TextCell(segment_label(segment))),
      #("days", NumberCell(segment.days)),
      #("amount", MoneyCell(segment.amount)),
    ]),
    children: [],
    detail: None,
  )
}

/// A variance engineer total row: Engineer · Paid · Should be · Δ. The should-be
/// per-level breakdown is the child rows; a child carries a neutral zero in the
/// Paid and Δ columns (one cell type per column).
fn variance_row(line: PayrollLine) -> BuiltRow {
  let paid = option.unwrap(line.paid_amount, money.zero())
  let should_be = line.preview_amount
  let delta = money.subtract(should_be, paid)
  let cells =
    dict.from_list([
      #("engineer", engineer_cell(line)),
      #("paid", MoneyCell(paid)),
      #("should_be", MoneyCell(should_be)),
      #("delta", SignedMoneyCell(amount: delta, tone: delta_tone(delta))),
    ])
  let children =
    list.map(line.preview_segments, fn(segment) { variance_child(segment) })
  BuiltRow(
    row: Row(id: row_id(line), cells:, children:, detail: None),
    engineer: line.engineer,
    amount: paid,
    delta:,
  )
}

fn variance_child(segment: PayrollSegment) -> Row {
  Row(
    id: child_id(segment),
    cells: dict.from_list([
      #("engineer", TextCell(segment_label(segment))),
      #("paid", MoneyCell(money.zero())),
      #("should_be", MoneyCell(segment.amount)),
      #("delta", SignedMoneyCell(amount: money.zero(), tone: Neutral)),
    ]),
    children: [],
    detail: None,
  )
}

fn engineer_cell(line: PayrollLine) -> Cell {
  PersonCell(
    name: line.engineer,
    sub: None,
    initials: initials(line.engineer),
    color: swatch_color(line.engineer_id),
  )
}

/// A segment's row label: the seniority band and the monthly salary in force.
fn segment_label(segment: PayrollSegment) -> String {
  "↳ "
  <> level_band(segment.level)
  <> " · "
  <> money_text(segment.monthly_salary)
  <> "/mo"
}

/// Δ reads good when the run paid at least the should-be (no back-pay owed),
/// critical when back-pay is owed, neutral when exactly reconciled.
fn delta_tone(delta: Money) -> Tone {
  case money.compare(delta, money.zero()) {
    order.Gt -> Critical
    order.Eq -> Neutral
    order.Lt -> Positive
  }
}

// --- filter / sort (outer rows only) ----------------------------------------

/// Apply the outer-row filters: an engineer-name substring and an amount range over
/// the mode's headline amount column. Child segment rows are never filtered.
fn filter_rows(
  rows: List(BuiltRow),
  filters: dict.Dict(String, FilterValue),
) -> List(BuiltRow) {
  let name = text_of(filters, "engineer")
  let #(amount_lo, amount_hi) = number_range_of(filters)
  list.filter(rows, fn(built) {
    name_matches(built.engineer, name)
    && amount_in_range(built, amount_lo, amount_hi, filters)
  })
}

fn name_matches(engineer: String, query: Option(String)) -> Bool {
  case query {
    None -> True
    Some(needle) ->
      string.contains(string.lowercase(engineer), string.lowercase(needle))
  }
}

/// The amount range applies to whichever column the active filter names: the
/// headline amount (`amount`/`paid`) or the variance `delta`.
fn amount_in_range(
  built: BuiltRow,
  lo: Option(Float),
  hi: Option(Float),
  filters: dict.Dict(String, FilterValue),
) -> Bool {
  let value = case dict.has_key(filters, "delta") {
    True -> money.to_float(built.delta)
    False -> money.to_float(built.amount)
  }
  within(value, lo, hi)
}

fn within(value: Float, lo: Option(Float), hi: Option(Float)) -> Bool {
  let above = case lo {
    Some(min) -> value >=. min
    None -> True
  }
  let below = case hi {
    Some(max) -> value <=. max
    None -> True
  }
  above && below
}

fn text_of(
  filters: dict.Dict(String, FilterValue),
  key: String,
) -> Option(String) {
  case dict.get(filters, key) {
    Ok(TextValue("")) -> None
    Ok(TextValue(text)) -> Some(text)
    _ -> None
  }
}

fn number_range_of(
  filters: dict.Dict(String, FilterValue),
) -> #(Option(Float), Option(Float)) {
  let from = fn(key) {
    case dict.get(filters, key) {
      Ok(NumberRange(min:, max:)) -> Some(#(min, max))
      _ -> None
    }
  }
  case from("amount"), from("paid"), from("delta") {
    Some(bounds), _, _ -> bounds
    _, Some(bounds), _ -> bounds
    _, _, Some(bounds) -> bounds
    _, _, _ -> #(None, None)
  }
}

/// Sort the outer rows by the allowlisted key; an unknown key falls back to the
/// engineer name. The default (no sort) is engineer ascending.
fn sort_rows(rows: List(BuiltRow), sort: Option(Sort)) -> List(BuiltRow) {
  let Sort(key:, dir:) = option.unwrap(sort, Sort(default_sort_key, Asc))
  let compare = comparator(key)
  let sorted =
    list.sort(rows, fn(a, b) {
      case dir {
        Asc -> compare(a, b)
        Desc -> order.negate(compare(a, b))
      }
    })
  sorted
}

fn comparator(key: String) -> fn(BuiltRow, BuiltRow) -> order.Order {
  case key {
    "days" -> fn(a: BuiltRow, b: BuiltRow) {
      float.compare(row_days(a), row_days(b))
    }
    "amount" | "paid" | "should_be" -> fn(a: BuiltRow, b: BuiltRow) {
      money.compare(a.amount, b.amount)
    }
    "delta" -> fn(a: BuiltRow, b: BuiltRow) { money.compare(a.delta, b.delta) }
    _ -> fn(a: BuiltRow, b: BuiltRow) { string.compare(a.engineer, b.engineer) }
  }
}

fn row_days(built: BuiltRow) -> Float {
  case dict.get(built.row.cells, "days") {
    Ok(NumberCell(days)) -> days
    _ -> 0.0
  }
}

// --- ids / cursor -----------------------------------------------------------

fn row_id(line: PayrollLine) -> String {
  int.to_string(line.engineer_id)
}

fn child_id(segment: PayrollSegment) -> String {
  "level-" <> int.to_string(segment.level)
}

fn encode_offset(offset: Int) -> String {
  pagination.encode_cursor([int.to_string(offset)])
}

fn decode_offset(cursor: Option(String)) -> Int {
  case cursor {
    None -> 0
    Some(token) ->
      case pagination.decode_cursor(token, 1) {
        Ok([text]) -> result.unwrap(int.parse(text), 0)
        _ -> 0
      }
  }
}

// --- helpers ----------------------------------------------------------------

fn mode_to_string(mode: Mode) -> String {
  case mode {
    Preview -> "preview"
    Reconciled -> "reconciled"
    Variance -> "variance"
  }
}

fn money_text(amount: Money) -> String {
  let value = money.to_float(amount)
  let whole = float.truncate(value)
  case int.to_float(whole) == value {
    True -> "$" <> int.to_string(whole)
    False -> "$" <> float.to_string(value)
  }
}

fn initials(name: String) -> String {
  string.split(name, " ")
  |> list.filter_map(string.first)
  |> list.take(2)
  |> string.concat
  |> string.uppercase
}

fn swatch_color(id: Int) -> String {
  let bucket = result.unwrap(int.modulo(id, 7), 0) + 1
  "var(--cat-" <> int.to_string(bucket) <> ")"
}

fn level_band(level: Int) -> String {
  case level {
    1 -> "Associate"
    2 -> "Engineer"
    3 -> "Senior"
    4 -> "Staff"
    5 -> "Principal"
    6 -> "Distinguished"
    7 -> "Fellow"
    _ -> "Engineer"
  }
}
