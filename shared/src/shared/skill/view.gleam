//// The capability & skill taxonomy read models and their JSON codecs: the
//// `TaxonomySnapshot` behind the taxonomy admin page (`GET /api/skills`) and the
//// `EngineerSkills` bundle behind an engineer's skills tab
//// (`GET /api/engineers/:id/skills`). Pure Gleam, no target-specific deps, so they
//// round-trip on both ends of the JSON-over-HTTP boundary. Dates serialise as
//// ISO-8601 "YYYY-MM-DD" strings; `proficiency` is the read-side weighted-average
//// rollup, decoded leniently as a `Float`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/wire

/// One capability in the catalog, as-of a date.
pub type CapabilityInfo {
  CapabilityInfo(capability_id: Int, name: String, summary: String)
}

/// One skill in the catalog, as-of a date.
pub type SkillInfo {
  SkillInfo(skill_id: Int, name: String, summary: String)
}

/// One (capability, skill) composition weight in force as-of a date — a
/// weighted cell of the composition matrix.
pub type CapabilitySkillMapping {
  CapabilitySkillMapping(capability_id: Int, skill_id: Int, weight: Int)
}

/// The taxonomy admin read model (`GET /api/skills`): the capability catalog, the
/// skill catalog, and the composition matrix in force as-of a date.
pub type TaxonomySnapshot {
  TaxonomySnapshot(
    capabilities: List(CapabilityInfo),
    skills: List(SkillInfo),
    mappings: List(CapabilitySkillMapping),
  )
}

/// One row of an engineer's skill matrix, as-of a date: the skill's level (0 if
/// never assessed) and the capabilities it feeds.
pub type SkillAssessment {
  SkillAssessment(
    skill_id: Int,
    name: String,
    level: Int,
    capability_names: List(String),
  )
}

/// One capability's rolled-up proficiency for an engineer, as-of a date — the
/// weighted average of the engineer's skill levels across the capability's
/// constituent skills.
pub type CapabilityRollup {
  CapabilityRollup(capability_id: Int, name: String, proficiency: Float)
}

/// One version of an engineer's assessment on a skill — the history row behind
/// the recent-assessments panel.
pub type AssessmentVersion {
  AssessmentVersion(
    skill_id: Int,
    skill_name: String,
    level: Int,
    valid_from: Date,
    valid_to: Option(Date),
  )
}

/// The per-engineer skills read model (`GET /api/engineers/:id/skills`): the
/// as-of skill matrix, the as-of capability rollups, and the recent assessment
/// history.
pub type EngineerSkills {
  EngineerSkills(
    matrix: List(SkillAssessment),
    rollups: List(CapabilityRollup),
    recent: List(AssessmentVersion),
  )
}

pub fn encode_taxonomy_snapshot(snapshot: TaxonomySnapshot) -> Json {
  let TaxonomySnapshot(capabilities:, skills:, mappings:) = snapshot
  json.object([
    #("capabilities", json.array(capabilities, encode_capability_info)),
    #("skills", json.array(skills, encode_skill_info)),
    #("mappings", json.array(mappings, encode_capability_skill_mapping)),
  ])
}

pub fn taxonomy_snapshot_decoder() -> Decoder(TaxonomySnapshot) {
  use capabilities <- decode.field(
    "capabilities",
    decode.list(capability_info_decoder()),
  )
  use skills <- decode.field("skills", decode.list(skill_info_decoder()))
  use mappings <- decode.field(
    "mappings",
    decode.list(capability_skill_mapping_decoder()),
  )
  decode.success(TaxonomySnapshot(capabilities:, skills:, mappings:))
}

fn encode_capability_info(info: CapabilityInfo) -> Json {
  let CapabilityInfo(capability_id:, name:, summary:) = info
  json.object([
    #("capability_id", json.int(capability_id)),
    #("name", json.string(name)),
    #("summary", json.string(summary)),
  ])
}

fn capability_info_decoder() -> Decoder(CapabilityInfo) {
  use capability_id <- decode.field("capability_id", decode.int)
  use name <- decode.field("name", decode.string)
  use summary <- decode.field("summary", decode.string)
  decode.success(CapabilityInfo(capability_id:, name:, summary:))
}

fn encode_skill_info(info: SkillInfo) -> Json {
  let SkillInfo(skill_id:, name:, summary:) = info
  json.object([
    #("skill_id", json.int(skill_id)),
    #("name", json.string(name)),
    #("summary", json.string(summary)),
  ])
}

fn skill_info_decoder() -> Decoder(SkillInfo) {
  use skill_id <- decode.field("skill_id", decode.int)
  use name <- decode.field("name", decode.string)
  use summary <- decode.field("summary", decode.string)
  decode.success(SkillInfo(skill_id:, name:, summary:))
}

fn encode_capability_skill_mapping(mapping: CapabilitySkillMapping) -> Json {
  let CapabilitySkillMapping(capability_id:, skill_id:, weight:) = mapping
  json.object([
    #("capability_id", json.int(capability_id)),
    #("skill_id", json.int(skill_id)),
    #("weight", json.int(weight)),
  ])
}

fn capability_skill_mapping_decoder() -> Decoder(CapabilitySkillMapping) {
  use capability_id <- decode.field("capability_id", decode.int)
  use skill_id <- decode.field("skill_id", decode.int)
  use weight <- decode.field("weight", decode.int)
  decode.success(CapabilitySkillMapping(capability_id:, skill_id:, weight:))
}

pub fn encode_engineer_skills(skills: EngineerSkills) -> Json {
  let EngineerSkills(matrix:, rollups:, recent:) = skills
  json.object([
    #("matrix", json.array(matrix, encode_skill_assessment)),
    #("rollups", json.array(rollups, encode_capability_rollup)),
    #("recent", json.array(recent, encode_assessment_version)),
  ])
}

pub fn engineer_skills_decoder() -> Decoder(EngineerSkills) {
  use matrix <- decode.field("matrix", decode.list(skill_assessment_decoder()))
  use rollups <- decode.field(
    "rollups",
    decode.list(capability_rollup_decoder()),
  )
  use recent <- decode.field(
    "recent",
    decode.list(assessment_version_decoder()),
  )
  decode.success(EngineerSkills(matrix:, rollups:, recent:))
}

fn encode_skill_assessment(assessment: SkillAssessment) -> Json {
  let SkillAssessment(skill_id:, name:, level:, capability_names:) = assessment
  json.object([
    #("skill_id", json.int(skill_id)),
    #("name", json.string(name)),
    #("level", json.int(level)),
    #("capability_names", json.array(capability_names, json.string)),
  ])
}

fn skill_assessment_decoder() -> Decoder(SkillAssessment) {
  use skill_id <- decode.field("skill_id", decode.int)
  use name <- decode.field("name", decode.string)
  use level <- decode.field("level", decode.int)
  use capability_names <- decode.field(
    "capability_names",
    decode.list(decode.string),
  )
  decode.success(SkillAssessment(skill_id:, name:, level:, capability_names:))
}

fn encode_capability_rollup(rollup: CapabilityRollup) -> Json {
  let CapabilityRollup(capability_id:, name:, proficiency:) = rollup
  json.object([
    #("capability_id", json.int(capability_id)),
    #("name", json.string(name)),
    #("proficiency", json.float(proficiency)),
  ])
}

fn capability_rollup_decoder() -> Decoder(CapabilityRollup) {
  use capability_id <- decode.field("capability_id", decode.int)
  use name <- decode.field("name", decode.string)
  use proficiency <- decode.field("proficiency", wire.lenient_float_decoder())
  decode.success(CapabilityRollup(capability_id:, name:, proficiency:))
}

fn encode_assessment_version(version: AssessmentVersion) -> Json {
  let AssessmentVersion(skill_id:, skill_name:, level:, valid_from:, valid_to:) =
    version
  json.object([
    #("skill_id", json.int(skill_id)),
    #("skill_name", json.string(skill_name)),
    #("level", json.int(level)),
    #("valid_from", wire.encode_date(valid_from)),
    #("valid_to", wire.encode_option_date(valid_to)),
  ])
}

fn assessment_version_decoder() -> Decoder(AssessmentVersion) {
  use skill_id <- decode.field("skill_id", decode.int)
  use skill_name <- decode.field("skill_name", decode.string)
  use level <- decode.field("level", decode.int)
  use valid_from <- decode.field("valid_from", wire.date_decoder())
  use valid_to <- decode.field("valid_to", wire.option_date_decoder())
  decode.success(AssessmentVersion(
    skill_id:,
    skill_name:,
    level:,
    valid_from:,
    valid_to:,
  ))
}
