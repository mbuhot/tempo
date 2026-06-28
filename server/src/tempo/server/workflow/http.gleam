//// Web: the `/api/workflows` API for draft mutations and reads. These are NOT
//// journaled commands — they autosave draft state — so they bypass the operations
//// pipeline and write directly on the pooled connection, gated only by an
//// authenticated principal. The final commit is a journaled command and goes
//// through POST /api/operations instead. Owner/assignee scoping rides in the rows:
//// reads resolve `assignee_is_me` for the caller, and the resume list is keyed to
//// the caller's account.

import gleam/dynamic/decode.{type Decoder}
import gleam/http
import gleam/json
import gleam/option.{None, Some}
import shared/workflow/schema as wschema
import shared/workflow/value.{type FieldValue}
import shared/workflow/view
import tempo/server/auth.{type Principal}
import tempo/server/context.{type Context}
import tempo/server/operation.{type OperationError, DatabaseError, InvalidValue}
import tempo/server/web/guard
import tempo/server/web/response
import tempo/server/workflow/instance
import tempo/server/workflow/schema as flow
import wisp

/// GET /api/workflows — the caller's resumable drafts; POST /api/workflows — start
/// a new draft of `{kind}`, returning `{instance_id}`.
pub fn handle_collection(req: wisp.Request, ctx: Context) -> wisp.Response {
  use principal <- guard.authenticated(ctx)
  case req.method {
    http.Get -> list_response(ctx, principal)
    http.Post -> {
      use body <- wisp.require_json(req)
      case decode.run(body, start_decoder()) {
        Ok(kind) -> start_response(ctx, principal, kind)
        Error(_) ->
          response.error_response(400, "invalid_body", "expected {kind}")
      }
    }
    _ -> response.error_response(405, "method_not_allowed", "use GET or POST")
  }
}

/// GET /api/workflows/schema/:kind — the schema the client renders.
pub fn handle_schema(
  req: wisp.Request,
  ctx: Context,
  kind: String,
) -> wisp.Response {
  use _ <- guard.authenticated(ctx)
  use <- wisp.require_method(req, http.Get)
  case kind == flow.kind {
    True -> response.json_response(wschema.encode_schema(flow.onboard_schema()))
    False -> wisp.not_found()
  }
}

/// GET /api/workflows/:id — the draft view for the caller, 404 if no such instance.
pub fn handle_instance(
  req: wisp.Request,
  ctx: Context,
  id: String,
) -> wisp.Response {
  use principal <- guard.authenticated(ctx)
  use <- wisp.require_method(req, http.Get)
  case instance.draft_view(ctx.db, id, principal.account_id) {
    Ok(Some(draft)) -> response.json_response(view.encode_draft(draft))
    Ok(None) -> wisp.not_found()
    Error(error) -> error_response(error)
  }
}

/// POST /api/workflows/:id/:action — a draft mutation: field | step | handoff |
/// cancel.
pub fn handle_action(
  req: wisp.Request,
  ctx: Context,
  id: String,
  action: String,
) -> wisp.Response {
  use _ <- guard.authenticated(ctx)
  use <- wisp.require_method(req, http.Post)
  case action {
    "field" -> save_field_action(req, ctx, id)
    "step" -> complete_step_action(req, ctx, id)
    "handoff" -> hand_off_action(req, ctx, id)
    "cancel" -> void_response(instance.cancel(ctx.db, id))
    _ -> wisp.not_found()
  }
}

fn save_field_action(
  req: wisp.Request,
  ctx: Context,
  id: String,
) -> wisp.Response {
  use body <- wisp.require_json(req)
  case decode.run(body, field_decoder()) {
    Ok(#(step, field, field_value)) ->
      void_response(instance.save_field(
        ctx.db,
        id,
        step,
        field,
        value.encode(field_value),
      ))
    Error(_) ->
      response.error_response(
        400,
        "invalid_body",
        "expected {step, field, value}",
      )
  }
}

fn complete_step_action(
  req: wisp.Request,
  ctx: Context,
  id: String,
) -> wisp.Response {
  use body <- wisp.require_json(req)
  case decode.run(body, next_step_decoder()) {
    Ok(next_step) ->
      void_response(instance.complete_step(ctx.db, id, next_step))
    Error(_) ->
      response.error_response(400, "invalid_body", "expected {next_step}")
  }
}

fn hand_off_action(
  req: wisp.Request,
  ctx: Context,
  id: String,
) -> wisp.Response {
  use body <- wisp.require_json(req)
  case decode.run(body, assignee_decoder()) {
    Ok(assignee_id) -> void_response(instance.hand_off(ctx.db, id, assignee_id))
    Error(_) ->
      response.error_response(400, "invalid_body", "expected {assignee_id}")
  }
}

fn list_response(ctx: Context, principal: Principal) -> wisp.Response {
  case instance.list_for(ctx.db, principal.account_id) {
    Ok(summaries) -> response.json_response(view.encode_summaries(summaries))
    Error(error) -> error_response(error)
  }
}

fn start_response(
  ctx: Context,
  principal: Principal,
  kind: String,
) -> wisp.Response {
  case kind == flow.kind {
    False ->
      response.error_response(400, "unknown_kind", "unknown workflow kind")
    True ->
      case
        instance.start(ctx.db, flow.kind, principal.account_id, flow.first_step)
      {
        Ok(id) ->
          response.json_response(
            json.object([#("instance_id", json.string(id))]),
          )
        Error(error) -> error_response(error)
      }
  }
}

fn void_response(result: Result(Nil, OperationError)) -> wisp.Response {
  case result {
    Ok(_) -> response.json_response(json.object([]))
    Error(error) -> error_response(error)
  }
}

fn error_response(error: OperationError) -> wisp.Response {
  case error {
    InvalidValue ->
      response.error_response(422, "invalid_value", "a draft value is invalid")
    DatabaseError(query_error) -> response.db_error_response(query_error)
    _ -> response.error_response(500, "error", "the draft operation failed")
  }
}

fn start_decoder() -> Decoder(String) {
  use kind <- decode.field("kind", decode.string)
  decode.success(kind)
}

fn field_decoder() -> Decoder(#(String, String, FieldValue)) {
  use step <- decode.field("step", decode.string)
  use field <- decode.field("field", decode.string)
  use field_value <- decode.field("value", value.decoder())
  decode.success(#(step, field, field_value))
}

fn next_step_decoder() -> Decoder(String) {
  use next_step <- decode.field("next_step", decode.string)
  decode.success(next_step)
}

fn assignee_decoder() -> Decoder(Int) {
  use assignee_id <- decode.field("assignee_id", decode.int)
  decode.success(assignee_id)
}
