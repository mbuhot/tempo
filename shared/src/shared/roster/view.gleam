//// The operations-console directory read model and its JSON codec: a `Ref`
//// (id + name) directory entry and the as-of `Roster` of engineers/projects/
//// clients. Pure Gleam, no target-specific deps, so they round-trip on both ends
//// of the JSON-over-HTTP boundary.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}

/// A directory entry: a durable subject's id paired with its display name. The
/// operations console renders these as `<select>` options — the `id` is the
/// option value (what `build_command` parses), the `name` the visible text —
/// so the presenter picks a name and the form still carries the id/name string
/// the command needs.
pub type Ref {
  Ref(id: Int, name: String)
}

/// The operations-console directory as-of a date (`GET /api/roster?as_of=`): the
/// engineers EMPLOYED on the date and the projects ACTIVE on the date (both
/// date-filtered so the console can only name a subject valid then), plus every
/// client (a durable identity with no validity window, so not date-filtered).
/// Each list is a `Ref` (id + name) the console turns into `<select>` options.
pub type Roster {
  Roster(engineers: List(Ref), projects: List(Ref), clients: List(Ref))
}

/// Encode a `Ref` (one directory entry) as a JSON object.
pub fn encode_ref(reference: Ref) -> Json {
  let Ref(id:, name:) = reference
  json.object([#("id", json.int(id)), #("name", json.string(name))])
}

/// Decode a `Ref` from a JSON object.
pub fn ref_decoder() -> Decoder(Ref) {
  use id <- decode.field("id", decode.int)
  use name <- decode.field("name", decode.string)
  decode.success(Ref(id:, name:))
}

/// Encode a `Roster` (the console directory) as a JSON object.
pub fn encode_roster(roster: Roster) -> Json {
  let Roster(engineers:, projects:, clients:) = roster
  json.object([
    #("engineers", json.array(engineers, encode_ref)),
    #("projects", json.array(projects, encode_ref)),
    #("clients", json.array(clients, encode_ref)),
  ])
}

/// Decode a `Roster` from a JSON object.
pub fn roster_decoder() -> Decoder(Roster) {
  use engineers <- decode.field("engineers", decode.list(ref_decoder()))
  use projects <- decode.field("projects", decode.list(ref_decoder()))
  use clients <- decode.field("clients", decode.list(ref_decoder()))
  decode.success(Roster(engineers:, projects:, clients:))
}
