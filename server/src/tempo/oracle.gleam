//// A verification that the `010_split_allocation` schema migration preserves the
//// observable history of the org board: for every date in the seed span, the
//// board is identical before and after applying `010_split_allocation`.
////
//// The check seeds a fresh database (drops and recreates `public`, then applies
//// the pre-migration schema 001+002+003), snapshots the board for every day in
//// the seed span, applies the `010_split_allocation` coalescing migration,
//// re-snapshots every day, and compares the two snapshots date by date. Equal
//// boards everywhere confirm the migration leaves the board's observable output
//// unchanged.
////
//// Each snapshot runs the production board SQL
//// (`src/tempo/server/sql/board_engaged.sql`) wrapped in a CTE that renders one
//// date's whole board to a single NULL-tolerant text blob, so the comparison is
//// over the exact query the app serves rather than a re-typed copy of it. The
//// rendering covers the user-visible columns — engineer, level, project, client,
//// fraction, charge rate — and excludes the engagement window, which the
//// coalescing migration is expected to change and the client never renders.
////
////     gleam run -m tempo/oracle
////
//// Exits non-zero (via `panic`) on the first date whose board differs, reporting
//// that date and both renderings. On success it leaves the database at the
//// migrated schema, the same end state `gleam run -m tempo/migrate` produces.

import gleam/dynamic/decode
import gleam/erlang/application
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import simplifile
import tempo/server/context
import tempo/server/migrate

/// The board for one date: the date and a deterministic text rendering of
/// every row the production board query returns for it (NULL-tolerant, one row
/// per line; see `board_snapshot_sql`).
pub type DateBoard {
  DateBoard(date: Date, board: String)
}

/// The first date whose board differs across the migration, with both renderings.
pub type Mismatch {
  Mismatch(date: Date, before: String, after: String)
}

/// `gleam run -m tempo/oracle`. Rebuilds a fresh pre-migration DB, snapshots
/// every day's board, applies the migration, re-snapshots, and asserts the boards
/// are equal for every date. Prints a summary on success; `panic`s (non-zero
/// exit) on the first differing date so it can gate CI.
pub fn main() -> Nil {
  let assert Ok(ctx) = context.start()
  let db = ctx.db

  io.println("Migration oracle (010_split_allocation)")
  io.println(
    "Resetting to a fresh pre-migration schema (001 + 002 + 003 + 014)...",
  )
  let assert Ok(Nil) = reset_to_fresh_v1(db)

  let dates = seed_span_dates(db)
  io.println(
    "Sampling the board for every day in the seed span: "
    <> describe_span(dates),
  )

  let snapshot_sql = board_snapshot_sql()
  let before = snapshot(db, snapshot_sql, dates)
  io.println("Applying 010_split_allocation...")
  let assert Ok(Nil) = apply_recorded(db, "010_split_allocation.sql")
  let after = snapshot(db, snapshot_sql, dates)

  case first_mismatch(before, after) {
    Ok(mismatch) -> panic as render_mismatch(mismatch)
    Error(Nil) ->
      io.println(
        "ORACLE PASS: board identical for all "
        <> int.to_string(list.length(dates))
        <> " dates across the migration.",
      )
  }
}

// --- fresh pre-migration seed -----------------------------------------------

/// Drop and recreate the `public` schema (clearing any prior state and the
/// migrate runner's `schema_migrations`), recreate an empty ledger, then apply the
/// pre-migration schema — 001_init, 002_facts, 003_seed — plus 014_engineer_facts,
/// directly, in order, recording each. Each file's statements run in their own
/// transaction so a bad seed aborts loudly. `btree_gist` is dropped with the schema
/// and re-created by 001 (`CREATE EXTENSION IF NOT EXISTS`).
///
/// 014 is applied here even though it post-dates `010`: the production board read
/// (`board_engaged.sql`) now sources the engineer name from the `engineer_current`
/// view that 014 introduces, so the view must exist before the board is snapshotted.
/// 014 (engineer anchor + detail facts) is independent of `010` (the allocation
/// split), so applying it in the v1 baseline does not affect what `010` changes —
/// the board comparison still isolates `010`'s effect.
fn reset_to_fresh_v1(db: pog.Connection) -> Result(Nil, String) {
  use _ <- result.try(reset_public_schema(db))
  use _ <- result.try(ensure_ledger(db))
  list.try_each(
    ["001_init.sql", "002_facts.sql", "003_seed.sql", "014_engineer_facts.sql"],
    fn(version) { apply_recorded(db, version) },
  )
}

/// Tear down everything in `public` and recreate the empty schema.
fn reset_public_schema(db: pog.Connection) -> Result(Nil, String) {
  ["DROP SCHEMA public CASCADE", "CREATE SCHEMA public"]
  |> list.try_each(fn(statement) { execute(db, statement) })
}

/// Recreate the migrate runner's `schema_migrations` ledger (dropped with the
/// schema), so that after the oracle the DB is in the SAME state
/// `gleam run -m tempo/migrate` leaves: the migrated schema + a full ledger.
/// Without this, the runner would think nothing is applied and re-run 001+ over
/// existing tables, breaking the shared dev DB the `gleam test` suite uses.
fn ensure_ledger(db: pog.Connection) -> Result(Nil, String) {
  execute(
    db,
    "CREATE TABLE schema_migrations (
       version text PRIMARY KEY,
       applied_at timestamptz NOT NULL DEFAULT now()
     )",
  )
}

/// Apply a migration file from `priv/migrations` and record its version in the
/// ledger, all in one transaction (a failing statement rolls the file back,
/// including its ledger row). Mirrors `tempo/server/migrate`'s per-file
/// semantics, so the oracle's end state matches the production runner's.
fn apply_recorded(db: pog.Connection, version: String) -> Result(Nil, String) {
  use body <- result.try(read_priv_sql("migrations/" <> version))
  let statements = migrate.split_statements(body)
  pog.transaction(db, fn(conn) {
    use _ <- result.try(
      list.try_each(statements, fn(statement) {
        pog.query(statement)
        |> pog.execute(on: conn)
        |> result.map(fn(_) { Nil })
      }),
    )
    pog.query("INSERT INTO schema_migrations (version) VALUES ($1)")
    |> pog.parameter(pog.text(version))
    |> pog.execute(on: conn)
    |> result.map(fn(_) { Nil })
  })
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    "applying " <> version <> ": " <> string.inspect(error)
  })
}

/// Read a file under the `tempo` package `priv/` directory as raw text.
fn read_priv_sql(relative_path: String) -> Result(String, String) {
  use priv <- result.try(
    application.priv_directory("tempo")
    |> result.replace_error("priv directory not found"),
  )
  simplifile.read(priv <> "/" <> relative_path)
  |> result.map_error(fn(error) {
    "reading " <> relative_path <> ": " <> string.inspect(error)
  })
}

/// Run one statement against the pool, mapping any error to a readable string.
fn execute(db: pog.Connection, statement: String) -> Result(Nil, String) {
  pog.query(statement)
  |> pog.execute(on: db)
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    "running `" <> statement <> "`: " <> string.inspect(error)
  })
}

// --- snapshot ---------------------------------------------------------------

/// Every day the seed covers, as plain `date`s, taken from the database's own
/// `generate_series` over the seed span. Spanning `[2024-01-01, 2027-01-01)` (the
/// widest seeded range, 003_seed.sql), the dense set of sample dates is every day
/// from 2024-01-01 through 2026-12-31 inclusive (the last in-range day; the upper
/// bound is exclusive).
pub fn seed_span_dates(db: pog.Connection) -> List(Date) {
  let row_decoder = {
    use day <- decode.field(0, pog.calendar_date_decoder())
    decode.success(day)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT d::date
       FROM generate_series('2024-01-01'::date, '2026-12-31'::date, '1 day') AS d",
    )
    |> pog.returning(row_decoder)
    |> pog.execute(on: db)
  returned.rows
}

/// Wrap the *production* board query (src/tempo/server/sql/board_engaged.sql) in a
/// CTE and render its whole result for one date to a single text blob: one line
/// per row, columns `|`-joined, every column COALESCEd so a NULL (e.g. an
/// employed-but-unallocated engineer) renders as `∅` instead of failing to
/// decode. Rows are ordered by (engineer, project) so the blob is deterministic.
/// Reading the file (not re-typing the SQL) keeps the oracle faithful: it tests
/// the exact query the app serves and cannot drift from it.
///
/// THE ORACLE INVARIANT is the *user-visible* board: for every date the board's
/// project/client/fraction/rate are identical before and after. The rendering
/// therefore compares exactly what the user sees — engineer, level, project,
/// client, fraction, charge rate — and deliberately EXCLUDES the engagement
/// window (valid_from/valid_to). That window is the allocation's own
/// `lower/upper(allocated_during)`, which the coalescing migration is SUPPOSED to change
/// (it merges rate-fragmented rows into whole engagements), and which the client
/// never renders (client/app `describe_engagement` drops it via `..`). Including
/// it would assert the migration did nothing, the opposite of the point.
///
/// Public so the seed-equivalence test (ADR-023) renders the board with the exact
/// same machinery the oracle uses, rather than a re-typed copy.
pub fn board_snapshot_sql() -> String {
  let assert Ok(board_sql) =
    read_priv_sql("../src/tempo/server/sql/board_engaged.sql")
  let board_cte = strip_trailing_semicolon(string.trim(board_sql))
  "WITH board AS (\n" <> board_cte <> "\n)
SELECT COALESCE(string_agg(
  concat_ws('|',
    engineer,
    level::text,
    COALESCE(project, '∅'),
    COALESCE(client, '∅'),
    COALESCE(fraction::text, '∅'),
    COALESCE(day_rate::text, '∅')
  ),
  E'\\n' ORDER BY engineer, project NULLS FIRST
), '') AS board
FROM board"
}

/// Run the board-snapshot query for each date and pair the rendering with its
/// date. Public so the seed-equivalence test (ADR-023) reuses it.
pub fn snapshot(
  db: pog.Connection,
  snapshot_sql: String,
  dates: List(Date),
) -> List(DateBoard) {
  let row_decoder = {
    use board <- decode.field(0, decode.string)
    decode.success(board)
  }
  list.map(dates, fn(date) {
    let assert Ok(returned) =
      pog.query(snapshot_sql)
      |> pog.parameter(pog.calendar_date(date))
      |> pog.returning(row_decoder)
      |> pog.execute(on: db)
    let assert [board] = returned.rows
    DateBoard(date:, board:)
  })
}

// --- comparison -------------------------------------------------------------

/// The first date whose board differs between the before- and after-migration
/// snapshots, or `Error(Nil)` if every date matches. The two snapshots are taken
/// over the identical date list, so they align element-for-element.
pub fn first_mismatch(
  before: List(DateBoard),
  after: List(DateBoard),
) -> Result(Mismatch, Nil) {
  list.zip(before, after)
  |> list.find_map(fn(pair) {
    let #(before_board, after_board) = pair
    case before_board.board == after_board.board {
      True -> Error(Nil)
      False ->
        Ok(Mismatch(
          date: before_board.date,
          before: before_board.board,
          after: after_board.board,
        ))
    }
  })
}

// --- reporting --------------------------------------------------------------

/// A human-readable description of the sampled span: first..last and the count.
fn describe_span(dates: List(Date)) -> String {
  case dates, list.last(dates) {
    [first, ..], Ok(last) ->
      iso(first)
      <> " .. "
      <> iso(last)
      <> " ("
      <> int.to_string(list.length(dates))
      <> " days)"
    _, _ -> "(empty)"
  }
}

/// The loud failure message naming the first differing date and both renderings.
fn render_mismatch(mismatch: Mismatch) -> String {
  "ORACLE FAIL: board differs across the migration at "
  <> iso(mismatch.date)
  <> "\n  before:\n"
  <> mismatch.before
  <> "\n  after:\n"
  <> mismatch.after
}

/// Render a `calendar.Date` as `YYYY-MM-DD` for messages.
fn iso(date: Date) -> String {
  let calendar.Date(year:, month:, day:) = date
  pad(year, 4)
  <> "-"
  <> pad(calendar.month_to_int(month), 2)
  <> "-"
  <> pad(day, 2)
}

fn pad(value: Int, width: Int) -> String {
  int.to_string(value) |> string.pad_start(to: width, with: "0")
}

/// Drop a single trailing `;` (and any following whitespace) so the board SQL can
/// be embedded as a CTE subquery.
fn strip_trailing_semicolon(sql: String) -> String {
  case string.ends_with(sql, ";") {
    True -> string.drop_end(sql, 1)
    False -> sql
  }
}
