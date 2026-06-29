//// Domain: the people-roster generic-table read (data-table system). Builds the
//// table `Schema` the client renders from (with live Level select options), then
//// runs ONE filtered/sorted/paged query and maps each row to typed `Cell`s.
////
//// The list query is hand-bound with `pog` rather than Squirrel: every advertised
//// filter is an optional `(param IS NULL OR col matches param)` guard bound as a
//// real param, and the only request-derived strings that reach the SQL text are
//// sort keys, gated through `sort_column`'s allowlist. Sort is `ORDER BY` over the
//// sortable columns; pagination is `LIMIT/OFFSET`, the opaque cursor encoding the
//// next offset.
////
//// The page subquery mirrors `people_list.sql` (one row per EMPLOYED engineer as of
//// `as_of` — id, name, email, level, day_rate, summed allocation fraction, covering
//// leave kind, allocated project titles) plus the annual leave balance, and derives
//// a single `status` category ('on_projects' / 'on_leave' / 'unassigned') the client
//// renders as a toned pill.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/access
import shared/level
import shared/money.{type Money}
import shared/pagination
import shared/table/cell.{
  type Cell, EntityCell, EnumCell, MoneyCell, NumberCell, PercentCell,
  PersonCell, Placeholder,
}
import shared/table/column.{
  type Schema, Accent, Column, EntityType, EnumType, MoneyType, Neutral,
  NumberType, NumericEnd, PercentType, PersonType, Positive, Schema, Start,
  Warning,
}
import shared/table/filter.{FilterOption, NumberRangeFilter, SelectFilter}
import shared/table/query.{type Applied}
import shared/table/response.{
  type Row, type TableResponse, Page, Row, TableResponse,
}
import shared/table/sort.{Asc, Sort}
import tempo/server/auth
import tempo/server/context.{type Context}
import tempo/server/table/builder

const default_sort_key = "name"

/// One filtered/sorted/paged slice of the people roster, plus the schema the client
/// renders from. `applied` is the parsed filter/sort/page request. Runs the filter-
/// options query (for the live Level select choices), then the list query.
pub fn people_table(
  context: Context,
  as_of: Date,
  applied: Applied,
) -> Result(TableResponse, pog.QueryError) {
  use options <- result.try(filter_options(context, as_of))
  let schema = people_schema(options)
  let offset = decode_offset(applied.cursor)
  let limit = applied.page_size
  use returned <- result.try(run_list(context, as_of, applied, limit, offset))
  // In-progress onboardings are not engineers yet, so they ride atop the FIRST page
  // (offset 0) regardless of filters/sort — a small set, always visible to resume.
  use drafts <- result.map(case offset {
    0 -> onboarding_draft_rows(context)
    _ -> Ok([])
  })
  let fetched = returned.rows
  let page_rows = list.take(fetched, limit)
  let next_cursor = case list.length(fetched) > limit {
    True -> Some(encode_offset(offset + limit))
    False -> None
  }
  let rows =
    list.append(
      list.map(drafts, draft_row_to_table_row),
      list.map(page_rows, row_to_table_row),
    )
  TableResponse(schema:, rows:, page: Page(next_cursor:), footer: None)
}

// --- in-progress onboarding drafts ------------------------------------------

type DraftRow {
  DraftRow(instance_id: String, name: String, status: String)
}

/// The in-progress onboarding drafts, with the engineer's entered name (the open
/// transaction-time value of identity.full_name) and lifecycle status. These appear
/// as rows in the roster so a manager/Finance can resume them.
fn onboarding_draft_rows(
  context: Context,
) -> Result(List(DraftRow), pog.QueryError) {
  let #(account_id, can_commit) = draft_scope(context)
  let row_decoder = {
    use instance_id <- decode.field(0, decode.string)
    use name <- decode.field(1, decode.string)
    use status <- decode.field(2, decode.string)
    decode.success(DraftRow(instance_id:, name:, status:))
  }
  use returned <- result.map(
    pog.query(onboarding_drafts_sql)
    |> pog.parameter(pog.int(account_id))
    |> pog.parameter(pog.bool(can_commit))
    |> pog.returning(row_decoder)
    |> pog.execute(on: context.db),
  )
  returned.rows
}

/// The draft-prepend scope for the viewer: their account id, and whether they hold the
/// onboarding commit permission (so they may also see the shared awaiting-Finance
/// queue). Mirrors `workflow/instance.list_for`. No principal (the route guard makes
/// this unreachable in production) sees no drafts.
fn draft_scope(context: Context) -> #(Int, Bool) {
  case context.principal {
    Some(principal) -> #(
      principal.account_id,
      auth.can(principal, access.engineer_onboard_commit),
    )
    None -> #(-1, False)
  }
}

const onboarding_drafts_sql = "
SELECT i.id,
       coalesce(v.value #>> '{full_name,value}', ''),
       i.status
  FROM workflow_instance i
  LEFT JOIN workflow_step_value v
    ON v.instance_id = i.id AND v.step_id = 'identity'
       AND upper_inf(v.recorded_during)
 WHERE i.kind = 'onboard_engineer'
   AND i.status IN ('draft', 'awaiting_finance')
   AND (i.owner_id = $1 OR ($2 AND i.status = 'awaiting_finance'))
 ORDER BY i.created_at
"

fn draft_row_to_table_row(row: DraftRow) -> Row {
  let display_name = case row.name {
    "" -> "New engineer"
    name -> name
  }
  Row(
    id: row.instance_id,
    cells: dict.from_list([
      #(
        "name",
        PersonCell(
          name: display_name,
          sub: Some("Onboarding"),
          initials: initials(display_name),
          category: 0,
        ),
      ),
      #("level", EntityCell(label: "—", sub: None, swatch: Placeholder)),
      #("status", draft_status_cell(row.status)),
      #("allocated", PercentCell(0.0)),
      #("annual_leave", NumberCell(0.0)),
      #("day_rate", MoneyCell(money.zero())),
    ]),
    children: [],
    detail: None,
  )
}

fn draft_status_cell(status: String) -> Cell {
  case status {
    "awaiting_finance" -> EnumCell(label: "Awaiting payroll", tone: Warning)
    _ -> EnumCell(label: "Onboarding", tone: Accent)
  }
}

// --- schema -----------------------------------------------------------------

/// The static people schema, with the Level select options filled from the live
/// `options` (the distinct levels that appear on employed engineers).
pub fn people_schema(options: FilterOptions) -> Schema {
  Schema(
    table_id: "people",
    child_columns: None,
    default_sort: Some(Sort(key: default_sort_key, dir: Asc)),
    filters: [],
    columns: [
      Column(
        key: "name",
        label: "Engineer",
        column_type: PersonType,
        align: Start,
        sortable: True,
        hideable: False,
        filter: None,
      ),
      Column(
        key: "level",
        label: "Level",
        column_type: EntityType,
        align: Start,
        sortable: True,
        hideable: True,
        filter: Some(level_filter(options.levels)),
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
            FilterOption(value: "on_projects", label: "On projects"),
            FilterOption(value: "on_leave", label: "On leave"),
            FilterOption(value: "unassigned", label: "Unassigned"),
          ]),
        ),
      ),
      Column(
        key: "allocated",
        label: "Allocated",
        column_type: PercentType,
        align: NumericEnd,
        sortable: True,
        hideable: True,
        filter: Some(NumberRangeFilter),
      ),
      Column(
        key: "annual_leave",
        label: "Annual lv.",
        column_type: NumberType,
        align: NumericEnd,
        sortable: True,
        hideable: True,
        filter: Some(NumberRangeFilter),
      ),
      Column(
        key: "day_rate",
        label: "Day rate",
        column_type: MoneyType,
        align: NumericEnd,
        sortable: True,
        hideable: True,
        filter: Some(NumberRangeFilter),
      ),
    ],
  )
}

/// The schema with empty select options — its column filter KINDS are all the web
/// boundary needs to parse the applied filters out of the query params.
pub fn filter_schema() -> Schema {
  people_schema(FilterOptions(levels: []))
}

fn level_filter(levels: List(Int)) -> filter.FilterKind {
  SelectFilter(
    multi: True,
    options: list.map(levels, fn(level) {
      FilterOption(value: int.to_string(level), label: level.band(level))
    }),
  )
}

// --- filter options ---------------------------------------------------------

/// The distinct levels held by employed engineers as of the date, for the Level
/// select filter's option list.
pub type FilterOptions {
  FilterOptions(levels: List(Int))
}

fn filter_options(
  context: Context,
  as_of: Date,
) -> Result(FilterOptions, pog.QueryError) {
  let row_decoder = {
    use levels <- decode.field(0, decode.list(decode.int))
    decode.success(FilterOptions(levels:))
  }
  use returned <- result.map(
    pog.query(filter_options_sql)
    |> pog.parameter(pog.calendar_date(as_of))
    |> pog.returning(row_decoder)
    |> pog.execute(on: context.db),
  )
  case returned.rows {
    [row, ..] -> row
    [] -> FilterOptions(levels: [])
  }
}

const filter_options_sql = "
SELECT
  coalesce((SELECT array_agg(DISTINCT engineer_role.level ORDER BY engineer_role.level)
    FROM employment
    JOIN engineer_role ON engineer_role.engineer_id = employment.engineer_id
                      AND engineer_role.held_during @> $1::date
   WHERE employment.employed_during @> $1::date), '{}'::int[]) AS levels
"

// --- list query -------------------------------------------------------------

type ListRow {
  ListRow(
    engineer_id: Int,
    name: String,
    email: String,
    level: Int,
    status: String,
    allocated: Float,
    annual_leave: Float,
    day_rate: String,
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
  let #(allocated_lo, allocated_hi) =
    builder.number_range_of(filters, "allocated")
  let #(annual_lo, annual_hi) = builder.number_range_of(filters, "annual_leave")
  let #(rate_lo, rate_hi) = builder.number_range_of(filters, "day_rate")

  let filtered =
    builder.new([pog.calendar_date(as_of)])
    |> builder.select(
      "page.level::text",
      builder.select_values(filters, "level"),
    )
    |> builder.select("page.status", builder.select_values(filters, "status"))
    |> builder.number_range("page.allocated * 100", allocated_lo, allocated_hi)
    |> builder.number_range("page.annual_leave", annual_lo, annual_hi)
    |> builder.number_range("page.day_rate::numeric", rate_lo, rate_hi)

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
      "page.engineer_id ASC",
    )
    <> paging

  list.fold(builder.params(built), pog.query(sql), pog.parameter)
  |> pog.returning(list_row_decoder())
  |> pog.execute(on: context.db)
}

fn list_row_decoder() -> Decoder(ListRow) {
  use engineer_id <- decode.field(0, decode.int)
  use name <- decode.field(1, decode.string)
  use email <- decode.field(2, decode.string)
  use level <- decode.field(3, decode.int)
  use status <- decode.field(4, decode.string)
  use allocated <- decode.field(5, decode.float)
  use annual_leave <- decode.field(6, decode.float)
  use day_rate <- decode.field(7, decode.string)
  decode.success(ListRow(
    engineer_id:,
    name:,
    email:,
    level:,
    status:,
    allocated:,
    annual_leave:,
    day_rate:,
  ))
}

const page_subquery = "
SELECT * FROM (
  SELECT
    engineer.id AS engineer_id,
    coalesce(engineer_current.name, '') AS name,
    coalesce(engineer_current.email, '') AS email,
    engineer_role.level AS level,
    CASE
      WHEN on_leave.kind IS NOT NULL THEN 'on_leave'
      WHEN coalesce(alloc.projects, '') <> '' THEN 'on_projects'
      ELSE 'unassigned'
    END AS status,
    coalesce(alloc.allocated_fraction, 0)::float8 AS allocated,
    round(accrued_leave(engineer.id, 'annual', $1::date)
          - taken_leave(engineer.id, 'annual', $1::date), 1)::float8 AS annual_leave,
    rate_card.day_rate::text AS day_rate
  FROM employment
  JOIN engineer ON engineer.id = employment.engineer_id
  JOIN engineer_current ON engineer_current.id = engineer.id
  JOIN engineer_role ON engineer_role.engineer_id = engineer.id
                    AND engineer_role.held_during @> $1::date
  JOIN rate_card ON rate_card.level = engineer_role.level
                AND rate_card.effective_during @> $1::date
  LEFT JOIN LATERAL (
    SELECT leave.kind FROM leave
     WHERE leave.engineer_id = engineer.id
       AND leave.on_leave_during @> $1::date
     LIMIT 1
  ) on_leave ON true
  LEFT JOIN LATERAL (
    SELECT sum(allocation.fraction) AS allocated_fraction,
           string_agg(DISTINCT coalesce(project_current.title, ''), ', '
                      ORDER BY coalesce(project_current.title, '')) AS projects
      FROM allocation
      JOIN project_run ON project_run.project_id = allocation.project_id
                      AND project_run.active_during @> $1::date
      JOIN project_current ON project_current.id = allocation.project_id
     WHERE allocation.engineer_id = engineer.id
       AND allocation.allocated_during @> $1::date
  ) alloc ON true
  WHERE employment.employed_during @> $1::date
) page"

// --- sort -------------------------------------------------------------------

/// Maps a request sort key to its trusted SQL column, falling back to name for an
/// absent or unknown key. The allowlist is the injection boundary for sorting.
fn sort_column(key: String) -> String {
  case key {
    "level" -> "page.level"
    "status" -> "page.status"
    "allocated" -> "page.allocated"
    "annual_leave" -> "page.annual_leave"
    "day_rate" -> "page.day_rate::numeric"
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
    id: int.to_string(row.engineer_id),
    cells: dict.from_list([
      #(
        "name",
        PersonCell(
          name: row.name,
          sub: sub_email(row.email),
          initials: initials(row.name),
          category: row.engineer_id,
        ),
      ),
      #("level", level.cell(row.level)),
      #("status", status_cell(row.status)),
      #("allocated", PercentCell(row.allocated *. 100.0)),
      #("annual_leave", NumberCell(row.annual_leave)),
      #("day_rate", MoneyCell(parse_money(row.day_rate))),
    ]),
    children: [],
    detail: None,
  )
}

fn sub_email(email: String) -> Option(String) {
  case email {
    "" -> None
    _ -> Some(email)
  }
}

/// The toned status pill for the derived status category.
fn status_cell(status: String) -> Cell {
  case status {
    "on_projects" -> EnumCell(label: "On projects", tone: Positive)
    "on_leave" -> EnumCell(label: "On leave", tone: Warning)
    _ -> EnumCell(label: "Unassigned", tone: Neutral)
  }
}

fn initials(name: String) -> String {
  string.split(name, " ")
  |> list.filter_map(string.first)
  |> list.take(2)
  |> string.concat
  |> string.uppercase
}

fn parse_money(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}
