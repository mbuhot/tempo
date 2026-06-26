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
import shared/board/view.{
  type BoardRow, type BoardSnapshot, type UnstaffedProject, BoardRow,
  BoardSnapshot, OnLeave, OnProject, Unassigned, UnstaffedProject,
} as _
import shared/leave/view.{type LeaveBalance, LeaveBalance} as _
import shared/money.{type Money}
import tempo/server/async.{type AsyncQuery}
import tempo/server/board/sql as board_sql
import tempo/server/context.{type Context, query_timeout}
import tempo/server/leave/sql as leave_sql

/// Parse a money amount from a trusted SQL `numeric::text` column.
fn money(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

/// Compute the board snapshot for a date: spawn the three engagement queries, the
/// unstaffed-projects query, and the leave balances CONCURRENTLY against the pool,
/// await all of them, then map each to its shared type and merge the engagement
/// rows sorted by engineer name. The queries are independent, so the wall-clock
/// cost is the slowest one rather than their sum.
pub fn snapshot(
  context: Context,
  date: Date,
) -> Result(BoardSnapshot, pog.QueryError) {
  let engaged: AsyncQuery(board_sql.BoardEngagedRow) =
    async.start(fn() { board_sql.board_engaged(context.db, date) })
  let unassigned: AsyncQuery(board_sql.BoardUnassignedRow) =
    async.start(fn() { board_sql.board_unassigned(context.db, date) })
  let leave: AsyncQuery(board_sql.BoardLeaveRow) =
    async.start(fn() { board_sql.board_leave(context.db, date) })
  let unstaffed: AsyncQuery(board_sql.BoardUnstaffedRow) =
    async.start(fn() { board_sql.board_unstaffed(context.db, date) })
  let balances: AsyncQuery(leave_sql.LeaveBalancesRow) =
    async.start(fn() { leave_sql.leave_balances(context.db, date) })

  let engaged = async.await(engaged, query_timeout)
  let unassigned = async.await(unassigned, query_timeout)
  let leave = async.await(leave, query_timeout)
  let unstaffed = async.await(unstaffed, query_timeout)
  let balances = async.await(balances, query_timeout)

  use engaged <- result.try(engaged)
  use unassigned <- result.try(unassigned)
  use leave <- result.try(leave)
  use unstaffed <- result.try(unstaffed)
  use balances <- result.try(balances)

  let rows =
    list.flatten([
      list.map(engaged.rows, board_row_to_shared),
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
fn unstaffed_row_to_shared(
  row: board_sql.BoardUnstaffedRow,
) -> UnstaffedProject {
  UnstaffedProject(
    project_id: row.project_id,
    title: row.title,
    client: row.client,
  )
}

/// Map a leave_balances row to the shared `LeaveBalance` (engineer + annual/sick
/// days available as of the board date).
fn balance_row_to_shared(row: leave_sql.LeaveBalancesRow) -> LeaveBalance {
  LeaveBalance(engineer: row.engineer, annual: row.annual, sick: row.sick)
}

/// Map an on-project query row to the shared `BoardRow` / `OnProject`.
fn board_row_to_shared(row: board_sql.BoardEngagedRow) -> BoardRow {
  BoardRow(
    engineer: row.engineer,
    level: row.level,
    engagement: OnProject(
      project: row.project,
      client: row.client,
      fraction: row.fraction,
      day_rate: money(row.day_rate),
      valid_from: row.valid_from,
      valid_to: row.valid_to,
    ),
  )
}

/// Map an unassigned board row (employed, no allocation, not on leave) to the
/// shared `BoardRow`/`Unassigned` contract.
fn unassigned_row_to_shared(row: board_sql.BoardUnassignedRow) -> BoardRow {
  BoardRow(engineer: row.engineer, level: row.level, engagement: Unassigned)
}

/// Map an on-leave board row to the shared `BoardRow`/`OnLeave` contract. The
/// level falls back to 0 only if the leave row carries none (not expected for a
/// leave-covered, employed engineer, who always has a role).
fn leave_row_to_shared(row: board_sql.BoardLeaveRow) -> BoardRow {
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
