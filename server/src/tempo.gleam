//// Server entrypoint (`gleam run`); boots the Wisp server with the pog pool.
////
//// Starts the pog pool (context.gleam), wires it into the router, and serves the
//// JSON API + static assets over mist. The process then sleeps forever so the
//// supervision tree stays up.

import gleam/erlang/process
import gleam/int
import mist
import tempo/server/context
import tempo/server/web/router
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()

  let assert Ok(ctx) = context.start()
  let secret_key_base = secret_key_base()
  let port = 8000

  let handler = fn(request) { router.handle_request(request, ctx) }

  let assert Ok(_) =
    handler
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.bind("0.0.0.0")
    |> mist.start

  wisp.log_info("tempo listening on http://0.0.0.0:" <> int.to_string(port))
  process.sleep_forever()
}

/// The secret key base used to sign session cookies (issue #6). Read from
/// `TEMPO_SECRET_KEY_BASE` when set, so sessions survive a restart and verify
/// across multiple instances; otherwise a fresh random key per boot — fine for
/// dev (a restart simply forces re-login), but a deployment must set the env var.
fn secret_key_base() -> String {
  context.env_string("TEMPO_SECRET_KEY_BASE", wisp.random_string(64))
}
