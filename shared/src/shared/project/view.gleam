//// The project read models and their JSON codecs: the `ProjectProfile`/
//// `ProjectPlan` facts, the projects-list `ProjectListRow`/`ProjectList`, the
//// project-detail row types (`TeamMember`/`ProjectRequirement`) and the
//// `ProjectDetail` bundle. Pure Gleam, no target-specific deps, so they
//// round-trip on both ends of the JSON-over-HTTP boundary. Dates serialise as
//// ISO-8601 "YYYY-MM-DD" strings; money fields decode leniently. `ProjectDetail`
//// embeds the invoices from `shared/invoice/view`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/invoice/view as invoice_view
import shared/wire

/// A project's profile as one edit-grouped fact: the project's `title` (the
/// human-facing name) and a free-text `summary`. The underlying
/// `project_profile` table is period-keyed (`recorded_during`) and append-only,
/// read LATEST — so this record carries only the scalar fields of the
/// most-recently-recorded version, not its transaction-time bounds (mirroring
/// `ClientProfile`).
pub type ProjectProfile {
  ProjectProfile(project_id: Int, title: String, summary: String)
}

/// A project's plan as one edit-grouped fact: the `budget` (a money amount, so
/// a `Float`) and a `target_completion` date. The underlying `project_plan`
/// table is period-keyed (`planned_during`) and append-only, read LATEST — so
/// this record carries only the scalar fields of the most-recently-recorded
/// version, not its transaction-time bounds.
pub type ProjectPlan {
  ProjectPlan(project_id: Int, budget: Float, target_completion: Date)
}

/// One row of the projects list (`GET /api/projects?as_of=`): a project's `title`,
/// `client` name, `budget`, `target_completion`, `team_size` (allocations covering
/// the as-of date), and `active` (true when its run covers the as-of date).
pub type ProjectListRow {
  ProjectListRow(
    project_id: Int,
    title: String,
    client: String,
    budget: Float,
    target_completion: Date,
    team_size: Int,
    active: Bool,
  )
}

/// The projects list for a single date (mirrors `PeopleList`): the `date` and one
/// `ProjectListRow` per project.
pub type ProjectList {
  ProjectList(date: Date, projects: List(ProjectListRow))
}

/// One member of a project's team on the project-detail read model: the engineer's
/// `name`, `level`, allocation `fraction`, and resolved `day_rate`. Carries
/// `engineer_id` so the team card can click through to the engineer detail. Band
/// is derived client-side from `level`.
pub type TeamMember {
  TeamMember(
    engineer_id: Int,
    name: String,
    level: Int,
    fraction: Float,
    day_rate: Float,
  )
}

/// One capacity requirement on the project-detail read model (demand): the project
/// needs `quantity` FTE at a given `level` over `[valid_from, valid_to)`. One line
/// per `(project, level)` over non-overlapping periods. Independent of which
/// engineers (if any) fill it — the roles may need to be hired.
pub type ProjectRequirement {
  ProjectRequirement(
    project_id: Int,
    level: Int,
    quantity: Float,
    valid_from: Date,
    valid_to: Date,
  )
}

/// The project-detail read model (`GET /api/projects/:id?as_of=`): the project's
/// `profile` and `plan`, its `client` name, its run period `[valid_from, valid_to)`
/// with `active` (covers the as-of date), its `team` as-of, its capacity
/// `requirements` (demand), and its `invoices`.
pub type ProjectDetail {
  ProjectDetail(
    profile: ProjectProfile,
    client: String,
    plan: ProjectPlan,
    valid_from: Date,
    valid_to: Date,
    active: Bool,
    team: List(TeamMember),
    requirements: List(ProjectRequirement),
    invoices: List(invoice_view.Invoice),
  )
}

/// Encode a `ProjectProfile` (the project's current profile fact) as a JSON
/// object.
pub fn encode_project_profile(profile: ProjectProfile) -> Json {
  let ProjectProfile(project_id:, title:, summary:) = profile
  json.object([
    #("project_id", json.int(project_id)),
    #("title", json.string(title)),
    #("summary", json.string(summary)),
  ])
}

/// Decode a `ProjectProfile` from a JSON object.
pub fn project_profile_decoder() -> Decoder(ProjectProfile) {
  use project_id <- decode.field("project_id", decode.int)
  use title <- decode.field("title", decode.string)
  use summary <- decode.field("summary", decode.string)
  decode.success(ProjectProfile(project_id:, title:, summary:))
}

/// Encode a `ProjectPlan` (the project's current plan fact) as a JSON object.
pub fn encode_project_plan(plan: ProjectPlan) -> Json {
  let ProjectPlan(project_id:, budget:, target_completion:) = plan
  json.object([
    #("project_id", json.int(project_id)),
    #("budget", json.float(budget)),
    #("target_completion", wire.encode_date(target_completion)),
  ])
}

/// Decode a `ProjectPlan` from a JSON object.
pub fn project_plan_decoder() -> Decoder(ProjectPlan) {
  use project_id <- decode.field("project_id", decode.int)
  use budget <- decode.field("budget", wire.lenient_float_decoder())
  use target_completion <- decode.field(
    "target_completion",
    wire.date_decoder(),
  )
  decode.success(ProjectPlan(project_id:, budget:, target_completion:))
}

/// Encode a `ProjectListRow` (one projects-list row) as a JSON object.
pub fn encode_project_list_row(project: ProjectListRow) -> Json {
  let ProjectListRow(
    project_id:,
    title:,
    client:,
    budget:,
    target_completion:,
    team_size:,
    active:,
  ) = project
  json.object([
    #("project_id", json.int(project_id)),
    #("title", json.string(title)),
    #("client", json.string(client)),
    #("budget", json.float(budget)),
    #("target_completion", wire.encode_date(target_completion)),
    #("team_size", json.int(team_size)),
    #("active", json.bool(active)),
  ])
}

/// Decode a `ProjectListRow` from a JSON object.
pub fn project_list_row_decoder() -> Decoder(ProjectListRow) {
  use project_id <- decode.field("project_id", decode.int)
  use title <- decode.field("title", decode.string)
  use client <- decode.field("client", decode.string)
  use budget <- decode.field("budget", wire.lenient_float_decoder())
  use target_completion <- decode.field(
    "target_completion",
    wire.date_decoder(),
  )
  use team_size <- decode.field("team_size", decode.int)
  use active <- decode.field("active", decode.bool)
  decode.success(ProjectListRow(
    project_id:,
    title:,
    client:,
    budget:,
    target_completion:,
    team_size:,
    active:,
  ))
}

/// Encode a `ProjectList` (the projects list for a date) to JSON.
pub fn encode_project_list(list: ProjectList) -> Json {
  let ProjectList(date:, projects:) = list
  json.object([
    #("date", wire.encode_date(date)),
    #("projects", json.array(projects, encode_project_list_row)),
  ])
}

/// Decode a `ProjectList` from JSON.
pub fn project_list_decoder() -> Decoder(ProjectList) {
  use date <- decode.field("date", wire.date_decoder())
  use projects <- decode.field(
    "projects",
    decode.list(project_list_row_decoder()),
  )
  decode.success(ProjectList(date:, projects:))
}

/// Encode a `TeamMember` (one project-team member) as a JSON object.
pub fn encode_team_member(member: TeamMember) -> Json {
  let TeamMember(engineer_id:, name:, level:, fraction:, day_rate:) = member
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("level", json.int(level)),
    #("fraction", json.float(fraction)),
    #("day_rate", json.float(day_rate)),
  ])
}

/// Decode a `TeamMember` from a JSON object.
pub fn team_member_decoder() -> Decoder(TeamMember) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use level <- decode.field("level", decode.int)
  use fraction <- decode.field("fraction", wire.lenient_float_decoder())
  use day_rate <- decode.field("day_rate", wire.lenient_float_decoder())
  decode.success(TeamMember(engineer_id:, name:, level:, fraction:, day_rate:))
}

/// Encode a `ProjectRequirement` (one capacity-requirement line) as a JSON object.
pub fn encode_project_requirement(requirement: ProjectRequirement) -> Json {
  let ProjectRequirement(project_id:, level:, quantity:, valid_from:, valid_to:) =
    requirement
  json.object([
    #("project_id", json.int(project_id)),
    #("level", json.int(level)),
    #("quantity", json.float(quantity)),
    #("valid_from", wire.encode_date(valid_from)),
    #("valid_to", wire.encode_date(valid_to)),
  ])
}

/// Decode a `ProjectRequirement` from a JSON object.
pub fn project_requirement_decoder() -> Decoder(ProjectRequirement) {
  use project_id <- decode.field("project_id", decode.int)
  use level <- decode.field("level", decode.int)
  use quantity <- decode.field("quantity", wire.lenient_float_decoder())
  use valid_from <- decode.field("valid_from", wire.date_decoder())
  use valid_to <- decode.field("valid_to", wire.date_decoder())
  decode.success(ProjectRequirement(
    project_id:,
    level:,
    quantity:,
    valid_from:,
    valid_to:,
  ))
}

/// Encode a `ProjectDetail` (the project-detail read model) to JSON.
pub fn encode_project_detail(detail: ProjectDetail) -> Json {
  let ProjectDetail(
    profile:,
    client:,
    plan:,
    valid_from:,
    valid_to:,
    active:,
    team:,
    requirements:,
    invoices:,
  ) = detail
  json.object([
    #("profile", encode_project_profile(profile)),
    #("client", json.string(client)),
    #("plan", encode_project_plan(plan)),
    #("valid_from", wire.encode_date(valid_from)),
    #("valid_to", wire.encode_date(valid_to)),
    #("active", json.bool(active)),
    #("team", json.array(team, encode_team_member)),
    #("requirements", json.array(requirements, encode_project_requirement)),
    #("invoices", json.array(invoices, invoice_view.encode_invoice)),
  ])
}

/// Decode a `ProjectDetail` from JSON.
pub fn project_detail_decoder() -> Decoder(ProjectDetail) {
  use profile <- decode.field("profile", project_profile_decoder())
  use client <- decode.field("client", decode.string)
  use plan <- decode.field("plan", project_plan_decoder())
  use valid_from <- decode.field("valid_from", wire.date_decoder())
  use valid_to <- decode.field("valid_to", wire.date_decoder())
  use active <- decode.field("active", decode.bool)
  use team <- decode.field("team", decode.list(team_member_decoder()))
  use requirements <- decode.field(
    "requirements",
    decode.list(project_requirement_decoder()),
  )
  use invoices <- decode.field(
    "invoices",
    decode.list(invoice_view.invoice_decoder()),
  )
  decode.success(ProjectDetail(
    profile:,
    client:,
    plan:,
    valid_from:,
    valid_to:,
    active:,
    team:,
    requirements:,
    invoices:,
  ))
}
