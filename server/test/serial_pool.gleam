//// A third, isolated pog pool for read tests whose subject COMMITS and fans its
//// independent queries out concurrently (e.g. `pnl/view.pnl`). A fan-out spawns
//// linked processes that each check a connection out of the pool, so it cannot run
//// against a rolled-back single-connection `pog.transaction` fixture — the spawned
//// children cannot share that one in-transaction connection. These tests therefore
//// COMMIT their writes against a dedicated database (`tempo_serial`) and read them
//// back through the pool, exactly as the real handlers do.
////
//// Because the database is committed and reset between tests, its users must run
//// serially even though gleeunit runs tests concurrently. `run/1` takes an Erlang
//// `:global` lock around each body so only one serial test touches the database at
//// a time; waiters block inside `:global` holding NO connection, and `:global`
//// auto-releases a held lock if its requester process dies, so a panicking test
//// cannot wedge the lock. `reset/0` truncates every table (except the migration
//// tracker) and re-seeds the base cast, so each body starts from the same slate.
////
//// Like the other pools, the name is a fixed atom built from a constant string so
//// `start`/`db` independently derive the SAME `process.Name`.

import gleam/erlang/process.{type Pid}
import gleam/option.{None}
import pog
import tempo/seed
import tempo/server/context.{type DbSettings, DbSettings}

const database_name = "tempo_serial"

/// A `process.Name` is internally a registered atom; building one from a constant
/// string yields a stable, shareable pool name.
pub type DbPoolName =
  process.Name(pog.Message)

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: String) -> DbPoolName

fn pool_name() -> DbPoolName {
  binary_to_atom("tempo_serial_db_pool")
}

/// A `:global` lock id: the shared ResourceId names the mutex, the requester `Pid`
/// is the lock holder. Mutual exclusion is on the ResourceId, so distinct test
/// processes contend; a held lock auto-releases when its holder dies.
type LockId =
  #(String, Pid)

@external(erlang, "global", "set_lock")
fn global_set_lock(id: LockId) -> Bool

@external(erlang, "global", "del_lock")
fn global_del_lock(id: LockId) -> Bool

fn lock_id() -> LockId {
  #("tempo_serial_lock", process.self())
}

/// Recreate the dedicated database, migrate it, seed it, and open its pool. Call
/// once, before any serial test runs (from `tempo_test.main`).
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

/// Serialize `body` against the committed database: take the shared `:global` lock
/// (blocking until acquired), reset to the base seed, run `body` against the POOL
/// (so its writes commit and its fan-out reads work), then release the lock and
/// return the body's value.
pub fn run(body: fn(context.Context) -> a) -> a {
  let _ = global_set_lock(lock_id())
  reset()
  let result = body(ctx())
  let _ = global_del_lock(lock_id())
  result
}

/// Truncate every table (RESTART IDENTITY CASCADE) except the migration tracker,
/// then re-apply the base seed. `seed.run` is a no-op on an already-seeded DB
/// (engineer rows present), but after the truncate the cast is gone, so it
/// repopulates the base cast in full.
pub fn reset() -> Nil {
  let assert Ok(_) = pog.query(truncate_all) |> pog.execute(on: db())
  let assert Ok(seed.Seeded) = seed.run(ctx(), "dev")
  Nil
}

const truncate_all = "DO $$ DECLARE r RECORD; BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename <> 'schema_migrations'
  LOOP EXECUTE 'TRUNCATE TABLE ' || quote_ident(r.tablename) || ' RESTART IDENTITY CASCADE'; END LOOP;
END $$;"

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
  let admin_name = binary_to_atom("tempo_serial_admin_pool")
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
/// via a short-lived pool. `seed.run` migrates first, then seeds the empty DB.
fn migrate_and_seed_database() -> Nil {
  let migrate_name = binary_to_atom("tempo_serial_migrate_pool")
  let assert Ok(started) =
    pog.start(context.pool_config(settings(), migrate_name) |> pog.pool_size(1))
  let assert Ok(seed.Seeded) =
    seed.run(context.Context(started.data, None), "dev")
  Nil
}
