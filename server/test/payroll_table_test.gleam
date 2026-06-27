//// Layer-2 tests for the payroll generic-table read (`payroll/table`). Insert a
//// small fixture of engineers whose names share a distinctive "Ztest" token — a
//// token NO seed engineer carries — so every data assertion scopes to that token
//// (the outer engineer-name filter) and isolates the fixture's rows from the shared
//// dev DB's seeded payroll. Each test runs in its OWN transaction and rolls back, so
//// the base seed the read-only tests rely on is never mutated.
////
//// The window is June 2026. One fixture engineer ("Ztest Promoted") is promoted
//// mid-month (L1 the first half, L2 the second), so their preview total breaks into
//// TWO per-level segments — the nested children the table exposes.

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar.{type Date, Date, July, June}
import pog
import shared/money
import shared/table/cell.{MoneyCell, NumberCell, PersonCell, TextCell}
import shared/table/column
import shared/table/query.{
  type Applied, type FilterValue, Applied, NumberRange, TextValue,
}
import shared/table/response.{type Row}
import shared/table/sort.{type Sort, Asc, Desc, Sort}
import tempo/server/context.{type Context, Context}
import tempo/server/payroll/table as payroll_table
import test_pool

// --- harness ----------------------------------------------------------------

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

fn exec(conn: pog.Connection, sql: String) -> Nil {
  let assert Ok(_) =
    pog.query(sql)
    |> pog.execute(on: conn)
  Nil
}

fn ctx(conn: pog.Connection) -> Context {
  Context(db: conn, principal: None)
}

fn applied(
  filters: List(#(String, FilterValue)),
  sort: Option(Sort),
) -> Applied {
  Applied(filters: dict.from_list(filters), sort:, page_size: 100, cursor: None)
}

/// Scope every data assertion to the fixture's distinctive name token so the shared
/// dev DB's seeded payroll never leaks into the count/order assertions.
fn scoped(
  filters: List(#(String, FilterValue)),
  sort: Option(Sort),
) -> Applied {
  applied([#("engineer", TextValue("Ztest")), ..filters], sort)
}

fn cell_of(row: Row, key: String) -> cell.Cell {
  let assert Ok(value) = dict.get(row.cells, key)
  value
}

fn from() -> Date {
  Date(2026, June, 1)
}

fn to() -> Date {
  Date(2026, July, 1)
}

// --- fixture ----------------------------------------------------------------

fn insert_engineer(conn: pog.Connection, name: String) -> Int {
  let row_decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("INSERT INTO engineer DEFAULT VALUES RETURNING id")
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  exec(
    conn,
    "INSERT INTO engineer_contact "
      <> "(engineer_id, name, email, phone, postal_address, recorded_during) "
      <> "VALUES ("
      <> int.to_string(id)
      <> ", '"
      <> name
      <> "', '"
      <> name
      <> "@tempo.test', '', '', daterange('2024-01-01', NULL, '[)'))",
  )
  exec(
    conn,
    "INSERT INTO employment (engineer_id, employed_during) VALUES ("
      <> int.to_string(id)
      <> ", daterange('2026-01-01', NULL, '[)'))",
  )
  id
}

/// A role band held over a single date range.
fn give_role(
  conn: pog.Connection,
  engineer_id: Int,
  level: Int,
  range: String,
) {
  exec(
    conn,
    "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES ("
      <> int.to_string(engineer_id)
      <> ", "
      <> int.to_string(level)
      <> ", "
      <> range
      <> ")",
  )
}

/// "Ztest Steady": employed all June at one level (one segment). "Ztest Promoted":
/// L1 for the first half of June, L2 for the second (two segments). The seed already
/// carries salaries for every level, so both engineers price.
fn fixture(conn: pog.Connection) -> #(Int, Int) {
  let steady = insert_engineer(conn, "Ztest Steady")
  give_role(conn, steady, 3, "daterange('2026-01-01', NULL, '[)')")

  let promoted = insert_engineer(conn, "Ztest Promoted")
  give_role(conn, promoted, 1, "daterange('2026-01-01', '2026-06-16', '[)')")
  give_role(conn, promoted, 2, "daterange('2026-06-16', NULL, '[)')")
  #(steady, promoted)
}

// --- tests ------------------------------------------------------------------

pub fn schema_advertises_preview_columns_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      payroll_table.payroll_table(
        ctx(conn),
        from(),
        to(),
        payroll_table.Preview,
        applied([], None),
      )
    assert response.schema.table_id == "payroll-preview"
    let keys = list.map(response.schema.columns, fn(column) { column.key })
    assert keys == ["engineer", "days", "amount"]
    assert response.schema.default_sort == Some(Sort(key: "engineer", dir: Asc))
  })
}

pub fn schema_advertises_variance_columns_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      payroll_table.payroll_table(
        ctx(conn),
        from(),
        to(),
        payroll_table.Variance,
        applied([], None),
      )
    assert response.schema.table_id == "payroll-variance"
    let keys = list.map(response.schema.columns, fn(column) { column.key })
    assert keys == ["engineer", "paid", "should_be", "delta"]
    let assert Ok(delta_column) =
      list.find(response.schema.columns, fn(column) { column.key == "delta" })
    assert delta_column.column_type == column.SignedMoneyType
  })
}

pub fn engineer_row_carries_segment_children_test() {
  rolling_back(fn(conn) {
    let _ = fixture(conn)
    let assert Ok(response) =
      payroll_table.payroll_table(
        ctx(conn),
        from(),
        to(),
        payroll_table.Preview,
        scoped([], None),
      )
    let assert Ok(promoted) =
      list.find(response.rows, fn(row) {
        case cell_of(row, "engineer") {
          PersonCell(name:, ..) -> name == "Ztest Promoted"
          _ -> False
        }
      })
    assert list.length(promoted.children) == 2
    let assert [first_segment, ..] = promoted.children
    let assert TextCell(label) = cell_of(first_segment, "engineer")
    assert label == "↳ Associate · $2000/mo"
    let assert NumberCell(_) = cell_of(first_segment, "days")
    let assert MoneyCell(_) = cell_of(first_segment, "amount")
    assert first_segment.children == []
  })
}

pub fn steady_engineer_has_one_segment_child_test() {
  rolling_back(fn(conn) {
    let _ = fixture(conn)
    let assert Ok(response) =
      payroll_table.payroll_table(
        ctx(conn),
        from(),
        to(),
        payroll_table.Preview,
        scoped([], None),
      )
    let assert Ok(steady) =
      list.find(response.rows, fn(row) {
        case cell_of(row, "engineer") {
          PersonCell(name:, ..) -> name == "Ztest Steady"
          _ -> False
        }
      })
    assert list.length(steady.children) == 1
  })
}

pub fn engineer_name_filter_narrows_to_one_test() {
  rolling_back(fn(conn) {
    let _ = fixture(conn)
    let assert Ok(response) =
      payroll_table.payroll_table(
        ctx(conn),
        from(),
        to(),
        payroll_table.Preview,
        applied([#("engineer", TextValue("Ztest Promoted"))], None),
      )
    assert list.length(response.rows) == 1
    let assert [only] = response.rows
    let assert PersonCell(name:, ..) = cell_of(only, "engineer")
    assert name == "Ztest Promoted"
  })
}

pub fn default_sort_is_engineer_ascending_test() {
  rolling_back(fn(conn) {
    let _ = fixture(conn)
    let assert Ok(response) =
      payroll_table.payroll_table(
        ctx(conn),
        from(),
        to(),
        payroll_table.Preview,
        scoped([], None),
      )
    let names = engineer_names(response.rows)
    assert names == ["Ztest Promoted", "Ztest Steady"]
  })
}

pub fn engineer_sort_descending_reverses_order_test() {
  rolling_back(fn(conn) {
    let _ = fixture(conn)
    let assert Ok(response) =
      payroll_table.payroll_table(
        ctx(conn),
        from(),
        to(),
        payroll_table.Preview,
        scoped([], Some(Sort(key: "engineer", dir: Desc))),
      )
    let names = engineer_names(response.rows)
    assert names == ["Ztest Steady", "Ztest Promoted"]
  })
}

pub fn amount_range_filter_excludes_below_threshold_test() {
  rolling_back(fn(conn) {
    let _ = fixture(conn)
    let assert Ok(unfiltered) =
      payroll_table.payroll_table(
        ctx(conn),
        from(),
        to(),
        payroll_table.Preview,
        scoped([], None),
      )
    let amounts = list.map(unfiltered.rows, fn(row) { amount_of(row) })
    let assert Ok(max_amount) =
      list.reduce(amounts, fn(acc, value) {
        case value >. acc {
          True -> value
          False -> acc
        }
      })
    let assert Ok(filtered) =
      payroll_table.payroll_table(
        ctx(conn),
        from(),
        to(),
        payroll_table.Preview,
        scoped(
          [#("amount", NumberRange(min: Some(max_amount), max: None))],
          None,
        ),
      )
    assert list.length(filtered.rows) < list.length(unfiltered.rows)
    assert list.all(filtered.rows, fn(row) {
      amount_of(row) >=. max_amount -. 0.01
    })
  })
}

// --- helpers ----------------------------------------------------------------

fn engineer_names(rows: List(Row)) -> List(String) {
  list.map(rows, fn(row) {
    let assert PersonCell(name:, ..) = cell_of(row, "engineer")
    name
  })
}

fn amount_of(row: Row) -> Float {
  let assert MoneyCell(amount) = cell_of(row, "amount")
  money.to_float(amount)
}
