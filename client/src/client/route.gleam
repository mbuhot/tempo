//// The client's URL contract: the `Route` sum the shell renders, the path it
//// serializes to, and the global as-of date carried alongside it in the query
//// string (ADR-036).
////
//// The `?date=YYYY-MM-DD` query is NOT part of the route identity — it is the one
//// global as-of, mirrored in the URL so a shared link or a reload opens on the
//// same instant. `to_path` renders the route path only; `with_as_of` appends the
//// date; `as_of_of` reads it back. The Finance route carries an optional invoice
//// id and Activity carries its own filters in the query (FR-AC3) so cross-page
//// navigation needs no shell edit.

import client/time
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import gleam/uri.{type Uri}

/// The three Finance sub-tabs (FR-F*). The active tab rides in the route so a
/// link opens the page on the right tab and the shell needs no per-tab state.
pub type FinanceTab {
  Invoices
  Payroll
  Pnl
  Forecast
}

/// The pages the shell can render. Detail routes carry their entity id so a deep
/// link resolves directly; `Finance` additionally carries an optional invoice id
/// for invoice drill-in from Projects/Finance without a shell edit. `NotFound`
/// is the fallback for an unrecognised path.
pub type Route {
  Board
  People(id: Option(Int))
  Clients(id: Option(Int))
  Projects(id: Option(Int))
  Finance(tab: FinanceTab, invoice: Option(Int))
  Activity
  Settings
  Access
  /// The onboarding wizard. `/onboard` is the landing (start new or resume);
  /// `/onboard/<id>/<step>` is the wizard open at a step, so browser back/forward
  /// moves between steps and a deep link reopens mid-flow.
  Onboard(instance_id: Option(String), step_id: Option(String))
  NotFound
}

/// Parse a `Uri` into a `Route`, reading the path segments only (the as-of date
/// and activity filters live in the query, read separately by `as_of_of` /
/// `activity_filters_of`). An empty path opens the Board; an unknown path is
/// `NotFound`.
pub fn parse(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] -> Board
    ["board"] -> Board
    ["people"] -> People(id: None)
    ["people", id] -> People(id: int.parse(id) |> option.from_result)
    ["clients"] -> Clients(id: None)
    ["clients", id] -> Clients(id: int.parse(id) |> option.from_result)
    ["projects"] -> Projects(id: None)
    ["projects", id] -> Projects(id: int.parse(id) |> option.from_result)
    ["finance"] -> Finance(tab: Invoices, invoice: None)
    ["finance", tab] ->
      Finance(tab: finance_tab_from_string(tab), invoice: None)
    ["finance", tab, invoice] ->
      Finance(
        tab: finance_tab_from_string(tab),
        invoice: int.parse(invoice) |> option.from_result,
      )
    ["activity"] -> Activity
    ["settings"] -> Settings
    ["access"] -> Access
    ["onboard"] -> Onboard(instance_id: None, step_id: None)
    ["onboard", id] -> Onboard(instance_id: Some(id), step_id: None)
    ["onboard", id, step] -> Onboard(instance_id: Some(id), step_id: Some(step))
    _ -> NotFound
  }
}

/// The path a route serializes to, WITHOUT the as-of date or any query. Use
/// `with_as_of` to get the full URL the shell navigates to.
pub fn to_path(route: Route) -> String {
  case route {
    Board -> "/board"
    People(id: None) -> "/people"
    People(id: Some(id)) -> "/people/" <> int.to_string(id)
    Clients(id: None) -> "/clients"
    Clients(id: Some(id)) -> "/clients/" <> int.to_string(id)
    Projects(id: None) -> "/projects"
    Projects(id: Some(id)) -> "/projects/" <> int.to_string(id)
    Finance(tab:, invoice: None) -> "/finance/" <> finance_tab_to_string(tab)
    Finance(tab:, invoice: Some(invoice)) ->
      "/finance/" <> finance_tab_to_string(tab) <> "/" <> int.to_string(invoice)
    Activity -> "/activity"
    Settings -> "/settings"
    Access -> "/access"
    Onboard(instance_id: None, ..) -> "/onboard"
    Onboard(instance_id: Some(id), step_id: None) -> "/onboard/" <> id
    Onboard(instance_id: Some(id), step_id: Some(step)) ->
      "/onboard/" <> id <> "/" <> step
    NotFound -> "/"
  }
}

/// The as-of date carried in the URL's `?date=YYYY-MM-DD`, or `None` when absent
/// or malformed. The shell reconciles its global as-of against this on every URL
/// change so a shared link opens on the right instant.
pub fn as_of_of(uri: Uri) -> Option(calendar.Date) {
  query_param(uri, "date")
  |> option.then(fn(value) { time.parse_iso_date(value) |> option.from_result })
}

/// The full URL for a route at an as-of date: the route's path with the date in
/// the query string. The shell `modem.replace`s this on a scrub and `push`es it
/// on a navigation.
pub fn with_as_of(route: Route, as_of: calendar.Date) -> String {
  to_path(route) <> "?date=" <> iso_date(as_of)
}

/// The four optional activity filters carried in the URL query (FR-AC3): the
/// half-open `from`/`to` system-time window and the operation/actor filters. Each
/// is `None` when absent or malformed so a partial query still parses.
pub fn activity_filters_of(
  uri: Uri,
) -> #(
  Option(calendar.Date),
  Option(calendar.Date),
  Option(String),
  Option(String),
) {
  let from =
    query_param(uri, "from")
    |> option.then(fn(value) {
      time.parse_iso_date(value) |> option.from_result
    })
  let to =
    query_param(uri, "to")
    |> option.then(fn(value) {
      time.parse_iso_date(value) |> option.from_result
    })
  let operation = query_param(uri, "operation")
  let actor = query_param(uri, "actor")
  #(from, to, operation, actor)
}

/// The Activity URL for a set of filters: the `/activity` path with each present
/// filter appended to the query. An absent filter is omitted so the URL stays
/// clean. The Activity page raises `Navigate` with this so its filter state is
/// shareable and survives a reload (FR-AC3).
pub fn activity_path(
  from: Option(calendar.Date),
  to: Option(calendar.Date),
  operation: Option(String),
  actor: Option(String),
) -> String {
  let params =
    [
      from |> option.map(fn(date) { #("from", iso_date(date)) }),
      to |> option.map(fn(date) { #("to", iso_date(date)) }),
      operation |> option.map(fn(value) { #("operation", value) }),
      actor |> option.map(fn(value) { #("actor", value) }),
    ]
    |> option.values
  case params {
    [] -> "/activity"
    pairs ->
      "/activity?"
      <> pairs
      |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
      |> string.join("&")
  }
}

/// The string a `FinanceTab` serializes to in the URL path.
fn finance_tab_to_string(tab: FinanceTab) -> String {
  case tab {
    Invoices -> "invoices"
    Payroll -> "payroll"
    Pnl -> "pnl"
    Forecast -> "forecast"
  }
}

/// Parse a URL path segment back into a `FinanceTab`, defaulting to `Invoices`.
fn finance_tab_from_string(raw: String) -> FinanceTab {
  case raw {
    "payroll" -> Payroll
    "pnl" -> Pnl
    "forecast" -> Forecast
    _ -> Invoices
  }
}

/// The value of a named query parameter, or `None` when there is no query or the
/// parameter is absent.
fn query_param(uri: Uri, name: String) -> Option(String) {
  case uri.query {
    None -> None
    Some(query) ->
      case uri.parse_query(query) {
        Ok(params) -> list.key_find(params, name) |> option.from_result
        Error(Nil) -> None
      }
  }
}

/// Render a `Date` as ISO-8601 "YYYY-MM-DD" for the query string.
fn iso_date(date: calendar.Date) -> String {
  let calendar.Date(year:, month:, day:) = date
  pad4(year) <> "-" <> pad2(calendar.month_to_int(month)) <> "-" <> pad2(day)
}

fn pad2(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 2, with: "0")
}

fn pad4(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 4, with: "0")
}
