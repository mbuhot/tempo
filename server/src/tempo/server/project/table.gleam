//// Domain: the projects generic-table read (data-table system). Builds the table
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
//// The page subquery mirrors `project_list.sql` (one row per project that has a run
//// STARTED by `as_of` — id, title, owning client, latest-read budget/target, the
//// team size on `as_of`, and `active` = its run covers `as_of`) and derives a single
//// `state` category ('active' / 'ended') the client renders as a toned pill.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/money.{type Money}
import shared/pagination
import shared/table/cell.{
  type Cell, Category, DateCell, EntityCell, EnumCell, MoneyCell, NumberCell,
}
import shared/table/column.{
  type Schema, Column, DateType, EntityType, EnumType, MoneyType, Neutral,
  NumberType, NumericEnd, Positive, Schema, Start,
}
import shared/table/filter.{FilterOption, NumberRangeFilter, SelectFilter}
import shared/table/query.{type Applied}
import shared/table/response.{
  type Row, type TableResponse, Page, Row, TableResponse,
}
import shared/table/sort.{Asc, Sort}
import tempo/server/context.{type Context}
import tempo/server/table/builder

const default_sort_key = "title"

/// One filtered/sorted/paged slice of the projects table, plus the schema the client
/// renders from. `applied` is the parsed filter/sort/page request. The state filter's
/// options are fixed (active / ended), so the schema needs no live options query.
pub fn project_table(
  context: Context,
  as_of: Date,
  applied: Applied,
) -> Result(TableResponse, pog.QueryError) {
  let schema = project_schema()
  let offset = decode_offset(applied.cursor)
  let limit = applied.page_size
  use returned <- result.try(run_list(context, as_of, applied, limit, offset))
  use drafts <- result.map(case offset {
    0 -> project_draft_rows(context)
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

// --- schema -----------------------------------------------------------------

/// The static projects schema. The State select offers the two derived categories;
/// Team and Budget offer number ranges; the project title is the un-hideable lead
/// column.
pub fn project_schema() -> Schema {
  Schema(
    table_id: "projects",
    child_columns: None,
    default_sort: Some(Sort(key: default_sort_key, dir: Asc)),
    filters: [],
    columns: [
      Column(
        key: "title",
        label: "Project",
        column_type: EntityType,
        align: Start,
        sortable: True,
        hideable: False,
        filter: None,
      ),
      Column(
        key: "state",
        label: "State",
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
      Column(
        key: "team_size",
        label: "Team",
        column_type: NumberType,
        align: NumericEnd,
        sortable: True,
        hideable: True,
        filter: Some(NumberRangeFilter),
      ),
      Column(
        key: "budget",
        label: "Budget",
        column_type: MoneyType,
        align: NumericEnd,
        sortable: True,
        hideable: True,
        filter: Some(NumberRangeFilter),
      ),
      Column(
        key: "target_completion",
        label: "Target",
        column_type: DateType,
        align: Start,
        sortable: True,
        hideable: True,
        filter: None,
      ),
    ],
  )
}

/// The schema with its column filter KINDS — all the web boundary needs to parse the
/// applied filters out of the query params.
pub fn filter_schema() -> Schema {
  project_schema()
}

// --- in-progress create_project drafts --------------------------------------

type DraftRow {
  DraftRow(instance_id: String, title: String, status: String)
}

fn project_draft_rows(
  context: Context,
) -> Result(List(DraftRow), pog.QueryError) {
  let row_decoder = {
    use instance_id <- decode.field(0, decode.string)
    use title <- decode.field(1, decode.string)
    use status <- decode.field(2, decode.string)
    decode.success(DraftRow(instance_id:, title:, status:))
  }
  use returned <- result.map(
    pog.query(project_drafts_sql)
    |> pog.returning(row_decoder)
    |> pog.execute(on: context.db),
  )
  returned.rows
}

const project_drafts_sql = "
SELECT i.id,
       coalesce(v.value #>> '{title,value}', ''),
       i.status
  FROM workflow_instance i
  LEFT JOIN workflow_step_value v
    ON v.instance_id = i.id AND v.step_id = 'description'
       AND upper_inf(v.recorded_during)
 WHERE i.kind = 'create_project' AND i.status IN ('draft', 'awaiting_finance')
 ORDER BY i.created_at
"

fn draft_row_to_table_row(row: DraftRow) -> Row {
  let display_title = case row.title {
    "" -> "(untitled project)"
    title -> title
  }
  Row(
    id: row.instance_id,
    cells: dict.from_list([
      #(
        "title",
        EntityCell(
          label: display_title,
          sub: Some("Draft"),
          swatch: Category(0),
        ),
      ),
      #("state", draft_state_cell(row.status)),
      #("team_size", NumberCell(0.0)),
      #("budget", MoneyCell(money.zero())),
      #("target_completion", DateCell(calendar.Date(2000, calendar.January, 1))),
    ]),
    children: [],
    detail: None,
  )
}

fn draft_state_cell(status: String) -> Cell {
  case status {
    "awaiting_finance" -> EnumCell(label: "Awaiting approval", tone: Neutral)
    _ -> EnumCell(label: "Draft", tone: Neutral)
  }
}

// --- list query -------------------------------------------------------------

type ListRow {
  ListRow(
    project_id: Int,
    title: String,
    client: String,
    state: String,
    team_size: Int,
    budget: String,
    target_completion: Date,
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
  let #(team_lo, team_hi) = builder.number_range_of(filters, "team_size")
  let #(budget_lo, budget_hi) = builder.number_range_of(filters, "budget")

  let filtered =
    builder.new([pog.calendar_date(as_of)])
    |> builder.select("page.state", builder.select_values(filters, "state"))
    |> builder.number_range("page.team_size", team_lo, team_hi)
    |> builder.number_range("page.budget::numeric", budget_lo, budget_hi)

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
      "page.project_id ASC",
    )
    <> paging

  list.fold(builder.params(built), pog.query(sql), pog.parameter)
  |> pog.returning(list_row_decoder())
  |> pog.execute(on: context.db)
}

fn list_row_decoder() -> Decoder(ListRow) {
  use project_id <- decode.field(0, decode.int)
  use title <- decode.field(1, decode.string)
  use client <- decode.field(2, decode.string)
  use state <- decode.field(3, decode.string)
  use team_size <- decode.field(4, decode.int)
  use budget <- decode.field(5, decode.string)
  use target_completion <- decode.field(6, pog.calendar_date_decoder())
  decode.success(ListRow(
    project_id:,
    title:,
    client:,
    state:,
    team_size:,
    budget:,
    target_completion:,
  ))
}

const page_subquery = "
SELECT * FROM (
  SELECT DISTINCT ON (project_run.project_id)
    project_run.project_id AS project_id,
    coalesce(project_current.title, '') AS title,
    coalesce(client_current.name, '') AS client,
    CASE WHEN project_run.active_during @> $1::date THEN 'active' ELSE 'ended' END AS state,
    (
      SELECT count(DISTINCT allocation.engineer_id)
        FROM allocation
       WHERE allocation.project_id = project_run.project_id
         AND allocation.allocated_during @> $1::date
    )::int AS team_size,
    coalesce(plan.budget, 0)::text AS budget,
    coalesce(plan.target_completion, upper(project_run.active_during)) AS target_completion
  FROM project_run
  JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
  JOIN client_current ON client_current.id = contract_terms.client_id
  JOIN project_current ON project_current.id = project_run.project_id
  LEFT JOIN LATERAL (
    SELECT project_plan.budget, project_plan.target_completion
      FROM project_plan
     WHERE project_plan.project_id = project_run.project_id
     ORDER BY lower(project_plan.planned_during) DESC
     LIMIT 1
  ) plan ON true
  WHERE lower(project_run.active_during) <= $1::date
  ORDER BY project_run.project_id,
           (project_run.active_during @> $1::date) DESC,
           lower(project_run.active_during) DESC
) page"

// --- sort -------------------------------------------------------------------

/// Maps a request sort key to its trusted SQL column, falling back to title for an
/// absent or unknown key. The allowlist is the injection boundary for sorting.
fn sort_column(key: String) -> String {
  case key {
    "state" -> "page.state"
    "team_size" -> "page.team_size"
    "budget" -> "page.budget::numeric"
    "target_completion" -> "page.target_completion"
    _ -> "page.title"
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
    id: int.to_string(row.project_id),
    cells: dict.from_list([
      #(
        "title",
        EntityCell(
          label: row.title,
          sub: Some(row.client),
          swatch: Category(row.project_id),
        ),
      ),
      #("state", state_cell(row.state)),
      #("team_size", NumberCell(int.to_float(row.team_size))),
      #("budget", MoneyCell(parse_money(row.budget))),
      #("target_completion", DateCell(row.target_completion)),
    ]),
    children: [],
    detail: None,
  )
}

/// The toned state pill for the derived state category.
fn state_cell(state: String) -> Cell {
  case state {
    "active" -> EnumCell(label: "Active", tone: Positive)
    _ -> EnumCell(label: "Ended", tone: Neutral)
  }
}

fn parse_money(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}
