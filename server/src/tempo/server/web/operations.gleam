//// Web: POST /api/operations handler. Decodes the shared `OperationRequest`
//// envelope (`{actor, command}`), dispatches the command through the domain, and
//// maps the typed result to HTTP. Imports `wisp` (it owns the HTTP shape) but
//// never `sql` — it reaches the database only through the domain `command` /
//// `event` modules, which already speak shared types.
////
//// On success the operation appended exactly one `event_log` row inside the
//// dispatch transaction; the handler returns that newly-created event as JSON
//// (the newest journal row, fetched back through the domain). A malformed body
//// is a 400; a rejected operation maps by its `OperationError` (ARCHITECTURE §5a):
//// `ContainmentViolated`/`OverlappingFact` → 409, `InvalidValue` → 422,
//// `DatabaseError` → 500.

import gleam/dynamic/decode
import gleam/http
import shared/codecs
import shared/types.{type OperationRequest}
import tempo/server/command.{
  type OperationError, ContainmentViolated, DatabaseError, InvalidValue,
  OverlappingFact,
}
import tempo/server/context.{type Context}
import tempo/server/event
import tempo/server/web/response
import wisp

/// Handle POST /api/operations — apply a domain command on an actor's behalf.
///
/// Thin handler (task spec Notes): decode the `{actor, command}` envelope, run
/// the domain dispatch, encode the outcome. A malformed body is a 400; a rejected
/// operation maps by its typed `OperationError` to the matching 4xx/5xx.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use body <- wisp.require_json(req)
  case decode.run(body, codecs.operation_request_decoder()) {
    Error(_) ->
      response.error_response(400, "invalid_body", "expected {actor, command}")
    Ok(request) -> dispatch(ctx, request)
  }
}

fn dispatch(ctx: Context, request: OperationRequest) -> wisp.Response {
  case command.dispatch(ctx, actor: request.actor, command: request.command) {
    Ok(Nil) -> created_event_response(ctx)
    Error(error) -> error_response(error)
  }
}

/// On success, return the event the operation just appended — the newest journal
/// row (`event.list` is newest-first). If the journal read fails after a
/// committed write, surface a 500 rather than a misleading success.
fn created_event_response(ctx: Context) -> wisp.Response {
  case event.list(ctx) {
    Ok([newest, ..]) -> response.json_response(codecs.encode_event(newest))
    Ok([]) -> wisp.internal_server_error()
    Error(_) -> wisp.internal_server_error()
  }
}

/// Map a typed `OperationError` to its HTTP status and a small JSON error body
/// (ARCHITECTURE §5a): a containment PERIOD-FK or `WITHOUT OVERLAPS` violation is
/// a 409 conflict, a `CHECK` violation is a 422, anything else is a 500.
fn error_response(error: OperationError) -> wisp.Response {
  case error {
    ContainmentViolated(which:) ->
      response.error_response(
        409,
        "containment_violated",
        "the operation would place a fact outside its containing fact ("
          <> which
          <> ")",
      )
    OverlappingFact ->
      response.error_response(
        409,
        "overlapping_fact",
        "the operation overlaps an existing fact for the same key",
      )
    InvalidValue ->
      response.error_response(
        422,
        "invalid_value",
        "a value is out of range (fraction, level, or hours)",
      )
    DatabaseError(_) -> wisp.internal_server_error()
  }
}
