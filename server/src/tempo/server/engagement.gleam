//// Domain: the engagement aggregate — the client engagements (contracts) and the
//// projects contained by them. `handle` routes each engagement command to a named
//// operation that does ONLY its temporal writes on the in-transaction connection
//// and classifies any database rejection; `command.dispatch` owns the transaction
//// and persists the journal event(s) `handle` returns. No HTTP — never imports
//// `wisp`.
////
//// Both operations are Asserts (write pattern 1): `sign_contract` inserts a
//// contract term, resolving the client by name and minting the entity id;
//// `start_project` inserts a project under a contract, contained by it via the
//// `project_within_contract` PERIOD FK — a project whose active period falls
//// outside the contract's term is rejected by the database.

import gleam/int
import pog
import shared/codecs
import shared/types.{type Command, SignContract, StartProject}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply an engagement-aggregate command: route it to its named operation, which does
/// its temporal writes and returns the journal event(s) it produced. The dispatch
/// `route` only ever sends engagement commands here, so any other variant is a routing
/// bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  case command {
    SignContract(..) -> sign_contract(conn, command)
    StartProject(..) -> start_project(conn, command)
    _ ->
      panic as "engagement.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Sign a contract for a client over a term: insert the contract, resolving the
/// client by name to its id and minting the contract entity id in SQL (Assert), then
/// return its journal event carrying that minted id.
fn sign_contract(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert SignContract(client:, valid_from:, valid_to:) = command
  use created <- operation.try(sql.contract_create(
    conn,
    client,
    valid_from,
    valid_to,
  ))
  let contract_id = case created.rows {
    [row, ..] -> row.id
    [] -> 0
  }
  Ok([
    Event(
      operation: "sign_contract",
      summary: "Sign contract for "
        <> client
        <> " (contract "
        <> int.to_string(contract_id)
        <> ") over "
        <> operation.span(valid_from, valid_to),
      payload: codecs.encode_command(command),
    ),
  ])
}

/// Start a project under a contract over its active period: insert the project,
/// contained by the contract via the `project_within_contract` PERIOD FK (Assert),
/// then return its journal event carrying the minted project id.
fn start_project(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert StartProject(name:, contract_id:, valid_from:, valid_to:) = command
  use created <- operation.try(sql.project_create(
    conn,
    contract_id,
    name,
    valid_from,
    valid_to,
  ))
  let project_id = case created.rows {
    [row, ..] -> row.id
    [] -> 0
  }
  Ok([
    Event(
      operation: "start_project",
      summary: "Start project "
        <> name
        <> " under contract "
        <> int.to_string(contract_id)
        <> " (project "
        <> int.to_string(project_id)
        <> ") over "
        <> operation.span(valid_from, valid_to),
      payload: codecs.encode_command(command),
    ),
  ])
}
