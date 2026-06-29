//// Domain: the forecast generic-table read (data-table system). Builds the table
//// `Schema` the client renders from, then runs ONE filtered/sorted/paged query over
//// the forecast window and maps each calendar-month row to typed `Cell`s — the
//// month-by-month revenue / cost / profit / margin the Finance Forecast tab shows.
////
//// The page subquery is the forecast month aggregation (the same committed-demand
//// revenue and expected cost the `forecast` read computes), wrapped so its derived
//// numeric columns (profit, margin %) are available to the generic `builder`: each
//// present filter folds in one `WHERE` condition binding its own param, and the
//// ORDER BY column comes from `sort_column`'s allowlist, so no request value reaches
//// the SQL text. Pagination is `LIMIT/OFFSET`, the opaque cursor encoding the next
//// offset.
////
//// Profit carries a server-driven tone: `Positive` when the month is in the black
//// (profit ≥ 0), `Critical` when it runs at a loss, so the client renders it
//// colour-coded via the shared `SignedMoneyCell`. The to-the-cliff totals ride in
//// the response `footer` (the table's `<tfoot>`): the summed revenue / cost / profit
//// over EVERY forecast month and the blended margin, rendered by the same typed cells
//// as the body so they line up under their columns.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date, Date}
import pog
import shared/forecast/view.{type Forecast, type ForecastMonth}
import shared/money.{type Money}
import shared/pagination
import shared/table/cell.{DateCell, MoneyCell, PercentCell, SignedMoneyCell}
import shared/table/column.{
  type Schema, type Tone, Column, Critical, DateType, MoneyType, NumericEnd,
  PercentType, Positive, Schema, SignedMoneyType, Start,
}
import shared/table/filter.{NumberRangeFilter}
import shared/table/query.{type Applied}
import shared/table/response.{
  type Footer, type Row, type TableResponse, Footer, Page, Row, TableResponse,
}
import shared/table/sort.{Asc, Sort}
import tempo/server/context.{type Context}
import tempo/server/forecast/view as forecast_read
import tempo/server/table/builder

const default_sort_key = "month"

/// One filtered/sorted/paged slice of the forecast table, plus the schema the client
/// renders from. `applied` is the parsed filter/sort/page request; the rows are one
/// per calendar month from the `as_of` month to the demand cliff.
pub fn forecast_table(
  context: Context,
  as_of: Date,
  applied: Applied,
) -> Result(TableResponse, pog.QueryError) {
  let schema = forecast_schema()
  let offset = decode_offset(applied.cursor)
  let limit = applied.page_size
  use returned <- result.try(run_list(context, as_of, applied, limit, offset))
  use summary <- result.map(forecast_read.forecast(context, as_of))
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
    footer: Some(total_footer(summary)),
  )
}

/// The to-the-cliff totals as the table footer: revenue / cost summed over EVERY
/// forecast month, profit toned by sign, and the blended margin — the same figures
/// the headline read derives, keyed to the numeric columns (the leading month column
/// carries only the "Total" label).
fn total_footer(summary: Forecast) -> Footer {
  let months = summary.months
  let total_revenue =
    money.sum(list.map(months, fn(month: ForecastMonth) { month.revenue }))
  let total_cost =
    money.sum(list.map(months, fn(month: ForecastMonth) { month.cost }))
  let total_profit = money.subtract(total_revenue, total_cost)
  let total_margin = case money.to_float(total_revenue) >. 0.0 {
    True -> money.ratio(total_profit, total_revenue) *. 100.0
    False -> 0.0
  }
  Footer(
    label: "Total",
    cells: dict.from_list([
      #("revenue", MoneyCell(total_revenue)),
      #("cost", MoneyCell(total_cost)),
      #(
        "profit",
        SignedMoneyCell(amount: total_profit, tone: profit_tone(total_profit)),
      ),
      #("margin", PercentCell(total_margin)),
    ]),
  )
}

// --- schema -----------------------------------------------------------------

/// The static forecast schema: the month plus that month's revenue, cost, profit
/// (toned), and margin %.
pub fn forecast_schema() -> Schema {
  Schema(
    table_id: "forecast",
    child_columns: None,
    default_sort: Some(Sort(key: default_sort_key, dir: Asc)),
    filters: [],
    columns: [
      Column(
        key: "month",
        label: "Month",
        column_type: DateType,
        align: Start,
        sortable: True,
        hideable: False,
        filter: None,
      ),
      Column(
        key: "revenue",
        label: "Revenue",
        column_type: MoneyType,
        align: NumericEnd,
        sortable: True,
        hideable: True,
        filter: None,
      ),
      Column(
        key: "cost",
        label: "Cost",
        column_type: MoneyType,
        align: NumericEnd,
        sortable: True,
        hideable: True,
        filter: None,
      ),
      Column(
        key: "profit",
        label: "Profit",
        column_type: SignedMoneyType,
        align: NumericEnd,
        sortable: True,
        hideable: True,
        filter: Some(NumberRangeFilter),
      ),
      Column(
        key: "margin",
        label: "Margin",
        column_type: PercentType,
        align: NumericEnd,
        sortable: True,
        hideable: True,
        filter: Some(NumberRangeFilter),
      ),
    ],
  )
}

/// The schema the web boundary parses applied filters against (the column filter
/// KINDS are all it needs). Identical to `forecast_schema` since the forecast table
/// carries no live select options.
pub fn filter_schema() -> Schema {
  forecast_schema()
}

// --- list query -------------------------------------------------------------

type ListRow {
  ListRow(
    month: Date,
    revenue: String,
    cost: String,
    profit: String,
    margin: Float,
  )
}

/// Composes the list query with the generic `builder`: the as-of is bound first
/// (`$1`, referenced by the fixed `page` subquery), each present filter folds in one
/// `WHERE` condition binding its own param, and `LIMIT/OFFSET` bind last. The ORDER
/// BY column comes from `sort_column`'s allowlist, so no sort value reaches SQL.
fn run_list(
  context: Context,
  as_of: Date,
  applied: Applied,
  limit: Int,
  offset: Int,
) -> Result(pog.Returned(ListRow), pog.QueryError) {
  let filters = applied.filters
  let #(profit_lo, profit_hi) = builder.number_range_of(filters, "profit")
  let #(margin_lo, margin_hi) = builder.number_range_of(filters, "margin")

  let filtered =
    builder.new([pog.calendar_date(as_of)])
    |> builder.number_range("page.profit::numeric", profit_lo, profit_hi)
    |> builder.number_range("page.margin", margin_lo, margin_hi)

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
      "page.month ASC",
    )
    <> paging

  list.fold(builder.params(built), pog.query(sql), pog.parameter)
  |> pog.returning(list_row_decoder())
  |> pog.execute(on: context.db)
}

fn list_row_decoder() -> Decoder(ListRow) {
  use month <- decode.field(0, pog.calendar_date_decoder())
  use revenue <- decode.field(1, decode.string)
  use cost <- decode.field(2, decode.string)
  use profit <- decode.field(3, decode.string)
  use margin <- decode.field(4, decode.float)
  decode.success(ListRow(month:, revenue:, cost:, profit:, margin:))
}

/// The forecast month series as a `page` subquery: the committed-demand revenue and
/// expected cost the `forecast` read computes, with profit and margin % derived in
/// SQL so the generic builder can filter and sort on them. `$1` = as-of date (the
/// window's first month).
const page_subquery = "
SELECT * FROM (
  WITH cliff AS (
    SELECT greatest(
      (SELECT max(upper(required_during)) FROM project_requirement),
      (SELECT max(upper(allocated_during)) FROM allocation)
    ) AS at
  ),
  months AS (
    SELECT
      month_start::date AS month,
      daterange(
        month_start::date,
        (month_start + interval '1 month')::date,
        '[)'
      ) AS span
    FROM cliff,
      generate_series(
        date_trunc('month', $1::date),
        date_trunc('month', cliff.at - 1),
        interval '1 month'
      ) AS month_start
  ),
  requirement_demand AS (
    SELECT
      project_requirement.project_id,
      months.month,
      months.span,
      project_requirement.level,
      project_requirement.quantity,
      project_requirement.required_during * months.span AS sub_period
    FROM months
    JOIN project_requirement
      ON project_requirement.required_during && months.span
  ),
  allocation_demand AS (
    SELECT
      allocation.project_id,
      months.month,
      months.span,
      engineer_role.level,
      allocation.fraction AS quantity,
      allocation.allocated_during
        * engineer_role.held_during
        * months.span AS sub_period
    FROM months
    JOIN allocation
      ON allocation.allocated_during && months.span
    JOIN engineer_role
      ON engineer_role.engineer_id = allocation.engineer_id
     AND engineer_role.held_during && allocation.allocated_during
     AND engineer_role.held_during && months.span
    WHERE NOT EXISTS (
      SELECT 1 FROM project_requirement
       WHERE project_requirement.project_id = allocation.project_id
         AND project_requirement.required_during && months.span
    )
  ),
  demand AS (
    SELECT project_id, month, span, level, quantity, sub_period
      FROM requirement_demand
    UNION ALL
    SELECT project_id, month, span, level, quantity, sub_period
      FROM allocation_demand
  ),
  revenue AS (
    SELECT
      demand.month,
      sum(demand.quantity
          * recognized_revenue(
              rate_card.day_rate,
              demand.sub_period * rate_card.effective_during))::numeric
        AS revenue
    FROM demand
    JOIN rate_card ON rate_card.level = demand.level
                  AND rate_card.effective_during && demand.sub_period
    WHERE NOT isempty(demand.sub_period * rate_card.effective_during)
    GROUP BY demand.month
  ),
  cost AS (
    SELECT
      demand.month,
      sum(demand.quantity
          * prorated_salary(
              salary.monthly_salary,
              demand.sub_period * salary.effective_during,
              demand.span))::numeric
        AS cost
    FROM demand
    JOIN salary ON salary.level = demand.level
               AND salary.effective_during && demand.sub_period
    WHERE NOT isempty(demand.sub_period * salary.effective_during)
    GROUP BY demand.month
  )
  SELECT
    months.month AS month,
    coalesce(revenue.revenue, 0)::text AS revenue,
    coalesce(cost.cost, 0)::text AS cost,
    (coalesce(revenue.revenue, 0) - coalesce(cost.cost, 0))::text AS profit,
    CASE WHEN coalesce(revenue.revenue, 0) = 0 THEN 0::float8
         ELSE ((coalesce(revenue.revenue, 0) - coalesce(cost.cost, 0))
               / revenue.revenue * 100)::float8 END AS margin
  FROM months
  LEFT JOIN revenue ON revenue.month = months.month
  LEFT JOIN cost    ON cost.month = months.month
) page"

// --- sort -------------------------------------------------------------------

/// Maps a request sort key to its trusted SQL column, falling back to month for an
/// absent or unknown key. The allowlist is the injection boundary for sorting.
fn sort_column(key: String) -> String {
  case key {
    "revenue" -> "page.revenue::numeric"
    "cost" -> "page.cost::numeric"
    "profit" -> "page.profit::numeric"
    "margin" -> "page.margin"
    _ -> "page.month"
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
  let profit = parse_money(row.profit)
  Row(
    id: iso_date(row.month),
    cells: dict.from_list([
      #("month", DateCell(Some(row.month))),
      #("revenue", MoneyCell(parse_money(row.revenue))),
      #("cost", MoneyCell(parse_money(row.cost))),
      #("profit", SignedMoneyCell(amount: profit, tone: profit_tone(profit))),
      #("margin", PercentCell(row.margin)),
    ]),
    children: [],
    detail: None,
  )
}

/// Profit reads good while the month is in the black, critical at a loss.
fn profit_tone(profit: Money) -> Tone {
  case money.to_float(profit) >=. 0.0 {
    True -> Positive
    False -> Critical
  }
}

fn parse_money(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

/// The month start as an ISO "YYYY-MM-DD" string, the row's stable unique id.
fn iso_date(date: Date) -> String {
  let Date(year:, month:, day:) = date
  pad(year, 4)
  <> "-"
  <> pad(calendar.month_to_int(month), 2)
  <> "-"
  <> pad(day, 2)
}

fn pad(value: Int, width: Int) -> String {
  string.pad_start(int.to_string(value), to: width, with: "0")
}
