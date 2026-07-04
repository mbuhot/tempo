//// Domain: the engagement aggregate — the client engagements (contracts) and the
//// projects contained by them. `command.route` destructures each engagement command
//// and calls the matching operation here with its already-narrowed fields; the
//// operation returns the `Fact`s it records, and `command.dispatch` records them
//// (through `repository`) and persists the journal in ONE transaction. No HTTP —
//// never imports `wisp`.
////
//// Contract and project are ID-ONLY anchors with their attributes in period-keyed
//// facts, so each operation reserves the id then records the anchor and its founding
//// facts. `sign_contract` records the contract anchor and its terms (resolving the
//// client by name). `start_project` records the project anchor, its run (contained
//// in its contract by the `project_within_contract` PERIOD FK), the founding profile
//// (title = name, summary ''), and the founding plan (budget 0, target = valid_to);
//// the profile/plan are recorded from `valid_from` so the latest read picks them up
//// over the whole run, and are editable later via UpdateProjectProfile / …Plan.

import gleam/int
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/command.{EngagementCommand} as gateway
import shared/engagement/command.{
  type EngagementCommand, RescheduleProject, SignContract, StartProject,
}
import shared/money
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}
import tempo/server/repository

/// Route an engagement command to its operation, returning the audit entry and the
/// facts it records. Exhaustive over `EngagementCommand`.
pub fn route(
  conn: pog.Connection,
  command: EngagementCommand,
) -> Result(Recorded, OperationError) {
  case command {
    SignContract(client:, valid_from:, valid_to:) ->
      sign_contract(conn, command, client:, valid_from:, valid_to:)
    StartProject(name:, contract_id:, valid_from:, valid_to:) ->
      start_project(conn, command, name:, contract_id:, valid_from:, valid_to:)
    RescheduleProject(project_id:, valid_from:, valid_to:) ->
      reschedule_project(conn, command, project_id:, valid_from:, valid_to:)
  }
}

/// Sign a contract for a client over a term: reserve the contract id, then record
/// the anchor and its founding terms (resolving the client by name), with the
/// journal entry.
pub fn sign_contract(
  conn: pog.Connection,
  command: EngagementCommand,
  client client: String,
  valid_from valid_from: Date,
  valid_to valid_to: Date,
) -> Result(Recorded, OperationError) {
  use contract_id <- result.try(repository.create_contract(conn))
  let fact.ContractId(id) = contract_id
  Ok(
    Recorded(
      entry: Event(
        operation: "sign_contract",
        summary: "Sign contract for "
          <> client
          <> " (contract "
          <> int.to_string(id)
          <> ") over "
          <> operation.span(valid_from, valid_to),
        payload: gateway.encode_command(EngagementCommand(command)),
      ),
      facts: [
        fact.ContractTerms(
          contract_id:,
          client:,
          from: valid_from,
          to: valid_to,
        ),
      ],
    ),
  )
}

/// Start a project under a contract over its active period: reserve the project id,
/// then record the anchor, its run, and the founding profile and plan, with the
/// journal entry.
pub fn start_project(
  conn: pog.Connection,
  command: EngagementCommand,
  name name: String,
  contract_id contract_id: Int,
  valid_from valid_from: Date,
  valid_to valid_to: Date,
) -> Result(Recorded, OperationError) {
  use project_id <- result.try(repository.create_project(conn))
  let fact.ProjectId(id) = project_id
  Ok(
    Recorded(
      entry: Event(
        operation: "start_project",
        summary: "Start project "
          <> name
          <> " under contract "
          <> int.to_string(contract_id)
          <> " (project "
          <> int.to_string(id)
          <> ") over "
          <> operation.span(valid_from, valid_to),
        payload: gateway.encode_command(EngagementCommand(command)),
      ),
      facts: [
        fact.ProjectRun(
          project_id:,
          contract_id: fact.ContractId(contract_id),
          from: valid_from,
          to: valid_to,
        ),
        fact.ProjectProfile(
          project_id:,
          title: name,
          summary: "",
          from: valid_from,
        ),
        fact.ProjectPlan(
          project_id:,
          budget: money.zero(),
          target_completion: valid_to,
          from: valid_from,
        ),
      ],
    ),
  )
}

/// Move a project's whole plan to a new [from, to) run window: the repository
/// resolves the delta shift and clamping in one statement, so this handler only
/// records the intent as a fact.
pub fn reschedule_project(
  conn: pog.Connection,
  command: EngagementCommand,
  project_id project_id: Int,
  valid_from valid_from: Date,
  valid_to valid_to: Date,
) -> Result(Recorded, OperationError) {
  let _ = conn
  Ok(
    Recorded(
      entry: Event(
        operation: "reschedule_project",
        summary: "Reschedule project "
          <> int.to_string(project_id)
          <> " to "
          <> operation.span(valid_from, valid_to),
        payload: gateway.encode_command(EngagementCommand(command)),
      ),
      facts: [
        fact.ProjectRescheduled(
          project_id: fact.ProjectId(project_id),
          from: valid_from,
          to: valid_to,
        ),
      ],
    ),
  )
}
