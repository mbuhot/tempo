//// Layer-3 HTTP API tests (ARCHITECTURE.md §2/§5, PRD FR-1/FR-7) for the Wisp
//// router. They drive the real handlers through `wisp/simulate` against the
//// deterministic v1-wide seed ("now" = 2026-06-15), parse the JSON response back
//// through the shared codecs, and assert the exact decoded values — proving the
//// full Squirrel-row -> shared-type -> JSON path end to end.
////
//// Read paths (board, timesheet form) only query the seed. The write path
//// commits, so the success test deletes the row it created afterwards to leave
//// the seed pristine; the rejection test relies on the PERIOD FK rolling its own
//// transaction back, so it mutates nothing.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/json
import gleam/list
import gleam/time/calendar
import pog
import shared/codecs
import shared/types.{
  type BoardSnapshot, type TimesheetDay, BoardRow, BoardSnapshot, OnLeave,
  OnProject, TimesheetDay, TimesheetLine,
}
import tempo/server/context.{type Context, Context}
import tempo/server/web/router
import wisp/simulate

// --- context ----------------------------------------------------------------

/// A single-connection context per test, mirroring the sql_test pool sizing so
/// the suite does not exhaust PG's max_connections under the concurrent runner.
fn ctx() -> Context {
  let pool_name = process.new_name(prefix: "tempo_api_test_db")
  let config =
    context.pool_config(context.settings_from_env(), pool_name)
    |> pog.pool_size(1)
  let assert Ok(started) = pog.start(config)
  Context(db: started.data)
}

// --- GET /api/board ---------------------------------------------------------

// As of the seed "now" the board has Marcus on Data Platform, Priya on her two
// half-time projects, and Aisha suppressed to "On leave" — exactly the shared
// BoardSnapshot the client renders, decoded back from the JSON the handler sent.
pub fn board_as_of_now_returns_snapshot_test() {
  let response =
    simulate.request(http.Get, "/api/board?as_of=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 200

  let snapshot = decode_board(response)

  assert snapshot
    == BoardSnapshot(as_of: calendar.Date(2026, calendar.June, 15), rows: [
      BoardRow(
        engineer: "Aisha Okafor",
        level: 6,
        engagement: OnLeave(
          kind: "annual",
          valid_from: calendar.Date(2026, calendar.June, 8),
          valid_to: calendar.Date(2026, calendar.June, 22),
        ),
      ),
      BoardRow(
        engineer: "Marcus Chen",
        level: 4,
        engagement: OnProject(
          project: "Data Platform",
          client: "Globex Corporation",
          fraction: 1.0,
          day_rate: 1000.0,
          valid_from: calendar.Date(2025, calendar.January, 1),
          valid_to: calendar.Date(2027, calendar.January, 1),
        ),
      ),
      BoardRow(
        engineer: "Priya Sharma",
        level: 5,
        engagement: OnProject(
          project: "Inventory Sync",
          client: "Northwind Trading",
          fraction: 0.5,
          day_rate: 1200.0,
          valid_from: calendar.Date(2025, calendar.June, 1),
          valid_to: calendar.Date(2027, calendar.January, 1),
        ),
      ),
      BoardRow(
        engineer: "Priya Sharma",
        level: 5,
        engagement: OnProject(
          project: "Ledger Migration",
          client: "Northwind Trading",
          fraction: 0.5,
          day_rate: 1200.0,
          valid_from: calendar.Date(2024, calendar.January, 1),
          valid_to: calendar.Date(2027, calendar.January, 1),
        ),
      ),
    ])
}

// A missing as_of is a 400, not a crash or a 500.
pub fn board_without_as_of_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/board")
    |> router.handle_request(ctx())

  assert response.status == 400
}

// A malformed as_of is a 400.
pub fn board_with_bad_as_of_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/board?as_of=not-a-date")
    |> router.handle_request(ctx())

  assert response.status == 400
}

// --- GET /api/timesheet -----------------------------------------------------

// Priya (id 1) on Tuesday 2026-06-09: her two half-time projects, each with the
// 4.00 hours the seed logged that day, returned as the shared TimesheetDay.
pub fn timesheet_read_returns_day_test() {
  let response =
    simulate.request(http.Get, "/api/timesheet?engineer=1&day=2026-06-09")
    |> router.handle_request(ctx())

  assert response.status == 200

  let day = decode_timesheet(response)

  assert day
    == TimesheetDay(
      engineer_id: 1,
      as_of: calendar.Date(2026, calendar.June, 9),
      lines: [
        TimesheetLine(
          project_id: 200,
          project: "Inventory Sync",
          fraction: 0.5,
          hours: 4.0,
          valid_from: calendar.Date(2025, calendar.June, 1),
          valid_to: calendar.Date(2027, calendar.January, 1),
        ),
        TimesheetLine(
          project_id: 100,
          project: "Ledger Migration",
          fraction: 0.5,
          hours: 4.0,
          valid_from: calendar.Date(2024, calendar.January, 1),
          valid_to: calendar.Date(2027, calendar.January, 1),
        ),
      ],
    )
}

// Aisha (id 3) is on leave on the seed "now", so the form offers nothing.
pub fn timesheet_read_on_leave_is_empty_test() {
  let response =
    simulate.request(http.Get, "/api/timesheet?engineer=3&day=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 200
  assert decode_timesheet(response).lines == []
}

// A missing engineer param is a 400.
pub fn timesheet_read_without_engineer_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/timesheet?day=2026-06-09")
    |> router.handle_request(ctx())

  assert response.status == 400
}

// --- POST /api/timesheet ----------------------------------------------------

// Logging hours against a project the engineer is NOT allocated to that day is
// rejected by the timesheet PERIOD FK and surfaced as a clean 422 with a typed
// error body — never a 500. Marcus (id 2) is on project 300, not 100.
pub fn timesheet_write_without_allocation_is_unprocessable_test() {
  let response =
    simulate.request(http.Post, "/api/timesheet")
    |> simulate.json_body(
      json.object([
        #("engineer_id", json.int(2)),
        #("project_id", json.int(100)),
        #("day", json.string("2026-06-10")),
        #("hours", json.float(8.0)),
      ]),
    )
    |> router.handle_request(ctx())

  assert response.status == 422
  assert decode_error_code(response) == "not_allocated"
}

// A malformed JSON body is a 400, not a 500.
pub fn timesheet_write_bad_body_is_bad_request_test() {
  let response =
    simulate.request(http.Post, "/api/timesheet")
    |> simulate.json_body(json.object([#("engineer_id", json.int(2))]))
    |> router.handle_request(ctx())

  assert response.status == 400
}

// A valid write (Marcus id 2 on project 300, a day covered by his allocation)
// succeeds and the refreshed form reflects the logged hours. The row is deleted
// afterwards so the shared seed is left untouched.
pub fn timesheet_write_logs_hours_test() {
  let context = ctx()
  let response =
    simulate.request(http.Post, "/api/timesheet")
    |> simulate.json_body(
      json.object([
        #("engineer_id", json.int(2)),
        #("project_id", json.int(300)),
        #("day", json.string("2026-06-10")),
        #("hours", json.float(7.5)),
      ]),
    )
    |> router.handle_request(context)

  assert response.status == 200

  let logged =
    decode_timesheet(response).lines
    |> list.filter(fn(line) { line.project_id == 300 })
    |> list.map(fn(line) { line.hours })

  // Restore the seed regardless of the assertion outcome.
  delete_timesheet(context, 2, 300, calendar.Date(2026, calendar.June, 10))

  assert logged == [7.5]
}

// --- static / fallthrough ---------------------------------------------------

// An unknown path is a 404 (the static fallthrough finds no file).
pub fn unknown_path_is_not_found_test() {
  let response =
    simulate.request(http.Get, "/no/such/route")
    |> router.handle_request(ctx())

  assert response.status == 404
}

// --- helpers ----------------------------------------------------------------

fn decode_board(response) -> BoardSnapshot {
  let assert Ok(snapshot) =
    simulate.read_body(response)
    |> json.parse(codecs.board_snapshot_decoder())
  snapshot
}

fn decode_timesheet(response) -> TimesheetDay {
  let assert Ok(day) =
    simulate.read_body(response)
    |> json.parse(codecs.timesheet_day_decoder())
  day
}

fn decode_error_code(response) -> String {
  let decoder = {
    use code <- decode.field("error", decode.string)
    decode.success(code)
  }
  let assert Ok(code) =
    simulate.read_body(response)
    |> json.parse(decoder)
  code
}

/// Remove a single timesheet row created by a write test, restoring the seed.
fn delete_timesheet(
  context: Context,
  engineer_id: Int,
  project_id: Int,
  day: calendar.Date,
) -> Nil {
  let assert Ok(_) =
    pog.query(
      "DELETE FROM timesheet WHERE engineer_id = $1 AND project_id = $2 "
      <> "AND work_day @> $3::date",
    )
    |> pog.parameter(pog.int(engineer_id))
    |> pog.parameter(pog.int(project_id))
    |> pog.parameter(pog.calendar_date(day))
    |> pog.execute(on: context.db)
  Nil
}
