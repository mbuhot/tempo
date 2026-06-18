//// On-demand demo financials seed (`gleam run -m tempo/seed_financials`, run via
//// `./bin/seed-invoices`). Unlike `tempo/seed`, this does NOT reset the schema and
//// is NOT wired into `bin/up`: it layers a full half-year financial story onto an
//// already-migrated dev DB so the timesheet / invoices / payroll / P&L screens have
//// something to show when you ask for it. A freshly-migrated DB stays test-clean
//// until you run it.
////
//// It seeds the whole pipeline for Jan–Jun 2026 against the founding fixture
//// (engineers Priya/Marcus/Aisha; projects Ledger 100, Inventory 200, Data
//// Platform 300):
////   * TIMESHEETS — every engineer's hours for the Mon–Fri working days of each
////     week (Priya 4h on each of her two projects, Marcus/Aisha 8h on Data
////     Platform), one `LogWeek` per engineer per week, skipping Aisha's June leave.
////   * INVOICES — one per project per month (18 in all), progressed so all three
////     statuses show: Jan–Mar PAID, Apr–May ISSUED, Jun left DRAFT.
////   * PAYROLL — one run per month (six runs).
//// Financials are computed from allocations/role/salary/rate-card, not the
//// timesheet (P&L utilization is capacity-based), so the timesheets are the work
//// record the My-timesheet grid shows rather than an input to the billing.
////
//// IDEMPOTENCY: it first reads the invoice list as of 2026-06-30; if any invoice
//// already covers that date it prints `seed-financials: already populated, skipping`
//// and exits without writing, so re-running is safe (drafting again would mint
//// duplicate invoices). Each write goes through `command.dispatch` (actor "seed");
//// a failing operation `panic`s (non-zero exit) so a broken seed gates loudly. It
//// reuses `finance_query.list_invoices` to resolve a freshly-drafted invoice's
//// minted id by project NAME and billing month rather than adding a new query.

import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{
  type Date, type TimeOfDay, April, Date, February, January, July, June, March,
  May, TimeOfDay,
}
import gleam/time/timestamp
import shared/types.{
  type Command, type Invoice, type TimesheetEntry, DraftInvoice, IssueInvoice,
  LogWeek, PayInvoice, RunPayroll, TimesheetEntry,
}
import tempo/server/command
import tempo/server/context.{type Context}
import tempo/server/finance_query

/// The actor recorded against every demo `event_log` row.
const seed_actor = "seed"

/// The as-of date the idempotency probe reads at: by 2026-06-30 every month's
/// invoices exist (June's draft opens 06-01), so a non-empty list means the demo
/// set has been seeded before.
const probe_date = Date(2026, June, 30)

/// The projects billed each month, with the names `list_invoices` reports — used to
/// resolve a freshly-drafted invoice's minted id (project name + billing month is
/// unique).
const billable_projects = [
  #(100, "Ledger Migration"),
  #(200, "Inventory Sync"),
  #(300, "Data Platform"),
]

// --- types -------------------------------------------------------------------

/// One engineer's standing daily work for the seed period: the projects they log
/// against (with hours per working day) and any leave windows `[from, to)` to skip.
type Worker {
  Worker(
    engineer_id: Int,
    daily: List(#(Int, Float)),
    leave: List(#(Date, Date)),
  )
}

/// One month's billing + payroll plan: the billing window `[from, to)` and the
/// invoice lifecycle to drive. `issue` of `None` leaves the month's invoices in
/// draft; `pay` of `None` leaves them issued — so across the six months the set
/// spans draft → issued → paid.
type MonthPlan {
  MonthPlan(from: Date, to: Date, issue: Option(Date), pay: Option(Date))
}

// --- entrypoint --------------------------------------------------------------

/// `gleam run -m tempo/seed_financials` (via `./bin/seed-invoices`). Connect to the
/// dev DB, skip if already populated, otherwise replay the demo pipeline and print a
/// one-line summary. `panic`s (non-zero exit) on the first failure.
pub fn main() -> Nil {
  let assert Ok(ctx) = context.start()

  case already_populated(ctx) {
    True -> io.println("seed-financials: already populated, skipping")
    False -> seed(ctx)
  }
}

/// True when an invoice already covers `probe_date` — the signal the demo set has
/// been seeded before (so re-running is a no-op).
fn already_populated(ctx: Context) -> Bool {
  list_invoices(ctx, probe_date) != []
}

/// Replay the demo pipeline against the (already-migrated) dev DB: log Jan–Jun
/// timesheets, then for each month draft + progress its invoices and run its
/// payroll. Each write asserts `Ok`. Prints a one-line summary.
fn seed(ctx: Context) -> Nil {
  log_timesheets(ctx)
  list.each(month_plans(), fn(plan) { bill_month(ctx, plan) })
  io.println(
    "seed-financials: logged Jan–Jun 2026 timesheets, drafted 18 invoices "
    <> "(Jan–Mar paid, Apr–May issued, Jun draft), and ran six monthly payrolls.",
  )
}

// --- timesheets --------------------------------------------------------------

/// The engineers and their standing daily work for the seed period.
fn workers() -> List(Worker) {
  [
    // Priya — half-time on each Northwind project (an 8h day split 4/4).
    Worker(engineer_id: 1, daily: [#(100, 4.0), #(200, 4.0)], leave: []),
    // Marcus — full-time on Data Platform.
    Worker(engineer_id: 2, daily: [#(300, 8.0)], leave: []),
    // Aisha — full-time on Data Platform, off on annual leave 8–21 Jun.
    Worker(engineer_id: 3, daily: [#(300, 8.0)], leave: [
      #(Date(2026, June, 8), Date(2026, June, 22)),
    ]),
  ]
}

/// Log every worker's hours for the Mon–Fri working days of Jan–Jun 2026, one
/// `LogWeek` per worker per calendar week (skipping leave days, and weeks with no
/// loggable day). Every allocation spans the period, so each working day is
/// loggable.
fn log_timesheets(ctx: Context) -> Nil {
  let period_start = date_to_day_index(Date(2026, January, 1))
  let period_end = date_to_day_index(Date(2026, June, 30))
  list.each(workers(), fn(worker) {
    list.each(mondays_in(period_start, period_end), fn(monday) {
      case week_entries(worker, monday, period_start, period_end) {
        [] -> Nil
        entries ->
          apply(ctx, LogWeek(engineer_id: worker.engineer_id, entries:))
      }
    })
  })
}

/// The Monday day-indices of every week overlapping `[start, end]` (inclusive day
/// indices). Epoch day 0 is a Thursday, so the Monday of a day index `d` is
/// `d - ((d + 3) mod 7)`.
fn mondays_in(start: Int, end: Int) -> List(Int) {
  let first_monday = start - weekday_of(start)
  let weeks = { end - first_monday } / 7
  int_range(0, weeks)
  |> list.map(fn(week) { first_monday + week * 7 })
}

/// The `TimesheetEntry` list for one worker's week: each Mon–Fri day in range and
/// not on leave, times each of the worker's daily project/hours.
fn week_entries(
  worker: Worker,
  monday: Int,
  start: Int,
  end: Int,
) -> List(TimesheetEntry) {
  int_range(0, 4)
  |> list.map(fn(offset) { monday + offset })
  |> list.filter(fn(index) { index >= start && index <= end })
  |> list.map(day_index_to_date)
  |> list.filter(fn(day) { !on_leave(worker, day) })
  |> list.flat_map(fn(day) {
    list.map(worker.daily, fn(work) {
      let #(project_id, hours) = work
      TimesheetEntry(project_id:, day:, hours:)
    })
  })
}

/// Whether `day` falls in any of the worker's leave windows `[from, to)`.
fn on_leave(worker: Worker, day: Date) -> Bool {
  let index = date_to_day_index(day)
  list.any(worker.leave, fn(window) {
    let #(from, to) = window
    index >= date_to_day_index(from) && index < date_to_day_index(to)
  })
}

// --- invoices + payroll ------------------------------------------------------

/// The six monthly plans: Jan–Mar drafted then issued early next month and paid
/// late next month (→ paid); Apr–May drafted then issued, not paid (→ issued); Jun
/// drafted only (→ draft).
fn month_plans() -> List(MonthPlan) {
  [
    MonthPlan(
      from: Date(2026, January, 1),
      to: Date(2026, February, 1),
      issue: Some(Date(2026, February, 5)),
      pay: Some(Date(2026, February, 26)),
    ),
    MonthPlan(
      from: Date(2026, February, 1),
      to: Date(2026, March, 1),
      issue: Some(Date(2026, March, 5)),
      pay: Some(Date(2026, March, 26)),
    ),
    MonthPlan(
      from: Date(2026, March, 1),
      to: Date(2026, April, 1),
      issue: Some(Date(2026, April, 6)),
      pay: Some(Date(2026, April, 27)),
    ),
    MonthPlan(
      from: Date(2026, April, 1),
      to: Date(2026, May, 1),
      issue: Some(Date(2026, May, 5)),
      pay: None,
    ),
    MonthPlan(
      from: Date(2026, May, 1),
      to: Date(2026, June, 1),
      issue: Some(Date(2026, June, 5)),
      pay: None,
    ),
    MonthPlan(
      from: Date(2026, June, 1),
      to: Date(2026, July, 1),
      issue: None,
      pay: None,
    ),
  ]
}

/// Bill every project for the month (draft → issue → pay per the plan) and run the
/// month's payroll.
fn bill_month(ctx: Context, plan: MonthPlan) -> Nil {
  list.each(billable_projects, fn(project) {
    let #(project_id, project_name) = project
    apply(
      ctx,
      DraftInvoice(project_id:, billing_from: plan.from, billing_to: plan.to),
    )
    case plan.issue {
      None -> Nil
      Some(issue_at) -> {
        let invoice_id = drafted_invoice_id(ctx, project_name, plan.from)
        apply(ctx, IssueInvoice(invoice_id:, at: issue_at))
        case plan.pay {
          None -> Nil
          Some(pay_at) -> apply(ctx, PayInvoice(invoice_id:, at: pay_at))
        }
      }
    }
  })
  apply(ctx, RunPayroll(period_from: plan.from, period_to: plan.to))
}

/// The minted id of the invoice for `project_name` whose billing month starts at
/// `billing_from`, read as of that date (the draft status opens there, so it lists).
/// `panic`s if absent — the draft that mints it runs immediately before.
fn drafted_invoice_id(
  ctx: Context,
  project_name: String,
  billing_from: Date,
) -> Int {
  case
    list.find(list_invoices(ctx, billing_from), fn(invoice) {
      invoice.project == project_name && invoice.billing_from == billing_from
    })
  {
    Ok(invoice) -> invoice.id
    Error(Nil) ->
      panic as {
        "seed-financials: no drafted invoice for "
        <> project_name
        <> " from "
        <> string.inspect(billing_from)
      }
  }
}

// --- helpers -----------------------------------------------------------------

/// Dispatch one demo command through `command.dispatch` (actor "seed"), asserting
/// it succeeds. A failure `panic`s with the operation error so the seed gates loudly.
fn apply(ctx: Context, command: Command) -> Nil {
  case command.dispatch(ctx, actor: seed_actor, command: command) {
    Ok(_) -> Nil
    Error(error) ->
      panic as {
        "seed-financials: dispatching "
        <> string.inspect(command)
        <> " failed: "
        <> string.inspect(error)
      }
  }
}

/// List the invoices as of `as_of`, asserting the read succeeds.
fn list_invoices(ctx: Context, as_of: Date) -> List(Invoice) {
  let assert Ok(invoices) = finance_query.list_invoices(ctx, as_of)
  invoices
}

// --- day-index date arithmetic (mirrors the client's week math) --------------

const seconds_per_day = 86_400

/// 0 = Monday .. 6 = Sunday for a day index (epoch day 0 is a Thursday).
fn weekday_of(index: Int) -> Int {
  int.modulo(index + 3, 7) |> result.unwrap(0)
}

fn date_to_day_index(date: Date) -> Int {
  let instant = timestamp.from_calendar(date, midnight(), calendar.utc_offset)
  float.round(timestamp.to_unix_seconds(instant)) / seconds_per_day
}

fn day_index_to_date(index: Int) -> Date {
  let instant = timestamp.from_unix_seconds(index * seconds_per_day)
  let #(date, _time) = timestamp.to_calendar(instant, calendar.utc_offset)
  date
}

fn midnight() -> TimeOfDay {
  TimeOfDay(hours: 0, minutes: 0, seconds: 0, nanoseconds: 0)
}

/// Inclusive list of integers `from..to` (`[]` when `from > to`).
fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}
