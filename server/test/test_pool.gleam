//// One pog connection pool shared across the whole test suite. `start()` runs
//// once (before any test) from `tempo_test.main`, opening a single right-sized
//// pool under a fixed name. Every test then addresses that one pool via
//// `db()`/`ctx()`, so the concurrent gleeunit runner no longer opens a pool per
//// test (which summed past PG's `max_connections`).
////
//// The shared name is a fixed atom built directly with `erlang:binary_to_atom`
//// and typed as `process.Name(pog.Message)`: a `process.Name` is a registered
//// atom under the hood, so `start` and `db` independently derive the SAME name
//// from one string — no run-time storage needed (unlike `process.new_name`,
//// whose random suffix differs on every call).

import gleam/erlang/process
import gleam/option.{None}
import pog
import tempo/server/context

/// A `process.Name` is internally a registered atom; building one directly from
/// a constant string yields a stable, shareable pool name.
pub type DbPoolName =
  process.Name(pog.Message)

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: String) -> DbPoolName

fn pool_name() -> DbPoolName {
  binary_to_atom("tempo_test_db_pool")
}

/// Open the single shared pool under the fixed name. Call once, before any test
/// runs — `pog.start` brings up the supervised pool registered under the name.
pub fn start() -> Nil {
  let config =
    context.pool_config(context.settings_from_env(), pool_name())
    |> pog.pool_size(20)
  let assert Ok(_) = pog.start(config)
  Nil
}

/// A connection to the shared pool (must call `start` first).
pub fn db() -> pog.Connection {
  pog.named_connection(pool_name())
}

/// A `Context` wrapping the shared pool, with no principal (an unauthenticated
/// context — tests that drive an authenticated route inject one).
pub fn ctx() -> context.Context {
  context.Context(db(), None)
}
