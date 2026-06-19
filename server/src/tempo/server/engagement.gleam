//// Domain: the engagement aggregate — the client engagements (contracts) and the
//// projects contained by them. `handle` routes each engagement command to a named
//// operation that does ONLY its temporal writes on the in-transaction connection
//// and classifies any database rejection; `command.dispatch` owns the transaction
//// and persists the journal event(s) `handle` returns. No HTTP — never imports
//// `wisp`.
////
//// Both operations are Asserts (write pattern 1). Contract and project are now
//// ID-ONLY anchors with their attributes in period-keyed facts, so each "create"
//// mints the anchor then opens its founding facts:
//// `sign_contract` mints the `contract` anchor then opens a `contract_terms` row
//// (resolving the client by name);
//// `start_project` mints the `project` anchor then opens a `project_run` row
//// (contained in its contract by the `project_within_contract` PERIOD FK — a run
//// whose active period falls outside the contract's term is rejected by the
//// database), the founding `project_profile` (title = name, summary ''), and the
//// founding `project_plan` (budget 0, target_completion = valid_to).

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

/// Sign a contract for a client over a term: mint the contract anchor (its id in
/// SQL), then open its founding contract_terms row resolving the client by name to
/// its id (Assert), then return its journal event carrying that minted id.
fn sign_contract(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert SignContract(client:, valid_from:, valid_to:) = command
  use created <- operation.try(sql.contract_create(conn))
  let assert [row] = created.rows
  let contract_id = row.id
  use _ <- operation.try(sql.contract_terms_open(
    conn,
    contract_id,
    client,
    valid_from,
    valid_to,
  ))
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

/// Start a project under a contract over its active period: mint the project anchor
/// (its id in SQL), open its project_run contained by the contract via the
/// `project_within_contract` PERIOD FK (Assert), then seed its founding facts — a
/// project_profile (title = name, summary '') and a project_plan (budget 0,
/// target_completion = valid_to) — then return its journal event carrying the minted
/// project id. The profile/plan are seeded from `valid_from` so the latest read
/// picks them up over the whole run; they are editable later via
/// UpdateProjectProfile / UpdateProjectPlan.
fn start_project(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert StartProject(name:, contract_id:, valid_from:, valid_to:) = command
  use created <- operation.try(sql.project_create(conn))
  let assert [row] = created.rows
  let project_id = row.id
  use _ <- operation.try(sql.project_run_open(
    conn,
    project_id,
    contract_id,
    valid_from,
    valid_to,
  ))
  use _ <- operation.try(sql.project_profile_open(
    conn,
    project_id,
    name,
    "",
    valid_from,
  ))
  use _ <- operation.try(sql.project_plan_open(
    conn,
    project_id,
    0.0,
    valid_to,
    valid_from,
  ))
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
