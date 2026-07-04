//// The project capability-coverage read model and its JSON codec: the demand
//// (`CoverageRequirement`) for a capability at a target level over a bounded
//// window, split into the engineers who cover it and the ones who don't (design
//// §coverage). Pure Gleam, no target-specific deps, so it round-trips on both
//// ends of the JSON-over-HTTP boundary. Dates serialise as ISO-8601 "YYYY-MM-DD"
//// strings; `proficiency` and `allocation` are read-side rollups, decoded
//// leniently as `Float`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire

/// One capability in the catalog, as-of a date — the client's Set-requirement
/// modal sources its select from this rather than the `skills.manage`-gated
/// taxonomy read.
pub type CapabilityChoice {
  CapabilityChoice(capability_id: Int, name: String)
}

/// One engineer covering (or not covering) a requirement: their rolled-up
/// `proficiency` (Phase 1 `capability_rollup` math) and their allocation share
/// on the project.
pub type CoverageEngineer {
  CoverageEngineer(
    engineer_id: Int,
    name: String,
    proficiency: Float,
    allocation: Float,
  )
}

/// One required capability on the project-detail coverage read model: the
/// project needs `quantity` engineers at `target_level` over
/// `[valid_from, valid_to)`, split into `covering` (proficiency ≥ target_level)
/// and `others` (allocated but below target).
pub type CoverageRequirement {
  CoverageRequirement(
    capability_id: Int,
    capability_name: String,
    target_level: Int,
    quantity: Float,
    valid_from: Date,
    valid_to: Date,
    covering: List(CoverageEngineer),
    others: List(CoverageEngineer),
  )
}

/// The project-detail Capability coverage read model
/// (`GET /api/projects/:id/coverage?as_of=`): the full capability `catalog`
/// as-of, and the project's coverage `requirements` as-of.
pub type CoverageSnapshot {
  CoverageSnapshot(
    catalog: List(CapabilityChoice),
    requirements: List(CoverageRequirement),
  )
}

pub fn encode_coverage_snapshot(snapshot: CoverageSnapshot) -> Json {
  let CoverageSnapshot(catalog:, requirements:) = snapshot
  json.object([
    #("catalog", json.array(catalog, encode_capability_choice)),
    #("requirements", json.array(requirements, encode_coverage_requirement)),
  ])
}

pub fn coverage_snapshot_decoder() -> Decoder(CoverageSnapshot) {
  use catalog <- decode.field(
    "catalog",
    decode.list(capability_choice_decoder()),
  )
  use requirements <- decode.field(
    "requirements",
    decode.list(coverage_requirement_decoder()),
  )
  decode.success(CoverageSnapshot(catalog:, requirements:))
}

fn encode_capability_choice(choice: CapabilityChoice) -> Json {
  let CapabilityChoice(capability_id:, name:) = choice
  json.object([
    #("capability_id", json.int(capability_id)),
    #("name", json.string(name)),
  ])
}

fn capability_choice_decoder() -> Decoder(CapabilityChoice) {
  use capability_id <- decode.field("capability_id", decode.int)
  use name <- decode.field("name", decode.string)
  decode.success(CapabilityChoice(capability_id:, name:))
}

fn encode_coverage_requirement(requirement: CoverageRequirement) -> Json {
  let CoverageRequirement(
    capability_id:,
    capability_name:,
    target_level:,
    quantity:,
    valid_from:,
    valid_to:,
    covering:,
    others:,
  ) = requirement
  json.object([
    #("capability_id", json.int(capability_id)),
    #("capability_name", json.string(capability_name)),
    #("target_level", json.int(target_level)),
    #("quantity", json.float(quantity)),
    #("valid_from", wire.encode_date(valid_from)),
    #("valid_to", wire.encode_date(valid_to)),
    #("covering", json.array(covering, encode_coverage_engineer)),
    #("others", json.array(others, encode_coverage_engineer)),
  ])
}

fn coverage_requirement_decoder() -> Decoder(CoverageRequirement) {
  use capability_id <- decode.field("capability_id", decode.int)
  use capability_name <- decode.field("capability_name", decode.string)
  use target_level <- decode.field("target_level", decode.int)
  use quantity <- decode.field("quantity", wire.lenient_float_decoder())
  use valid_from <- decode.field("valid_from", wire.date_decoder())
  use valid_to <- decode.field("valid_to", wire.date_decoder())
  use covering <- decode.field(
    "covering",
    decode.list(coverage_engineer_decoder()),
  )
  use others <- decode.field("others", decode.list(coverage_engineer_decoder()))
  decode.success(CoverageRequirement(
    capability_id:,
    capability_name:,
    target_level:,
    quantity:,
    valid_from:,
    valid_to:,
    covering:,
    others:,
  ))
}

fn encode_coverage_engineer(engineer: CoverageEngineer) -> Json {
  let CoverageEngineer(engineer_id:, name:, proficiency:, allocation:) =
    engineer
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("proficiency", json.float(proficiency)),
    #("allocation", json.float(allocation)),
  ])
}

fn coverage_engineer_decoder() -> Decoder(CoverageEngineer) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use proficiency <- decode.field("proficiency", wire.lenient_float_decoder())
  use allocation <- decode.field("allocation", wire.lenient_float_decoder())
  decode.success(CoverageEngineer(
    engineer_id:,
    name:,
    proficiency:,
    allocation:,
  ))
}
