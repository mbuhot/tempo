//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/roster/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `roster_clients` query
/// defined in `./src/tempo/server/roster/sql/roster_clients.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RosterClientsRow {
  RosterClientsRow(id: Int, name: String)
}

/// roster_clients.sql — every client, by name.
///
/// The client-directory slice the operations console offers as a name <select>
/// (SignContract carries the client by NAME). A client is a durable identity —
/// it has no validity window — so this is NOT date-filtered: every client is
/// always selectable, id + name, ordered by name for a stable dropdown.
///
/// The id comes from the `client` ANCHOR (provably NOT NULL); the NAME, which left
/// the anchor for the edit-grouped client_profile fact, is read through the
/// `client_current` view (latest profile per client). The INNER JOIN means a
/// client with no profile row is omitted (every seeded client has one). coalesce
/// keeps the name column NOT NULL through the view boundary; it is never actually
/// null (the join is on a NOT NULL profile column).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn roster_clients(
  db: pog.Connection,
) -> Result(pog.Returned(RosterClientsRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(RosterClientsRow(id:, name:))
  }

  "-- roster_clients.sql — every client, by name.
--
-- The client-directory slice the operations console offers as a name <select>
-- (SignContract carries the client by NAME). A client is a durable identity —
-- it has no validity window — so this is NOT date-filtered: every client is
-- always selectable, id + name, ordered by name for a stable dropdown.
--
-- The id comes from the `client` ANCHOR (provably NOT NULL); the NAME, which left
-- the anchor for the edit-grouped client_profile fact, is read through the
-- `client_current` view (latest profile per client). The INNER JOIN means a
-- client with no profile row is omitted (every seeded client has one). coalesce
-- keeps the name column NOT NULL through the view boundary; it is never actually
-- null (the join is on a NOT NULL profile column).
SELECT client.id, coalesce(cc.name, '') AS name
FROM client
JOIN client_current cc ON cc.id = client.id
ORDER BY name;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `roster_engineers` query
/// defined in `./src/tempo/server/roster/sql/roster_engineers.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RosterEngineersRow {
  RosterEngineersRow(id: Int, name: String)
}

/// roster_engineers.sql — engineers EMPLOYED as-of the date ($1::date).
///
/// The engineer-directory slice the operations console offers as a name <select>:
/// only engineers whose employment window covers the slider's as-of date, so the
/// console can never name an engineer who is not on the books on that date. One
/// row per engineer (employment has at most one row covering a date), id + name,
/// ordered by name for a stable, alphabetised dropdown.
///
/// The id comes from the `engineer` ANCHOR (provably NOT NULL); the NAME, which
/// left the anchor for the edit-grouped contact fact, is read through the
/// `engineer_current` view (latest contact per engineer). The INNER JOIN means an
/// engineer with no contact row is omitted (every seeded/onboarded engineer has
/// one). coalesce keeps the name column NOT NULL through the view boundary; it is
/// never actually null (the join is on a NOT NULL contact column).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn roster_engineers(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(RosterEngineersRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(RosterEngineersRow(id:, name:))
  }

  "-- roster_engineers.sql — engineers EMPLOYED as-of the date ($1::date).
--
-- The engineer-directory slice the operations console offers as a name <select>:
-- only engineers whose employment window covers the slider's as-of date, so the
-- console can never name an engineer who is not on the books on that date. One
-- row per engineer (employment has at most one row covering a date), id + name,
-- ordered by name for a stable, alphabetised dropdown.
--
-- The id comes from the `engineer` ANCHOR (provably NOT NULL); the NAME, which
-- left the anchor for the edit-grouped contact fact, is read through the
-- `engineer_current` view (latest contact per engineer). The INNER JOIN means an
-- engineer with no contact row is omitted (every seeded/onboarded engineer has
-- one). coalesce keeps the name column NOT NULL through the view boundary; it is
-- never actually null (the join is on a NOT NULL contact column).
SELECT e.id, coalesce(ec.name, '') AS name
FROM engineer e
JOIN employment emp
  ON emp.engineer_id = e.id AND emp.employed_during @> $1::date
JOIN engineer_current ec ON ec.id = e.id
ORDER BY name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `roster_projects` query
/// defined in `./src/tempo/server/roster/sql/roster_projects.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RosterProjectsRow {
  RosterProjectsRow(id: Int, name: String)
}

/// roster_projects.sql — projects ACTIVE as-of the date ($1::date).
///
/// The project-directory slice the operations console offers as a name <select>:
/// only projects whose active window covers the slider's as-of date. The run's
/// `active_during` WITHOUT OVERLAPS constraint guarantees at most one project_run
/// row per project id per date, so this returns one row per active project, id +
/// name, ordered by name for a stable, alphabetised dropdown. The NAME left the
/// project anchor for the project_profile fact, so the title is read through the
/// `project_current` view (latest profile per project) and coalesced to keep the
/// String contract past Squirrel's nullable-view inference.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn roster_projects(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(RosterProjectsRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(RosterProjectsRow(id:, name:))
  }

  "-- roster_projects.sql — projects ACTIVE as-of the date ($1::date).
--
-- The project-directory slice the operations console offers as a name <select>:
-- only projects whose active window covers the slider's as-of date. The run's
-- `active_during` WITHOUT OVERLAPS constraint guarantees at most one project_run
-- row per project id per date, so this returns one row per active project, id +
-- name, ordered by name for a stable, alphabetised dropdown. The NAME left the
-- project anchor for the project_profile fact, so the title is read through the
-- `project_current` view (latest profile per project) and coalesced to keep the
-- String contract past Squirrel's nullable-view inference.
SELECT project_run.project_id AS id, coalesce(project_current.title, '') AS name
FROM project_run
JOIN project_current ON project_current.id = project_run.project_id
WHERE project_run.active_during @> $1::date
ORDER BY name;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
