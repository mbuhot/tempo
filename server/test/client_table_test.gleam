//// Layer-2 tests for the clients generic-table read (`client/table`). Insert a small
//// fixture of clients that each hold a contract but run NO project — a shape no base-
//// seed client has (every seeded client runs at least one project) — so every data
//// assertion can scope to `projects = 0` and isolate the fixture's rows from the
//// shared dev DB's seeded directory. Each test runs in its OWN transaction and rolls
//// back, so the base seed the read-only tests rely on is never mutated.

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar.{type Date, Date, January, June}
import pog
import shared/table/cell.{DateCell, EntityCell, EnumCell, NumberCell}
import shared/table/column
import shared/table/query.{
  type Applied, type FilterValue, Applied, NumberRange, SelectValue,
}
import shared/table/response.{type Row}
import shared/table/sort.{type Sort, Asc, Desc, Sort}
import tempo/server/client/table as client_table
import tempo/server/context.{type Context, Context}
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
  sort: option.Option(Sort),
) -> Applied {
  Applied(filters: dict.from_list(filters), sort:, page_size: 50, cursor: None)
}

/// Scope every data assertion to the fixture's project-less clients so the shared dev
/// DB's seeded directory never leaks into the count/order assertions.
fn scoped(
  filters: List(#(String, FilterValue)),
  sort: option.Option(Sort),
) -> Applied {
  applied(
    [#("projects", NumberRange(min: None, max: Some(0.0))), ..filters],
    sort,
  )
}

fn cell_of(row: Row, key: String) -> cell.Cell {
  let assert Ok(value) = dict.get(row.cells, key)
  value
}

// --- fixture ----------------------------------------------------------------

fn insert_client(conn: pog.Connection, name: String) -> Int {
  let row_decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("INSERT INTO client DEFAULT VALUES RETURNING id")
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  let assert Ok(_) =
    pog.query(
      "INSERT INTO client_profile (client_id, name, recorded_during) "
      <> "VALUES ($1, $2, daterange('2024-01-01', NULL, '[)'))",
    )
    |> pog.parameter(pog.int(id))
    |> pog.parameter(pog.text(name))
    |> pog.execute(on: conn)
  id
}

/// One client holding a single contract over `term` but running no project, so its
/// row has `projects = 0` (the fixture's isolation handle). Returns the client id.
fn client_with_contract(
  conn: pog.Connection,
  name: String,
  contract_id: Int,
  term: String,
) -> Int {
  let client_id = insert_client(conn, name)
  exec(
    conn,
    "INSERT INTO contract (id) VALUES (" <> int.to_string(contract_id) <> ")",
  )
  exec(
    conn,
    "INSERT INTO contract_terms (contract_id, client_id, term) VALUES ("
      <> int.to_string(contract_id)
      <> ", "
      <> int.to_string(client_id)
      <> ", "
      <> term
      <> ")",
  )
  client_id
}

/// Two project-less clients: Apex (contract covering the as-of → active) and Borealis
/// (contract that started before but ended by the as-of → ended). Both `since`
/// 2026-01-01. Sorted by name: Apex, then Borealis.
fn fixture(conn: pog.Connection) -> Nil {
  let _ =
    client_with_contract(
      conn,
      "Apex Holdings",
      90_301,
      "daterange('2026-01-01', '2027-01-01')",
    )
  let _ =
    client_with_contract(
      conn,
      "Borealis Trust",
      90_302,
      "daterange('2026-01-01', '2026-04-01')",
    )
  Nil
}

fn as_of() -> Date {
  Date(2026, June, 15)
}

// --- tests ------------------------------------------------------------------

pub fn schema_advertises_client_columns_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      client_table.client_table(ctx(conn), as_of(), applied([], None))
    assert response.schema.table_id == "clients"
    let keys = list.map(response.schema.columns, fn(column) { column.key })
    assert keys == ["name", "since", "projects", "status"]
    assert response.schema.default_sort == Some(Sort(key: "name", dir: Asc))
  })
}

pub fn unfiltered_returns_both_clients_with_rich_cells_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      client_table.client_table(ctx(conn), as_of(), scoped([], None))
    assert list.length(response.rows) == 2
    let assert [first, ..] = response.rows
    let assert EntityCell(label:, ..) = cell_of(first, "name")
    assert label == "Apex Holdings"
    assert cell_of(first, "since") == DateCell(Date(2026, January, 1))
    assert cell_of(first, "projects") == NumberCell(0.0)
    assert cell_of(first, "status")
      == EnumCell(label: "Active", tone: column.Positive)
  })
}

pub fn default_sort_is_name_ascending_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      client_table.client_table(ctx(conn), as_of(), scoped([], None))
    let names =
      list.map(response.rows, fn(row) {
        let assert EntityCell(label:, ..) = cell_of(row, "name")
        label
      })
    assert names == ["Apex Holdings", "Borealis Trust"]
  })
}

pub fn name_sort_descending_reverses_order_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      client_table.client_table(
        ctx(conn),
        as_of(),
        scoped([], Some(Sort(key: "name", dir: Desc))),
      )
    let names =
      list.map(response.rows, fn(row) {
        let assert EntityCell(label:, ..) = cell_of(row, "name")
        label
      })
    assert names == ["Borealis Trust", "Apex Holdings"]
  })
}

pub fn status_filter_keeps_only_ended_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      client_table.client_table(
        ctx(conn),
        as_of(),
        scoped([#("status", SelectValue(["ended"]))], None),
      )
    assert list.length(response.rows) == 1
    let assert [row] = response.rows
    let assert EntityCell(label:, ..) = cell_of(row, "name")
    assert label == "Borealis Trust"
    assert cell_of(row, "status")
      == EnumCell(label: "Ended", tone: column.Neutral)
  })
}
