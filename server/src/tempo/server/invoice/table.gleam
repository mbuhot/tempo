//// Domain: the invoices generic-table read (data-table system). Builds the table
//// `Schema` the client renders from (with live Client/Project/Team select options),
//// then runs ONE filtered/sorted/paged query and maps each row to typed `Cell`s.
////
//// The list query is hand-bound with `pog` rather than Squirrel: every advertised
//// filter is an optional `(param IS NULL OR col matches param)` guard, and Squirrel
//// never infers nullable params — so binding real NULLs needs the raw query and a
//// hand-written row decoder. Sort is a `CASE`-driven `ORDER BY` over the sortable
//// columns; pagination is `LIMIT/OFFSET`, with the opaque cursor encoding the next
//// offset (so true keyset can replace the internals later with no wire change).

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/money.{type Money}
import shared/pagination
import shared/table/cell.{
  type Chip, Chip, ChipsCell, DateCell, EntityCell, EnumCell, MoneyCell,
  NumberCell, TextCell,
}
import shared/table/column.{
  type Schema, type Tone, ChipsType, Column, DateType, EntityType, EnumType,
  MoneyType, Neutral, NumberType, NumericEnd, Positive, Schema, Start, TextType,
  Warning,
}
import shared/table/filter.{
  DateRangeFilter, FilterOption, NumberRangeFilter, SelectFilter,
}
import shared/table/query.{
  type Applied, type FilterValue, DateRange, NumberRange, SelectValue,
}
import shared/table/response.{
  type Row, type TableResponse, Page, Row, TableResponse,
}
import shared/table/sort.{type Sort, Desc, Sort}
import shared/wire
import tempo/server/context.{type Context}

const default_sort_key = "billing_month"

/// One filtered/sorted/paged slice of the invoices table, plus the schema the client
/// renders from. `applied` is the parsed filter/sort/page request. Runs the filter-
/// options query (for the live select choices), then the list query.
pub fn invoice_table(
  context: Context,
  as_of: Date,
  applied: Applied,
) -> Result(TableResponse, pog.QueryError) {
  use options <- result.try(filter_options(context, as_of))
  let schema = invoice_schema(options)
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

/// The static invoices schema, with the Client/Project/Team select options filled
/// from the live `options` (the distinct values that appear on invoices).
pub fn invoice_schema(options: FilterOptions) -> Schema {
  Schema(
    table_id: "invoices",
    default_sort: Some(Sort(key: default_sort_key, dir: Desc)),
    columns: [
      Column(
        key: "id",
        label: "#",
        column_type: NumberType,
        align: NumericEnd,
        sortable: True,
        hideable: False,
        filter: None,
      ),
      Column(
        key: "project",
        label: "Project",
        column_type: EntityType,
        align: Start,
        sortable: True,
        hideable: True,
        filter: Some(select(options.projects)),
      ),
      Column(
        key: "client",
        label: "Client",
        column_type: TextType,
        align: Start,
        sortable: True,
        hideable: True,
        filter: Some(select(options.clients)),
      ),
      Column(
        key: "engineers",
        label: "Team",
        column_type: ChipsType,
        align: Start,
        sortable: False,
        hideable: True,
        filter: Some(select(options.engineers)),
      ),
      Column(
        key: "billing_month",
        label: "Billing month",
        column_type: DateType,
        align: Start,
        sortable: True,
        hideable: True,
        filter: Some(DateRangeFilter),
      ),
      Column(
        key: "total",
        label: "Total",
        column_type: MoneyType,
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
            FilterOption(value: "draft", label: "Draft"),
            FilterOption(value: "issued", label: "Issued"),
            FilterOption(value: "paid", label: "Paid"),
          ]),
        ),
      ),
    ],
  )
}

fn select(values: List(String)) -> filter.FilterKind {
  SelectFilter(
    multi: True,
    options: list.map(values, fn(value) { FilterOption(value:, label: value) }),
  )
}

// --- filter options ---------------------------------------------------------

/// The distinct Client / Project / Team values that appear on invoices, for the
/// select filters' option lists.
pub type FilterOptions {
  FilterOptions(
    clients: List(String),
    projects: List(String),
    engineers: List(String),
  )
}

fn filter_options(
  context: Context,
  _as_of: Date,
) -> Result(FilterOptions, pog.QueryError) {
  let row_decoder = {
    use clients <- decode.field(0, decode.list(decode.string))
    use projects <- decode.field(1, decode.list(decode.string))
    use engineers <- decode.field(2, decode.list(decode.string))
    decode.success(FilterOptions(clients:, projects:, engineers:))
  }
  use returned <- result.map(
    pog.query(filter_options_sql)
    |> pog.returning(row_decoder)
    |> pog.execute(on: context.db),
  )
  case returned.rows {
    [row, ..] -> row
    [] -> FilterOptions(clients: [], projects: [], engineers: [])
  }
}

const filter_options_sql = "
SELECT
  coalesce((SELECT array_agg(DISTINCT name ORDER BY name) FROM (
    SELECT client.name
      FROM invoice_subject
      JOIN project_run ON project_run.project_id = invoice_subject.project_id
      JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
      JOIN client_current client ON client.id = contract_terms.client_id
  ) clients), '{}'::text[]) AS clients,
  coalesce((SELECT array_agg(DISTINCT title ORDER BY title) FROM (
    SELECT project.title
      FROM invoice_subject
      JOIN project_current project ON project.id = invoice_subject.project_id
  ) projects), '{}'::text[]) AS projects,
  coalesce((SELECT array_agg(DISTINCT name ORDER BY name) FROM (
    SELECT engineer.name
      FROM invoice_line
      JOIN engineer_current engineer ON engineer.id = invoice_line.engineer_id
  ) engineers), '{}'::text[]) AS engineers
"

// --- list query -------------------------------------------------------------

type ListRow {
  ListRow(
    id: Int,
    project: String,
    client: String,
    billing_from: Date,
    billing_to: Date,
    status: String,
    total: String,
    engineers: List(String),
    issued_at: Option(Date),
    paid_at: Option(Date),
  )
}

fn run_list(
  context: Context,
  as_of: Date,
  applied: Applied,
  limit: Int,
  offset: Int,
) -> Result(pog.Returned(ListRow), pog.QueryError) {
  let status = select_param(applied.filters, "status")
  let client = select_param(applied.filters, "client")
  let project = select_param(applied.filters, "project")
  let engineers = select_param(applied.filters, "engineers")
  let #(total_lo, total_hi) = number_bounds(applied.filters, "total")
  let #(billing_lo, billing_hi) = date_bounds(applied.filters, "billing_month")
  let #(sort_key, sort_dir) = sort_params(applied.sort)

  pog.query(list_sql)
  |> pog.parameter(pog.calendar_date(as_of))
  |> pog.parameter(pog.nullable(text_array, status))
  |> pog.parameter(pog.nullable(text_array, client))
  |> pog.parameter(pog.nullable(text_array, project))
  |> pog.parameter(pog.nullable(text_array, engineers))
  |> pog.parameter(pog.nullable(pog.calendar_date, billing_lo))
  |> pog.parameter(pog.nullable(pog.calendar_date, billing_hi))
  |> pog.parameter(pog.nullable(pog.float, total_lo))
  |> pog.parameter(pog.nullable(pog.float, total_hi))
  |> pog.parameter(pog.text(sort_key))
  |> pog.parameter(pog.text(sort_dir))
  |> pog.parameter(pog.int(limit + 1))
  |> pog.parameter(pog.int(offset))
  |> pog.returning(list_row_decoder())
  |> pog.execute(on: context.db)
}

fn text_array(values: List(String)) -> pog.Value {
  pog.array(pog.text, values)
}

fn list_row_decoder() -> Decoder(ListRow) {
  use id <- decode.field(0, decode.int)
  use project <- decode.field(1, decode.string)
  use client <- decode.field(2, decode.string)
  use billing_from <- decode.field(3, pog.calendar_date_decoder())
  use billing_to <- decode.field(4, pog.calendar_date_decoder())
  use status <- decode.field(5, decode.string)
  use total <- decode.field(6, decode.string)
  use engineers <- decode.field(7, decode.list(decode.string))
  use issued_at <- decode.field(8, decode.optional(pog.calendar_date_decoder()))
  use paid_at <- decode.field(9, decode.optional(pog.calendar_date_decoder()))
  decode.success(ListRow(
    id:,
    project:,
    client:,
    billing_from:,
    billing_to:,
    status:,
    total:,
    engineers:,
    issued_at:,
    paid_at:,
  ))
}

const list_sql = "
SELECT * FROM (
  SELECT
    invoice.id,
    coalesce((SELECT project.title FROM project_current project
              WHERE project.id = invoice_subject.project_id LIMIT 1), '') AS project,
    coalesce((SELECT client.name FROM project_run
              JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
              JOIN client_current client ON client.id = contract_terms.client_id
              WHERE project_run.project_id = invoice_subject.project_id LIMIT 1), '') AS client,
    lower(invoice_subject.billing_period) AS billing_from,
    upper(invoice_subject.billing_period) AS billing_to,
    invoice_status.status,
    coalesce((SELECT sum(invoice_line.amount) FROM invoice_line
              WHERE invoice_line.invoice_id = invoice.id), 0)::text AS total,
    coalesce((SELECT array_agg(DISTINCT engineer.name ORDER BY engineer.name)
                FROM invoice_line
                JOIN engineer_current engineer ON engineer.id = invoice_line.engineer_id
               WHERE invoice_line.invoice_id = invoice.id), '{}'::text[]) AS engineers,
    (SELECT lower(issued.status_during) FROM invoice_status issued
      WHERE issued.invoice_id = invoice.id AND issued.status = 'issued'
        AND lower(issued.status_during) <= $1::date LIMIT 1) AS issued_at,
    (SELECT lower(paid.status_during) FROM invoice_status paid
      WHERE paid.invoice_id = invoice.id AND paid.status = 'paid'
        AND lower(paid.status_during) <= $1::date LIMIT 1) AS paid_at
  FROM invoice
  JOIN invoice_subject ON invoice_subject.invoice_id = invoice.id
  JOIN invoice_status ON invoice_status.invoice_id = invoice.id
                     AND invoice_status.status_during @> $1::date
) page
WHERE ($2::text[] IS NULL OR page.status = ANY($2::text[]))
  AND ($3::text[] IS NULL OR page.client = ANY($3::text[]))
  AND ($4::text[] IS NULL OR page.project = ANY($4::text[]))
  AND ($5::text[] IS NULL OR page.engineers && $5::text[])
  AND ($6::date IS NULL OR page.billing_from >= $6::date)
  AND ($7::date IS NULL OR page.billing_from <= $7::date)
  AND ($8::numeric IS NULL OR page.total::numeric >= $8::numeric)
  AND ($9::numeric IS NULL OR page.total::numeric <= $9::numeric)
ORDER BY
  CASE WHEN $10 = 'total'   AND $11 = 'asc'  THEN page.total::numeric END ASC,
  CASE WHEN $10 = 'total'   AND $11 = 'desc' THEN page.total::numeric END DESC,
  CASE WHEN $10 = 'client'  AND $11 = 'asc'  THEN page.client END ASC,
  CASE WHEN $10 = 'client'  AND $11 = 'desc' THEN page.client END DESC,
  CASE WHEN $10 = 'project' AND $11 = 'asc'  THEN page.project END ASC,
  CASE WHEN $10 = 'project' AND $11 = 'desc' THEN page.project END DESC,
  CASE WHEN $10 = 'status'  AND $11 = 'asc'  THEN page.status END ASC,
  CASE WHEN $10 = 'status'  AND $11 = 'desc' THEN page.status END DESC,
  CASE WHEN $10 = 'id'      AND $11 = 'asc'  THEN page.id END ASC,
  CASE WHEN $10 = 'id'      AND $11 = 'desc' THEN page.id END DESC,
  CASE WHEN $11 = 'asc'  THEN page.billing_from END ASC,
  CASE WHEN $11 = 'desc' THEN page.billing_from END DESC,
  page.id
LIMIT $12::int OFFSET $13::int
"

// --- filter params ----------------------------------------------------------

fn select_param(
  filters: Dict(String, FilterValue),
  key: String,
) -> Option(List(String)) {
  case dict.get(filters, key) {
    Ok(SelectValue([])) -> None
    Ok(SelectValue(values)) -> Some(values)
    _ -> None
  }
}

fn number_bounds(
  filters: Dict(String, FilterValue),
  key: String,
) -> #(Option(Float), Option(Float)) {
  case dict.get(filters, key) {
    Ok(NumberRange(min:, max:)) -> #(min, max)
    _ -> #(None, None)
  }
}

fn date_bounds(
  filters: Dict(String, FilterValue),
  key: String,
) -> #(Option(Date), Option(Date)) {
  case dict.get(filters, key) {
    Ok(DateRange(from:, to:)) -> #(parse_date(from), parse_date(to))
    _ -> #(None, None)
  }
}

fn parse_date(text: Option(String)) -> Option(Date) {
  case text {
    Some(value) -> option.from_result(wire.parse_iso_date(value))
    None -> None
  }
}

fn sort_params(sort: Option(Sort)) -> #(String, String) {
  case sort {
    Some(Sort(key:, dir:)) -> #(key, sort.dir_to_string(dir))
    None -> #(default_sort_key, "desc")
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
    id: int.to_string(row.id),
    cells: dict.from_list([
      #("id", NumberCell(int.to_float(row.id))),
      #("project", EntityCell(label: row.project, color: swatch_color(row.id))),
      #("client", TextCell(row.client)),
      #("engineers", ChipsCell(list.map(row.engineers, to_chip))),
      #("billing_month", DateCell(row.billing_from)),
      #("total", MoneyCell(parse_money(row.total))),
      #(
        "status",
        EnumCell(label: capitalize(row.status), tone: status_tone(row.status)),
      ),
    ]),
  )
}

fn to_chip(name: String) -> Chip {
  Chip(label: name, initials: Some(initials(name)), color: None)
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

fn status_tone(status: String) -> Tone {
  case status {
    "issued" -> Warning
    "paid" -> Positive
    _ -> Neutral
  }
}

fn capitalize(text: String) -> String {
  case string.pop_grapheme(text) {
    Ok(#(head, tail)) -> string.uppercase(head) <> tail
    Error(Nil) -> text
  }
}

fn parse_money(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}
