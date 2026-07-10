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
import gleam/set
import gleam/string
import gleam/time/calendar
import pog
import shared/access
import shared/availability/view.{type AvailabilityRecord, type HolidayListing} as availability_view
import shared/board/view.{
  type BoardSnapshot, BoardRow, OnLeave, OnProject, Unassigned,
} as board_view
import shared/client/view.{type ClientDetail, type ClientList} as client_view
import shared/command.{type Event, EngineerCommand} as gateway
import shared/engineer/command as engineer_command
import shared/engineer/view.{type EngineerDetail} as engineer_view
import shared/engineer_skill/command as engineer_skill_command
import shared/invoice/view.{type InvoicePage} as invoice_view
import shared/meeting/view.{type CandidateSlot, type MeetingRecord} as meeting_view
import shared/money.{type Money}
import shared/payroll/command as payroll_command
import shared/people/view.{type PeopleList, RosterOnProjects} as people_view
import shared/project/view.{type ProjectDetail, type ProjectList} as project_view
import shared/project_capability/view.{
  type CoverageSnapshot, type GapRecommendations, CapabilityChoice,
  CoverageEngineer, CoverageRequirement, GapRecommendations, Pairing,
  Recommendation,
} as project_capability_view
import shared/settings/view.{type Settings} as settings_view
import shared/skill/view.{
  type EngineerSkills, type TaxonomySnapshot, CapabilityInfo, CapabilityRollup,
  CapabilitySkillMapping, SkillAssessment, SkillInfo,
} as skill_view
import shared/table/response as table_response
import shared/timesheet/command as timesheet_command
import shared/timesheet/view.{
  type TimesheetWeek, TimesheetCell, TimesheetWeek, TimesheetWeekRow,
} as timesheet_view
import tempo/server/account/seed as account_seed
import tempo/server/auth.{type Principal, Principal}
import tempo/server/context.{type Context, Context}
import tempo/server/event
import tempo/server/web/router
import test_pool
import wisp
import wisp/simulate

// --- context ----------------------------------------------------------------

/// A `Context` over the suite's shared pool, unauthenticated.
fn ctx() -> Context {
  test_pool.ctx()
}

/// The suite's shared `Context` with `principal` injected — the test seam the
/// principal-in-`Context` middleware unlocks. Routing a request through
/// `router.route_request(_, ctx_as(p))` exercises the full router + guards with `p`
/// as the authenticated principal, with no login/cookie round-trip and no coupling
/// to the account/role seed. The cookie→principal resolution itself stays covered by
/// the login and session tests, which go through `router.handle_request`.
fn ctx_as(principal: Principal) -> Context {
  Context(..ctx(), principal: option.Some(principal))
}

/// An "Admin" principal holding every permission — what most read/write tests inject,
/// so authorization never masks the behaviour under test. account_id 0 / no linked
/// engineer (a synthetic test principal, not a seeded account).
fn admin() -> Principal {
  Principal(
    account_id: 0,
    actor: "Admin",
    engineer_id: option.None,
    permissions: set.from_list(access.all()),
  )
}

// --- auth helpers (real login → cookie → resolve, for the session glue tests) --

/// Sign in as `actor` (a display name) through POST /api/login against `context`,
/// posting the seeded dev credentials for that identity and returning the login
/// request and its response so a follow-up call can carry the issued session cookie
/// via `simulate.session`. Used only by the tests that exercise the real
/// cookie→principal path (the session is otherwise injected via `ctx_as`).
fn sign_in(context: Context, actor: String) -> #(wisp.Request, wisp.Response) {
  let request =
    simulate.request(http.Post, "/api/login")
    |> simulate.json_body(
      json.object([
        #("username", json.string(username_for(actor))),
        #("password", json.string(account_seed.dev_password)),
      ]),
    )
  #(request, router.handle_request(request, context))
}

/// The seeded login username (email) for an actor display name — the inverse of the
/// dev account cast, so the tests sign in with real credentials without hardcoding
/// emails.
fn username_for(actor: String) -> String {
  let assert Ok(account) =
    list.find(account_seed.dev_accounts(), fn(account) {
      account.display_name == actor
    })
  account.username
}

/// POST a command to /api/operations as an authenticated "Admin" principal (every
/// permission), injected straight into the context — so the write path is exercised
/// without a login round-trip. The server still derives the journal actor from the
/// principal, never the body.
fn post_operation(context: Context, command: gateway.Command) -> wisp.Response {
  simulate.request(http.Post, "/api/operations")
  |> simulate.json_body(
    gateway.encode_operation_request(gateway.OperationRequest(command:)),
  )
  |> router.route_request(Context(..context, principal: option.Some(admin())))
}

fn money_of(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

/// Route a request as an authenticated "Admin" principal (every permission), so a gated
/// read endpoint's permission guard is satisfied. The handler still validates params (a
/// 400/404 surfaces as before, no longer masked by a 401).
fn read(request: wisp.Request) -> wisp.Response {
  router.route_request(request, ctx_as(admin()))
}

// --- GET /api/board ---------------------------------------------------------

// On the seed "now" the board has Marcus on Data Platform, Priya on her two
// half-time projects, and Aisha suppressed to "On leave" — exactly the shared
// BoardSnapshot the client renders, decoded back from the JSON the handler sent.
pub fn board_now_returns_snapshot_test() {
  let response =
    simulate.request(http.Get, "/api/board?date=2026-06-15")
    |> read()

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
        engineer: "Dmitri Volkov",
        level: 2,
        engagement: OnProject(
          project: "Data Platform",
          client: "Globex Corporation",
          fraction: 1.0,
          day_rate: money_of("600.00"),
          valid_from: calendar.Date(2026, calendar.March, 1),
          valid_to: calendar.Date(2027, calendar.January, 1),
        ),
      ),
      BoardRow(engineer: "Hannah Park", level: 6, engagement: Unassigned),
      BoardRow(engineer: "Ines Duarte", level: 2, engagement: Unassigned),
      BoardRow(engineer: "Jonas Weber", level: 3, engagement: Unassigned),
      BoardRow(
        engineer: "Marcus Chen",
        level: 4,
        engagement: OnProject(
          project: "Data Platform",
          client: "Globex Corporation",
          fraction: 1.0,
          day_rate: money_of("1000.00"),
          valid_from: calendar.Date(2025, calendar.January, 1),
          valid_to: calendar.Date(2027, calendar.January, 1),
        ),
      ),
      BoardRow(
        engineer: "Mei Lin",
        level: 5,
        engagement: OnProject(
          project: "Data Platform",
          client: "Globex Corporation",
          fraction: 1.0,
          day_rate: money_of("1200.00"),
          valid_from: calendar.Date(2026, calendar.February, 1),
          valid_to: calendar.Date(2027, calendar.January, 1),
        ),
      ),
      BoardRow(
        engineer: "Noah Fischer",
        level: 5,
        engagement: OnProject(
          project: "Warehouse Automation",
          client: "Northwind Trading",
          fraction: 1.0,
          day_rate: money_of("1200.00"),
          valid_from: calendar.Date(2026, calendar.February, 1),
          valid_to: calendar.Date(2027, calendar.January, 1),
        ),
      ),
      BoardRow(
        engineer: "Omar Haddad",
        level: 4,
        engagement: OnProject(
          project: "Inventory Sync",
          client: "Northwind Trading",
          fraction: 0.6,
          day_rate: money_of("1000.00"),
          valid_from: calendar.Date(2026, calendar.March, 1),
          valid_to: calendar.Date(2026, calendar.December, 1),
        ),
      ),
      BoardRow(
        engineer: "Priya Sharma",
        level: 5,
        engagement: OnProject(
          project: "Inventory Sync",
          client: "Northwind Trading",
          fraction: 0.5,
          day_rate: money_of("1200.00"),
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
          day_rate: money_of("1200.00"),
          valid_from: calendar.Date(2024, calendar.January, 1),
          valid_to: calendar.Date(2027, calendar.January, 1),
        ),
      ),
      BoardRow(
        engineer: "Rohan Sharma",
        level: 2,
        engagement: OnProject(
          project: "Data Platform",
          client: "Globex Corporation",
          fraction: 0.5,
          day_rate: money_of("600.00"),
          valid_from: calendar.Date(2026, calendar.May, 1),
          valid_to: calendar.Date(2026, calendar.October, 1),
        ),
      ),
      BoardRow(engineer: "Sofia Rossi", level: 4, engagement: Unassigned),
      BoardRow(
        engineer: "Tunde Okafor",
        level: 3,
        engagement: OnProject(
          project: "Inventory Sync",
          client: "Northwind Trading",
          fraction: 0.8,
          day_rate: money_of("800.00"),
          valid_from: calendar.Date(2026, calendar.April, 1),
          valid_to: calendar.Date(2026, calendar.November, 1),
        ),
      ),
    ]
  // Each employed engineer carries a leave balance as of the date (exact values
  // are asserted at clean dates in leave_test); the board is name-ordered. The
  // recommender bench (#40 Phase 3 Stage 1, engineers 4-11) is employed from
  // 2026-01-01, so it appears here too, as does the cross-capability pairing
  // fixture (#40 review fix, engineers 12-13) employed from 2026-01-15.
  assert list.map(snapshot.balances, fn(balance) { balance.engineer })
    == [
      "Aisha Okafor", "Dmitri Volkov", "Hannah Park", "Ines Duarte",
      "Jonas Weber", "Marcus Chen", "Mei Lin", "Noah Fischer", "Omar Haddad",
      "Priya Sharma", "Rohan Sharma", "Sofia Rossi", "Tunde Okafor",
    ]
}

// A missing date is a 400, not a crash or a 500.
pub fn board_without_date_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/board")
    |> read()

  assert response.status == 400
}

// A malformed date is a 400.
pub fn board_with_bad_date_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/board?date=not-a-date")
    |> read()

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
    |> read()

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
    |> read()

  assert response.status == 200

  let week = decode_timesheet(response)
  assert week.rows == []
  assert week.days == []
}

// A missing week param is a 400.
pub fn timesheet_read_without_week_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/timesheet?engineer=1")
    |> read()

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
    post_operation(
      context,
      gateway.TimesheetCommand(timesheet_command.LogTimesheet(
        engineer_id: 2,
        project_id: 300,
        day: calendar.Date(2026, calendar.June, 10),
        hours: 7.5,
      )),
    )

  let status = response.status
  let assert [event] = decode_events(response)

  // Re-read the week for that engineer; the logged hours are on the 06-10 cell of
  // the Data Platform (300) row.
  let week =
    simulate.request(http.Get, "/api/timesheet?engineer=2&week=2026-06-08")
    |> read()
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
    post_operation(
      context,
      gateway.TimesheetCommand(
        timesheet_command.LogWeek(engineer_id: 2, entries: [
          timesheet_command.TimesheetEntry(
            project_id: 300,
            day: calendar.Date(2026, calendar.June, 8),
            hours: 5.0,
          ),
          timesheet_command.TimesheetEntry(
            project_id: 300,
            day: calendar.Date(2026, calendar.June, 9),
            hours: 6.0,
          ),
        ]),
      ),
    )

  let status = response.status
  let assert [event] = decode_events(response)

  // Re-read the week; both cells of the Data Platform (300) row are on record.
  let week =
    simulate.request(http.Get, "/api/timesheet?engineer=2&week=2026-06-08")
    |> read()
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

// A successful operation returns 200 with the committed-event ack(s) as a JSON
// array (the operation tag and summary — NOT the re-encoded payload, which is the
// journal's; GET /api/events), and the journal really grew by that row. Promote
// Marcus (id 2) to L6 effective 2026-09-01: the
// FOR PORTION OF change commits, so the role split and the appended event_log row
// are both undone afterwards to leave the shared seed pristine.
pub fn operation_promote_returns_created_event_test() {
  let context = ctx()
  let before = event_count(context)

  let response =
    post_operation(
      context,
      EngineerCommand(engineer_command.Promote(
        engineer_id: 2,
        level: 6,
        effective: calendar.Date(2026, calendar.September, 1),
      )),
    )

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
  // The actor is derived from the authenticated session ("Admin"), NOT the request
  // body — the forgeable-actor fix (issue #6).
  assert event.actor == "Admin"
  assert event.summary == "Promote engineer 2 to L6 from 2026-09-01"
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
    post_operation(
      context,
      gateway.TimesheetCommand(timesheet_command.LogTimesheet(
        engineer_id: 2,
        project_id: 100,
        day: calendar.Date(2026, calendar.June, 10),
        hours: 8.0,
      )),
    )

  assert response.status == 409
  assert decode_error_code(response) == "containment_violated"
  // The whole dispatch transaction rolled back: no journal row was appended.
  assert event_count(context) == before
}

// On an authenticated session, a body missing the `command` is a 400, not a 500.
pub fn operation_bad_body_is_bad_request_test() {
  let response =
    simulate.request(http.Post, "/api/operations")
    |> simulate.json_body(json.object([#("not_a_command", json.string("x"))]))
    |> router.route_request(ctx_as(admin()))

  assert response.status == 400
}

// --- authentication & authorization (issue #6) ------------------------------

// An operation with NO session is rejected with 401 before any command runs: the
// actor can no longer be forged through the body. The journal does not grow.
pub fn operation_without_session_is_unauthenticated_test() {
  let context = ctx()
  let before = event_count(context)

  let response =
    simulate.request(http.Post, "/api/operations")
    |> simulate.json_body(
      gateway.encode_operation_request(
        gateway.OperationRequest(
          command: EngineerCommand(engineer_command.Promote(
            engineer_id: 2,
            level: 6,
            effective: calendar.Date(2026, calendar.September, 1),
          )),
        ),
      ),
    )
    |> router.handle_request(context)

  assert response.status == 401
  assert decode_error_code(response) == "unauthenticated"
  assert event_count(context) == before
}

// A session cookie the client tampered with (re-signed under a different key) does
// not verify, so the request is treated as unauthenticated — a forged session
// cannot impersonate an actor. A bogus cookie value yields a 401.
pub fn operation_with_forged_session_is_unauthenticated_test() {
  let context = ctx()
  let before = event_count(context)

  let response =
    simulate.request(http.Post, "/api/operations")
    |> simulate.json_body(
      gateway.encode_operation_request(
        gateway.OperationRequest(
          command: EngineerCommand(engineer_command.Promote(
            engineer_id: 2,
            level: 6,
            effective: calendar.Date(2026, calendar.September, 1),
          )),
        ),
      ),
    )
    |> simulate.header("cookie", "tempo_session=Admin%7Cadmin")
    |> router.handle_request(context)

  assert response.status == 401
  assert event_count(context) == before
}

// The journal actor is DERIVED FROM THE SESSION, not the body. Authenticate as a
// specific identity (Ops, a manager who may promote) and assert the recorded event
// carries THAT actor, regardless of what a body could have claimed (the body no longer
// carries an actor at all).
pub fn operation_actor_is_derived_from_session_test() {
  let context = ctx()

  let #(login_request, login_response) = sign_in(context, "Ops")
  let response =
    simulate.request(http.Post, "/api/operations")
    |> simulate.json_body(
      gateway.encode_operation_request(
        gateway.OperationRequest(
          command: EngineerCommand(engineer_command.Promote(
            engineer_id: 2,
            level: 6,
            effective: calendar.Date(2026, calendar.September, 1),
          )),
        ),
      ),
    )
    |> simulate.session(login_request, login_response)
    |> router.handle_request(context)

  let status = response.status
  let assert [event] = decode_events(response)

  restore_engineer_2_roles(context)
  delete_event(context, event.id)

  assert status == 200
  assert event.actor == "Ops"
}

// The authorization gate refuses a financial command for a non-Admin principal
// with 403, before any transaction opens: Ops may not run payroll. The journal
// does not grow.
pub fn operation_forbidden_for_unauthorized_role_is_403_test() {
  let context = ctx()
  let before = event_count(context)

  let #(login_request, login_response) = sign_in(context, "Ops")
  let response =
    simulate.request(http.Post, "/api/operations")
    |> simulate.json_body(
      gateway.encode_operation_request(
        gateway.OperationRequest(
          command: gateway.PayrollCommand(payroll_command.RunPayroll(
            period_from: calendar.Date(2026, calendar.June, 1),
            period_to: calendar.Date(2026, calendar.July, 1),
          )),
        ),
      ),
    )
    |> simulate.session(login_request, login_response)
    |> router.handle_request(context)

  assert response.status == 403
  assert decode_error_code(response) == "unauthorized"
  assert event_count(context) == before
}

// A principal without skills.manage is refused the taxonomy read with 403:
// Finance manages money, not the capability/skill taxonomy.
pub fn skills_taxonomy_forbidden_for_unauthorized_role_is_403_test() {
  let context = ctx()

  let #(login_request, login_response) = sign_in(context, "Finance")
  let response =
    simulate.request(http.Get, "/api/skills?as_of=2026-06-15")
    |> simulate.session(login_request, login_response)
    |> router.handle_request(context)

  assert response.status == 403
  assert decode_error_code(response) == "forbidden"
}

// A principal without skills.assess is refused an assessment write with 403,
// before any transaction opens: Finance may not assess engineer skills.
pub fn assess_skill_forbidden_for_unauthorized_role_is_403_test() {
  let context = ctx()
  let before = event_count(context)

  let #(login_request, login_response) = sign_in(context, "Finance")
  let response =
    simulate.request(http.Post, "/api/operations")
    |> simulate.json_body(
      gateway.encode_operation_request(
        gateway.OperationRequest(
          command: gateway.EngineerSkillCommand(
            engineer_skill_command.AssessSkill(
              engineer_id: 2,
              skill_id: 5,
              level: 4,
              effective: calendar.Date(2026, calendar.September, 1),
            ),
          ),
        ),
      ),
    )
    |> simulate.session(login_request, login_response)
    |> router.handle_request(context)

  assert response.status == 403
  assert decode_error_code(response) == "unauthorized"
  assert event_count(context) == before
}

// Correct credentials succeed (200) and issue a session; a wrong password and an
// unknown username are both refused with the SAME uniform 401, so login leaks no
// oracle for which accounts exist and the journal can never be stamped with a junk
// actor.
pub fn login_accepts_correct_credentials_and_rejects_bad_ones_test() {
  let context = ctx()

  let #(_, known) = sign_in(context, "Admin")
  assert known.status == 200

  let wrong_password = attempt_login(context, "admin@alembic.com.au", "nope")
  assert wrong_password.status == 401
  assert decode_error_code(wrong_password) == "unauthenticated"

  let unknown_user =
    attempt_login(context, "mallory@alembic.com.au", account_seed.dev_password)
  assert unknown_user.status == 401
  assert decode_error_code(unknown_user) == "unauthenticated"
}

// Logout expires the session cookie: a 200 carrying a `Set-Cookie` that clears
// `tempo_session` (Max-Age 0), so the browser drops it and the next request is
// unauthenticated.
pub fn logout_clears_the_session_cookie_test() {
  let response =
    simulate.request(http.Post, "/api/logout")
    |> read()

  assert response.status == 200
  let assert Ok(set_cookie) = list.key_find(response.headers, "set-cookie")
  assert string.contains(set_cookie, "tempo_session=")
  assert string.contains(set_cookie, "Max-Age=0")
}

/// POST raw credentials to /api/login (no dev-cast lookup), for the rejection cases
/// that use a username with no seeded account.
fn attempt_login(
  context: Context,
  username: String,
  password: String,
) -> wisp.Response {
  simulate.request(http.Post, "/api/login")
  |> simulate.json_body(
    json.object([
      #("username", json.string(username)),
      #("password", json.string(password)),
    ]),
  )
  |> router.handle_request(context)
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
    post_operation(
      context,
      EngineerCommand(engineer_command.Promote(
        engineer_id: 2,
        level: 6,
        effective: calendar.Date(2026, calendar.September, 1),
      )),
    )
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
    |> read()
  // ... but is excluded by a window ending at 2026-02-10 (the upper bound is open).
  let hidden =
    simulate.request(http.Get, "/api/events?from=2026-02-01&to=2026-02-10")
    |> read()

  // Restore the seed regardless of the assertion outcome.
  restore_engineer_2_roles(context)
  delete_event(context, created.id)

  assert visible.status == 200
  // The feed comes back newest-first (id DESC) and carries the recorded event.
  let events = decode_event_page(visible).events
  assert ids_descending(events)
  let assert [newest, ..] = events
  assert newest.id == created.id

  // Outside the half-open window, it is absent.
  assert hidden.status == 200
  assert list.all(decode_event_page(hidden).events, fn(journal_event) {
    journal_event.id != created.id
  })
}

// GET /api/events with no params returns the whole journal (all filters optional).
pub fn events_without_params_returns_the_whole_journal_test() {
  let context = ctx()

  let post =
    post_operation(
      context,
      EngineerCommand(engineer_command.Promote(
        engineer_id: 2,
        level: 6,
        effective: calendar.Date(2026, calendar.September, 1),
      )),
    )
  let assert [created] = decode_events(post)

  let response =
    simulate.request(http.Get, "/api/events")
    |> read()

  restore_engineer_2_roles(context)
  delete_event(context, created.id)

  assert response.status == 200
  assert list.any(decode_event_page(response).events, fn(journal_event) {
    journal_event.id == created.id
  })
}

// A present-but-malformed date param is a 400.
pub fn events_with_malformed_from_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/events?from=not-a-date")
    |> read()

  assert response.status == 400
}

// Keyset paging the journal (#12): a limit-1 first page holds the newest event and
// a cursor; following it returns the next-newest with no overlap, still id-DESC.
// The demo seed journals dozens of operations, so the first page is not the last.
pub fn events_cursor_pages_newest_first_without_overlap_test() {
  let first =
    simulate.request(http.Get, "/api/events?limit=1")
    |> read()
    |> decode_event_page

  assert list.length(first.events) == 1
  let assert option.Some(cursor) = first.next_cursor
  let assert [first_event] = first.events

  let second =
    simulate.request(http.Get, "/api/events?limit=1&cursor=" <> cursor)
    |> read()
    |> decode_event_page

  let assert [second_event] = second.events
  assert second_event.id < first_event.id
}

// A malformed events cursor is a 400.
pub fn events_malformed_cursor_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/events?cursor=@@bad@@")
    |> read()

  assert response.status == 400
}

// --- GET /api/people --------------------------------------------------------

// The people roster as of the seed "now" carries one row per employed engineer,
// each with the engineer_id and resolved day_rate the board cannot supply. Priya
// (engineer 1, L5) is allocated to her two projects, so her row is on-projects.
pub fn people_roster_now_returns_rows_test() {
  let response =
    simulate.request(http.Get, "/api/people?as_of=2026-06-15")
    |> read()

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
    |> read()

  assert response.status == 400
}

// Keyset paging the people roster (#12): a limit-1 first page holds one engineer
// and a cursor; following it returns the next engineer with no overlap, in the same
// (name, engineer_id) order as the unpaged read.
pub fn people_cursor_pages_without_overlap_test() {
  let first =
    simulate.request(http.Get, "/api/people?as_of=2026-06-15&limit=1")
    |> read()
    |> decode_people

  assert list.length(first.people) == 1
  let assert option.Some(cursor) = first.next_cursor

  let second =
    simulate.request(
      http.Get,
      "/api/people?as_of=2026-06-15&limit=1&cursor=" <> cursor,
    )
    |> read()
    |> decode_people

  let first_ids = list.map(first.people, fn(person) { person.engineer_id })
  let second_ids = list.map(second.people, fn(person) { person.engineer_id })
  assert list.any(second_ids, fn(id) { list.contains(first_ids, id) }) == False

  let unpaged =
    simulate.request(http.Get, "/api/people?as_of=2026-06-15")
    |> read()
    |> decode_people
  let expected =
    list.take(list.map(unpaged.people, fn(person) { person.engineer_id }), 2)
  assert list.append(first_ids, second_ids) == expected
}

// --- GET /api/engineers/:id -------------------------------------------------

// Marcus Chen (engineer 2) resolves to his current contact and as-of employment.
pub fn engineer_detail_returns_bundle_test() {
  let response =
    simulate.request(http.Get, "/api/engineers/2?as_of=2026-06-15")
    |> read()

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
    |> read()

  assert response.status == 404
}

// A non-integer engineer id is a 400.
pub fn engineer_detail_bad_id_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/engineers/abc?as_of=2026-06-15")
    |> read()

  assert response.status == 400
}

// --- GET /api/skills ---------------------------------------------------------

// The taxonomy snapshot as-of 2026-06-15: the seed's 4 capabilities, 12 skills,
// and their weighted composition matrix, each read back in the exact order and
// values base_seed.sql wrote (server/priv/seed/base_seed.sql:380-458).
pub fn skills_taxonomy_now_returns_capabilities_skills_and_mappings_test() {
  let response =
    simulate.request(http.Get, "/api/skills?as_of=2026-06-15")
    |> read()

  assert response.status == 200

  let snapshot = decode_taxonomy_snapshot(response)
  assert snapshot.capabilities
    == [
      CapabilityInfo(
        2,
        "Data Engineering",
        "Pipelines, warehousing, and distributed data systems",
      ),
      CapabilityInfo(
        3,
        "Frontend Delivery",
        "Client applications and the interfaces engineers ship them through",
      ),
      CapabilityInfo(
        1,
        "Payments Platform",
        "Billing, ledger, and payment-gateway integrations",
      ),
      CapabilityInfo(
        4,
        "Platform Infrastructure",
        "Cloud infrastructure, deployment, and operability",
      ),
    ]
  assert snapshot.skills
    == [
      SkillInfo(
        4,
        "API Design",
        "Designing stable, versioned service interfaces",
      ),
      SkillInfo(11, "CI/CD", "Build, test, and deployment pipelines"),
      SkillInfo(
        12,
        "Cloud Infrastructure",
        "Provisioning and operating cloud infrastructure",
      ),
      SkillInfo(6, "Data Pipelines", "Building and operating ETL/ELT pipelines"),
      SkillInfo(
        7,
        "Distributed Systems",
        "Consistency, partitioning, and failure handling at scale",
      ),
      SkillInfo(8, "Frontend Development", "Building client applications"),
      SkillInfo(
        10,
        "Kubernetes",
        "Operating containerised workloads on Kubernetes",
      ),
      SkillInfo(
        3,
        "Ledger Accounting Systems",
        "Double-entry ledgers and reconciliation",
      ),
      SkillInfo(
        1,
        "Payment Gateways",
        "Integrating and operating third-party payment gateways",
      ),
      SkillInfo(
        2,
        "PCI Compliance",
        "Handling cardholder data within PCI-DSS controls",
      ),
      SkillInfo(
        5,
        "SQL & Database Design",
        "Relational schema design and query optimisation",
      ),
      SkillInfo(
        9,
        "UI/UX Design",
        "Interaction and visual design for user-facing products",
      ),
    ]
  assert snapshot.mappings
    == [
      CapabilitySkillMapping(1, 1, 3),
      CapabilitySkillMapping(1, 2, 3),
      CapabilitySkillMapping(1, 3, 2),
      CapabilitySkillMapping(1, 4, 1),
      CapabilitySkillMapping(2, 5, 3),
      CapabilitySkillMapping(2, 6, 3),
      CapabilitySkillMapping(2, 7, 2),
      CapabilitySkillMapping(3, 4, 1),
      CapabilitySkillMapping(3, 8, 3),
      CapabilitySkillMapping(3, 9, 2),
      CapabilitySkillMapping(4, 7, 1),
      CapabilitySkillMapping(4, 10, 3),
      CapabilitySkillMapping(4, 11, 2),
      CapabilitySkillMapping(4, 12, 3),
    ]
}

// --- GET /api/engineers/:id/skills --------------------------------------------

// Marcus's (engineer 2) skill matrix and capability rollups as-of 2026-06-15: he
// was reassessed on Data Pipelines from 2026-05-01 (3 -> 4), so both the matrix
// and the weighted rollups reflect the reassessed level
// (server/priv/seed/base_seed.sql:472-499).
pub fn engineer_skills_now_returns_matrix_and_rollups_test() {
  let response =
    simulate.request(http.Get, "/api/engineers/2/skills?as_of=2026-06-15")
    |> read()

  assert response.status == 200

  let skills = decode_engineer_skills(response)
  assert skills.matrix
    == [
      SkillAssessment(4, "API Design", 2, [
        "Payments Platform", "Frontend Delivery",
      ]),
      SkillAssessment(11, "CI/CD", 2, ["Platform Infrastructure"]),
      SkillAssessment(12, "Cloud Infrastructure", 2, [
        "Platform Infrastructure",
      ]),
      SkillAssessment(6, "Data Pipelines", 4, ["Data Engineering"]),
      SkillAssessment(7, "Distributed Systems", 3, [
        "Data Engineering", "Platform Infrastructure",
      ]),
      SkillAssessment(8, "Frontend Development", 0, ["Frontend Delivery"]),
      SkillAssessment(10, "Kubernetes", 0, ["Platform Infrastructure"]),
      SkillAssessment(3, "Ledger Accounting Systems", 0, [
        "Payments Platform",
      ]),
      SkillAssessment(1, "Payment Gateways", 0, ["Payments Platform"]),
      SkillAssessment(2, "PCI Compliance", 0, ["Payments Platform"]),
      SkillAssessment(5, "SQL & Database Design", 4, ["Data Engineering"]),
      SkillAssessment(9, "UI/UX Design", 0, ["Frontend Delivery"]),
    ]
  assert skills.rollups
    == [
      CapabilityRollup(2, "Data Engineering", 3.75),
      CapabilityRollup(3, "Frontend Delivery", 0.3333333333333333),
      CapabilityRollup(1, "Payments Platform", 0.2222222222222222),
      CapabilityRollup(4, "Platform Infrastructure", 1.4444444444444444),
    ]
}

// An unknown engineer id is a 404.
pub fn engineer_skills_unknown_is_not_found_test() {
  let response =
    simulate.request(http.Get, "/api/engineers/999/skills?as_of=2026-06-15")
    |> read()

  assert response.status == 404
}

// A non-integer engineer id is a 400.
pub fn engineer_skills_bad_id_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/engineers/abc/skills?as_of=2026-06-15")
    |> read()

  assert response.status == 400
}

// --- GET /api/invoices (keyset pagination, #12) -----------------------------

// The default page over the BASE test seed (which has no invoices) is an empty
// page: zero rows and no next_cursor. This is the seed-independent shape the HTTP
// layer guarantees; the paging-WITH-rows behaviour is exercised over a
// transactional rollback fixture in pnl_test (the base seed cannot supply invoices
// without mutating shared state).
pub fn invoices_default_page_on_empty_seed_is_empty_test() {
  let response =
    simulate.request(http.Get, "/api/invoices?as_of=2026-06-15")
    |> read()

  assert response.status == 200

  let page = decode_invoice_page(response)
  assert page.invoices == []
  assert page.next_cursor == option.None
}

// GET /api/invoices/table advertises the data-table schema and a (possibly empty)
// page of rows. The base seed has no invoices, so the rows are empty here; the
// schema is asserted directly. Row-content behaviour is covered in table_test and
// the e2e suite.
pub fn invoices_table_advertises_schema_test() {
  let response =
    simulate.request(http.Get, "/api/invoices/table?as_of=2026-06-15")
    |> read()

  assert response.status == 200

  let table = decode_table(response)
  assert table.schema.table_id == "invoices"
  let keys = list.map(table.schema.columns, fn(column) { column.key })
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
  assert table.rows == []
}

// A present-but-undecodable cursor is a 400 (a forged or corrupted token), not a
// 500 or a silent first-page.
pub fn invoices_malformed_cursor_is_bad_request_test() {
  let response =
    simulate.request(
      http.Get,
      "/api/invoices?as_of=2026-06-15&cursor=not-a-real-cursor",
    )
    |> read()

  assert response.status == 400
}

// --- GET /api/clients -------------------------------------------------------

// The clients list as of "now" carries both seed clients with their active flag.
pub fn clients_list_now_returns_rows_test() {
  let response =
    simulate.request(http.Get, "/api/clients?as_of=2026-06-15")
    |> read()

  assert response.status == 200

  let list = decode_client_list(response)
  assert list.date == calendar.Date(2026, calendar.June, 15)

  let assert Ok(northwind) =
    list.clients
    |> list.find(fn(client) { client.client_id == 1 })
  assert northwind.name == "Northwind Trading"
  assert northwind.active
}

// On the timeline scrub, a client whose first contract starts AFTER the as-of date
// has not come into existence yet: it is absent from the directory, not listed with
// an 'ended' pill (the clients mirror of the projects #19 rule). At 2024-06-04 only
// Northwind (contract from 2024-01-01) has started; Globex (2025-01-01) and Initech
// (2026-06-01) are not yet shown.
pub fn clients_list_excludes_not_yet_started_clients_test() {
  let response =
    simulate.request(http.Get, "/api/clients?as_of=2024-06-04")
    |> read()

  assert response.status == 200

  let bundle = decode_client_list(response)
  let ids = list.map(bundle.clients, fn(client) { client.client_id })
  assert ids == [1]
}

// Keyset paging the clients directory (#12): a limit-1 first page holds one row
// and a cursor; following it returns the next client with no overlap, in the same
// (name, client_id) order as the unpaged read.
pub fn clients_cursor_pages_without_overlap_test() {
  let first =
    simulate.request(http.Get, "/api/clients?as_of=2026-06-15&limit=1")
    |> read()
    |> decode_client_list

  assert list.length(first.clients) == 1
  let assert option.Some(cursor) = first.next_cursor

  let second =
    simulate.request(
      http.Get,
      "/api/clients?as_of=2026-06-15&limit=1&cursor=" <> cursor,
    )
    |> read()
    |> decode_client_list

  let first_ids = list.map(first.clients, fn(client) { client.client_id })
  let second_ids = list.map(second.clients, fn(client) { client.client_id })
  assert list.any(second_ids, fn(id) { list.contains(first_ids, id) }) == False

  let unpaged =
    simulate.request(http.Get, "/api/clients?as_of=2026-06-15")
    |> read()
    |> decode_client_list
  assert unpaged.next_cursor == option.None
  let expected =
    list.take(list.map(unpaged.clients, fn(client) { client.client_id }), 2)
  assert list.append(first_ids, second_ids) == expected
}

// A malformed clients cursor is a 400.
pub fn clients_malformed_cursor_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/clients?as_of=2026-06-15&cursor=@@bad@@")
    |> read()

  assert response.status == 400
}

// --- GET /api/clients/:id ---------------------------------------------------

// Northwind (client 1) resolves to its profile with its contract since-date.
pub fn client_detail_returns_bundle_test() {
  let response =
    simulate.request(http.Get, "/api/clients/1?as_of=2026-06-15")
    |> read()

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
    |> read()

  assert response.status == 404
}

// --- GET /api/projects ------------------------------------------------------

// The projects list as of "now" carries Ledger Migration (project 100) active,
// with its client and budget.
pub fn projects_list_now_returns_rows_test() {
  let response =
    simulate.request(http.Get, "/api/projects?as_of=2026-06-15")
    |> read()

  assert response.status == 200

  let list = decode_project_list(response)
  assert list.date == calendar.Date(2026, calendar.June, 15)

  let assert Ok(ledger) =
    list.projects
    |> list.find(fn(project) { project.project_id == 100 })
  assert ledger.title == "Ledger Migration"
  assert ledger.client == "Northwind Trading"
  assert ledger.budget == money_of("500000.00")
  assert ledger.active
}

// Keyset paging the projects directory (#12): a limit-1 first page holds one row
// and a cursor; following it returns the next project with no overlap, in the same
// (title, project_id) order as the unpaged read.
pub fn projects_cursor_pages_without_overlap_test() {
  let first =
    simulate.request(http.Get, "/api/projects?as_of=2026-06-15&limit=1")
    |> read()
    |> decode_project_list

  assert list.length(first.projects) == 1
  let assert option.Some(cursor) = first.next_cursor

  let second =
    simulate.request(
      http.Get,
      "/api/projects?as_of=2026-06-15&limit=1&cursor=" <> cursor,
    )
    |> read()
    |> decode_project_list

  let first_ids = list.map(first.projects, fn(project) { project.project_id })
  let second_ids = list.map(second.projects, fn(project) { project.project_id })
  assert list.any(second_ids, fn(id) { list.contains(first_ids, id) }) == False

  let unpaged =
    simulate.request(http.Get, "/api/projects?as_of=2026-06-15")
    |> read()
    |> decode_project_list
  let expected =
    list.take(list.map(unpaged.projects, fn(project) { project.project_id }), 2)
  assert list.append(first_ids, second_ids) == expected
}

// --- GET /api/projects/:id --------------------------------------------------

// Ledger Migration (project 100) resolves to its profile, plan, client, and run.
pub fn project_detail_returns_bundle_test() {
  let response =
    simulate.request(http.Get, "/api/projects/100?as_of=2026-06-15")
    |> read()

  assert response.status == 200

  let detail = decode_project_detail(response)
  assert detail.profile.project_id == 100
  assert detail.profile.title == "Ledger Migration"
  assert detail.client == "Northwind Trading"
  assert detail.plan.budget == money_of("500000.00")
  assert detail.active
}

// An unknown project id is a 404.
pub fn project_detail_unknown_is_not_found_test() {
  let response =
    simulate.request(http.Get, "/api/projects/999?as_of=2026-06-15")
    |> read()

  assert response.status == 404
}

// --- GET /api/projects/:id/coverage ------------------------------------------

// Ledger Migration (project 100)'s seeded capability demand (#39): the
// Payments Platform requirement needs 2 engineers at L3, but Priya, the
// project's only allocated engineer, rolls up to ~3.56 there (Payment
// Gateways(3)=4, PCI Compliance(3)=3, Ledger Accounting Systems(2)=4, API
// Design(1)=3) — she covers alone, leaving a visible gap of one against the
// quantity. The Frontend Delivery requirement needs only 1 and Priya's ~1.5
// rollup clears it, so it is fully covered. The catalog carries the full
// seeded capability taxonomy, ordered by name.
pub fn project_capability_coverage_now_returns_the_seeded_gap_test() {
  let response =
    simulate.request(http.Get, "/api/projects/100/coverage?as_of=2026-06-15")
    |> read()

  assert response.status == 200

  let snapshot = decode_coverage_snapshot(response)
  assert snapshot.catalog
    == [
      CapabilityChoice(2, "Data Engineering"),
      CapabilityChoice(3, "Frontend Delivery"),
      CapabilityChoice(1, "Payments Platform"),
      CapabilityChoice(4, "Platform Infrastructure"),
    ]
  assert snapshot.requirements
    == [
      CoverageRequirement(
        capability_id: 3,
        capability_name: "Frontend Delivery",
        target_level: 1,
        quantity: 1.0,
        valid_from: calendar.Date(2026, calendar.January, 10),
        valid_to: calendar.Date(2027, calendar.January, 1),
        covering: [
          CoverageEngineer(
            engineer_id: 1,
            name: "Priya Sharma",
            proficiency: 1.5,
            allocation: 0.5,
          ),
        ],
        others: [],
      ),
      CoverageRequirement(
        capability_id: 1,
        capability_name: "Payments Platform",
        target_level: 3,
        quantity: 2.0,
        valid_from: calendar.Date(2026, calendar.January, 10),
        valid_to: calendar.Date(2027, calendar.January, 1),
        covering: [
          CoverageEngineer(
            engineer_id: 1,
            name: "Priya Sharma",
            proficiency: 3.5555555555555556,
            allocation: 0.5,
          ),
        ],
        others: [],
      ),
    ]
}

// A non-integer project id is a 400.
pub fn project_capability_coverage_bad_id_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/projects/abc/coverage?as_of=2026-06-15")
    |> read()

  assert response.status == 400
}

// An unknown project is a 404 (mirrors project_detail_unknown_is_not_found_test).
pub fn project_capability_coverage_unknown_project_is_not_found_test() {
  let response =
    simulate.request(http.Get, "/api/projects/999/coverage?as_of=2026-06-15")
    |> read()

  assert response.status == 404
}

// A missing as_of is a 400 (mirrors settings_without_as_of_is_bad_request_test).
pub fn project_capability_coverage_without_as_of_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/projects/100/coverage")
    |> read()

  assert response.status == 400
}

// --- GET /api/projects/:id/recommendations -----------------------------------

// The seeded recommender bench (#40 Phase 3 Stage 2) against Ledger
// Migration's Payments Platform gap (target L3 x2.00, covered only by Priya):
// ready-now fits first (capped fit DESC, then free DESC, then name — Omar ties
// Mei's capped 1.0 but wins on free), then growth pairings (free DESC, then
// name). Frontend Delivery is fully covered so it produces no gap at all.
pub fn project_capability_recommendations_now_returns_the_seeded_gaps_test() {
  let response =
    simulate.request(
      http.Get,
      "/api/projects/100/recommendations?as_of=2026-06-15",
    )
    |> read()

  assert response.status == 200

  let gaps = decode_gap_recommendations_list(response)
  assert gaps
    == [
      GapRecommendations(
        capability_id: 1,
        capability_name: "Payments Platform",
        target_level: 3,
        quantity: 2.0,
        covered: 1,
        recommendations: [
          Recommendation(
            engineer_id: 4,
            name: "Omar Haddad",
            level: 4,
            proficiency: 3.0,
            free: 0.4,
            rationale: "covers the Payments Platform gap at 3.0; 40% available",
            pairing: option.None,
          ),
          Recommendation(
            engineer_id: 6,
            name: "Mei Lin",
            level: 5,
            proficiency: 3.6666666666666665,
            free: 0.0,
            rationale: "covers the Payments Platform gap at 3.7; 0% available",
            pairing: option.None,
          ),
          Recommendation(
            engineer_id: 5,
            name: "Sofia Rossi",
            level: 4,
            proficiency: 2.6666666666666665,
            free: 1.0,
            rationale: "covers the Payments Platform gap at 2.7; 100% available",
            pairing: option.None,
          ),
          Recommendation(
            engineer_id: 7,
            name: "Tunde Okafor",
            level: 3,
            proficiency: 2.0,
            free: 0.2,
            rationale: "covers the Payments Platform gap at 2.0; 20% available",
            pairing: option.None,
          ),
          Recommendation(
            engineer_id: 8,
            name: "Rohan Sharma",
            level: 2,
            proficiency: 0.8888888888888888,
            free: 0.5,
            rationale: "growth: learns Payment Gateways under Priya Sharma; 50% available",
            pairing: option.Some(Pairing(
              teacher_id: 1,
              teacher_name: "Priya Sharma",
              skill_name: "Payment Gateways",
            )),
          ),
          Recommendation(
            engineer_id: 9,
            name: "Dmitri Volkov",
            level: 2,
            proficiency: 0.5555555555555556,
            free: 0.0,
            rationale: "growth: learns Ledger Accounting Systems under Priya Sharma; 0% available",
            pairing: option.Some(Pairing(
              teacher_id: 1,
              teacher_name: "Priya Sharma",
              skill_name: "Ledger Accounting Systems",
            )),
          ),
        ],
      ),
    ]
}

// A non-integer project id is a 400 (mirrors the coverage route).
pub fn project_capability_recommendations_bad_id_is_bad_request_test() {
  let response =
    simulate.request(
      http.Get,
      "/api/projects/abc/recommendations?as_of=2026-06-15",
    )
    |> read()

  assert response.status == 400
}

// An unknown project is a 404 (mirrors the coverage route).
pub fn project_capability_recommendations_unknown_project_is_not_found_test() {
  let response =
    simulate.request(
      http.Get,
      "/api/projects/999/recommendations?as_of=2026-06-15",
    )
    |> read()

  assert response.status == 404
}

// A missing as_of is a 400 (mirrors the coverage route).
pub fn project_capability_recommendations_without_as_of_is_bad_request_test() {
  let response =
    simulate.request(http.Get, "/api/projects/100/recommendations")
    |> read()

  assert response.status == 400
}

// --- GET /api/settings ------------------------------------------------------

// The settings read as of "now" carries the rate card, salaries, and leave policy.
pub fn settings_now_returns_tables_test() {
  let response =
    simulate.request(http.Get, "/api/settings?as_of=2026-06-15")
    |> read()

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
    |> read()

  assert response.status == 400
}

// --- GET /api/meetings --------------------------------------------------------

// As of 2026-07-05, the seeded "July all-hands" (2026-07-10 09:00 Europe/London) is
// upcoming. Its canonical offset is London's July BST offset (+60); Priya (id 1,
// relocated to London from 2026-07-01) reads the same +60 local offset, and Marcus
// (id 2, Los Angeles) reads PDT's -420.
pub fn meetings_upcoming_includes_seeded_all_hands_test() {
  let response =
    simulate.request(http.Get, "/api/meetings?as_of=2026-07-05")
    |> read()

  assert response.status == 200

  let meetings = decode_meetings(response)
  let assert Ok(all_hands) =
    list.find(meetings, fn(meeting) { meeting.title == "July all-hands" })

  assert all_hands.canonical_offset_minutes == 60

  let assert Ok(priya) =
    list.find(all_hands.attendees, fn(attendee) { attendee.engineer_id == 1 })
  assert priya.timezone == option.Some("Europe/London")
  assert priya.local_offset_minutes == option.Some(60)

  let assert Ok(marcus) =
    list.find(all_hands.attendees, fn(attendee) { attendee.engineer_id == 2 })
  assert marcus.local_offset_minutes == option.Some(-420)
}

// A principal without read.engineers is refused the meetings read with 403.
pub fn meetings_forbidden_for_unauthorized_role_is_403_test() {
  let context = ctx()

  let #(login_request, login_response) = sign_in(context, "Priya Sharma")
  let response =
    simulate.request(http.Get, "/api/meetings?as_of=2026-07-05")
    |> simulate.session(login_request, login_response)
    |> router.handle_request(context)

  assert response.status == 403
  assert decode_error_code(response) == "forbidden"
}

// --- GET /api/meetings/find-a-time ------------------------------------------

// Sydney and LA only overlap for the last hour of Priya's (id 1) work day / the
// first hour of Marcus's (id 2) — required=[1,2], 2026-06-15..2026-06-19 viewed in
// Europe/London, 60-minute slots. A signed-in read returns 200 and the exact set
// of candidate slots the finder computes, decoded back through the shared codec.
pub fn find_a_time_signed_in_read_returns_candidate_slots_test() {
  let response =
    simulate.request(
      http.Get,
      "/api/meetings/find-a-time?from=2026-06-15&to=2026-06-19&tz=Europe%2FLondon&duration=60&required=1,2",
    )
    |> read()

  assert response.status == 200

  let slots = decode_candidate_slots(response)
  assert list.map(slots, fn(slot) { #(slot.starts_at, slot.ends_at) })
    == [
      #("2026-06-15T23:00:00Z", "2026-06-16T00:00:00Z"),
      #("2026-06-16T23:00:00Z", "2026-06-17T00:00:00Z"),
      #("2026-06-17T23:00:00Z", "2026-06-18T00:00:00Z"),
      #("2026-06-18T23:00:00Z", "2026-06-19T00:00:00Z"),
    ]
}

// A principal without read.engineers is refused the finder read with 403.
pub fn find_a_time_forbidden_for_unauthorized_role_is_403_test() {
  let context = ctx()

  let #(login_request, login_response) = sign_in(context, "Priya Sharma")
  let response =
    simulate.request(
      http.Get,
      "/api/meetings/find-a-time?from=2026-06-15&to=2026-06-19&tz=Europe%2FLondon&duration=60&required=1,2",
    )
    |> simulate.session(login_request, login_response)
    |> router.handle_request(context)

  assert response.status == 403
  assert decode_error_code(response) == "forbidden"
}

// A missing `required` is a 400, not a 500.
pub fn find_a_time_without_required_is_bad_request_test() {
  let response =
    simulate.request(
      http.Get,
      "/api/meetings/find-a-time?from=2026-06-15&to=2026-06-19&tz=Europe%2FLondon&duration=60",
    )
    |> read()

  assert response.status == 400
}

// An unrecognised timezone is a 400.
pub fn find_a_time_with_unknown_timezone_is_bad_request_test() {
  let response =
    simulate.request(
      http.Get,
      "/api/meetings/find-a-time?from=2026-06-15&to=2026-06-19&tz=Mars%2FOlympus_Mons&duration=60&required=1,2",
    )
    |> read()

  assert response.status == 400
}

// --- GET /api/meetings/find-a-time/project-team ------------------------------

// Project 300 (seeded) has engineers 2 (Marcus) and 3 (Aisha) allocated across
// 2025-01-01..2027-01-01, plus three bench engineers (#40 Phase 3 Stage 1) whose
// allocations cover the seed "now": 6 (Mei), 8 (Rohan), 9 (Dmitri) — so an as-of
// read on 2026-06-15 returns all five, ids ascending — the "Fill from project"
// wizard affordance's data source.
pub fn find_a_time_project_team_returns_the_seeded_allocation_test() {
  let response =
    simulate.request(
      http.Get,
      "/api/meetings/find-a-time/project-team?project_id=300&as_of=2026-06-15",
    )
    |> read()

  assert response.status == 200
  assert decode_int_list(response) == [2, 3, 6, 8, 9]
}

// --- GET /api/engineers/:id/availability, GET /api/holidays -----------------

// As of 2026-07-05, Priya (id 1) has her seeded default 9-17 Mon-Thu, her Friday
// dropped from 2026-07-01, no hours on the weekend, and (relocated to London from
// 2026-07-01) the seeded GB "Summer Bank Holiday" among her upcoming holidays.
pub fn availability_returns_priyas_weekly_grid_and_holidays_test() {
  let response =
    simulate.request(http.Get, "/api/engineers/1/availability?as_of=2026-07-05")
    |> read()

  assert response.status == 200

  let record = decode_availability(response)
  assert list.length(record.week) == 7

  let assert Ok(monday) = list.find(record.week, fn(slot) { slot.weekday == 0 })
  assert monday.starts == option.Some("09:00")
  assert monday.ends == option.Some("17:00")

  let assert Ok(friday) = list.find(record.week, fn(slot) { slot.weekday == 4 })
  assert friday.starts == option.None
  assert friday.ends == option.None

  let assert Ok(saturday) =
    list.find(record.week, fn(slot) { slot.weekday == 5 })
  assert saturday.starts == option.None

  let assert Ok(sunday) = list.find(record.week, fn(slot) { slot.weekday == 6 })
  assert sunday.starts == option.None

  assert list.any(record.holidays, fn(holiday) {
    holiday.name == "Summer Bank Holiday"
  })
}

// As of 2026-06-16, Marcus's (id 2) seeded focus block reads its America/Los_Angeles
// PDT offset, and his Los Angeles holidays include both the nationwide and
// California-specific rows.
pub fn availability_returns_marcuss_focus_block_and_holidays_test() {
  let response =
    simulate.request(http.Get, "/api/engineers/2/availability?as_of=2026-06-16")
    |> read()

  assert response.status == 200

  let record = decode_availability(response)

  let assert Ok(block) =
    list.find(record.focus_blocks, fn(block) {
      block.title == "Deep work: incident review"
    })
  assert block.offset_minutes == option.Some(-420)

  assert list.any(record.holidays, fn(holiday) {
    holiday.name == "California Admission Day"
  })
  assert list.any(record.holidays, fn(holiday) {
    holiday.name == "Thanksgiving"
  })
}

// The 5 seeded 2026 holidays, each paired with its region's display name.
pub fn holidays_listing_includes_region_names_test() {
  let response =
    simulate.request(http.Get, "/api/holidays?as_of=2026-07-05")
    |> read()

  assert response.status == 200

  let listings = decode_holiday_listings(response)
  assert list.length(listings) == 5

  let assert Ok(labour_day) =
    list.find(listings, fn(listing) {
      listing.holiday_on == calendar.Date(2026, calendar.October, 5)
    })
  assert labour_day.region_name == "New South Wales"
}

// A principal without read.engineers is refused the holidays read with 403.
pub fn holidays_forbidden_for_unauthorized_role_is_403_test() {
  let context = ctx()

  let #(login_request, login_response) = sign_in(context, "Priya Sharma")
  let response =
    simulate.request(http.Get, "/api/holidays?as_of=2026-07-05")
    |> simulate.session(login_request, login_response)
    |> router.handle_request(context)

  assert response.status == 403
  assert decode_error_code(response) == "forbidden"
}

// --- static / fallthrough ---------------------------------------------------

// An unknown NON-API path serves the SPA shell (200), so client routes like
// /people/5 resolve on a cold load — the history-API fallback (FR-U4).
pub fn unknown_client_path_serves_the_spa_shell_test() {
  let response =
    simulate.request(http.Get, "/no/such/route")
    |> read()

  assert response.status == 200
}

// An unmatched /api/* path is still a genuine 404, not the SPA shell.
pub fn unknown_api_path_is_not_found_test() {
  let response =
    simulate.request(http.Get, "/api/no-such-endpoint")
    |> read()

  assert response.status == 404
}

// --- helpers ----------------------------------------------------------------

fn decode_board(response) -> BoardSnapshot {
  let assert Ok(snapshot) =
    simulate.read_body(response)
    |> json.parse(board_view.board_snapshot_decoder())
  snapshot
}

fn decode_timesheet(response) -> TimesheetWeek {
  let assert Ok(week) =
    simulate.read_body(response)
    |> json.parse(timesheet_view.timesheet_week_decoder())
  week
}

fn decode_people(response) -> PeopleList {
  let assert Ok(list) =
    simulate.read_body(response)
    |> json.parse(people_view.people_list_decoder())
  list
}

fn decode_engineer_detail(response) -> EngineerDetail {
  let assert Ok(detail) =
    simulate.read_body(response)
    |> json.parse(engineer_view.engineer_detail_decoder())
  detail
}

fn decode_invoice_page(response) -> InvoicePage {
  let assert Ok(page) =
    simulate.read_body(response)
    |> json.parse(invoice_view.invoice_page_decoder())
  page
}

fn decode_table(response) -> table_response.TableResponse {
  let assert Ok(table) =
    simulate.read_body(response)
    |> json.parse(table_response.response_decoder())
  table
}

fn decode_client_list(response) -> ClientList {
  let assert Ok(list) =
    simulate.read_body(response)
    |> json.parse(client_view.client_list_decoder())
  list
}

fn decode_client_detail(response) -> ClientDetail {
  let assert Ok(detail) =
    simulate.read_body(response)
    |> json.parse(client_view.client_detail_decoder())
  detail
}

fn decode_project_list(response) -> ProjectList {
  let assert Ok(list) =
    simulate.read_body(response)
    |> json.parse(project_view.project_list_decoder())
  list
}

fn decode_project_detail(response) -> ProjectDetail {
  let assert Ok(detail) =
    simulate.read_body(response)
    |> json.parse(project_view.project_detail_decoder())
  detail
}

fn decode_coverage_snapshot(response) -> CoverageSnapshot {
  let assert Ok(snapshot) =
    simulate.read_body(response)
    |> json.parse(project_capability_view.coverage_snapshot_decoder())
  snapshot
}

fn decode_gap_recommendations_list(response) -> List(GapRecommendations) {
  let assert Ok(gaps) =
    simulate.read_body(response)
    |> json.parse(
      decode.list(project_capability_view.gap_recommendations_decoder()),
    )
  gaps
}

fn decode_settings(response) -> Settings {
  let assert Ok(settings) =
    simulate.read_body(response)
    |> json.parse(settings_view.settings_decoder())
  settings
}

fn decode_meetings(response) -> List(MeetingRecord) {
  let assert Ok(meetings) =
    simulate.read_body(response)
    |> json.parse(decode.list(meeting_view.meeting_record_decoder()))
  meetings
}

fn decode_candidate_slots(response) -> List(CandidateSlot) {
  let assert Ok(slots) =
    simulate.read_body(response)
    |> json.parse(decode.list(meeting_view.candidate_slot_decoder()))
  slots
}

fn decode_int_list(response) -> List(Int) {
  let assert Ok(ids) =
    simulate.read_body(response)
    |> json.parse(decode.list(decode.int))
  ids
}

fn decode_availability(response) -> AvailabilityRecord {
  let assert Ok(record) =
    simulate.read_body(response)
    |> json.parse(availability_view.availability_record_decoder())
  record
}

fn decode_holiday_listings(response) -> List(HolidayListing) {
  let assert Ok(listings) =
    simulate.read_body(response)
    |> json.parse(decode.list(availability_view.holiday_listing_decoder()))
  listings
}

fn decode_taxonomy_snapshot(response) -> TaxonomySnapshot {
  let assert Ok(snapshot) =
    simulate.read_body(response)
    |> json.parse(skill_view.taxonomy_snapshot_decoder())
  snapshot
}

fn decode_engineer_skills(response) -> EngineerSkills {
  let assert Ok(skills) =
    simulate.read_body(response)
    |> json.parse(skill_view.engineer_skills_decoder())
  skills
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

fn decode_events(response) -> List(gateway.CommittedEvent) {
  let assert Ok(events) =
    simulate.read_body(response)
    |> json.parse(decode.list(gateway.committed_event_decoder()))
  events
}

fn decode_event_page(response) -> gateway.EventPage {
  let assert Ok(page) =
    simulate.read_body(response)
    |> json.parse(gateway.event_page_decoder())
  page
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
