//// Domain/API types shared by server and client. Must stay target-agnostic.
////
//// These are the API contract: the server maps Squirrel rows to them and the
//// client renders them, with `codecs.gleam` carrying the JSON between. The charge
//// rate is a plain value on the row, never "where it came from".
//// Date fields are `gleam/time/calendar.Date` — the same type Squirrel rows decode
//// to and `pog` parameters expect, so dates flow from the DB through these types to
//// the wire (and back on the client) without a boundary conversion. The codecs
//// still serialise them as ISO-8601 "YYYY-MM-DD" strings, unchanged on the wire.

import gleam/time/calendar.{type Date}

/// An engineer's situation on the org board for a date. Leave takes precedence
/// over an allocation in the read model: an engineer covered by a leave fact is
/// `OnLeave`, otherwise one `OnProject` per project they are allocated to. An
/// employed engineer with no allocation on the date is `Unassigned`.
pub type Engagement {
  /// Allocated to a project. `day_rate` is the resolved charge rate as a plain
  /// value.
  OnProject(
    project: String,
    client: String,
    fraction: Float,
    day_rate: Float,
    valid_from: Date,
    valid_to: Date,
  )
  /// Covered by a leave fact; the underlying allocation is suppressed. `kind` is
  /// the leave kind (annual | sick | parental | …); the period is the leave window.
  OnLeave(kind: String, valid_from: Date, valid_to: Date)
  /// Employed but not allocated (and not on leave) as of the date.
  Unassigned
}

/// One line on the org board: an engineer, their level on the date, and their
/// situation. Engaged engineers contribute one row per project; on-leave engineers
/// contribute a single `OnLeave` row.
pub type BoardRow {
  BoardRow(engineer: String, level: Int, engagement: Engagement)
}

/// The whole org board for a single date.
pub type BoardSnapshot {
  BoardSnapshot(date: Date, rows: List(BoardRow))
}

/// One cell of the weekly timesheet grid: a single (project, day) slot. `allocated`
/// is the cell's editability — true when an allocation to the project covers `date`
/// AND the engineer is not on leave that day; the grid disables the cell when false.
/// `hours` is the hours already logged for that cell (0.0 if none yet).
pub type TimesheetCell {
  TimesheetCell(date: Date, allocated: Bool, hours: Float)
}

/// One row of the weekly timesheet grid: a project the engineer is allocated to on
/// any day of the week, with one `cell` per column day. `cells` are ordered Mon..Sun,
/// aligned with the enclosing `TimesheetWeek.days`.
pub type TimesheetWeekRow {
  TimesheetWeekRow(project_id: Int, project: String, cells: List(TimesheetCell))
}

/// An engineer's weekly timesheet grid: the Mon..Sun `days` columns of the week
/// starting `week_start`, and one `row` per project allocated on any day of the week.
/// `days` is the 7 column dates (or `[]` when there are no rows). `rows` is empty
/// when the engineer has nothing to log all week (e.g. on leave all week).
pub type TimesheetWeek {
  TimesheetWeek(
    engineer_id: Int,
    week_start: Date,
    days: List(Date),
    rows: List(TimesheetWeekRow),
  )
}

/// One (project, day) entry of a `LogWeek` submission: the hours to set for that
/// cell. An `hours` of 0.0 clears the cell.
pub type TimesheetEntry {
  TimesheetEntry(project_id: Int, day: Date, hours: Float)
}

/// A directory entry: a durable subject's id paired with its display name. The
/// operations console renders these as `<select>` options — the `id` is the
/// option value (what `build_command` parses), the `name` the visible text —
/// so the presenter picks a name and the form still carries the id/name string
/// the command needs.
pub type Ref {
  Ref(id: Int, name: String)
}

/// The operations-console directory as-of a date (`GET /api/roster?as_of=`): the
/// engineers EMPLOYED on the date and the projects ACTIVE on the date (both
/// date-filtered so the console can only name a subject valid then), plus every
/// client (a durable identity with no validity window, so not date-filtered).
/// Each list is a `Ref` (id + name) the console turns into `<select>` options.
pub type Roster {
  Roster(engineers: List(Ref), projects: List(Ref), clients: List(Ref))
}

/// A validated timesheet write request: which engineer logs how many hours
/// against which project on which day. This decoded payload IS the POST
/// /api/timesheet contract — the client encodes it, the server decodes it, and
/// the domain logs it.
pub type WriteRequest {
  WriteRequest(engineer_id: Int, project_id: Int, day: Date, hours: Float)
}

/// The typed command vocabulary (the write model). One variant per business
/// operation: the client encodes a `Command`, the server decodes the same value
/// and dispatches it to the matching temporal write, then re-encodes it as the
/// `event_log` payload. Defined in `shared` so both ends agree on the contract.
///
/// The variants group into the four write patterns:
///   * Assert — `OnboardEngineer`, `SignContract`, `StartProject`,
///     `AssignToProject`, `TakeLeave`, `LogTimesheet`, `DraftInvoice`,
///     `RunPayroll`: plain inserts (the financial pair also compute their lines).
///   * Change — `Promote`, `ChangeAllocationFraction`, `ReviseRateCard`,
///     `SetSalary`, `IssueInvoice`, `PayInvoice`: "publish a new version effective
///     from a date" (`FOR PORTION OF … TO NULL`); the invoice transitions cap the
///     current status row and assert the next.
///   * Surgical — `AdjustRateForPortion`: bump a level's rate for a bounded
///     window (`FOR PORTION OF … FROM a TO b`).
///   * Close / cascade — `RollOff`, `TerminateEmployment`:
///     `DELETE … FOR PORTION OF`.
///
/// Date fields carry domain meaning: `effective` is the open-ended "from here on"
/// pivot of a change/close; `valid_from`/`valid_to` bound an asserted or surgical
/// period. Levels and ids are `Int`, fraction/hours/rate/salary are `Float`, and
/// name/kind/client are `String`.
pub type Command {
  /// Hire an engineer: create their identity, open-ended employment, and initial
  /// role, all from `effective`.
  OnboardEngineer(name: String, level: Int, effective: Date)
  /// Open a contract term for a client.
  SignContract(client: String, valid_from: Date, valid_to: Date)
  /// Start a project under a contract for a bounded active period.
  StartProject(name: String, contract_id: Int, valid_from: Date, valid_to: Date)
  /// Allocate an engineer to a project at a fraction for a period.
  AssignToProject(
    engineer_id: Int,
    project_id: Int,
    fraction: Float,
    valid_from: Date,
    valid_to: Date,
  )
  /// Put an engineer on leave of a kind for a period.
  TakeLeave(engineer_id: Int, kind: String, valid_from: Date, valid_to: Date)
  /// Log hours an engineer worked on a project on a day.
  LogTimesheet(engineer_id: Int, project_id: Int, day: Date, hours: Float)
  /// Log a whole week's hours atomically: each entry sets one (project, day) cell
  /// for the engineer; an `hours` of 0.0 clears that cell. Every entry commits or
  /// none.
  LogWeek(engineer_id: Int, entries: List(TimesheetEntry))
  /// Promote an engineer to a new level effective from a date.
  Promote(engineer_id: Int, level: Int, effective: Date)
  /// Change an engineer's allocation fraction on a project effective from a date.
  ChangeAllocationFraction(
    engineer_id: Int,
    project_id: Int,
    fraction: Float,
    effective: Date,
  )
  /// Publish a new day rate for a level effective from a date.
  ReviseRateCard(level: Int, day_rate: Float, effective: Date)
  /// Bump a level's day rate for a bounded window, splitting the rate-card row
  /// into before/during/after.
  AdjustRateForPortion(
    level: Int,
    day_rate: Float,
    valid_from: Date,
    valid_to: Date,
  )
  /// Cap an engineer's allocation on a project from a date (roll off the project).
  RollOff(engineer_id: Int, project_id: Int, effective: Date)
  /// Terminate an engineer's employment from a date, capping every contained fact.
  TerminateEmployment(engineer_id: Int, effective: Date)
  /// Publish a new monthly salary for a level effective from a date (the cost
  /// analogue of `ReviseRateCard`, via `FOR PORTION OF` on `salary`).
  SetSalary(level: Int, monthly_salary: Float, effective: Date)
  /// Draft an invoice for a project's billing month, computing its lines at the
  /// contract-agreed rate (`rate_card` as of the contract's signing date).
  DraftInvoice(project_id: Int, billing_from: Date, billing_to: Date)
  /// Transition an invoice `draft -> issued` at a date (a temporal status change).
  IssueInvoice(invoice_id: Int, at: Date)
  /// Transition an invoice `issued -> paid` at a date (a temporal status change).
  PayInvoice(invoice_id: Int, at: Date)
  /// Run payroll for a month, computing one prorated `payroll_line` per employed
  /// engineer (split by role so a mid-month promotion blends salaries).
  RunPayroll(period_from: Date, period_to: Date)
}

/// The POST /api/operations request body: an `actor` (who is applying the
/// operation — nominal, no auth) and the `Command` to apply. The client encodes
/// this envelope and the server decodes it, then dispatches the command on the
/// actor's behalf. Defined in `shared` so both ends agree on the contract.
pub type OperationRequest {
  OperationRequest(actor: String, command: Command)
}

/// One row of the provenance journal read model. The server appends an `Event`
/// per dispatched `Command` (the `operation` tag, a human `summary`, and the
/// command re-encoded as `payload`); the client renders the journal. `payload`
/// is carried as a raw JSON string so the journal view can show it verbatim
/// without re-decoding the original `Command` variant.
pub type Event {
  Event(
    id: Int,
    occurred_at: String,
    actor: String,
    operation: String,
    summary: String,
    payload: String,
  )
}

/// One invoice on the invoices-table read model (FR-F1/FR-F4): the durable subject
/// (`id`, `project`, `client`, the `billing_from`..`billing_to` month) plus its
/// `status` *as of* the selected date and its `total` (Σ line amounts). `status`
/// is the lifecycle word ("draft" | "issued" | "paid") covering the as-of date.
pub type Invoice {
  Invoice(
    id: Int,
    project: String,
    client: String,
    billing_from: Date,
    billing_to: Date,
    status: String,
    total: Float,
  )
}

/// One snapshot line of an invoice (FR-F1): the engineer who worked the project in
/// the period, their `level` during the work, the contract-agreed `day_rate`, the
/// allocation-weighted `days`, and `amount = days × day_rate`.
pub type InvoiceLine {
  InvoiceLine(
    engineer: String,
    level: Int,
    day_rate: Float,
    days: Float,
    amount: Float,
  )
}

/// The invoice-detail read model (`GET /api/invoices/:id`): the `invoice` header
/// and its computed `lines`.
pub type InvoiceDetail {
  InvoiceDetail(invoice: Invoice, lines: List(InvoiceLine))
}

/// One line of a payroll run (FR-F5/FR-F6): the engineer, the prorated `amount`
/// owed for the period, and the employed `days` it covers.
pub type PayrollLine {
  PayrollLine(engineer: String, amount: Float, days: Float)
}

/// A payroll run read model (`GET /api/payroll?period=`): the `period_from`..
/// `period_to` month and one `PayrollLine` per employed engineer.
pub type Payroll {
  Payroll(period_from: Date, period_to: Date, lines: List(PayrollLine))
}

/// One per-employee row of the P&L statement (FR-F8): the engineer's `revenue`
/// (their invoice lines), `cost` (their payroll line), `profit` (revenue − cost),
/// `margin_pct` (profit / revenue), and `utilization_pct` (billable share of
/// employed days).
pub type PnlRow {
  PnlRow(
    engineer: String,
    revenue: Float,
    cost: Float,
    profit: Float,
    margin_pct: Float,
    utilization_pct: Float,
  )
}

/// The P&L statement read model (`GET /api/pnl?as_of=`, FR-F7/FR-F8): month and
/// year-to-date totals for revenue/cost/profit, plus the per-employee `rows`.
pub type Pnl {
  Pnl(
    month_revenue: Float,
    month_cost: Float,
    month_profit: Float,
    ytd_revenue: Float,
    ytd_cost: Float,
    ytd_profit: Float,
    rows: List(PnlRow),
  )
}
