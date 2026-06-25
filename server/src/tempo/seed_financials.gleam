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
////   * PAYROLL — one run per month for EVERY month Jan 2024 – Jun 2026 (30 runs),
////     not just the invoice window: the P&L cost is a SNAPSHOT of materialized
////     payroll runs overlapping the window, so a month with employed engineers but
////     no run reads revenue at $0 cost. Allocations (revenue) start 2024-01-01, so a
////     run per month back to then keeps the per-engineer P&L cost accurate at any
////     as-of date.
//// Financials are computed from allocations/role/salary/rate-card, not the
//// timesheet (P&L utilization is capacity-based), so the timesheets are the work
//// record the My-timesheet grid shows rather than an input to the billing.
////
//// IDEMPOTENCY is PER-SCENARIO so a partial DB tops up only what is missing rather
//// than skipping the whole seed when ANY invoice exists (which once skipped payroll
//// on a partial DB): timesheets are logged only if absent; each month's invoices are
//// drafted/progressed only if that month's invoice is absent; each month's payroll is
//// run only if no run covers it; the back-dated variance promotion is applied only if
//// absent. Each step is independently safe to re-run. Each write goes through
//// `command.dispatch` (actor "seed"); a failing operation `panic`s (non-zero exit) so
//// a broken seed gates loudly. It reuses `invoice/view.list_invoices` to resolve a
//// freshly-drafted invoice's minted id by project NAME and billing month rather than
//// adding a new query.
////
//// VARIANCE DEMO: after the monthly runs it records a back-dated promotion of
//// Priya (engineer 1) L5 -> L6 effective 2026-05-01 — into the already-run MAY month.
//// The May run froze her line at the L5 salary ($10,000); the back-dated promotion
//// lifts the LIVE recompute to the L6 salary ($14,000), so the Payroll tab at May
//// reads the ⚠ back-pay-owed / Δ state out of the box. Priya bills Ledger/Inventory,
//// not Data Platform, so this does not touch the Data-Platform invoice totals.

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
import shared/command.{type Command} as gateway
import shared/engineer/command as engineer_command
import shared/invoice/command as invoice_command
import shared/invoice/view.{type Invoice}
import shared/payroll/command as payroll_command
import shared/timesheet/command as timesheet_command
import tempo/server/auth.{Admin, Principal}
import tempo/server/command
import tempo/server/context.{type Context}
import tempo/server/engineer/sql as engineer_sql
import tempo/server/event
import tempo/server/invoice/view as invoice_read
import tempo/server/payroll/view as payroll_read
import tempo/server/timesheet/sql as timesheet_sql
import tempo/server/web/cursor

/// The principal every demo command is dispatched as: actor "seed" (stamped on
/// every `event_log` row), with the `Admin` role so the financial demo commands
/// (invoices, payroll, salary) pass the authorization gate.
const seed_principal = Principal(actor: "seed", role: Admin)

/// The back-dated variance demo: promote Priya (engineer 1) from her seeded L5 to L6,
/// effective the start of the already-run MAY month. The L6 salary band ($14,000)
/// exists in the base seed, and Priya bills Ledger/Inventory (not Data Platform), so
/// the promotion lifts only her own May payroll preview — not any invoice total.
const variance_engineer_id = 1

const variance_level = 6

const variance_effective = Date(2026, May, 1)

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
/// dev DB and replay the demo pipeline; each step tops up only what is missing, so a
/// partial DB fills in the rest and a full DB is a no-op. `panic`s (non-zero exit) on
/// the first failure.
pub fn main() -> Nil {
  let assert Ok(ctx) = context.start()
  seed(ctx)
}

/// Replay the demo pipeline against the (already-migrated) dev DB, PER-SCENARIO
/// idempotent: log Jan–Jun timesheets (if absent), draft + progress each month's
/// invoices (if that month's invoice is absent), run payroll for every month from the
/// start of operations through Jun 2026 (each month if no run covers it), then apply
/// the back-dated variance promotion (if absent). Each write asserts `Ok`. Prints a
/// one-line summary.
fn seed(ctx: Context) -> Nil {
  log_timesheets(ctx)
  list.each(month_plans(), fn(plan) { bill_month(ctx, plan) })
  run_monthly_payrolls(ctx)
  apply_variance_promotion(ctx)
  io.println(
    "seed-financials: ensured Jan–Jun 2026 timesheets, 18 invoices "
    <> "(Jan–Mar paid, Apr–May issued, Jun draft), a payroll run for every month "
    <> "Jan 2024 – Jun 2026, and the back-dated May variance promotion (Priya "
    <> "L5->L6).",
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
/// loggable. Skipped wholesale when timesheets are already present (re-logging a week
/// would mint duplicate entries).
fn log_timesheets(ctx: Context) -> Nil {
  case timesheets_present(ctx) {
    True -> Nil
    False -> log_all_timesheets(ctx)
  }
}

/// True when engineer 1 already has any hours logged in the first seed week — the
/// signal the timesheet scenario has run before.
fn timesheets_present(ctx: Context) -> Bool {
  let first_monday =
    day_index_to_date(
      date_to_day_index(Date(2026, January, 1))
      - weekday_of(date_to_day_index(Date(2026, January, 1))),
    )
  let assert Ok(returned) =
    timesheet_sql.timesheet_week(ctx.db, 1, first_monday)
  list.any(returned.rows, fn(row) { row.hours >. 0.0 })
}

fn log_all_timesheets(ctx: Context) -> Nil {
  let period_start = date_to_day_index(Date(2026, January, 1))
  let period_end = date_to_day_index(Date(2026, June, 30))
  list.each(workers(), fn(worker) {
    list.each(mondays_in(period_start, period_end), fn(monday) {
      case week_entries(worker, monday, period_start, period_end) {
        [] -> Nil
        entries -> {
          // Submitted at the end of the working week (its Friday), clamped to the
          // period for the final partial week — that is when the entry is recorded.
          let submitted_on = day_index_to_date(int.min(monday + 4, period_end))
          apply(
            ctx,
            gateway.TimesheetCommand(timesheet_command.LogWeek(
              engineer_id: worker.engineer_id,
              entries:,
            )),
            submitted_on,
          )
        }
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
) -> List(timesheet_command.TimesheetEntry) {
  int_range(0, 4)
  |> list.map(fn(offset) { monday + offset })
  |> list.filter(fn(index) { index >= start && index <= end })
  |> list.map(day_index_to_date)
  |> list.filter(fn(day) { !on_leave(worker, day) })
  |> list.flat_map(fn(day) {
    list.map(worker.daily, fn(work) {
      let #(project_id, hours) = work
      timesheet_command.TimesheetEntry(project_id:, day:, hours:)
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

/// Bill every project for the month (draft → issue → pay per the plan). Each event is
/// recorded at the date it would naturally happen: invoices are prepared at month end
/// and issued/paid on their issue/pay date. PER-SCENARIO idempotent: a project's
/// invoice is drafted + progressed only if that month's invoice is absent — so a
/// partial DB tops up exactly the gaps. Payroll is no longer run here; it is a
/// separate pass over EVERY month (see `run_monthly_payrolls`).
fn bill_month(ctx: Context, plan: MonthPlan) -> Nil {
  let month_end = day_index_to_date(date_to_day_index(plan.to) - 1)
  list.each(billable_projects, fn(project) {
    let #(project_id, project_name) = project
    case existing_invoice_id(ctx, project_name, plan.from) {
      Some(_) -> Nil
      None -> bill_project(ctx, project_id, project_name, plan, month_end)
    }
  })
}

/// The inclusive month range payroll must cover: from the start of operations (Priya's
/// 2024-01-01 employment + allocation, the earliest revenue) through the June 2026
/// demo "now". Each is a month START; the run window is `[month_start, next month)`.
const payroll_from = Date(2024, January, 1)

const payroll_through = Date(2026, June, 1)

/// Run payroll for EVERY month from `payroll_from` through `payroll_through`
/// (inclusive), so the per-engineer P&L cost — a SNAPSHOT of payroll runs overlapping
/// the window — is populated for every month with employed engineers, not only the
/// Jan–Jun 2026 invoice window (without a run, such a month reads revenue at $0 cost).
/// Recorded at each month's end. PER-MONTH idempotent: a month already covered by a
/// run is skipped (the payroll_period EXCLUDE-overlap would refuse a duplicate
/// anyway). Runs BEFORE the variance promotion, so the May 2026 run still froze
/// Priya's L5 line.
fn run_monthly_payrolls(ctx: Context) -> Nil {
  list.each(month_starts(payroll_from, payroll_through), fn(month_start) {
    let month_after = next_month_start(month_start)
    case payroll_run_present(ctx, month_start, month_after) {
      True -> Nil
      False -> {
        let month_end = day_index_to_date(date_to_day_index(month_after) - 1)
        apply(
          ctx,
          gateway.PayrollCommand(payroll_command.RunPayroll(
            period_from: month_start,
            period_to: month_after,
          )),
          month_end,
        )
      }
    }
  })
}

/// Draft one project's invoice for the month and progress it (issue, then pay) per
/// the plan, recording each event at the date it would naturally happen.
fn bill_project(
  ctx: Context,
  project_id: Int,
  project_name: String,
  plan: MonthPlan,
  month_end: Date,
) -> Nil {
  apply(
    ctx,
    gateway.InvoiceCommand(invoice_command.DraftInvoice(
      project_id:,
      billing_from: plan.from,
      billing_to: plan.to,
    )),
    month_end,
  )
  case plan.issue {
    None -> Nil
    Some(issue_at) -> {
      let invoice_id = drafted_invoice_id(ctx, project_name, plan.from)
      apply(
        ctx,
        gateway.InvoiceCommand(invoice_command.IssueInvoice(
          invoice_id:,
          at: issue_at,
        )),
        issue_at,
      )
      case plan.pay {
        None -> Nil
        Some(pay_at) ->
          apply(
            ctx,
            gateway.InvoiceCommand(invoice_command.PayInvoice(
              invoice_id:,
              at: pay_at,
            )),
            pay_at,
          )
      }
    }
  }
}

/// The minted id of the invoice for `project_name` whose billing month starts at
/// `billing_from` if one already exists, else `None` — the per-project guard that
/// keeps `bill_month` from re-drafting a month already billed.
fn existing_invoice_id(
  ctx: Context,
  project_name: String,
  billing_from: Date,
) -> Option(Int) {
  list_invoices(ctx, billing_from)
  |> list.find(fn(invoice) {
    invoice.project == project_name && invoice.billing_from == billing_from
  })
  |> result.map(fn(invoice) { invoice.id })
  |> option.from_result
}

/// True when a materialized payroll run already covers the month `[from, to)` — the
/// per-month guard that keeps `bill_month` from re-running a month (which the
/// payroll_period EXCLUDE-overlap constraint would refuse anyway).
fn payroll_run_present(ctx: Context, from: Date, to: Date) -> Bool {
  let assert Ok(payroll) = payroll_read.payroll(ctx, from, to)
  payroll.run != None
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

// --- back-dated variance promotion -------------------------------------------

/// Record the back-dated promotion that surfaces a payroll variance: Priya L5 -> L6
/// effective the start of the already-run May month. The May run froze her line at
/// the L5 salary; this lifts the live recompute to L6, so the May Payroll tab shows
/// the ⚠ back-pay-owed / Δ state. Recorded on 2026-06-01 (after the six runs, so the
/// run captured the OLD salary). Skipped if Priya already holds the target level over
/// the effective date — so re-running is a no-op (a re-promote to the same level from
/// the same date is a FOR-PORTION-OF no-op anyway, but the guard avoids a dangling
/// journal entry).
fn apply_variance_promotion(ctx: Context) -> Nil {
  case variance_promotion_present(ctx) {
    True -> Nil
    False ->
      apply(
        ctx,
        gateway.EngineerCommand(engineer_command.Promote(
          engineer_id: variance_engineer_id,
          level: variance_level,
          effective: variance_effective,
        )),
        Date(2026, June, 1),
      )
  }
}

/// True when Priya already holds the variance target level over the effective date —
/// the signal the back-dated promotion has been applied before.
fn variance_promotion_present(ctx: Context) -> Bool {
  let assert Ok(returned) =
    engineer_sql.engineer_role_history(ctx.db, variance_engineer_id)
  let effective_index = date_to_day_index(variance_effective)
  list.any(returned.rows, fn(role) {
    role.level == variance_level
    && date_to_day_index(role.valid_from) <= effective_index
    && effective_index < date_to_day_index(role.valid_to)
  })
}

// --- helpers -----------------------------------------------------------------

/// Dispatch one demo command through `command.dispatch` (as the seed principal,
/// actor "seed"), then
/// backdate the journal event it appended to `occurred_on` — the date the
/// operation would naturally have been entered — so the demo journal reads as a
/// realistic timeline rather than all at the instant the seed ran. A failure
/// `panic`s with the operation error so the seed gates loudly.
fn apply(ctx: Context, command: Command, occurred_on: Date) -> Nil {
  case command.dispatch(ctx, principal: seed_principal, command: command) {
    Error(error) ->
      panic as {
        "seed-financials: dispatching "
        <> string.inspect(command)
        <> " failed: "
        <> string.inspect(error)
      }
    Ok(created) ->
      case event.set_occurred_at(ctx, created.id, occurred_on) {
        Ok(Nil) -> Nil
        Error(error) ->
          panic as {
            "seed-financials: backdating event "
            <> string.inspect(created.id)
            <> " failed: "
            <> string.inspect(error)
          }
      }
  }
}

/// List the invoices as of `as_of`, asserting the read succeeds. The seed needs
/// the whole ledger to resolve a project's invoice, so it reads the first keyset
/// page at the max page size (the seed has far fewer invoices than that).
fn list_invoices(ctx: Context, as_of: Date) -> List(Invoice) {
  let assert Ok(#(invoices, _next_cursor)) =
    invoice_read.list_invoices(
      ctx,
      as_of,
      cursor.date_id_start(),
      context.max_page_limit,
    )
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

/// Every first-of-month from `from` through `through` (both first-of-month),
/// inclusive of both ends.
fn month_starts(from: Date, through: Date) -> List(Date) {
  case date_to_day_index(from) > date_to_day_index(through) {
    True -> []
    False -> [from, ..month_starts(next_month_start(from), through)]
  }
}

/// The first day of the month following `date`'s month (rolling over the year).
fn next_month_start(date: Date) -> Date {
  case calendar.month_from_int(calendar.month_to_int(date.month) + 1) {
    Ok(month) -> Date(date.year, month, 1)
    Error(Nil) -> Date(date.year + 1, January, 1)
  }
}

/// Inclusive list of integers `from..to` (`[]` when `from > to`).
fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}
