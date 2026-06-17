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
import gleam/int
import gleam/json
import gleam/list
import gleam/time/calendar
import pog
import shared/codecs
import shared/types.{
  type BoardSnapshot, type Event, type TimesheetDay, BoardRow, BoardSnapshot,
  OnLeave, OnProject, Promote, TimesheetDay, TimesheetLine,
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

// On the seed "now" the board has Marcus on Data Platform, Priya on her two
// half-time projects, and Aisha suppressed to "On leave" — exactly the shared
// BoardSnapshot the client renders, decoded back from the JSON the handler sent.
pub fn board_now_returns_snapshot_test() {
  let response =
    simulate.request(http.Get, "/api/board?date=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 200

  let snapshot = decode_board(response)

  assert snapshot
    == BoardSnapshot(date: calendar.Date(2026, calendar.June, 15), rows: [
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

// A missing date is a 400, not a crash or a 500.
pub fn board_without_date_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/board")
    |> router.handle_request(ctx())

  assert response.status == 400
}

// A malformed date is a 400.
pub fn board_with_bad_date_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/board?date=not-a-date")
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
      date: calendar.Date(2026, calendar.June, 9),
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

// --- POST /api/operations ---------------------------------------------------

// A successful operation returns 200 with the newly-created event as JSON (the
// operation tag, summary, and re-encoded payload), and the journal really grew
// by that row. Promote Marcus (id 2) to L6 effective 2026-09-01: the FOR PORTION
// OF change commits, so the role split and the appended event_log row are both
// undone afterwards to leave the shared seed pristine.
pub fn operation_promote_returns_created_event_test() {
  let context = ctx()
  let before = event_count(context)

  let response =
    simulate.request(http.Post, "/api/operations")
    |> simulate.json_body(
      codecs.encode_operation_request(types.OperationRequest(
        actor: "mike@alembic.com.au",
        command: Promote(
          engineer_id: 2,
          level: 6,
          effective: calendar.Date(2026, calendar.September, 1),
        ),
      )),
    )
    |> router.handle_request(context)

  let status = response.status
  let event = decode_event(response)
  let after = event_count(context)

  // Restore the seed regardless of the assertion outcome: undo the role split
  // and drop the appended journal row.
  restore_engineer_2_roles(context)
  delete_event(context, event.id)

  assert status == 200
  assert event.operation == "promote"
  assert event.actor == "mike@alembic.com.au"
  assert event.summary == "Promote engineer 2 to L6 from 2026-09-01"
  assert event.payload
    == "{\"op\": \"promote\", \"level\": 6, \"effective\": \"2026-09-01\", \"engineer_id\": 2}"
  assert after == before + 1
}

// A rejected operation maps by its typed OperationError. Logging hours for
// Marcus (id 2) against project 100 — which he is NOT allocated to — fires the
// timesheet PERIOD FK (a containment violation), so the dispatch transaction
// rolls back and the handler returns a 409 with the containment error code. The
// rollback means the seed is untouched.
pub fn operation_containment_violation_is_conflict_test() {
  let context = ctx()
  let before = event_count(context)

  let response =
    simulate.request(http.Post, "/api/operations")
    |> simulate.json_body(
      codecs.encode_operation_request(types.OperationRequest(
        actor: "mike@alembic.com.au",
        command: types.LogTimesheet(
          engineer_id: 2,
          project_id: 100,
          day: calendar.Date(2026, calendar.June, 10),
          hours: 8.0,
        ),
      )),
    )
    |> router.handle_request(context)

  assert response.status == 409
  assert decode_error_code(response) == "containment_violated"
  // The whole dispatch transaction rolled back: no journal row was appended.
  assert event_count(context) == before
}

// A malformed body is a 400, not a 500.
pub fn operation_bad_body_is_bad_request_test() {
  let response =
    simulate.request(http.Post, "/api/operations")
    |> simulate.json_body(json.object([#("actor", json.string("nobody"))]))
    |> router.handle_request(ctx())

  assert response.status == 400
}

// --- GET /api/events --------------------------------------------------------

// GET /api/events returns the journal newest-first as a JSON array of Events.
// The hand-written seed leaves the journal empty, so this test first applies an
// operation (a Promote) to put one known row in the feed, then asserts the feed
// returns it; the role split and the journal row are undone afterwards so the
// shared seed is left pristine.
pub fn events_returns_journal_test() {
  let context = ctx()

  let post =
    simulate.request(http.Post, "/api/operations")
    |> simulate.json_body(
      codecs.encode_operation_request(types.OperationRequest(
        actor: "mike@alembic.com.au",
        command: Promote(
          engineer_id: 2,
          level: 6,
          effective: calendar.Date(2026, calendar.September, 1),
        ),
      )),
    )
    |> router.handle_request(context)
  let created = decode_event(post)

  let response =
    simulate.request(http.Get, "/api/events")
    |> router.handle_request(context)
  let status = response.status
  let events = decode_events(response)

  // Restore the seed regardless of the assertion outcome.
  restore_engineer_2_roles(context)
  delete_event(context, created.id)

  assert status == 200
  // The feed comes back newest-first (id DESC) and carries the event just
  // appended at its head.
  assert ids_descending(events)
  let assert [newest, ..] = events
  assert newest == created
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

fn decode_event(response) -> Event {
  let assert Ok(event) =
    simulate.read_body(response)
    |> json.parse(codecs.event_decoder())
  event
}

fn decode_events(response) -> List(Event) {
  let assert Ok(events) =
    simulate.read_body(response)
    |> json.parse(decode.list(codecs.event_decoder()))
  events
}

/// True when the events are in strictly descending id order (newest-first).
fn ids_descending(events: List(Event)) -> Bool {
  let ids = list.map(events, fn(event) { event.id })
  ids == list.sort(ids, by: fn(a, b) { int.compare(b, a) })
}

/// Count the journal rows directly, so a test can assert the feed grew (or did
/// not) by exactly one across an operation.
fn event_count(context: Context) -> Int {
  let row_decoder = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  let assert Ok(returned) =
    pog.query("SELECT count(*)::int FROM event_log")
    |> pog.returning(row_decoder)
    |> pog.execute(on: context.db)
  let assert [count, ..] = returned.rows
  count
}

/// Delete a single journal row by id, undoing the event a write test appended.
fn delete_event(context: Context, id: Int) -> Nil {
  let assert Ok(_) =
    pog.query("DELETE FROM event_log WHERE id = $1")
    |> pog.parameter(pog.int(id))
    |> pog.execute(on: context.db)
  Nil
}

/// Restore engineer 2's (Marcus) role timeline to the seed state after a Promote
/// test split it: delete every role row for him and re-insert the two seed rows
/// (L4 before the promotion, L5 after), so the shared seed is left untouched.
fn restore_engineer_2_roles(context: Context) -> Nil {
  let assert Ok(_) =
    pog.query("DELETE FROM engineer_role WHERE engineer_id = 2")
    |> pog.execute(on: context.db)
  let assert Ok(_) =
    pog.query(
      "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES "
      <> "(2, 4, daterange('2024-06-01', '2026-07-01')), "
      <> "(2, 5, daterange('2026-07-01', '2027-01-01'))",
    )
    |> pog.execute(on: context.db)
  Nil
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
