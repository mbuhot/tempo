//// The persistence seam: reserve anchor ids (`next_id`) and record a list of
//// `Fact`s (`record_facts`), each mapped to the SQL that makes the database reflect
//// it, on the caller's in-transaction connection (`command.dispatch` owns the
//// transaction, so all of a command's facts commit together or roll back together).
//// A database rejection is classified into a typed `OperationError` by constraint
//// name (via `operation.try`/`operation.run`).
////
//// This module is the ONE place a fact's write SEMANTIC lives, so handlers stay
//// declarative — they say WHICH facts a command records, the repository says HOW:
////   - identity anchors and bounded asserts are plain inserts;
////   - an open-ended versioned attribute (level, details, profile/plan, client) is
////     a change from `from` onward, falling back to an open if no version yet
////     exists (`change_or_open` — so the founding write at onboard/start_project and
////     a later edit are the SAME fact);
////   - a rate is a revise (`None`) or a bounded surgical edit (`Some(to)`);
////   - an allocation is a fresh bounded assign (`Some(to)`) or a re-fraction (`None`);
////   - an invoice status is a cap-then-open (the prior status ends where the next
////     begins);
////   - worked hours is a delete-then-insert upsert (0 clears the day);
////   - a retraction (`EngineerOffProject`, `EngineerDeparted`) caps the span — and
////     departure cascades the cap to allocations, leave, and role;
////   - `CommandHandled` appends the provenance journal row (`event_log`), stamped
////     with the actor, and is the only fact that yields a persisted `Event`.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/types.{type Event}
import tempo/server/event
import tempo/server/fact.{
  type Fact, ClientProfile, CommandHandled, Contract, ContractTerms, Engineer,
  EngineerAllocatedToProject, EngineerAtLevel, EngineerBankingDetails,
  EngineerContactDetails, EngineerDeparted, EngineerEmergencyContact,
  EngineerEmployed, EngineerOffProject, EngineerOnLeave, EngineerWorkedHours,
  Invoice, InvoiceInStatus, InvoiceLine, InvoiceSubject, PayrollLine,
  PayrollPeriod, PayrollRun, Project, ProjectPlan, ProjectProfile, ProjectRun,
  RateCard, Salary,
}
import tempo/server/operation.{type OperationError}
import tempo/server/sql

/// The id sequences a command reserves from before recording a freshly-minted
/// anchor's facts.
pub type Sequence {
  Engineers
  Contracts
  Projects
  Invoices
  PayrollRuns
}

/// Reserve the next id from `sequence` (a `nextval`), so a handler can thread it
/// into the anchor and every fact contained by it without reading anything back.
pub fn next_id(
  conn: pog.Connection,
  sequence: Sequence,
) -> Result(Int, OperationError) {
  case sequence {
    Engineers -> {
      use returned <- operation.try(sql.engineer_next_id(conn))
      let assert [row] = returned.rows
      Ok(row.id)
    }
    Contracts -> {
      use returned <- operation.try(sql.contract_next_id(conn))
      let assert [row] = returned.rows
      Ok(row.id)
    }
    Projects -> {
      use returned <- operation.try(sql.project_next_id(conn))
      let assert [row] = returned.rows
      Ok(row.id)
    }
    Invoices -> {
      use returned <- operation.try(sql.invoice_next_id(conn))
      let assert [row] = returned.rows
      Ok(row.id)
    }
    PayrollRuns -> {
      use returned <- operation.try(sql.payroll_run_next_id(conn))
      let assert [row] = returned.rows
      Ok(row.id)
    }
  }
}

/// Record every fact in order on `conn`, returning the journal events the
/// `CommandHandled` facts produced (the rows the database minted). Short-circuits on
/// the first rejection, returning its typed `OperationError`; the caller's
/// transaction then rolls them all back.
pub fn record_facts(
  conn: pog.Connection,
  actor actor: String,
  facts facts: List(Fact),
) -> Result(List(Event), OperationError) {
  use events <- result.map(
    list.try_map(facts, fn(a_fact) { record(conn, actor, a_fact) }),
  )
  list.flatten(events)
}

fn record(
  conn: pog.Connection,
  actor: String,
  a_fact: Fact,
) -> Result(List(Event), OperationError) {
  case a_fact {
    CommandHandled(operation: tag, summary:, payload:) ->
      event.append(
        conn,
        actor:,
        event: operation.Event(operation: tag, summary:, payload:),
      )
      |> result.map_error(operation.classify)
      |> result.map(fn(journal_event) { [journal_event] })

    _ -> write(conn, a_fact) |> result.replace([])
  }
}

/// Write one domain fact (everything except `CommandHandled`): map it to the SQL
/// that makes the database reflect it.
fn write(conn: pog.Connection, a_fact: Fact) -> Result(Nil, OperationError) {
  case a_fact {
    CommandHandled(..) -> Ok(Nil)

    // --- identity anchors -----------------------------------------------------
    Engineer(id:) -> sql.engineer_create(conn, id) |> operation.run
    Contract(id:) -> sql.contract_create(conn, id) |> operation.run
    Project(id:) -> sql.project_create(conn, id) |> operation.run
    Invoice(id:) -> sql.invoice_create(conn, id) |> operation.run
    PayrollRun(id:) -> sql.payroll_run_create(conn, id) |> operation.run

    // --- engineer -------------------------------------------------------------
    EngineerEmployed(engineer_id:, from:) ->
      sql.employment_open(conn, engineer_id, from) |> operation.run

    EngineerDeparted(engineer_id:, from:) ->
      record_departure(conn, engineer_id, from)

    EngineerAtLevel(engineer_id:, level:, from:) ->
      change_or_open(
        sql.engineer_role_change(conn, engineer_id, level, from),
        fn() { sql.engineer_role_open(conn, engineer_id, level, from) },
      )

    EngineerContactDetails(
      engineer_id:,
      name:,
      email:,
      phone:,
      postal_address:,
      from:,
    ) ->
      change_or_open(
        sql.engineer_contact_revise(
          conn,
          engineer_id,
          from,
          name,
          email,
          phone,
          postal_address,
        ),
        fn() {
          sql.engineer_contact_open(
            conn,
            engineer_id,
            name,
            email,
            phone,
            postal_address,
            from,
          )
        },
      )

    EngineerBankingDetails(
      engineer_id:,
      bank:,
      branch:,
      account_no:,
      account_name:,
      from:,
    ) ->
      change_or_open(
        sql.engineer_banking_revise(
          conn,
          engineer_id,
          from,
          bank,
          branch,
          account_no,
          account_name,
        ),
        fn() {
          sql.engineer_banking_open(
            conn,
            engineer_id,
            bank,
            branch,
            account_no,
            account_name,
            from,
          )
        },
      )

    EngineerEmergencyContact(
      engineer_id:,
      relation:,
      name:,
      phone:,
      email:,
      from:,
    ) ->
      change_or_open(
        sql.engineer_emergency_revise(
          conn,
          engineer_id,
          from,
          relation,
          name,
          phone,
          email,
        ),
        fn() {
          sql.engineer_emergency_open(
            conn,
            engineer_id,
            relation,
            name,
            phone,
            email,
            from,
          )
        },
      )

    // --- allocation & leave ---------------------------------------------------
    EngineerAllocatedToProject(engineer_id:, project_id:, fraction:, from:, to:) ->
      case to {
        Some(to_date) ->
          sql.allocation_assign(
            conn,
            engineer_id,
            project_id,
            from,
            fraction,
            to_date,
          )
          |> operation.run
        None ->
          sql.allocation_change_fraction(
            conn,
            engineer_id,
            project_id,
            from,
            fraction,
          )
          |> operation.run
      }

    EngineerOffProject(engineer_id:, project_id:, from:) ->
      sql.allocation_close(conn, engineer_id, project_id, from) |> operation.run

    EngineerOnLeave(engineer_id:, kind:, from:, to:) ->
      sql.leave_take(conn, engineer_id, kind, from, to) |> operation.run

    // --- rates & salary -------------------------------------------------------
    RateCard(level:, day_rate:, from:, to:) ->
      case to {
        None ->
          sql.rate_card_revise(conn, from, day_rate, level) |> operation.run
        Some(to_date) ->
          sql.rate_card_for_portion_of(conn, from, to_date, day_rate, level)
          |> operation.run
      }

    Salary(level:, monthly_salary:, from:) ->
      sql.salary_revise(conn, from, monthly_salary, level) |> operation.run

    // --- engagement -----------------------------------------------------------
    ContractTerms(contract_id:, client:, from:, to:) ->
      sql.contract_terms_open(conn, contract_id, client, from, to)
      |> operation.run

    ProjectRun(project_id:, contract_id:, from:, to:) ->
      sql.project_run_open(conn, project_id, contract_id, from, to)
      |> operation.run

    ProjectProfile(project_id:, title:, summary:, from:) ->
      change_or_open(
        sql.project_profile_revise(conn, project_id, from, title, summary),
        fn() {
          sql.project_profile_open(conn, project_id, title, summary, from)
        },
      )

    ProjectPlan(project_id:, budget:, target_completion:, from:) ->
      change_or_open(
        sql.project_plan_revise(
          conn,
          project_id,
          from,
          budget,
          target_completion,
        ),
        fn() {
          sql.project_plan_open(
            conn,
            project_id,
            budget,
            target_completion,
            from,
          )
        },
      )

    // --- client ---------------------------------------------------------------
    ClientProfile(client_id:, name:, from:) ->
      change_or_open(
        sql.client_profile_revise(conn, client_id, from, name),
        fn() { sql.client_profile_open(conn, client_id, name, from) },
      )

    // --- timesheet ------------------------------------------------------------
    EngineerWorkedHours(engineer_id:, project_id:, day:, hours:) ->
      record_hours(conn, engineer_id, project_id, day, hours)

    // --- invoice & payroll ----------------------------------------------------
    InvoiceSubject(invoice_id:, project_id:, from:, to:) ->
      sql.invoice_subject_insert(conn, invoice_id, project_id, from, to)
      |> operation.run

    InvoiceInStatus(invoice_id:, status:, from:) -> {
      use _ <- operation.try(sql.invoice_status_close(conn, invoice_id, from))
      sql.invoice_status_open(conn, invoice_id, status, from) |> operation.run
    }

    InvoiceLine(invoice_id:, engineer_id:, level:, day_rate:, days:, amount:) ->
      sql.invoice_line_insert(
        conn,
        invoice_id,
        engineer_id,
        level,
        day_rate,
        days,
        amount,
      )
      |> operation.run

    PayrollPeriod(run_id:, from:, to:) ->
      sql.payroll_period_insert(conn, run_id, from, to) |> operation.run

    PayrollLine(run_id:, engineer_id:, amount:, days:) ->
      sql.payroll_line_insert(conn, run_id, engineer_id, amount, days)
      |> operation.run
  }
}

/// Record a versioned attribute from `from` onward: change the version in effect
/// (FOR PORTION OF … TO NULL), and if none yet exists (the founding write at
/// onboard/start_project) open the first span instead. The change is run for its row
/// count; a 0-row change means there is no covering version, so fall to `open`.
fn change_or_open(
  changed: Result(pog.Returned(a), pog.QueryError),
  open: fn() -> Result(b, pog.QueryError),
) -> Result(Nil, OperationError) {
  case changed {
    Error(error) -> Error(operation.classify(error))
    Ok(returned) ->
      case returned.count {
        0 -> operation.run(open())
        _ -> Ok(Nil)
      }
  }
}

/// Record worked hours as a per-day delete-then-insert upsert (the WITHOUT OVERLAPS
/// PK is not an ON CONFLICT target); 0 hours just clears the day. The timesheet
/// PERIOD FK (`timesheet_within_allocation`) classifies via `operation.try` as the
/// unified `ContainmentViolated` when the day is not covered by an allocation.
fn record_hours(
  conn: pog.Connection,
  engineer_id: Int,
  project_id: Int,
  day: Date,
  hours: Float,
) -> Result(Nil, OperationError) {
  use _ <- operation.try(sql.timesheet_delete(
    conn,
    engineer_id,
    project_id,
    day,
  ))
  case hours == 0.0 {
    True -> Ok(Nil)
    False ->
      sql.timesheet_write(conn, engineer_id, project_id, day, hours)
      |> operation.run
  }
}

/// Record an engineer's departure from `from`: cap every fact contained by the
/// employment FIRST — allocation → leave → role — then the employment itself. The
/// PERIOD FKs both force that order and verify completeness: a child left dangling
/// past `from` rejects the whole transaction.
fn record_departure(
  conn: pog.Connection,
  engineer_id: Int,
  from: Date,
) -> Result(Nil, OperationError) {
  use _ <- operation.try(sql.allocation_close_all(conn, engineer_id, from))
  use _ <- operation.try(sql.leave_close_all(conn, engineer_id, from))
  use _ <- operation.try(sql.engineer_role_close_all(conn, engineer_id, from))
  sql.employment_close(conn, engineer_id, from) |> operation.run
}
