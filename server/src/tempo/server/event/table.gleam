//// Domain: the Activity journal as a generic data-table read (data-table system).
//// Builds the table `Schema` the client renders from — three columns (When, Actor,
//// Event) plus three SCHEMA-LEVEL filters that don't map to a displayed column
//// (operation, actor, an occurred date-range) — then runs ONE filtered, paged query
//// newest-first and maps each row to typed `Cell`s, carrying the pretty-printed JSON
//// payload as the row's full-width `detail` panel.
////
//// The feed is SYSTEM time (`occurred_at`), independent of the valid-time as-of rail.
//// The standalone filters are bound via the generic `builder` (operation/actor as
//// multi-select `= ANY`, occurred as a date-range over `occurred_at::date`); the order
//// and pagination are the journal's existing keyset by descending id, encoded into the
//// opaque cursor (`web/cursor.encode_id`).

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pog
import shared/pagination
import shared/table/cell.{type Cell, PersonCell, TextCell}
import shared/table/column.{
  type Schema, PersonType, Schema, StandaloneFilter, Start, TextType,
}
import shared/table/filter.{
  type FilterKind, DateRangeFilter, FilterOption, SelectFilter,
}
import shared/table/query.{type Applied}
import shared/table/response.{
  type Row, type TableResponse, Page, Row, TableResponse,
}
import tempo/server/context.{type Context}
import tempo/server/table/builder
import tempo/server/web/cursor

/// One filtered, paged slice of the Activity journal newest-first, plus the schema
/// the client renders from. `applied` is the parsed filter/page request. Runs the
/// filter-options query (the live distinct operations/actors for the select choices),
/// then the keyset list query.
pub fn events_table(
  context: Context,
  applied: Applied,
) -> Result(TableResponse, pog.QueryError) {
  use options <- result.try(filter_options(context))
  let schema = events_schema(options)
  let limit = applied.page_size
  let after = decode_cursor(applied.cursor)
  use returned <- result.map(run_list(context, applied, after, limit))
  let #(rows, next_cursor) =
    pagination.paginate(returned.rows, limit, fn(row: ListRow) {
      cursor.encode_id(row.id)
    })
  TableResponse(
    schema:,
    rows: list.map(rows, row_to_table_row),
    page: Page(next_cursor:),
  )
}

// --- schema -----------------------------------------------------------------

/// The Activity table schema: three columns — When (the full event timestamp as
/// TextType, since events carry a time-of-day the date-only wire `DateType` cannot
/// represent), Actor (PersonType, with avatar), and Event (TextType, the human
/// summary) — and three schema-level filters keyed off no displayed column:
/// operation and actor multi-selects (live distinct values), plus an `occurred`
/// date-range for the recorded-between window. No per-column filters or sort.
pub fn events_schema(options: FilterOptions) -> Schema {
  Schema(
    table_id: "events",
    child_columns: None,
    default_sort: None,
    filters: [
      StandaloneFilter(
        key: "operation",
        label: "Operation",
        kind: select(options.operations),
      ),
      StandaloneFilter(
        key: "actor",
        label: "Actor",
        kind: select(options.actors),
      ),
      StandaloneFilter(
        key: "occurred",
        label: "Recorded",
        kind: DateRangeFilter(options: []),
      ),
    ],
    columns: [
      column("when", "When (UTC)", TextType),
      column("actor", "Actor", PersonType),
      column("event", "Event", TextType),
    ],
  )
}

/// The schema with empty select options — its filter KINDS are all the web boundary
/// needs to parse the applied filters out of the query params (the live options
/// matter only in the response the full read builds).
pub fn filter_schema() -> Schema {
  events_schema(FilterOptions(operations: [], actors: []))
}

fn column(key: String, label: String, column_type) -> column.Column {
  column.Column(
    key:,
    label:,
    column_type:,
    align: Start,
    sortable: False,
    hideable: False,
    filter: None,
  )
}

fn select(values: List(String)) -> FilterKind {
  SelectFilter(
    multi: True,
    options: list.map(values, fn(value) { FilterOption(value:, label: value) }),
  )
}

// --- filter options ---------------------------------------------------------

/// The distinct operations and actors that appear in the journal, for the
/// schema-level select filters' option lists.
pub type FilterOptions {
  FilterOptions(operations: List(String), actors: List(String))
}

fn filter_options(context: Context) -> Result(FilterOptions, pog.QueryError) {
  let row_decoder = {
    use operations <- decode.field(0, decode.list(decode.string))
    use actors <- decode.field(1, decode.list(decode.string))
    decode.success(FilterOptions(operations:, actors:))
  }
  use returned <- result.map(
    pog.query(filter_options_sql)
    |> pog.returning(row_decoder)
    |> pog.execute(on: context.db),
  )
  case returned.rows {
    [row, ..] -> row
    [] -> FilterOptions(operations: [], actors: [])
  }
}

const filter_options_sql = "
SELECT
  coalesce((SELECT array_agg(DISTINCT operation ORDER BY operation)
              FROM event_log), '{}'::text[]) AS operations,
  coalesce((SELECT array_agg(DISTINCT actor ORDER BY actor)
              FROM event_log), '{}'::text[]) AS actors
"

// --- list query -------------------------------------------------------------

type ListRow {
  ListRow(
    id: Int,
    occurred_at: String,
    actor: String,
    operation: String,
    summary: String,
    payload: String,
  )
}

/// Composes the keyset list query with the generic `builder`: the descending-id
/// keyset bound is bound first (`$1`, the `id < $1` page predicate), each present
/// standalone filter folds in one `WHERE` condition binding its own param
/// (operation/actor as `= ANY`, occurred as a date-range over `occurred_at::date`),
/// and the page LIMIT binds last. Fetches `limit + 1` so the look-ahead row tells
/// `paginate` whether a further page exists. Order is fixed `id DESC` (the journal's
/// keyset), so no sort value reaches SQL.
fn run_list(
  context: Context,
  applied: Applied,
  after: Int,
  limit: Int,
) -> Result(pog.Returned(ListRow), pog.QueryError) {
  let filters = applied.filters
  let #(occurred_lo, occurred_hi) = builder.date_range_of(filters, "occurred")

  let filtered =
    builder.new([pog.int(after)])
    |> builder.condition("id < $1::bigint")
    |> builder.select("operation", builder.select_values(filters, "operation"))
    |> builder.select("actor", builder.select_values(filters, "actor"))
    |> builder.date_range("occurred_at::date", occurred_lo, occurred_hi)

  let #(built, limit_placeholder) = builder.bind(filtered, pog.int(limit + 1))
  let sql =
    list_prefix
    <> builder.where_clause(built)
    <> " ORDER BY id DESC LIMIT "
    <> limit_placeholder
    <> "::int"

  list.fold(builder.params(built), pog.query(sql), pog.parameter)
  |> pog.returning(list_row_decoder())
  |> pog.execute(on: context.db)
}

const list_prefix = "SELECT
  id,
  occurred_at::text,
  actor,
  operation,
  summary,
  payload::text
FROM event_log"

fn list_row_decoder() -> Decoder(ListRow) {
  use id <- decode.field(0, decode.int)
  use occurred_at <- decode.field(1, decode.string)
  use actor <- decode.field(2, decode.string)
  use operation <- decode.field(3, decode.string)
  use summary <- decode.field(4, decode.string)
  use payload <- decode.field(5, decode.string)
  decode.success(ListRow(
    id:,
    occurred_at:,
    actor:,
    operation:,
    summary:,
    payload:,
  ))
}

// --- cursor (id keyset) -----------------------------------------------------

/// The descending-id keyset upper bound from the opaque cursor: absent (or
/// malformed) ⇒ the first-page sentinel above every id, so `id < bound` admits the
/// whole journal.
fn decode_cursor(token: Option(String)) -> Int {
  case token {
    None -> cursor.id_ceiling
    Some(value) ->
      case cursor.decode_id(value) {
        Ok(cursor.IdBound(id:)) -> id
        Error(Nil) -> cursor.id_ceiling
      }
  }
}

// --- row to cells -----------------------------------------------------------

fn row_to_table_row(row: ListRow) -> Row {
  Row(
    id: int.to_string(row.id),
    cells: dict.from_list([
      #("when", TextCell(string.slice(row.occurred_at, 0, 19))),
      #("actor", actor_cell(row.actor)),
      #("event", TextCell(event_summary(row.operation, row.summary))),
    ]),
    children: [],
    detail: Some(pretty_payload(row.payload)),
  )
}

/// A human one-line summary for the Event column: the operation tag and the recorded
/// summary, joined when both are present.
fn event_summary(operation: String, summary: String) -> String {
  case string.trim(summary) {
    "" -> operation
    text -> operation <> " · " <> text
  }
}

fn actor_cell(actor: String) -> Cell {
  PersonCell(
    name: actor,
    sub: None,
    initials: initials(actor),
    color: actor_color(actor),
  )
}

fn initials(name: String) -> String {
  string.split(name, " ")
  |> list.filter_map(string.first)
  |> list.take(2)
  |> string.concat
  |> string.uppercase
}

/// A stable category tint for an actor's avatar, derived from the name so the same
/// person always gets the same colour (mirrors the prototype's `actor_category`).
fn actor_color(actor: String) -> String {
  let sum =
    string.to_utf_codepoints(actor)
    |> list.fold(0, fn(acc, codepoint) {
      acc + string.utf_codepoint_to_int(codepoint)
    })
  let bucket = result.unwrap(int.modulo(sum, 7), 0) + 1
  "var(--cat-" <> int.to_string(bucket) <> ")"
}

/// Pretty-print the compact JSON payload string for the row's detail panel by
/// re-indenting it: structural punctuation outside string literals (`{`, `[`, `,`,
/// `:`) drives the line breaks and a two-space indent level, while characters inside
/// a string literal (tracking `\"` escapes) pass through verbatim. A payload that
/// isn't well-formed JSON still renders readably — the scanner never throws, it just
/// echoes the text — so the panel is always populated.
fn pretty_payload(payload: String) -> String {
  indent(string.to_graphemes(payload), Outside, 0, "")
}

type Scan {
  Outside
  InString
  Escaped
}

fn indent(chars: List(String), scan: Scan, depth: Int, acc: String) -> String {
  case chars {
    [] -> acc
    [char, ..rest] ->
      case scan {
        Escaped -> indent(rest, InString, depth, acc <> char)
        InString ->
          case char {
            "\\" -> indent(rest, Escaped, depth, acc <> char)
            "\"" -> indent(rest, Outside, depth, acc <> char)
            _ -> indent(rest, InString, depth, acc <> char)
          }
        Outside ->
          case char {
            "\"" -> indent(rest, InString, depth, acc <> char)
            "{" | "[" -> {
              let depth = depth + 1
              indent(rest, Outside, depth, acc <> char <> newline(depth))
            }
            "}" | "]" -> {
              let depth = depth - 1
              indent(rest, Outside, depth, acc <> newline(depth) <> char)
            }
            "," -> indent(rest, Outside, depth, acc <> char <> newline(depth))
            ":" -> indent(rest, Outside, depth, acc <> char <> " ")
            " " -> indent(rest, Outside, depth, acc)
            _ -> indent(rest, Outside, depth, acc <> char)
          }
      }
  }
}

fn newline(depth: Int) -> String {
  "\n" <> string.repeat("  ", depth)
}
