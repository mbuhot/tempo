//// Perf-only bulk seed entrypoint (`gleam run -m tempo/seed_scale`, via
//// `bin/seed-scale`). Applies `priv/seed/scale_seed.sql` — a deterministic,
//// index-scale synthetic dataset (500 engineers, 150 clients/contracts, 200
//// projects, rolling allocations, leave, monthly payroll, invoices) sized for
//// the EXPLAIN ANALYZE perf gate (`tempo/perf`, `bin/perf`) — on top of an
//// already-migrated database.
////
//// Guarded the same way as `tempo/seed`: the target database must be EMPTY (no
//// engineer rows yet), so a re-run against an already-scaled database is a
//// no-op rather than a double-insert. There is deliberately NO `TEMPO_ENV`
//// guard here — this always targets an explicitly-named database
//// (`tempo_perf` by convention, never `tempo`/`tempo_test*`/`tempo_e2e*`), so
//// there is no "real environment" this could accidentally seed.

import gleam/dynamic/decode
import gleam/erlang/application
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import pog
import simplifile
import tempo/server/context.{type Context}
import tempo/server/migrate

/// What a scale-seed run did, or why it declined.
pub type ScaleReport {
  Scaled
  AlreadyScaled
}

/// Everything that can stop a scale-seed run.
pub type ScaleError {
  ScaleNotFound
  ScaleReadError(error: simplifile.FileError)
  ScaleApplyFailed(error: pog.QueryError)
}

/// Tables the scale seed populates, in an order sensible for a row-count
/// readout (anchors, then their facts, in roughly the order the seed writes
/// them).
const seeded_tables = [
  "engineer", "employment", "engineer_contact", "engineer_role", "client",
  "client_profile", "contract", "contract_terms", "project", "project_run",
  "project_profile", "project_plan", "project_requirement", "allocation",
  "leave", "rate_card", "salary", "leave_policy", "payroll_run",
  "payroll_period", "payroll_line", "payroll_line_segment", "invoice",
  "invoice_subject", "invoice_status", "invoice_line", "event_log",
]

/// `gleam run -m tempo/seed_scale` (via `bin/seed-scale`). Connect to the
/// database named by the environment (`TEMPO_DB_NAME`, `tempo_perf` by
/// convention), apply the scale seed if it is empty, then print a row count per
/// seeded table. Exits non-zero (via `panic`) on failure.
pub fn main() -> Nil {
  let assert Ok(ctx) = context.start()
  case run(ctx) {
    Ok(Scaled) -> {
      io.println("seed-scale: bulk dataset applied.")
      print_row_counts(ctx)
    }
    Ok(AlreadyScaled) ->
      io.println("seed-scale: DB already has the scale cast — nothing to do.")
    Error(error) -> panic as { "seed-scale failed: " <> string.inspect(error) }
  }
}

/// Apply the scale seed if the database is empty (a no-op once scaled). Every
/// statement in `scale_seed.sql` runs in one transaction, so a failure leaves
/// the database unscaled rather than half-scaled.
pub fn run(context: Context) -> Result(ScaleReport, ScaleError) {
  case already_scaled(context) {
    True -> Ok(AlreadyScaled)
    False -> {
      use statements <- result.try(scale_statements())
      use _ <- result.map(apply_scale(context.db, statements))
      Scaled
    }
  }
}

/// True when the scale cast is already present (any engineer row) — the signal
/// this database has already been through `run`, used to keep a re-run a no-op.
fn already_scaled(context: Context) -> Bool {
  table_has_rows(context, "SELECT count(*) FROM engineer")
}

fn table_has_rows(context: Context, count_query: String) -> Bool {
  let row_decoder = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  case
    pog.query(count_query)
    |> pog.returning(row_decoder)
    |> pog.execute(on: context.db)
  {
    Ok(returned) ->
      case returned.rows {
        [count, ..] -> count > 0
        [] -> False
      }
    Error(_) -> False
  }
}

/// Read and split `priv/seed/scale_seed.sql` into individual statements,
/// reusing the migration runner's dollar-quote-aware lexer.
fn scale_statements() -> Result(List(String), ScaleError) {
  use priv <- result.try(
    application.priv_directory("tempo")
    |> result.replace_error(ScaleNotFound),
  )
  use body <- result.map(
    simplifile.read(priv <> "/seed/scale_seed.sql")
    |> result.map_error(ScaleReadError),
  )
  migrate.split_statements(body)
}

/// Apply every scale-seed statement in one transaction.
fn apply_scale(
  db: pog.Connection,
  statements: List(String),
) -> Result(Nil, ScaleError) {
  let outcome =
    pog.transaction(db, fn(conn) {
      use _ <- result.try(execute_each(conn, statements))
      Ok(Nil)
    })
  case outcome {
    Ok(_) -> Ok(Nil)
    Error(pog.TransactionRolledBack(error)) -> Error(error)
    Error(pog.TransactionQueryError(error)) -> Error(ScaleApplyFailed(error))
  }
}

/// A generous per-statement timeout override, in case pog's 5s default ever
/// applies to this connection kind. The load-bearing constraint is actually
/// pgo's pool-wide 5s CHECKOUT deadline (not exposed by pog's public API): the
/// whole transaction, start to commit, must complete inside it — see
/// scale_seed.sql's invoice_line comment for why one join order took that from
/// 17s to well under a second.
const statement_timeout = 120_000

/// Execute each statement against the open transaction, stopping at the first
/// failure.
fn execute_each(
  conn: pog.Connection,
  statements: List(String),
) -> Result(Nil, ScaleError) {
  use statement <- list_try_each(statements)
  pog.query(statement)
  |> pog.timeout(statement_timeout)
  |> pog.execute(on: conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(ScaleApplyFailed)
}

fn list_try_each(
  items: List(a),
  apply: fn(a) -> Result(Nil, ScaleError),
) -> Result(Nil, ScaleError) {
  case items {
    [] -> Ok(Nil)
    [first, ..rest] -> {
      use _ <- result.try(apply(first))
      list_try_each(rest, apply)
    }
  }
}

/// Print `<table>: <count>` for every table the scale seed touched, so
/// `bin/seed-scale` gives a quick readout of what it just built.
fn print_row_counts(context: Context) -> Nil {
  list.each(seeded_tables, fn(table) {
    let count = row_count(context, table)
    io.println(table <> ": " <> int.to_string(count))
  })
}

fn row_count(context: Context, table: String) -> Int {
  let row_decoder = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  case
    pog.query("SELECT count(*) FROM " <> table)
    |> pog.returning(row_decoder)
    |> pog.execute(on: context.db)
  {
    Ok(returned) ->
      case returned.rows {
        [count, ..] -> count
        [] -> 0
      }
    Error(_) -> 0
  }
}
