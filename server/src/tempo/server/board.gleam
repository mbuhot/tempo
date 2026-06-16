//// Domain: assemble the as-of org board by running the temporal join and mapping
//// rows to shared types. No HTTP — this layer never imports `wisp`.
////
//// The board snapshot is assembled from three Squirrel queries, one per
//// Engagement variant: `board_as_of` (employed + allocated, leave-suppressed),
//// `board_unassigned_as_of` (employed, not allocated, not on leave), and
//// `board_leave_as_of` (the engineers a covering leave fact hides from the first).
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
  type BoardRow, type BoardSnapshot, BoardRow, BoardSnapshot, OnLeave, OnProject,
  Unassigned,
}
import tempo/server/context.{type Context}
import tempo/server/sql

/// Compute the board snapshot as of a date: run the three as-of queries, map each
/// row to a shared `BoardRow`, and merge them sorted by engineer name.
pub fn snapshot(
  context: Context,
  as_of: Date,
) -> Result(BoardSnapshot, pog.QueryError) {
  use board <- result.try(sql.board_as_of(context.db, as_of))
  use unassigned <- result.try(sql.board_unassigned_as_of(context.db, as_of))
  use leave <- result.try(sql.board_leave_as_of(context.db, as_of))
  let rows =
    list.flatten([
      list.map(board.rows, board_row_to_shared),
      list.map(unassigned.rows, unassigned_row_to_shared),
      list.map(leave.rows, leave_row_to_shared),
    ])
    |> list.sort(by_engineer)
  Ok(BoardSnapshot(as_of:, rows:))
}

/// Map an on-project query row to the shared `BoardRow` / `OnProject`.
fn board_row_to_shared(row: sql.BoardAsOfRow) -> BoardRow {
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
fn unassigned_row_to_shared(row: sql.BoardUnassignedAsOfRow) -> BoardRow {
  BoardRow(engineer: row.engineer, level: row.level, engagement: Unassigned)
}

/// Map an on-leave board row to the shared `BoardRow`/`OnLeave` contract. The
/// level falls back to 0 only if the leave row carries none (not expected for a
/// leave-covered, employed engineer, who always has a role).
fn leave_row_to_shared(row: sql.BoardLeaveAsOfRow) -> BoardRow {
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
