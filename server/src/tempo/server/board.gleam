//// Domain: assemble the org board for a date by running the temporal join and
//// mapping rows to shared types. No HTTP — this layer never imports `wisp`.
////
//// The board snapshot is assembled from three Squirrel queries, one per
//// Engagement variant: `board_engaged` (employed + allocated, leave-suppressed),
//// `board_unassigned` (employed, not allocated, not on leave), and
//// `board_leave` (the engineers a covering leave fact hides from the first).
//// Each maps to the shared `BoardRow`/`Engagement` contract; the merged list is
//// sorted by engineer so the wire order is deterministic for the client and tests.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/types.{
  type BoardRow, type BoardSnapshot, type LeaveBalance, type UnstaffedProject,
  BoardRow, BoardSnapshot, LeaveBalance, OnLeave, OnProject, Unassigned,
  UnstaffedProject,
}
import tempo/server/context.{type Context}
import tempo/server/sql

/// Compute the board snapshot for a date: run the three engagement queries, the
/// unstaffed-projects query, and the leave balances; map each to its shared type,
/// and merge the engagement rows sorted by engineer name.
pub fn snapshot(
  context: Context,
  date: Date,
) -> Result(BoardSnapshot, pog.QueryError) {
  use board <- result.try(sql.board_engaged(context.db, date))
  use unassigned <- result.try(sql.board_unassigned(context.db, date))
  use leave <- result.try(sql.board_leave(context.db, date))
  use unstaffed <- result.try(sql.board_unstaffed(context.db, date))
  use balances <- result.try(sql.leave_balances(context.db, date))
  let rows =
    list.flatten([
      list.map(board.rows, board_row_to_shared),
      list.map(unassigned.rows, unassigned_row_to_shared),
      list.map(leave.rows, leave_row_to_shared),
    ])
    |> list.sort(by_engineer)
  let balances = list.map(balances.rows, balance_row_to_shared)
  let unstaffed = list.map(unstaffed.rows, unstaffed_row_to_shared)
  Ok(BoardSnapshot(date:, rows:, balances:, unstaffed:))
}

/// Map a board_unstaffed row (an active project with no covering allocation) to
/// the shared `UnstaffedProject` (the board's unstaffed lane).
fn unstaffed_row_to_shared(row: sql.BoardUnstaffedRow) -> UnstaffedProject {
  UnstaffedProject(
    project_id: row.project_id,
    title: row.title,
    client: row.client,
  )
}

/// Map a leave_balances row to the shared `LeaveBalance` (engineer + annual/sick
/// days available as of the board date).
fn balance_row_to_shared(row: sql.LeaveBalancesRow) -> LeaveBalance {
  LeaveBalance(engineer: row.engineer, annual: row.annual, sick: row.sick)
}

/// Map an on-project query row to the shared `BoardRow` / `OnProject`.
fn board_row_to_shared(row: sql.BoardEngagedRow) -> BoardRow {
  BoardRow(
    engineer: row.engineer,
    level: row.level,
    engagement: OnProject(
      project: row.project,
      client: row.client,
      fraction: row.fraction,
      day_rate: row.day_rate,
      valid_from: row.valid_from,
      valid_to: row.valid_to,
    ),
  )
}

/// Map an unassigned board row (employed, no allocation, not on leave) to the
/// shared `BoardRow`/`Unassigned` contract.
fn unassigned_row_to_shared(row: sql.BoardUnassignedRow) -> BoardRow {
  BoardRow(engineer: row.engineer, level: row.level, engagement: Unassigned)
}

/// Map an on-leave board row to the shared `BoardRow`/`OnLeave` contract. The
/// level falls back to 0 only if the leave row carries none (not expected for a
/// leave-covered, employed engineer, who always has a role).
fn leave_row_to_shared(row: sql.BoardLeaveRow) -> BoardRow {
  BoardRow(
    engineer: row.engineer,
    level: level_or_zero(row.level),
    engagement: OnLeave(
      kind: row.kind,
      valid_from: row.valid_from,
      valid_to: row.valid_to,
    ),
  )
}

fn level_or_zero(level: Option(Int)) -> Int {
  case level {
    Some(value) -> value
    None -> 0
  }
}

/// Order board rows by engineer name (the deterministic wire order). Ties keep
/// their relative input order, preserving the per-engineer project ordering the
/// queries already impose (`ORDER BY engineer.name, project.name`).
fn by_engineer(left: BoardRow, right: BoardRow) -> order.Order {
  string.compare(left.engineer, right.engineer)
}
