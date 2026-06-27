//// Layer-2 operation tests for the financial aggregates (PRD-financials.md §7).
//// Apply each financial command to a known state, then assert the resulting facts
//// AND the `event_log` row (operation/summary/payload, never `occurred_at`).
////
//// ISOLATION (same as operations_test.gleam). Each test runs its OWN
//// `pog.transaction`, builds a minimal test-local fixture, drives the operation
//// through `command.dispatch_in`, reads the resulting facts/journal back, then
//// returns `Error(…)` so the whole transaction rolls back — the migrated+seeded
//// state the read-only tests rely on is never mutated.
////
//// Fixture levels are L1/L2 only — the levels the seed leaves EMPTY in `rate_card`
//// and `salary` (the seed populates L3..L6). Since both tables are keyed
//// `WITHOUT OVERLAPS (level)`, using L1/L2 lets a test insert its own rate-card and
//// salary versions without colliding with the seed. Entity ids (engineer, contract,
//// project, invoice, run) are minted by the fixture/operation or pinned to high,
//// test-local literals well clear of the seed range.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/time/calendar.{type Date, August, Date, July, June, March}
import pog
import shared/command.{type Command} as gateway
import shared/invoice/command as invoice_command
import shared/money.{type Money}
import shared/payroll/command as payroll_command
import shared/payroll/view as payroll_view
import shared/rate_card/command as rate_card_command
import shared/salary/command as salary_command
import tempo/server/command
import tempo/server/context.{Context}
import tempo/server/operation
import tempo/server/payroll/view as payroll_read
import test_pool

// --- rollback harness -------------------------------------------------------

/// Run `body` inside a transaction, then roll back, smuggling its return value out
/// through `TransactionRolledBack` so the seed is never mutated.
fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

/// Apply `command` through the dispatch seam on `conn`, asserting it succeeds.
fn apply(conn: pog.Connection, command: Command) -> Nil {
  let assert Ok(_) = command.dispatch_in(conn, "tester", command)
  Nil
}

fn money_of(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

/// Run a parameterless statement, asserting it succeeds. Used for raw fixture
/// inserts the test sets up before the operation under test runs.
fn exec(conn: pog.Connection, sql: String) -> Nil {
  let assert Ok(_) =
    pog.query(sql)
    |> pog.execute(on: conn)
  Nil
}

/// Insert an engineer (ID-ONLY anchor) plus a founding engineer_contact row
/// carrying `name`, and return the minted id. The name now lives in the contact
/// fact (read via the engineer_current view), not on the anchor.
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

/// Insert a client and return its minted id.
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
      "INSERT INTO client_profile "
      <> "(client_id, name, recorded_during) "
      <> "VALUES ($1, $2, daterange('2024-01-01', NULL, '[)'))",
    )
    |> pog.parameter(pog.int(id))
    |> pog.parameter(pog.text(name))
    |> pog.execute(on: conn)
  id
}

// --- read-back helpers ------------------------------------------------------

/// One invoice line read back for exact assertion (the snapshot the draft computed).
type Line {
  Line(
    engineer: String,
    level: Int,
    day_rate: Float,
    days: Float,
    amount: Float,
  )
}

/// Read an invoice's snapshot lines back, joined to engineer name, ordered as the
/// billing query emits them (engineer, level).
fn read_invoice_lines(conn: pog.Connection, invoice_id: Int) -> List(Line) {
  let decoder = {
    use engineer <- decode.field(0, decode.string)
    use level <- decode.field(1, decode.int)
    use day_rate <- decode.field(2, pog.numeric_decoder())
    use days <- decode.field(3, pog.numeric_decoder())
    use amount <- decode.field(4, pog.numeric_decoder())
    decode.success(Line(engineer:, level:, day_rate:, days:, amount:))
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT e.name, il.level, il.day_rate, il.days, il.amount
         FROM invoice_line il JOIN engineer_current e ON e.id = il.engineer_id
        WHERE il.invoice_id = $1
        ORDER BY e.name, il.level",
    )
    |> pog.parameter(pog.int(invoice_id))
    |> pog.returning(decoder)
    |> pog.execute(on: conn)
  returned.rows
}

/// The status of an invoice covering a given date (the as-of read). Returns "" when
/// no status row covers the date.
fn status_as_of(conn: pog.Connection, invoice_id: Int, on: Date) -> String {
  let decoder = {
    use status <- decode.field(0, decode.string)
    decode.success(status)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT status FROM invoice_status
        WHERE invoice_id = $1 AND status_during @> $2::date",
    )
    |> pog.parameter(pog.int(invoice_id))
    |> pog.parameter(pog.calendar_date(on))
    |> pog.returning(decoder)
    |> pog.execute(on: conn)
  case returned.rows {
    [status, ..] -> status
    [] -> ""
  }
}

/// One payroll line read back for exact assertion: the engineer's prorated amount
/// and employed days for the run.
type PayLine {
  PayLine(engineer: String, amount: Float, days: Float)
}

/// Read a run's payroll lines back for the named engineers only (the seed's own
/// engineers also get lines from `payroll_amounts`; the test asserts on its own).
fn read_payroll_lines(
  conn: pog.Connection,
  run_id: Int,
  names: List(String),
) -> List(PayLine) {
  let decoder = {
    use engineer <- decode.field(0, decode.string)
    use amount <- decode.field(1, pog.numeric_decoder())
    use days <- decode.field(2, pog.numeric_decoder())
    decode.success(PayLine(engineer:, amount:, days:))
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT e.name, pl.amount, pl.days
         FROM payroll_line pl JOIN engineer_current e ON e.id = pl.engineer_id
        WHERE pl.run_id = $1 AND e.name = ANY($2)
        ORDER BY e.name",
    )
    |> pog.parameter(pog.int(run_id))
    |> pog.parameter(pog.array(pog.text, names))
    |> pog.returning(decoder)
    |> pog.execute(on: conn)
  returned.rows
}

/// One persisted payroll segment read back for exact assertion: the level, the
/// monthly salary in force, the pro-rated days, and the amount at that level.
type PaySegment {
  PaySegment(level: Int, monthly_salary: Float, days: Float, amount: Float)
}

/// Read a run's frozen per-level segments back for one engineer, ascending by level.
fn read_payroll_segments(
  conn: pog.Connection,
  run_id: Int,
  name: String,
) -> List(PaySegment) {
  let decoder = {
    use level <- decode.field(0, decode.int)
    use monthly_salary <- decode.field(1, pog.numeric_decoder())
    use days <- decode.field(2, pog.numeric_decoder())
    use amount <- decode.field(3, pog.numeric_decoder())
    decode.success(PaySegment(level:, monthly_salary:, days:, amount:))
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT pls.level, pls.monthly_salary, pls.days, pls.amount
         FROM payroll_line_segment pls
         JOIN engineer_current e ON e.id = pls.engineer_id
        WHERE pls.run_id = $1 AND e.name = $2
        ORDER BY pls.level",
    )
    |> pog.parameter(pog.int(run_id))
    |> pog.parameter(pog.text(name))
    |> pog.returning(decoder)
    |> pog.execute(on: conn)
  returned.rows
}

/// One journal row, minus the real-clock `occurred_at` (never asserted).
type Journal {
  Journal(actor: String, operation: String, summary: String, payload: String)
}

/// Read this transaction's `event_log` rows newest-first. The seed records its
/// founding history under actor `seed`; these tests dispatch under `tester`, so the
/// `actor <> 'seed'` filter isolates the rows this test wrote.
fn read_journal(conn: pog.Connection) -> List(Journal) {
  let decoder = {
    use actor <- decode.field(0, decode.string)
    use operation <- decode.field(1, decode.string)
    use summary <- decode.field(2, decode.string)
    use payload <- decode.field(3, decode.string)
    decode.success(Journal(actor:, operation:, summary:, payload:))
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT actor, operation, summary, payload::text FROM event_log"
      <> " WHERE actor <> 'seed' ORDER BY id DESC",
    )
    |> pog.returning(decoder)
    |> pog.execute(on: conn)
  returned.rows
}

/// The id of the most-recently minted invoice for a project (the test project owns
/// exactly one).
fn invoice_id_for_project(conn: pog.Connection, project_id: Int) -> Int {
  let row_decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT invoice_id FROM invoice_subject WHERE project_id = $1 ORDER BY invoice_id DESC",
    )
    |> pog.parameter(pog.int(project_id))
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  id
}

/// The id of the most-recently minted payroll run covering a period start.
fn run_id_covering(conn: pog.Connection, period_start: Date) -> Int {
  let row_decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT run_id FROM payroll_period WHERE period @> $1::date ORDER BY run_id DESC",
    )
    |> pog.parameter(pog.calendar_date(period_start))
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  id
}

// --- fixtures ---------------------------------------------------------------

/// Set up one L1 engineer fully allocated to a fresh project for the whole of 2026,
/// under a contract signed on 2026-01-01, with an L1 rate card at `rate` open-ended
/// from 2024. Returns the minted `#(engineer_id, project_id)`. This is the billing
/// fixture: the contract's agreed date is 2026-01-01.
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
    "INSERT INTO rate_card (level, day_rate, effective_during) VALUES "
      <> "(1, "
      <> rate
      <> ", daterange('2024-01-01', NULL, '[)'))",
  )
  // Contract = anchor + terms; the term (and client_id) live in contract_terms.
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
  // Project = anchor + run + profile; the NAME ('Test Project') is the profile
  // title so the billing reads resolve it through project_current.
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

// --- SetSalary — the cost-rate Change (FOR PORTION OF, like ReviseRateCard) ---

/// Read a level's salary versions back as `(monthly_salary, from, to)` ordered by
/// start; an open-ended upper renders as "".
fn read_salary(
  conn: pog.Connection,
  level: Int,
) -> List(#(String, String, String)) {
  let decoder = {
    use salary <- decode.field(0, decode.string)
    use from <- decode.field(1, decode.string)
    use to <- decode.field(2, decode.string)
    decode.success(#(salary, from, to))
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT monthly_salary::text, lower(effective_during)::text,
              coalesce(upper(effective_during)::text, '')
         FROM salary WHERE level = $1 ORDER BY lower(effective_during)",
    )
    |> pog.parameter(pog.int(level))
    |> pog.returning(decoder)
    |> pog.execute(on: conn)
  returned.rows
}

// SetSalary re-rates a level from a date onward (the Change pattern, the cost
// analogue of ReviseRateCard): it splits the version covering the effective date —
// the new salary lands on [effective, upper) and the [lower, effective) leftover
// keeps the OLD salary — and records one journal row. Uses L1 (empty in the seed)
// with a test-local baseline so there is a version to revise.
pub fn set_salary_caps_the_level_from_the_effective_date_test() {
  let #(salaries, journal) =
    rolling_back(fn(conn) {
      // Baseline L1 salary 3000 open-ended from Jan (the version SetSalary revises).
      // Clear the seed's L1 salary first so this test owns the level's band.
      exec(conn, "DELETE FROM salary WHERE level = 1")
      exec(
        conn,
        "INSERT INTO salary (level, monthly_salary, effective_during) VALUES "
          <> "(1, 3000.00, daterange('2026-01-01', NULL, '[)'))",
      )
      // Raise L1 to 3500 effective Jul — splits the open version at Jul.
      apply(
        conn,
        gateway.SalaryCommand(salary_command.SetSalary(
          1,
          money_of("3500.00"),
          Date(2026, July, 1),
        )),
      )
      #(read_salary(conn, 1), read_journal(conn))
    })

  // 3000 leftover [Jan,Jul), revised 3500 [Jul,∞).
  assert salaries
    == [
      #("3000.00", "2026-01-01", "2026-07-01"),
      #("3500.00", "2026-07-01", ""),
    ]
  // Exactly one journal row: the salary revision.
  let assert [row] = journal
  assert row.actor == "tester"
  assert row.operation == "set_salary"
  // float.to_string renders 3500.0 in scientific form (matching rate_card summaries).
  assert row.summary == "Set L1 salary to 3500.00 from 2026-07-01"
  assert json.parse(row.payload, gateway.command_decoder())
    == Ok(
      gateway.SalaryCommand(salary_command.SetSalary(
        1,
        money_of("3500.00"),
        Date(2026, July, 1),
      )),
    )
}

// --- DraftInvoice — agreed-rate billing (FR-F2, the temporal centerpiece) ----

// DraftInvoice computes its lines at the rate the CONTRACT agreed (rate_card as of
// lower(contract.term) = 2026-01-01), NOT the current rate. A later
// ReviseRateCard that raises L1 from March 2026 does not change the billed rate:
// the June invoice still bills the old agreed 800, days = 30 (June), amount = 24000.
pub fn draft_invoice_bills_the_agreed_rate_after_a_later_revision_test() {
  let #(lines, status, journal, project_id, invoice_id) =
    rolling_back(fn(conn) {
      let _engineer_id =
        billing_fixture(
          conn,
          "Ada Lovelace",
          "Babbage Engines",
          90_101,
          80_101,
          "800.00",
        )
      // Raise L1 to 9999 effective March 2026 — AFTER the contract's agreed date.
      apply(
        conn,
        gateway.RateCardCommand(rate_card_command.ReviseRateCard(
          1,
          money_of("9999.00"),
          Date(2026, March, 1),
        )),
      )
      // Draft June 2026 — billed at the agreed (older) 800, not 9999.
      apply(
        conn,
        gateway.InvoiceCommand(invoice_command.DraftInvoice(
          80_101,
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
      let invoice_id = invoice_id_for_project(conn, 80_101)
      #(
        read_invoice_lines(conn, invoice_id),
        status_as_of(conn, invoice_id, Date(2026, June, 15)),
        read_journal(conn),
        80_101,
        invoice_id,
      )
    })

  // One line at the agreed rate: 800/day × 30 days (June) × fraction 1.0 = 24000.
  assert lines == [Line("Ada Lovelace", 1, 800.0, 30.0, 24_000.0)]
  // The drafted invoice reads `draft` as of a date inside the billing month.
  assert status == "draft"
  // The newest journal row is the draft (the rate revision precedes it).
  let assert [row, ..] = journal
  assert row.actor == "tester"
  assert row.operation == "draft_invoice"
  assert row.summary
    == "Draft invoice for project "
    <> int.to_string(project_id)
    <> " (invoice "
    <> int.to_string(invoice_id)
    <> ") over 2026-06-01..2026-07-01"
  assert json.parse(row.payload, gateway.command_decoder())
    == Ok(
      gateway.InvoiceCommand(invoice_command.DraftInvoice(
        project_id,
        Date(2026, June, 1),
        Date(2026, July, 1),
      )),
    )
}

// --- Issue / Pay — the temporal status lifecycle (FR-F3, FR-F4) --------------

// IssueInvoice moves draft → issued and PayInvoice moves issued → paid, each a
// temporal status Change (cap the current span, open the next). The status read
// AS OF a date reflects the lifecycle: draft before the issue date, issued between
// issue and pay, paid after — scrubbing the date back shows the earlier state.
pub fn issue_then_pay_moves_status_as_of_the_transition_dates_test() {
  let #(before_issue, between, after_pay, journal_ops) =
    rolling_back(fn(conn) {
      let _engineer_id =
        billing_fixture(
          conn,
          "Grace Hopper",
          "Mark Computers",
          90_102,
          80_102,
          "800.00",
        )
      apply(
        conn,
        gateway.InvoiceCommand(invoice_command.DraftInvoice(
          80_102,
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
      let invoice_id = invoice_id_for_project(conn, 80_102)
      // draft from Jun 1; issue Jul 15; pay Aug 15.
      apply(
        conn,
        gateway.InvoiceCommand(invoice_command.IssueInvoice(
          invoice_id,
          Date(2026, July, 15),
        )),
      )
      apply(
        conn,
        gateway.InvoiceCommand(invoice_command.PayInvoice(
          invoice_id,
          Date(2026, August, 15),
        )),
      )
      #(
        // before the issue date: still draft
        status_as_of(conn, invoice_id, Date(2026, June, 20)),
        // between issue and pay: issued
        status_as_of(conn, invoice_id, Date(2026, July, 20)),
        // after the pay date: paid
        status_as_of(conn, invoice_id, Date(2026, August, 20)),
        list.map(read_journal(conn), fn(row) { row.operation }),
      )
    })

  assert before_issue == "draft"
  assert between == "issued"
  assert after_pay == "paid"
  // Newest-first: pay, issue, draft (the fixture writes nothing to the journal).
  assert journal_ops == ["pay_invoice", "issue_invoice", "draft_invoice"]
}

// PayInvoice on a freshly DRAFTED invoice is an out-of-order transition: the status
// covering the date is `draft`, not the expected predecessor `issued`, so the
// command is rejected as InvalidValue (the guard fires before any write).
pub fn pay_invoice_on_a_draft_is_rejected_as_out_of_order_test() {
  let outcome =
    rolling_back(fn(conn) {
      let _engineer_id =
        billing_fixture(
          conn,
          "Edsger Dijkstra",
          "THE Systems",
          90_103,
          80_103,
          "800.00",
        )
      apply(
        conn,
        gateway.InvoiceCommand(invoice_command.DraftInvoice(
          80_103,
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
      let invoice_id = invoice_id_for_project(conn, 80_103)
      // Skip issuing — pay a draft directly.
      command.dispatch_in(
        conn,
        "tester",
        gateway.InvoiceCommand(invoice_command.PayInvoice(
          invoice_id,
          Date(2026, July, 15),
        )),
      )
    })

  assert outcome == Error(operation.InvalidValue)
}

// --- RunPayroll — proration of part-periods (FR-F5, FR-F6) -------------------

// RunPayroll prorates each engineer's salary over employment ∩ month, split by
// role+salary version. For June 2026 (30 days), at L1=3000 / L2=6000 monthly:
//   * full month, no leave    → 3000 over 30 days
//   * hired mid-month (Jun 16)→ 1500 over 15 days (clipped to employed days)
//   * terminated mid-month    → 1500 over 15 days (clipped)
//   * promoted L1→L2 mid-month→ 1500 (L1, 15d) + 3000 (L2, 15d) = 4500 over 30 days
//   * on leave second half    → 3000 over 30 days (leave is paid in FULL, ignored)
pub fn run_payroll_prorates_hires_terminations_promotions_and_leave_test() {
  let names = [
    "Pay Full", "Pay Hired", "Pay Terminated", "Pay Promoted", "Pay OnLeave",
  ]
  let #(lines, journal, run_id) =
    rolling_back(fn(conn) {
      // Baseline L1 / L2 cost rates (levels the seed leaves empty), open-ended
      // from 2024 — inserted directly, since SetSalary is a CHANGE (FOR PORTION
      // OF an existing version), not the baseline Assert.
      exec(conn, "DELETE FROM salary WHERE level IN (1, 2)")
      exec(
        conn,
        "INSERT INTO salary (level, monthly_salary, effective_during) VALUES "
          <> "(1, 3000.00, daterange('2024-01-01', NULL, '[)')), "
          <> "(2, 6000.00, daterange('2024-01-01', NULL, '[)'))",
      )

      // Full month at L1.
      let full = insert_engineer(conn, "Pay Full")
      employed_at(conn, full, "2026-01-01", "", level: 1, role_to: "")

      // Hired Jun 16 at L1.
      let hired = insert_engineer(conn, "Pay Hired")
      employed_at(conn, hired, "2026-06-16", "", level: 1, role_to: "")

      // Terminated Jun 16 (employment + role both capped at Jun 16).
      let terminated = insert_engineer(conn, "Pay Terminated")
      employed_at(
        conn,
        terminated,
        "2026-01-01",
        "2026-06-16",
        level: 1,
        role_to: "2026-06-16",
      )

      // Promoted L1 → L2 on Jun 16 (two role versions over open-ended employment).
      let promoted = insert_engineer(conn, "Pay Promoted")
      exec(
        conn,
        "INSERT INTO employment (engineer_id, employed_during) VALUES ("
          <> int.to_string(promoted)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES "
          <> "("
          <> int.to_string(promoted)
          <> ", 1, daterange('2026-01-01','2026-06-16')), "
          <> "("
          <> int.to_string(promoted)
          <> ", 2, daterange('2026-06-16', NULL, '[)'))",
      )

      // On leave the second half of June — paid in FULL (leave ignored).
      let on_leave = insert_engineer(conn, "Pay OnLeave")
      employed_at(conn, on_leave, "2026-01-01", "", level: 1, role_to: "")
      exec(
        conn,
        "INSERT INTO leave (engineer_id, kind, on_leave_during) VALUES ("
          <> int.to_string(on_leave)
          <> ", 'annual', daterange('2026-06-16','2026-07-01'))",
      )

      apply(
        conn,
        gateway.PayrollCommand(payroll_command.RunPayroll(
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
      let run_id = run_id_covering(conn, Date(2026, June, 15))
      #(read_payroll_lines(conn, run_id, names), read_journal(conn), run_id)
    })

  // Ordered by engineer name (read_payroll_lines ORDER BY e.name).
  assert lines
    == [
      PayLine("Pay Full", 3000.0, 30.0),
      PayLine("Pay Hired", 1500.0, 15.0),
      PayLine("Pay OnLeave", 3000.0, 30.0),
      PayLine("Pay Promoted", 4500.0, 30.0),
      PayLine("Pay Terminated", 1500.0, 15.0),
    ]
  // Exactly one journal row for the run; pin its summary/payload.
  let assert [row] = journal
  assert row.actor == "tester"
  assert row.operation == "run_payroll"
  assert row.summary
    == "Run payroll over 2026-06-01..2026-07-01 (run "
    <> int.to_string(run_id)
    <> ")"
  assert json.parse(row.payload, gateway.command_decoder())
    == Ok(
      gateway.PayrollCommand(payroll_command.RunPayroll(
        Date(2026, June, 1),
        Date(2026, July, 1),
      )),
    )
}

// RunPayroll freezes the per-level breakdown (#23): an engineer promoted L1 -> L2
// mid-June (Jun 16) has their June line split into two payroll_line_segment rows —
// L1 over the first 15 days at 3000/mo (1500) and L2 over the last 15 days at
// 6000/mo (3000) — which sum back to the 4500 / 30-day payroll_line total. The
// read model surfaces the same split on BOTH sides: the frozen `paid_segments` and
// the live `preview_segments` (reconciled, nothing back-dated).
pub fn run_payroll_freezes_per_level_segments_test() {
  let #(line, segments, read_line) =
    rolling_back(fn(conn) {
      exec(conn, "DELETE FROM salary WHERE level IN (1, 2)")
      exec(
        conn,
        "INSERT INTO salary (level, monthly_salary, effective_during) VALUES "
          <> "(1, 3000.00, daterange('2024-01-01', NULL, '[)')), "
          <> "(2, 6000.00, daterange('2024-01-01', NULL, '[)'))",
      )

      let promoted = insert_engineer(conn, "Seg Promoted")
      exec(
        conn,
        "INSERT INTO employment (engineer_id, employed_during) VALUES ("
          <> int.to_string(promoted)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES "
          <> "("
          <> int.to_string(promoted)
          <> ", 1, daterange('2026-01-01','2026-06-16')), "
          <> "("
          <> int.to_string(promoted)
          <> ", 2, daterange('2026-06-16', NULL, '[)'))",
      )

      apply(
        conn,
        gateway.PayrollCommand(payroll_command.RunPayroll(
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
      let run_id = run_id_covering(conn, Date(2026, June, 15))
      let assert Ok(payroll) =
        payroll_read.payroll(
          Context(db: conn, principal: None),
          Date(2026, June, 1),
          Date(2026, July, 1),
        )
      let assert Ok(read_line) =
        list.find(payroll.lines, fn(line) { line.engineer == "Seg Promoted" })
      #(
        read_payroll_lines(conn, run_id, ["Seg Promoted"]),
        read_payroll_segments(conn, run_id, "Seg Promoted"),
        read_line,
      )
    })

  // The collapsed line is the full month at the blended total.
  assert line == [PayLine("Seg Promoted", 4500.0, 30.0)]
  // The frozen breakdown is one row per level, ascending, summing to the line.
  assert segments
    == [
      PaySegment(level: 1, monthly_salary: 3000.0, days: 15.0, amount: 1500.0),
      PaySegment(level: 2, monthly_salary: 6000.0, days: 15.0, amount: 3000.0),
    ]
  // The read model carries the split on both sides (reconciled: paid == preview).
  let expected_segments = [
    payroll_view.PayrollSegment(
      1,
      15.0,
      money_of("3000.00"),
      money_of("1500.00"),
    ),
    payroll_view.PayrollSegment(
      2,
      15.0,
      money_of("6000.00"),
      money_of("3000.00"),
    ),
  ]
  assert read_line.paid_segments == expected_segments
  assert read_line.preview_segments == expected_segments
}

// A second run whose period overlaps an existing run is rejected by the
// payroll_period_no_overlap exclusion — payroll cannot be run twice for a month.
pub fn running_payroll_twice_for_a_month_is_rejected_test() {
  let outcome =
    rolling_back(fn(conn) {
      exec(conn, "DELETE FROM salary WHERE level = 1")
      exec(
        conn,
        "INSERT INTO salary (level, monthly_salary, effective_during) VALUES "
          <> "(1, 3000.00, daterange('2024-01-01', NULL, '[)'))",
      )
      let engineer = insert_engineer(conn, "Pay Once")
      employed_at(conn, engineer, "2026-01-01", "", level: 1, role_to: "")

      // First run for June succeeds; a second run for the same month must be refused.
      apply(
        conn,
        gateway.PayrollCommand(payroll_command.RunPayroll(
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
      command.dispatch_in(
        conn,
        "tester",
        gateway.PayrollCommand(payroll_command.RunPayroll(
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
    })

  assert outcome == Error(operation.OverlappingFact)
}

/// Insert an employed engineer with one role version. `employed_to`/`role_to` are
/// "" for an open-ended span. `level` is the role level. Used by the payroll
/// fixtures (the full-month, hired, terminated, and on-leave engineers).
fn employed_at(
  conn: pog.Connection,
  engineer_id: Int,
  employed_from: String,
  employed_to: String,
  level level: Int,
  role_to role_to: String,
) -> Nil {
  exec(
    conn,
    "INSERT INTO employment (engineer_id, employed_during) VALUES ("
      <> int.to_string(engineer_id)
      <> ", "
      <> daterange(employed_from, employed_to)
      <> ")",
  )
  exec(
    conn,
    "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES ("
      <> int.to_string(engineer_id)
      <> ", "
      <> int.to_string(level)
      <> ", "
      <> daterange(employed_from, role_to)
      <> ")",
  )
  Nil
}

/// A SQL daterange literal `[from, to)`; an empty `to` is the open-ended NULL upper.
fn daterange(from: String, to: String) -> String {
  case to {
    "" -> "daterange('" <> from <> "', NULL, '[)')"
    _ -> "daterange('" <> from <> "', '" <> to <> "')"
  }
}
