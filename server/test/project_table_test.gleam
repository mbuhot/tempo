//// Layer-2 tests for the projects generic-table read (`project/table`). Insert a
//// small fixture of projects whose plans carry budgets in a distinctive high band
//// (~900_000) that NO base-seed project uses — so every data assertion can scope to
//// that budget range and isolate the fixture's rows from the shared dev DB's seeded
//// directory. Each test runs in its OWN transaction and rolls back, so the base seed
//// the read-only tests rely on is never mutated.

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar.{type Date, Date, January, June}
import pog
import shared/table/cell.{DateCell, EntityCell, EnumCell, MoneyCell, NumberCell}
import shared/table/column
import shared/table/query.{
  type Applied, type FilterValue, Applied, NumberRange, SelectValue,
}
import shared/table/response.{type Row}
import shared/table/sort.{type Sort, Asc, Desc, Sort}
import tempo/server/context.{type Context, Context}
import tempo/server/project/table as project_table
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

/// Scope every data assertion to the fixture's distinctive budget band so the shared
/// dev DB's seeded directory never leaks into the count/order assertions.
fn scoped(
  filters: List(#(String, FilterValue)),
  sort: option.Option(Sort),
) -> Applied {
  applied(
    [
      #("budget", NumberRange(min: Some(900_000.0), max: Some(900_100.0))),
      ..filters
    ],
    sort,
  )
}

fn cell_of(row: Row, key: String) -> cell.Cell {
  let assert Ok(value) = dict.get(row.cells, key)
  value
}

// --- fixture ----------------------------------------------------------------

fn insert_project(conn: pog.Connection, title: String) -> Int {
  let row_decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("INSERT INTO project DEFAULT VALUES RETURNING id")
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  let assert Ok(_) =
    pog.query(
      "INSERT INTO project_profile (project_id, title, summary, recorded_during) "
      <> "VALUES ($1, $2, '', daterange('2024-01-01', NULL, '[)'))",
    )
    |> pog.parameter(pog.int(id))
    |> pog.parameter(pog.text(title))
    |> pog.execute(on: conn)
  id
}

/// One project run over `run_term` (whose owning client/contract are minted at the
/// shared `client_id`), with a plan carrying the distinctive `budget` and the given
/// `target`. No allocations, so `team_size = 0`. Returns the project id.
fn project_with_run(
  conn: pog.Connection,
  title: String,
  client_id: Int,
  run_term: String,
  budget: String,
  target: String,
) -> Int {
  let project_id = insert_project(conn, title)
  exec(
    conn,
    "INSERT INTO project_run (project_id, contract_id, active_during) VALUES ("
      <> int.to_string(project_id)
      <> ", "
      <> int.to_string(client_id)
      <> ", "
      <> run_term
      <> ")",
  )
  exec(
    conn,
    "INSERT INTO project_plan (project_id, budget, target_completion, planned_during) VALUES ("
      <> int.to_string(project_id)
      <> ", "
      <> budget
      <> ", '"
      <> target
      <> "', daterange('2024-01-01', NULL, '[)'))",
  )
  project_id
}

/// Mint one client + contract + contract_terms covering `[2026-01-01, 2027-01-01)`
/// at a reserved id, so the fixture's project runs have an owning contract to anchor
/// to. Returns that shared client/contract id.
fn shared_client(conn: pog.Connection, id: Int) -> Int {
  exec(conn, "INSERT INTO client (id) VALUES (" <> int.to_string(id) <> ")")
  exec(
    conn,
    "INSERT INTO client_profile (client_id, name, recorded_during) VALUES ("
      <> int.to_string(id)
      <> ", 'Acme Anvil Co', daterange('2024-01-01', NULL, '[)'))",
  )
  exec(conn, "INSERT INTO contract (id) VALUES (" <> int.to_string(id) <> ")")
  exec(
    conn,
    "INSERT INTO contract_terms (contract_id, client_id, term) VALUES ("
      <> int.to_string(id)
      <> ", "
      <> int.to_string(id)
      <> ", daterange('2026-01-01', '2027-01-01'))",
  )
  id
}

/// Two project-less-team projects sharing one client/contract: Aurora (run covering
/// the as-of → active, budget 900_001) and Beacon (run that started before but ended
/// by the as-of → ended, budget 900_002). Both target 2026-01-01. Sorted by title:
/// Aurora, then Beacon.
fn fixture(conn: pog.Connection) -> Nil {
  let client_id = shared_client(conn, 90_401)
  let _ =
    project_with_run(
      conn,
      "Aurora Platform",
      client_id,
      "daterange('2026-01-01', '2027-01-01')",
      "900001",
      "2026-01-01",
    )
  let _ =
    project_with_run(
      conn,
      "Beacon Migration",
      client_id,
      "daterange('2026-01-01', '2026-04-01')",
      "900002",
      "2026-01-01",
    )
  Nil
}

fn as_of() -> Date {
  Date(2026, June, 15)
}

// --- tests ------------------------------------------------------------------

pub fn schema_advertises_project_columns_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      project_table.project_table(ctx(conn), as_of(), applied([], None))
    assert response.schema.table_id == "projects"
    let keys = list.map(response.schema.columns, fn(column) { column.key })
    assert keys
      == ["title", "state", "team_size", "budget", "target_completion"]
    assert response.schema.default_sort == Some(Sort(key: "title", dir: Asc))
  })
}

pub fn unfiltered_returns_both_projects_with_rich_cells_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      project_table.project_table(ctx(conn), as_of(), scoped([], None))
    assert list.length(response.rows) == 2
    let assert [first, ..] = response.rows
    let assert EntityCell(label:, ..) = cell_of(first, "title")
    assert label == "Aurora Platform"
    assert cell_of(first, "state")
      == EnumCell(label: "Active", tone: column.Positive)
    assert cell_of(first, "team_size") == NumberCell(0.0)
    assert cell_of(first, "target_completion")
      == DateCell(Date(2026, January, 1))
    let assert MoneyCell(_) = cell_of(first, "budget")
  })
}

pub fn default_sort_is_title_ascending_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      project_table.project_table(ctx(conn), as_of(), scoped([], None))
    let titles =
      list.map(response.rows, fn(row) {
        let assert EntityCell(label:, ..) = cell_of(row, "title")
        label
      })
    assert titles == ["Aurora Platform", "Beacon Migration"]
  })
}

pub fn title_sort_descending_reverses_order_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      project_table.project_table(
        ctx(conn),
        as_of(),
        scoped([], Some(Sort(key: "title", dir: Desc))),
      )
    let titles =
      list.map(response.rows, fn(row) {
        let assert EntityCell(label:, ..) = cell_of(row, "title")
        label
      })
    assert titles == ["Beacon Migration", "Aurora Platform"]
  })
}

pub fn state_filter_keeps_only_ended_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      project_table.project_table(
        ctx(conn),
        as_of(),
        scoped([#("state", SelectValue(["ended"]))], None),
      )
    assert list.length(response.rows) == 1
    let assert [row] = response.rows
    let assert EntityCell(label:, ..) = cell_of(row, "title")
    assert label == "Beacon Migration"
    assert cell_of(row, "state")
      == EnumCell(label: "Ended", tone: column.Neutral)
  })
}
