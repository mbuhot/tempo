//// The page-side glue for the generic data table: the load state, the fetch /
//// fetch-more wiring, and the mapping of every `table.Outcome` to an effect
//// (re-query, append the next page for infinite scroll, persist the column layout,
//// debounce-settle a typed filter, or activate a row). A list page embeds one
//// `Host`, forwards its `Msg`, and only routes `Out.Activated(id)` to its own
//// navigation — the infinite scroll, debounce, and layout persistence live here
//// once, shared across every table-backed page.

import client/api
import client/scheduler
import client/storage
import client/table
import client/time
import client/ui
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import gleam/uri
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import rsvp
import shared/table/column
import shared/table/response.{type Footer, type Row, type TableResponse}

/// A table embedded in a page: the API endpoint that answers `{schema, rows, page}`,
/// the fixed `base` query params prepended to every request (e.g. `as_of`, or a
/// `from`/`to` window), and the current load state.
pub type Host {
  Host(endpoint: String, base: List(#(String, String)), load: Load)
}

/// The table's load state. `Loaded` holds the server schema, the rows accumulated
/// across infinite-scroll pages, the opaque `next_cursor` for the following page,
/// and the local table view state (sort/filters/column layout).
pub type Load {
  Loading
  Loaded(
    schema: column.Schema,
    rows: List(Row),
    next_cursor: Option(String),
    table_state: table.State,
    footer: Option(Footer),
  )
  Failed(message: String)
}

pub type Msg {
  Got(as_of: calendar.Date, result: Result(TableResponse, rsvp.Error(String)))
  GotMore(
    as_of: calendar.Date,
    result: Result(TableResponse, rsvp.Error(String)),
  )
  TableMsg(sub: table.Msg)
}

/// What the host hands back to the page after an update: usually `Stay`, or
/// `Activated(id)` when a row was clicked (the page maps the id to its own route).
pub type Out {
  Stay
  Activated(id: String)
  ActionInvoked(action: String, row: String)
}

/// Start a table against `endpoint`, fetching the first (bounded) page as-of `as_of`.
/// A thin wrapper over `init_with` that fixes the `as_of` base param.
pub fn init(endpoint: String, as_of: calendar.Date) -> #(Host, Effect(Msg)) {
  init_with(endpoint, [#("as_of", time.iso_date(as_of))], as_of)
}

/// Start a table against `endpoint` with explicit fixed `base` query params (e.g. a
/// `from`/`to` window) prepended to every request. `as_of` is still carried through
/// the fetch so a stale reply is dropped.
pub fn init_with(
  endpoint: String,
  base: List(#(String, String)),
  as_of: calendar.Date,
) -> #(Host, Effect(Msg)) {
  let host = Host(endpoint:, base:, load: Loading)
  #(host, fetch(host, as_of, table.initial_params()))
}

/// Re-fetch for a new `as_of` (stale-while-revalidate), keeping the active filters /
/// sort / layout. The current rows stay on screen until the fresh page replaces
/// them. Updates the `as_of` base param so the existing as-of callers keep working.
pub fn refetch(host: Host, as_of: calendar.Date) -> #(Host, Effect(Msg)) {
  refetch_with(host, [#("as_of", time.iso_date(as_of))], as_of)
}

/// Re-fetch with new fixed `base` params (e.g. a moved `from`/`to` window), keeping
/// the active filters / sort / layout.
pub fn refetch_with(
  host: Host,
  base: List(#(String, String)),
  as_of: calendar.Date,
) -> #(Host, Effect(Msg)) {
  let host = Host(..host, base:)
  #(host, fetch(host, as_of, current_params(host)))
}

/// Whether the first page has loaded (a page-level readiness check).
pub fn is_loaded(host: Host) -> Bool {
  case host.load {
    Loaded(..) -> True
    _ -> False
  }
}

/// The load failure message, if the fetch failed.
pub fn failure(host: Host) -> Option(String) {
  case host.load {
    Failed(message:) -> Some(message)
    _ -> None
  }
}

fn current_params(host: Host) -> List(#(String, String)) {
  case host.load {
    Loaded(table_state:, ..) -> table.params(table_state)
    _ -> table.initial_params()
  }
}

pub fn update(
  host: Host,
  msg: Msg,
  as_of: calendar.Date,
) -> #(Host, Effect(Msg), Out) {
  case msg {
    Got(as_of: stamp, result:) ->
      case stamp == as_of {
        False -> #(host, effect.none(), Stay)
        True ->
          case result {
            Error(error) -> #(
              Host(..host, load: Failed(api.describe_error(error))),
              effect.none(),
              Stay,
            )
            Ok(table_response) -> {
              let table_state = case host.load {
                Loaded(table_state:, ..) ->
                  table.reconcile(table_state, table_response.schema)
                _ -> initial_state(table_response.schema)
              }
              #(
                Host(
                  ..host,
                  load: Loaded(
                    schema: table_response.schema,
                    rows: table_response.rows,
                    next_cursor: table_response.page.next_cursor,
                    table_state:,
                    footer: table_response.footer,
                  ),
                ),
                effect.none(),
                Stay,
              )
            }
          }
      }
    GotMore(as_of: stamp, result:) ->
      case stamp == as_of, host.load, result {
        True, Loaded(schema:, rows:, table_state:, ..), Ok(table_response) -> #(
          Host(
            ..host,
            load: Loaded(
              schema:,
              rows: list.append(rows, table_response.rows),
              next_cursor: table_response.page.next_cursor,
              table_state: table.reconcile(table_state, table_response.schema),
              footer: table_response.footer,
            ),
          ),
          effect.none(),
          Stay,
        )
        _, _, _ -> #(host, effect.none(), Stay)
      }
    TableMsg(sub:) ->
      case host.load {
        Loaded(schema:, rows:, next_cursor:, table_state:, footer:) -> {
          let #(next_state, outcome) = table.update(table_state, sub)
          let host =
            Host(
              ..host,
              load: Loaded(
                schema:,
                rows:,
                next_cursor:,
                table_state: next_state,
                footer:,
              ),
            )
          case outcome {
            table.Idle -> #(host, effect.none(), Stay)
            table.Requery(params:) -> #(host, fetch(host, as_of, params), Stay)
            table.AppendPage(params:) ->
              case next_cursor {
                Some(cursor) -> #(
                  host,
                  fetch_more(host, as_of, params, cursor),
                  Stay,
                )
                None -> #(host, effect.none(), Stay)
              }
            table.Persist(layout:) -> #(
              host,
              storage.set(table.layout_key(next_state, user_scope()), layout),
              Stay,
            )
            table.Schedule(token:) -> #(
              host,
              scheduler.after(
                table.debounce_ms,
                TableMsg(table.SettleFired(token)),
              ),
              Stay,
            )
            table.Activated(id:) -> #(host, effect.none(), Activated(id))
            table.ActionRaised(action:, row:) -> #(
              host,
              effect.none(),
              ActionInvoked(action:, row:),
            )
          }
        }
        _ -> #(host, effect.none(), Stay)
      }
  }
}

/// Render the table, or a loading / failed placeholder. The page wraps this in its
/// own panel chrome and `element.map`s it into its own message type.
pub fn view(host: Host, loading_message: String) -> Element(Msg) {
  case host.load {
    Loading -> ui.empty_state(message: loading_message)
    Failed(message:) -> ui.empty_state(message:)
    Loaded(schema:, rows:, next_cursor:, table_state:, footer:) ->
      element.map(
        table.view(
          schema,
          rows,
          table_state,
          option.is_some(next_cursor),
          footer,
        ),
        TableMsg,
      )
  }
}

fn initial_state(schema: column.Schema) -> table.State {
  let base = table.init(schema)
  case storage.get(table.layout_key(base, user_scope())) {
    Some(layout) -> table.with_layout(base, layout, schema)
    None -> base
  }
}

/// The signed-in user's layout scope, written to storage at sign-in. Falls back to
/// "shared" before an identity is known, so an anonymous/boot read never throws.
fn user_scope() -> String {
  storage.get("tempo.actor") |> option.unwrap("shared")
}

fn fetch(
  host: Host,
  as_of: calendar.Date,
  params: List(#(String, String)),
) -> Effect(Msg) {
  api.get(url(host, params), response.response_decoder(), Got(as_of, _))
}

fn fetch_more(
  host: Host,
  as_of: calendar.Date,
  params: List(#(String, String)),
  cursor: String,
) -> Effect(Msg) {
  api.get(
    url(host, list.append(params, [#("cursor", cursor)])),
    response.response_decoder(),
    GotMore(as_of, _),
  )
}

/// The request URL: the endpoint with the host's fixed base params first, then the
/// table's filter/sort/page params.
fn url(host: Host, params: List(#(String, String))) -> String {
  case list.append(host.base, params) {
    [] -> host.endpoint
    all -> host.endpoint <> "?" <> query_string(all)
  }
}

fn query_string(params: List(#(String, String))) -> String {
  params
  |> list.map(fn(pair) { pair.0 <> "=" <> uri.percent_encode(pair.1) })
  |> string.join("&")
}
