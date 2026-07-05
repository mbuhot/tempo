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
//// records (and in what order — a containing fact before the facts contained by it)
//// and the audit entry the command produces; the repository decides HOW each fact is
//// written (a fresh assert, a change from a date onward, a bounded surgical edit, or
//// a cap + cascade). An anchor is NOT a fact: it is minted by `repository.create_*`,
//// which inserts the id-only row and returns the strongly-typed id the facts carry.
////
//// Period convention: `from` alone is an open-ended span `[from, ∞)` (the change
//// pattern — recording it supersedes the prior version from `from` onward). `from` +
//// `to` is a bounded span `[from, to)`. Where `to` is `Option`, `None` is the
//// open-ended change and `Some` the bounded form (assign vs re-fraction; revise vs
//// surgical portion).

import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/money.{type Money}
import tempo/server/operation.{type Event}

/// What a command records: its journal `entry` (the audit log row) plus the `facts`
/// it produced, in write order (a containing fact before the facts contained by it).
/// A handler returns this; `command.dispatch` hands both to
/// `repository.record_facts`, which appends the entry, sets the audit context, and
/// writes the facts in one transaction.
pub type Recorded {
  Recorded(entry: Event, facts: List(Fact))
}

/// Strongly-typed anchor ids. An anchor is minted by `repository.create_*`, which
/// reserves the id, inserts the id-only anchor row, and returns the typed id; that id
/// then threads into every fact contained by (or describing) the anchor, so the type
/// system keeps, say, an engineer id out of a project-id position. `ClientId` has no
/// `create_client` — clients are registered only by the seed — but client facts still
/// carry it typed.
pub type EngineerId {
  EngineerId(Int)
}

pub type ContractId {
  ContractId(Int)
}

pub type ProjectId {
  ProjectId(Int)
}

pub type InvoiceId {
  InvoiceId(Int)
}

pub type PayrollRunId {
  PayrollRunId(Int)
}

pub type ClientId {
  ClientId(Int)
}

pub type CapabilityId {
  CapabilityId(Int)
}

pub type SkillId {
  SkillId(Int)
}

pub type MeetingId {
  MeetingId(Int)
}

pub type Fact {
  // --- engineer ---------------------------------------------------------------
  /// The engineer is employed from `from` onward (open-ended). Ended by
  /// `EngineerDeparted`.
  EngineerEmployed(engineer_id: EngineerId, from: Date)
  /// The engineer has departed from `from`: employment is capped and every fact
  /// contained by it (allocation, leave, role) is capped to match.
  EngineerDeparted(engineer_id: EngineerId, from: Date)
  /// The engineer holds `level` from `from` onward (change from a date onward; the
  /// first one, at onboard, opens the span).
  EngineerAtLevel(engineer_id: EngineerId, level: Int, from: Date)
  /// The engineer's contact details in force from `from` onward.
  EngineerContactDetails(
    engineer_id: EngineerId,
    name: String,
    email: String,
    phone: String,
    postal_address: String,
    from: Date,
  )
  /// The engineer's banking details in force from `from` onward.
  EngineerBankingDetails(
    engineer_id: EngineerId,
    bank: String,
    branch: String,
    account_no: String,
    account_name: String,
    from: Date,
  )
  /// The engineer's emergency contact in force from `from` onward.
  EngineerEmergencyContact(
    engineer_id: EngineerId,
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
    engineer_id: EngineerId,
    project_id: ProjectId,
    fraction: Float,
    from: Date,
    to: Option(Date),
  )
  /// The engineer is off the project from `from`: that one allocation is capped.
  EngineerOffProject(engineer_id: EngineerId, project_id: ProjectId, from: Date)
  /// The engineer is on `kind` leave over `[from, to)`.
  EngineerOnLeave(engineer_id: EngineerId, kind: String, from: Date, to: Date)

  // --- rates & salary ---------------------------------------------------------
  /// A level's billable day rate. `None` revises it from `from` onward; `Some(to)`
  /// is a bounded surgical edit over `[from, to)`.
  RateCard(level: Int, day_rate: Money, from: Date, to: Option(Date))
  /// A level's monthly salary from `from` onward.
  Salary(level: Int, monthly_salary: Money, from: Date)

  // --- engagement -------------------------------------------------------------
  /// A contract's term with a client over `[from, to)`.
  ContractTerms(contract_id: ContractId, client: String, from: Date, to: Date)
  /// A project's run under its contract over `[from, to)`.
  ProjectRun(
    project_id: ProjectId,
    contract_id: ContractId,
    from: Date,
    to: Date,
  )
  /// A project's profile (title/summary) in force from `from` onward.
  ProjectProfile(
    project_id: ProjectId,
    title: String,
    summary: String,
    from: Date,
  )
  /// A project's plan (budget/target) in force from `from` onward.
  ProjectPlan(
    project_id: ProjectId,
    budget: Money,
    target_completion: Date,
    from: Date,
  )
  /// A project's whole plan moved to a new [from, to) run window.
  ProjectRescheduled(project_id: ProjectId, from: Date, to: Date)
  /// A project's capacity requirement (demand): `quantity` FTE at `level` over the
  /// bounded span `[from, to)`. A FOR-PORTION-OF set on `(project_id, level)`.
  ProjectRequirement(
    project_id: ProjectId,
    level: Int,
    quantity: Float,
    from: Date,
    to: Date,
  )
  /// A project's capability demand: `quantity` engineers at `target_level`
  /// proficiency in a capability over the bounded span `[from, to)`. A
  /// FOR-PORTION-OF set on `(project_id, capability_id)`.
  ProjectCapabilityRequired(
    project_id: ProjectId,
    capability_id: CapabilityId,
    target_level: Int,
    quantity: Float,
    from: Date,
    to: Date,
  )

  // --- client -----------------------------------------------------------------
  /// A client's profile in force from `from` onward.
  ClientProfile(client_id: ClientId, name: String, from: Date)

  // --- timesheet --------------------------------------------------------------
  /// Hours an engineer worked on a project on a day (0 clears the day).
  EngineerWorkedHours(
    engineer_id: EngineerId,
    project_id: ProjectId,
    day: Date,
    hours: Float,
  )

  // --- invoice & payroll ------------------------------------------------------
  /// The subject of an invoice: the project billed and its billing month `[from, to)`.
  InvoiceSubject(
    invoice_id: InvoiceId,
    project_id: ProjectId,
    from: Date,
    to: Date,
  )
  /// The invoice is in `status` from `from` onward (the prior status is capped at
  /// `from`).
  InvoiceInStatus(invoice_id: InvoiceId, status: String, from: Date)
  /// A billed line on an invoice: the engineer, level, agreed day rate, days, and
  /// amount.
  InvoiceLine(
    invoice_id: InvoiceId,
    engineer_id: EngineerId,
    level: Int,
    day_rate: Money,
    days: Float,
    amount: Money,
  )
  /// The period a payroll run covers, `[from, to)`.
  PayrollPeriod(run_id: PayrollRunId, from: Date, to: Date)
  /// A line on a payroll run: the engineer, prorated amount owed, and employed days.
  PayrollLine(
    run_id: PayrollRunId,
    engineer_id: EngineerId,
    amount: Money,
    days: Float,
  )
  /// A frozen per-level segment of a payroll line: the level, the monthly salary at
  /// that level, the pro-rated days, and the amount. The segments of a (run,
  /// engineer) sum back to its `PayrollLine` total — the breakdown a mid-month
  /// promotion or salary revision splits into.
  PayrollLineSegment(
    run_id: PayrollRunId,
    engineer_id: EngineerId,
    level: Int,
    monthly_salary: Money,
    days: Float,
    amount: Money,
  )

  // --- access control ---------------------------------------------------------
  /// An account holds `role` from `from` onward (open-ended; a re-grant re-opens it).
  UserRoleGranted(account_id: Int, role: String, from: Date)
  /// An account's `role` is revoked from `from`: the held period is capped there.
  UserRoleRevoked(account_id: Int, role: String, from: Date)

  // --- skills taxonomy ---------------------------------------------------------
  /// A capability's profile (name/summary) in force from `from` onward.
  CapabilityProfile(
    capability_id: CapabilityId,
    name: String,
    summary: String,
    from: Date,
  )
  /// A capability is retired from `from`: its profile and its skill mappings are
  /// capped there.
  CapabilityRetired(capability_id: CapabilityId, from: Date)
  /// A skill contributes `weight` to a capability's composition from `from` onward.
  CapabilitySkillSet(
    capability_id: CapabilityId,
    skill_id: SkillId,
    weight: Int,
    from: Date,
  )
  /// A skill is removed from a capability's composition from `from`: that one
  /// mapping is capped.
  CapabilitySkillRemoved(
    capability_id: CapabilityId,
    skill_id: SkillId,
    from: Date,
  )
  /// A skill's profile (name/summary) in force from `from` onward.
  SkillProfile(skill_id: SkillId, name: String, summary: String, from: Date)
  /// A skill is retired from `from`: its profile and every capability's mapping to
  /// it are capped there.
  SkillRetired(skill_id: SkillId, from: Date)
  /// An engineer is assessed at `level` on a skill from `from` onward (open-ended;
  /// a re-assessment re-opens it).
  EngineerSkillAssessed(
    engineer_id: EngineerId,
    skill_id: SkillId,
    level: Int,
    from: Date,
  )

  // --- scheduling ---------------------------------------------------------------
  /// The engineer is located in `country`/`region` on IANA TZID `timezone` from
  /// `from` onward (change from a date onward; a relocation re-opens it).
  EngineerLocated(
    engineer_id: EngineerId,
    country: String,
    region: Option(String),
    timezone: String,
    from: Date,
  )

  // --- meeting -------------------------------------------------------------------
  /// A meeting's detail (composed instant range, title, location, client/project) as
  /// scheduled. Plain mutable row; a reschedule is `MeetingRescheduled`, a cancel is
  /// `MeetingCancelled`.
  MeetingScheduled(
    meeting_id: MeetingId,
    date: Date,
    starts_at: String,
    duration_minutes: Int,
    timezone: String,
    title: String,
    location: Option(String),
    client_id: Option(Int),
    project_id: Option(Int),
  )
  /// The meeting moves in place to a new date/start/duration/timezone.
  MeetingRescheduled(
    meeting_id: MeetingId,
    date: Date,
    starts_at: String,
    duration_minutes: Int,
    timezone: String,
  )
  /// The meeting is cancelled.
  MeetingCancelled(meeting_id: MeetingId)
  /// An engineer is added (or re-marked) as an attendee of the meeting.
  MeetingAttendeeAdded(
    meeting_id: MeetingId,
    engineer_id: Int,
    attendance: String,
  )
  /// An attendee is removed from the meeting.
  MeetingAttendeeRemoved(meeting_id: MeetingId, engineer_id: Int)
}
