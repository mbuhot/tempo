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
import shared/invoice/status as invoice_status
import shared/invoice/view.{type Invoice, Invoice} as _
import shared/money.{type Money}
import shared/pagination
import shared/project/view.{
  type ProjectDetail, type ProjectList, type ProjectListRow, type ProjectPlan,
  type ProjectProfile, type ProjectRequirement, type TeamMember, ProjectDetail,
  ProjectList, ProjectListRow, ProjectPlan, ProjectProfile, ProjectRequirement,
  TeamMember,
} as _
import tempo/server/async.{type AsyncQuery}
import tempo/server/context.{type Context, query_timeout}
import tempo/server/project/sql
import tempo/server/web/cursor.{type NameIdBound, NameIdBound}

/// Parse a money amount from a trusted SQL `numeric::text` column.
fn money(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

/// One keyset page of the projects list as-of `as_of` (issue #12): each project
/// with its client, budget, target, team size, and active flag, starting strictly
/// after `after` at most `limit` rows, plus the `next_cursor` for the following
/// page (`None` on the last page). The order is the SQL's stable (title,
/// project_id).
pub fn list(
  context: Context,
  as_of: Date,
  after: NameIdBound,
  limit: Int,
) -> Result(ProjectList, pog.QueryError) {
  let NameIdBound(name:, id:) = after
  use returned <- result.map(sql.project_list(
    context.db,
    as_of,
    name,
    id,
    limit + 1,
  ))
  let #(rows, next_cursor) =
    pagination.paginate(returned.rows, limit, fn(row: sql.ProjectListRow) {
      cursor.encode_name_id(row.title, row.project_id)
    })
  ProjectList(
    date: as_of,
    projects: list.map(rows, list_row_to_shared),
    next_cursor:,
  )
}

fn list_row_to_shared(row: sql.ProjectListRow) -> ProjectListRow {
  ProjectListRow(
    project_id: row.project_id,
    title: row.title,
    client: row.client,
    budget: money(row.budget),
    target_completion: row.target_completion,
    team_size: row.team_size,
    active: row.active,
  )
}

/// One project's detail as-of `as_of`. `Ok(Error(Nil))` when no profile or no run
/// (unknown id) → 404. The as-of drives the run `active` flag and the team/invoices
/// snapshot.
///
/// The six component queries are independent, so they fan out CONCURRENTLY and are
/// awaited together — the wall-clock cost is the slowest one, not their sum. The
/// profile query is the 404 gate: for an unknown project the other five still run
/// (returning empty), a few wasted reads on the rare miss for a single round-trip on
/// the common hit.
pub fn detail(
  context: Context,
  project_id: Int,
  as_of: Date,
) -> Result(Result(ProjectDetail, Nil), pog.QueryError) {
  let profile = async.start(fn() { current_profile(context, project_id) })
  let plan: AsyncQuery(sql.ProjectPlanCurrentRow) =
    async.start(fn() { sql.project_plan_current(context.db, project_id) })
  let run: AsyncQuery(sql.ProjectRunPeriodRow) =
    async.start(fn() { sql.project_run_period(context.db, project_id, as_of) })
  let team: AsyncQuery(sql.ProjectTeamRow) =
    async.start(fn() { sql.project_team(context.db, project_id, as_of) })
  let requirements: AsyncQuery(sql.ProjectRequirementsRow) =
    async.start(fn() { sql.project_requirements(context.db, project_id) })
  let invoices: AsyncQuery(sql.ProjectInvoicesRow) =
    async.start(fn() { sql.project_invoices(context.db, project_id, as_of) })

  let profile = async.await(profile, query_timeout)
  let plan = async.await(plan, query_timeout)
  let run = async.await(run, query_timeout)
  let team = async.await(team, query_timeout)
  let requirements = async.await(requirements, query_timeout)
  let invoices = async.await(invoices, query_timeout)

  use profile_rows <- result.try(profile)
  use plan <- result.try(plan)
  use run <- result.try(run)
  use team <- result.try(team)
  use requirements <- result.try(requirements)
  use invoices <- result.map(invoices)

  case profile_rows {
    [] -> Error(Nil)
    [profile, ..] ->
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
    budget: money(row.budget),
    target_completion: row.target_completion,
  )
}

fn team_member_to_shared(row: sql.ProjectTeamRow) -> TeamMember {
  TeamMember(
    engineer_id: row.engineer_id,
    name: row.name,
    level: row.level,
    fraction: row.fraction,
    day_rate: money(row.day_rate),
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
  let assert Ok(status) = invoice_status.from_string(row.status)
  Invoice(
    id: row.id,
    project: row.project,
    client: row.client,
    billing_from: row.billing_from,
    billing_to: row.billing_to,
    status:,
    total: money(row.total),
    issued_at: row.issued_at,
    paid_at: row.paid_at,
  )
}
