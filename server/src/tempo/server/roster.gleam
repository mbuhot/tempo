//// Domain: assemble the operations-console directory for a date by running the
//// three roster queries and mapping rows to shared `Ref`s. No HTTP — this layer
//// never imports `wisp`.
////
//// The roster is the as-of directory the console turns into name `<select>`s:
//// the engineers EMPLOYED on the date and the projects ACTIVE on the date (both
//// date-filtered, so the console can only name a subject valid then), plus every
//// client. A client is a durable identity with no validity window, so its query
//// takes no date and the roster offers the same client list regardless of `as_of`.

import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/types.{type Ref, type Roster, Ref, Roster}
import tempo/server/context.{type Context}
import tempo/server/sql

/// Compute the console directory as-of `as_of`: the employed engineers and the
/// active projects on the date, plus every client (clients ignore `as_of`). Each
/// list is mapped from its Squirrel row to a shared `Ref` (id + name).
pub fn roster(context: Context, as_of: Date) -> Result(Roster, pog.QueryError) {
  use engineers <- result.try(sql.roster_engineers(context.db, as_of))
  use projects <- result.try(sql.roster_projects(context.db, as_of))
  use clients <- result.map(sql.roster_clients(context.db))
  Roster(
    engineers: list.map(engineers.rows, engineer_row_to_ref),
    projects: list.map(projects.rows, project_row_to_ref),
    clients: list.map(clients.rows, client_row_to_ref),
  )
}

fn engineer_row_to_ref(row: sql.RosterEngineersRow) -> Ref {
  Ref(id: row.id, name: row.name)
}

fn project_row_to_ref(row: sql.RosterProjectsRow) -> Ref {
  Ref(id: row.id, name: row.name)
}

fn client_row_to_ref(row: sql.RosterClientsRow) -> Ref {
  Ref(id: row.id, name: row.name)
}
