//// Domain: the project READ models — the projects `list` (`GET /api/projects?as_of=`)
//// and one project's `detail` (`GET /api/projects/:id?as_of=`). No HTTP — this
//// layer never imports `wisp`.
////
//// `list` runs `project_list` (every project with a run: title, client name,
//// budget, target, team size as-of, and `active` = run covering the date) and maps
//// each row. `detail` reads the project's profile from the `project_current` view,
//// its current plan (`project_plan_current`), its run period + client name
//// (`project_run_period`), its as-of team (`project_team`) and its invoices
//// (`project_invoices`). The team cards mirror the board's OnProject cards but also
//// carry the engineer_id for click-through.
////
//// `detail` returns `Result(Result(ProjectDetail, Nil), pog.QueryError)`:
//// `Ok(Error(Nil))` when the project has no profile or no run (unknown id) so the
//// handler can answer a 404; `Error(_)` is a database failure.

import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/invoice/view.{type Invoice, Invoice} as _
import shared/project/view.{
  type ProjectDetail, type ProjectList, type ProjectListRow, type ProjectPlan,
  type ProjectProfile, type ProjectRequirement, type TeamMember, ProjectDetail,
  ProjectList, ProjectListRow, ProjectPlan, ProjectProfile, ProjectRequirement,
  TeamMember,
} as _
import tempo/server/context.{type Context}
import tempo/server/sql

/// The projects list as-of `as_of`: every project with a run, with its client,
/// budget, target, team size, and active flag.
pub fn list(
  context: Context,
  as_of: Date,
) -> Result(ProjectList, pog.QueryError) {
  use returned <- result.map(sql.project_list(context.db, as_of))
  ProjectList(
    date: as_of,
    projects: list.map(returned.rows, list_row_to_shared),
  )
}

fn list_row_to_shared(row: sql.ProjectListRow) -> ProjectListRow {
  ProjectListRow(
    project_id: row.project_id,
    title: row.title,
    client: row.client,
    budget: row.budget,
    target_completion: row.target_completion,
    team_size: row.team_size,
    active: row.active,
  )
}

/// One project's detail as-of `as_of`. `Ok(Error(Nil))` when no profile or no run
/// (unknown id) → 404. The as-of drives the run `active` flag and the team/invoices
/// snapshot.
pub fn detail(
  context: Context,
  project_id: Int,
  as_of: Date,
) -> Result(Result(ProjectDetail, Nil), pog.QueryError) {
  use profile_rows <- result.try(current_profile(context, project_id))
  case profile_rows {
    [] -> Ok(Error(Nil))
    [profile, ..] -> assemble(context, project_id, as_of, profile)
  }
}

fn assemble(
  context: Context,
  project_id: Int,
  as_of: Date,
  profile: ProjectProfile,
) -> Result(Result(ProjectDetail, Nil), pog.QueryError) {
  use plan <- result.try(sql.project_plan_current(context.db, project_id))
  use run <- result.try(sql.project_run_period(context.db, project_id, as_of))
  use team <- result.try(sql.project_team(context.db, project_id, as_of))
  use requirements <- result.try(sql.project_requirements(
    context.db,
    project_id,
  ))
  use invoices <- result.map(sql.project_invoices(context.db, project_id, as_of))

  case plan.rows, run.rows {
    [plan, ..], [run, ..] ->
      Ok(ProjectDetail(
        profile:,
        client: run.client,
        plan: plan_to_shared(plan),
        valid_from: run.valid_from,
        valid_to: run.valid_to,
        active: run.active,
        team: list.map(team.rows, team_member_to_shared),
        requirements: list.map(requirements.rows, requirement_to_shared),
        invoices: list.map(invoices.rows, invoice_to_shared),
      ))
    _, _ -> Error(Nil)
  }
}

/// Read the project's profile (id + title + summary) from the `project_current`
/// view directly — no dedicated `.sql` reader exists and the view exposes all three.
fn current_profile(
  context: Context,
  project_id: Int,
) -> Result(List(ProjectProfile), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use summary <- decode.field(2, decode.string)
    decode.success(ProjectProfile(project_id: id, title:, summary:))
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

const project_current_sql = "SELECT id, title, summary
FROM project_current
WHERE id = $1;"

fn plan_to_shared(row: sql.ProjectPlanCurrentRow) -> ProjectPlan {
  ProjectPlan(
    project_id: row.project_id,
    budget: row.budget,
    target_completion: row.target_completion,
  )
}

fn team_member_to_shared(row: sql.ProjectTeamRow) -> TeamMember {
  TeamMember(
    engineer_id: row.engineer_id,
    name: row.name,
    level: row.level,
    fraction: row.fraction,
    day_rate: row.day_rate,
  )
}

fn requirement_to_shared(
  row: sql.ProjectRequirementsRow,
) -> ProjectRequirement {
  ProjectRequirement(
    project_id: row.project_id,
    level: row.level,
    quantity: row.quantity,
    valid_from: row.valid_from,
    valid_to: row.valid_to,
  )
}

fn invoice_to_shared(row: sql.ProjectInvoicesRow) -> Invoice {
  Invoice(
    id: row.id,
    project: row.project,
    client: row.client,
    billing_from: row.billing_from,
    billing_to: row.billing_to,
    status: row.status,
    total: row.total,
    issued_at: row.issued_at,
    paid_at: row.paid_at,
  )
}
