//// Domain: the project capability-coverage READ model
//// (`GET /api/projects/:id/coverage?as_of=`). Assembles the capability catalog
//// as-of (the Set-requirement modal's select source) and the project's coverage
//// requirements as-of: each required capability split into the engineers who
//// cover it (rolled-up proficiency at or above the requirement's target level)
//// and the ones who don't. No HTTP — this layer never imports `wisp`.
////
//// Returns `Result(Result(CoverageSnapshot, Nil), pog.QueryError)`: `Ok(Error(Nil))`
//// when the project has no current profile (no such project) so the handler can
//// answer a 404 rather than a 500; `Error(_)` is a database failure.
////
//// The reads run SEQUENTIALLY (not fanned out concurrently) — a spawned process
//// cannot see the uncommitted rows of a transaction-fixture test, and the domain
//// tests drive this view inside one.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/project_capability/view.{
  type CapabilityChoice, type CoverageEngineer, type CoverageRequirement,
  type CoverageSnapshot, CapabilityChoice, CoverageEngineer, CoverageRequirement,
  CoverageSnapshot,
}
import tempo/server/capability/sql as capability_sql
import tempo/server/context.{type Context}
import tempo/server/project_capability/sql

/// The project's capability coverage as-of `as_of`. `Ok(Error(Nil))` when no
/// current profile (unknown project) → the handler answers 404; `Ok(Ok(snapshot))`
/// otherwise.
pub fn coverage(
  context: Context,
  project_id: Int,
  as_of: Date,
) -> Result(Result(CoverageSnapshot, Nil), pog.QueryError) {
  use profile_rows <- result.try(current_profile(context, project_id))
  case profile_rows {
    [] -> Ok(Error(Nil))
    [_, ..] -> {
      use catalog <- result.try(capability_sql.capability_catalog(
        context.db,
        as_of,
      ))
      use requirements <- result.try(sql.project_capabilities(
        context.db,
        project_id,
        as_of,
      ))
      use coverage_rows <- result.map(sql.capability_coverage(
        context.db,
        project_id,
        as_of,
      ))
      Ok(CoverageSnapshot(
        catalog: list.map(catalog.rows, capability_choice_to_shared),
        requirements: list.map(requirements.rows, requirement_to_shared(
          _,
          coverage_rows.rows,
        )),
      ))
    }
  }
}

/// Check the project's existence (id + current profile) from the
/// `project_current` view — the same source the sibling project-detail read
/// uses to gate its 404.
fn current_profile(
  context: Context,
  project_id: Int,
) -> Result(List(Int), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  use returned <- result.map(
    project_current_sql
    |> pog.query
    |> pog.parameter(pog.int(project_id))
    |> pog.returning(decoder)
    |> pog.execute(context.db),
  )
  returned.rows
}

const project_current_sql = "SELECT id FROM project_current WHERE id = $1;"

fn capability_choice_to_shared(
  row: capability_sql.CapabilityCatalogRow,
) -> CapabilityChoice {
  CapabilityChoice(capability_id: row.id, name: row.name)
}

fn requirement_to_shared(
  row: sql.ProjectCapabilitiesRow,
  coverage_rows: List(sql.CapabilityCoverageRow),
) -> CoverageRequirement {
  let allocated_engineers =
    list.filter(coverage_rows, fn(coverage_row) {
      coverage_row.capability_id == row.capability_id
    })
  let #(covering, others) =
    list.partition(allocated_engineers, fn(coverage_row) {
      coverage_row.proficiency >=. int.to_float(row.target_level)
    })
  CoverageRequirement(
    capability_id: row.capability_id,
    capability_name: row.name,
    target_level: row.target_level,
    quantity: row.quantity,
    valid_from: row.valid_from,
    valid_to: row.valid_to,
    covering: list.map(covering, coverage_engineer_to_shared),
    others: list.map(others, coverage_engineer_to_shared),
  )
}

fn coverage_engineer_to_shared(
  row: sql.CapabilityCoverageRow,
) -> CoverageEngineer {
  CoverageEngineer(
    engineer_id: row.engineer_id,
    name: row.name,
    proficiency: row.proficiency,
    allocation: row.fraction,
  )
}
