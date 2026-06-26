//// Regression test for the "Unassigned" board slice (PRD FR-1): an engineer who
//// is employed but has no allocation and is not on leave on the date must
//// appear as `Unassigned`. Before the board was split into three queries
//// (board_engaged / board_unassigned / board_leave), such a
//// date produced a row with NULL project/client/rate that the non-null decoder
//// could not represent, so GET /api/board returned 500 (e.g. Marcus Chen across
//// mid-2024). This pins both the query and the fully-assembled snapshot.

import gleam/time/calendar
import shared/board/view as board_view
import shared/money
import tempo/server/board/sql
import tempo/server/board/view as board
import test_pool

// The board_unassigned query: at 2024-06-01 exactly Marcus is employed,
// not allocated, and not on leave — returned with his level (L4). Priya is
// allocated (Ledger) and so is absent here; she belongs to board_engaged.
pub fn board_unassigned_query_test() {
  let assert Ok(returned) =
    sql.board_unassigned(test_pool.db(), calendar.Date(2024, calendar.June, 1))

  assert returned.rows == [sql.BoardUnassignedRow("Marcus Chen", 4)]
}

// The assembled snapshot at 2024-06-01 succeeds (no 500) and renders Marcus as
// Unassigned alongside Priya's engagement — proving the three-slice board covers
// every employed engineer. Sorted by engineer name (Marcus before Priya).
//
// This test is in both tags' lineage, so it asserts only schema-invariant
// content: Marcus is matched exactly (Unassigned has no window), and Priya's
// engagement fields except its window — `valid_from`/`valid_to` legitimately
// differ between v1-wide (fragmented) and v2-split (coalesced), so they are
// ignored with `..`.
pub fn snapshot_includes_unassigned_test() {
  let assert Ok(snapshot) =
    board.snapshot(test_pool.ctx(), calendar.Date(2024, calendar.June, 1))

  let assert [marcus, priya] = snapshot.rows
  assert marcus == board_view.BoardRow("Marcus Chen", 4, board_view.Unassigned)
  let assert board_view.BoardRow(
    engineer: "Priya Sharma",
    level: 5,
    engagement: board_view.OnProject(
      project: "Ledger Migration",
      client: "Northwind Trading",
      fraction: 0.5,
      day_rate:,
      ..,
    ),
  ) = priya
  let assert Ok(expected_rate) = money.from_string("1200.00")
  assert day_rate == expected_rate
}
