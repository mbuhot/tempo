//// Layer-3 financial READ tests (PRD-financials.md §7) for the domain query
//// functions in `tempo/server/finance_query`. They run against the deterministic
//// v1-wide seed ("now" = 2026-06-15) plus the baseline salaries migration 012
//// seeds (L3..L6), drive the financial WRITES through the command bus to put
//// invoices and payroll on record, then assert the exact read-model values: the
//// invoices table (status as-of, total), an invoice's snapshot lines, the payroll
//// run, and the P&L month/YTD totals + a per-engineer row.
////
//// ISOLATION (as in financials_test.gleam). Each test runs inside its OWN
//// `pog.transaction` that is always rolled back: it applies the writes via
//// `command.dispatch_in`, reads back through the `finance_query` functions (given
//// a `Context` wrapping the same in-transaction connection), then returns
//// `Error(…)` so nothing is committed and the shared seed is undisturbed.
////
//// THE NUMBERS (June 2026, 30 days; agreed rate = rate_card as of lower(contract.term)):
////   * billing project 100 (Ledger, contract signed 2024): Priya L5 @1200 × 0.5 × 30 = 18000
////   * billing project 200 (Inventory, contract signed 2024): Priya L5 @1200 × 0.5 × 30 = 18000
////   * billing project 300 (Data, contract signed 2025): Marcus L4 @1000 × 30 = 30000,
////                                                        Aisha L6 @1800 × 30 = 54000
////   * payroll June: Priya L5 10000, Marcus L4 8000, Aisha L6 14000 (cost 32000)
//// So per engineer (month): Priya rev 36000, Marcus rev 30000, Aisha rev 54000
//// (total revenue 120000); everyone is 100% utilized (full-month allocation).

import gleam/dynamic/decode
import gleam/list
import gleam/option.{Some}
import gleam/time/calendar.{type Date, Date, July, June}
import pog
import shared/types.{
  type Invoice, type PnlRow, DraftInvoice, Invoice, InvoiceDetail, InvoiceLine,
  IssueInvoice, Payroll, PayrollLine, PayrollRunInfo, PnlRow, RunPayroll,
}
import tempo/server/command
import tempo/server/context.{Context}
import tempo/server/finance_query
import test_pool

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
    DraftInvoice(project_id, Date(2026, June, 1), Date(2026, July, 1)),
  )
  let invoice_id = newest_invoice_for_project(conn, project_id)
  apply(conn, IssueInvoice(invoice_id, issue_on))
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
// Aisha 54000 = 84000; projects 100 and 200 are 18000 each (Priya half-time).
pub fn list_invoices_shows_status_and_total_test() {
  let invoices =
    rolling_back(fn(conn) {
      let _ = draft_and_issue(conn, 100, Date(2026, June, 10))
      let _ = draft_and_issue(conn, 200, Date(2026, June, 10))
      let _ = draft_and_issue(conn, 300, Date(2026, June, 10))
      let assert Ok(invoices) =
        finance_query.list_invoices(Context(db: conn), Date(2026, June, 15))
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
      status: "issued",
      total: 84_000.0,
    )

  let ledger = invoice_for(invoices, "Ledger Migration")
  assert ledger.client == "Northwind Trading"
  assert ledger.status == "issued"
  assert ledger.total == 18_000.0
}

// FR-F4 carried into the list: an invoice issued on Jun 10 reads `draft` as of a
// date BEFORE its issue date (Jun 5), and `issued` after. Scrubbing the slider
// back shows the earlier lifecycle state.
pub fn list_invoices_status_is_as_of_the_date_test() {
  let #(before_issue, after_issue) =
    rolling_back(fn(conn) {
      let _ = draft_and_issue(conn, 300, Date(2026, June, 10))
      let assert Ok(before) =
        finance_query.list_invoices(Context(db: conn), Date(2026, June, 5))
      let assert Ok(after) =
        finance_query.list_invoices(Context(db: conn), Date(2026, June, 15))
      #(
        invoice_for(before, "Data Platform").status,
        invoice_for(after, "Data Platform").status,
      )
    })

  assert before_issue == "draft"
  assert after_issue == "issued"
}

// --- GET /api/invoices/:id (detail) — FR-F1 ---------------------------------

// The detail returns the header plus its snapshot lines. Project 300's invoice has
// two lines at the contract-agreed (2025) rates: Marcus L4 @1000 × 30 = 30000 and
// Aisha L6 @1800 × 30 = 54000, ordered by engineer name.
pub fn invoice_detail_returns_header_and_lines_test() {
  let detail =
    rolling_back(fn(conn) {
      let invoice_id = draft_and_issue(conn, 300, Date(2026, June, 10))
      let assert Ok(Ok(detail)) =
        finance_query.invoice_detail(
          Context(db: conn),
          invoice_id,
          Date(2026, June, 15),
        )
      detail
    })

  let InvoiceDetail(invoice:, lines:) = detail
  assert invoice.project == "Data Platform"
  assert invoice.status == "issued"
  assert invoice.total == 84_000.0
  assert lines
    == [
      InvoiceLine("Aisha Okafor", 6, 1800.0, 30.0, 54_000.0),
      InvoiceLine("Marcus Chen", 4, 1000.0, 30.0, 30_000.0),
    ]
}

// An unknown invoice id is `Ok(Error(Nil))` (the handler answers 404), not a crash.
pub fn invoice_detail_unknown_id_is_not_found_test() {
  let outcome =
    rolling_back(fn(conn) {
      finance_query.invoice_detail(
        Context(db: conn),
        999_999,
        Date(2026, June, 15),
      )
    })

  assert outcome == Ok(Error(Nil))
}

// --- GET /api/payroll?from=&to= — FR-F5/FR-F6 -------------------------------

// After running June payroll, the read reconciles each employed engineer's LIVE
// preview against the MATERIALIZED paid line. With no fact back-dated, paid equals
// preview for every engineer: Priya L5 10000, Marcus L4 8000, Aisha L6 14000, each
// over the full 30-day month (no part-periods in the seed for June). The run is
// materialized, so `run` is Some and the paid columns are populated.
pub fn payroll_run_reconciles_preview_against_paid_test() {
  let run =
    rolling_back(fn(conn) {
      apply(conn, RunPayroll(Date(2026, June, 1), Date(2026, July, 1)))
      let assert Ok(run) =
        finance_query.payroll(
          Context(db: conn),
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
        PayrollLine("Aisha Okafor", 14_000.0, 30.0, Some(14_000.0), Some(30.0)),
        PayrollLine("Marcus Chen", 8000.0, 30.0, Some(8000.0), Some(30.0)),
        PayrollLine("Priya Sharma", 10_000.0, 30.0, Some(10_000.0), Some(30.0)),
      ],
    )
}

// --- GET /api/pnl?as_of= — FR-F7/FR-F8 --------------------------------------

// The P&L for as-of 2026-06-15: June payroll (cost 32000) and the three June
// invoices issued before the month closes (revenue 120000). Month totals:
// revenue 120000, cost 32000, profit 88000. YTD (Jan 1 .. Jul 1) sees only these
// June facts (the only ones on record), so its totals match the month's. Aisha's
// per-engineer row: revenue 54000, cost 14000, profit 40000, margin
// 40000/54000, fully utilized.
pub fn pnl_totals_and_per_engineer_row_test() {
  let pnl =
    rolling_back(fn(conn) {
      apply(conn, RunPayroll(Date(2026, June, 1), Date(2026, July, 1)))
      let _ = draft_and_issue(conn, 100, Date(2026, June, 10))
      let _ = draft_and_issue(conn, 200, Date(2026, June, 10))
      let _ = draft_and_issue(conn, 300, Date(2026, June, 10))
      let assert Ok(pnl) =
        finance_query.pnl(Context(db: conn), Date(2026, June, 15))
      pnl
    })

  // Month totals.
  assert pnl.month_revenue == 120_000.0
  assert pnl.month_cost == 32_000.0
  assert pnl.month_profit == 88_000.0
  // YTD totals match (June is the only month with facts on record).
  assert pnl.ytd_revenue == 120_000.0
  assert pnl.ytd_cost == 32_000.0
  assert pnl.ytd_profit == 88_000.0

  // Aisha's per-engineer month row (revenue/cost/profit/margin/utilization). The
  // margin uses the same float arithmetic the domain does, so the comparison is
  // exact, not a tolerance.
  assert row_for(pnl.rows, "Aisha Okafor")
    == PnlRow(
      engineer: "Aisha Okafor",
      revenue: 54_000.0,
      cost: 14_000.0,
      profit: 40_000.0,
      margin_pct: { 54_000.0 -. 14_000.0 } /. 54_000.0 *. 100.0,
      utilization_pct: 100.0,
    )

  // The per-engineer rows reconcile to the month totals.
  let row_revenue =
    list.fold(pnl.rows, 0.0, fn(sum, row) { sum +. row.revenue })
  assert row_revenue == 120_000.0
}

// FR-F4 carried into the P&L: invoices DRAFTED but issued only AFTER the month
// closes (Aug 1) are still `draft` as of the month's exclusive upper bound
// (Jul 1), so no revenue is recognized this month — but the cost (June payroll)
// still lands, giving a negative month profit.
pub fn pnl_unissued_invoices_recognize_no_revenue_test() {
  let pnl =
    rolling_back(fn(conn) {
      apply(conn, RunPayroll(Date(2026, June, 1), Date(2026, July, 1)))
      // Draft the three invoices but DO NOT issue them until after the month.
      apply(conn, DraftInvoice(100, Date(2026, June, 1), Date(2026, July, 1)))
      apply(conn, DraftInvoice(200, Date(2026, June, 1), Date(2026, July, 1)))
      apply(conn, DraftInvoice(300, Date(2026, June, 1), Date(2026, July, 1)))
      let assert Ok(pnl) =
        finance_query.pnl(Context(db: conn), Date(2026, June, 15))
      pnl
    })

  assert pnl.month_revenue == 0.0
  assert pnl.month_cost == 32_000.0
  assert pnl.month_profit == -32_000.0
}
