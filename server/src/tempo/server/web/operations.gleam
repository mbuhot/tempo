//// Web: POST /api/operations handler. Decodes the shared `OperationRequest`
//// envelope (`{actor, command}`), dispatches the command through the domain, and
//// maps the typed result to HTTP. Imports `wisp` (it owns the HTTP shape) but
//// never `sql` — it reaches the database only through the domain `command`
//// module, which already speaks shared types.
////
//// On success `dispatch` returns the single journal event it appended inside its
//// own transaction (with its minted id/occurred_at); the handler returns that
//// created event in a one-element JSON array — the authoritative record of what
//// was written, and the stable wire shape the client decodes (it also refetches
//// /api/events). A malformed body is a 400; a rejected
//// operation maps by its `OperationError`: `ContainmentViolated`/`OverlappingFact`
//// → 409, `InvalidValue`/`InsufficientLeaveBalance` → 422, `DatabaseError` → 500.

import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/int
import gleam/json
import shared/codecs
import shared/types.{type Event, type OperationRequest}
import tempo/server/command
import tempo/server/context.{type Context}
import tempo/server/operation.{
  type OperationError, ContainmentViolated, DatabaseError,
  InsufficientLeaveBalance, InvalidValue, NoSuchVersion, OverlappingFact,
}
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
    Ok(event) -> created_event_response(event)
    Error(error) -> error_response(error)
  }
}

/// On success, return the event the operation just appended as a single-element
/// JSON array — it carries its minted id/occurred_at, so this is exactly what was
/// written (no race with a concurrent writer's newest row). The array shape is
/// the stable wire contract the client decodes, even though a command appends
/// exactly one event.
fn created_event_response(event: Event) -> wisp.Response {
  response.json_response(json.array([event], codecs.encode_event))
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
    NoSuchVersion ->
      response.error_response(
        422,
        "no_such_version",
        "no version covers the effective date for the level being revised",
      )
    InsufficientLeaveBalance(kind:, available:, requested:) ->
      response.error_response(
        422,
        "insufficient_leave_balance",
        "insufficient "
          <> kind
          <> " leave balance: "
          <> float.to_string(float.to_precision(available, 1))
          <> " days available on return, "
          <> int.to_string(float.round(requested))
          <> " requested",
      )
    DatabaseError(_) -> wisp.internal_server_error()
  }
}
