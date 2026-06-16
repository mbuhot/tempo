//// Regression test for the "Unassigned" board slice (PRD FR-1): an engineer who
//// is employed but has no allocation and is not on leave as of the date must
//// appear as `Unassigned`. Before the board was split into three queries
//// (board_as_of engaged / board_unassigned_as_of / board_leave_as_of), such a
//// date produced a row with NULL project/client/rate that the non-null decoder
//// could not represent, so GET /api/board returned 500 (e.g. Marcus Chen across
//// mid-2024). This pins both the query and the fully-assembled snapshot.

import gleam/erlang/process
import gleam/time/calendar
import pog
import shared/types
import tempo/server/board
import tempo/server/context
import tempo/server/sql

/// Single-connection pool per test (mirrors sql_test); these are read-only
/// against the shared seed.
fn db() -> pog.Connection {
  let pool_name = process.new_name(prefix: "tempo_unassigned_test_db")
  let config =
    context.pool_config(context.settings_from_env(), pool_name)
    |> pog.pool_size(1)
  let assert Ok(started) = pog.start(config)
  started.data
}

// The board_unassigned_as_of query: at 2024-06-01 exactly Marcus is employed,
// not allocated, and not on leave — returned with his level (L4). Priya is
// allocated (Ledger) and so is absent here; she belongs to board_as_of.
pub fn board_unassigned_as_of_query_test() {
  let assert Ok(returned) =
    sql.board_unassigned_as_of(db(), calendar.Date(2024, calendar.June, 1))

  assert returned.rows == [sql.BoardUnassignedAsOfRow("Marcus Chen", 4)]
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
    board.snapshot(
      context.Context(db: db()),
      calendar.Date(2024, calendar.June, 1),
    )

  let assert [marcus, priya] = snapshot.rows
  assert marcus == types.BoardRow("Marcus Chen", 4, types.Unassigned)
  let assert types.BoardRow(
    engineer: "Priya Sharma",
    level: 5,
    engagement: types.OnProject(
      project: "Ledger Migration",
      client: "Northwind Trading",
      fraction: 0.5,
      day_rate: 1200.0,
      ..,
    ),
  ) = priya
}
