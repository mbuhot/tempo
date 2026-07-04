//// Domain: the per-engineer skills READ model
//// (`GET /api/engineers/:id/skills?as_of=`). Assembles one engineer's skill
//// matrix (every skill in the taxonomy, with the capabilities it feeds), the
//// as-of capability rollups, and the full assessment history. No HTTP — this
//// layer never imports `wisp`.
////
//// Returns `Result(Result(EngineerSkills, Nil), pog.QueryError)`: `Ok(Error(Nil))`
//// when the engineer has no current contact (no such engineer) so the handler
//// can answer a 404 rather than a 500; `Error(_)` is a database failure.
////
//// The reads run SEQUENTIALLY (not fanned out concurrently) — a spawned process
//// cannot see the uncommitted rows of a transaction-fixture test, and the domain
//// tests drive this view inside one.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/skill/view.{
  type AssessmentVersion, type CapabilityRollup, type EngineerSkills,
  type SkillAssessment, AssessmentVersion, CapabilityRollup, EngineerSkills,
  SkillAssessment,
}
import tempo/server/capability/sql as capability_sql
import tempo/server/context.{type Context}
import tempo/server/engineer/sql as engineer_sql
import tempo/server/engineer_skill/sql

/// One engineer's skills as-of `as_of`. `Ok(Error(Nil))` when no current contact
/// (unknown engineer) → the handler answers 404; `Ok(Ok(skills))` otherwise.
pub fn skills(
  context: Context,
  engineer_id: Int,
  as_of: Date,
) -> Result(Result(EngineerSkills, Nil), pog.QueryError) {
  use contact <- result.try(engineer_sql.engineer_contact_current(
    context.db,
    engineer_id,
  ))
  case contact.rows {
    [] -> Ok(Error(Nil))
    [_, ..] -> {
      use matrix <- result.try(sql.skill_matrix(context.db, engineer_id, as_of))
      use capabilities <- result.try(capability_sql.capability_catalog(
        context.db,
        as_of,
      ))
      use mappings <- result.try(capability_sql.capability_skill_matrix(
        context.db,
        as_of,
      ))
      use rollups <- result.try(sql.capability_rollup(
        context.db,
        engineer_id,
        as_of,
      ))
      use recent <- result.map(sql.recent_assessments(context.db, engineer_id))
      let capability_names = capability_names_by_id(capabilities.rows)
      let capability_names_by_skill =
        group_capability_names_by_skill(mappings.rows, capability_names)
      Ok(EngineerSkills(
        matrix: list.map(matrix.rows, skill_assessment_to_shared(
          _,
          capability_names_by_skill,
        )),
        rollups: list.map(rollups.rows, capability_rollup_to_shared),
        recent: list.map(recent.rows, assessment_version_to_shared),
      ))
    }
  }
}

fn capability_names_by_id(
  rows: List(capability_sql.CapabilityCatalogRow),
) -> Dict(Int, String) {
  rows
  |> list.map(fn(row) { #(row.id, row.name) })
  |> dict.from_list
}

/// Group the composition matrix's (capability, skill) mappings by skill id,
/// resolving each capability id to its name.
fn group_capability_names_by_skill(
  mappings: List(capability_sql.CapabilitySkillMatrixRow),
  capability_names: Dict(Int, String),
) -> Dict(Int, List(String)) {
  list.fold(mappings, dict.new(), fn(grouped, mapping) {
    case dict.get(capability_names, mapping.capability_id) {
      Ok(name) ->
        dict.upsert(grouped, mapping.skill_id, fn(existing) {
          case existing {
            Some(names) -> list.append(names, [name])
            None -> [name]
          }
        })
      Error(Nil) -> grouped
    }
  })
}

fn skill_assessment_to_shared(
  row: sql.SkillMatrixRow,
  capability_names_by_skill: Dict(Int, List(String)),
) -> SkillAssessment {
  SkillAssessment(
    skill_id: row.skill_id,
    name: row.name,
    level: row.level,
    capability_names: dict.get(capability_names_by_skill, row.skill_id)
      |> result.unwrap([]),
  )
}

fn capability_rollup_to_shared(
  row: sql.CapabilityRollupRow,
) -> CapabilityRollup {
  CapabilityRollup(
    capability_id: row.capability_id,
    name: row.name,
    proficiency: row.proficiency,
  )
}

fn assessment_version_to_shared(
  row: sql.RecentAssessmentsRow,
) -> AssessmentVersion {
  AssessmentVersion(
    skill_id: row.skill_id,
    skill_name: row.name,
    level: row.level,
    valid_from: row.valid_from,
    valid_to: open_end(row.ongoing, row.valid_to),
  )
}

/// An open (`ongoing`) period has no end date; otherwise its coalesced upper bound.
fn open_end(ongoing: Bool, valid_to: Date) -> Option(Date) {
  case ongoing {
    True -> None
    False -> Some(valid_to)
  }
}
