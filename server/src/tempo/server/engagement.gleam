//// Domain: the engagement aggregate — the client engagements (contracts) and the
//// projects contained by them. `handle` routes each engagement command to a named
//// operation that returns the `Fact`s it records; `command.dispatch` records them
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
import pog
import shared/codecs
import shared/types.{type Command, SignContract, StartProject}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}
import tempo/server/repository

/// Apply an engagement-aggregate command: route it to its named operation, which
/// returns the audit entry and facts it records. The dispatch `route` only ever
/// sends engagement commands here, so any other variant is a routing bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  case command {
    SignContract(..) -> sign_contract(conn, command)
    StartProject(..) -> start_project(conn, command)
    _ ->
      panic as "engagement.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Sign a contract for a client over a term: reserve the contract id, then record
/// the anchor and its founding terms (resolving the client by name), with the
/// journal entry.
fn sign_contract(
  conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  let assert SignContract(client:, valid_from:, valid_to:) = command
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
        payload: codecs.encode_command(command),
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
fn start_project(
  conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  let assert StartProject(name:, contract_id:, valid_from:, valid_to:) = command
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
        payload: codecs.encode_command(command),
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
          budget: 0.0,
          target_completion: valid_to,
          from: valid_from,
        ),
      ],
    ),
  )
}
