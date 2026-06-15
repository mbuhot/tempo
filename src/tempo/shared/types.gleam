//// Target: both (Erlang + JS) — domain/API types shared by server and client. Must stay target-agnostic.

/// A point in time the board/timesheet is rendered "as of".
pub type AsOf {
  AsOf(year: Int, month: Int, day: Int)
}

/// One engineer's situation on the org board, computed as of a date.
pub type BoardRow {
  BoardRow(
    engineer: String,
    level: Int,
    project: String,
    client: String,
    fraction: Float,
    day_rate: Float,
  )
}

/// The whole org board, as of a single instant.
pub type BoardSnapshot {
  BoardSnapshot(as_of: AsOf, rows: List(BoardRow))
}

/// Build a board snapshot for a given date.
pub fn board_snapshot(_as_of: AsOf, _rows: List(BoardRow)) -> BoardSnapshot {
  todo as "P1: assemble board snapshot from query rows"
}
