//// The persistence seam: record a list of `Fact`s, each mapped to the SQL that
//// writes it, on the caller's in-transaction connection (`command.dispatch` owns
//// the transaction, so all of an operation's facts commit together or roll back
//// together). A database rejection is classified into a typed `OperationError`
//// (via `operation.try`, which maps the constraint name).
////
//// The map from `Fact` to SQL is the only place a fact's write SEMANTIC lives: a
//// versioned detail is a FOR PORTION OF Change (`*_revise`); worked hours is a
//// delete-then-insert upsert (0 clears the day). Handlers stay declarative — they
//// decide WHICH facts; `record_facts` decides HOW each is written.

import gleam/list
import gleam/result
import pog
import tempo/server/fact.{
  type Fact, ClientProfile, EngineerBankingDetails, EngineerContactDetails,
  EngineerEmergencyContact, EngineerWorkedHours, ProjectPlan, ProjectProfile,
}
import tempo/server/operation.{type OperationError}
import tempo/server/sql

/// Record every fact in order on `conn`. Short-circuits on the first database
/// rejection, returning its typed `OperationError`; the caller's transaction then
/// rolls them all back.
pub fn record_facts(
  conn: pog.Connection,
  facts: List(Fact),
) -> Result(Nil, OperationError) {
  list.try_map(facts, fn(a_fact) { record(conn, a_fact) })
  |> result.replace(Nil)
}

fn record(conn: pog.Connection, a_fact: Fact) -> Result(Nil, OperationError) {
  case a_fact {
    EngineerContactDetails(
      engineer_id:,
      name:,
      email:,
      phone:,
      postal_address:,
      effective:,
    ) -> {
      use _ <- operation.try(sql.engineer_contact_revise(
        conn,
        engineer_id,
        effective,
        name,
        email,
        phone,
        postal_address,
      ))
      Ok(Nil)
    }

    EngineerBankingDetails(
      engineer_id:,
      bank:,
      branch:,
      account_no:,
      account_name:,
      effective:,
    ) -> {
      use _ <- operation.try(sql.engineer_banking_revise(
        conn,
        engineer_id,
        effective,
        bank,
        branch,
        account_no,
        account_name,
      ))
      Ok(Nil)
    }

    EngineerEmergencyContact(
      engineer_id:,
      relation:,
      name:,
      phone:,
      email:,
      effective:,
    ) -> {
      use _ <- operation.try(sql.engineer_emergency_revise(
        conn,
        engineer_id,
        effective,
        relation,
        name,
        phone,
        email,
      ))
      Ok(Nil)
    }

    ClientProfile(client_id:, name:, effective:) -> {
      use _ <- operation.try(sql.client_profile_revise(
        conn,
        client_id,
        effective,
        name,
      ))
      Ok(Nil)
    }

    ProjectProfile(project_id:, title:, summary:, effective:) -> {
      use _ <- operation.try(sql.project_profile_revise(
        conn,
        project_id,
        effective,
        title,
        summary,
      ))
      Ok(Nil)
    }

    ProjectPlan(project_id:, budget:, target_completion:, effective:) -> {
      use _ <- operation.try(sql.project_plan_revise(
        conn,
        project_id,
        effective,
        budget,
        target_completion,
      ))
      Ok(Nil)
    }

    // Hours are a delete-then-insert upsert (the WITHOUT OVERLAPS PK is not an
    // ON CONFLICT target); 0 hours just clears the day. The timesheet PERIOD FK
    // (`timesheet_within_allocation`) classifies via operation.try as the unified
    // ContainmentViolated when the day is not covered by an allocation.
    EngineerWorkedHours(engineer_id:, project_id:, day:, hours:) ->
      case hours == 0.0 {
        True -> {
          use _ <- operation.try(sql.timesheet_delete(
            conn,
            engineer_id,
            project_id,
            day,
          ))
          Ok(Nil)
        }
        False -> {
          use _ <- operation.try(sql.timesheet_delete(
            conn,
            engineer_id,
            project_id,
            day,
          ))
          use _ <- operation.try(sql.timesheet_write(
            conn,
            engineer_id,
            project_id,
            day,
            hours,
          ))
          Ok(Nil)
        }
      }
  }
}
