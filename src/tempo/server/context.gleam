//// Target: Erlang only — the pog connection pool shared across request handlers.

import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/result
import pog

/// Application context threaded through every Wisp handler. Holds the live
/// `pog` connection that handlers run queries against.
pub type Context {
  Context(db: pog.Connection)
}

/// Database connection settings, parsed from the environment (with dev
/// defaults). Kept separate from `start` so configuration is a pure value that
/// can be inspected and tested without opening a socket.
pub type DbSettings {
  DbSettings(
    host: String,
    port: Int,
    database: String,
    user: String,
    password: Option(String),
    pool_size: Int,
  )
}

/// Read database settings from the environment, falling back to the
/// `docker-compose.yml` dev defaults (host port 5434, user/db/password "tempo").
///
/// Recognised variables: `TEMPO_DB_HOST`, `TEMPO_DB_PORT`, `TEMPO_DB_NAME`,
/// `TEMPO_DB_USER`, `TEMPO_DB_PASSWORD`, `TEMPO_DB_POOL_SIZE`.
pub fn settings_from_env() -> DbSettings {
  DbSettings(
    host: env_string("TEMPO_DB_HOST", "127.0.0.1"),
    port: env_int("TEMPO_DB_PORT", 5434),
    database: env_string("TEMPO_DB_NAME", "tempo"),
    user: env_string("TEMPO_DB_USER", "tempo"),
    password: Some(env_string("TEMPO_DB_PASSWORD", "tempo")),
    pool_size: env_int("TEMPO_DB_POOL_SIZE", 10),
  )
}

/// Turn settings into a `pog.Config` bound to the given pool name. The pool name
/// lets the same pool be addressed by `pog.named_connection` from elsewhere.
pub fn pool_config(
  settings: DbSettings,
  pool_name: process.Name(pog.Message),
) -> pog.Config {
  pog.default_config(pool_name:)
  |> pog.host(settings.host)
  |> pog.port(settings.port)
  |> pog.database(settings.database)
  |> pog.user(settings.user)
  |> pog.password(settings.password)
  |> pog.pool_size(settings.pool_size)
}

/// Start the pog pool from environment-derived settings and build the context.
///
/// Returns an error if the supervision tree for the pool fails to start.
pub fn start() -> Result(Context, actor.StartError) {
  let pool_name = process.new_name(prefix: "tempo_db")
  let config = pool_config(settings_from_env(), pool_name)
  use started <- result.map(pog.start(config))
  Context(db: started.data)
}

/// Run `SELECT 1` against the pool to confirm a live PG19 connection. Returns
/// the integer the database echoed back (always `1` on success).
pub fn smoke_check(db: pog.Connection) -> Result(Int, pog.QueryError) {
  let row_decoder = {
    use value <- decode.field(0, decode.int)
    decode.success(value)
  }
  use returned <- result.map(
    pog.query("SELECT 1")
    |> pog.returning(row_decoder)
    |> pog.execute(on: db),
  )
  case returned.rows {
    [value, ..] -> value
    [] -> 0
  }
}

fn env_string(name: String, default: String) -> String {
  case envoy.get(name) {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

fn env_int(name: String, default: Int) -> Int {
  case envoy.get(name) {
    Ok(value) ->
      case int.parse(value) {
        Ok(parsed) -> parsed
        Error(Nil) -> default
      }
    Error(Nil) -> default
  }
}
