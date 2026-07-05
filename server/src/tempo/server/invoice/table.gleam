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

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/invoice/status.{Draft, Issued, Paid}
import shared/money
import shared/pagination
import shared/table/cell.{
  type Chip, Category, Chip, ChipsCell, DateCell, EntityCell, EnumCell,
  MoneyCell, TextCell,
}
import shared/table/column.{
  type Schema, type Tone, ChipsType, Column, DateType, EntityType, EnumType,
  MoneyType, Neutral, NumericEnd, Positive, Schema, Start, TextType, Warning,
}
import shared/table/filter.{
  type FilterOption, DateRangeFilter, FilterOption, NumberRangeFilter,
  SelectFilter,
}
import shared/table/query.{type Applied}
import shared/table/response.{
  type Row, type TableResponse, Page, Row, TableResponse,
}
import shared/table/sort.{Desc, Sort}
import tempo/server/context.{type Context}
import tempo/server/table/builder

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
  let offset = pagination.decode_offset(applied.cursor)
  let limit = applied.page_size
  use returned <- result.map(run_list(context, as_of, applied, limit, offset))
  let fetched = returned.rows
  let page_rows = list.take(fetched, limit)
  let next_cursor = case list.length(fetched) > limit {
    True -> Some(pagination.encode_offset(offset + limit))
    False -> None
  }
  TableResponse(
    schema:,
    rows: list.map(page_rows, row_to_table_row),
    page: Page(next_cursor:),
    footer: None,
  )
}

// --- schema -----------------------------------------------------------------

/// The static invoices schema, with the Client/Project/Team select options filled
/// from the live `options` (the distinct values that appear on invoices).
pub fn invoice_schema(options: FilterOptions) -> Schema {
  Schema(
    table_id: "invoices",
    child_columns: None,
    default_sort: Some(Sort(key: default_sort_key, dir: Desc)),
    filters: [],
    columns: [
      Column(
        key: "id",
        label: "#",
        column_type: TextType,
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
        filter: Some(DateRangeFilter(options: month_options(options.months))),
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
            FilterOption(value: status.to_string(Draft), label: "Draft"),
            FilterOption(value: status.to_string(Issued), label: "Issued"),
            FilterOption(value: status.to_string(Paid), label: "Paid"),
          ]),
        ),
      ),
    ],
  )
}

/// The schema with empty select options — its column filter KINDS are all the web
/// boundary needs to parse the applied filters out of the query params (the live
/// options matter only in the response the full read builds).
pub fn filter_schema() -> Schema {
  invoice_schema(
    FilterOptions(clients: [], projects: [], engineers: [], months: []),
  )
}

fn select(values: List(String)) -> filter.FilterKind {
  SelectFilter(
    multi: True,
    options: list.map(values, fn(value) { FilterOption(value:, label: value) }),
  )
}

/// Turn the distinct billing-month start dates ("2026-06-01") into From/To dropdown
/// options: the ISO date is the value the range filter compares, the label is the
/// human month ("Jun 2026").
fn month_options(months: List(String)) -> List(FilterOption) {
  list.map(months, fn(month) {
    FilterOption(value: month, label: month_label(month))
  })
}

fn month_label(iso: String) -> String {
  month_name(string.slice(iso, 5, 2)) <> " " <> string.slice(iso, 0, 4)
}

fn month_name(number: String) -> String {
  case number {
    "01" -> "Jan"
    "02" -> "Feb"
    "03" -> "Mar"
    "04" -> "Apr"
    "05" -> "May"
    "06" -> "Jun"
    "07" -> "Jul"
    "08" -> "Aug"
    "09" -> "Sep"
    "10" -> "Oct"
    "11" -> "Nov"
    "12" -> "Dec"
    _ -> number
  }
}

// --- filter options ---------------------------------------------------------

/// The distinct Client / Project / Team values that appear on invoices, for the
/// select filters' option lists.
pub type FilterOptions {
  FilterOptions(
    clients: List(String),
    projects: List(String),
    engineers: List(String),
    months: List(String),
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
    use months <- decode.field(3, decode.list(decode.string))
    decode.success(FilterOptions(clients:, projects:, engineers:, months:))
  }
  use returned <- result.map(
    pog.query(filter_options_sql)
    |> pog.returning(row_decoder)
    |> pog.execute(on: context.db),
  )
  case returned.rows {
    [row, ..] -> row
    [] -> FilterOptions(clients: [], projects: [], engineers: [], months: [])
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
  ) engineers), '{}'::text[]) AS engineers,
  coalesce((SELECT array_agg(m ORDER BY m DESC) FROM (
    SELECT DISTINCT to_char(lower(billing_period), 'YYYY-MM-DD') AS m
      FROM invoice_subject
  ) months), '{}'::text[]) AS months
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

/// Composes the list query with the generic `builder`: `as_of` is bound first
/// (`$1`, referenced throughout the fixed `page` subquery), each present filter folds
/// in one `WHERE` condition binding its own param, and `LIMIT/OFFSET` bind last. The
/// ORDER BY column comes from `sort_column`'s allowlist, so no sort value reaches SQL.
fn run_list(
  context: Context,
  as_of: Date,
  applied: Applied,
  limit: Int,
  offset: Int,
) -> Result(pog.Returned(ListRow), pog.QueryError) {
  let filters = applied.filters
  let #(billing_lo, billing_hi) =
    builder.date_range_of(filters, "billing_month")
  let #(total_lo, total_hi) = builder.number_range_of(filters, "total")

  let filtered =
    builder.new([pog.calendar_date(as_of)])
    |> builder.select("page.status", builder.select_values(filters, "status"))
    |> builder.select("page.client", builder.select_values(filters, "client"))
    |> builder.select("page.project", builder.select_values(filters, "project"))
    |> builder.overlaps(
      "page.engineers",
      builder.select_values(filters, "engineers"),
    )
    |> builder.date_range("page.billing_from", billing_lo, billing_hi)
    |> builder.number_range("page.total::numeric", total_lo, total_hi)

  let #(built, paging) = builder.limit_offset(filtered, limit + 1, offset)
  let sql =
    page_subquery
    <> builder.where_clause(built)
    <> builder.order_by(
      applied.sort,
      default_sort_key,
      sort_column,
      "page.id DESC",
    )
    <> paging

  list.fold(builder.params(built), pog.query(sql), pog.parameter)
  |> pog.returning(list_row_decoder())
  |> pog.execute(on: context.db)
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

const page_subquery = "
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
) page"

// --- sort -------------------------------------------------------------------

/// Maps a request sort key to its trusted SQL column, falling back to billing month
/// for an absent or unknown key. The allowlist is the injection boundary for sorting.
fn sort_column(key: String) -> String {
  case key {
    "total" -> "page.total::numeric"
    "client" -> "page.client"
    "project" -> "page.project"
    "status" -> "page.status"
    "id" -> "page.id"
    _ -> "page.billing_from"
  }
}

// --- row to cells -----------------------------------------------------------

fn row_to_table_row(row: ListRow) -> Row {
  Row(
    id: int.to_string(row.id),
    cells: dict.from_list([
      #("id", TextCell("#" <> int.to_string(row.id))),
      #(
        "project",
        EntityCell(label: row.project, sub: None, swatch: Category(row.id)),
      ),
      #("client", TextCell(row.client)),
      #("engineers", ChipsCell(list.map(row.engineers, to_chip))),
      #("billing_month", DateCell(Some(row.billing_from))),
      #("total", MoneyCell(money.trusted_from_string(row.total))),
      #(
        "status",
        EnumCell(label: capitalize(row.status), tone: status_tone(row.status)),
      ),
    ]),
    children: [],
    detail: None,
  )
}

fn to_chip(name: String) -> Chip {
  Chip(label: name, initials: Some(initials(name)))
}

fn initials(name: String) -> String {
  string.split(name, " ")
  |> list.filter_map(string.first)
  |> list.take(2)
  |> string.concat
  |> string.uppercase
}

fn status_tone(status_text: String) -> Tone {
  let assert Ok(parsed) = status.from_string(status_text)
  case parsed {
    Draft -> Neutral
    Issued -> Warning
    Paid -> Positive
  }
}

fn capitalize(text: String) -> String {
  case string.pop_grapheme(text) {
    Ok(#(head, tail)) -> string.uppercase(head) <> tail
    Error(Nil) -> text
  }
}
