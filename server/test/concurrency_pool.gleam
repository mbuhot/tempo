//// A second, isolated pog pool for the two-connection concurrency tests (issue
//// #2). Those tests must COMMIT — the read-modify-write race only exists across
//// committed transactions — so they cannot run against the shared seed pool
//// (`test_pool`), whose other tests read globally-committed tables (`event_log`,
//// `leave`) inside their own concurrent transactions and would see the committed
//// fixtures. `start()` therefore drops and recreates a dedicated database
//// (`tempo_concurrency`), migrates the same schema + seed into it, and opens a
//// pool named for it; the concurrency tests own that database outright.
////
//// Like `test_pool`, the pool name is a fixed atom built from a constant string so
//// `start` and `db` independently derive the SAME `process.Name`.

import gleam/erlang/process
import gleam/option.{None}
import pog
import tempo/seed
import tempo/server/context.{type DbSettings, DbSettings}

const database_name = "tempo_concurrency"

/// A `process.Name` is internally a registered atom; building one from a constant
/// string yields a stable, shareable pool name.
pub type DbPoolName =
  process.Name(pog.Message)

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: String) -> DbPoolName

fn pool_name() -> DbPoolName {
  binary_to_atom("tempo_concurrency_db_pool")
}

/// Recreate the dedicated database, migrate it, and open its pool. Call once,
/// before any concurrency test runs (from `tempo_test.main`).
pub fn start() -> Nil {
  recreate_database()
  migrate_and_seed_database()
  let assert Ok(_) =
    pog.start(context.pool_config(settings(), pool_name()) |> pog.pool_size(10))
  Nil
}

/// A connection to the dedicated pool (must call `start` first).
pub fn db() -> pog.Connection {
  pog.named_connection(pool_name())
}

/// A `Context` wrapping the dedicated pool.
pub fn ctx() -> context.Context {
  context.Context(db(), None)
}

/// The base settings with the database swapped to the dedicated one.
fn settings() -> DbSettings {
  let DbSettings(host:, port:, user:, password:, pool_size:, ..) =
    context.settings_from_env()
  DbSettings(
    host:,
    port:,
    database: database_name,
    user:,
    password:,
    pool_size:,
  )
}

/// Drop and recreate the dedicated database via a short-lived maintenance pool on
/// the server's default `postgres` database (CREATE/DROP DATABASE cannot run
/// inside a transaction, so these execute autocommit on a pooled connection).
fn recreate_database() -> Nil {
  let DbSettings(host:, port:, user:, password:, pool_size:, ..) =
    context.settings_from_env()
  let maintenance =
    DbSettings(host:, port:, database: "postgres", user:, password:, pool_size:)
  let admin_name = binary_to_atom("tempo_concurrency_admin_pool")
  let assert Ok(started) =
    pog.start(context.pool_config(maintenance, admin_name) |> pog.pool_size(1))
  let admin = started.data
  let assert Ok(_) =
    pog.query("DROP DATABASE IF EXISTS " <> database_name <> " WITH (FORCE)")
    |> pog.execute(on: admin)
  let assert Ok(_) =
    pog.query("CREATE DATABASE " <> database_name) |> pog.execute(on: admin)
  Nil
}

/// Migrate the schema and apply the base seed into the freshly-created database
/// via a short-lived pool, so the dedicated database carries the same fixtures as
/// the shared one. `seed.run` migrates first, then seeds the empty DB (dev env).
fn migrate_and_seed_database() -> Nil {
  let migrate_name = binary_to_atom("tempo_concurrency_migrate_pool")
  let assert Ok(started) =
    pog.start(context.pool_config(settings(), migrate_name) |> pog.pool_size(1))
  let assert Ok(seed.Seeded) =
    seed.run(context.Context(started.data, None), "dev")
  Nil
}
