//// Domain: the capability & skill taxonomy READ model (`GET /api/skills?as_of=`).
//// Runs the three as-of catalog reads — the capability catalog, the skill
//// catalog, and the composition matrix — and bundles them into the shared
//// `TaxonomySnapshot`. No HTTP — this layer never imports `wisp`.

import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/skill/view.{
  type CapabilityInfo, type CapabilitySkillMapping, type SkillInfo,
  type TaxonomySnapshot, CapabilityInfo, CapabilitySkillMapping, SkillInfo,
  TaxonomySnapshot,
}
import tempo/server/capability/sql
import tempo/server/context.{type Context}

/// The taxonomy snapshot as-of `as_of`: the capability catalog, the skill
/// catalog, and the composition matrix in force on that date.
pub fn taxonomy(
  context: Context,
  as_of: Date,
) -> Result(TaxonomySnapshot, pog.QueryError) {
  use capabilities <- result.try(sql.capability_catalog(context.db, as_of))
  use skills <- result.try(sql.skill_catalog(context.db, as_of))
  use mappings <- result.map(sql.capability_skill_matrix(context.db, as_of))
  TaxonomySnapshot(
    capabilities: list.map(capabilities.rows, capability_info_to_shared),
    skills: list.map(skills.rows, skill_info_to_shared),
    mappings: list.map(mappings.rows, capability_skill_mapping_to_shared),
  )
}

fn capability_info_to_shared(row: sql.CapabilityCatalogRow) -> CapabilityInfo {
  CapabilityInfo(capability_id: row.id, name: row.name, summary: row.summary)
}

fn skill_info_to_shared(row: sql.SkillCatalogRow) -> SkillInfo {
  SkillInfo(skill_id: row.id, name: row.name, summary: row.summary)
}

fn capability_skill_mapping_to_shared(
  row: sql.CapabilitySkillMatrixRow,
) -> CapabilitySkillMapping {
  CapabilitySkillMapping(
    capability_id: row.capability_id,
    skill_id: row.skill_id,
    weight: row.weight,
  )
}
