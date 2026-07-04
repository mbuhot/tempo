//// The Locations page (Scheduling Phase A): every engineer and their location
//// as of the global rail date, read from `GET /api/locations?as_of=`. An
//// engineer with no location on the date renders a dimmed "No location set"
//// row (excluded from any future finder).
////
//// Each row carries a permission-gated "Set location" launcher that opens the
//// shared `ui` op-form modal pre-filled with the engineer's id and (when one
//// exists) their current country/region/timezone; submitting posts
//// `SetEngineerLocation` via `api.submit_operation` and, on success, refetches
//// the listing and raises `OperationCommitted`.
////
//// Follows the frozen page interface (init/update/view/refetch + OutMsg).

import client/api
import client/page.{type OutMsg, OperationCommitted}
import client/time
import client/ui
import gleam/dynamic/decode
import gleam/int
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
  Model(as_of: Date, actor: String, state: State, op: Option(ui.OpState))
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
  OpOpened(permit: ui.Permit, engineer_id: Int, current: Option(LocationRecord))
  OpCancelled
  OpFieldEdited(field: ui.OpField, value: String)
  OpSubmitted
  OperationReturned(result: Result(Nil, rsvp.Error(String)))
}

pub fn init(_route, as_of: Date, actor: String) -> #(Model, Effect(Msg)) {
  #(Model(as_of:, actor:, state: LocationsLoading, op: None), fetch(as_of))
}

pub fn refetch(
  model: Model,
  as_of: Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  #(Model(..model, as_of:, actor:), fetch(as_of))
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

    OpOpened(permit:, engineer_id:, current:) -> {
      let kind = ui.permit_kind(permit)
      let form =
        ui.blank_op_form(kind, model.as_of)
        |> ui.update_op_form(ui.FEngineerId, int.to_string(engineer_id))
        |> prefill_location(current)
      #(
        Model(..model, op: Some(ui.OpState(kind:, form:, error: None))),
        effect.none(),
        [],
      )
    }

    OpCancelled -> #(Model(..model, op: None), effect.none(), [])

    OpFieldEdited(field:, value:) ->
      case model.op {
        Some(ui.OpState(kind:, form:, ..)) -> #(
          Model(
            ..model,
            op: Some(ui.OpState(
              kind:,
              form: ui.update_op_form(form, field, value),
              error: None,
            )),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    OpSubmitted ->
      case model.op {
        Some(ui.OpState(kind:, form:, ..)) ->
          case ui.build_command(kind, form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OperationReturned),
              [],
            )
            Error(prompt) -> #(
              Model(
                ..model,
                op: Some(ui.OpState(kind:, form:, error: Some(prompt))),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    OperationReturned(result:) ->
      case result {
        Ok(_events) -> {
          let #(refreshed, fetch_effect) =
            refetch(Model(..model, op: None), model.as_of, model.actor)
          #(refreshed, fetch_effect, [OperationCommitted])
        }
        Error(error) -> #(
          set_op_error(model, api.describe_error(error)),
          effect.none(),
          [],
        )
      }
  }
}

/// Pre-fill the form's location fields from the row's current location, if any.
/// A row with no location on record opens the modal blank.
fn prefill_location(
  form: ui.OpForm,
  current: Option(LocationRecord),
) -> ui.OpForm {
  case current {
    Some(location_view.LocationRecord(country:, region:, timezone:, ..)) ->
      form
      |> ui.update_op_form(ui.FCountry, country)
      |> ui.update_op_form(ui.FRegion, option.unwrap(region, ""))
      |> ui.update_op_form(ui.FTimezone, timezone)
    None -> form
  }
}

/// Surface a rejection on the open op form, leaving its typed fields intact.
fn set_op_error(model: Model, message: String) -> Model {
  case model.op {
    Some(ui.OpState(kind:, form:, ..)) ->
      Model(..model, op: Some(ui.OpState(kind:, form:, error: Some(message))))
    None -> model
  }
}

// --- View -------------------------------------------------------------------

pub fn view(
  model: Model,
  as_of: Date,
  permissions: Set(String),
) -> Element(Msg) {
  let _ = as_of
  html.div([], [
    view_op_modal(model.op),
    ui.list_page(
      title: "Locations",
      blurb: "Every engineer's country, region, and IANA timezone as of the rail date, so the finder and calendar know each person's local wall-clock.",
      actions: [],
      body: view_body(model.state, permissions),
    ),
  ])
}

fn view_body(state: State, permissions: Set(String)) -> Element(Msg) {
  case state {
    LocationsLoading -> ui.empty_state(message: "Loading locations…")
    LocationsFailed(detail:) ->
      ui.empty_state(message: "Could not load locations: " <> detail)
    LocationsLoaded(entries:) -> view_table(entries, permissions)
  }
}

fn view_table(
  entries: List(EngineerLocation),
  permissions: Set(String),
) -> Element(Msg) {
  ui.data_table(
    headers: [
      #("Engineer", False),
      #("Location", False),
      #("Timezone", False),
      #("Offset", False),
      #("Since", False),
      #("", False),
    ],
    rows: list.map(entries, view_row(_, permissions)),
  )
}

fn view_row(entry: EngineerLocation, permissions: Set(String)) -> Element(Msg) {
  let location_view.EngineerLocation(engineer_id:, name:, location:) = entry
  case location {
    Some(record) -> view_located_row(engineer_id, name, record, permissions)
    None -> view_unlocated_row(engineer_id, name, permissions)
  }
}

fn view_located_row(
  engineer_id: Int,
  name: String,
  record: LocationRecord,
  permissions: Set(String),
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
    html.td([], [
      set_location_launch(engineer_id, Some(record), permissions),
    ]),
  ])
}

fn view_unlocated_row(
  engineer_id: Int,
  name: String,
  permissions: Set(String),
) -> Element(Msg) {
  html.tr([attribute.class("loc-row--empty")], [
    html.td([], [view_engineer_cell(engineer_id, name)]),
    html.td([], [html.text("No location set")]),
    html.td([attribute.class("mono")], [html.text("—")]),
    html.td([attribute.class("mono")], [html.text("—")]),
    html.td([attribute.class("mono")], [html.text("excluded from finder")]),
    html.td([], [set_location_launch(engineer_id, None, permissions)]),
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

/// The per-row "Set location" launcher: gated by `location.manage`, opening the
/// op modal pre-filled with this engineer's id and current location (if any).
fn set_location_launch(
  engineer_id: Int,
  current: Option(LocationRecord),
  permissions: Set(String),
) -> Element(Msg) {
  ui.launch(
    ui.permit(permissions, own: False, kind: ui.OpSetLocation),
    to_msg: fn(granted) { OpOpened(permit: granted, engineer_id:, current:) },
    label: "Set location",
    kind: ui.Ghost,
    size: ui.Small,
  )
}

// --- Op form ------------------------------------------------------------

fn view_op_modal(op: Option(ui.OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(ui.OpState(kind:, form:, error:)) ->
      ui.modal(
        title: "Set location",
        error: option.unwrap(error, ""),
        body: op_fields(kind, form),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: "Set location",
      )
  }
}

fn op_fields(kind: ui.OpKind, form: ui.OpForm) -> List(Element(Msg)) {
  case kind {
    ui.OpSetLocation -> [
      text_field("Country", ui.FCountry, form.country),
      text_field("Region", ui.FRegion, form.region),
      text_field("Timezone (IANA TZID)", ui.FTimezone, form.timezone),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    _ -> []
  }
}

fn text_field(label: String, field: ui.OpField, value: String) -> Element(Msg) {
  ui.op_field(
    label:,
    field:,
    value:,
    input_type: "text",
    to_msg: fn(field, value) { OpFieldEdited(field:, value:) },
  )
}

fn date_field(label: String, field: ui.OpField, value: String) -> Element(Msg) {
  ui.op_field(
    label:,
    field:,
    value:,
    input_type: "date",
    to_msg: fn(field, value) { OpFieldEdited(field:, value:) },
  )
}
