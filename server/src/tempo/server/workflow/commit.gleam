//// Commit a completed onboarding draft into real engineer facts — the only moment
//// onboarding writes domain data. Runs inside `command.dispatch`'s transaction:
//// it reads the draft's current values, mints the engineer, maps the fields to the
//// employment/role/contact/banking facts, marks the instance committed, and returns
//// them for `repository.record_facts` to persist with the journal entry. Requires
//// the instance to be awaiting Finance and the payroll step confirmed; anything
//// missing rejects the whole commit (the transaction rolls back).

import gleam/dict.{type Dict}
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/command.{WorkflowCommand} as gateway
import shared/workflow/command.{type WorkflowCommand, CommitOnboarding}
import shared/workflow/value.{type FieldValue, BoolValue, DateValue, TextValue}
import tempo/server/fact.{
  type Recorded, EngineerAtLevel, EngineerBankingDetails, EngineerContactDetails,
  EngineerEmployed, EngineerId, Recorded,
}
import tempo/server/operation.{type OperationError, Event, InvalidValue}
import tempo/server/repository
import tempo/server/workflow/instance.{
  AwaitingFinance, Cancelled, Committed, Draft,
}

/// Route a workflow command. Phase 1 has one: commit an onboarding draft.
pub fn route(
  conn: pog.Connection,
  command: WorkflowCommand,
) -> Result(Recorded, OperationError) {
  case command {
    CommitOnboarding(instance_id:) ->
      commit_onboarding(conn, command, instance_id)
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

  use full_name <- result.try(text(values, "identity.full_name"))
  use email <- result.try(text(values, "identity.work_email"))
  use level <- result.try(level_of(values))
  use start_date <- result.try(date(values, "employment.start_date"))
  use bank <- result.try(text(values, "banking.bank"))
  use account_no <- result.try(text(values, "banking.account_no"))
  use account_name <- result.try(text(values, "banking.account_name"))

  use engineer_id <- result.try(repository.create_engineer(conn))
  let EngineerId(id) = engineer_id

  use _ <- result.try(instance.mark_committed(conn, instance_id))

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
          phone: optional(values, "contact.phone"),
          postal_address: optional(values, "contact.postal_address"),
          from: start_date,
        ),
        EngineerBankingDetails(
          engineer_id:,
          bank:,
          branch: optional(values, "banking.branch"),
          account_no:,
          account_name:,
          from: start_date,
        ),
      ],
    ),
  )
}

fn require_confirmed(
  values: Dict(String, FieldValue),
) -> Result(Nil, OperationError) {
  case dict.get(values, "payroll.payroll_confirmed") {
    Ok(BoolValue(True)) -> Ok(Nil)
    _ -> Error(InvalidValue)
  }
}

fn text(
  values: Dict(String, FieldValue),
  key: String,
) -> Result(String, OperationError) {
  case dict.get(values, key) {
    Ok(TextValue(text)) -> Ok(text)
    _ -> Error(InvalidValue)
  }
}

fn optional(values: Dict(String, FieldValue), key: String) -> String {
  case dict.get(values, key) {
    Ok(TextValue(text)) -> text
    _ -> ""
  }
}

fn date(
  values: Dict(String, FieldValue),
  key: String,
) -> Result(Date, OperationError) {
  case dict.get(values, key) {
    Ok(DateValue(date)) -> Ok(date)
    _ -> Error(InvalidValue)
  }
}

fn level_of(values: Dict(String, FieldValue)) -> Result(Int, OperationError) {
  case dict.get(values, "level.level") {
    Ok(TextValue(text)) -> int.parse(text) |> result.replace_error(InvalidValue)
    _ -> Error(InvalidValue)
  }
}
