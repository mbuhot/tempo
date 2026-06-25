//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/client/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `client_contracts` query
/// defined in `./src/tempo/server/client/sql/client_contracts.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ClientContractsRow {
  ClientContractsRow(
    contract_id: Int,
    valid_from: Date,
    valid_to: Date,
    active: Bool,
  )
}

/// client_contracts.sql — one client's contract terms for the detail read model
/// (GET /api/clients/:id; the ContractRow list). Params: $1 = client_id,
/// $2 = as-of (for the active flag only).
///
/// Every contract_terms period-row for the client, decomposed to plain dates:
/// contract_id, lower(term) AS valid_from, upper(term) AS valid_to (non-null for
/// every seed row — all bounded at 2027-01-01). `active` is (term @> $2): the as-of
/// marks each contract active/ended per FR-CP1 without hiding it, so the whole list
/// is returned regardless of $2. Ordered oldest-first then by contract_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn client_contracts(
  db: pog.Connection,
  contract_terms_client_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(ClientContractsRow), pog.QueryError) {
  let decoder = {
    use contract_id <- decode.field(0, decode.int)
    use valid_from <- decode.field(1, pog.calendar_date_decoder())
    use valid_to <- decode.field(2, pog.calendar_date_decoder())
    use active <- decode.field(3, decode.bool)
    decode.success(ClientContractsRow(
      contract_id:,
      valid_from:,
      valid_to:,
      active:,
    ))
  }

  "-- client_contracts.sql — one client's contract terms for the detail read model
-- (GET /api/clients/:id; the ContractRow list). Params: $1 = client_id,
-- $2 = as-of (for the active flag only).
--
-- Every contract_terms period-row for the client, decomposed to plain dates:
-- contract_id, lower(term) AS valid_from, upper(term) AS valid_to (non-null for
-- every seed row — all bounded at 2027-01-01). `active` is (term @> $2): the as-of
-- marks each contract active/ended per FR-CP1 without hiding it, so the whole list
-- is returned regardless of $2. Ordered oldest-first then by contract_id.
SELECT
  contract_terms.contract_id,
  lower(contract_terms.term) AS valid_from,
  upper(contract_terms.term) AS valid_to,
  (contract_terms.term @> $2::date) AS active
FROM contract_terms
WHERE contract_terms.client_id = $1
ORDER BY lower(contract_terms.term), contract_terms.contract_id;
"
  |> pog.query
  |> pog.parameter(pog.int(contract_terms_client_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `client_current` query
/// defined in `./src/tempo/server/client/sql/client_current.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ClientCurrentRow {
  ClientCurrentRow(id: Option(Int), name: Option(String))
}

/// Runs the `client_current` query
/// defined in `./src/tempo/server/client/sql/client_current.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn client_current(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(ClientCurrentRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.optional(decode.int))
    use name <- decode.field(1, decode.optional(decode.string))
    decode.success(ClientCurrentRow(id:, name:))
  }

  "SELECT id::integer, name::text FROM client_current WHERE id = $1::integer
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `client_list` query
/// defined in `./src/tempo/server/client/sql/client_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ClientListRow {
  ClientListRow(
    client_id: Int,
    name: String,
    since: Option(Date),
    project_count: Int,
    active: Bool,
  )
}

/// client_list.sql — the clients-directory read model (GET /api/clients?as_of=$1;
/// mirrors project_list's as-of existence). One row per client that has COME INTO
/// EXISTENCE by $1 — i.e. has a contract whose term STARTS on or before $1: name, the
/// earliest contract start (since), the count of distinct projects ever run for the
/// client, and whether any contract covers $1 (active). Param: $1 = the as-of date.
///
/// EXISTENCE. A client whose first contract starts AFTER $1 is absent, not rendered as
/// 'ended' (the WHERE EXISTS lower(term) <= $1) — the timeline-scrub mirror of
/// project_list (#19). A client that HAS started but whose contracts have all ended by
/// $1 still lists, with active=false → the 'ended' pill, which is now shown only for a
/// genuinely-ended client.
///
/// name from the client_current latest-read view (INNER join — every seeded client has
/// a profile). `since` is min(lower(term)) over the client's contracts (always <= $1
/// for a listed client). The `"since?"` alias forces the generated column to
/// Option(Date) (the schema does not guarantee >=1 contract), matching the shared
/// ClientListRow.since. `active` is a correlated bool_or(term @> $1) coalesced to
/// false. The project count is a correlated count of distinct project ids reachable
/// through the client's contracts' runs. Ordered by name for a stable directory.
///
/// Keyset pagination (#12). Stable total order is (name, client_id) — the display
/// order plus the unique id tiebreaker. The cursor names the last row returned:
/// $2 = its name, $3 = its id; a row is on the NEXT page when (name, id) sorts
/// strictly after it. The first page passes the sentinel ('', 0), which precedes
/// every real row. $4 = limit; the caller fetches limit+1 to detect a further page.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn client_list(
  db: pog.Connection,
  arg_1: Date,
  arg_2: String,
  arg_3: Int,
  arg_4: Int,
) -> Result(pog.Returned(ClientListRow), pog.QueryError) {
  let decoder = {
    use client_id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use since <- decode.field(2, decode.optional(pog.calendar_date_decoder()))
    use project_count <- decode.field(3, decode.int)
    use active <- decode.field(4, decode.bool)
    decode.success(ClientListRow(
      client_id:,
      name:,
      since:,
      project_count:,
      active:,
    ))
  }

  "-- client_list.sql — the clients-directory read model (GET /api/clients?as_of=$1;
-- mirrors project_list's as-of existence). One row per client that has COME INTO
-- EXISTENCE by $1 — i.e. has a contract whose term STARTS on or before $1: name, the
-- earliest contract start (since), the count of distinct projects ever run for the
-- client, and whether any contract covers $1 (active). Param: $1 = the as-of date.
--
-- EXISTENCE. A client whose first contract starts AFTER $1 is absent, not rendered as
-- 'ended' (the WHERE EXISTS lower(term) <= $1) — the timeline-scrub mirror of
-- project_list (#19). A client that HAS started but whose contracts have all ended by
-- $1 still lists, with active=false → the 'ended' pill, which is now shown only for a
-- genuinely-ended client.
--
-- name from the client_current latest-read view (INNER join — every seeded client has
-- a profile). `since` is min(lower(term)) over the client's contracts (always <= $1
-- for a listed client). The `\"since?\"` alias forces the generated column to
-- Option(Date) (the schema does not guarantee >=1 contract), matching the shared
-- ClientListRow.since. `active` is a correlated bool_or(term @> $1) coalesced to
-- false. The project count is a correlated count of distinct project ids reachable
-- through the client's contracts' runs. Ordered by name for a stable directory.
--
-- Keyset pagination (#12). Stable total order is (name, client_id) — the display
-- order plus the unique id tiebreaker. The cursor names the last row returned:
-- $2 = its name, $3 = its id; a row is on the NEXT page when (name, id) sorts
-- strictly after it. The first page passes the sentinel ('', 0), which precedes
-- every real row. $4 = limit; the caller fetches limit+1 to detect a further page.
SELECT * FROM (
SELECT
  client.id AS client_id,
  coalesce(client_current.name, '') AS name,
  (
    SELECT min(lower(contract_terms.term))
      FROM contract_terms
     WHERE contract_terms.client_id = client.id
  ) AS \"since?\",
  (
    SELECT count(DISTINCT project_run.project_id)
      FROM contract_terms
      JOIN project_run ON project_run.contract_id = contract_terms.contract_id
     WHERE contract_terms.client_id = client.id
  )::int AS project_count,
  coalesce((
    SELECT bool_or(contract_terms.term @> $1::date)
      FROM contract_terms
     WHERE contract_terms.client_id = client.id
  ), false) AS active
FROM client
JOIN client_current ON client_current.id = client.id
WHERE EXISTS (
  SELECT 1
    FROM contract_terms
   WHERE contract_terms.client_id = client.id
     AND lower(contract_terms.term) <= $1::date
)
) page
WHERE (page.name, page.client_id) > ($2::text, $3::int)
ORDER BY page.name, page.client_id
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

/// client_profile_upsert.sql — record a client profile from $2 onward (delete-then-insert
/// semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
/// rows that start at or after $2, then inserts [$2, NULL) with the new name. Passing NULL
/// as the upper bound asserts the new name holds to infinity, superseding any scheduled
/// future versions. $1 = client_id, $2 = effective, $3 = name, $4 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn client_profile_upsert(
  db: pog.Connection,
  client_id: Int,
  arg_2: Date,
  arg_3: String,
  arg_4: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- client_profile_upsert.sql — record a client profile from $2 onward (delete-then-insert
-- semantics). The temporal DELETE clips the row covering $2 to [start, $2) and removes any
-- rows that start at or after $2, then inserts [$2, NULL) with the new name. Passing NULL
-- as the upper bound asserts the new name holds to infinity, superseding any scheduled
-- future versions. $1 = client_id, $2 = effective, $3 = name, $4 = audit_id.
WITH deleted AS (
  DELETE FROM client_profile
     FOR PORTION OF recorded_during FROM $2::date TO NULL
   WHERE client_id = $1
)
INSERT INTO client_profile
  (client_id, name, recorded_during, audit_id)
VALUES ($1, $3, daterange($2::date, NULL, '[)'), $4);
"
  |> pog.query
  |> pog.parameter(pog.int(client_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `client_projects` query
/// defined in `./src/tempo/server/client/sql/client_projects.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ClientProjectsRow {
  ClientProjectsRow(
    project_id: Int,
    title: String,
    budget: Float,
    target_completion: Date,
    valid_from: Date,
    valid_to: Date,
    active: Bool,
  )
}

/// client_projects.sql — one client's projects for the detail read model (GET
/// /api/clients/:id; the ClientProjectRow list; FR-CP1). Params: $1 = client_id,
/// $2 = as-of (for the active flag only).
///
/// A multi-hop temporal join from the client's contracts out to its projects:
/// contract_terms (the client's contracts) → project_run (each contract's project
/// runs) → project_current for the title and a LATERAL latest-read project_plan for
/// the budget/target. The run window is decomposed to plain dates: lower/upper
/// active_during AS valid_from/valid_to (non-null for every seed run, bounded at
/// 2027-01-01). `active` is (active_during @> $2) — the as-of marks each project
/// active/ended without hiding it, so the whole list is returned regardless of $2.
/// The plan is the most-recently-effective project_plan row (DISTINCT ON by start
/// desc, like project_plan_current) so budget/target are scalar; a project with no
/// plan yet coalesces budget to 0 and falls back to the run end for target. Ordered
/// by run start then title.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn client_projects(
  db: pog.Connection,
  contract_terms_client_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(ClientProjectsRow), pog.QueryError) {
  let decoder = {
    use project_id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use budget <- decode.field(2, pog.numeric_decoder())
    use target_completion <- decode.field(3, pog.calendar_date_decoder())
    use valid_from <- decode.field(4, pog.calendar_date_decoder())
    use valid_to <- decode.field(5, pog.calendar_date_decoder())
    use active <- decode.field(6, decode.bool)
    decode.success(ClientProjectsRow(
      project_id:,
      title:,
      budget:,
      target_completion:,
      valid_from:,
      valid_to:,
      active:,
    ))
  }

  "-- client_projects.sql — one client's projects for the detail read model (GET
-- /api/clients/:id; the ClientProjectRow list; FR-CP1). Params: $1 = client_id,
-- $2 = as-of (for the active flag only).
--
-- A multi-hop temporal join from the client's contracts out to its projects:
-- contract_terms (the client's contracts) → project_run (each contract's project
-- runs) → project_current for the title and a LATERAL latest-read project_plan for
-- the budget/target. The run window is decomposed to plain dates: lower/upper
-- active_during AS valid_from/valid_to (non-null for every seed run, bounded at
-- 2027-01-01). `active` is (active_during @> $2) — the as-of marks each project
-- active/ended without hiding it, so the whole list is returned regardless of $2.
-- The plan is the most-recently-effective project_plan row (DISTINCT ON by start
-- desc, like project_plan_current) so budget/target are scalar; a project with no
-- plan yet coalesces budget to 0 and falls back to the run end for target. Ordered
-- by run start then title.
SELECT
  project_run.project_id,
  coalesce(project_current.title, '') AS title,
  coalesce(plan.budget, 0)::numeric AS budget,
  coalesce(plan.target_completion, upper(project_run.active_during)) AS target_completion,
  lower(project_run.active_during) AS valid_from,
  upper(project_run.active_during) AS valid_to,
  (project_run.active_during @> $2::date) AS active
FROM contract_terms
JOIN project_run ON project_run.contract_id = contract_terms.contract_id
JOIN project_current ON project_current.id = project_run.project_id
LEFT JOIN LATERAL (
  SELECT project_plan.budget, project_plan.target_completion
    FROM project_plan
   WHERE project_plan.project_id = project_run.project_id
   ORDER BY lower(project_plan.planned_during) DESC
   LIMIT 1
) plan ON true
WHERE contract_terms.client_id = $1
ORDER BY lower(project_run.active_during), title;
"
  |> pog.query
  |> pog.parameter(pog.int(contract_terms_client_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// contract_create.sql — insert the contract identity (ID-ONLY anchor) at a reserved id.
///
/// Step 1 of sign_contract. The id is reserved up-front from contract_id_seq
/// (contract_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
/// The engagement term lives in a separate contract_terms fact recorded alongside.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn contract_create(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- contract_create.sql — insert the contract identity (ID-ONLY anchor) at a reserved id.
--
-- Step 1 of sign_contract. The id is reserved up-front from contract_id_seq
-- (contract_next_id) and supplied as $1, so this is a plain insert with no RETURNING.
-- The engagement term lives in a separate contract_terms fact recorded alongside.
INSERT INTO contract (id) VALUES ($1);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `contract_next_id` query
/// defined in `./src/tempo/server/client/sql/contract_next_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ContractNextIdRow {
  ContractNextIdRow(id: Int)
}

/// contract_next_id.sql — reserve the next contract id from its sequence.
///
/// Called before sign_contract records any contract fact: the handler threads this id
/// into the Contract anchor and its terms in one transaction, so nothing is read back.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn contract_next_id(
  db: pog.Connection,
) -> Result(pog.Returned(ContractNextIdRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(ContractNextIdRow(id:))
  }

  "-- contract_next_id.sql — reserve the next contract id from its sequence.
--
-- Called before sign_contract records any contract fact: the handler threads this id
-- into the Contract anchor and its terms in one transaction, so nothing is read back.
SELECT nextval('contract_id_seq')::int AS id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// contract_terms_open.sql — open a contract's term (resolving the client by name to
/// its id). Last param is the audit_id. $1 = contract_id, $2 = client name,
/// $3 = from, $4 = to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn contract_terms_open(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: Date,
  arg_4: Date,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- contract_terms_open.sql — open a contract's term (resolving the client by name to
-- its id). Last param is the audit_id. $1 = contract_id, $2 = client name,
-- $3 = from, $4 = to.
INSERT INTO contract_terms (contract_id, client_id, term, audit_id)
VALUES (
  $1,
  (SELECT id FROM client_current WHERE name = $2),
  daterange($3::date, $4::date, '[)'),
  $5
);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
