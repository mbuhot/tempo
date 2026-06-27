//// Layer-2 tests for the forecast generic-table read (`forecast/table`). The
//// forecast table is READ-ONLY over committed demand, so — as in `forecast_test` —
//// each test reads through `forecast/table.forecast_table` inside its OWN
//// `pog.transaction` and rolls back, leaving the shared seed undisturbed; no fixture
//// is inserted.
////
//// The as-of is 2026-06-15 (the seed "now"), whose cliff is 2027-01-01, so the
//// horizon is exactly June..December 2026 — seven contiguous first-of-month rows.
//// Every seed month carries revenue from the active allocations and a positive
//// profit, so each profit cell is a SignedMoneyCell toned Positive. The figures are
//// asserted against `forecast/view.forecast`, the canonical month derivation, so the
//// table read and the headline read can never drift.

import gleam/dict
import gleam/float
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar.{type Date, Date, December, June}
import pog
import shared/money
import shared/table/cell.{DateCell, MoneyCell, PercentCell, SignedMoneyCell}
import shared/table/column
import shared/table/query.{type Applied, type FilterValue, Applied, NumberRange}
import shared/table/response.{type Row}
import shared/table/sort.{type Sort, Asc, Desc, Sort}
import tempo/server/context.{type Context, Context}
import tempo/server/forecast/table as forecast_table
import tempo/server/forecast/view as forecast_read
import test_pool

// --- harness ----------------------------------------------------------------

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

fn ctx(conn: pog.Connection) -> Context {
  Context(db: conn, principal: None)
}

fn applied(
  filters: List(#(String, FilterValue)),
  sort: Option(Sort),
) -> Applied {
  Applied(filters: dict.from_list(filters), sort:, page_size: 200, cursor: None)
}

fn as_of() -> Date {
  Date(2026, June, 15)
}

fn cell_of(row: Row, key: String) -> cell.Cell {
  let assert Ok(value) = dict.get(row.cells, key)
  value
}

fn months_in_order(rows: List(Row)) -> List(Date) {
  list.map(rows, fn(row) {
    let assert DateCell(month) = cell_of(row, "month")
    month
  })
}

// --- tests ------------------------------------------------------------------

pub fn schema_advertises_forecast_columns_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      forecast_table.forecast_table(ctx(conn), as_of(), applied([], None))
    assert response.schema.table_id == "forecast"
    let keys = list.map(response.schema.columns, fn(column) { column.key })
    assert keys == ["month", "revenue", "cost", "profit", "margin"]
    assert response.schema.default_sort == Some(Sort(key: "month", dir: Asc))
  })
}

pub fn profit_column_is_signed_money_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      forecast_table.forecast_table(ctx(conn), as_of(), applied([], None))
    let assert Ok(profit_column) =
      list.find(response.schema.columns, fn(column) { column.key == "profit" })
    assert profit_column.column_type == column.SignedMoneyType
  })
}

pub fn rows_span_the_as_of_month_to_the_cliff_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      forecast_table.forecast_table(ctx(conn), as_of(), applied([], None))
    let assert Ok(headline) = forecast_read.forecast(ctx(conn), as_of())
    let expected = list.map(headline.months, fn(month) { month.month })
    assert months_in_order(response.rows) == expected
  })
}

pub fn june_row_has_rich_cells_with_positive_profit_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      forecast_table.forecast_table(ctx(conn), as_of(), applied([], None))
    let assert Ok(headline) = forecast_read.forecast(ctx(conn), as_of())
    let assert Ok(june) =
      list.find(headline.months, fn(month) {
        month.month == Date(2026, June, 1)
      })
    let assert [first, ..] = response.rows
    assert cell_of(first, "month") == DateCell(Date(2026, June, 1))
    assert cell_of(first, "revenue") == MoneyCell(june.revenue)
    assert cell_of(first, "cost") == MoneyCell(june.cost)
    assert cell_of(first, "profit")
      == SignedMoneyCell(amount: june.profit, tone: column.Positive)
  })
}

pub fn every_seed_month_profit_is_positively_toned_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      forecast_table.forecast_table(ctx(conn), as_of(), applied([], None))
    assert list.all(response.rows, fn(row) {
      case cell_of(row, "profit") {
        SignedMoneyCell(tone:, ..) -> tone == column.Positive
        _ -> False
      }
    })
  })
}

pub fn row_id_is_the_iso_month_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      forecast_table.forecast_table(ctx(conn), as_of(), applied([], None))
    let assert [first, ..] = response.rows
    assert first.id == "2026-06-01"
  })
}

pub fn default_sort_is_month_ascending_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      forecast_table.forecast_table(ctx(conn), as_of(), applied([], None))
    let assert [first, ..] = response.rows
    let assert Ok(last) = list.last(response.rows)
    assert cell_of(first, "month") == DateCell(Date(2026, June, 1))
    assert cell_of(last, "month") == DateCell(Date(2026, December, 1))
  })
}

pub fn month_sort_descending_puts_december_first_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      forecast_table.forecast_table(
        ctx(conn),
        as_of(),
        applied([], Some(Sort(key: "month", dir: Desc))),
      )
    let assert [first, ..] = response.rows
    assert cell_of(first, "month") == DateCell(Date(2026, December, 1))
  })
}

pub fn footer_totals_the_forecast_to_the_cliff_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      forecast_table.forecast_table(ctx(conn), as_of(), applied([], None))
    let assert Ok(headline) = forecast_read.forecast(ctx(conn), as_of())
    let total_revenue =
      money.sum(list.map(headline.months, fn(month) { month.revenue }))
    let total_cost =
      money.sum(list.map(headline.months, fn(month) { month.cost }))
    let total_profit = money.subtract(total_revenue, total_cost)
    let total_margin = money.ratio(total_profit, total_revenue) *. 100.0

    let assert Some(footer) = response.footer
    assert footer.label == "Total"
    assert dict.get(footer.cells, "revenue") == Ok(MoneyCell(total_revenue))
    assert dict.get(footer.cells, "cost") == Ok(MoneyCell(total_cost))
    assert dict.get(footer.cells, "profit")
      == Ok(SignedMoneyCell(amount: total_profit, tone: column.Positive))
    assert dict.get(footer.cells, "margin") == Ok(PercentCell(total_margin))
    assert dict.get(footer.cells, "month") == Error(Nil)
  })
}

pub fn profit_range_filter_excludes_below_threshold_months_test() {
  rolling_back(fn(conn) {
    let assert Ok(headline) = forecast_read.forecast(ctx(conn), as_of())
    let profits =
      list.map(headline.months, fn(month) { money.to_float(month.profit) })
    let assert Ok(max_profit) =
      list.reduce(profits, fn(acc, value) {
        case value >. acc {
          True -> value
          False -> acc
        }
      })

    let assert Ok(response) =
      forecast_table.forecast_table(
        ctx(conn),
        as_of(),
        applied(
          [
            #(
              "profit",
              NumberRange(min: Some(float.to_string(max_profit)), max: None),
            ),
          ],
          None,
        ),
      )

    assert list.length(response.rows) < list.length(headline.months)
    assert list.all(response.rows, fn(row) {
      case cell_of(row, "profit") {
        SignedMoneyCell(amount:, ..) ->
          money.to_float(amount) >=. max_profit -. 0.01
        _ -> False
      }
    })
  })
}
