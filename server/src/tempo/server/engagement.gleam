//// Domain: the engagement aggregate — the client engagements (contracts) and the
//// projects contained by them. `handle` matches the engagement commands, does
//// ONLY their temporal writes on the in-transaction connection, classifies any
//// database rejection, and returns the journal event(s) it produced;
//// `command.dispatch` owns the transaction and persists those events. No HTTP —
//// never imports `wisp`.
////
//// Both operations are Asserts (write pattern 1): `SignContract` inserts a
//// contract term, resolving the client by name and minting the entity id;
//// `StartProject` inserts a project under a contract, contained by it via the
//// `project_within_contract` PERIOD FK — a project whose active period falls
//// outside the contract's term is rejected by the database.

import gleam/int
import gleam/result
import pog
import shared/codecs
import shared/types.{type Command, SignContract, StartProject}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply an engagement-aggregate command: run its temporal writes on the
/// in-transaction connection, classify any database rejection, and on success
/// return the single journal event it produced. Only the engagement commands
/// reach here (the dispatch `route` guarantees it); any other variant is a no-op.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let written = case command {
    SignContract(client:, valid_from:, valid_to:) ->
      sql.contract_create(conn, client, valid_from, valid_to)
      |> result.replace(Nil)
    StartProject(name:, contract_id:, valid_from:, valid_to:) ->
      sql.project_create(conn, contract_id, name, valid_from, valid_to)
      |> result.replace(Nil)
    _ -> Ok(Nil)
  }
  case written {
    Error(query_error) -> Error(operation.classify(query_error))
    Ok(Nil) -> Ok(events(command))
  }
}

/// The journal event(s) an applied engagement command produces.
fn events(command: Command) -> List(Event) {
  case command {
    SignContract(client:, valid_from:, valid_to:) -> [
      Event(
        operation: "sign_contract",
        summary: "Sign contract for "
          <> client
          <> " over "
          <> operation.span(valid_from, valid_to),
        payload: codecs.encode_command(command),
      ),
    ]
    StartProject(name:, contract_id:, valid_from:, valid_to:) -> [
      Event(
        operation: "start_project",
        summary: "Start project "
          <> name
          <> " under contract "
          <> int.to_string(contract_id)
          <> " over "
          <> operation.span(valid_from, valid_to),
        payload: codecs.encode_command(command),
      ),
    ]
    _ -> []
  }
}
