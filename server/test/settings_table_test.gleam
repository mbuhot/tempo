//// Layer-2 tests for the settings generic-table reads (`settings/table`): the
//// rate-card & salary-bands table (with its server-advertised per-row actions) and
//// the read-only leave-policy table. These read the base seed's rate card / salary
//// bands / leave policy as-of a fixed date, so each test asserts only on structure
//// that the seed guarantees (schema columns, the actions cell, a non-empty page).
//// Each test runs in its own transaction and rolls back.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/time/calendar.{type Date, Date, June}
import pog
import shared/access
import shared/table/cell.{Action, ActionsCell, EnumCell, MoneyCell}
import shared/table/column.{ActionsType}
import shared/table/response.{type Row}
import tempo/server/auth.{Principal}
import tempo/server/context.{type Context, Context}
import tempo/server/settings/table as settings_table
import test_pool

// --- harness ----------------------------------------------------------------

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

/// A context with an Admin principal holding every permission, so the rate-card
/// table advertises both per-row actions.
fn admin_ctx(conn: pog.Connection) -> Context {
  Context(
    db: conn,
    principal: Some(Principal(
      account_id: 0,
      actor: "Admin",
      engineer_id: None,
      permissions: set.from_list(access.all()),
    )),
  )
}

/// A context with no principal — an unauthenticated reader sees no actions.
fn anon_ctx(conn: pog.Connection) -> Context {
  Context(db: conn, principal: None)
}

fn cell_of(row: Row, key: String) -> cell.Cell {
  let assert Ok(value) = dict.get(row.cells, key)
  value
}

fn as_of() -> Date {
  Date(2026, June, 15)
}

// --- rate-card table --------------------------------------------------------

pub fn rate_card_schema_advertises_columns_including_actions_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      settings_table.rate_card_table(admin_ctx(conn), as_of())
    assert response.schema.table_id == "settings_rate_card"
    let keys = list.map(response.schema.columns, fn(column) { column.key })
    assert keys == ["level", "day_rate", "monthly_salary", "actions"]
    let assert Ok(actions_column) =
      list.find(response.schema.columns, fn(column) { column.key == "actions" })
    assert actions_column.column_type == ActionsType
    assert actions_column.sortable == False
    assert actions_column.filter == None
  })
}

pub fn rate_card_rows_carry_rich_cells_and_actions_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      settings_table.rate_card_table(admin_ctx(conn), as_of())
    let assert [first, ..] = response.rows
    let assert EnumCell(label:, ..) = cell_of(first, "level")
    assert label == "L1 · Associate"
    let assert MoneyCell(_) = cell_of(first, "day_rate")
    let assert MoneyCell(_) = cell_of(first, "monthly_salary")
    assert cell_of(first, "actions")
      == ActionsCell([
        Action(id: "revise_rate", label: "Revise"),
        Action(id: "set_salary", label: "Set salary"),
      ])
  })
}

pub fn rate_card_actions_empty_for_unauthenticated_reader_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      settings_table.rate_card_table(anon_ctx(conn), as_of())
    let assert [first, ..] = response.rows
    assert cell_of(first, "actions") == ActionsCell([])
  })
}

pub fn rate_card_row_id_is_the_level_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      settings_table.rate_card_table(admin_ctx(conn), as_of())
    let assert [first, ..] = response.rows
    assert first.id == "1"
  })
}

// --- leave-policy table -----------------------------------------------------

pub fn leave_policy_schema_advertises_columns_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) =
      settings_table.leave_policy_table(admin_ctx(conn), as_of())
    assert response.schema.table_id == "settings_leave_policy"
    let keys = list.map(response.schema.columns, fn(column) { column.key })
    assert keys == ["kind", "level", "days_per_year"]
  })
}
