//// Domain: the per-engineer P&L generic-table read (data-table system). Builds the
//// table `Schema` the client renders from, then runs ONE filtered/sorted/paged
//// query over the MONTH window containing `as_of` and maps each row to typed
//// `Cell`s — the per-engineer revenue / cost / profit / margin / utilization
//// breakdown the Finance P&L tab shows.
////
//// The page subquery is the per-engineer month aggregation (the same capacity-based
//// revenue, month-settled cost, and utilization the `pnl_rows` read computes),
//// wrapped so its derived numeric columns (profit, margin %, utilization %) are
//// available to the generic `builder`: each present filter folds in one `WHERE`
//// condition binding its own param, and the ORDER BY column comes from
//// `sort_column`'s allowlist, so no request value reaches the SQL text. Pagination
//// is `LIMIT/OFFSET`, the opaque cursor encoding the next offset.
////
//// Profit carries a server-driven tone: `Positive` when the engineer is profitable
//// (profit ≥ 0), `Critical` when they run at a loss, so the client renders it
//// colour-coded via the shared `SignedMoneyCell`.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date, Date, January}
import pog
import shared/money.{type Money}
import shared/pagination
import shared/table/cell.{MoneyCell, PercentCell, PersonCell, SignedMoneyCell}
import shared/table/column.{
  type Schema, type Tone, Column, Critical, MoneyType, NumericEnd, PercentType,
  PersonType, Positive, Schema, SignedMoneyType, Start,
}
import shared/table/filter.{NumberRangeFilter}
import shared/table/query.{type Applied}
import shared/table/response.{
  type Row, type TableResponse, Page, Row, TableResponse,
}
import shared/table/sort.{Desc, Sort}
import tempo/server/context.{type Context}
import tempo/server/table/builder

const default_sort_key = "profit"

/// One filtered/sorted/paged slice of the per-engineer P&L table, plus the schema
/// the client renders from. `applied` is the parsed filter/sort/page request; the
/// figures are for the calendar month containing `as_of`.
pub fn pnl_table(
  context: Context,
  as_of: Date,
  applied: Applied,
) -> Result(TableResponse, pog.QueryError) {
  let schema = pnl_schema()
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

/// The static per-engineer P&L schema: the engineer plus the month's revenue,
/// cost, profit (toned), margin %, and utilization %.
pub fn pnl_schema() -> Schema {
  Schema(
    table_id: "pnl",
    default_sort: Some(Sort(key: default_sort_key, dir: Desc)),
    columns: [
      Column(
        key: "engineer",
        label: "Engineer",
        column_type: PersonType,
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
      Column(
        key: "utilization",
        label: "Utilization",
        column_type: PercentType,
        align: NumericEnd,
        sortable: True,
        hideable: True,
        filter: None,
      ),
    ],
  )
}

/// The schema the web boundary parses applied filters against (the column filter
/// KINDS are all it needs). Identical to `pnl_schema` since the P&L table carries
/// no live select options.
pub fn filter_schema() -> Schema {
  pnl_schema()
}

// --- list query -------------------------------------------------------------

type ListRow {
  ListRow(
    engineer_id: Int,
    engineer: String,
    revenue: String,
    cost: String,
    profit: String,
    margin: Float,
    utilization: Float,
  )
}

/// Composes the list query with the generic `builder`: the month window's start /
/// end are bound first (`$1`/`$2`, referenced throughout the fixed `page`
/// subquery), each present filter folds in one `WHERE` condition binding its own
/// param, and `LIMIT/OFFSET` bind last. The ORDER BY column comes from
/// `sort_column`'s allowlist, so no sort value reaches SQL.
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
    builder.new([
      pog.calendar_date(first_of_month(as_of)),
      pog.calendar_date(first_of_next_month(as_of)),
    ])
    |> builder.number_range("page.profit::numeric", profit_lo, profit_hi)
    |> builder.number_range("page.margin", margin_lo, margin_hi)

  let effective_sort =
    option.or(applied.sort, Some(Sort(key: default_sort_key, dir: Desc)))
  let #(built, paging) = builder.limit_offset(filtered, limit + 1, offset)
  let sql =
    page_subquery
    <> builder.where_clause(built)
    <> builder.order_by(
      effective_sort,
      default_sort_key,
      sort_column,
      "page.engineer ASC",
    )
    <> paging

  list.fold(builder.params(built), pog.query(sql), pog.parameter)
  |> pog.returning(list_row_decoder())
  |> pog.execute(on: context.db)
}

fn list_row_decoder() -> Decoder(ListRow) {
  use engineer_id <- decode.field(0, decode.int)
  use engineer <- decode.field(1, decode.string)
  use revenue <- decode.field(2, decode.string)
  use cost <- decode.field(3, decode.string)
  use profit <- decode.field(4, decode.string)
  use margin <- decode.field(5, decode.float)
  use utilization <- decode.field(6, decode.float)
  decode.success(ListRow(
    engineer_id:,
    engineer:,
    revenue:,
    cost:,
    profit:,
    margin:,
    utilization:,
  ))
}

/// The per-engineer month P&L as a `page` subquery: the capacity-based revenue,
/// month-settled cost, and utilization the `pnl_rows` read computes, with profit /
/// margin % / utilization % derived in SQL so the generic builder can filter and
/// sort on them. `$1` = month start, `$2` = month end (exclusive).
const page_subquery = "
SELECT * FROM (
  WITH params AS (
    SELECT daterange($1::date, $2::date, '[)') AS period
  ),
  months AS (
    SELECT
      daterange(
        month_start::date,
        (month_start + interval '1 month')::date,
        '[)'
      ) AS span
    FROM params,
      generate_series(
        date_trunc('month', lower(params.period)),
        date_trunc('month', upper(params.period) - 1),
        interval '1 month'
      ) AS month_start
  ),
  emp AS (
    SELECT
      employment.engineer_id,
      sum(range_days(employment.employed_during * params.period))::numeric
        AS employed_days
    FROM params
    JOIN employment ON employment.employed_during && params.period
    GROUP BY employment.engineer_id
  ),
  util AS (
    SELECT
      allocation.engineer_id,
      sum(allocation.fraction
          * range_days(allocation.allocated_during * employment.employed_during
                       * params.period))::numeric AS utilization_days
    FROM params
    JOIN allocation ON allocation.allocated_during && params.period
    JOIN employment ON employment.engineer_id = allocation.engineer_id
                   AND employment.employed_during && allocation.allocated_during
                   AND employment.employed_during && params.period
    WHERE NOT isempty(allocation.allocated_during * employment.employed_during
                      * params.period)
    GROUP BY allocation.engineer_id
  ),
  rev AS (
    SELECT
      allocation.engineer_id,
      sum(allocation.fraction
          * recognized_revenue(
              rate_card.day_rate,
              allocation.allocated_during * engineer_role.held_during
                * rate_card.effective_during * params.period))::numeric
        AS revenue
    FROM params
    JOIN allocation    ON allocation.allocated_during && params.period
    JOIN engineer_role ON engineer_role.engineer_id = allocation.engineer_id
                      AND engineer_role.held_during && allocation.allocated_during
                      AND engineer_role.held_during && params.period
    JOIN rate_card     ON rate_card.level = engineer_role.level
                      AND rate_card.effective_during && engineer_role.held_during
                      AND rate_card.effective_during && params.period
    WHERE NOT isempty(allocation.allocated_during * engineer_role.held_during
                      * rate_card.effective_during * params.period)
    GROUP BY allocation.engineer_id
  ),
  actual_cost AS (
    SELECT
      payroll_line.engineer_id,
      sum(payroll_line.amount)::numeric AS cost
    FROM months
    JOIN payroll_period ON payroll_period.period && months.span
    JOIN payroll_line   ON payroll_line.run_id = payroll_period.run_id
    GROUP BY payroll_line.engineer_id
  ),
  estimated_cost AS (
    SELECT
      employment.engineer_id,
      sum(prorated_salary(
            salary.monthly_salary,
            employment.employed_during * engineer_role.held_during
              * salary.effective_during * months.span,
            months.span))::numeric AS cost
    FROM months
    JOIN employment    ON employment.employed_during && months.span
    JOIN engineer_role ON engineer_role.engineer_id = employment.engineer_id
                      AND engineer_role.held_during && employment.employed_during
                      AND engineer_role.held_during && months.span
    JOIN salary        ON salary.level = engineer_role.level
                      AND salary.effective_during && engineer_role.held_during
                      AND salary.effective_during && months.span
    WHERE NOT EXISTS (
      SELECT 1 FROM payroll_period WHERE payroll_period.period && months.span
    )
    AND NOT isempty(employment.employed_during * engineer_role.held_during
                    * salary.effective_during * months.span)
    GROUP BY employment.engineer_id
  ),
  cost AS (
    SELECT engineer_id, sum(cost)::numeric AS cost
    FROM (
      SELECT engineer_id, cost FROM actual_cost
      UNION ALL
      SELECT engineer_id, cost FROM estimated_cost
    ) per_engineer
    GROUP BY engineer_id
  )
  SELECT
    emp.engineer_id AS engineer_id,
    coalesce(engineer.name, '') AS engineer,
    coalesce(rev.revenue, 0)::text AS revenue,
    coalesce(cost.cost, 0)::text AS cost,
    (coalesce(rev.revenue, 0) - coalesce(cost.cost, 0))::text AS profit,
    CASE WHEN coalesce(rev.revenue, 0) = 0 THEN 0::float8
         ELSE ((coalesce(rev.revenue, 0) - coalesce(cost.cost, 0))
               / rev.revenue * 100)::float8 END AS margin,
    CASE WHEN emp.employed_days = 0 THEN 0::float8
         ELSE (coalesce(util.utilization_days, 0)
               / emp.employed_days * 100)::float8 END AS utilization
  FROM emp
  JOIN engineer_current engineer ON engineer.id = emp.engineer_id
  LEFT JOIN util ON util.engineer_id = emp.engineer_id
  LEFT JOIN rev  ON rev.engineer_id = emp.engineer_id
  LEFT JOIN cost ON cost.engineer_id = emp.engineer_id
) page"

// --- sort -------------------------------------------------------------------

/// Maps a request sort key to its trusted SQL column, falling back to profit for an
/// absent or unknown key. The allowlist is the injection boundary for sorting.
fn sort_column(key: String) -> String {
  case key {
    "engineer" -> "page.engineer"
    "revenue" -> "page.revenue::numeric"
    "cost" -> "page.cost::numeric"
    "margin" -> "page.margin"
    "utilization" -> "page.utilization"
    _ -> "page.profit::numeric"
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
    id: int.to_string(row.engineer_id),
    cells: dict.from_list([
      #(
        "engineer",
        PersonCell(
          name: row.engineer,
          sub: None,
          initials: initials(row.engineer),
          color: swatch_color(row.engineer_id),
        ),
      ),
      #("revenue", MoneyCell(parse_money(row.revenue))),
      #("cost", MoneyCell(parse_money(row.cost))),
      #("profit", SignedMoneyCell(amount: profit, tone: profit_tone(profit))),
      #("margin", PercentCell(row.margin)),
      #("utilization", PercentCell(row.utilization)),
    ]),
  )
}

/// Profit reads good while the engineer is in the black, critical at a loss.
fn profit_tone(profit: Money) -> Tone {
  case money.to_float(profit) >=. 0.0 {
    True -> Positive
    False -> Critical
  }
}

fn initials(name: String) -> String {
  string.split(name, " ")
  |> list.filter_map(string.first)
  |> list.take(2)
  |> string.concat
  |> string.uppercase
}

// --- month window -----------------------------------------------------------

/// The first day of the calendar month containing `date`.
fn first_of_month(date: Date) -> Date {
  Date(year: date.year, month: date.month, day: 1)
}

/// The first day of the month AFTER the one containing `date` (the exclusive upper
/// bound of the month window); December rolls over to the next January.
fn first_of_next_month(date: Date) -> Date {
  case calendar.month_to_int(date.month) {
    12 -> Date(year: date.year + 1, month: January, day: 1)
    month ->
      case calendar.month_from_int(month + 1) {
        Ok(next) -> Date(year: date.year, month: next, day: 1)
        Error(Nil) -> Date(year: date.year, month: January, day: 1)
      }
  }
}

fn parse_money(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

fn swatch_color(id: Int) -> String {
  let bucket = result.unwrap(int.modulo(id, 7), 0) + 1
  "var(--cat-" <> int.to_string(bucket) <> ")"
}
