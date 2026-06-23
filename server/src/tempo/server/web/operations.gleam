//// Web: POST /api/operations handler. AUTHENTICATES the request (a signed session
//// cookie), derives the `Principal` from it — never the body (issue #6) —, decodes
//// the shared `OperationRequest` envelope (`{command}`), dispatches the command
//// through the domain on that principal's behalf, and maps the typed result to
//// HTTP. Imports `wisp` (it owns the HTTP shape) but never `sql` — it reaches the
//// database only through the domain `command` module, which already speaks shared
//// types.
////
//// An unauthenticated or invalid-session request is a 401 (no command runs). On
//// success `dispatch` returns the single journal event it appended inside its own
//// transaction (with its minted id/occurred_at); the handler returns that created
//// event in a one-element JSON array — the authoritative record of what was
//// written, and the stable wire shape the client decodes (it also refetches
//// /api/events). A malformed body is a 400; a rejected operation maps by its
//// `OperationError`: `Unauthorized` → 403, `ContainmentViolated`/`OverlappingFact`
//// → 409, `InvalidValue`/`InsufficientLeaveBalance` → 422, `DatabaseError` → 500
//// (503 when the cause is a saturated connection pool).

import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/int
import gleam/json
import shared/codecs
import shared/types.{type Event, type OperationRequest}
import tempo/server/auth.{type Principal}
import tempo/server/command
import tempo/server/context.{type Context}
import tempo/server/operation.{
  type OperationError, ContainmentViolated, DatabaseError,
  InsufficientLeaveBalance, InvalidValue, NoSuchVersion, OverlappingFact,
  Unauthorized,
}
import tempo/server/web/response
import tempo/server/web/session
import wisp

/// Handle POST /api/operations — apply a domain command on the AUTHENTICATED
/// principal's behalf.
///
/// Authenticate first: a missing/invalid session is a 401 and no command runs.
/// Then decode the `{command}` envelope, run the domain dispatch keyed on the
/// session-derived principal (which also stamps the journal actor), encode the
/// outcome. A malformed body is a 400; a rejected operation maps by its typed
/// `OperationError` to the matching 4xx/5xx.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case session.principal(req) {
    Error(Nil) ->
      response.error_response(
        401,
        "unauthenticated",
        "sign in before applying an operation",
      )
    Ok(principal) -> authenticated(req, ctx, principal)
  }
}

fn authenticated(
  req: wisp.Request,
  ctx: Context,
  principal: Principal,
) -> wisp.Response {
  use body <- wisp.require_json(req)
  case decode.run(body, codecs.operation_request_decoder()) {
    Error(_) ->
      response.error_response(400, "invalid_body", "expected {command}")
    Ok(request) -> dispatch(ctx, principal, request)
  }
}

fn dispatch(
  ctx: Context,
  principal: Principal,
  request: OperationRequest,
) -> wisp.Response {
  case command.dispatch(ctx, principal:, command: request.command) {
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
    Unauthorized(actor:, command:) ->
      response.error_response(
        403,
        "unauthorized",
        actor <> " is not permitted to run " <> command,
      )
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
    DatabaseError(error) -> response.db_error_response(error)
  }
}
