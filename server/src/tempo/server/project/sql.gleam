//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/project/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog

/// project_create.sql — insert the project identity (ID-ONLY anchor) at a reserved id.
///
/// Step 1 of start_project. The id is reserved up-front from project_id_seq
/// (project_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
/// The run/profile/plan are separate facts recorded alongside.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_create(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_create.sql — insert the project identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of start_project. The id is reserved up-front from project_id_seq
-- (project_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
-- The run/profile/plan are separate facts recorded alongside.
INSERT INTO project (id) VALUES ($1);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_invoices` query
/// defined in `./src/tempo/server/project/sql/project_invoices.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectInvoicesRow {
  ProjectInvoicesRow(
    id: Int,
    project: String,
    client: String,
    billing_from: Date,
    billing_to: Date,
    status: String,
    total: Float,
    issued_at: Option(Date),
    paid_at: Option(Date),
  )
}

/// project_invoices.sql — one project's invoices for the detail read model (GET
/// /api/projects/:id; FR-CP7). Params: $1 = project_id, $2 = as-of.
///
/// invoice_list scoped to a single project: same columns and shape as invoice_list
/// (so it decodes through the reused Invoice codec) but filtered to
/// invoice_subject.project_id = $1. The status shown is the row covering $2 via `@>`,
/// so scrubbing the rail back shows a draft before its issue date (FR-F4); an invoice
/// with no status covering $2 is dropped (the status JOIN is INNER). The project name
/// is THIS project's title; the client name is reached through the project's run to
/// its contract's client (correlated LIMIT-1 so a multi-period project does not
/// multiply rows). Total is coalesce(Σ amount, 0) over the snapshot lines. Ordered by
/// billing month then id.
///
/// issued_at/paid_at. The lower bound of the issued/paid status span — the day the
/// issue_invoice/pay_invoice transition occurred — or NULL when that transition has
/// not happened as-of $2. The `?` alias suffix forces Squirrel to generate
/// Option(Date) rather than inferring non-null off the all-issued/all-paid seed.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_invoices(
  db: pog.Connection,
  invoice_subject_project_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(ProjectInvoicesRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use project <- decode.field(1, decode.string)
    use client <- decode.field(2, decode.string)
    use billing_from <- decode.field(3, pog.calendar_date_decoder())
    use billing_to <- decode.field(4, pog.calendar_date_decoder())
    use status <- decode.field(5, decode.string)
    use total <- decode.field(6, pog.numeric_decoder())
    use issued_at <- decode.field(
      7,
      decode.optional(pog.calendar_date_decoder()),
    )
    use paid_at <- decode.field(8, decode.optional(pog.calendar_date_decoder()))
    decode.success(ProjectInvoicesRow(
      id:,
      project:,
      client:,
      billing_from:,
      billing_to:,
      status:,
      total:,
      issued_at:,
      paid_at:,
    ))
  }

  "-- project_invoices.sql — one project's invoices for the detail read model (GET
-- /api/projects/:id; FR-CP7). Params: $1 = project_id, $2 = as-of.
--
-- invoice_list scoped to a single project: same columns and shape as invoice_list
-- (so it decodes through the reused Invoice codec) but filtered to
-- invoice_subject.project_id = $1. The status shown is the row covering $2 via `@>`,
-- so scrubbing the rail back shows a draft before its issue date (FR-F4); an invoice
-- with no status covering $2 is dropped (the status JOIN is INNER). The project name
-- is THIS project's title; the client name is reached through the project's run to
-- its contract's client (correlated LIMIT-1 so a multi-period project does not
-- multiply rows). Total is coalesce(Σ amount, 0) over the snapshot lines. Ordered by
-- billing month then id.
--
-- issued_at/paid_at. The lower bound of the issued/paid status span — the day the
-- issue_invoice/pay_invoice transition occurred — or NULL when that transition has
-- not happened as-of $2. The `?` alias suffix forces Squirrel to generate
-- Option(Date) rather than inferring non-null off the all-issued/all-paid seed.
SELECT
  invoice.id,
  coalesce((
    SELECT project.title FROM project_current project
     WHERE project.id = invoice_subject.project_id
     LIMIT 1
  ), '') AS project,
  coalesce((
    SELECT client.name
      FROM project_run
      JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
      JOIN client_current client ON client.id = contract_terms.client_id
     WHERE project_run.project_id = invoice_subject.project_id
     LIMIT 1
  ), '') AS client,
  lower(invoice_subject.billing_period) AS billing_from,
  upper(invoice_subject.billing_period) AS billing_to,
  invoice_status.status,
  coalesce((
    SELECT sum(invoice_line.amount)
      FROM invoice_line
     WHERE invoice_line.invoice_id = invoice.id
  ), 0)::numeric AS total,
  (
    SELECT lower(issued.status_during)
      FROM invoice_status issued
     WHERE issued.invoice_id = invoice.id
       AND issued.status = 'issued'
       AND lower(issued.status_during) <= $2::date
     LIMIT 1
  ) AS \"issued_at?\",
  (
    SELECT lower(paid.status_during)
      FROM invoice_status paid
     WHERE paid.invoice_id = invoice.id
       AND paid.status = 'paid'
       AND lower(paid.status_during) <= $2::date
     LIMIT 1
  ) AS \"paid_at?\"
FROM invoice
JOIN invoice_subject ON invoice_subject.invoice_id = invoice.id
                    AND invoice_subject.project_id = $1
JOIN invoice_status ON invoice_status.invoice_id = invoice.id
                   AND invoice_status.status_during @> $2::date
ORDER BY lower(invoice_subject.billing_period), invoice.id;
"
  |> pog.query
  |> pog.parameter(pog.int(invoice_subject_project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_list` query
/// defined in `./src/tempo/server/project/sql/project_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
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

/// project_list.sql — the projects-directory read model (GET /api/projects?as_of=$1;
/// FR-CP5). One row per project that has a run: title, owning client, budget, target,
/// the team size on $1, and whether the run covers $1 (active). Param: $1 = as-of.
///
/// project_run anchors the project (every listed project has a run). A project may
/// have several historical runs, so DISTINCT ON (project_id) keeps the run covering
/// $1 (sorted first), falling back to the latest-started run for an ended project so
/// it still lists with active=false — a started project is marked active/ended, never
/// hidden. A run that has NOT started by $1 is excluded (lower(active_during) <= $1),
/// so a project dormant before its start is absent, not rendered as 'ended'.
/// The title comes from project_current, the client name through the run's contract
/// to client_current, and budget/target from a LATERAL latest-read project_plan
/// (DISTINCT ON by start desc, like project_plan_current; coalesced for a planless
/// project). team_size is a correlated count of DISTINCT engineers whose allocation
/// to this project covers $1 (0 for a dormant project). The inner DISTINCT ON picks
/// one run per project; the outer query orders the directory by title.
///
/// Keyset pagination (#12). Stable total order is (title, project_id) — the display
/// order plus the unique id tiebreaker. The cursor names the last row returned:
/// $2 = its title, $3 = its id; a row is on the NEXT page when (title, id) sorts
/// strictly after it. The first page passes the sentinel ('', 0), which precedes
/// every real row. $4 = limit; the caller fetches limit+1 to detect a further page.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_list(
  db: pog.Connection,
  arg_1: Date,
  arg_2: String,
  arg_3: Int,
  arg_4: Int,
) -> Result(pog.Returned(ProjectListRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use client <- decode.field(2, decode.string)
    use budget <- decode.field(3, pog.numeric_decoder())
    use target_completion <- decode.field(4, pog.calendar_date_decoder())
    use team_size <- decode.field(5, decode.int)
    use active <- decode.field(6, decode.bool)
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

  "-- project_list.sql — the projects-directory read model (GET /api/projects?as_of=$1;
-- FR-CP5). One row per project that has a run: title, owning client, budget, target,
-- the team size on $1, and whether the run covers $1 (active). Param: $1 = as-of.
--
-- project_run anchors the project (every listed project has a run). A project may
-- have several historical runs, so DISTINCT ON (project_id) keeps the run covering
-- $1 (sorted first), falling back to the latest-started run for an ended project so
-- it still lists with active=false — a started project is marked active/ended, never
-- hidden. A run that has NOT started by $1 is excluded (lower(active_during) <= $1),
-- so a project dormant before its start is absent, not rendered as 'ended'.
-- The title comes from project_current, the client name through the run's contract
-- to client_current, and budget/target from a LATERAL latest-read project_plan
-- (DISTINCT ON by start desc, like project_plan_current; coalesced for a planless
-- project). team_size is a correlated count of DISTINCT engineers whose allocation
-- to this project covers $1 (0 for a dormant project). The inner DISTINCT ON picks
-- one run per project; the outer query orders the directory by title.
--
-- Keyset pagination (#12). Stable total order is (title, project_id) — the display
-- order plus the unique id tiebreaker. The cursor names the last row returned:
-- $2 = its title, $3 = its id; a row is on the NEXT page when (title, id) sorts
-- strictly after it. The first page passes the sentinel ('', 0), which precedes
-- every real row. $4 = limit; the caller fetches limit+1 to detect a further page.
SELECT project_id, title, client, budget, target_completion, team_size, active
FROM (
SELECT project_id, title, client, budget, target_completion, team_size, active
FROM (
  SELECT DISTINCT ON (project_run.project_id)
    project_run.project_id,
    coalesce(project_current.title, '') AS title,
    coalesce(client_current.name, '') AS client,
    coalesce(plan.budget, 0)::numeric AS budget,
    coalesce(plan.target_completion, upper(project_run.active_during)) AS target_completion,
    (
      SELECT count(DISTINCT allocation.engineer_id)
        FROM allocation
       WHERE allocation.project_id = project_run.project_id
         AND allocation.allocated_during @> $1::date
    )::int AS team_size,
    (project_run.active_during @> $1::date) AS active
  FROM project_run
  JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
  JOIN client_current ON client_current.id = contract_terms.client_id
  JOIN project_current ON project_current.id = project_run.project_id
  LEFT JOIN LATERAL (
    SELECT project_plan.budget, project_plan.target_completion
      FROM project_plan
     WHERE project_plan.project_id = project_run.project_id
     ORDER BY lower(project_plan.planned_during) DESC
     LIMIT 1
  ) plan ON true
  WHERE lower(project_run.active_during) <= $1::date
  ORDER BY project_run.project_id,
           (project_run.active_during @> $1::date) DESC,
           lower(project_run.active_during) DESC
) ranked
ORDER BY title
) page
WHERE (page.title, page.project_id) > ($2::text, $3::int)
ORDER BY page.title, page.project_id
LIMIT $4::int;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.int(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_next_id` query
/// defined in `./src/tempo/server/project/sql/project_next_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectNextIdRow {
  ProjectNextIdRow(id: Int)
}

/// project_next_id.sql — reserve the next project id from its sequence.
///
/// Called before start_project records any project fact: the handler threads this id
/// into the Project anchor, its run, profile, and plan in one transaction, so nothing
/// is read back.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_next_id(
  db: pog.Connection,
) -> Result(pog.Returned(ProjectNextIdRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(ProjectNextIdRow(id:))
  }

  "-- project_next_id.sql — reserve the next project id from its sequence.
--
-- Called before start_project records any project fact: the handler threads this id
-- into the Project anchor, its run, profile, and plan in one transaction, so nothing
-- is read back.
SELECT nextval('project_id_seq')::int AS id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_plan_current` query
/// defined in `./src/tempo/server/project/sql/project_plan_current.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectPlanCurrentRow {
  ProjectPlanCurrentRow(project_id: Int, budget: Float, target_completion: Date)
}

/// project_plan_current.sql — a project's CURRENT plan (latest read).
///
/// The most-recently-effective project_plan row for one project: DISTINCT ON ordered
/// by the start of planned_during descending. Append-only + WITHOUT OVERLAPS means
/// the row with the greatest start is the one whose [effective, NULL) span is in
/// force. Scalar columns only — planned_during bounds are not exposed (the read
/// record is scalar-only). $1 = project_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_plan_current(
  db: pog.Connection,
  project_id: Int,
) -> Result(pog.Returned(ProjectPlanCurrentRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use budget <- decode.field(1, pog.numeric_decoder())
    use target_completion <- decode.field(2, pog.calendar_date_decoder())
    decode.success(ProjectPlanCurrentRow(
      project_id:,
      budget:,
      target_completion:,
    ))
  }

  "-- project_plan_current.sql — a project's CURRENT plan (latest read).
--
-- The most-recently-effective project_plan row for one project: DISTINCT ON ordered
-- by the start of planned_during descending. Append-only + WITHOUT OVERLAPS means
-- the row with the greatest start is the one whose [effective, NULL) span is in
-- force. Scalar columns only — planned_during bounds are not exposed (the read
-- record is scalar-only). $1 = project_id.
SELECT DISTINCT ON (project_id)
  project_id,
  budget,
  target_completion
FROM project_plan
WHERE project_id = $1
ORDER BY project_id, lower(planned_during) DESC;
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_plan_upsert.sql — record a project plan from $2 onward (delete-then-insert
/// semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
/// rows that start at or after $2, then inserts [$2, NULL) with the new values. Passing NULL
/// as the upper bound asserts the new plan holds to infinity, superseding any scheduled
/// future versions. $1 = project_id, $2 = effective, $3 = budget, $4 = target_completion,
/// $5 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_plan_upsert(
  db: pog.Connection,
  project_id: Int,
  arg_2: Date,
  arg_3: Float,
  arg_4: Date,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_plan_upsert.sql — record a project plan from $2 onward (delete-then-insert
-- semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
-- rows that start at or after $2, then inserts [$2, NULL) with the new values. Passing NULL
-- as the upper bound asserts the new plan holds to infinity, superseding any scheduled
-- future versions. $1 = project_id, $2 = effective, $3 = budget, $4 = target_completion,
-- $5 = audit_id.
WITH deleted AS (
  DELETE FROM project_plan
     FOR PORTION OF planned_during FROM $2::date TO NULL
   WHERE project_id = $1
)
INSERT INTO project_plan
  (project_id, budget, target_completion, planned_during, audit_id)
VALUES ($1, $3, $4::date, daterange($2::date, NULL, '[)'), $5);
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.float(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_profile_upsert.sql — record a project profile from $2 onward (delete-then-insert
/// semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
/// rows that start at or after $2, then inserts [$2, NULL) with the new values. Passing NULL
/// as the upper bound asserts the new profile holds to infinity, superseding any scheduled
/// future versions. $1 = project_id, $2 = effective, $3 = title, $4 = summary, $5 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_profile_upsert(
  db: pog.Connection,
  project_id: Int,
  arg_2: Date,
  arg_3: String,
  arg_4: String,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_profile_upsert.sql — record a project profile from $2 onward (delete-then-insert
-- semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
-- rows that start at or after $2, then inserts [$2, NULL) with the new values. Passing NULL
-- as the upper bound asserts the new profile holds to infinity, superseding any scheduled
-- future versions. $1 = project_id, $2 = effective, $3 = title, $4 = summary, $5 = audit_id.
WITH deleted AS (
  DELETE FROM project_profile
     FOR PORTION OF recorded_during FROM $2::date TO NULL
   WHERE project_id = $1
)
INSERT INTO project_profile
  (project_id, title, summary, recorded_during, audit_id)
VALUES ($1, $3, $4, daterange($2::date, NULL, '[)'), $5);
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_requirement_clear.sql — step 1 of the FOR-PORTION-OF set. DELETE FOR
/// PORTION OF carves the target window [$2, $3) out of whatever (project, level) rows
/// cover any part of it, re-inserting the before/after remainders at their original
/// quantity (keeping their original audit_id). Step 2 (project_requirement_set.sql)
/// then inserts the new line over the now-vacant window.
///
/// `ON CONFLICT` cannot target the WITHOUT OVERLAPS PK (a GiST exclusion constraint),
/// so the set is delete-then-insert run in ONE transaction by the handler. A first
/// set over a vacant window deletes 0 rows (a harmless no-op); never branch on the
/// affected-row count. $1 = project_id, $2 = from, $3 = to, $4 = level.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_requirement_clear(
  db: pog.Connection,
  project_id: Int,
  arg_2: Date,
  arg_3: Date,
  arg_4: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_requirement_clear.sql — step 1 of the FOR-PORTION-OF set. DELETE FOR
-- PORTION OF carves the target window [$2, $3) out of whatever (project, level) rows
-- cover any part of it, re-inserting the before/after remainders at their original
-- quantity (keeping their original audit_id). Step 2 (project_requirement_set.sql)
-- then inserts the new line over the now-vacant window.
--
-- `ON CONFLICT` cannot target the WITHOUT OVERLAPS PK (a GiST exclusion constraint),
-- so the set is delete-then-insert run in ONE transaction by the handler. A first
-- set over a vacant window deletes 0 rows (a harmless no-op); never branch on the
-- affected-row count. $1 = project_id, $2 = from, $3 = to, $4 = level.
DELETE FROM project_requirement
   FOR PORTION OF required_during FROM $2::date TO $3::date
 WHERE project_id = $1 AND level = $4;
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_requirement_set.sql — step 2 of the FOR-PORTION-OF set: insert the demand
/// line over the window [$2, $3) that project_requirement_clear.sql just vacated. The
/// PERIOD-FK `requirement_within_project` rejects (→ ContainmentViolated) a window not
/// wholly contained by the project's run; the level/quantity CHECKs reject out-of-range
/// values (→ InvalidValue). $1 = project_id, $2 = from, $3 = to, $4 = level,
/// $5 = quantity, $6 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_requirement_set(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
  arg_3: Date,
  arg_4: Int,
  arg_5: Float,
  arg_6: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_requirement_set.sql — step 2 of the FOR-PORTION-OF set: insert the demand
-- line over the window [$2, $3) that project_requirement_clear.sql just vacated. The
-- PERIOD-FK `requirement_within_project` rejects (→ ContainmentViolated) a window not
-- wholly contained by the project's run; the level/quantity CHECKs reject out-of-range
-- values (→ InvalidValue). $1 = project_id, $2 = from, $3 = to, $4 = level,
-- $5 = quantity, $6 = audit_id.
INSERT INTO project_requirement
  (project_id, level, quantity, required_during, audit_id)
VALUES
  ($1, $4, $5, daterange($2::date, $3::date, '[)'), $6);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.parameter(pog.float(arg_5))
  |> pog.parameter(pog.int(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_requirements` query
/// defined in `./src/tempo/server/project/sql/project_requirements.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectRequirementsRow {
  ProjectRequirementsRow(
    project_id: Int,
    level: Int,
    quantity: Float,
    valid_from: Date,
    valid_to: Date,
  )
}

/// project_requirements.sql — one project's capacity-requirement lines (demand) for
/// the project-detail read model (GET /api/projects/:id; FR-CP). Param: $1 =
/// project_id.
///
/// Every requirement period-row for the project. Range columns are decomposed to
/// plain dates: lower(required_during) AS valid_from, upper(required_during) AS
/// valid_to (non-null for every row). One line per (project, level) over
/// non-overlapping periods. The detail is as-of-independent — the whole demand
/// timeline is returned regardless of the slider date — so unlike team/invoices this
/// read takes no as-of. Ordered by level then valid_from for a stable list.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_requirements(
  db: pog.Connection,
  project_requirement_project_id: Int,
) -> Result(pog.Returned(ProjectRequirementsRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use level <- decode.field(1, decode.int)
    use quantity <- decode.field(2, pog.numeric_decoder())
    use valid_from <- decode.field(3, pog.calendar_date_decoder())
    use valid_to <- decode.field(4, pog.calendar_date_decoder())
    decode.success(ProjectRequirementsRow(
      project_id:,
      level:,
      quantity:,
      valid_from:,
      valid_to:,
    ))
  }

  "-- project_requirements.sql — one project's capacity-requirement lines (demand) for
-- the project-detail read model (GET /api/projects/:id; FR-CP). Param: $1 =
-- project_id.
--
-- Every requirement period-row for the project. Range columns are decomposed to
-- plain dates: lower(required_during) AS valid_from, upper(required_during) AS
-- valid_to (non-null for every row). One line per (project, level) over
-- non-overlapping periods. The detail is as-of-independent — the whole demand
-- timeline is returned regardless of the slider date — so unlike team/invoices this
-- read takes no as-of. Ordered by level then valid_from for a stable list.
SELECT
  project_requirement.project_id,
  project_requirement.level,
  project_requirement.quantity,
  lower(project_requirement.required_during) AS valid_from,
  upper(project_requirement.required_during) AS valid_to
FROM project_requirement
WHERE project_requirement.project_id = $1
ORDER BY project_requirement.level, lower(project_requirement.required_during);
"
  |> pog.query
  |> pog.parameter(pog.int(project_requirement_project_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_run_during` query
/// defined in `./src/tempo/server/project/sql/project_run_during.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectRunDuringRow {
  ProjectRunDuringRow(project_id: Int, contract_id: Int)
}

/// project_run_during.sql — confirm a project's run (existence/contract window)
/// covers a period; one row per run whose active_during contains [from, to).
/// Selects only NOT-NULL columns so an open-ended run (NULL upper bound) decodes
/// cleanly — the guard cares only that a row exists.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_run_during(
  db: pog.Connection,
  project_id: Int,
  arg_2: Date,
  arg_3: Date,
) -> Result(pog.Returned(ProjectRunDuringRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use contract_id <- decode.field(1, decode.int)
    decode.success(ProjectRunDuringRow(project_id:, contract_id:))
  }

  "-- project_run_during.sql — confirm a project's run (existence/contract window)
-- covers a period; one row per run whose active_during contains [from, to).
-- Selects only NOT-NULL columns so an open-ended run (NULL upper bound) decodes
-- cleanly — the guard cares only that a row exists.
select
	project_id,
	contract_id
from project_run
where project_id = $1
	and (active_during @> daterange($2::date, $3::date, '[)'))
"
  |> pog.query
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// project_run_open.sql — open a project's run (existence/contract window), contained
/// by its contract via project_within_contract. Last param is the audit_id.
/// $1 = project_id, $2 = contract_id, $3 = from, $4 = to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_run_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: Date,
  arg_4: Date,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- project_run_open.sql — open a project's run (existence/contract window), contained
-- by its contract via project_within_contract. Last param is the audit_id.
-- $1 = project_id, $2 = contract_id, $3 = from, $4 = to.
INSERT INTO project_run (project_id, contract_id, active_during, audit_id)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'), $5);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_run_period` query
/// defined in `./src/tempo/server/project/sql/project_run_period.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectRunPeriodRow {
  ProjectRunPeriodRow(
    valid_from: Date,
    valid_to: Date,
    active: Bool,
    client: String,
  )
}

/// project_run_period.sql — one project's run window and owning client for the
/// detail read model (GET /api/projects/:id). Params: $1 = project_id, $2 = as-of
/// (for the active flag only).
///
/// The run is the project's existence/contract window (project_run). Its bounds are
/// decomposed to plain dates: lower(active_during) AS valid_from,
/// upper(active_during) AS valid_to (non-null for every seed run — all bounded at
/// 2027-01-01). `active` is (active_during @> $2): the as-of marks the run
/// active/ended without hiding it. The client name is reached through the run's
/// contract (contract_terms) to the client_current latest-read view; the contract is
/// joined on the same as-of so the name read matches the run window. A project may
/// have multiple historical runs — DISTINCT ON keeps the one whose window covers $2
/// (ordered so a covering run sorts first), falling back to the latest-started run
/// when none covers $2 so the detail page still renders an ended project. No row =>
/// the detail endpoint 404s.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_run_period(
  db: pog.Connection,
  project_run_project_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(ProjectRunPeriodRow), pog.QueryError) {
  let decoder = {
    use valid_from <- decode.field(0, pog.calendar_date_decoder())
    use valid_to <- decode.field(1, pog.calendar_date_decoder())
    use active <- decode.field(2, decode.bool)
    use client <- decode.field(3, decode.string)
    decode.success(ProjectRunPeriodRow(valid_from:, valid_to:, active:, client:))
  }

  "-- project_run_period.sql — one project's run window and owning client for the
-- detail read model (GET /api/projects/:id). Params: $1 = project_id, $2 = as-of
-- (for the active flag only).
--
-- The run is the project's existence/contract window (project_run). Its bounds are
-- decomposed to plain dates: lower(active_during) AS valid_from,
-- upper(active_during) AS valid_to (non-null for every seed run — all bounded at
-- 2027-01-01). `active` is (active_during @> $2): the as-of marks the run
-- active/ended without hiding it. The client name is reached through the run's
-- contract (contract_terms) to the client_current latest-read view; the contract is
-- joined on the same as-of so the name read matches the run window. A project may
-- have multiple historical runs — DISTINCT ON keeps the one whose window covers $2
-- (ordered so a covering run sorts first), falling back to the latest-started run
-- when none covers $2 so the detail page still renders an ended project. No row =>
-- the detail endpoint 404s.
SELECT DISTINCT ON (project_run.project_id)
  lower(project_run.active_during) AS valid_from,
  upper(project_run.active_during) AS valid_to,
  (project_run.active_during @> $2::date) AS active,
  coalesce(client_current.name, '') AS client
FROM project_run
JOIN contract_terms ON contract_terms.contract_id = project_run.contract_id
JOIN client_current ON client_current.id = contract_terms.client_id
WHERE project_run.project_id = $1
ORDER BY project_run.project_id,
         (project_run.active_during @> $2::date) DESC,
         lower(project_run.active_during) DESC;
"
  |> pog.query
  |> pog.parameter(pog.int(project_run_project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `project_team` query
/// defined in `./src/tempo/server/project/sql/project_team.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ProjectTeamRow {
  ProjectTeamRow(
    engineer_id: Int,
    name: String,
    level: Int,
    fraction: Float,
    day_rate: Float,
  )
}

/// project_team.sql — the engineers engaged on one project as of $2, for the project
/// detail team card (GET /api/projects/:id; FR-CP6). Params: $1 = project_id,
/// $2 = as-of.
///
/// The board_engaged temporal join scoped to a single project: employment(@>$2)
/// anchors the employed engineer, engineer_role(@>$2) gives the as-of level,
/// rate_card(level, @>$2) the charge rate (the two-hop role × rate_card join), and
/// allocation(@>$2) ties the engineer to THIS project on the date. All INNER joins,
/// so every column is non-null. Unlike the board, the team card carries engineer_id
/// (so a card can click through to /people/:id) and omits the project/client/period
/// columns the board needs. An engineer covered by a leave fact on $2 is suppressed
/// (NOT EXISTS) exactly as on the board — the team is who is actually working the
/// project on the date. Ordered by name for a stable card list.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn project_team(
  db: pog.Connection,
  allocation_project_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(ProjectTeamRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use level <- decode.field(2, decode.int)
    use fraction <- decode.field(3, pog.numeric_decoder())
    use day_rate <- decode.field(4, pog.numeric_decoder())
    decode.success(ProjectTeamRow(
      engineer_id:,
      name:,
      level:,
      fraction:,
      day_rate:,
    ))
  }

  "-- project_team.sql — the engineers engaged on one project as of $2, for the project
-- detail team card (GET /api/projects/:id; FR-CP6). Params: $1 = project_id,
-- $2 = as-of.
--
-- The board_engaged temporal join scoped to a single project: employment(@>$2)
-- anchors the employed engineer, engineer_role(@>$2) gives the as-of level,
-- rate_card(level, @>$2) the charge rate (the two-hop role × rate_card join), and
-- allocation(@>$2) ties the engineer to THIS project on the date. All INNER joins,
-- so every column is non-null. Unlike the board, the team card carries engineer_id
-- (so a card can click through to /people/:id) and omits the project/client/period
-- columns the board needs. An engineer covered by a leave fact on $2 is suppressed
-- (NOT EXISTS) exactly as on the board — the team is who is actually working the
-- project on the date. Ordered by name for a stable card list.
SELECT
  engineer.id AS engineer_id,
  coalesce(engineer_current.name, '') AS name,
  engineer_role.level,
  allocation.fraction,
  rate_card.day_rate
FROM employment
JOIN engineer ON engineer.id = employment.engineer_id
JOIN engineer_current ON engineer_current.id = engineer.id
JOIN engineer_role ON engineer_role.engineer_id = engineer.id
                  AND engineer_role.held_during @> $2::date
JOIN rate_card ON rate_card.level = engineer_role.level
              AND rate_card.effective_during @> $2::date
JOIN allocation ON allocation.engineer_id = engineer.id
               AND allocation.project_id = $1
               AND allocation.allocated_during @> $2::date
WHERE employment.employed_during @> $2::date
  AND NOT EXISTS (
    SELECT 1 FROM leave
     WHERE leave.engineer_id = engineer.id
       AND leave.on_leave_during @> $2::date
  )
ORDER BY name;
"
  |> pog.query
  |> pog.parameter(pog.int(allocation_project_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
