//// On-demand demo financials seed (`gleam run -m tempo/seed_financials`, run via
//// `./bin/seed-invoices`). Unlike `tempo/seed`, this does NOT reset the schema and
//// is NOT wired into `bin/up`: it layers a small, realistic financial story onto an
//// already-migrated dev DB so the invoices / payroll / P&L screens have something to
//// show when you ask for it. A freshly-migrated DB stays test-clean until you run it.
////
//// It populates a demo set against the founding fixture's pinned project ids
//// (Ledger 100, Data Platform 300):
////   * an ISSUED invoice — Data Platform's June, drafted then issued 2026-06-20,
////   * a DRAFT invoice — Ledger's June, left in draft, and
////   * a June PAYROLL run.
////
//// IDEMPOTENCY: it first reads the invoice list as of 2026-06-30; if any invoice
//// already covers that date it prints `seed-invoices: already populated, skipping`
//// and exits without writing, so re-running is safe. Each write goes through
//// `command.dispatch` (actor "seed"); a failing operation `panic`s (non-zero exit)
//// so a broken seed gates loudly. It reuses `finance_query.list_invoices` to find
//// the drafted invoice's minted id by project NAME rather than adding a new query.

import gleam/io
import gleam/list
import gleam/string
import gleam/time/calendar.{Date, July, June}
import shared/types.{
  type Command, type Invoice, DraftInvoice, IssueInvoice, RunPayroll,
}
import tempo/server/command
import tempo/server/context.{type Context}
import tempo/server/finance_query

/// The actor recorded against every demo `event_log` row.
const seed_actor = "seed"

/// The as-of date the idempotency probe and the issued-invoice lookup read at: the
/// end of the demo billing month, by which point both June invoices exist and the
/// Data Platform one reads `issued`.
const probe_date = Date(2026, June, 30)

/// `gleam run -m tempo/seed_financials` (via `./bin/seed-invoices`). Connect to the
/// dev DB, skip if already populated, otherwise replay the demo financial operations
/// and print a one-line summary. `panic`s (non-zero exit) on the first failure.
pub fn main() -> Nil {
  let assert Ok(ctx) = context.start()

  case already_populated(ctx) {
    True -> io.println("seed-invoices: already populated, skipping")
    False -> seed(ctx)
  }
}

/// True when an invoice already covers `probe_date` — the signal the demo set has
/// been seeded before (so re-running is a no-op).
fn already_populated(ctx: Context) -> Bool {
  list_invoices(ctx) != []
}

/// Replay the demo financial operations against the (already-migrated) dev DB:
/// draft + issue Data Platform's June invoice, draft Ledger's June invoice (left in
/// draft), and run June payroll. Each write asserts `Ok`. Prints a one-line summary.
fn seed(ctx: Context) -> Nil {
  // a. Draft Data Platform's June invoice (project 300).
  apply(
    ctx,
    DraftInvoice(
      project_id: 300,
      billing_from: Date(2026, June, 1),
      billing_to: Date(2026, July, 1),
    ),
  )

  // b. Find the drafted Data Platform invoice by name, then issue it 2026-06-20.
  let data_platform_id = invoice_id_for_project(ctx, "Data Platform")
  apply(
    ctx,
    IssueInvoice(invoice_id: data_platform_id, at: Date(2026, June, 20)),
  )

  // c. Draft Ledger's June invoice (project 100), left in draft.
  apply(
    ctx,
    DraftInvoice(
      project_id: 100,
      billing_from: Date(2026, June, 1),
      billing_to: Date(2026, July, 1),
    ),
  )

  // d. Run June payroll.
  apply(
    ctx,
    RunPayroll(period_from: Date(2026, June, 1), period_to: Date(2026, July, 1)),
  )

  io.println(
    "seed-invoices: created Data Platform June invoice (issued 2026-06-20, id "
    <> string.inspect(data_platform_id)
    <> "), Ledger June invoice (draft), and a June payroll run.",
  )
}

/// Dispatch one demo command through `command.dispatch` (actor "seed"), asserting it
/// succeeds. A failure `panic`s with the operation error so the seed gates loudly.
fn apply(ctx: Context, command: Command) -> Nil {
  case command.dispatch(ctx, actor: seed_actor, command: command) {
    Ok(_) -> Nil
    Error(error) ->
      panic as {
        "seed-invoices: dispatching "
        <> string.inspect(command)
        <> " failed: "
        <> string.inspect(error)
      }
  }
}

/// The id of the (single) invoice whose project is `project_name`, read as of
/// `probe_date`. `panic`s if no such invoice exists — the draft that mints it runs
/// immediately before, so its absence is a seed bug.
fn invoice_id_for_project(ctx: Context, project_name: String) -> Int {
  case
    list.find(list_invoices(ctx), fn(invoice) {
      invoice.project == project_name
    })
  {
    Ok(invoice) -> invoice.id
    Error(Nil) ->
      panic as {
        "seed-invoices: no invoice found for project " <> project_name
      }
  }
}

/// List the invoices as of `probe_date`, asserting the read succeeds.
fn list_invoices(ctx: Context) -> List(Invoice) {
  let assert Ok(invoices) = finance_query.list_invoices(ctx, probe_date)
  invoices
}
