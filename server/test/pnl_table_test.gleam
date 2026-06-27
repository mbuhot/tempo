//// Layer-2 tests for the per-engineer P&L generic-table read (`pnl/table`). Insert
//// a small fixture of engineers employed at level 1 across 2026 — a level NO seed
//// engineer holds — and scope every data assertion to the fixture's two engineers
//// by name, isolating the fixture's rows from the shared dev DB's seeded roster.
//// Each test runs in its OWN transaction and rolls back, so the base seed is never
//// mutated.
////
//// The as-of is JULY 2026 — a month with NO payroll run on record, so each fixture
//// engineer's cost is the EXPECTED salary (the payroll_amounts proration) rather than
//// a $0 actual. The seed rate card (L1 @ 400/day) and salary (L1 @ 2000/month) then
//// make the figures deterministic: an allocated full-month L1 engineer earns
//// 400 × 31 = 12400 against a 2000 estimated cost, a +10400 PROFIT (tone Positive); a
//// benched L1 engineer earns 0 against the same 2000 cost, a −2000 LOSS (tone
//// Critical).

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar.{type Date, Date, July}
import pog
import shared/money
import shared/table/cell.{PercentCell, PersonCell, SignedMoneyCell}
import shared/table/column
import shared/table/query.{type Applied, type FilterValue, Applied, NumberRange}
import shared/table/response.{type Row}
import shared/table/sort.{type Sort, Asc, Sort}
import tempo/server/context.{type Context, Context}
import tempo/server/pnl/table as pnl_table
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
  Applied(filters: dict.from_list(filters), sort:, page_size: 200, cursor: None)
}

fn cell_of(row: Row, key: String) -> cell.Cell {
  let assert Ok(value) = dict.get(row.cells, key)
  value
}

/// The fixture row for an engineer by name; the fixture names are unique against
/// the shared dev DB so this isolates the fixture from the seeded roster.
fn row_for(rows: List(Row), name: String) -> Row {
  let assert Ok(row) =
    list.find(rows, fn(row) {
      case dict.get(row.cells, "engineer") {
        Ok(PersonCell(name: row_name, ..)) -> row_name == name
        _ -> False
      }
    })
  row
}

// --- fixture ----------------------------------------------------------------

fn insert_engineer(conn: pog.Connection, name: String, email: String) -> Int {
  let row_decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("INSERT INTO engineer DEFAULT VALUES RETURNING id")
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  let assert Ok(_) =
    pog.query(
      "INSERT INTO engineer_contact "
      <> "(engineer_id, name, email, phone, postal_address, recorded_during) "
      <> "VALUES ($1, $2, $3, '', '', daterange('2024-01-01', NULL, '[)'))",
    )
    |> pog.parameter(pog.int(id))
    |> pog.parameter(pog.text(name))
    |> pog.parameter(pog.text(email))
    |> pog.execute(on: conn)
  id
}

/// Employ one engineer at level 1 for all of 2026, allocated to a fresh project at
/// `fraction` ("0" leaves them on the bench). Returns the engineer id.
fn employ(
  conn: pog.Connection,
  name: String,
  email: String,
  project_id: Int,
  fraction: String,
) -> Int {
  let engineer_id = insert_engineer(conn, name, email)
  exec(
    conn,
    "INSERT INTO employment (engineer_id, employed_during) VALUES ("
      <> int.to_string(engineer_id)
      <> ", daterange('2026-01-01', NULL, '[)'))",
  )
  exec(
    conn,
    "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES ("
      <> int.to_string(engineer_id)
      <> ", 1, daterange('2026-01-01', NULL, '[)'))",
  )
  case fraction {
    "0" -> Nil
    _ -> {
      exec(
        conn,
        "INSERT INTO project (id) VALUES (" <> int.to_string(project_id) <> ")",
      )
      exec(
        conn,
        "INSERT INTO project_profile (project_id, title, summary, recorded_during) VALUES ("
          <> int.to_string(project_id)
          <> ", 'Test Project', '', daterange('2024-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO contract (id) VALUES (" <> int.to_string(project_id) <> ")",
      )
      exec(
        conn,
        "INSERT INTO client (id) VALUES (" <> int.to_string(project_id) <> ")",
      )
      exec(
        conn,
        "INSERT INTO client_profile (client_id, name, recorded_during) VALUES ("
          <> int.to_string(project_id)
          <> ", 'Test Client', daterange('2024-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO contract_terms (contract_id, client_id, term) VALUES ("
          <> int.to_string(project_id)
          <> ", "
          <> int.to_string(project_id)
          <> ", daterange('2026-01-01', '2027-01-01'))",
      )
      exec(
        conn,
        "INSERT INTO project_run (project_id, contract_id, active_during) VALUES ("
          <> int.to_string(project_id)
          <> ", "
          <> int.to_string(project_id)
          <> ", daterange('2026-01-01', '2027-01-01'))",
      )
      exec(
        conn,
        "INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", "
          <> int.to_string(project_id)
          <> ", "
          <> fraction
          <> ", daterange('2026-01-01', '2027-01-01'))",
      )
    }
  }
  engineer_id
}

/// Two level-1 engineers employed across 2026: Ada (allocated 1.00 → +10400
/// profit in July) and Babbage (benched → −2000 loss).
fn fixture(conn: pog.Connection) -> Nil {
  let _ = employ(conn, "Ada Lovelace", "ada@tempo.test", 90_301, "1.00")
  let _ = employ(conn, "Babbage Charles", "babbage@tempo.test", 90_302, "0")
  Nil
}

fn as_of() -> Date {
  Date(2026, July, 15)
}

fn money_of(text: String) -> money.Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

// --- tests ------------------------------------------------------------------

pub fn schema_advertises_pnl_columns_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      pnl_table.pnl_table(ctx(conn), as_of(), applied([], None))
    assert response.schema.table_id == "pnl"
    let keys = list.map(response.schema.columns, fn(column) { column.key })
    assert keys
      == ["engineer", "revenue", "cost", "profit", "margin", "utilization"]
    assert response.schema.default_sort
      == Some(Sort(key: "profit", dir: sort.Desc))
  })
}

pub fn profit_column_is_signed_money_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      pnl_table.pnl_table(ctx(conn), as_of(), applied([], None))
    let assert Ok(profit_column) =
      list.find(response.schema.columns, fn(column) { column.key == "profit" })
    assert profit_column.column_type == column.SignedMoneyType
  })
}

pub fn allocated_engineer_row_has_rich_cells_and_positive_profit_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      pnl_table.pnl_table(ctx(conn), as_of(), applied([], None))
    let ada = row_for(response.rows, "Ada Lovelace")
    let assert PersonCell(name:, ..) = cell_of(ada, "engineer")
    assert name == "Ada Lovelace"
    assert cell_of(ada, "revenue") == cell.MoneyCell(money_of("12400.00"))
    assert cell_of(ada, "cost") == cell.MoneyCell(money_of("2000.00"))
    assert cell_of(ada, "profit")
      == SignedMoneyCell(amount: money_of("10400.00"), tone: column.Positive)
    let assert PercentCell(utilization) = cell_of(ada, "utilization")
    assert utilization == 100.0
  })
}

pub fn benched_engineer_runs_at_a_loss_with_critical_tone_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      pnl_table.pnl_table(ctx(conn), as_of(), applied([], None))
    let babbage = row_for(response.rows, "Babbage Charles")
    assert cell_of(babbage, "revenue") == cell.MoneyCell(money_of("0.00"))
    assert cell_of(babbage, "profit")
      == SignedMoneyCell(amount: money_of("-2000.00"), tone: column.Critical)
    let assert PercentCell(utilization) = cell_of(babbage, "utilization")
    assert utilization == 0.0
  })
}

pub fn default_sort_is_profit_descending_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      pnl_table.pnl_table(ctx(conn), as_of(), applied([], None))
    let names = fixture_names_in_order(response.rows)
    assert names == ["Ada Lovelace", "Babbage Charles"]
  })
}

pub fn profit_sort_ascending_puts_the_loss_first_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      pnl_table.pnl_table(
        ctx(conn),
        as_of(),
        applied([], Some(Sort(key: "profit", dir: Asc))),
      )
    let names = fixture_names_in_order(response.rows)
    assert names == ["Babbage Charles", "Ada Lovelace"]
  })
}

pub fn profit_range_filter_keeps_only_the_profitable_engineer_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      pnl_table.pnl_table(
        ctx(conn),
        as_of(),
        applied([#("profit", NumberRange(min: Some(0.0), max: None))], None),
      )
    let names = fixture_names_in_order(response.rows)
    assert names == ["Ada Lovelace"]
  })
}

/// The fixture's two engineer names, in result order, dropping any seeded roster
/// rows so the order assertion isolates the fixture.
fn fixture_names_in_order(rows: List(Row)) -> List(String) {
  rows
  |> list.filter_map(fn(row) {
    case dict.get(row.cells, "engineer") {
      Ok(PersonCell(name:, ..)) ->
        case name == "Ada Lovelace" || name == "Babbage Charles" {
          True -> Ok(name)
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}
