//// The persistence seam: mint identity anchors (`create_*` — reserve the id with
//// `nextval`, insert the id-only row, return its strongly-typed id) and record a list
//// of `Fact`s (`record_facts`), each mapped to the SQL that makes the database reflect
//// it, on the caller's in-transaction connection (`command.dispatch` owns the
//// transaction, so all of a command's facts commit together or roll back together).
//// A database rejection is classified into a typed `OperationError` by constraint
//// name (via `operation.try`/`operation.run`).
////
//// This module is the ONE place a fact's write SEMANTIC lives, so handlers stay
//// declarative — they say WHICH facts a command records, the repository says HOW:
////   - a bounded assert is a plain insert;
////   - an open-ended versioned attribute (level, details, profile/plan, client) is a
////     temporal upsert (`*_upsert`): ONE statement changes the version covering `from`
////     (FOR PORTION OF … TO NULL) and opens the first span only if none yet exists — so
////     the founding write at onboard/start_project and a later edit are the SAME fact;
////   - a rate is a revise (`None`) or a bounded surgical edit (`Some(to)`);
////   - an allocation is a fresh bounded assign (`Some(to)`) or a re-fraction (`None`);
////   - an invoice status is a cap-then-open (the prior status ends where the next
////     begins);
////   - worked hours is a delete-then-insert upsert (0 clears the day);
////   - a retraction (`EngineerOffProject`, `EngineerDeparted`) caps the span —
////     departure cascades the cap to allocations, leave, role, and skill; retiring
////     a capability or skill cascades the cap to the capability_skill mappings it
////     owns, leaving engineer_skill assessments open.
////
//// `record_facts` first appends the command's journal `entry` to `event_log`, then
//// writes each fact, passing the appended entry's id as the `audit_id` every fact
//// carries (its FK back to the command that recorded it). A revise SETs audit_id on
//// the changed portion; PG copies the original onto the carved-off leftover. A
//// delete (a retraction's cap) leaves no row, so its provenance lives only in
//// event_log.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/command.{type Event}
import shared/money
import tempo/server/allocation/sql as allocation_sql
import tempo/server/capability/sql as capability_sql
import tempo/server/client/sql as client_sql
import tempo/server/engineer/sql as engineer_sql
import tempo/server/engineer_skill/sql as engineer_skill_sql
import tempo/server/event
import tempo/server/fact.{
  type CapabilityId, type ClientId, type ContractId, type EngineerId, type Fact,
  type InvoiceId, type PayrollRunId, type ProjectId, type SkillId, CapabilityId,
  CapabilityProfile, CapabilityRetired, CapabilitySkillRemoved,
  CapabilitySkillSet, ClientId, ClientProfile, ContractId, ContractTerms,
  EngineerAllocatedToProject, EngineerAtLevel, EngineerBankingDetails,
  EngineerContactDetails, EngineerDeparted, EngineerEmergencyContact,
  EngineerEmployed, EngineerId, EngineerLocated, EngineerOffProject,
  EngineerOnLeave, EngineerSkillAssessed, EngineerWorkedHours, InvoiceId,
  InvoiceInStatus, InvoiceLine, InvoiceSubject, PayrollLine, PayrollLineSegment,
  PayrollPeriod, PayrollRunId, ProjectCapabilityRequired, ProjectId, ProjectPlan,
  ProjectProfile, ProjectRequirement, ProjectRun, RateCard, Salary, SkillId,
  SkillProfile, SkillRetired, UserRoleGranted, UserRoleRevoked,
}
import tempo/server/invoice/sql as invoice_sql
import tempo/server/leave/sql as leave_sql
import tempo/server/location/sql as location_sql
import tempo/server/operation.{type Event as JournalEntry, type OperationError}
import tempo/server/payroll/sql as payroll_sql
import tempo/server/project/sql as project_sql
import tempo/server/project_capability/sql as project_capability_sql
import tempo/server/rate_card/sql as rate_card_sql
import tempo/server/role/sql as role_sql
import tempo/server/salary/sql as salary_sql
import tempo/server/skill/sql as skill_sql
import tempo/server/timesheet/sql as timesheet_sql

/// Mint an engineer anchor: reserve its id (`nextval`), insert the id-only row, and
/// return the strongly-typed `EngineerId` a handler threads into every fact about the
/// engineer (so the type system keeps it out of a project-id position). The anchor row
/// carries no `audit_id` — an anchor is not a fact — but it shares the command's
/// transaction, so it rolls back with the facts if any of them is rejected.
pub fn create_engineer(
  conn: pog.Connection,
) -> Result(EngineerId, OperationError) {
  use returned <- operation.try(engineer_sql.engineer_next_id(conn))
  let assert [row] = returned.rows
  use _ <- result.try(
    engineer_sql.engineer_create(conn, row.id) |> operation.run,
  )
  Ok(EngineerId(row.id))
}

/// Mint a client anchor (reserve id, insert the id-only row), returning its typed id.
pub fn create_client(conn: pog.Connection) -> Result(ClientId, OperationError) {
  use returned <- operation.try(client_sql.client_next_id(conn))
  let assert [row] = returned.rows
  use _ <- result.try(client_sql.client_create(conn, row.id) |> operation.run)
  Ok(ClientId(row.id))
}

/// Mint a contract anchor (reserve id, insert the id-only row), returning its typed id.
pub fn create_contract(
  conn: pog.Connection,
) -> Result(ContractId, OperationError) {
  use returned <- operation.try(client_sql.contract_next_id(conn))
  let assert [row] = returned.rows
  use _ <- result.try(client_sql.contract_create(conn, row.id) |> operation.run)
  Ok(ContractId(row.id))
}

/// Mint a project anchor (reserve id, insert the id-only row), returning its typed id.
pub fn create_project(
  conn: pog.Connection,
) -> Result(ProjectId, OperationError) {
  use returned <- operation.try(project_sql.project_next_id(conn))
  let assert [row] = returned.rows
  use _ <- result.try(project_sql.project_create(conn, row.id) |> operation.run)
  Ok(ProjectId(row.id))
}

/// Mint an invoice anchor (reserve id, insert the id-only row), returning its typed id.
pub fn create_invoice(
  conn: pog.Connection,
) -> Result(InvoiceId, OperationError) {
  use returned <- operation.try(invoice_sql.invoice_next_id(conn))
  let assert [row] = returned.rows
  use _ <- result.try(invoice_sql.invoice_create(conn, row.id) |> operation.run)
  Ok(InvoiceId(row.id))
}

/// Mint a capability anchor (reserve id, insert the id-only row), returning its typed
/// id.
pub fn create_capability(
  conn: pog.Connection,
) -> Result(CapabilityId, OperationError) {
  use returned <- operation.try(capability_sql.capability_next_id(conn))
  let assert [row] = returned.rows
  use _ <- result.try(
    capability_sql.capability_create(conn, row.id) |> operation.run,
  )
  Ok(CapabilityId(row.id))
}

/// Mint a skill anchor (reserve id, insert the id-only row), returning its typed id.
pub fn create_skill(conn: pog.Connection) -> Result(SkillId, OperationError) {
  use returned <- operation.try(skill_sql.skill_next_id(conn))
  let assert [row] = returned.rows
  use _ <- result.try(skill_sql.skill_create(conn, row.id) |> operation.run)
  Ok(SkillId(row.id))
}

/// Mint a payroll-run anchor (reserve id, insert the id-only row), returning its typed
/// id.
pub fn create_payroll_run(
  conn: pog.Connection,
) -> Result(PayrollRunId, OperationError) {
  use returned <- operation.try(payroll_sql.payroll_run_next_id(conn))
  let assert [row] = returned.rows
  use _ <- result.try(
    payroll_sql.payroll_run_create(conn, row.id) |> operation.run,
  )
  Ok(PayrollRunId(row.id))
}

/// Record a command's outcome in one transaction: append its journal `entry` (the
/// `event_log` row), then write each fact in order, stamping each with the appended
/// entry's id as its `audit_id`. Returns the persisted journal event (the row the
/// database minted). Short-circuits on the first rejection, returning its typed
/// `OperationError`; the caller's transaction then rolls them all back.
pub fn record_facts(
  conn: pog.Connection,
  actor actor: String,
  entry entry: JournalEntry,
  facts facts: List(Fact),
) -> Result(Event, OperationError) {
  use appended <- result.try(
    event.append(conn, actor:, event: entry)
    |> result.map_error(operation.classify),
  )
  use _ <- result.try(
    list.try_map(facts, fn(a_fact) { write(conn, appended.id, a_fact) })
    |> result.replace(Nil),
  )
  Ok(appended)
}

/// Write one fact under `audit_id` (the recording command's event_log id): map it to
/// the SQL that makes the database reflect it, passing `audit_id` to every insert and
/// revise, and unwrapping the strongly-typed anchor id in the pattern. Deletes (a
/// retraction's cap) carry no audit_id. Anchors are not facts — they are minted by
/// `create_*`, so they never reach here.
fn write(
  conn: pog.Connection,
  audit_id: Int,
  a_fact: Fact,
) -> Result(Nil, OperationError) {
  case a_fact {
    // --- engineer -------------------------------------------------------------
    EngineerEmployed(engineer_id: EngineerId(engineer_id), from:) ->
      engineer_sql.employment_open(conn, engineer_id, from, audit_id)
      |> operation.run

    EngineerDeparted(engineer_id: EngineerId(engineer_id), from:) ->
      record_departure(conn, engineer_id, from)

    EngineerAtLevel(engineer_id: EngineerId(engineer_id), level:, from:) ->
      engineer_sql.engineer_role_upsert(
        conn,
        engineer_id,
        from,
        level,
        audit_id,
      )
      |> require_covering_version

    EngineerContactDetails(
      engineer_id: EngineerId(engineer_id),
      name:,
      email:,
      phone:,
      postal_address:,
      from:,
    ) ->
      engineer_sql.engineer_contact_upsert(
        conn,
        engineer_id,
        from,
        name,
        email,
        phone,
        postal_address,
        audit_id,
      )
      |> operation.run

    EngineerBankingDetails(
      engineer_id: EngineerId(engineer_id),
      bank:,
      branch:,
      account_no:,
      account_name:,
      from:,
    ) ->
      engineer_sql.engineer_banking_upsert(
        conn,
        engineer_id,
        from,
        bank,
        branch,
        account_no,
        account_name,
        audit_id,
      )
      |> operation.run

    EngineerEmergencyContact(
      engineer_id: EngineerId(engineer_id),
      relation:,
      name:,
      phone:,
      email:,
      from:,
    ) ->
      engineer_sql.engineer_emergency_upsert(
        conn,
        engineer_id,
        from,
        relation,
        name,
        phone,
        email,
        audit_id,
      )
      |> operation.run

    // --- allocation & leave ---------------------------------------------------
    EngineerAllocatedToProject(
      engineer_id: EngineerId(engineer_id),
      project_id: ProjectId(project_id),
      fraction:,
      from:,
      to:,
    ) ->
      case to {
        Some(to_date) ->
          allocation_sql.allocation_assign(
            conn,
            engineer_id,
            project_id,
            from,
            fraction,
            to_date,
            audit_id,
          )
          |> operation.run
        None ->
          allocation_sql.allocation_change_fraction(
            conn,
            engineer_id,
            project_id,
            from,
            fraction,
            audit_id,
          )
          |> operation.run
      }

    EngineerOffProject(
      engineer_id: EngineerId(engineer_id),
      project_id: ProjectId(project_id),
      from:,
    ) ->
      allocation_sql.allocation_close(conn, engineer_id, project_id, from)
      |> operation.run

    EngineerOnLeave(engineer_id: EngineerId(engineer_id), kind:, from:, to:) ->
      leave_sql.leave_take(conn, engineer_id, kind, from, to, audit_id)
      |> operation.run

    // --- rates & salary -------------------------------------------------------
    RateCard(level:, day_rate:, from:, to:) ->
      case to {
        None ->
          rate_card_sql.rate_card_revise(
            conn,
            from,
            money.to_string(day_rate),
            level,
            audit_id,
          )
          |> require_covering_version
        Some(to_date) ->
          rate_card_sql.rate_card_for_portion_of(
            conn,
            from,
            to_date,
            money.to_string(day_rate),
            level,
            audit_id,
          )
          |> operation.run
      }

    Salary(level:, monthly_salary:, from:) ->
      salary_sql.salary_revise(
        conn,
        from,
        money.to_string(monthly_salary),
        level,
        audit_id,
      )
      |> require_covering_version

    // --- engagement -----------------------------------------------------------
    ContractTerms(contract_id: ContractId(contract_id), client:, from:, to:) ->
      client_sql.contract_terms_open(
        conn,
        contract_id,
        client,
        from,
        to,
        audit_id,
      )
      |> operation.run

    ProjectRun(
      project_id: ProjectId(project_id),
      contract_id: ContractId(contract_id),
      from:,
      to:,
    ) ->
      project_sql.project_run_open(
        conn,
        project_id,
        contract_id,
        from,
        to,
        audit_id,
      )
      |> operation.run

    ProjectProfile(project_id: ProjectId(project_id), title:, summary:, from:) ->
      project_sql.project_profile_upsert(
        conn,
        project_id,
        from,
        title,
        summary,
        audit_id,
      )
      |> operation.run

    ProjectPlan(
      project_id: ProjectId(project_id),
      budget:,
      target_completion:,
      from:,
    ) ->
      project_sql.project_plan_upsert(
        conn,
        project_id,
        from,
        money.to_string(budget),
        target_completion,
        audit_id,
      )
      |> operation.run

    ProjectRequirement(
      project_id: ProjectId(project_id),
      level:,
      quantity:,
      from:,
      to:,
    ) ->
      record_requirement(conn, audit_id, project_id, level, quantity, from, to)

    ProjectCapabilityRequired(
      project_id: ProjectId(project_id),
      capability_id: CapabilityId(capability_id),
      target_level:,
      quantity:,
      from:,
      to:,
    ) ->
      record_capability_requirement(
        conn,
        audit_id,
        project_id,
        capability_id,
        target_level,
        quantity,
        from,
        to,
      )

    // --- client ---------------------------------------------------------------
    ClientProfile(client_id: ClientId(client_id), name:, from:) ->
      client_sql.client_profile_upsert(conn, client_id, from, name, audit_id)
      |> operation.run

    // --- timesheet ------------------------------------------------------------
    EngineerWorkedHours(
      engineer_id: EngineerId(engineer_id),
      project_id: ProjectId(project_id),
      day:,
      hours:,
    ) -> record_hours(conn, audit_id, engineer_id, project_id, day, hours)

    // --- invoice & payroll ----------------------------------------------------
    InvoiceSubject(
      invoice_id: InvoiceId(invoice_id),
      project_id: ProjectId(project_id),
      from:,
      to:,
    ) ->
      invoice_sql.invoice_subject_insert(
        conn,
        invoice_id,
        project_id,
        from,
        to,
        audit_id,
      )
      |> operation.run

    InvoiceInStatus(invoice_id: InvoiceId(invoice_id), status:, from:) -> {
      use _ <- operation.try(invoice_sql.invoice_status_close(
        conn,
        invoice_id,
        from,
      ))
      invoice_sql.invoice_status_open(conn, invoice_id, status, from, audit_id)
      |> operation.run
    }

    InvoiceLine(
      invoice_id: InvoiceId(invoice_id),
      engineer_id: EngineerId(engineer_id),
      level:,
      day_rate:,
      days:,
      amount:,
    ) ->
      invoice_sql.invoice_line_insert(
        conn,
        invoice_id,
        engineer_id,
        level,
        money.to_string(day_rate),
        days,
        money.to_string(amount),
        audit_id,
      )
      |> operation.run

    PayrollPeriod(run_id: PayrollRunId(run_id), from:, to:) ->
      payroll_sql.payroll_period_insert(conn, run_id, from, to, audit_id)
      |> operation.run

    PayrollLine(
      run_id: PayrollRunId(run_id),
      engineer_id: EngineerId(engineer_id),
      amount:,
      days:,
    ) ->
      payroll_sql.payroll_line_insert(
        conn,
        run_id,
        engineer_id,
        money.to_string(amount),
        days,
        audit_id,
      )
      |> operation.run

    PayrollLineSegment(
      run_id: PayrollRunId(run_id),
      engineer_id: EngineerId(engineer_id),
      level:,
      monthly_salary:,
      days:,
      amount:,
    ) ->
      payroll_sql.payroll_line_segment_insert(
        conn,
        run_id,
        engineer_id,
        level,
        money.to_string(monthly_salary),
        days,
        money.to_string(amount),
        audit_id,
      )
      |> operation.run

    // --- access control -------------------------------------------------------
    UserRoleGranted(account_id:, role:, from:) ->
      role_sql.user_role_grant(conn, account_id, role, from, audit_id)
      |> operation.run

    UserRoleRevoked(account_id:, role:, from:) ->
      role_sql.user_role_revoke(conn, account_id, role, from)
      |> operation.run

    // --- skills taxonomy --------------------------------------------------------
    CapabilityProfile(
      capability_id: CapabilityId(capability_id),
      name:,
      summary:,
      from:,
    ) ->
      capability_sql.capability_profile_upsert(
        conn,
        capability_id,
        from,
        name,
        summary,
        audit_id,
      )
      |> operation.run

    CapabilityRetired(capability_id: CapabilityId(capability_id), from:) ->
      record_capability_retirement(conn, capability_id, from)

    CapabilitySkillSet(
      capability_id: CapabilityId(capability_id),
      skill_id: SkillId(skill_id),
      weight:,
      from:,
    ) ->
      capability_sql.capability_skill_upsert(
        conn,
        capability_id,
        skill_id,
        from,
        weight,
        audit_id,
      )
      |> operation.run

    CapabilitySkillRemoved(
      capability_id: CapabilityId(capability_id),
      skill_id: SkillId(skill_id),
      from:,
    ) ->
      capability_sql.capability_skill_remove(
        conn,
        capability_id,
        skill_id,
        from,
      )
      |> operation.run

    SkillProfile(skill_id: SkillId(skill_id), name:, summary:, from:) ->
      skill_sql.skill_profile_upsert(
        conn,
        skill_id,
        from,
        name,
        summary,
        audit_id,
      )
      |> operation.run

    SkillRetired(skill_id: SkillId(skill_id), from:) ->
      record_skill_retirement(conn, skill_id, from)

    EngineerSkillAssessed(
      engineer_id: EngineerId(engineer_id),
      skill_id: SkillId(skill_id),
      level:,
      from:,
    ) ->
      engineer_skill_sql.engineer_skill_upsert(
        conn,
        engineer_id,
        skill_id,
        from,
        level,
        audit_id,
      )
      |> require_covering_version

    EngineerLocated(
      engineer_id: EngineerId(engineer_id),
      country:,
      region:,
      timezone:,
      from:,
    ) ->
      location_sql.engineer_location_upsert(
        conn,
        engineer_id,
        from,
        country,
        option.unwrap(region, ""),
        timezone,
        audit_id,
      )
      |> operation.run
  }
}

/// Assert a temporal write (`salary`/`rate_card` revise, `engineer_role` promote,
/// `engineer_skill` assess) actually matched a covering row: its `RETURNING` rows
/// are empty exactly when no version (or no employment) covered the effective
/// date, so the write's `FOR PORTION OF` clause or `FROM employment` join matched
/// nothing. A bare `operation.run` discards the rows and reports `Ok` for that
/// no-op, journalling a change that never happened; this rejects it as a typed
/// `NoSuchVersion` so the caller's transaction rolls the journal entry back too.
fn require_covering_version(
  result: Result(pog.Returned(a), pog.QueryError),
) -> Result(Nil, OperationError) {
  use returned <- operation.try(result)
  case returned.rows {
    [] -> Error(operation.NoSuchVersion)
    [_, ..] -> Ok(Nil)
  }
}

/// Record worked hours as a per-day delete-then-insert upsert (the WITHOUT OVERLAPS
/// PK is not an ON CONFLICT target); 0 hours just clears the day. The timesheet
/// PERIOD FK (`timesheet_within_allocation`) classifies via `operation.try` as the
/// unified `ContainmentViolated` when the day is not covered by an allocation.
fn record_hours(
  conn: pog.Connection,
  audit_id: Int,
  engineer_id: Int,
  project_id: Int,
  day: Date,
  hours: Float,
) -> Result(Nil, OperationError) {
  use _ <- operation.try(timesheet_sql.timesheet_delete(
    conn,
    engineer_id,
    project_id,
    day,
  ))
  case hours == 0.0 {
    True -> Ok(Nil)
    False ->
      timesheet_sql.timesheet_write(
        conn,
        engineer_id,
        project_id,
        day,
        hours,
        audit_id,
      )
      |> operation.run
  }
}

/// Record a project's capacity requirement as a FOR-PORTION-OF set on
/// `(project_id, level)`: carve the target window out of any covering rows (the
/// before/after remainders re-insert at their original quantity), then insert the
/// new demand line. The WITHOUT OVERLAPS PK is not an ON CONFLICT target, so this is
/// a clear-then-set run in ONE transaction. The insert's PERIOD-FK
/// (`requirement_within_project`) classifies via `operation.run` as
/// `ContainmentViolated` when the window is not covered by the project's run.
fn record_requirement(
  conn: pog.Connection,
  audit_id: Int,
  project_id: Int,
  level: Int,
  quantity: Float,
  from: Date,
  to: Date,
) -> Result(Nil, OperationError) {
  use _ <- operation.try(project_sql.project_requirement_clear(
    conn,
    project_id,
    from,
    to,
    level,
  ))
  project_sql.project_requirement_set(
    conn,
    project_id,
    from,
    to,
    level,
    quantity,
    audit_id,
  )
  |> operation.run
}

/// Record a project's capability demand as a FOR-PORTION-OF set on
/// `(project_id, capability_id)`: carve the target window out of any covering
/// rows (the before/after remainders re-insert at their original
/// target_level/quantity), then insert the new demand line. The WITHOUT
/// OVERLAPS PK is not an ON CONFLICT target, so this is a clear-then-set run in
/// ONE transaction. The insert's PERIOD-FK (`project_capability_within_run`)
/// classifies via `operation.run` as `ContainmentViolated` when the window is
/// not covered by the project's run.
fn record_capability_requirement(
  conn: pog.Connection,
  audit_id: Int,
  project_id: Int,
  capability_id: Int,
  target_level: Int,
  quantity: Float,
  from: Date,
  to: Date,
) -> Result(Nil, OperationError) {
  use _ <- operation.try(project_capability_sql.project_capability_clear(
    conn,
    project_id,
    from,
    to,
    capability_id,
  ))
  project_capability_sql.project_capability_set(
    conn,
    project_id,
    from,
    to,
    capability_id,
    target_level,
    quantity,
    audit_id,
  )
  |> operation.run
}

/// Record an engineer's departure from `from`: cap every fact contained by the
/// employment FIRST — allocation → leave → role → skill — then the employment
/// itself. The PERIOD FKs both force that order and verify completeness: a child
/// left dangling past `from` rejects the whole transaction. These are deletes, so
/// they carry no audit_id (a retraction's provenance lives only in event_log).
fn record_departure(
  conn: pog.Connection,
  engineer_id: Int,
  from: Date,
) -> Result(Nil, OperationError) {
  use _ <- operation.try(allocation_sql.allocation_close_all(
    conn,
    engineer_id,
    from,
  ))
  use _ <- operation.try(leave_sql.leave_close_all(conn, engineer_id, from))
  use _ <- operation.try(engineer_sql.engineer_role_close_all(
    conn,
    engineer_id,
    from,
  ))
  use _ <- operation.try(engineer_skill_sql.engineer_skill_close_all(
    conn,
    engineer_id,
    from,
  ))
  engineer_sql.employment_close(conn, engineer_id, from) |> operation.run
}

/// Record a capability's retirement from `from`: cap its skill mappings first,
/// then its profile. `engineer_skill` rows stay open — the rollup reads join
/// through the taxonomy as-of, so a retired capability's mappings simply drop out.
fn record_capability_retirement(
  conn: pog.Connection,
  capability_id: Int,
  from: Date,
) -> Result(Nil, OperationError) {
  use _ <- operation.try(capability_sql.capability_skill_close_for_capability(
    conn,
    capability_id,
    from,
  ))
  capability_sql.capability_profile_close(conn, capability_id, from)
  |> operation.run
}

/// Record a skill's retirement from `from`: cap every capability's mapping to it
/// first, then its profile. `engineer_skill` rows stay open — the rollup reads
/// join through the taxonomy as-of, so a retired skill simply drops out.
fn record_skill_retirement(
  conn: pog.Connection,
  skill_id: Int,
  from: Date,
) -> Result(Nil, OperationError) {
  use _ <- operation.try(skill_sql.capability_skill_close_for_skill(
    conn,
    skill_id,
    from,
  ))
  skill_sql.skill_profile_close(conn, skill_id, from) |> operation.run
}
