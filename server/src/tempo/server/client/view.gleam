//// Domain: the client READ models — the clients `list` (`GET /api/clients?as_of=`)
//// and one client's `detail` (`GET /api/clients/:id?as_of=`). No HTTP — this layer
//// never imports `wisp`.
////
//// `list` runs `client_list` (every client: name, earliest-contract `since`,
//// project count, and `active` = any contract covering the as-of date) and maps
//// each row. `detail` reads the client's profile from the `client_current` view
//// plus its contract and project timelines; the as-of drives only the per-row
//// `active` flags (the profile name is durable/latest-read). `since` is the minimum
//// contract start folded in Gleam — `None` for a contractless client.
////
//// `detail` returns `Result(Result(ClientDetail, Nil), pog.QueryError)`:
//// `Ok(Error(Nil))` when the client has no profile (unknown id) so the handler can
//// answer a 404; `Error(_)` is a database failure.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/client/view.{
  type ClientDetail, type ClientList, type ClientListRow, type ClientProfile,
  type ClientProjectRow, type ContractRow, ClientDetail, ClientList,
  ClientListRow, ClientProfile, ClientProjectRow, ContractRow,
}
import shared/money.{type Money}
import shared/pagination
import tempo/server/client/sql
import tempo/server/context.{type Context}
import tempo/server/web/cursor.{type NameIdBound, NameIdBound}

/// Parse a money amount from a trusted SQL `numeric::text` column.
fn money(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

/// One keyset page of the clients list as-of `as_of` (issue #12): each client with
/// its `since`, project count, and active flag, starting strictly after `after` at
/// most `limit` rows, plus the `next_cursor` for the following page (`None` on the
/// last page). The order is the SQL's stable (name, client_id).
pub fn list(
  context: Context,
  as_of: Date,
  after: NameIdBound,
  limit: Int,
) -> Result(ClientList, pog.QueryError) {
  let NameIdBound(name:, id:) = after
  use returned <- result.map(sql.client_list(
    context.db,
    as_of,
    name,
    id,
    limit + 1,
  ))
  let #(rows, next_cursor) =
    pagination.paginate(returned.rows, limit, fn(row: sql.ClientListRow) {
      cursor.encode_name_id(row.name, row.client_id)
    })
  ClientList(
    date: as_of,
    clients: list.map(rows, list_row_to_shared),
    next_cursor:,
  )
}

fn list_row_to_shared(row: sql.ClientListRow) -> ClientListRow {
  ClientListRow(
    client_id: row.client_id,
    name: row.name,
    since: row.since,
    project_count: row.project_count,
    active: row.active,
  )
}

/// One client's detail as-of `as_of`. `Ok(Error(Nil))` when no profile (unknown
/// id) → 404. `since` is the earliest contract start (None when contractless); the
/// as-of drives only the per-row `active` flags.
pub fn detail(
  context: Context,
  client_id: Int,
  as_of: Date,
) -> Result(Result(ClientDetail, Nil), pog.QueryError) {
  use profile_rows <- result.try(current_profile(context, client_id))
  case profile_rows {
    [] -> Ok(Error(Nil))
    [profile, ..] -> assemble(context, client_id, as_of, profile)
  }
}

fn assemble(
  context: Context,
  client_id: Int,
  as_of: Date,
  profile: ClientProfile,
) -> Result(Result(ClientDetail, Nil), pog.QueryError) {
  use contracts <- result.try(sql.client_contracts(context.db, client_id, as_of))
  use projects <- result.map(sql.client_projects(context.db, client_id, as_of))
  let contracts = list.map(contracts.rows, contract_row_to_shared)
  Ok(ClientDetail(
    profile:,
    since: earliest_start(contracts),
    contracts:,
    projects: list.map(projects.rows, client_project_row_to_shared),
  ))
}

/// Read the client's profile (id + name) from the `client_current` view directly —
/// no dedicated `.sql` reader exists and the view already exposes both columns.
fn current_profile(
  context: Context,
  client_id: Int,
) -> Result(List(ClientProfile), pog.QueryError) {
  use returned <- result.map(sql.client_current(context.db, client_id))
  returned.rows
  |> list.map(fn(row) {
    // Squirrel infers id/name are nullable, but they are not
    let assert sql.ClientCurrentRow(id: Some(client_id), name: Some(name)) = row
    ClientProfile(client_id:, name:)
  })
}

fn contract_row_to_shared(row: sql.ClientContractsRow) -> ContractRow {
  ContractRow(
    contract_id: row.contract_id,
    valid_from: row.valid_from,
    valid_to: row.valid_to,
    active: row.active,
  )
}

fn client_project_row_to_shared(
  row: sql.ClientProjectsRow,
) -> ClientProjectRow {
  ClientProjectRow(
    project_id: row.project_id,
    title: row.title,
    budget: money(row.budget),
    target_completion: row.target_completion,
    valid_from: row.valid_from,
    valid_to: row.valid_to,
    active: row.active,
  )
}

/// The earliest contract start across the client's contracts (the client `since`),
/// or `None` when the client has no contracts.
fn earliest_start(contracts: List(ContractRow)) -> Option(Date) {
  list.fold(contracts, None, fn(earliest, contract) {
    case earliest {
      None -> Some(contract.valid_from)
      Some(current) ->
        case calendar.naive_date_compare(contract.valid_from, current) {
          order.Lt -> Some(contract.valid_from)
          _ -> earliest
        }
    }
  })
}
