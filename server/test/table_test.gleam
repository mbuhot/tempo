//// Layer-2 tests for the invoices generic-table read (`invoice/table`). Build a
//// billing fixture, draft two invoices (May + June) for one project through the
//// command path, then drive `invoice_table` with assorted `Applied` filter/sort/
//// page states and assert the decoded rows. Each test runs in its OWN transaction
//// and rolls back, so the base seed the read-only tests rely on is never mutated.

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar.{type Date, Date, July, June, May}
import pog
import shared/command.{type Command} as gateway
import shared/invoice/command as invoice_command
import shared/money
import shared/table/cell.{type Cell, EntityCell, EnumCell, MoneyCell, TextCell}
import shared/table/column
import shared/table/query.{
  type Applied, type FilterValue, Applied, DateRange, NumberRange, SelectValue,
}
import shared/table/response.{type Row}
import shared/table/sort.{type Sort, Asc, Desc, Sort}
import tempo/server/command
import tempo/server/context.{type Context, Context}
import tempo/server/invoice/table as invoice_table
import test_pool

// --- harness (mirrors financials_test) --------------------------------------

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

fn apply(conn: pog.Connection, command: Command) -> Nil {
  let assert Ok(_) = command.dispatch_in(conn, "tester", command)
  Nil
}

fn exec(conn: pog.Connection, sql: String) -> Nil {
  let assert Ok(_) =
    pog.query(sql)
    |> pog.execute(on: conn)
  Nil
}

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
  let assert Ok(_) =
    pog.query(
      "INSERT INTO engineer_contact "
      <> "(engineer_id, name, email, phone, postal_address, recorded_during) "
      <> "VALUES ($1, $2, '', '', '', daterange('2024-01-01', NULL, '[)'))",
    )
    |> pog.parameter(pog.int(id))
    |> pog.parameter(pog.text(name))
    |> pog.execute(on: conn)
  id
}

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

fn billing_fixture(
  conn: pog.Connection,
  engineer_name: String,
  client_name: String,
  contract_id: Int,
  project_id: Int,
  rate: String,
) -> Int {
  let engineer_id = insert_engineer(conn, engineer_name)
  let client_id = insert_client(conn, client_name)
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
  exec(conn, "DELETE FROM rate_card WHERE level = 1")
  exec(
    conn,
    "INSERT INTO rate_card (level, day_rate, effective_during) VALUES (1, "
      <> rate
      <> ", daterange('2024-01-01', NULL, '[)'))",
  )
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
      <> ", daterange('2026-01-01', '2027-01-01'))",
  )
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
    "INSERT INTO project_run (project_id, contract_id, active_during) VALUES ("
      <> int.to_string(project_id)
      <> ", "
      <> int.to_string(contract_id)
      <> ", daterange('2026-01-01', '2027-01-01'))",
  )
  exec(
    conn,
    "INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during) VALUES ("
      <> int.to_string(engineer_id)
      <> ", "
      <> int.to_string(project_id)
      <> ", 1.00, daterange('2026-01-01', '2027-01-01'))",
  )
  engineer_id
}

// --- helpers ----------------------------------------------------------------

fn ctx(conn: pog.Connection) -> Context {
  Context(db: conn, principal: None)
}

fn applied(
  filters: List(#(String, FilterValue)),
  sort: option.Option(Sort),
) -> Applied {
  Applied(filters: dict.from_list(filters), sort:, page_size: 50, cursor: None)
}

/// The dev DB the suite shares may already carry demo invoices, so every data
/// assertion scopes to the fixture's unique client to isolate its two invoices.
fn scoped(
  filters: List(#(String, FilterValue)),
  sort: option.Option(Sort),
) -> Applied {
  applied([#("client", SelectValue(["Babbage Engines"])), ..filters], sort)
}

fn cell_of(row: Row, key: String) -> Cell {
  let assert Ok(value) = dict.get(row.cells, key)
  value
}

fn fixture(conn: pog.Connection) -> Nil {
  let _ =
    billing_fixture(
      conn,
      "Ada Lovelace",
      "Babbage Engines",
      90_101,
      80_101,
      "800.00",
    )
  apply(
    conn,
    gateway.InvoiceCommand(invoice_command.DraftInvoice(
      80_101,
      Date(2026, May, 1),
      Date(2026, June, 1),
    )),
  )
  apply(
    conn,
    gateway.InvoiceCommand(invoice_command.DraftInvoice(
      80_101,
      Date(2026, June, 1),
      Date(2026, July, 1),
    )),
  )
  Nil
}

fn as_of() -> Date {
  Date(2026, June, 15)
}

// --- tests ------------------------------------------------------------------

pub fn schema_advertises_invoice_columns_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      invoice_table.invoice_table(ctx(conn), as_of(), applied([], None))
    assert response.schema.table_id == "invoices"
    let keys = list.map(response.schema.columns, fn(column) { column.key })
    assert keys
      == [
        "id",
        "project",
        "client",
        "engineers",
        "billing_month",
        "total",
        "status",
      ]
    assert response.schema.default_sort
      == Some(Sort(key: "billing_month", dir: Desc))
  })
}

pub fn unfiltered_returns_both_invoices_with_rich_cells_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      invoice_table.invoice_table(ctx(conn), as_of(), scoped([], None))
    assert list.length(response.rows) == 2
    let assert [first, ..] = response.rows
    assert cell_of(first, "client") == TextCell("Babbage Engines")
    assert cell_of(first, "status")
      == EnumCell(label: "Draft", tone: column.Neutral)
    let assert EntityCell(label:, ..) = cell_of(first, "project")
    assert label == "Test Project"
  })
}

pub fn default_sort_is_billing_month_descending_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      invoice_table.invoice_table(ctx(conn), as_of(), scoped([], None))
    let months =
      list.map(response.rows, fn(row) {
        let assert cell.DateCell(Some(date)) = cell_of(row, "billing_month")
        date
      })
    assert months == [Date(2026, June, 1), Date(2026, May, 1)]
  })
}

pub fn status_filter_excludes_non_matching_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(paid) =
      invoice_table.invoice_table(
        ctx(conn),
        as_of(),
        scoped([#("status", SelectValue(["paid"]))], None),
      )
    assert paid.rows == []
    let assert Ok(draft) =
      invoice_table.invoice_table(
        ctx(conn),
        as_of(),
        scoped([#("status", SelectValue(["draft"]))], None),
      )
    assert list.length(draft.rows) == 2
  })
}

pub fn total_range_filter_keeps_only_in_band_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      invoice_table.invoice_table(
        ctx(conn),
        as_of(),
        scoped([#("total", NumberRange(min: Some("24500"), max: None))], None),
      )
    assert list.length(response.rows) == 1
    let assert [row] = response.rows
    let assert MoneyCell(amount) = cell_of(row, "total")
    assert money.to_string(amount) == "24800.00"
  })
}

pub fn date_range_filter_keeps_only_that_month_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      invoice_table.invoice_table(
        ctx(conn),
        as_of(),
        scoped(
          [#("billing_month", DateRange(from: Some("2026-06-01"), to: None))],
          None,
        ),
      )
    assert list.length(response.rows) == 1
    let assert [row] = response.rows
    assert cell_of(row, "billing_month")
      == cell.DateCell(Some(Date(2026, June, 1)))
  })
}

pub fn sort_by_total_ascending_orders_rows_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      invoice_table.invoice_table(
        ctx(conn),
        as_of(),
        scoped([], Some(Sort(key: "total", dir: Asc))),
      )
    let totals =
      list.map(response.rows, fn(row) {
        let assert MoneyCell(amount) = cell_of(row, "total")
        money.to_string(amount)
      })
    assert totals == ["24000.00", "24800.00"]
  })
}

pub fn page_size_one_yields_a_next_cursor_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let scope = dict.from_list([#("client", SelectValue(["Babbage Engines"]))])
    let first_page =
      Applied(filters: scope, sort: None, page_size: 1, cursor: None)
    let assert Ok(response) =
      invoice_table.invoice_table(ctx(conn), as_of(), first_page)
    assert list.length(response.rows) == 1
    let assert Some(cursor) = response.page.next_cursor
    let assert Ok(next) =
      invoice_table.invoice_table(
        ctx(conn),
        as_of(),
        Applied(filters: scope, sort: None, page_size: 1, cursor: Some(cursor)),
      )
    assert list.length(next.rows) == 1
    let first_id = {
      let assert [row] = response.rows
      row.id
    }
    let next_id = {
      let assert [row] = next.rows
      row.id
    }
    assert first_id != next_id
  })
}
