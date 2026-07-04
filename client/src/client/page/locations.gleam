//// The Locations page (Scheduling Phase A): every engineer and their location
//// as of the global rail date, read from `GET /api/locations?as_of=`. An
//// engineer with no location on the date renders a dimmed "No location set"
//// row (excluded from any future finder). Setting a location from the UI is
//// Task 10; this page is read-only.
////
//// Follows the frozen page interface (init/update/view/refetch + OutMsg).

import client/api
import client/page.{type OutMsg}
import client/time
import client/ui
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/time/calendar.{type Date}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import rsvp
import shared/location/view.{type EngineerLocation, type LocationRecord} as location_view

pub type Model {
  Model(as_of: Date, state: State)
}

/// The page's load state: fetching, the loaded roster-with-location, or a load
/// failure.
pub type State {
  LocationsLoading
  LocationsLoaded(entries: List(EngineerLocation))
  LocationsFailed(detail: String)
}

pub type Msg {
  Fetched(
    as_of: Date,
    result: Result(List(EngineerLocation), rsvp.Error(String)),
  )
}

pub fn init(_route, as_of: Date, _actor: String) -> #(Model, Effect(Msg)) {
  #(Model(as_of:, state: LocationsLoading), fetch(as_of))
}

pub fn refetch(
  model: Model,
  as_of: Date,
  _actor: String,
) -> #(Model, Effect(Msg)) {
  #(Model(..model, as_of:), fetch(as_of))
}

fn fetch(as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/locations?as_of=" <> time.iso_date(as_of),
    decode.list(location_view.engineer_location_decoder()),
    fn(result) { Fetched(as_of:, result:) },
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    Fetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let state = case result {
            Ok(entries) -> LocationsLoaded(entries:)
            Error(error) -> LocationsFailed(detail: api.describe_error(error))
          }
          #(Model(..model, state:), effect.none(), [])
        }
      }
  }
}

// --- View -------------------------------------------------------------------

pub fn view(
  model: Model,
  as_of: Date,
  permissions: Set(String),
) -> Element(Msg) {
  let _ = as_of
  let _ = permissions
  ui.list_page(
    title: "Locations",
    blurb: "Every engineer's country, region, and IANA timezone as of the rail date, so the finder and calendar know each person's local wall-clock.",
    actions: [],
    body: view_body(model.state),
  )
}

fn view_body(state: State) -> Element(Msg) {
  case state {
    LocationsLoading -> ui.empty_state(message: "Loading locations…")
    LocationsFailed(detail:) ->
      ui.empty_state(message: "Could not load locations: " <> detail)
    LocationsLoaded(entries:) -> view_table(entries)
  }
}

fn view_table(entries: List(EngineerLocation)) -> Element(Msg) {
  ui.data_table(
    headers: [
      #("Engineer", False),
      #("Location", False),
      #("Timezone", False),
      #("Offset", False),
      #("Since", False),
    ],
    rows: list.map(entries, view_row),
  )
}

fn view_row(entry: EngineerLocation) -> Element(Msg) {
  let location_view.EngineerLocation(engineer_id:, name:, location:) = entry
  case location {
    Some(record) -> view_located_row(engineer_id, name, record)
    None -> view_unlocated_row(engineer_id, name)
  }
}

fn view_located_row(
  engineer_id: Int,
  name: String,
  record: LocationRecord,
) -> Element(Msg) {
  let location_view.LocationRecord(
    country:,
    region:,
    timezone:,
    valid_from:,
    ..,
  ) = record
  html.tr([], [
    html.td([], [view_engineer_cell(engineer_id, name)]),
    html.td([], [view_location_cell(country, region)]),
    html.td([attribute.class("mono")], [html.text(timezone)]),
    html.td([attribute.class("mono muted")], [html.text("—")]),
    html.td([attribute.class("mono")], [html.text(time.format_date(valid_from))]),
  ])
}

fn view_unlocated_row(engineer_id: Int, name: String) -> Element(Msg) {
  html.tr([attribute.class("loc-row--empty")], [
    html.td([], [view_engineer_cell(engineer_id, name)]),
    html.td([], [html.text("No location set")]),
    html.td([attribute.class("mono")], [html.text("—")]),
    html.td([attribute.class("mono")], [html.text("—")]),
    html.td([attribute.class("mono")], [html.text("excluded from finder")]),
  ])
}

fn view_engineer_cell(engineer_id: Int, name: String) -> Element(Msg) {
  html.span([attribute.class("cell-name")], [
    ui.avatar(name:, category: engineer_id, class: "avatar"),
    html.span([attribute.class("cell-name__text")], [
      html.span([attribute.class("cell-name__name")], [html.text(name)]),
    ]),
  ])
}

fn view_location_cell(country: String, region: Option(String)) -> Element(Msg) {
  html.span([attribute.class("cell-name__text")], [
    html.span([attribute.class("cell-name__name")], [html.text(country)]),
    case region {
      Some(text) -> html.span([attribute.class("cell-sub")], [html.text(text)])
      None -> element.none()
    },
  ])
}
