//// Layer-2 tests for the Activity journal generic-table read (`event/table`).
//// Insert a small fixture of `event_log` rows whose operation carries a distinctive
//// "ztest." prefix — a prefix NO seeded operation uses — so every data assertion
//// scopes to those operations (the operation filter) and isolates the fixture's rows
//// from the shared dev DB's seeded journal. Each test runs in its OWN transaction and
//// rolls back, so the base seed the read-only tests rely on is never mutated.

import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/string
import pog
import shared/table/cell.{PersonCell, TextCell}
import shared/table/column.{StandaloneFilter}
import shared/table/filter.{DateRangeFilter, SelectFilter}
import shared/table/query.{
  type Applied, type FilterValue, Applied, DateRange, SelectValue,
}
import shared/table/response.{type Row}
import tempo/server/context.{type Context, Context}
import tempo/server/event/table as event_table
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

fn applied(filters: List(#(String, FilterValue))) -> Applied {
  Applied(
    filters: dict.from_list(filters),
    sort: None,
    page_size: 100,
    cursor: None,
  )
}

/// Scope every data assertion to the fixture's distinctive operations so the shared
/// dev DB's seeded journal never leaks into the count/order assertions.
fn scoped(filters: List(#(String, FilterValue))) -> Applied {
  applied([
    #("operation", SelectValue(["ztest.created", "ztest.updated"])),
    ..filters
  ])
}

fn cell_of(row: Row, key: String) -> cell.Cell {
  let assert Ok(value) = dict.get(row.cells, key)
  value
}

// --- fixture ----------------------------------------------------------------

/// Three fixture journal rows: two by Ada (a create then an update), one by Grace (a
/// create), each recorded on a distinct day in June 2026 with a JSON payload.
fn fixture(conn: pog.Connection) -> Nil {
  insert_event(
    conn,
    "2026-06-10 09:00:00",
    "Ada Test",
    "ztest.created",
    "created widget 1",
    "{\"id\":1,\"name\":\"one\"}",
  )
  insert_event(
    conn,
    "2026-06-12 11:30:00",
    "Grace Test",
    "ztest.created",
    "created widget 2",
    "{\"id\":2,\"name\":\"two\"}",
  )
  insert_event(
    conn,
    "2026-06-15 14:45:00",
    "Ada Test",
    "ztest.updated",
    "updated widget 1",
    "{\"id\":1,\"name\":\"ONE\"}",
  )
}

fn insert_event(
  conn: pog.Connection,
  occurred_at: String,
  actor: String,
  operation: String,
  summary: String,
  payload: String,
) -> Nil {
  exec(
    conn,
    "INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES ("
      <> "'"
      <> occurred_at
      <> "', '"
      <> actor
      <> "', '"
      <> operation
      <> "', '"
      <> summary
      <> "', '"
      <> payload
      <> "'::jsonb)",
  )
}

// --- tests ------------------------------------------------------------------

pub fn schema_advertises_three_columns_and_schema_level_filters_test() {
  rolling_back(fn(conn) {
    let assert Ok(response) = event_table.events_table(ctx(conn), applied([]))
    assert response.schema.table_id == "events"
    let keys = list.map(response.schema.columns, fn(column) { column.key })
    assert keys == ["when", "actor", "event"]

    let filter_keys =
      list.map(response.schema.filters, fn(standalone) { standalone.key })
    assert filter_keys == ["operation", "actor", "occurred"]

    let assert Ok(occurred) =
      list.find(response.schema.filters, fn(standalone) {
        standalone.key == "occurred"
      })
    let assert StandaloneFilter(kind: DateRangeFilter(..), ..) = occurred

    let assert Ok(operation) =
      list.find(response.schema.filters, fn(standalone) {
        standalone.key == "operation"
      })
    let assert StandaloneFilter(kind: SelectFilter(..), ..) = operation
  })
}

pub fn live_options_include_fixture_operations_and_actors_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) = event_table.events_table(ctx(conn), applied([]))
    let assert Ok(operation) =
      list.find(response.schema.filters, fn(standalone) {
        standalone.key == "operation"
      })
    let assert StandaloneFilter(kind: SelectFilter(options:, ..), ..) =
      operation
    let values = list.map(options, fn(option) { option.value })
    assert list.contains(values, "ztest.created")
    assert list.contains(values, "ztest.updated")

    let assert Ok(actor) =
      list.find(response.schema.filters, fn(standalone) {
        standalone.key == "actor"
      })
    let assert StandaloneFilter(kind: SelectFilter(options:, ..), ..) = actor
    let actors = list.map(options, fn(option) { option.value })
    assert list.contains(actors, "Ada Test")
    assert list.contains(actors, "Grace Test")
  })
}

pub fn rows_carry_payload_detail_and_typed_cells_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) = event_table.events_table(ctx(conn), scoped([]))
    assert list.length(response.rows) == 3

    let assert [newest, ..] = response.rows
    let assert TextCell(when) = cell_of(newest, "when")
    assert string.starts_with(when, "2026-06-15")
    let assert PersonCell(name:, ..) = cell_of(newest, "actor")
    assert name == "Ada Test"
    let assert TextCell(event) = cell_of(newest, "event")
    assert event == "ztest.updated · updated widget 1"

    let assert option.Some(detail) = newest.detail
    assert string.contains(detail, "\"name\"")
    assert string.contains(detail, "ONE")
    assert string.contains(detail, "\n")
  })
}

pub fn newest_first_by_descending_id_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) = event_table.events_table(ctx(conn), scoped([]))
    let summaries =
      list.map(response.rows, fn(row) {
        let assert TextCell(event) = cell_of(row, "event")
        event
      })
    assert summaries
      == [
        "ztest.updated · updated widget 1",
        "ztest.created · created widget 2",
        "ztest.created · created widget 1",
      ]
  })
}

pub fn operation_filter_narrows_rows_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      event_table.events_table(
        ctx(conn),
        applied([#("operation", SelectValue(["ztest.updated"]))]),
      )
    assert list.length(response.rows) == 1
    let assert [only] = response.rows
    let assert TextCell(event) = cell_of(only, "event")
    assert event == "ztest.updated · updated widget 1"
  })
}

pub fn actor_filter_narrows_rows_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      event_table.events_table(
        ctx(conn),
        scoped([#("actor", SelectValue(["Grace Test"]))]),
      )
    assert list.length(response.rows) == 1
    let assert [only] = response.rows
    let assert PersonCell(name:, ..) = cell_of(only, "actor")
    assert name == "Grace Test"
  })
}

pub fn occurred_date_range_filter_narrows_rows_test() {
  rolling_back(fn(conn) {
    fixture(conn)
    let assert Ok(response) =
      event_table.events_table(
        ctx(conn),
        scoped([
          #(
            "occurred",
            DateRange(
              from: option.Some("2026-06-13"),
              to: option.Some("2026-06-30"),
            ),
          ),
        ]),
      )
    assert list.length(response.rows) == 1
    let assert [only] = response.rows
    let assert TextCell(when) = cell_of(only, "when")
    assert string.starts_with(when, "2026-06-15")
  })
}
