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
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/project_capability/view.{
  type CapabilityChoice, type CoverageEngineer, type CoverageRequirement,
  type CoverageSnapshot, type GapRecommendations, type Pairing,
  type Recommendation, CapabilityChoice, CoverageEngineer, CoverageRequirement,
  CoverageSnapshot, GapRecommendations, Pairing, Recommendation,
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

/// The project's assignment recommendations as-of `as_of` (#40 Phase 3): for
/// each UNMET required capability (covered engineer count below `quantity`,
/// the same `covering` count `coverage` computes), the ranked candidates NOT
/// currently on the project — ready-now fits (proficiency >= 1.0) first, then
/// growth pairings (a below-target learner shadowing an on-team level-4
/// teacher). `Ok(Error(Nil))` when no current profile (unknown project) → the
/// handler answers 404; `Ok(Ok(gaps))` otherwise.
pub fn recommendations(
  context: Context,
  project_id: Int,
  as_of: Date,
) -> Result(Result(List(GapRecommendations), Nil), pog.QueryError) {
  use profile_rows <- result.try(current_profile(context, project_id))
  case profile_rows {
    [] -> Ok(Error(Nil))
    [_, ..] -> {
      use requirements <- result.try(sql.project_capabilities(
        context.db,
        project_id,
        as_of,
      ))
      use coverage_rows <- result.try(sql.capability_coverage(
        context.db,
        project_id,
        as_of,
      ))
      use candidate_rows <- result.try(sql.recommendation_candidates(
        context.db,
        project_id,
        as_of,
      ))
      use pairing_rows <- result.map(sql.recommendation_pairings(
        context.db,
        project_id,
        as_of,
      ))
      Ok(
        list.filter_map(requirements.rows, fn(requirement) {
          option.to_result(
            gap_recommendations(
              requirement,
              coverage_rows.rows,
              candidate_rows.rows,
              pairing_rows.rows,
            ),
            Nil,
          )
        }),
      )
    }
  }
}

fn gap_recommendations(
  requirement: sql.ProjectCapabilitiesRow,
  coverage_rows: List(sql.CapabilityCoverageRow),
  candidate_rows: List(sql.RecommendationCandidatesRow),
  pairing_rows: List(sql.RecommendationPairingsRow),
) -> Option(GapRecommendations) {
  let covered =
    covered_count(
      coverage_rows,
      requirement.capability_id,
      requirement.target_level,
    )
  case int.to_float(covered) <. requirement.quantity {
    False -> option.None
    True -> {
      let pool =
        list.filter(candidate_rows, fn(row) {
          row.capability_id == requirement.capability_id
        })
      let requirement_pairing_rows =
        list.filter(pairing_rows, fn(row) {
          row.capability_id == requirement.capability_id
        })
      let ready_now =
        pool
        |> list.filter(fn(row) { row.proficiency >=. 1.0 })
        |> rank_ready_now(requirement.target_level)
        |> list.map(ready_now_recommendation(_, requirement.name))
      let growth =
        pool
        |> list.filter(fn(row) { row.proficiency <. 1.0 })
        |> list.filter_map(growth_recommendation(_, requirement_pairing_rows))
        |> rank_growth
      option.Some(GapRecommendations(
        capability_id: requirement.capability_id,
        capability_name: requirement.name,
        target_level: requirement.target_level,
        quantity: requirement.quantity,
        covered:,
        recommendations: list.append(ready_now, growth),
      ))
    }
  }
}

/// The Phase-2 coverage `covering` list length: allocated engineers whose
/// rolled-up proficiency in `capability_id` is at or above `target_level`.
fn covered_count(
  coverage_rows: List(sql.CapabilityCoverageRow),
  capability_id: Int,
  target_level: Int,
) -> Int {
  coverage_rows
  |> list.filter(fn(row) {
    row.capability_id == capability_id
    && row.proficiency >=. int.to_float(target_level)
  })
  |> list.length
}

/// Ready-now candidates ranked by capped fit (proficiency / target_level,
/// capped at 1.0 so an above-target fit ties an at-target one) DESC, then free
/// DESC, then name ASC.
fn rank_ready_now(
  rows: List(sql.RecommendationCandidatesRow),
  target_level: Int,
) -> List(sql.RecommendationCandidatesRow) {
  list.sort(rows, fn(left, right) {
    case
      float.compare(
        capped_fit(right, target_level),
        capped_fit(left, target_level),
      )
    {
      order.Eq ->
        case float.compare(right.free, left.free) {
          order.Eq -> string.compare(left.name, right.name)
          other -> other
        }
      other -> other
    }
  })
}

fn capped_fit(
  row: sql.RecommendationCandidatesRow,
  target_level: Int,
) -> Float {
  float.min(row.proficiency /. int.to_float(target_level), 1.0)
}

fn ready_now_recommendation(
  row: sql.RecommendationCandidatesRow,
  capability_name: String,
) -> Recommendation {
  Recommendation(
    engineer_id: row.engineer_id,
    name: row.name,
    level: row.level,
    proficiency: row.proficiency,
    free: row.free,
    rationale: "covers the "
      <> capability_name
      <> " gap at "
      <> one_decimal(row.proficiency)
      <> "; "
      <> percent(row.free)
      <> "% available",
    pairing: option.None,
  )
}

/// A below-target candidate's growth recommendation, or `Error(Nil)` when no
/// qualifying pairing exists (omitted from the result entirely).
fn growth_recommendation(
  row: sql.RecommendationCandidatesRow,
  pairing_rows: List(sql.RecommendationPairingsRow),
) -> Result(Recommendation, Nil) {
  use pairing <- result.map(choose_pairing(pairing_rows, row.engineer_id))
  Recommendation(
    engineer_id: row.engineer_id,
    name: row.name,
    level: row.level,
    proficiency: row.proficiency,
    free: row.free,
    rationale: "growth: learns "
      <> pairing.skill_name
      <> " under "
      <> pairing.teacher_name
      <> "; "
      <> percent(row.free)
      <> "% available",
    pairing: option.Some(pairing),
  )
}

/// The one pairing a learner gets: among their qualifying rows (already
/// weight >= 2, level 1/2, with a real on-team level-4 teacher — the SQL
/// guarantees that), the highest-weight skill, then skill name ASC, then
/// teacher name ASC.
fn choose_pairing(
  pairing_rows: List(sql.RecommendationPairingsRow),
  learner_id: Int,
) -> Result(Pairing, Nil) {
  let learner_rows =
    list.filter(pairing_rows, fn(row) { row.learner_id == learner_id })
  use best_weight <- result.try(
    learner_rows
    |> list.map(fn(row) { row.weight })
    |> list.reduce(int.max),
  )
  let top_weight_rows =
    list.filter(learner_rows, fn(row) { row.weight == best_weight })
  use chosen_skill_name <- result.try(
    top_weight_rows
    |> list.map(fn(row) { row.skill_name })
    |> list.sort(string.compare)
    |> list.first,
  )
  use chosen_row <- result.map(
    top_weight_rows
    |> list.filter(fn(row) { row.skill_name == chosen_skill_name })
    |> list.sort(fn(left, right) {
      string.compare(left.teacher_name, right.teacher_name)
    })
    |> list.first,
  )
  Pairing(
    teacher_id: chosen_row.teacher_id,
    teacher_name: chosen_row.teacher_name,
    skill_name: chosen_row.skill_name,
  )
}

/// Growth rows ranked by free DESC, then name ASC.
fn rank_growth(rows: List(Recommendation)) -> List(Recommendation) {
  list.sort(rows, fn(left, right) {
    case float.compare(right.free, left.free) {
      order.Eq -> string.compare(left.name, right.name)
      other -> other
    }
  })
}

fn one_decimal(value: Float) -> String {
  value
  |> float.to_precision(1)
  |> float.to_string
}

fn percent(free: Float) -> String {
  { free *. 100.0 }
  |> float.round
  |> int.to_string
}
