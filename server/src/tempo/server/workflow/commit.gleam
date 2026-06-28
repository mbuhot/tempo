//// Commit a completed workflow draft into real domain facts — the only moment a
//// workflow writes domain data. Runs inside `command.dispatch`'s transaction:
//// reads the draft's current values, mints the anchors, maps fields to facts, marks
//// the instance committed, and returns them for `repository.record_facts`. Requires
//// the instance to be in a committable status and the confirmation step confirmed;
//// anything missing rejects the whole commit (the transaction rolls back).
////
//// Supported workflows: `CommitOnboarding` (engineer facts) and `CreateProject`
//// (client/contract/project facts).

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/command.{WorkflowCommand} as gateway
import shared/money.{type Money}
import shared/workflow/command.{
  type WorkflowCommand, CommitOnboarding, CreateProject,
}
import shared/workflow/value.{
  type FieldValue, BoolValue, DateValue, MoneyValue, TextValue,
}

fn field_at(
  values: Dict(String, Dict(String, FieldValue)),
  step: String,
  field: String,
) -> Result(FieldValue, Nil) {
  use step_values <- result.try(dict.get(values, step))
  dict.get(step_values, field)
}

import tempo/server/client/sql as client_sql
import tempo/server/fact.{
  type EngineerId, type Recorded, ClientProfile, ContractTerms, EngineerAtLevel,
  EngineerBankingDetails, EngineerContactDetails, EngineerEmergencyContact,
  EngineerEmployed, EngineerId, ProjectPlan, ProjectProfile, ProjectRun,
  Recorded,
}
import tempo/server/operation.{type OperationError, Event, InvalidValue}
import tempo/server/repository
import tempo/server/workflow/instance.{
  AwaitingFinance, Cancelled, Committed, Draft,
}

/// Route a workflow commit command to its handler.
pub fn route(
  conn: pog.Connection,
  command: WorkflowCommand,
) -> Result(Recorded, OperationError) {
  case command {
    CommitOnboarding(instance_id:) ->
      commit_onboarding(conn, command, instance_id)
    CreateProject(instance_id:) -> create_project(conn, command, instance_id)
  }
}

fn commit_onboarding(
  conn: pog.Connection,
  command: WorkflowCommand,
  instance_id: String,
) -> Result(Recorded, OperationError) {
  use maybe <- result.try(instance.load(conn, instance_id))
  // The commit PERMISSION (engineer.onboard.commit, enforced by the command gate) is
  // the real authority — so an admin who holds it commits straight from a draft with
  // no hand-off, while a manager who lacks it must hand off first. The status check
  // only blocks committing something already committed or cancelled.
  use _ <- result.try(case maybe {
    Some(loaded) ->
      case loaded.status {
        Draft | AwaitingFinance -> Ok(Nil)
        Committed | Cancelled -> Error(InvalidValue)
      }
    None -> Error(InvalidValue)
  })

  use values <- result.try(instance.current_values(conn, instance_id))
  use _ <- result.try(require_confirmed(values))

  use full_name <- result.try(text(values, "identity", "full_name"))
  use email <- result.try(text(values, "identity", "work_email"))
  use level <- result.try(level_of(values))
  use start_date <- result.try(date(values, "employment", "start_date"))
  use bank <- result.try(text(values, "banking", "bank"))
  use account_no <- result.try(text(values, "banking", "account_no"))
  use account_name <- result.try(text(values, "banking", "account_name"))

  use engineer_id <- result.try(repository.create_engineer(conn))
  let EngineerId(id) = engineer_id

  use _ <- result.try(instance.mark_committed(conn, instance_id))

  let emergency_facts = emergency_contact(values, engineer_id, start_date)

  Ok(
    Recorded(
      entry: Event(
        operation: "onboard_engineer",
        summary: "Onboard "
          <> full_name
          <> " at L"
          <> int.to_string(level)
          <> " (engineer "
          <> int.to_string(id)
          <> ") from "
          <> operation.iso(start_date),
        payload: gateway.encode_command(WorkflowCommand(command)),
      ),
      facts: [
        EngineerEmployed(engineer_id:, from: start_date),
        EngineerAtLevel(engineer_id:, level:, from: start_date),
        EngineerContactDetails(
          engineer_id:,
          name: full_name,
          email:,
          phone: optional(values, "contact", "phone"),
          postal_address: optional(values, "contact", "postal_address"),
          from: start_date,
        ),
        EngineerBankingDetails(
          engineer_id:,
          bank:,
          branch: optional(values, "banking", "branch"),
          account_no:,
          account_name:,
          from: start_date,
        ),
        ..emergency_facts
      ],
    ),
  )
}

fn create_project(
  conn: pog.Connection,
  command: WorkflowCommand,
  instance_id: String,
) -> Result(Recorded, OperationError) {
  use maybe <- result.try(instance.load(conn, instance_id))
  use _ <- result.try(case maybe {
    Some(loaded) ->
      case loaded.status {
        Draft | AwaitingFinance -> Ok(Nil)
        Committed | Cancelled -> Error(InvalidValue)
      }
    None -> Error(InvalidValue)
  })

  use values <- result.try(instance.current_values(conn, instance_id))
  use _ <- result.try(require_project_confirmed(values))

  use title <- result.try(text(values, "description", "title"))
  let summary = optional(values, "description", "summary")
  use start <- result.try(date(values, "timeframe", "start"))
  use end <- result.try(date(values, "timeframe", "end"))
  use budget <- result.try(money_of(values, "timeframe", "budget"))
  let target = case date(values, "timeframe", "target_completion") {
    Ok(target_date) -> target_date
    Error(_) -> end
  }
  use contract_from <- result.try(date(values, "contract", "contract_from"))
  use contract_to <- result.try(date(values, "contract", "contract_to"))

  use #(client_name, profile_facts) <- result.try(resolve_client(
    conn,
    values,
    contract_from,
  ))

  use contract_id <- result.try(repository.create_contract(conn))
  use project_id <- result.try(repository.create_project(conn))

  use _ <- result.try(instance.mark_committed(conn, instance_id))

  Ok(Recorded(
    entry: Event(
      operation: "create_project",
      summary: "Create project "
        <> title
        <> " for "
        <> client_name
        <> " from "
        <> operation.iso(start),
      payload: gateway.encode_command(WorkflowCommand(command)),
    ),
    facts: list.append(profile_facts, [
      ContractTerms(
        contract_id:,
        client: client_name,
        from: contract_from,
        to: contract_to,
      ),
      ProjectRun(project_id:, contract_id:, from: start, to: end),
      ProjectProfile(project_id:, title:, summary:, from: start),
      ProjectPlan(project_id:, budget:, target_completion: target, from: start),
    ]),
  ))
}

/// Resolve the client field to its name and any profile facts to emit.
/// Returns `#(name, profile_facts)` where `profile_facts` is non-empty only for
/// new clients (a single `ClientProfile`).
fn resolve_client(
  conn: pog.Connection,
  values: Dict(String, Dict(String, FieldValue)),
  contract_from: Date,
) -> Result(#(String, List(fact.Fact)), OperationError) {
  let chosen = optional(values, "client", "client")
  case chosen == "__new__" {
    True -> {
      use name <- result.try(text(values, "client", "new_client_name"))
      case string.is_empty(name) {
        True -> Error(InvalidValue)
        False -> {
          use client_id <- result.try(repository.create_client(conn))
          Ok(#(name, [ClientProfile(client_id:, name:, from: contract_from)]))
        }
      }
    }
    False -> {
      use client_int_id <- result.try(
        int.parse(chosen) |> result.replace_error(InvalidValue),
      )
      use returned <- operation.try(client_sql.client_current(
        conn,
        client_int_id,
      ))
      case returned.rows {
        [row, ..] ->
          case row.name {
            Some(name) -> Ok(#(name, []))
            None -> Error(InvalidValue)
          }
        [] -> Error(InvalidValue)
      }
    }
  }
}

fn require_project_confirmed(
  values: Dict(String, Dict(String, FieldValue)),
) -> Result(Nil, OperationError) {
  case field_at(values, "confirm", "confirmed") {
    Ok(BoolValue(True)) -> Ok(Nil)
    _ -> Error(InvalidValue)
  }
}

fn money_of(
  values: Dict(String, Dict(String, FieldValue)),
  step: String,
  field: String,
) -> Result(Money, OperationError) {
  case field_at(values, step, field) {
    Ok(MoneyValue(amount)) -> Ok(amount)
    _ -> Error(InvalidValue)
  }
}

/// The engineer's emergency contact as a (possibly empty) fact list: written only
/// when a contact name was entered, since every other field is meaningless without
/// one. The wizard's emergency step is optional, so a skipped step records nothing.
fn emergency_contact(
  values: Dict(String, Dict(String, FieldValue)),
  engineer_id: EngineerId,
  from: Date,
) -> List(fact.Fact) {
  case optional(values, "emergency", "emergency_name") {
    "" -> []
    name -> [
      EngineerEmergencyContact(
        engineer_id:,
        relation: optional(values, "emergency", "emergency_relation"),
        name:,
        phone: optional(values, "emergency", "emergency_phone"),
        email: optional(values, "emergency", "emergency_email"),
        from:,
      ),
    ]
  }
}

fn require_confirmed(
  values: Dict(String, Dict(String, FieldValue)),
) -> Result(Nil, OperationError) {
  case field_at(values, "payroll", "payroll_confirmed") {
    Ok(BoolValue(True)) -> Ok(Nil)
    _ -> Error(InvalidValue)
  }
}

fn text(
  values: Dict(String, Dict(String, FieldValue)),
  step: String,
  field: String,
) -> Result(String, OperationError) {
  case field_at(values, step, field) {
    Ok(TextValue(t)) -> Ok(t)
    _ -> Error(InvalidValue)
  }
}

fn optional(
  values: Dict(String, Dict(String, FieldValue)),
  step: String,
  field: String,
) -> String {
  case field_at(values, step, field) {
    Ok(TextValue(t)) -> t
    _ -> ""
  }
}

fn date(
  values: Dict(String, Dict(String, FieldValue)),
  step: String,
  field: String,
) -> Result(Date, OperationError) {
  case field_at(values, step, field) {
    Ok(DateValue(d)) -> Ok(d)
    _ -> Error(InvalidValue)
  }
}

fn level_of(
  values: Dict(String, Dict(String, FieldValue)),
) -> Result(Int, OperationError) {
  case field_at(values, "level", "level") {
    Ok(TextValue(t)) -> int.parse(t) |> result.replace_error(InvalidValue)
    _ -> Error(InvalidValue)
  }
}
