//// Domain: assemble the people roster for a date (`GET /api/people?as_of=`). One
//// `PersonRow` per EMPLOYED engineer, joining the `people_list` read model (id,
//// name, email, level, day_rate, summed allocation fraction, covering leave kind,
//// comma-joined project titles) to `leave_balances` (the annual balance) by
//// engineer_id. No HTTP — this layer never imports `wisp`.
////
//// This does NOT reshape the org board: `BoardRow` carries no engineer_id/email and
//// its day_rate/fraction live only on the engaged variant, so a dedicated
//// `people_list.sql` supplies everything for bench/leave engineers too. The roster
//// `status` collapses an engineer's several allocations into one cell — a covering
//// leave fact wins (`RosterOnLeave`), else the project titles (`RosterOnProjects`),
//// else `RosterUnassigned`.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/types.{
  type PeopleList, type PersonRow, type RosterStatus, PeopleList, PersonRow,
  RosterOnLeave, RosterOnProjects, RosterUnassigned,
}
import tempo/server/context.{type Context}
import tempo/server/sql

/// Compute the people roster as-of `as_of`: run `people_list` and `leave_balances`,
/// join their rows by engineer_id, and map each to a shared `PersonRow`.
pub fn roster(
  context: Context,
  as_of: Date,
) -> Result(PeopleList, pog.QueryError) {
  use people <- result.try(sql.people_list(context.db, as_of))
  use balances <- result.map(sql.leave_balances(context.db, as_of))
  let annual_by_engineer =
    balances.rows
    |> list.map(fn(row) { #(row.engineer_id, row.annual) })
    |> dict.from_list
  let rows =
    list.map(people.rows, fn(row) {
      let annual_balance =
        dict.get(annual_by_engineer, row.engineer_id)
        |> result.unwrap(0.0)
      person_row_to_shared(row, annual_balance)
    })
  PeopleList(date: as_of, people: rows)
}

/// Map one `people_list` row (plus the annual balance joined from `leave_balances`)
/// to the shared `PersonRow`, collapsing the engineer's engagement into a single
/// roster status.
fn person_row_to_shared(
  row: sql.PeopleListRow,
  annual_balance: Float,
) -> PersonRow {
  PersonRow(
    engineer_id: row.engineer_id,
    name: row.name,
    email: row.email,
    level: row.level,
    status: status_of(row),
    allocated_fraction: row.allocated_fraction,
    annual_balance:,
    day_rate: row.day_rate,
  )
}

/// Collapse an engineer's engagement into a single roster cell: a covering leave
/// fact wins (`RosterOnLeave`), else the engineer's allocated project titles
/// (`RosterOnProjects`), else `RosterUnassigned`. `people_list` joins the project
/// titles into one comma-separated string; split it back into the list here.
fn status_of(row: sql.PeopleListRow) -> RosterStatus {
  case row.leave_kind {
    Some(kind) -> RosterOnLeave(kind:)
    None ->
      case project_titles(row.projects) {
        [] -> RosterUnassigned
        projects -> RosterOnProjects(projects:)
      }
  }
}

/// Split the comma-joined project titles `people_list` emits back into a list; an
/// empty string (a bench/leave engineer with no allocations) becomes `[]`.
fn project_titles(joined: String) -> List(String) {
  case joined {
    "" -> []
    _ ->
      string.split(joined, ", ")
      |> list.filter(fn(title) { title != "" })
  }
}
