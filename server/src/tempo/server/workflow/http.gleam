//// Web: the `/api/workflows` API for draft mutations and reads. These are NOT
//// journaled commands — they autosave draft state — so they bypass the operations
//// pipeline and write directly on the pooled connection, gated only by an
//// authenticated principal. The final commit is a journaled command and goes
//// through POST /api/operations instead. Scoping rides in the rows: a draft belongs
//// to its owner, and once it is awaiting Finance anyone holding the commit permission
//// can see it (the shared queue) — `can_act` and the resume list reflect that.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/http
import gleam/json
import gleam/option.{None, Some}
import shared/access
import shared/workflow/kind as wkind
import shared/workflow/schema as wschema
import shared/workflow/value.{type FieldValue}
import shared/workflow/view
import tempo/server/auth.{type Principal}
import tempo/server/context.{type Context}
import tempo/server/operation.{type OperationError, DatabaseError, InvalidValue}
import tempo/server/web/guard
import tempo/server/web/response
import tempo/server/workflow/instance
import tempo/server/workflow/registry
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
  case registry.schema_for(kind, ctx) {
    Ok(schema) -> response.json_response(wschema.encode_schema(schema))
    Error(_) -> wisp.not_found()
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
  case instance.load(ctx.db, id) {
    Ok(None) -> wisp.not_found()
    Error(error) -> error_response(error)
    Ok(Some(found)) ->
      case registry.schema_for(wkind.to_string(found.kind), ctx) {
        Error(_) -> wisp.not_found()
        Ok(schema) -> {
          let ids = registry.step_ids(schema)
          case
            instance.draft_view(
              ctx.db,
              found,
              principal.account_id,
              can_commit(principal),
              ids,
            )
          {
            Ok(draft) -> response.json_response(view.encode_draft(draft))
            Error(error) -> error_response(error)
          }
        }
      }
  }
}

/// POST /api/workflows/:id/:action — a draft mutation: values | step | handoff |
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
    "values" -> save_values_action(req, ctx, id)
    "step" -> complete_step_action(req, ctx, id)
    "handoff" -> handoff_action(ctx, id)
    "cancel" -> void_response(instance.cancel(ctx.db, id))
    _ -> wisp.not_found()
  }
}

fn save_values_action(
  req: wisp.Request,
  ctx: Context,
  id: String,
) -> wisp.Response {
  use body <- wisp.require_json(req)
  case decode.run(body, step_values_decoder()) {
    Ok(#(step, step_values)) ->
      void_response(instance.save_step(ctx.db, id, step, step_values))
    Error(_) ->
      response.error_response(400, "invalid_body", "expected {step, values}")
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

fn list_response(ctx: Context, principal: Principal) -> wisp.Response {
  case instance.list_for(ctx.db, principal.account_id, can_commit(principal)) {
    Ok(summaries) -> response.json_response(view.encode_summaries(summaries))
    Error(error) -> error_response(error)
  }
}

/// Whether the principal holds any workflow's commit permission — the gate for
/// SEEING a draft that is awaiting a commit-holder in the resume queue. This is
/// queue visibility only; the per-instance authority is enforced at commit time by
/// the command access policy (each workflow command maps to its own permission).
fn can_commit(principal: Principal) -> Bool {
  auth.can(principal, access.engineer_onboard_commit)
  || auth.can(principal, access.project_create_confirm)
}

fn start_response(
  ctx: Context,
  principal: Principal,
  kind: String,
) -> wisp.Response {
  case registry.schema_for(kind, ctx) {
    Error(_) ->
      response.error_response(400, "unknown_kind", "unknown workflow kind")
    Ok(schema) -> {
      let assert Ok(workflow_kind) = wkind.from_string(kind)
      case
        instance.start(
          ctx.db,
          workflow_kind,
          principal.account_id,
          registry.first_step(schema),
        )
      {
        Ok(id) ->
          response.json_response(
            json.object([#("instance_id", json.string(id))]),
          )
        Error(error) -> error_response(error)
      }
    }
  }
}

fn handoff_action(ctx: Context, id: String) -> wisp.Response {
  case instance.load(ctx.db, id) {
    Ok(Some(found)) ->
      case registry.schema_for(wkind.to_string(found.kind), ctx) {
        Ok(schema) ->
          void_response(instance.hand_off(
            ctx.db,
            id,
            registry.finance_step(schema),
          ))
        Error(_) -> wisp.not_found()
      }
    Ok(None) -> wisp.not_found()
    Error(error) -> error_response(error)
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

fn step_values_decoder() -> Decoder(#(String, dict.Dict(String, FieldValue))) {
  use step <- decode.field("step", decode.string)
  use step_values <- decode.field("values", value.step_decoder())
  decode.success(#(step, step_values))
}

fn next_step_decoder() -> Decoder(String) {
  use next_step <- decode.field("next_step", decode.string)
  decode.success(next_step)
}
