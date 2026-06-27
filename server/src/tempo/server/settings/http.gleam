//// Web: GET /api/settings?as_of= handler — the rate card, salaries, and leave
//// policy in force as of a date. Parse the as-of date, call the domain, encode the
//// result. Imports `wisp` (it owns the HTTP shape) but never `sql` — it talks to
//// the domain `settings` module, which already speaks shared types.
////
//// A missing/malformed `as_of` is a 400; a database failure is a 500.

import gleam/http
import shared/settings/view as settings_view
import shared/table/query.{Applied}
import shared/table/response as table_response
import tempo/server/context.{type Context}
import tempo/server/settings/table as settings_table
import tempo/server/settings/view as settings
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/settings?as_of=YYYY-MM-DD — the current rate card, salaries, and
/// leave policy as of the date.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case settings.read(ctx, as_of) {
        Ok(settings) ->
          response.json_response(settings_view.encode_settings(settings))
        Error(error) -> response.db_error_response(error)
      }
  }
}

/// Handle GET /api/settings/rate-card/table?as_of=&filter.*= — the rate-card &
/// salary-bands generic data-table read: the schema plus one row per level (level
/// band, day rate, monthly salary, and the per-row actions the principal may
/// perform), narrowed by the `level` filter. A missing/malformed `as_of` is a 400;
/// a database failure is a 500.
pub fn handle_rate_card_table(
  req: wisp.Request,
  ctx: Context,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) -> {
      let applied =
        query.from_params(
          wisp.get_query(req),
          settings_table.rate_card_filter_schema(),
          context.default_page_limit,
        )
      let clamped =
        Applied(..applied, page_size: context.clamp_limit(applied.page_size))
      case settings_table.rate_card_table(ctx, as_of, clamped) {
        Ok(table) ->
          response.json_response(table_response.encode_response(table))
        Error(error) -> response.db_error_response(error)
      }
    }
  }
}

/// Handle GET /api/settings/leave-policy/table?as_of=&filter.*= — the read-only
/// leave-policy generic data-table read: the schema plus one row per policy line
/// (leave kind, level band, days-per-year), narrowed by the `level` and `kind`
/// filters. A missing/malformed `as_of` is a 400; a database failure is a 500.
pub fn handle_leave_policy_table(
  req: wisp.Request,
  ctx: Context,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) -> {
      let applied =
        query.from_params(
          wisp.get_query(req),
          settings_table.leave_policy_filter_schema(),
          context.default_page_limit,
        )
      let clamped =
        Applied(..applied, page_size: context.clamp_limit(applied.page_size))
      case settings_table.leave_policy_table(ctx, as_of, clamped) {
        Ok(table) ->
          response.json_response(table_response.encode_response(table))
        Error(error) -> response.db_error_response(error)
      }
    }
  }
}
