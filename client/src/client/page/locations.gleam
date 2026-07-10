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
import client/ui/atoms
import client/ui/op_commands
import client/ui/ops
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam/time/calendar.{type Date}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/access
import shared/availability/command as availability_command
import shared/availability/view.{type HolidayListing} as availability_view
import shared/command as gateway
import shared/location/view.{type EngineerLocation, type LocationRecord} as location_view
import shared/wire

pub type Model {
  Model(
    as_of: Date,
    actor: String,
    state: State,
    op: Option(ops.OpState),
    holidays: HolidaysState,
    import_form: Option(ImportForm),
  )
}

/// The page's load state: fetching, the loaded roster-with-location, or a load
/// failure.
pub type State {
  LocationsLoading
  LocationsLoaded(entries: List(EngineerLocation))
  LocationsFailed(detail: String)
}

/// The holidays panel's load state, fetched independently of the locations
/// roster.
pub type HolidaysState {
  HolidaysLoading
  HolidaysLoaded(entries: List(HolidayListing))
  HolidaysFailed(detail: String)
}

/// The paste-to-import textarea plus any rejection surfaced by parsing or by
/// the server.
pub type ImportForm {
  ImportForm(text: String, error: Option(String))
}

pub type Msg {
  Fetched(
    as_of: Date,
    result: Result(List(EngineerLocation), rsvp.Error(String)),
  )
  HolidaysFetched(
    as_of: Date,
    result: Result(List(HolidayListing), rsvp.Error(String)),
  )
  OpOpened(
    permit: ops.Permit,
    engineer_id: Int,
    current: Option(LocationRecord),
  )
  OpCancelled
  OpFieldEdited(field: ops.OpField, value: String)
  OpSubmitted
  ImportOpened
  ImportCancelled
  ImportTextEdited(String)
  ImportSubmitted
  OperationReturned(result: Result(Nil, rsvp.Error(String)))
}

pub fn init(_route, as_of: Date, actor: String) -> #(Model, Effect(Msg)) {
  #(
    Model(
      as_of:,
      actor:,
      state: LocationsLoading,
      op: None,
      holidays: HolidaysLoading,
      import_form: None,
    ),
    effect.batch([fetch(as_of), fetch_holidays(as_of)]),
  )
}

pub fn refetch(
  model: Model,
  as_of: Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  #(
    Model(..model, as_of:, actor:),
    effect.batch([fetch(as_of), fetch_holidays(as_of)]),
  )
}

fn fetch(as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/locations?as_of=" <> time.iso_date(as_of),
    decode.list(location_view.engineer_location_decoder()),
    fn(result) { Fetched(as_of:, result:) },
  )
}

fn fetch_holidays(as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/holidays?as_of=" <> time.iso_date(as_of),
    decode.list(availability_view.holiday_listing_decoder()),
    fn(result) { HolidaysFetched(as_of:, result:) },
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

    HolidaysFetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let holidays = case result {
            Ok(entries) -> HolidaysLoaded(entries:)
            Error(error) -> HolidaysFailed(detail: api.describe_error(error))
          }
          #(Model(..model, holidays:), effect.none(), [])
        }
      }

    OpOpened(permit:, engineer_id:, current:) -> {
      let kind = ops.permit_kind(permit)
      let form =
        ops.blank_op_form(kind, model.as_of)
        |> ops.update_op_form(ops.FEngineerId, int.to_string(engineer_id))
        |> prefill_location(current)
      #(
        Model(..model, op: Some(ops.OpState(kind:, form:, error: None))),
        effect.none(),
        [],
      )
    }

    OpCancelled -> #(Model(..model, op: None), effect.none(), [])

    OpFieldEdited(field:, value:) ->
      case model.op {
        Some(ops.OpState(kind:, form:, ..)) -> #(
          Model(
            ..model,
            op: Some(ops.OpState(
              kind:,
              form: ops.update_op_form(form, field, value),
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
        Some(ops.OpState(kind:, form:, ..)) ->
          case op_commands.build_command(kind, form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OperationReturned),
              [],
            )
            Error(prompt) -> #(
              Model(
                ..model,
                op: Some(ops.OpState(kind:, form:, error: Some(prompt))),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    ImportOpened -> #(
      Model(..model, import_form: Some(ImportForm(text: "", error: None))),
      effect.none(),
      [],
    )

    ImportCancelled -> #(Model(..model, import_form: None), effect.none(), [])

    ImportTextEdited(text) ->
      case model.import_form {
        Some(_) -> #(
          Model(..model, import_form: Some(ImportForm(text:, error: None))),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    ImportSubmitted ->
      case model.import_form {
        Some(form) ->
          case parse_holiday_lines(form.text) {
            Ok(rows) -> #(
              model,
              api.submit_operation(
                gateway.AvailabilityCommand(availability_command.ImportHolidays(
                  rows:,
                )),
                OperationReturned,
              ),
              [],
            )
            Error(message) -> #(
              Model(
                ..model,
                import_form: Some(ImportForm(..form, error: Some(message))),
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
            refetch(
              Model(..model, op: None, import_form: None),
              model.as_of,
              model.actor,
            )
          #(refreshed, fetch_effect, [OperationCommitted])
        }
        Error(error) -> {
          let message = api.describe_error(error)
          case model.import_form {
            Some(form) -> #(
              Model(
                ..model,
                import_form: Some(ImportForm(..form, error: Some(message))),
              ),
              effect.none(),
              [],
            )
            None -> #(set_op_error(model, message), effect.none(), [])
          }
        }
      }
  }
}

/// Pre-fill the form's location fields from the row's current location, if any.
/// A row with no location on record opens the modal blank.
fn prefill_location(
  form: ops.OpForm,
  current: Option(LocationRecord),
) -> ops.OpForm {
  case current {
    Some(location_view.LocationRecord(country:, region:, timezone:, ..)) ->
      form
      |> ops.update_op_form(ops.FCountry, country)
      |> ops.update_op_form(ops.FRegion, option.unwrap(region, ""))
      |> ops.update_op_form(ops.FTimezone, timezone)
    None -> form
  }
}

/// Surface a rejection on the open op form, leaving its typed fields intact.
fn set_op_error(model: Model, message: String) -> Model {
  case model.op {
    Some(ops.OpState(kind:, form:, ..)) ->
      Model(..model, op: Some(ops.OpState(kind:, form:, error: Some(message))))
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
    view_import_modal(model.import_form),
    atoms.list_page(
      title: "Locations",
      blurb: "Every engineer's country, region, and IANA timezone as of the rail date, so the finder and calendar know each person's local wall-clock.",
      actions: [],
      body: view_body(model.state, permissions),
    ),
    view_holidays_section(model.holidays, permissions),
  ])
}

fn view_body(state: State, permissions: Set(String)) -> Element(Msg) {
  case state {
    LocationsLoading -> atoms.empty_state(message: "Loading locations…")
    LocationsFailed(detail:) ->
      atoms.empty_state(message: "Could not load locations: " <> detail)
    LocationsLoaded(entries:) -> view_table(entries, permissions)
  }
}

fn view_table(
  entries: List(EngineerLocation),
  permissions: Set(String),
) -> Element(Msg) {
  atoms.data_table(
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
    utc_offset_minutes:,
    valid_from:,
    ..,
  ) = record
  html.tr([], [
    html.td([], [view_engineer_cell(engineer_id, name)]),
    html.td([], [view_location_cell(country, region)]),
    html.td([attribute.class("mono")], [html.text(timezone)]),
    html.td([attribute.class("mono")], [
      html.text(time.utc_offset(utc_offset_minutes)),
    ]),
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
    atoms.avatar(name:, category: engineer_id, class: "avatar"),
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
  ops.launch(
    ops.permit(permissions, own: False, kind: ops.OpSetLocation),
    to_msg: fn(granted) { OpOpened(permit: granted, engineer_id:, current:) },
    label: "Set location",
    kind: atoms.Ghost,
    size: atoms.Small,
  )
}

// --- Op form ------------------------------------------------------------

fn view_op_modal(op: Option(ops.OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(ops.OpState(kind:, form:, error:)) ->
      atoms.modal(
        title: "Set location",
        error: option.unwrap(error, ""),
        body: op_fields(kind, form),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: "Set location",
      )
  }
}

fn op_fields(kind: ops.OpKind, form: ops.OpForm) -> List(Element(Msg)) {
  case kind {
    ops.OpSetLocation -> [
      text_field("Country", ops.FCountry, form.country),
      text_field("Region", ops.FRegion, form.region),
      text_field("Timezone (IANA TZID)", ops.FTimezone, form.timezone),
      date_field("Effective", ops.FEffective, form.effective),
    ]
    _ -> []
  }
}

fn text_field(
  label: String,
  field: ops.OpField,
  value: String,
) -> Element(Msg) {
  ops.op_field(
    label:,
    field:,
    value:,
    input_type: "text",
    to_msg: fn(field, value) { OpFieldEdited(field:, value:) },
  )
}

fn date_field(
  label: String,
  field: ops.OpField,
  value: String,
) -> Element(Msg) {
  ops.op_field(
    label:,
    field:,
    value:,
    input_type: "date",
    to_msg: fn(field, value) { OpFieldEdited(field:, value:) },
  )
}

// --- Holidays -------------------------------------------------------------

fn view_holidays_section(
  state: HolidaysState,
  permissions: Set(String),
) -> Element(Msg) {
  atoms.panel(
    title: "Public holidays",
    count: "",
    right: holidays_actions(permissions),
    body: [view_holidays_body(state)],
  )
}

fn holidays_actions(permissions: Set(String)) -> List(Element(Msg)) {
  case set.contains(permissions, access.holiday_manage) {
    True -> [
      atoms.button(
        label: "Import holidays",
        kind: atoms.Ghost,
        size: atoms.Small,
        on_press: ImportOpened,
      ),
    ]
    False -> []
  }
}

fn view_holidays_body(state: HolidaysState) -> Element(Msg) {
  case state {
    HolidaysLoading -> atoms.empty_state(message: "Loading holidays…")
    HolidaysFailed(detail:) ->
      atoms.empty_state(message: "Could not load holidays: " <> detail)
    HolidaysLoaded(entries:) -> view_holidays_table(entries)
  }
}

fn view_holidays_table(entries: List(HolidayListing)) -> Element(Msg) {
  case entries {
    [] -> atoms.empty_state(message: "No upcoming holidays.")
    _ ->
      atoms.data_table(
        headers: [#("Region", False), #("Date", False), #("Name", False)],
        rows: list.map(entries, view_holiday_row),
      )
  }
}

fn view_holiday_row(entry: HolidayListing) -> Element(Msg) {
  let availability_view.HolidayListing(region_name:, holiday_on:, name:, ..) =
    entry
  html.tr([], [
    html.td([], [html.text(region_name)]),
    html.td([attribute.class("mono")], [html.text(time.format_date(holiday_on))]),
    html.td([], [html.text(name)]),
  ])
}

fn view_import_modal(form: Option(ImportForm)) -> Element(Msg) {
  case form {
    None -> element.none()
    Some(ImportForm(text:, error:)) ->
      atoms.modal(
        title: "Import holidays",
        error: option.unwrap(error, ""),
        body: [
          html.p([attribute.class("op-form__hint")], [
            html.text(
              "country,region,date,name — one holiday per line; leave region empty for nationwide",
            ),
          ]),
          html.label([attribute.class("op-form__field")], [
            html.span([], [html.text("Holiday lines")]),
            html.textarea(
              [
                attribute.attribute("aria-label", "Holiday lines"),
                event.on_input(ImportTextEdited),
              ],
              text,
            ),
          ]),
        ],
        on_cancel: ImportCancelled,
        on_confirm: ImportSubmitted,
        confirm_label: "Import",
      )
  }
}

/// Parse "country,region,date,name" lines (region empty = nationwide); commas
/// beyond the third stay in the name.
pub fn parse_holiday_lines(
  text: String,
) -> Result(List(availability_command.HolidayRow), String) {
  let lines =
    text
    |> string.split("\n")
    |> list.map(string.trim)
    |> list.filter(fn(line) { line != "" })
  case lines {
    [] -> Error("no holiday lines found")
    _ ->
      lines
      |> list.index_map(fn(line, index) { parse_line(line, index + 1) })
      |> result.all
  }
}

fn parse_line(
  line: String,
  number: Int,
) -> Result(availability_command.HolidayRow, String) {
  let prefix = "line " <> int.to_string(number) <> ": "
  case string.split(line, ",") {
    [country, region, date_text, ..name_parts] -> {
      let name = string.trim(string.join(name_parts, ","))
      case wire.parse_iso_date(string.trim(date_text)) {
        Error(_) -> Error(prefix <> "date must be YYYY-MM-DD")
        Ok(holiday_on) ->
          case string.trim(country), name {
            "", _ -> Error(prefix <> "country is required")
            _, "" -> Error(prefix <> "name is required")
            trimmed_country, _ ->
              Ok(availability_command.HolidayRow(
                country: trimmed_country,
                region: string.trim(region),
                holiday_on:,
                name:,
              ))
          }
      }
    }
    _ -> Error(prefix <> "expected country,region,date,name")
  }
}
