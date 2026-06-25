//// The client read models and their JSON codecs: the `ClientProfile` fact, the
//// client-detail row types (`ContractRow`/`ClientProjectRow`) and `ClientDetail`
//// bundle, and the clients-list `ClientListRow`/`ClientList`. Pure Gleam, no
//// target-specific deps, so they round-trip on both ends of the JSON-over-HTTP
//// boundary. Dates serialise as ISO-8601 "YYYY-MM-DD" strings; money fields
//// decode leniently.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/pagination
import shared/wire

/// A client's profile as one edit-grouped fact: the client's `name`. The
/// underlying `client_profile` table is period-keyed (`recorded_during`) and
/// append-only, read LATEST — so this record carries only the scalar fields of
/// the most-recently-recorded version, not its transaction-time bounds. A client
/// has only a name, so this is the client's single fact group (mirroring
/// `EngineerContact`).
pub type ClientProfile {
  ClientProfile(client_id: Int, name: String)
}

/// One contract term on the client-detail read model: the `contract_id` and its
/// term `[valid_from, valid_to)`, with `active` true when the term covers the
/// detail's as-of date (active/ended derived as of the date).
pub type ContractRow {
  ContractRow(contract_id: Int, valid_from: Date, valid_to: Date, active: Bool)
}

/// One project of a client on the client-detail read model: the project's `title`,
/// `budget`, `target_completion`, its run period `[valid_from, valid_to)`, with
/// `active` true when the run covers the detail's as-of date.
pub type ClientProjectRow {
  ClientProjectRow(
    project_id: Int,
    title: String,
    budget: Float,
    target_completion: Date,
    valid_from: Date,
    valid_to: Date,
    active: Bool,
  )
}

/// The client-detail read model (`GET /api/clients/:id?as_of=`): the client's
/// `profile`, their `since` date (the earliest contract's start, `None` when the
/// client has no contracts), and their `contracts`/`projects` with active/ended
/// flags computed as-of. The profile name is durable (latest-read), as-of only
/// drives the per-row `active` flags.
pub type ClientDetail {
  ClientDetail(
    profile: ClientProfile,
    since: Option(Date),
    contracts: List(ContractRow),
    projects: List(ClientProjectRow),
  )
}

/// One row of the clients list (`GET /api/clients?as_of=`): a client's `name`,
/// `since` (earliest contract start, `None` when contractless), `project_count`,
/// and `active` (true when any contract covers the as-of date).
pub type ClientListRow {
  ClientListRow(
    client_id: Int,
    name: String,
    since: Option(Date),
    project_count: Int,
    active: Bool,
  )
}

/// The clients list for a single date (mirrors `PeopleList`): the `date`, one
/// `ClientListRow` per client, and the opaque `next_cursor` for the following
/// keyset page (`None` on the last page; issue #12). The item shape is unchanged —
/// `next_cursor` is purely additive.
pub type ClientList {
  ClientList(
    date: Date,
    clients: List(ClientListRow),
    next_cursor: Option(String),
  )
}

/// Encode a `ClientProfile` (the client's current profile fact) as a JSON
/// object.
pub fn encode_client_profile(profile: ClientProfile) -> Json {
  let ClientProfile(client_id:, name:) = profile
  json.object([
    #("client_id", json.int(client_id)),
    #("name", json.string(name)),
  ])
}

/// Decode a `ClientProfile` from a JSON object.
pub fn client_profile_decoder() -> Decoder(ClientProfile) {
  use client_id <- decode.field("client_id", decode.int)
  use name <- decode.field("name", decode.string)
  decode.success(ClientProfile(client_id:, name:))
}

/// Encode a `ContractRow` (one client contract term) as a JSON object.
pub fn encode_contract_row(contract: ContractRow) -> Json {
  let ContractRow(contract_id:, valid_from:, valid_to:, active:) = contract
  json.object([
    #("contract_id", json.int(contract_id)),
    #("valid_from", wire.encode_date(valid_from)),
    #("valid_to", wire.encode_date(valid_to)),
    #("active", json.bool(active)),
  ])
}

/// Decode a `ContractRow` from a JSON object.
pub fn contract_row_decoder() -> Decoder(ContractRow) {
  use contract_id <- decode.field("contract_id", decode.int)
  use valid_from <- decode.field("valid_from", wire.date_decoder())
  use valid_to <- decode.field("valid_to", wire.date_decoder())
  use active <- decode.field("active", decode.bool)
  decode.success(ContractRow(contract_id:, valid_from:, valid_to:, active:))
}

/// Encode a `ClientProjectRow` (one of a client's projects) as a JSON object.
pub fn encode_client_project_row(project: ClientProjectRow) -> Json {
  let ClientProjectRow(
    project_id:,
    title:,
    budget:,
    target_completion:,
    valid_from:,
    valid_to:,
    active:,
  ) = project
  json.object([
    #("project_id", json.int(project_id)),
    #("title", json.string(title)),
    #("budget", json.float(budget)),
    #("target_completion", wire.encode_date(target_completion)),
    #("valid_from", wire.encode_date(valid_from)),
    #("valid_to", wire.encode_date(valid_to)),
    #("active", json.bool(active)),
  ])
}

/// Decode a `ClientProjectRow` from a JSON object.
pub fn client_project_row_decoder() -> Decoder(ClientProjectRow) {
  use project_id <- decode.field("project_id", decode.int)
  use title <- decode.field("title", decode.string)
  use budget <- decode.field("budget", wire.lenient_float_decoder())
  use target_completion <- decode.field(
    "target_completion",
    wire.date_decoder(),
  )
  use valid_from <- decode.field("valid_from", wire.date_decoder())
  use valid_to <- decode.field("valid_to", wire.date_decoder())
  use active <- decode.field("active", decode.bool)
  decode.success(ClientProjectRow(
    project_id:,
    title:,
    budget:,
    target_completion:,
    valid_from:,
    valid_to:,
    active:,
  ))
}

/// Encode a `ClientDetail` (the client-detail read model) to JSON.
pub fn encode_client_detail(detail: ClientDetail) -> Json {
  let ClientDetail(profile:, since:, contracts:, projects:) = detail
  json.object([
    #("profile", encode_client_profile(profile)),
    #("since", wire.encode_option_date(since)),
    #("contracts", json.array(contracts, encode_contract_row)),
    #("projects", json.array(projects, encode_client_project_row)),
  ])
}

/// Decode a `ClientDetail` from JSON.
pub fn client_detail_decoder() -> Decoder(ClientDetail) {
  use profile <- decode.field("profile", client_profile_decoder())
  use since <- decode.field("since", wire.option_date_decoder())
  use contracts <- decode.field(
    "contracts",
    decode.list(contract_row_decoder()),
  )
  use projects <- decode.field(
    "projects",
    decode.list(client_project_row_decoder()),
  )
  decode.success(ClientDetail(profile:, since:, contracts:, projects:))
}

/// Encode a `ClientListRow` (one clients-list row) as a JSON object.
pub fn encode_client_list_row(client: ClientListRow) -> Json {
  let ClientListRow(client_id:, name:, since:, project_count:, active:) = client
  json.object([
    #("client_id", json.int(client_id)),
    #("name", json.string(name)),
    #("since", wire.encode_option_date(since)),
    #("project_count", json.int(project_count)),
    #("active", json.bool(active)),
  ])
}

/// Decode a `ClientListRow` from a JSON object.
pub fn client_list_row_decoder() -> Decoder(ClientListRow) {
  use client_id <- decode.field("client_id", decode.int)
  use name <- decode.field("name", decode.string)
  use since <- decode.field("since", wire.option_date_decoder())
  use project_count <- decode.field("project_count", decode.int)
  use active <- decode.field("active", decode.bool)
  decode.success(ClientListRow(
    client_id:,
    name:,
    since:,
    project_count:,
    active:,
  ))
}

/// Encode a `ClientList` (the clients list for a date) to JSON.
pub fn encode_client_list(list: ClientList) -> Json {
  let ClientList(date:, clients:, next_cursor:) = list
  json.object([
    #("date", wire.encode_date(date)),
    #("clients", json.array(clients, encode_client_list_row)),
    #("next_cursor", pagination.encode_next_cursor(next_cursor)),
  ])
}

/// Decode a `ClientList` from JSON.
pub fn client_list_decoder() -> Decoder(ClientList) {
  use date <- decode.field("date", wire.date_decoder())
  use clients <- decode.field("clients", decode.list(client_list_row_decoder()))
  use next_cursor <- decode.field(
    "next_cursor",
    pagination.next_cursor_decoder(),
  )
  decode.success(ClientList(date:, clients:, next_cursor:))
}
