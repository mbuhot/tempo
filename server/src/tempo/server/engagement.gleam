//// Domain: the engagement aggregate — the client engagements (contracts) and the
//// projects contained by them. Every function takes the in-transaction connection
//// and does ONLY its temporal writes; `command.dispatch` owns the transaction and
//// the `event_log` row. No HTTP — never imports `wisp`.
////
//// Both operations are Asserts (write pattern 1): `sign_contract` inserts a
//// contract term, resolving the client by name and minting the entity id;
//// `start_project` inserts a project under a contract, contained by it via the
//// `project_within_contract` PERIOD FK — a project whose active period falls
//// outside the contract's term is rejected by the database.

import gleam/result
import gleam/time/calendar.{type Date}
import pog
import tempo/server/sql

/// Sign a contract for a client over [valid_from, valid_to) (the Assert pattern).
/// The client is carried by name and resolved to its id in SQL; the contract's
/// entity id is minted there too. `valid_to` may be open-ended.
pub fn sign_contract(
  conn: pog.Connection,
  client: String,
  valid_from: Date,
  valid_to: Date,
) -> Result(Nil, pog.QueryError) {
  use _ <- result.map(sql.contract_create(conn, client, valid_from, valid_to))
  Nil
}

/// Start a project under a contract over [valid_from, valid_to) (the Assert
/// pattern). The project's entity id is minted in SQL; the
/// `project_within_contract` PERIOD FK is the backstop — a project active outside
/// its contract's term is rejected by the database.
pub fn start_project(
  conn: pog.Connection,
  name: String,
  contract_id: Int,
  valid_from: Date,
  valid_to: Date,
) -> Result(Nil, pog.QueryError) {
  use _ <- result.map(sql.project_create(
    conn,
    contract_id,
    name,
    valid_from,
    valid_to,
  ))
  Nil
}
