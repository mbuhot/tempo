//// Dev-only base-seed entrypoint (`gleam run -m tempo/seed`, run via `bin/seed`).
//// Applies `priv/seed/base_seed.sql` — the deterministic demo cast (clients,
//// engineers, rate card, allocations, ...) — on top of a migrated schema. It is
//// DELIBERATELY NOT a migration: the forward runner only ever applies
//// `priv/migrations`, so this fictional data can never be injected into a real
//// environment by a deploy.
////
//// Two guards make seeding a non-dev environment impossible by default:
////   * TEMPO_ENV must be `dev` (the unset default). Any other value refuses with
////     `NotDevEnvironment` before touching the DB.
////   * The seed only runs against an EMPTY DB. A DB that already has the cast
////     (engineer rows present) reports `AlreadySeeded` and changes nothing, so
////     re-running is a safe no-op rather than a double-insert.
////
//// It runs `migrate.run` first so a fresh DB ends up schema + seed in one step
//// (mirroring the old `bin/migrate`, which applied schema + the 002 seed migration).

import gleam/dynamic/decode
import gleam/erlang/application
import gleam/io
import gleam/result
import gleam/string
import pog
import simplifile
import tempo/server/context.{type Context}
import tempo/server/migrate

/// The TEMPO_ENV value that permits seeding. Unset defaults to this, so local dev
/// and the test suite seed without configuration; a deployed environment must set
/// TEMPO_ENV to something else to be refused.
const dev_env = "dev"

/// What a seed run did, or why it declined.
pub type SeedReport {
  Seeded
  AlreadySeeded
}

/// Everything that can stop a seed: a non-dev environment, a failed migrate
/// pre-step, or a problem reading/applying the seed SQL.
pub type SeedError {
  NotDevEnvironment(env: String)
  MigrateFailed(error: migrate.MigrateError)
  SeedNotFound
  SeedReadError(error: simplifile.FileError)
  SeedApplyFailed(error: pog.QueryError)
}

/// `gleam run -m tempo/seed` (via `bin/seed`). Connect to the dev DB, ensure the
/// schema is migrated, then seed an empty DB. Prints a one-line summary and exits
/// non-zero on refusal/failure.
pub fn main() -> Nil {
  let assert Ok(ctx) = context.start()
  case run(ctx, env_or_dev()) {
    Ok(Seeded) -> io.println("seed: base demo data applied.")
    Ok(AlreadySeeded) ->
      io.println("seed: DB already has the demo cast — nothing to do.")
    Error(NotDevEnvironment(env)) ->
      panic as {
        "seed: refusing to seed a non-dev environment (TEMPO_ENV=" <> env <> ")"
      }
    Error(error) -> panic as { "seed failed: " <> string.inspect(error) }
  }
}

/// The environment the seed should run as: `TEMPO_ENV` if set, else `dev`.
pub fn env_or_dev() -> String {
  context.env_string("TEMPO_ENV", dev_env)
}

/// Ensure the schema is migrated, then apply the base seed if (a) `env` is dev
/// and (b) the DB is empty. A non-dev `env` refuses up front; a non-empty DB is a
/// no-op (`AlreadySeeded`). Applies every statement of the seed file in one
/// transaction so a failure leaves the DB unseeded rather than half-seeded.
pub fn run(context: Context, env: String) -> Result(SeedReport, SeedError) {
  use <- guard_dev(env)
  use _ <- result.try(migrate.run(context) |> result.map_error(MigrateFailed))
  case already_seeded(context) {
    True -> Ok(AlreadySeeded)
    False -> {
      use statements <- result.try(seed_statements())
      use _ <- result.map(apply_seed(context.db, statements))
      Seeded
    }
  }
}

/// Refuse anything but the dev environment before any DB work.
fn guard_dev(
  env: String,
  then: fn() -> Result(SeedReport, SeedError),
) -> Result(SeedReport, SeedError) {
  case env == dev_env {
    True -> then()
    False -> Error(NotDevEnvironment(env))
  }
}

/// True when the demo cast is already present (any engineer row) — the signal the
/// seed has run, used to keep a re-run a no-op.
fn already_seeded(context: Context) -> Bool {
  let row_decoder = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  case
    pog.query("SELECT count(*) FROM engineer")
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

/// Read and split `priv/seed/base_seed.sql` into individual statements, reusing
/// the migration runner's dollar-quote-aware lexer.
fn seed_statements() -> Result(List(String), SeedError) {
  use priv <- result.try(
    application.priv_directory("tempo")
    |> result.replace_error(SeedNotFound),
  )
  let path = priv <> "/seed/base_seed.sql"
  use body <- result.map(
    simplifile.read(path) |> result.map_error(SeedReadError),
  )
  migrate.split_statements(body)
}

/// Apply every seed statement in one transaction, so a failure rolls the whole
/// seed back and leaves an empty DB rather than a partially-seeded one.
fn apply_seed(
  db: pog.Connection,
  statements: List(String),
) -> Result(Nil, SeedError) {
  let outcome =
    pog.transaction(db, fn(conn) {
      use _ <- result.try(execute_each(conn, statements))
      Ok(Nil)
    })
  case outcome {
    Ok(_) -> Ok(Nil)
    Error(pog.TransactionRolledBack(error)) -> Error(error)
    Error(pog.TransactionQueryError(error)) -> Error(SeedApplyFailed(error))
  }
}

/// Execute each statement against the open transaction, stopping at the first
/// failure.
fn execute_each(
  conn: pog.Connection,
  statements: List(String),
) -> Result(Nil, SeedError) {
  use statement <- list_try_each(statements)
  pog.query(statement)
  |> pog.execute(on: conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(SeedApplyFailed)
}

fn list_try_each(
  items: List(a),
  apply: fn(a) -> Result(Nil, SeedError),
) -> Result(Nil, SeedError) {
  case items {
    [] -> Ok(Nil)
    [first, ..rest] -> {
      use _ <- result.try(apply(first))
      list_try_each(rest, apply)
    }
  }
}
