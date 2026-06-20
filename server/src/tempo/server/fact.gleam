//// The facts the system records — the typed information schema. Each variant is a
//// thing that holds over time (a state with a validity period), NOT an event that
//// happened; `repository` maps each to the SQL that makes the database reflect it.
//// The temporal database preserves the history (a new version per change); the only
//// history a fact loses is a back-dated edit that overwrites an earlier value, which
//// the event_log audits. Each recorded fact also carries an `audit_id` FK to the
//// event_log entry of the command that wrote it (filled by the repository, not a
//// field here).
////
//// This is the event-sourced shape without the event-log+projection machinery: the
//// facts ARE the rows, recorded directly. A handler decides WHICH facts a command
//// records (and in what order — anchors before the facts contained by them) and the
//// audit entry the command produces; the repository decides HOW each fact is written
//// (a fresh assert, a change from a date onward, a bounded surgical edit, or a cap +
//// cascade).
////
//// Period convention: `from` alone is an open-ended span `[from, ∞)` (the change
//// pattern — recording it supersedes the prior version from `from` onward). `from` +
//// `to` is a bounded span `[from, to)`. Where `to` is `Option`, `None` is the
//// open-ended change and `Some` the bounded form (assign vs re-fraction; revise vs
//// surgical portion).

import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import tempo/server/operation.{type Event}

/// What a command records: its journal `entry` (the audit log row) plus the `facts`
/// it produced, in write order (anchors first, then the facts contained by them).
/// A handler returns this; `command.dispatch` hands both to
/// `repository.record_facts`, which appends the entry, sets the audit context, and
/// writes the facts in one transaction.
pub type Recorded {
  Recorded(entry: Event, facts: List(Fact))
}

pub type Fact {
  // --- identity anchors (must precede the facts contained by them) ------------
  /// Engineer `id` is on the books (the ID-ONLY anchor).
  Engineer(id: Int)
  /// Contract `id` exists (the ID-ONLY anchor).
  Contract(id: Int)
  /// Project `id` exists (the ID-ONLY anchor).
  Project(id: Int)
  /// Invoice `id` exists (the ID-ONLY anchor).
  Invoice(id: Int)
  /// Payroll run `id` exists (the ID-ONLY anchor).
  PayrollRun(id: Int)

  // --- engineer ---------------------------------------------------------------
  /// The engineer is employed from `from` onward (open-ended). Ended by
  /// `EngineerDeparted`.
  EngineerEmployed(engineer_id: Int, from: Date)
  /// The engineer has departed from `from`: employment is capped and every fact
  /// contained by it (allocation, leave, role) is capped to match.
  EngineerDeparted(engineer_id: Int, from: Date)
  /// The engineer holds `level` from `from` onward (change from a date onward; the
  /// first one, at onboard, opens the span).
  EngineerAtLevel(engineer_id: Int, level: Int, from: Date)
  /// The engineer's contact details in force from `from` onward.
  EngineerContactDetails(
    engineer_id: Int,
    name: String,
    email: String,
    phone: String,
    postal_address: String,
    from: Date,
  )
  /// The engineer's banking details in force from `from` onward.
  EngineerBankingDetails(
    engineer_id: Int,
    bank: String,
    branch: String,
    account_no: String,
    account_name: String,
    from: Date,
  )
  /// The engineer's emergency contact in force from `from` onward.
  EngineerEmergencyContact(
    engineer_id: Int,
    relation: String,
    name: String,
    phone: String,
    email: String,
    from: Date,
  )

  // --- allocation & leave -----------------------------------------------------
  /// The engineer is allocated to the project at `fraction`. `Some(to)` is a fresh
  /// bounded assignment `[from, to)`; `None` re-fractions the version in effect at
  /// `from` onward.
  EngineerAllocatedToProject(
    engineer_id: Int,
    project_id: Int,
    fraction: Float,
    from: Date,
    to: Option(Date),
  )
  /// The engineer is off the project from `from`: that one allocation is capped.
  EngineerOffProject(engineer_id: Int, project_id: Int, from: Date)
  /// The engineer is on `kind` leave over `[from, to)`.
  EngineerOnLeave(engineer_id: Int, kind: String, from: Date, to: Date)

  // --- rates & salary ---------------------------------------------------------
  /// A level's billable day rate. `None` revises it from `from` onward; `Some(to)`
  /// is a bounded surgical edit over `[from, to)`.
  RateCard(level: Int, day_rate: Float, from: Date, to: Option(Date))
  /// A level's monthly salary from `from` onward.
  Salary(level: Int, monthly_salary: Float, from: Date)

  // --- engagement -------------------------------------------------------------
  /// A contract's term with a client over `[from, to)`.
  ContractTerms(contract_id: Int, client: String, from: Date, to: Date)
  /// A project's run under its contract over `[from, to)`.
  ProjectRun(project_id: Int, contract_id: Int, from: Date, to: Date)
  /// A project's profile (title/summary) in force from `from` onward.
  ProjectProfile(project_id: Int, title: String, summary: String, from: Date)
  /// A project's plan (budget/target) in force from `from` onward.
  ProjectPlan(
    project_id: Int,
    budget: Float,
    target_completion: Date,
    from: Date,
  )

  // --- client -----------------------------------------------------------------
  /// A client's profile in force from `from` onward.
  ClientProfile(client_id: Int, name: String, from: Date)

  // --- timesheet --------------------------------------------------------------
  /// Hours an engineer worked on a project on a day (0 clears the day).
  EngineerWorkedHours(
    engineer_id: Int,
    project_id: Int,
    day: Date,
    hours: Float,
  )

  // --- invoice & payroll ------------------------------------------------------
  /// The subject of an invoice: the project billed and its billing month `[from, to)`.
  InvoiceSubject(invoice_id: Int, project_id: Int, from: Date, to: Date)
  /// The invoice is in `status` from `from` onward (the prior status is capped at
  /// `from`).
  InvoiceInStatus(invoice_id: Int, status: String, from: Date)
  /// A billed line on an invoice: the engineer, level, agreed day rate, days, and
  /// amount.
  InvoiceLine(
    invoice_id: Int,
    engineer_id: Int,
    level: Int,
    day_rate: Float,
    days: Float,
    amount: Float,
  )
  /// The period a payroll run covers, `[from, to)`.
  PayrollPeriod(run_id: Int, from: Date, to: Date)
  /// A line on a payroll run: the engineer, prorated amount owed, and employed days.
  PayrollLine(run_id: Int, engineer_id: Int, amount: Float, days: Float)
}
