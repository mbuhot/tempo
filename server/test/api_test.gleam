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
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/time/calendar
import pog
import shared/codecs
import shared/types.{
  type BoardSnapshot, type ClientDetail, type ClientList, type EngineerDetail,
  type Event, type PeopleList, type ProjectDetail, type ProjectList,
  type Settings, type TimesheetWeek, BoardRow, OnLeave, OnProject, Promote,
  RosterOnProjects, TimesheetCell, TimesheetWeek, TimesheetWeekRow,
}
import tempo/server/context.{type Context}
import tempo/server/event
import tempo/server/web/router
import test_pool
import wisp/simulate

// --- context ----------------------------------------------------------------

/// A `Context` over the suite's shared pool.
fn ctx() -> Context {
  test_pool.ctx()
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

  assert snapshot.date == calendar.Date(2026, calendar.June, 15)
  assert snapshot.rows
    == [
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
    ]
  // Each employed engineer carries a leave balance as of the date (exact values
  // are asserted at clean dates in leave_test); the board is name-ordered.
  assert list.map(snapshot.balances, fn(balance) { balance.engineer })
    == ["Aisha Okafor", "Marcus Chen", "Priya Sharma"]
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

// Priya (id 1), week of Monday 2026-06-08: the weekly grid carries her two
// half-time projects as rows (Inventory Sync then Ledger Migration, by name),
// each seven cells Mon 06-08 .. Sun 06-14, all allocated, with the 4.00 hours
// the seed logged on the Tuesday 06-09 cell of both. Returned as the shared
// TimesheetWeek the client renders.
pub fn timesheet_read_returns_week_test() {
  let response =
    simulate.request(http.Get, "/api/timesheet?engineer=1&week=2026-06-08")
    |> router.handle_request(ctx())

  assert response.status == 200

  let week = decode_timesheet(response)

  // The seven Mon..Sun column dates the grid renders.
  let days = [
    calendar.Date(2026, calendar.June, 8),
    calendar.Date(2026, calendar.June, 9),
    calendar.Date(2026, calendar.June, 10),
    calendar.Date(2026, calendar.June, 11),
    calendar.Date(2026, calendar.June, 12),
    calendar.Date(2026, calendar.June, 13),
    calendar.Date(2026, calendar.June, 14),
  ]
  // Every day allocated, 4.0 only on the Tuesday 06-09 cell.
  let cells =
    list.map(days, fn(day) {
      let hours = case day == calendar.Date(2026, calendar.June, 9) {
        True -> 4.0
        False -> 0.0
      }
      TimesheetCell(date: day, allocated: True, hours:)
    })

  assert week
    == TimesheetWeek(
      engineer_id: 1,
      week_start: calendar.Date(2026, calendar.June, 8),
      days:,
      rows: [
        TimesheetWeekRow(project_id: 200, project: "Inventory Sync", cells:),
        TimesheetWeekRow(project_id: 100, project: "Ledger Migration", cells:),
      ],
    )
}

// Aisha (id 3), week of Monday 2026-06-15: her leave covers the whole week. Leave
// takes precedence over her Data Platform allocation, so she has no loggable day —
// `form_week` drops a project with no loggable day, leaving an empty grid the client
// renders as "nothing to log this week".
pub fn timesheet_read_on_leave_has_no_rows_test() {
  let response =
    simulate.request(http.Get, "/api/timesheet?engineer=3&week=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 200

  let week = decode_timesheet(response)
  assert week.rows == []
  assert week.days == []
}

// A missing week param is a 400.
pub fn timesheet_read_without_week_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/timesheet?engineer=1")
    |> router.handle_request(ctx())

  assert response.status == 400
}

// --- LogTimesheet via POST /api/operations ----------------------------------

// Logging hours now goes through the unified operations write path: a
// LogTimesheet command posted to /api/operations. A valid write (Marcus id 2 on
// project 300, a day covered by his allocation) commits and returns the created
// log_timesheet event; re-reading the form for that engineer/day reflects the
// logged hours. The timesheet row and the appended journal row are removed
// afterwards so the shared seed is left untouched.
pub fn log_timesheet_operation_logs_hours_test() {
  let context = ctx()

  let response =
    simulate.request(http.Post, "/api/operations")
    |> simulate.json_body(
      codecs.encode_operation_request(types.OperationRequest(
        actor: "mike@alembic.com.au",
        command: types.LogTimesheet(
          engineer_id: 2,
          project_id: 300,
          day: calendar.Date(2026, calendar.June, 10),
          hours: 7.5,
        ),
      )),
    )
    |> router.handle_request(context)

  let status = response.status
  let assert [event] = decode_events(response)

  // Re-read the week for that engineer; the logged hours are on the 06-10 cell of
  // the Data Platform (300) row.
  let week =
    simulate.request(http.Get, "/api/timesheet?engineer=2&week=2026-06-08")
    |> router.handle_request(context)
  let logged =
    decode_timesheet(week).rows
    |> list.filter(fn(row) { row.project_id == 300 })
    |> list.flat_map(fn(row) { row.cells })
    |> list.filter(fn(cell) {
      cell.date == calendar.Date(2026, calendar.June, 10)
    })
    |> list.map(fn(cell) { cell.hours })

  // Restore the seed regardless of the assertion outcome: drop the timesheet row
  // and the journal row the operation committed.
  delete_timesheet(context, 2, 300, calendar.Date(2026, calendar.June, 10))
  delete_event(context, event.id)

  assert status == 200
  assert event.operation == "log_timesheet"
  assert logged == [7.5]
}

// --- LogWeek via POST /api/operations ---------------------------------------

// The whole-week atomic write: a LogWeek command setting two (project, day) cells
// for Marcus (id 2) on Data Platform (300) — Monday 06-08 = 5h, Tuesday 06-09 =
// 6h — commits in one transaction and returns a single log_week event. Re-reading
// the week reflects BOTH cells, proving the atomic multi-cell write persists. The
// two timesheet rows and the journal row are removed afterwards.
pub fn log_week_operation_logs_two_cells_test() {
  let context = ctx()

  let response =
    simulate.request(http.Post, "/api/operations")
    |> simulate.json_body(
      codecs.encode_operation_request(types.OperationRequest(
        actor: "mike@alembic.com.au",
        command: types.LogWeek(engineer_id: 2, entries: [
          types.TimesheetEntry(
            project_id: 300,
            day: calendar.Date(2026, calendar.June, 8),
            hours: 5.0,
          ),
          types.TimesheetEntry(
            project_id: 300,
            day: calendar.Date(2026, calendar.June, 9),
            hours: 6.0,
          ),
        ]),
      )),
    )
    |> router.handle_request(context)

  let status = response.status
  let assert [event] = decode_events(response)

  // Re-read the week; both cells of the Data Platform (300) row are on record.
  let week =
    simulate.request(http.Get, "/api/timesheet?engineer=2&week=2026-06-08")
    |> router.handle_request(context)
  let logged =
    decode_timesheet(week).rows
    |> list.filter(fn(row) { row.project_id == 300 })
    |> list.flat_map(fn(row) { row.cells })
    |> list.filter(fn(cell) {
      cell.date == calendar.Date(2026, calendar.June, 8)
      || cell.date == calendar.Date(2026, calendar.June, 9)
    })
    |> list.map(fn(cell) { #(cell.date, cell.hours) })

  // Restore the seed regardless of the assertion outcome.
  delete_timesheet(context, 2, 300, calendar.Date(2026, calendar.June, 8))
  delete_timesheet(context, 2, 300, calendar.Date(2026, calendar.June, 9))
  delete_event(context, event.id)

  assert status == 200
  assert event.operation == "log_week"
  assert logged
    == [
      #(calendar.Date(2026, calendar.June, 8), 5.0),
      #(calendar.Date(2026, calendar.June, 9), 6.0),
    ]
}

// --- POST /api/operations ---------------------------------------------------

// A successful operation returns 200 with the newly-created event(s) as a JSON
// array (the operation tag, summary, and re-encoded payload), and the journal
// really grew by that row. Promote Marcus (id 2) to L6 effective 2026-09-01: the
// FOR PORTION OF change commits, so the role split and the appended event_log row
// are both undone afterwards to leave the shared seed pristine.
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
  // The handler returns the created events as an array; a Promote produces one.
  let assert [event] = decode_events(response)
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

// GET /api/events?from=&to= returns the journal newest-first over a half-open
// `[from, to)` system-time window (occurred_at). The hand-written seed leaves the
// journal empty, so this applies a Promote and backdates its journal row to a fixed
// date, then asserts it falls inside a window that contains its date but outside a
// window that ends before it. The role split and journal row are undone afterwards
// so the shared seed is left pristine.
pub fn events_window_filters_by_occurred_at_test() {
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
  let assert [created] = decode_events(post)
  // Record it as entered on 2026-02-10, so the assertion is independent of the wall
  // clock that stamped occurred_at on the write.
  let assert Ok(Nil) =
    event.set_occurred_at(
      context,
      created.id,
      calendar.Date(2026, calendar.February, 10),
    )

  // 2026-02-10 falls in [2026-02-10, 2026-02-11) ...
  let visible =
    simulate.request(http.Get, "/api/events?from=2026-02-10&to=2026-02-11")
    |> router.handle_request(context)
  // ... but is excluded by a window ending at 2026-02-10 (the upper bound is open).
  let hidden =
    simulate.request(http.Get, "/api/events?from=2026-02-01&to=2026-02-10")
    |> router.handle_request(context)

  // Restore the seed regardless of the assertion outcome.
  restore_engineer_2_roles(context)
  delete_event(context, created.id)

  assert visible.status == 200
  // The feed comes back newest-first (id DESC) and carries the recorded event.
  let events = decode_events(visible)
  assert ids_descending(events)
  let assert [newest, ..] = events
  assert newest.id == created.id

  // Outside the half-open window, it is absent.
  assert hidden.status == 200
  assert list.all(decode_events(hidden), fn(journal_event) {
    journal_event.id != created.id
  })
}

// GET /api/events with no params returns the whole journal (all filters optional).
pub fn events_without_params_returns_the_whole_journal_test() {
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
  let assert [created] = decode_events(post)

  let response =
    simulate.request(http.Get, "/api/events")
    |> router.handle_request(context)

  restore_engineer_2_roles(context)
  delete_event(context, created.id)

  assert response.status == 200
  assert list.any(decode_events(response), fn(journal_event) {
    journal_event.id == created.id
  })
}

// A present-but-malformed date param is a 400.
pub fn events_with_malformed_from_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/events?from=not-a-date")
    |> router.handle_request(ctx())

  assert response.status == 400
}

// --- GET /api/people --------------------------------------------------------

// The people roster as of the seed "now" carries one row per employed engineer,
// each with the engineer_id and resolved day_rate the board cannot supply. Priya
// (engineer 1, L5) is allocated to her two projects, so her row is on-projects.
pub fn people_roster_now_returns_rows_test() {
  let response =
    simulate.request(http.Get, "/api/people?as_of=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 200

  let list = decode_people(response)
  assert list.date == calendar.Date(2026, calendar.June, 15)

  let assert Ok(priya) =
    list.people
    |> list.find(fn(person) { person.engineer_id == 1 })
  assert priya.name == "Priya Sharma"
  assert priya.level == 5
  assert priya.status
    == RosterOnProjects(["Inventory Sync", "Ledger Migration"])
}

// A missing/malformed as_of is a 400.
pub fn people_without_as_of_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/people")
    |> router.handle_request(ctx())

  assert response.status == 400
}

// --- GET /api/engineers/:id -------------------------------------------------

// Marcus Chen (engineer 2) resolves to his current contact and as-of employment.
pub fn engineer_detail_returns_bundle_test() {
  let response =
    simulate.request(http.Get, "/api/engineers/2?as_of=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 200

  let detail = decode_engineer_detail(response)
  assert detail.engineer_id == 2
  assert detail.name == "Marcus Chen"
  assert detail.level == 4
  assert detail.contact.email == "marcus.chen@alembic.com.au"
  assert detail.balance.engineer == "Marcus Chen"
}

// An unknown engineer id is a 404.
pub fn engineer_detail_unknown_is_not_found_test() {
  let response =
    simulate.request(http.Get, "/api/engineers/999?as_of=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 404
}

// A non-integer engineer id is a 400.
pub fn engineer_detail_bad_id_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/engineers/abc?as_of=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 400
}

// --- GET /api/clients -------------------------------------------------------

// The clients list as of "now" carries both seed clients with their active flag.
pub fn clients_list_now_returns_rows_test() {
  let response =
    simulate.request(http.Get, "/api/clients?as_of=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 200

  let list = decode_client_list(response)
  assert list.date == calendar.Date(2026, calendar.June, 15)

  let assert Ok(northwind) =
    list.clients
    |> list.find(fn(client) { client.client_id == 1 })
  assert northwind.name == "Northwind Trading"
  assert northwind.active
}

// --- GET /api/clients/:id ---------------------------------------------------

// Northwind (client 1) resolves to its profile with its contract since-date.
pub fn client_detail_returns_bundle_test() {
  let response =
    simulate.request(http.Get, "/api/clients/1?as_of=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 200

  let detail = decode_client_detail(response)
  assert detail.profile.client_id == 1
  assert detail.profile.name == "Northwind Trading"
  assert detail.since == option.Some(calendar.Date(2024, calendar.January, 1))
}

// An unknown client id is a 404.
pub fn client_detail_unknown_is_not_found_test() {
  let response =
    simulate.request(http.Get, "/api/clients/999?as_of=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 404
}

// --- GET /api/projects ------------------------------------------------------

// The projects list as of "now" carries Ledger Migration (project 100) active,
// with its client and budget.
pub fn projects_list_now_returns_rows_test() {
  let response =
    simulate.request(http.Get, "/api/projects?as_of=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 200

  let list = decode_project_list(response)
  assert list.date == calendar.Date(2026, calendar.June, 15)

  let assert Ok(ledger) =
    list.projects
    |> list.find(fn(project) { project.project_id == 100 })
  assert ledger.title == "Ledger Migration"
  assert ledger.client == "Northwind Trading"
  assert ledger.budget == 500_000.0
  assert ledger.active
}

// --- GET /api/projects/:id --------------------------------------------------

// Ledger Migration (project 100) resolves to its profile, plan, client, and run.
pub fn project_detail_returns_bundle_test() {
  let response =
    simulate.request(http.Get, "/api/projects/100?as_of=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 200

  let detail = decode_project_detail(response)
  assert detail.profile.project_id == 100
  assert detail.profile.title == "Ledger Migration"
  assert detail.client == "Northwind Trading"
  assert detail.plan.budget == 500_000.0
  assert detail.active
}

// An unknown project id is a 404.
pub fn project_detail_unknown_is_not_found_test() {
  let response =
    simulate.request(http.Get, "/api/projects/999?as_of=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 404
}

// --- GET /api/settings ------------------------------------------------------

// The settings read as of "now" carries the rate card, salaries, and leave policy.
pub fn settings_now_returns_tables_test() {
  let response =
    simulate.request(http.Get, "/api/settings?as_of=2026-06-15")
    |> router.handle_request(ctx())

  assert response.status == 200

  let settings = decode_settings(response)
  assert settings.date == calendar.Date(2026, calendar.June, 15)
  assert settings.rate_card != []
  assert settings.salaries != []
}

// A missing/malformed as_of is a 400.
pub fn settings_without_as_of_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/settings")
    |> router.handle_request(ctx())

  assert response.status == 400
}

// --- static / fallthrough ---------------------------------------------------

// An unknown NON-API path serves the SPA shell (200), so client routes like
// /people/5 resolve on a cold load — the history-API fallback (FR-U4).
pub fn unknown_client_path_serves_the_spa_shell_test() {
  let response =
    simulate.request(http.Get, "/no/such/route")
    |> router.handle_request(ctx())

  assert response.status == 200
}

// An unmatched /api/* path is still a genuine 404, not the SPA shell.
pub fn unknown_api_path_is_not_found_test() {
  let response =
    simulate.request(http.Get, "/api/no-such-endpoint")
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

fn decode_timesheet(response) -> TimesheetWeek {
  let assert Ok(week) =
    simulate.read_body(response)
    |> json.parse(codecs.timesheet_week_decoder())
  week
}

fn decode_people(response) -> PeopleList {
  let assert Ok(list) =
    simulate.read_body(response)
    |> json.parse(codecs.people_list_decoder())
  list
}

fn decode_engineer_detail(response) -> EngineerDetail {
  let assert Ok(detail) =
    simulate.read_body(response)
    |> json.parse(codecs.engineer_detail_decoder())
  detail
}

fn decode_client_list(response) -> ClientList {
  let assert Ok(list) =
    simulate.read_body(response)
    |> json.parse(codecs.client_list_decoder())
  list
}

fn decode_client_detail(response) -> ClientDetail {
  let assert Ok(detail) =
    simulate.read_body(response)
    |> json.parse(codecs.client_detail_decoder())
  detail
}

fn decode_project_list(response) -> ProjectList {
  let assert Ok(list) =
    simulate.read_body(response)
    |> json.parse(codecs.project_list_decoder())
  list
}

fn decode_project_detail(response) -> ProjectDetail {
  let assert Ok(detail) =
    simulate.read_body(response)
    |> json.parse(codecs.project_detail_decoder())
  detail
}

fn decode_settings(response) -> Settings {
  let assert Ok(settings) =
    simulate.read_body(response)
    |> json.parse(codecs.settings_decoder())
  settings
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
