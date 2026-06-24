//// Domain/API types shared by server and client. Must stay target-agnostic.
////
//// These are the API contract: the server maps Squirrel rows to them and the
//// client renders them, with `codecs.gleam` carrying the JSON between. The charge
//// rate is a plain value on the row, never "where it came from".
//// Date fields are `gleam/time/calendar.Date` — the same type Squirrel rows decode
//// to and `pog` parameters expect, so dates flow from the DB through these types to
//// the wire (and back on the client) without a boundary conversion. The codecs
//// still serialise them as ISO-8601 "YYYY-MM-DD" strings, unchanged on the wire.

import gleam/option.{type Option}
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

/// An engineer's leave balances (days accrued − taken) for a date — the board
/// readout. Computed as-of, so it recomputes as the slider moves.
pub type LeaveBalance {
  LeaveBalance(engineer: String, annual: Float, sick: Float)
}

/// A project with no engineers staffed on the board's date — a candidate for the
/// Assign modal, which pre-fills `project_id` to skip a title->id round-trip.
pub type UnstaffedProject {
  UnstaffedProject(project_id: Int, title: String, client: String)
}

/// The whole org board for a single date: the engagement rows, each employed
/// engineer's leave balances as of that date, and the unstaffed projects lane.
pub type BoardSnapshot {
  BoardSnapshot(
    date: Date,
    rows: List(BoardRow),
    balances: List(LeaveBalance),
    unstaffed: List(UnstaffedProject),
  )
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

/// An engineer's contact details as one edit-grouped fact: the person's
/// `name`, `email`, `phone`, and `postal_address`. The underlying
/// `engineer_contact` table is period-keyed (`recorded_during`) and
/// append-only, read LATEST — so this record carries only the scalar fields of
/// the most-recently-recorded version, not its transaction-time bounds.
pub type EngineerContact {
  EngineerContact(
    engineer_id: Int,
    name: String,
    email: String,
    phone: String,
    postal_address: String,
  )
}

/// An engineer's banking details as one edit-grouped fact: `bank`, `branch`,
/// `account_no` (text, never numeric — it may carry leading zeros), and
/// `account_name`. Backed by the append-only `engineer_banking` table read
/// LATEST; this record is the most-recently-recorded version's scalar fields.
pub type EngineerBanking {
  EngineerBanking(
    engineer_id: Int,
    bank: String,
    branch: String,
    account_no: String,
    account_name: String,
  )
}

/// An engineer's emergency contact as one edit-grouped fact: the `relation`
/// (e.g. "spouse"), the contact's `name`, `phone`, and `email`. Backed by the
/// append-only `engineer_emergency` table read LATEST; this record is the
/// most-recently-recorded version's scalar fields.
pub type EngineerEmergency {
  EngineerEmergency(
    engineer_id: Int,
    relation: String,
    name: String,
    phone: String,
    email: String,
  )
}

/// A client's profile as one edit-grouped fact: the client's `name`. The
/// underlying `client_profile` table is period-keyed (`recorded_during`) and
/// append-only, read LATEST — so this record carries only the scalar fields of
/// the most-recently-recorded version, not its transaction-time bounds. A client
/// has only a name, so this is the client's single fact group (mirroring
/// `EngineerContact`).
pub type ClientProfile {
  ClientProfile(client_id: Int, name: String)
}

/// A project's profile as one edit-grouped fact: the project's `title` (the
/// human-facing name) and a free-text `summary`. The underlying
/// `project_profile` table is period-keyed (`recorded_during`) and append-only,
/// read LATEST — so this record carries only the scalar fields of the
/// most-recently-recorded version, not its transaction-time bounds (mirroring
/// `ClientProfile`).
pub type ProjectProfile {
  ProjectProfile(project_id: Int, title: String, summary: String)
}

/// A project's plan as one edit-grouped fact: the `budget` (a money amount, so
/// a `Float`) and a `target_completion` date. The underlying `project_plan`
/// table is period-keyed (`planned_during`) and append-only, read LATEST — so
/// this record carries only the scalar fields of the most-recently-recorded
/// version, not its transaction-time bounds.
pub type ProjectPlan {
  ProjectPlan(project_id: Int, budget: Float, target_completion: Date)
}

pub type EngineerCommand {
  OnboardEngineer(name: String, level: Int, effective: Date)
  /// Promote an engineer to a new level effective from a date.
  Promote(engineer_id: Int, level: Int, effective: Date)
  /// Terminate an engineer's employment from a date, capping every contained fact.
  TerminateEmployment(engineer_id: Int, effective: Date)
}

pub type AllocationCommand {
  /// Allocate an engineer to a project at a fraction for a period.
  AssignToProject(
    engineer_id: Int,
    project_id: Int,
    fraction: Float,
    valid_from: Date,
    valid_to: Date,
  )

  /// Change an engineer's allocation fraction on a project effective from a date.
  ChangeAllocationFraction(
    engineer_id: Int,
    project_id: Int,
    fraction: Float,
    effective: Date,
  )
  /// Cap an engineer's allocation on a project from a date (roll off the project).
  RollOff(engineer_id: Int, project_id: Int, effective: Date)
}

pub type EngagementCommand {
  /// Open a contract term for a client.
  SignContract(client: String, valid_from: Date, valid_to: Date)
  /// Start a project under a contract for a bounded active period.
  StartProject(name: String, contract_id: Int, valid_from: Date, valid_to: Date)
}

pub type LeaveCommand {
  /// Put an engineer on leave of a kind for a period.
  TakeLeave(engineer_id: Int, kind: String, valid_from: Date, valid_to: Date)
}

pub type TimesheetCommand {
  /// Log hours an engineer worked on a project on a day.
  LogTimesheet(engineer_id: Int, project_id: Int, day: Date, hours: Float)
  /// Log a whole week's hours atomically: each entry sets one (project, day) cell
  /// for the engineer; an `hours` of 0.0 clears that cell. Every entry commits or
  /// none.
  LogWeek(engineer_id: Int, entries: List(TimesheetEntry))
}

pub type EngineerDetailsCommand {
  /// Record new contact details for an engineer effective from a date: close
  /// the `engineer_contact` row covering `effective` and open a new full row
  /// `[effective, NULL)` carrying `name`/`email`/`phone`/`postal_address` (a
  /// temporal Change on the append-only contact fact).
  UpdateContactDetails(
    engineer_id: Int,
    name: String,
    email: String,
    phone: String,
    postal_address: String,
    effective: Date,
  )
  /// Record new banking details for an engineer effective from a date: close
  /// the `engineer_banking` row covering `effective` and open a new full row
  /// `[effective, NULL)` carrying `bank`/`branch`/`account_no`/`account_name`
  /// (a temporal Change on the append-only banking fact). `account_no` is text.
  UpdateBankingDetails(
    engineer_id: Int,
    bank: String,
    branch: String,
    account_no: String,
    account_name: String,
    effective: Date,
  )
  /// Record a new emergency contact for an engineer effective from a date:
  /// close the `engineer_emergency` row covering `effective` and open a new
  /// full row `[effective, NULL)` carrying `relation`/`name`/`phone`/`email`
  /// (a temporal Change on the append-only emergency fact).
  UpdateEmergencyContact(
    engineer_id: Int,
    relation: String,
    name: String,
    phone: String,
    email: String,
    effective: Date,
  )
}

pub type ClientDetailsCommand {
  /// Record a new profile for a client effective from a date: close the
  /// `client_profile` row covering `effective` and open a new full row
  /// `[effective, NULL)` carrying `name` (a temporal Change on the append-only
  /// client_profile fact). A client has only a name, so this is its single
  /// Update command.
  UpdateClientProfile(client_id: Int, name: String, effective: Date)
}

pub type ProjectDetailsCommand {
  /// Record a new profile for a project effective from a date: close the
  /// `project_profile` row covering `effective` and open a new full row
  /// `[effective, NULL)` carrying `title`/`summary` (a temporal Change on the
  /// append-only project_profile fact). `title` is the project's human-facing
  /// name.
  UpdateProjectProfile(
    project_id: Int,
    title: String,
    summary: String,
    effective: Date,
  )
  /// Record a new plan for a project effective from a date: close the
  /// `project_plan` row covering `effective` and open a new full row
  /// `[effective, NULL)` carrying `budget`/`target_completion` (a temporal
  /// Change on the append-only project_plan fact). `budget` is a money amount.
  UpdateProjectPlan(
    project_id: Int,
    budget: Float,
    target_completion: Date,
    effective: Date,
  )
}

pub type RateCardCommand {
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
}

pub type SalaryCommand {
  /// Publish a new monthly salary for a level effective from a date (the cost
  /// analogue of `ReviseRateCard`, via `FOR PORTION OF` on `salary`).
  SetSalary(level: Int, monthly_salary: Float, effective: Date)
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
  EngineerCommand(EngineerCommand)
  AllocationCommand(AllocationCommand)
  EngagementCommand(EngagementCommand)
  LeaveCommand(LeaveCommand)
  TimesheetCommand(TimesheetCommand)
  EngineerDetailsCommand(EngineerDetailsCommand)
  ClientDetailsCommand(ClientDetailsCommand)
  ProjectDetailsCommand(ProjectDetailsCommand)
  RateCardCommand(RateCardCommand)
  SalaryCommand(SalaryCommand)

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
  /// Set a project's capacity requirement (demand) at a level for a bounded
  /// window: a FOR-PORTION-OF write on `(project_id, level)`, splitting the
  /// requirement row into before/during/after. `quantity` is fractional FTE.
  SetProjectRequirement(
    project_id: Int,
    level: Int,
    quantity: Float,
    valid_from: Date,
    valid_to: Date,
  )
}

/// The POST /api/operations request body: just the `Command` to apply. The
/// `actor` is NO LONGER carried here — it would be forgeable (issue #6). The
/// server derives the actor from the authenticated session (a signed cookie) and
/// stamps it on the journal, so the body cannot dictate who a change is
/// attributed to. Defined in `shared` so both ends agree on the contract.
pub type OperationRequest {
  OperationRequest(command: Command)
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
/// `issued_at`/`paid_at` are the dates those transitions took effect (the lower
/// bound of the issued/paid status span), each `None` until that transition has
/// happened as of the view — so the UI can show "Issued <date>" / "Paid <date>".
pub type Invoice {
  Invoice(
    id: Int,
    project: String,
    client: String,
    billing_from: Date,
    billing_to: Date,
    status: String,
    total: Float,
    issued_at: Option(Date),
    paid_at: Option(Date),
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

/// Identifies the materialized payroll run for a month (FR-F5/FR-F6) once it
/// exists; absent from the `Payroll` envelope until `RunPayroll` has been done.
pub type PayrollRunInfo {
  PayrollRunInfo(run_id: Int)
}

/// One engineer's line in the month's payroll panel. `preview_amount`/
/// `preview_days` are the LIVE recompute over current facts (always present).
/// `paid_amount`/`paid_days` are the MATERIALIZED values frozen at run time
/// (`None` until a run exists). Variance Δ = preview_amount - paid_amount.
pub type PayrollLine {
  PayrollLine(
    engineer: String,
    preview_amount: Float,
    preview_days: Float,
    paid_amount: Option(Float),
    paid_days: Option(Float),
  )
}

/// A month's payroll read model (`GET /api/payroll?period=`): the
/// `period_from`..`period_to` month, the materialized `run` (`None` until
/// `RunPayroll`), and one `PayrollLine` per employed engineer.
pub type Payroll {
  Payroll(
    period_from: Date,
    period_to: Date,
    run: Option(PayrollRunInfo),
    lines: List(PayrollLine),
  )
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

/// An engineer's roster situation collapsed to a single cell for the people list
/// (distinct from `Engagement`, which is one row per project). Several allocations
/// fold into one `RosterOnProjects` carrying the project titles; a covering leave
/// fact wins as `RosterOnLeave`; an employed engineer with neither is
/// `RosterUnassigned`. Band is NOT a wire field — it is a client-side label
/// derived from `level`.
pub type RosterStatus {
  RosterOnLeave(kind: String)
  RosterOnProjects(projects: List(String))
  RosterUnassigned
}

/// One row of the people list (`GET /api/people?as_of=`): an employed engineer
/// with their `level`, roster `status`, summed `allocated_fraction` as-of (0.0 on
/// bench/leave), `annual_balance` (annual leave days), and the level's resolved
/// `day_rate` (charge rate). Present for ALL employed engineers, not just
/// allocated ones. Band is derived client-side from `level`.
pub type PersonRow {
  PersonRow(
    engineer_id: Int,
    name: String,
    email: String,
    level: Int,
    status: RosterStatus,
    allocated_fraction: Float,
    annual_balance: Float,
    day_rate: Float,
  )
}

/// The people list for a single date: every employed engineer's `PersonRow`
/// as-of the `date` (mirrors `BoardSnapshot`'s date + rows shape).
pub type PeopleList {
  PeopleList(date: Date, people: List(PersonRow))
}

/// An engineer's employment fact as-of a date: when they `started`, their `level`,
/// and their `monthly_salary` (a cost figure). Assembled from the range-only
/// employment row joined to `engineer_role` (level) and `salary` (monthly_salary)
/// as-of. Band is derived client-side from `level`.
pub type Employment {
  Employment(engineer_id: Int, started: Date, level: Int, monthly_salary: Float)
}

/// One version of an engineer's role history (a `engineer_role` period decomposed
/// to plain dates): the `level` held over `[valid_from, valid_to)`. Band is
/// derived client-side from `level`.
pub type RoleVersion {
  RoleVersion(level: Int, valid_from: Date, valid_to: Date)
}

/// One row of an engineer's allocation history: the project they were allocated to
/// at a `fraction` over `[valid_from, valid_to)`, with `active` true when the
/// period covers the detail's as-of date (the date marks rows active/ended, it
/// does not hide them).
pub type AllocationRow {
  AllocationRow(
    project_id: Int,
    project: String,
    fraction: Float,
    valid_from: Date,
    valid_to: Date,
    active: Bool,
  )
}

/// One row of an engineer's leave history: a leave `kind` over the leave window
/// `[valid_from, valid_to)`.
pub type LeaveRecord {
  LeaveRecord(kind: String, valid_from: Date, valid_to: Date)
}

/// The engineer-detail read model (`GET /api/engineers/:id?as_of=`): the engineer's
/// `name`/`level`, their current contact/banking/emergency facts, the as-of
/// `employment`, their full `roles`/`allocations`/`leave_history`, and their
/// leave `balance` (annual + sick). The timesheet is a separate fetch. Band is
/// derived client-side from `level`.
pub type EngineerDetail {
  EngineerDetail(
    engineer_id: Int,
    name: String,
    level: Int,
    contact: EngineerContact,
    banking: EngineerBanking,
    emergency: EngineerEmergency,
    employment: Employment,
    roles: List(RoleVersion),
    allocations: List(AllocationRow),
    balance: LeaveBalance,
    leave_history: List(LeaveRecord),
  )
}

/// One contract term on the client-detail read model: the `contract_id` and its
/// term `[valid_from, valid_to)`, with `active` true when the term covers the
/// detail's as-of date (active/ended derived as of the date).
pub type ContractRow {
  ContractRow(contract_id: Int, valid_from: Date, valid_to: Date, active: Bool)
}

/// One project of a client on the client-detail read model: the project's `title`,
/// `budget`, `target_completion`, its run period `[valid_from, valid_to)`, with
/// `active` true when the run covers the detail's as-of date.
pub type ClientProjectRow {
  ClientProjectRow(
    project_id: Int,
    title: String,
    budget: Float,
    target_completion: Date,
    valid_from: Date,
    valid_to: Date,
    active: Bool,
  )
}

/// The client-detail read model (`GET /api/clients/:id?as_of=`): the client's
/// `profile`, their `since` date (the earliest contract's start, `None` when the
/// client has no contracts), and their `contracts`/`projects` with active/ended
/// flags computed as-of. The profile name is durable (latest-read), as-of only
/// drives the per-row `active` flags.
pub type ClientDetail {
  ClientDetail(
    profile: ClientProfile,
    since: Option(Date),
    contracts: List(ContractRow),
    projects: List(ClientProjectRow),
  )
}

/// One row of the clients list (`GET /api/clients?as_of=`): a client's `name`,
/// `since` (earliest contract start, `None` when contractless), `project_count`,
/// and `active` (true when any contract covers the as-of date).
pub type ClientListRow {
  ClientListRow(
    client_id: Int,
    name: String,
    since: Option(Date),
    project_count: Int,
    active: Bool,
  )
}

/// The clients list for a single date (mirrors `PeopleList`): the `date` and one
/// `ClientListRow` per client.
pub type ClientList {
  ClientList(date: Date, clients: List(ClientListRow))
}

/// One row of the projects list (`GET /api/projects?as_of=`): a project's `title`,
/// `client` name, `budget`, `target_completion`, `team_size` (allocations covering
/// the as-of date), and `active` (true when its run covers the as-of date).
pub type ProjectListRow {
  ProjectListRow(
    project_id: Int,
    title: String,
    client: String,
    budget: Float,
    target_completion: Date,
    team_size: Int,
    active: Bool,
  )
}

/// The projects list for a single date (mirrors `PeopleList`): the `date` and one
/// `ProjectListRow` per project.
pub type ProjectList {
  ProjectList(date: Date, projects: List(ProjectListRow))
}

/// One member of a project's team on the project-detail read model: the engineer's
/// `name`, `level`, allocation `fraction`, and resolved `day_rate`. Carries
/// `engineer_id` so the team card can click through to the engineer detail. Band
/// is derived client-side from `level`.
pub type TeamMember {
  TeamMember(
    engineer_id: Int,
    name: String,
    level: Int,
    fraction: Float,
    day_rate: Float,
  )
}

/// One capacity requirement on the project-detail read model (demand): the project
/// needs `quantity` FTE at a given `level` over `[valid_from, valid_to)`. One line
/// per `(project, level)` over non-overlapping periods. Independent of which
/// engineers (if any) fill it — the roles may need to be hired.
pub type ProjectRequirement {
  ProjectRequirement(
    project_id: Int,
    level: Int,
    quantity: Float,
    valid_from: Date,
    valid_to: Date,
  )
}

/// One month of the forecast (`GET /api/forecast?as_of=`): the first-of-`month`
/// Date (the client formats it) and the projected `revenue`, `cost`, `profit`, and
/// `margin_pct` from committed demand for that month.
pub type ForecastMonth {
  ForecastMonth(
    month: Date,
    revenue: Float,
    cost: Float,
    profit: Float,
    margin_pct: Float,
  )
}

/// The forecast read model (`GET /api/forecast?as_of=`): one `ForecastMonth` per
/// calendar month from the as-of month to the cliff.
pub type Forecast {
  Forecast(months: List(ForecastMonth))
}

/// The project-detail read model (`GET /api/projects/:id?as_of=`): the project's
/// `profile` and `plan`, its `client` name, its run period `[valid_from, valid_to)`
/// with `active` (covers the as-of date), its `team` as-of, its capacity
/// `requirements` (demand), and its `invoices`.
pub type ProjectDetail {
  ProjectDetail(
    profile: ProjectProfile,
    client: String,
    plan: ProjectPlan,
    valid_from: Date,
    valid_to: Date,
    active: Bool,
    team: List(TeamMember),
    requirements: List(ProjectRequirement),
    invoices: List(Invoice),
  )
}

/// One row of the rate card on the settings read model: the current `day_rate`
/// (charge rate) for a `level` as-of the date.
pub type RateCardRow {
  RateCardRow(level: Int, day_rate: Float)
}

/// One row of the salary table on the settings read model: the current
/// `monthly_salary` (cost) for a `level` as-of the date.
pub type SalaryRow {
  SalaryRow(level: Int, monthly_salary: Float)
}

/// One row of the leave policy on the settings read model: the `days_per_year`
/// allowance for a `(kind, level)` pair as-of the date. A `(kind, level)` with no
/// policy row is unlimited (absent from the list).
pub type LeavePolicyRow {
  LeavePolicyRow(kind: String, level: Int, days_per_year: Float)
}

/// The settings read model (`GET /api/settings?as_of=`): the `date` and the
/// current `rate_card`, `salaries`, and `leave_policy` lists as-of that date.
pub type Settings {
  Settings(
    date: Date,
    rate_card: List(RateCardRow),
    salaries: List(SalaryRow),
    leave_policy: List(LeavePolicyRow),
  )
}
