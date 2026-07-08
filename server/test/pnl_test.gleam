//// Layer-3 financial READ tests (PRD-financials.md §7) for the domain query
//// functions in `tempo/server/{invoice,payroll,pnl}/view`. They run against the deterministic
//// v1-wide seed ("now" = 2026-06-15) plus the baseline salaries migration 012
//// seeds (L3..L6), drive the financial WRITES through the command bus to put
//// invoices and payroll on record, then assert the exact read-model values: the
//// invoices table (status as-of, total), an invoice's snapshot lines, the payroll
//// run, and the P&L month/YTD totals + a per-engineer row.
////
//// ISOLATION (as in financials_test.gleam). Each test runs inside its OWN
//// `pog.transaction` that is always rolled back: it applies the writes via
//// `command.dispatch_in`, reads back through the per-concept read functions (given
//// a `Context` wrapping the same in-transaction connection), then returns
//// `Error(…)` so nothing is committed and the shared seed is undisturbed.
////
//// THE NUMBERS (June 2026, 30 days; agreed rate = rate_card as of lower(contract.term)).
//// The recommender bench (#40 Phase 3 Stage 1, engineers 4-11, employed from
//// 2026-01-01) adds allocations on projects 200/300 and, being employed, a payroll
//// line each — both folded in below:
////   * billing project 100 (Ledger, contract signed 2024): Priya L5 @1200 × 0.5 × 30
////     = 18000 (no bench engineer touches project 100)
////   * billing project 200 (Inventory, contract signed 2024): Priya L5 @1200 × 0.5 ×
////     30 = 18000, Omar L4 @1000 × 0.6 × 30 = 18000, Tunde L3 @800 × 0.8 × 30 =
////     19200 (total 55200)
////   * billing project 300 (Data, contract signed 2025): Marcus L4 @1000 × 30 =
////     30000, Aisha L6 @1800 × 30 = 54000, Mei L5 @1200 × 30 = 36000, Rohan L2 @600
////     × 0.5 × 30 = 9000, Dmitri L2 @600 × 30 = 18000 (total 147000)
////   * payroll June, all 11 employed engineers at their June level: Priya 10000,
////     Marcus 8000, Aisha 14000, Omar 8000, Sofia 8000, Mei 10000, Tunde 6000,
////     Rohan 4000, Dmitri 4000, Jonas 6000, Hannah 14000 (cost 92000)
//// So month revenue = 18000 + 55200 + 147000 = 220200; month cost = 92000; month
//// profit = 128200. Priya/Marcus/Aisha stay 100% utilized (full-month allocation),
//// unchanged from before the bench.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar.{type Date, Date, July, June, September}
import pog
import serial_pool
import shared/command as gateway
import shared/invoice/command as invoice_command
import shared/invoice/status.{Draft, Issued}
import shared/invoice/view.{type Invoice, Invoice, InvoiceDetail, InvoiceLine} as _
import shared/money.{type Money}
import shared/payroll/command as payroll_command
import shared/payroll/view.{Payroll, PayrollLine, PayrollRunInfo, PayrollSegment} as _
import shared/pnl/view.{type PnlRow, PnlRow} as _
import tempo/server/command
import tempo/server/context.{Context}
import tempo/server/invoice/view as invoice_read
import tempo/server/payroll/view as payroll_read
import tempo/server/pnl/view as pnl_read
import tempo/server/web/cursor
import test_pool

fn money_of(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

// --- rollback harness -------------------------------------------------------

/// Run `body` inside a transaction, then roll back, smuggling its return value out
/// through `TransactionRolledBack` so the seed is never mutated.
fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

/// Apply a command through the dispatch seam on `conn`, asserting it succeeds.
fn apply(conn: pog.Connection, command) -> Nil {
  let assert Ok(_) = command.dispatch_in(conn, "tester", command)
  Nil
}

/// Draft an invoice for a seed project's June 2026 month and issue it on
/// `issue_on`, returning the minted invoice id.
fn draft_and_issue(
  conn: pog.Connection,
  project_id: Int,
  issue_on: Date,
) -> Int {
  apply(
    conn,
    gateway.InvoiceCommand(invoice_command.DraftInvoice(
      project_id,
      Date(2026, June, 1),
      Date(2026, July, 1),
    )),
  )
  let invoice_id = newest_invoice_for_project(conn, project_id)
  apply(
    conn,
    gateway.InvoiceCommand(invoice_command.IssueInvoice(invoice_id, issue_on)),
  )
  invoice_id
}

/// The id of the most-recently minted invoice for a project (the seed has none, so
/// the test owns exactly one per project).
fn newest_invoice_for_project(conn: pog.Connection, project_id: Int) -> Int {
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

/// Find a P&L row for an engineer by name (the per-engineer breakdown is keyed by
/// name; the seed names are unique).
fn row_for(rows: List(PnlRow), engineer: String) -> PnlRow {
  let assert Ok(row) = list.find(rows, fn(row) { row.engineer == engineer })
  row
}

/// Find an invoice for a project by name in the list (the test's projects are
/// distinct).
fn invoice_for(invoices: List(Invoice), project: String) -> Invoice {
  let assert Ok(invoice) =
    list.find(invoices, fn(invoice) { invoice.project == project })
  invoice
}

// --- GET /api/invoices (list, ?as_of=) — FR-F1/FR-F4 ------------------------

// After drafting + issuing the three June invoices, the list (as of a date inside
// the month, after issue) shows each with the correct project/client, billing
// month, status `issued`, and line total. Project 300's total is Marcus 30000 +
// Aisha 54000 + Mei 36000 + Rohan 9000 + Dmitri 18000 = 147000 (the bench's Mei,
// Rohan, Dmitri are also allocated there — #40 Phase 3 Stage 1); project 100 is
// 18000 (Priya half-time, untouched by the bench).
pub fn list_invoices_shows_status_and_total_test() {
  let invoices =
    rolling_back(fn(conn) {
      let _ = draft_and_issue(conn, 100, Date(2026, June, 10))
      let _ = draft_and_issue(conn, 200, Date(2026, June, 10))
      let _ = draft_and_issue(conn, 300, Date(2026, June, 10))
      let assert Ok(#(invoices, _)) =
        invoice_read.list_invoices(
          Context(db: conn, principal: None),
          Date(2026, June, 15),
          cursor.date_id_start(),
          200,
        )
      invoices
    })

  let data = invoice_for(invoices, "Data Platform")
  assert data
    == Invoice(
      id: data.id,
      project: "Data Platform",
      client: "Globex Corporation",
      billing_from: Date(2026, June, 1),
      billing_to: Date(2026, July, 1),
      status: Issued,
      total: money_of("147000.00"),
      issued_at: Some(Date(2026, June, 10)),
      paid_at: None,
    )

  let ledger = invoice_for(invoices, "Ledger Migration")
  assert ledger.client == "Northwind Trading"
  assert ledger.status == Issued
  assert ledger.total == money_of("18000.00")
}

// FR-F4 carried into the list: an invoice issued on Jun 10 reads `draft` as of a
// date BEFORE its issue date (Jun 5), and `issued` after. Scrubbing the slider
// back shows the earlier lifecycle state.
pub fn list_invoices_status_is_as_of_the_date_test() {
  let #(before_issue, after_issue) =
    rolling_back(fn(conn) {
      let _ = draft_and_issue(conn, 300, Date(2026, June, 10))
      let assert Ok(#(before, _)) =
        invoice_read.list_invoices(
          Context(db: conn, principal: None),
          Date(2026, June, 5),
          cursor.date_id_start(),
          200,
        )
      let assert Ok(#(after, _)) =
        invoice_read.list_invoices(
          Context(db: conn, principal: None),
          Date(2026, June, 15),
          cursor.date_id_start(),
          200,
        )
      #(
        invoice_for(before, "Data Platform").status,
        invoice_for(after, "Data Platform").status,
      )
    })

  assert before_issue == Draft
  assert after_issue == Issued
}

// Keyset pagination (#12): with three June invoices drafted, a limit-2 first page
// returns exactly two rows and a next_cursor; following the cursor returns the
// remaining one row with no next_cursor and no overlap. The concatenation is the
// same stable (billing_from, id) order as the unpaged read.
pub fn list_invoices_pages_by_cursor_test() {
  let #(first_ids, first_cursor, second_ids, second_cursor, expected_ids) =
    rolling_back(fn(conn) {
      let a = draft_and_issue(conn, 100, Date(2026, June, 10))
      let b = draft_and_issue(conn, 200, Date(2026, June, 10))
      let c = draft_and_issue(conn, 300, Date(2026, June, 10))
      let context = Context(db: conn, principal: None)

      let assert Ok(#(first, first_cursor)) =
        invoice_read.list_invoices(
          context,
          Date(2026, June, 15),
          cursor.date_id_start(),
          2,
        )
      let assert Some(token) = first_cursor
      let assert Ok(after) = cursor.decode_date_id(token)
      let assert Ok(#(second, second_cursor)) =
        invoice_read.list_invoices(context, Date(2026, June, 15), after, 2)

      #(
        list.map(first, fn(invoice) { invoice.id }),
        first_cursor,
        list.map(second, fn(invoice) { invoice.id }),
        second_cursor,
        list.sort([a, b, c], int.compare),
      )
    })

  assert list.length(first_ids) == 2
  assert first_cursor != None
  assert list.length(second_ids) == 1
  assert second_cursor == None
  assert list.any(second_ids, fn(id) { list.contains(first_ids, id) }) == False
  assert list.append(first_ids, second_ids) == expected_ids
}

// --- GET /api/invoices/:id (detail) — FR-F1 ---------------------------------

// The detail returns the header plus its snapshot lines. Project 300's invoice has
// five lines at the contract-agreed (2025) rates: Marcus L4 @1000 × 30 = 30000,
// Aisha L6 @1800 × 30 = 54000, plus the bench (#40 Phase 3 Stage 1) also allocated
// there — Mei L5 @1200 × 30 = 36000, Rohan L2 @600 × 0.5 × 30 = 9000, Dmitri L2
// @600 × 30 = 18000 — ordered by engineer name.
pub fn invoice_detail_returns_header_and_lines_test() {
  let detail =
    rolling_back(fn(conn) {
      let invoice_id = draft_and_issue(conn, 300, Date(2026, June, 10))
      let assert Ok(Ok(detail)) =
        invoice_read.invoice_detail(
          Context(db: conn, principal: None),
          invoice_id,
          Date(2026, June, 15),
        )
      detail
    })

  let InvoiceDetail(invoice:, lines:) = detail
  assert invoice.project == "Data Platform"
  assert invoice.status == Issued
  assert invoice.total == money_of("147000.00")
  assert lines
    == [
      InvoiceLine(
        "Aisha Okafor",
        6,
        money_of("1800.00"),
        30.0,
        money_of("54000.00"),
      ),
      InvoiceLine(
        "Dmitri Volkov",
        2,
        money_of("600.00"),
        30.0,
        money_of("18000.00"),
      ),
      InvoiceLine(
        "Marcus Chen",
        4,
        money_of("1000.00"),
        30.0,
        money_of("30000.00"),
      ),
      InvoiceLine("Mei Lin", 5, money_of("1200.00"), 30.0, money_of("36000.00")),
      InvoiceLine(
        "Rohan Sharma",
        2,
        money_of("600.00"),
        15.0,
        money_of("9000.00"),
      ),
    ]
}

// An unknown invoice id is `Ok(Error(Nil))` (the handler answers 404), not a crash.
pub fn invoice_detail_unknown_id_is_not_found_test() {
  let outcome =
    rolling_back(fn(conn) {
      invoice_read.invoice_detail(
        Context(db: conn, principal: None),
        999_999,
        Date(2026, June, 15),
      )
    })

  assert outcome == Ok(Error(Nil))
}

// --- GET /api/payroll?from=&to= — FR-F5/FR-F6 -------------------------------

// After running June payroll, the read reconciles each employed engineer's LIVE
// preview against the MATERIALIZED paid line. With no fact back-dated, paid equals
// preview for every engineer, each over the full 30-day month (no part-periods in
// the seed for June): the original three (Priya L5 10000, Marcus L4 8000, Aisha L6
// 14000) plus the recommender bench (#40 Phase 3 Stage 1, engineers 4-11), who are
// employed and so draw a salary line too, regardless of allocation: Omar L4 8000,
// Sofia L4 8000, Mei L5 10000, Tunde L3 6000, Rohan L2 4000, Dmitri L2 4000, Jonas
// L3 6000, Hannah L6 14000. The run is materialized, so `run` is Some and the paid
// columns are populated.
pub fn payroll_run_reconciles_preview_against_paid_test() {
  let run =
    rolling_back(fn(conn) {
      apply(
        conn,
        gateway.PayrollCommand(payroll_command.RunPayroll(
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
      let assert Ok(run) =
        payroll_read.payroll(
          Context(db: conn, principal: None),
          Date(2026, June, 1),
          Date(2026, July, 1),
        )
      run
    })

  let assert Payroll(run: Some(PayrollRunInfo(run_id:)), ..) = run

  assert run
    == Payroll(
      period_from: Date(2026, June, 1),
      period_to: Date(2026, July, 1),
      run: Some(PayrollRunInfo(run_id:)),
      lines: [
        PayrollLine(
          engineer_id: 3,
          engineer: "Aisha Okafor",
          preview_amount: money_of("14000.00"),
          preview_days: 30.0,
          paid_amount: Some(money_of("14000.00")),
          paid_days: Some(30.0),
          preview_segments: [
            PayrollSegment(6, 30.0, money_of("14000.00"), money_of("14000.00")),
          ],
          paid_segments: [
            PayrollSegment(6, 30.0, money_of("14000.00"), money_of("14000.00")),
          ],
        ),
        PayrollLine(
          engineer_id: 9,
          engineer: "Dmitri Volkov",
          preview_amount: money_of("4000.00"),
          preview_days: 30.0,
          paid_amount: Some(money_of("4000.00")),
          paid_days: Some(30.0),
          preview_segments: [
            PayrollSegment(2, 30.0, money_of("4000.00"), money_of("4000.00")),
          ],
          paid_segments: [
            PayrollSegment(2, 30.0, money_of("4000.00"), money_of("4000.00")),
          ],
        ),
        PayrollLine(
          engineer_id: 11,
          engineer: "Hannah Park",
          preview_amount: money_of("14000.00"),
          preview_days: 30.0,
          paid_amount: Some(money_of("14000.00")),
          paid_days: Some(30.0),
          preview_segments: [
            PayrollSegment(6, 30.0, money_of("14000.00"), money_of("14000.00")),
          ],
          paid_segments: [
            PayrollSegment(6, 30.0, money_of("14000.00"), money_of("14000.00")),
          ],
        ),
        PayrollLine(
          engineer_id: 10,
          engineer: "Jonas Weber",
          preview_amount: money_of("6000.00"),
          preview_days: 30.0,
          paid_amount: Some(money_of("6000.00")),
          paid_days: Some(30.0),
          preview_segments: [
            PayrollSegment(3, 30.0, money_of("6000.00"), money_of("6000.00")),
          ],
          paid_segments: [
            PayrollSegment(3, 30.0, money_of("6000.00"), money_of("6000.00")),
          ],
        ),
        PayrollLine(
          engineer_id: 2,
          engineer: "Marcus Chen",
          preview_amount: money_of("8000.00"),
          preview_days: 30.0,
          paid_amount: Some(money_of("8000.00")),
          paid_days: Some(30.0),
          preview_segments: [
            PayrollSegment(4, 30.0, money_of("8000.00"), money_of("8000.00")),
          ],
          paid_segments: [
            PayrollSegment(4, 30.0, money_of("8000.00"), money_of("8000.00")),
          ],
        ),
        PayrollLine(
          engineer_id: 6,
          engineer: "Mei Lin",
          preview_amount: money_of("10000.00"),
          preview_days: 30.0,
          paid_amount: Some(money_of("10000.00")),
          paid_days: Some(30.0),
          preview_segments: [
            PayrollSegment(5, 30.0, money_of("10000.00"), money_of("10000.00")),
          ],
          paid_segments: [
            PayrollSegment(5, 30.0, money_of("10000.00"), money_of("10000.00")),
          ],
        ),
        PayrollLine(
          engineer_id: 4,
          engineer: "Omar Haddad",
          preview_amount: money_of("8000.00"),
          preview_days: 30.0,
          paid_amount: Some(money_of("8000.00")),
          paid_days: Some(30.0),
          preview_segments: [
            PayrollSegment(4, 30.0, money_of("8000.00"), money_of("8000.00")),
          ],
          paid_segments: [
            PayrollSegment(4, 30.0, money_of("8000.00"), money_of("8000.00")),
          ],
        ),
        PayrollLine(
          engineer_id: 1,
          engineer: "Priya Sharma",
          preview_amount: money_of("10000.00"),
          preview_days: 30.0,
          paid_amount: Some(money_of("10000.00")),
          paid_days: Some(30.0),
          preview_segments: [
            PayrollSegment(5, 30.0, money_of("10000.00"), money_of("10000.00")),
          ],
          paid_segments: [
            PayrollSegment(5, 30.0, money_of("10000.00"), money_of("10000.00")),
          ],
        ),
        PayrollLine(
          engineer_id: 8,
          engineer: "Rohan Sharma",
          preview_amount: money_of("4000.00"),
          preview_days: 30.0,
          paid_amount: Some(money_of("4000.00")),
          paid_days: Some(30.0),
          preview_segments: [
            PayrollSegment(2, 30.0, money_of("4000.00"), money_of("4000.00")),
          ],
          paid_segments: [
            PayrollSegment(2, 30.0, money_of("4000.00"), money_of("4000.00")),
          ],
        ),
        PayrollLine(
          engineer_id: 5,
          engineer: "Sofia Rossi",
          preview_amount: money_of("8000.00"),
          preview_days: 30.0,
          paid_amount: Some(money_of("8000.00")),
          paid_days: Some(30.0),
          preview_segments: [
            PayrollSegment(4, 30.0, money_of("8000.00"), money_of("8000.00")),
          ],
          paid_segments: [
            PayrollSegment(4, 30.0, money_of("8000.00"), money_of("8000.00")),
          ],
        ),
        PayrollLine(
          engineer_id: 7,
          engineer: "Tunde Okafor",
          preview_amount: money_of("6000.00"),
          preview_days: 30.0,
          paid_amount: Some(money_of("6000.00")),
          paid_days: Some(30.0),
          preview_segments: [
            PayrollSegment(3, 30.0, money_of("6000.00"), money_of("6000.00")),
          ],
          paid_segments: [
            PayrollSegment(3, 30.0, money_of("6000.00"), money_of("6000.00")),
          ],
        ),
      ],
    )
}

// --- GET /api/pnl?as_of= — FR-F7/FR-F8 --------------------------------------

// The P&L for as-of 2026-06-15: June payroll (cost 92000, all 11 employed
// engineers — #40 Phase 3 Stage 1) and the three June invoices issued before the
// month closes (revenue 220200, folding in the bench's project 200/300
// allocations). Month totals: revenue 220200, cost 92000, profit 128200.
//
// YTD (Jan 1 .. Jul 1) revenue is CAPACITY-based (ADR-043): the billable value of
// the work over Jan-June, day-counted per allocation ∩ role ∩ rate_card
// sub-period. The original three contribute 724000 (unchanged: Priya
// 0.5×181d×1200×2 + Marcus 181d×1000 + Aisha 181d×1800, where 181 is the day
// count Jan1..Jul1). The bench, all employed/assessed from 2026-01-01 (so YTD =
// their allocation's overlap with Jan1..Jul1), adds: Omar 0.6×122d×1000=73200
// (project 200, 2026-03-01..); Tunde 0.8×91d×800=58240 (project 200,
// 2026-04-01..); Mei 1.0×150d×1200=180000 (project 300, 2026-02-01..); Rohan
// 0.5×61d×600=18300 (project 300, 2026-05-01..); Dmitri 1.0×122d×600=73200
// (project 300, 2026-03-01..) — 402940 more, so ytd_revenue = 1126940.
//
// YTD cost blends ACTUALS and ESTIMATE month by month. No engineer's level/salary
// changes before July, so every one of the 6 YTD months (Jan-Jun) costs the same
// 92000 as June's payroll run (June is the ACTUAL snapshot; Jan-May are the
// EXPECTED-salary estimate) — ytd_cost = 92000 × 6 = 552000. ytd_profit =
// 1126940 - 552000 = 574940.
//
// Aisha's per-engineer row is untouched by the bench (her own allocation and
// salary are unchanged): revenue 54000, cost 14000, profit 40000, margin
// 40000/54000, fully utilized.
pub fn pnl_totals_and_per_engineer_row_test() {
  let pnl =
    serial_pool.run(fn(context) {
      apply(
        context.db,
        gateway.PayrollCommand(payroll_command.RunPayroll(
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
      let _ = draft_and_issue(context.db, 100, Date(2026, June, 10))
      let _ = draft_and_issue(context.db, 200, Date(2026, June, 10))
      let _ = draft_and_issue(context.db, 300, Date(2026, June, 10))
      let assert Ok(pnl) = pnl_read.pnl(context, Date(2026, June, 15))
      pnl
    })

  // Month totals.
  assert pnl.month_revenue == money_of("220200.00")
  assert pnl.month_cost == money_of("92000.00")
  assert pnl.month_profit == money_of("128200.00")
  assert pnl.ytd_revenue == money_of("1126940.00")
  assert pnl.ytd_cost == money_of("552000.00")
  assert pnl.ytd_profit == money_of("574940.00")

  // Aisha's per-engineer month row (revenue/cost/profit/margin/utilization). The
  // margin uses the same float arithmetic the domain does, so the comparison is
  // exact, not a tolerance.
  assert row_for(pnl.rows, "Aisha Okafor")
    == PnlRow(
      engineer: "Aisha Okafor",
      revenue: money_of("54000.00"),
      cost: money_of("14000.00"),
      profit: money_of("40000.00"),
      margin_pct: { 54_000.0 -. 14_000.0 } /. 54_000.0 *. 100.0,
      utilization_pct: 100.0,
    )

  // The per-engineer rows reconcile to the month totals.
  let row_revenue = money.sum(list.map(pnl.rows, fn(row) { row.revenue }))
  assert row_revenue == money_of("220200.00")
}

// Capacity-based recognition (ADR-043): P&L revenue is the billable value of the
// work performed (allocations × rate-card), recognized as the work happens —
// INDEPENDENT of invoice status. With the month's invoices only DRAFTED (never
// issued), June's revenue is still recognized in full; the invoice lifecycle governs
// the invoices table + cash, not the P&L.
pub fn pnl_recognizes_capacity_revenue_regardless_of_invoice_status_test() {
  let pnl =
    serial_pool.run(fn(context) {
      apply(
        context.db,
        gateway.PayrollCommand(payroll_command.RunPayroll(
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
      // Draft the three invoices but DO NOT issue them.
      apply(
        context.db,
        gateway.InvoiceCommand(invoice_command.DraftInvoice(
          100,
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
      apply(
        context.db,
        gateway.InvoiceCommand(invoice_command.DraftInvoice(
          200,
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
      apply(
        context.db,
        gateway.InvoiceCommand(invoice_command.DraftInvoice(
          300,
          Date(2026, June, 1),
          Date(2026, July, 1),
        )),
      )
      let assert Ok(pnl) = pnl_read.pnl(context, Date(2026, June, 15))
      pnl
    })

  // Capacity recognizes June's work in full despite no issued invoice (same
  // month totals as pnl_totals_and_per_engineer_row_test, which folds in the
  // recommender bench's project 200/300 allocations and payroll lines).
  assert pnl.month_revenue == money_of("220200.00")
  assert pnl.month_cost == money_of("92000.00")
  assert pnl.month_profit == money_of("128200.00")
}

// FORECASTED COST (the cost-side mirror of capacity revenue): scrubbing the P&L to a
// FUTURE month — one with no payroll run yet — must NOT read $0 cost against accrued
// revenue. With no run, each employed engineer's cost is the EXPECTED salary (the
// payroll_amounts proration), so the month shows a real profit. For September 2026
// (no run on record), all 11 employed engineers cost the same as June's payroll
// (92000, see the module doc) except Marcus, now L5 (10000, up from L4's 8000) after
// his 2026-07-01 promotion — 92000 - 8000 + 10000 = 94000.
pub fn pnl_estimates_cost_for_a_future_month_with_no_payroll_run_test() {
  let pnl =
    serial_pool.run(fn(context) {
      let assert Ok(pnl) = pnl_read.pnl(context, Date(2026, September, 15))
      pnl
    })

  assert pnl.month_cost == money_of("94000.00")
  assert row_for(pnl.rows, "Priya Sharma").cost == money_of("10000.00")
  assert row_for(pnl.rows, "Marcus Chen").cost == money_of("10000.00")
  assert row_for(pnl.rows, "Aisha Okafor").cost == money_of("14000.00")
}
