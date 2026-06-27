//// Domain: the clients generic-table read (data-table system). Builds the table
//// `Schema` the client renders from, then runs ONE filtered/sorted/paged query and
//// maps each row to typed `Cell`s.
////
//// The list query is hand-bound with `pog` rather than Squirrel: every advertised
//// filter is an optional `(param IS NULL OR col matches param)` guard bound as a
//// real param, and the only request-derived strings that reach the SQL text are
//// sort keys, gated through `sort_column`'s allowlist. Sort is `ORDER BY` over the
//// sortable columns; pagination is `LIMIT/OFFSET`, the opaque cursor encoding the
//// next offset.
////
//// The page subquery mirrors `client_list.sql` (one row per client that has COME
//// INTO EXISTENCE by `as_of` — id, name, earliest-contract `since`, distinct project
//// count, and `active` = any contract covering `as_of`) and derives a single
//// `status` category ('active' / 'ended') the client renders as a toned pill.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/pagination
import shared/table/cell.{type Cell, DateCell, EntityCell, EnumCell, NumberCell}
import shared/table/column.{
  type Schema, Column, DateType, EntityType, EnumType, Neutral, NumberType,
  NumericEnd, Positive, Schema, Start,
}
import shared/table/filter.{FilterOption, NumberRangeFilter, SelectFilter}
import shared/table/query.{type Applied}
import shared/table/response.{
  type Row, type TableResponse, Page, Row, TableResponse,
}
import shared/table/sort.{Asc, Sort}
import tempo/server/context.{type Context}
import tempo/server/table/builder

const default_sort_key = "name"

/// One filtered/sorted/paged slice of the clients table, plus the schema the client
/// renders from. `applied` is the parsed filter/sort/page request. The status filter's
/// options are fixed (active / ended), so the schema needs no live options query.
pub fn client_table(
  context: Context,
  as_of: Date,
  applied: Applied,
) -> Result(TableResponse, pog.QueryError) {
  let schema = client_schema()
  let offset = decode_offset(applied.cursor)
  let limit = applied.page_size
  use returned <- result.map(run_list(context, as_of, applied, limit, offset))
  let fetched = returned.rows
  let page_rows = list.take(fetched, limit)
  let next_cursor = case list.length(fetched) > limit {
    True -> Some(encode_offset(offset + limit))
    False -> None
  }
  TableResponse(
    schema:,
    rows: list.map(page_rows, row_to_table_row),
    page: Page(next_cursor:),
  )
}

// --- schema -----------------------------------------------------------------

/// The static clients schema. The Status select offers the two derived categories;
/// Projects offers a number range; the client name is the un-hideable lead column.
pub fn client_schema() -> Schema {
  Schema(
    table_id: "clients",
    child_columns: None,
    default_sort: Some(Sort(key: default_sort_key, dir: Asc)),
    filters: [],
    columns: [
      Column(
        key: "name",
        label: "Client",
        column_type: EntityType,
        align: Start,
        sortable: True,
        hideable: False,
        filter: None,
      ),
      Column(
        key: "since",
        label: "Since",
        column_type: DateType,
        align: Start,
        sortable: True,
        hideable: True,
        filter: None,
      ),
      Column(
        key: "projects",
        label: "Projects",
        column_type: NumberType,
        align: NumericEnd,
        sortable: True,
        hideable: True,
        filter: Some(NumberRangeFilter),
      ),
      Column(
        key: "status",
        label: "Status",
        column_type: EnumType,
        align: Start,
        sortable: True,
        hideable: True,
        filter: Some(
          SelectFilter(multi: True, options: [
            FilterOption(value: "active", label: "Active"),
            FilterOption(value: "ended", label: "Ended"),
          ]),
        ),
      ),
    ],
  )
}

/// The schema with its column filter KINDS — all the web boundary needs to parse the
/// applied filters out of the query params.
pub fn filter_schema() -> Schema {
  client_schema()
}

// --- list query -------------------------------------------------------------

type ListRow {
  ListRow(
    client_id: Int,
    name: String,
    since: Option(Date),
    projects: Int,
    status: String,
  )
}

/// Composes the list query with the generic `builder`: `as_of` is bound first (`$1`,
/// referenced throughout the fixed `page` subquery), each present filter folds in one
/// `WHERE` condition binding its own param, and `LIMIT/OFFSET` bind last. The ORDER BY
/// column comes from `sort_column`'s allowlist, so no sort value reaches SQL.
fn run_list(
  context: Context,
  as_of: Date,
  applied: Applied,
  limit: Int,
  offset: Int,
) -> Result(pog.Returned(ListRow), pog.QueryError) {
  let filters = applied.filters
  let #(projects_lo, projects_hi) = builder.number_range_of(filters, "projects")

  let filtered =
    builder.new([pog.calendar_date(as_of)])
    |> builder.select("page.status", builder.select_values(filters, "status"))
    |> builder.number_range("page.projects", projects_lo, projects_hi)

  let effective_sort =
    option.or(applied.sort, Some(Sort(key: default_sort_key, dir: Asc)))
  let #(built, paging) = builder.limit_offset(filtered, limit + 1, offset)
  let sql =
    page_subquery
    <> builder.where_clause(built)
    <> builder.order_by(
      effective_sort,
      default_sort_key,
      sort_column,
      "page.client_id ASC",
    )
    <> paging

  list.fold(builder.params(built), pog.query(sql), pog.parameter)
  |> pog.returning(list_row_decoder())
  |> pog.execute(on: context.db)
}

fn list_row_decoder() -> Decoder(ListRow) {
  use client_id <- decode.field(0, decode.int)
  use name <- decode.field(1, decode.string)
  use since <- decode.field(2, decode.optional(pog.calendar_date_decoder()))
  use projects <- decode.field(3, decode.int)
  use status <- decode.field(4, decode.string)
  decode.success(ListRow(client_id:, name:, since:, projects:, status:))
}

const page_subquery = "
SELECT * FROM (
  SELECT
    client.id AS client_id,
    coalesce(client_current.name, '') AS name,
    (
      SELECT min(lower(contract_terms.term))
        FROM contract_terms
       WHERE contract_terms.client_id = client.id
    ) AS since,
    (
      SELECT count(DISTINCT project_run.project_id)
        FROM contract_terms
        JOIN project_run ON project_run.contract_id = contract_terms.contract_id
       WHERE contract_terms.client_id = client.id
    )::int AS projects,
    CASE WHEN coalesce((
      SELECT bool_or(contract_terms.term @> $1::date)
        FROM contract_terms
       WHERE contract_terms.client_id = client.id
    ), false) THEN 'active' ELSE 'ended' END AS status
  FROM client
  JOIN client_current ON client_current.id = client.id
  WHERE EXISTS (
    SELECT 1
      FROM contract_terms
     WHERE contract_terms.client_id = client.id
       AND lower(contract_terms.term) <= $1::date
  )
) page"

// --- sort -------------------------------------------------------------------

/// Maps a request sort key to its trusted SQL column, falling back to name for an
/// absent or unknown key. The allowlist is the injection boundary for sorting.
fn sort_column(key: String) -> String {
  case key {
    "since" -> "page.since"
    "projects" -> "page.projects"
    "status" -> "page.status"
    _ -> "page.name"
  }
}

// --- cursor (offset) --------------------------------------------------------

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

// --- row to cells -----------------------------------------------------------

fn row_to_table_row(row: ListRow) -> Row {
  Row(
    id: int.to_string(row.client_id),
    cells: dict.from_list([
      #(
        "name",
        EntityCell(
          label: row.name,
          sub: None,
          color: swatch_color(row.client_id),
        ),
      ),
      #("since", since_cell(row.since)),
      #("projects", NumberCell(int.to_float(row.projects))),
      #("status", status_cell(row.status)),
    ]),
    children: [],
    detail: None,
  )
}

/// The toned status pill for the derived status category.
fn status_cell(status: String) -> Cell {
  case status {
    "active" -> EnumCell(label: "Active", tone: Positive)
    _ -> EnumCell(label: "Ended", tone: Neutral)
  }
}

fn since_cell(since: Option(Date)) -> Cell {
  case since {
    Some(date) -> DateCell(date)
    None -> EnumCell(label: "—", tone: Neutral)
  }
}

fn swatch_color(id: Int) -> String {
  let bucket = result.unwrap(int.modulo(id, 7), 0) + 1
  "var(--cat-" <> int.to_string(bucket) <> ")"
}
