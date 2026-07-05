//// Layer-2 tests for the people-roster generic-table read (`people/table`). Insert
//// a small fixture of employed engineers at level 1 — a level NO engineer in the
//// base seed holds as of the test date — so every data assertion can scope to
//// `level=1` and isolate the fixture's rows from the shared dev DB's seeded roster.
//// Each test runs in its OWN transaction and rolls back, so the base seed the
//// read-only tests rely on is never mutated.

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/time/calendar.{type Date, Date, June}
import pog
import shared/access
import shared/table/cell.{
  EntityCell, EnumCell, MoneyCell, PercentCell, PersonCell,
}
import shared/table/column
import shared/table/query.{
  type Applied, type FilterValue, Applied, NumberRange, SelectValue,
}
import shared/table/response.{type Row}
import shared/table/sort.{type Sort, Asc, Desc, Sort}
import shared/workflow/kind.{OnboardEngineer}
import tempo/server/auth.{Principal}
import tempo/server/context.{type Context, Context}
import tempo/server/people/table as people_table
import tempo/server/workflow/instance
import tempo/server/workflow/schema as flow
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

/// A context whose viewer is `account_id`, holding `permissions` — for the draft-
/// prepend scoping tests, which read `context.principal` to scope visible drafts.
fn viewer_ctx(
  conn: pog.Connection,
  account_id: Int,
  permissions: List(String),
) -> Context {
  Context(
    db: conn,
    principal: Some(Principal(
      account_id:,
      actor: "Tester",
      engineer_id: None,
      permissions: set.from_list(permissions),
    )),
  )
}

/// Two distinct existing account ids, for a draft owner and another viewer.
fn two_account_ids(conn: pog.Connection) -> #(Int, Int) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("SELECT id FROM account ORDER BY id LIMIT 2")
    |> pog.returning(decoder)
    |> pog.execute(conn)
  let assert [owner, other] = returned.rows
  #(owner, other)
}

fn row_ids(rows: List(Row)) -> List(String) {
  list.map(rows, fn(row) { row.id })
}

fn applied(
  filters: List(#(String, FilterValue)),
  sort: option.Option(Sort),
) -> Applied {
  Applied(filters: dict.from_list(filters), sort:, page_size: 50, cursor: None)
}

/// Scope every data assertion to the fixture's distinctive level so the shared dev
/// DB's seeded roster never leaks into the count/order assertions.
fn scoped(
  filters: List(#(String, FilterValue)),
  sort: option.Option(Sort),
) -> Applied {
  applied([#("level", SelectValue(["1"])), ..filters], sort)
}

fn cell_of(row: Row, key: String) -> cell.Cell {
  let assert Ok(value) = dict.get(row.cells, key)
  value
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

/// Employ one engineer at level 1, with the given allocation fraction to a fresh
/// project ("0" leaves them unassigned). Returns the engineer id.
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

/// Two employed engineers at level 1 (whose seed rate card already exists): Ada
/// (allocated 1.00) and Babbage (bench, no allocation). Both sort by name: Ada, then
/// Babbage.
fn fixture(conn: pog.Connection) -> Nil {
  let _ = employ(conn, "Ada Lovelace", "ada@tempo.test", 90_201, "1.00")
  let _ = employ(conn, "Babbage Charles", "babbage@tempo.test", 90_202, "0")
  Nil
}

fn as_of() -> Date {
  Date(2026, June, 15)
}

// --- tests ------------------------------------------------------------------

pub fn schema_advertises_people_columns_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      people_table.people_table(ctx(conn), as_of(), applied([], None))
    assert response.schema.table_id == "people"
    let keys = list.map(response.schema.columns, fn(column) { column.key })
    assert keys
      == ["name", "level", "status", "allocated", "annual_leave", "day_rate"]
    assert response.schema.default_sort == Some(Sort(key: "name", dir: Asc))
  })
}

pub fn unfiltered_returns_both_engineers_with_rich_cells_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      people_table.people_table(ctx(conn), as_of(), scoped([], None))
    assert list.length(response.rows) == 2
    let assert [first, ..] = response.rows
    let assert PersonCell(name:, sub:, ..) = cell_of(first, "name")
    assert name == "Ada Lovelace"
    assert sub == Some("ada@tempo.test")
    let assert EntityCell(label:, ..) = cell_of(first, "level")
    assert label == "L1 · Associate"
    assert cell_of(first, "status")
      == EnumCell(label: "On projects", tone: column.Positive)
    let assert MoneyCell(rate) = cell_of(first, "day_rate")
    let assert PercentCell(allocated) = cell_of(first, "allocated")
    assert allocated == 100.0
    let _ = rate
  })
}

pub fn default_sort_is_name_ascending_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      people_table.people_table(ctx(conn), as_of(), scoped([], None))
    let names =
      list.map(response.rows, fn(row) {
        let assert PersonCell(name:, ..) = cell_of(row, "name")
        name
      })
    assert names == ["Ada Lovelace", "Babbage Charles"]
  })
}

pub fn name_sort_descending_reverses_order_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      people_table.people_table(
        ctx(conn),
        as_of(),
        scoped([], Some(Sort(key: "name", dir: Desc))),
      )
    let names =
      list.map(response.rows, fn(row) {
        let assert PersonCell(name:, ..) = cell_of(row, "name")
        name
      })
    assert names == ["Babbage Charles", "Ada Lovelace"]
  })
}

pub fn status_filter_keeps_only_unassigned_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      people_table.people_table(
        ctx(conn),
        as_of(),
        scoped([#("status", SelectValue(["unassigned"]))], None),
      )
    assert list.length(response.rows) == 1
    let assert [row] = response.rows
    let assert PersonCell(name:, ..) = cell_of(row, "name")
    assert name == "Babbage Charles"
    assert cell_of(row, "status")
      == EnumCell(label: "Unassigned", tone: column.Neutral)
  })
}

pub fn allocated_range_filter_keeps_only_in_band_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      people_table.people_table(
        ctx(conn),
        as_of(),
        scoped([#("allocated", NumberRange(min: Some("0.5"), max: None))], None),
      )
    assert list.length(response.rows) == 1
    let assert [row] = response.rows
    let assert PersonCell(name:, ..) = cell_of(row, "name")
    assert name == "Ada Lovelace"
  })
}

/// Security (issue #32): a draft prepended into the roster is scoped to its owner —
/// the owner sees their in-progress onboarding draft, another viewer does not.
pub fn own_onboarding_draft_is_hidden_from_other_viewers_test() {
  rolling_back(fn(conn) {
    let #(owner, other) = two_account_ids(conn)
    let assert Ok(draft_id) =
      instance.start(conn, OnboardEngineer, owner, flow.first_step)

    let assert Ok(for_owner) =
      people_table.people_table(
        viewer_ctx(conn, owner, []),
        as_of(),
        applied([], None),
      )
    assert list.contains(row_ids(for_owner.rows), draft_id) == True

    let assert Ok(for_other) =
      people_table.people_table(
        viewer_ctx(conn, other, []),
        as_of(),
        applied([], None),
      )
    assert list.contains(row_ids(for_other.rows), draft_id) == False
  })
}

/// Security (issue #32): once a draft is awaiting Finance it joins the shared queue —
/// visible to a viewer holding the onboarding commit permission, hidden from one who
/// neither owns it nor can commit.
pub fn awaiting_finance_draft_is_visible_only_to_committers_test() {
  rolling_back(fn(conn) {
    let #(owner, other) = two_account_ids(conn)
    let assert Ok(draft_id) =
      instance.start(conn, OnboardEngineer, owner, flow.first_step)
    let assert Ok(_) = instance.hand_off(conn, draft_id, "payroll")

    let committer = viewer_ctx(conn, other, [access.engineer_onboard_commit])
    let assert Ok(for_committer) =
      people_table.people_table(committer, as_of(), applied([], None))
    assert list.contains(row_ids(for_committer.rows), draft_id) == True

    let assert Ok(for_other) =
      people_table.people_table(
        viewer_ctx(conn, other, []),
        as_of(),
        applied([], None),
      )
    assert list.contains(row_ids(for_other.rows), draft_id) == False
  })
}
