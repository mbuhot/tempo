//// The People detail (FR-PE*), a self-contained sub-component MVU split out of
//// `client/page/people`. This is the page's DETAIL mode (deep link /people/:id):
//// one engineer's full record — the bundle, the side panels, the editable weekly
//// timesheet grid, and the detail contextual operations. It owns its own `Model`
//// (its as-of, the engineer id, the bundle / timesheet / directory load states,
//// and the open op form), its own `Msg`, its `init`/`update`, and its `view`.
////
//// It reads `GET /api/engineers/:id?as_of=` for the bundle, `GET /api/timesheet`
//// for the grid, and `GET /api/roster?as_of=` for the op-form directory — all in
//// parallel, each result carrying the `as_of` (and the timesheet its engineer id)
//// so a stale reply is dropped. Its writes — Promote, TakeLeave, RollOff,
//// TerminateEmployment, LogWeek, and Update{Contact,Banking,Emergency}Details —
//// drive a shared `ui.OpForm`; submitting posts via `api.submit_operation` and, on
//// success, raises `OperationCommitted` and refetches. `LogWeek` is assembled
//// directly from the grid's edited cells rather than the empty-entry form. The back
//// link raises `Navigate(People(None))` so the shell owns the URL.

import client/api
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/page/people/timesheet as timesheet_grid
import client/route
import client/time
import client/ui
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/allocation/view.{AllocationRow} as allocation_view
import shared/command as gateway
import shared/engineer/view.{
  type EngineerDetail, Employment, EngineerBanking, EngineerContact,
  EngineerDetail, EngineerEmergency,
} as engineer_view
import shared/leave/view.{LeaveBalance} as leave_view
import shared/money
import shared/roster/view.{type Ref, type Roster} as roster_view
import shared/timesheet/command.{type TimesheetEntry, LogWeek, TimesheetEntry}
import shared/timesheet/view.{
  type TimesheetWeek, TimesheetCell, TimesheetWeekRow,
} as timesheet_view

// --- Model ------------------------------------------------------------------

/// The detail mode's state: the as-of its data answers, the shown engineer id, the
/// bundle / timesheet / directory load states (fetched in parallel as sibling
/// fields so whichever arrives first never discards the others), and the open
/// contextual op form (or `None`).
pub type Model {
  Model(
    as_of: calendar.Date,
    engineer_id: Int,
    detail: DetailData,
    timesheet: TimesheetData,
    roster: Directory,
    op: Option(ui.OpState),
  )
}

/// The engineer bundle's load state.
pub type DetailData {
  DetailLoading
  DetailLoaded(detail: EngineerDetail)
  DetailFailed(message: String)
}

/// The weekly timesheet grid's load state. When loaded it carries the fetched week
/// plus the presenter's in-progress edits keyed by `#(project_id, day_index)`, so
/// typed hours survive a re-render and feed the `LogWeek` submit.
pub type TimesheetData {
  TimesheetLoading
  TimesheetLoaded(week: TimesheetWeek, edits: Dict(#(Int, Int), String))
  TimesheetFailed(message: String)
}

/// The as-of operations directory's load state.
pub type Directory {
  DirectoryLoading
  DirectoryLoaded(roster: Roster)
  DirectoryFailed(message: String)
}

// --- Messages ---------------------------------------------------------------

/// The detail mode's messages: the bundle / timesheet / directory fetch results
/// (each carrying the `as_of` they answer, and the timesheet its engineer id), the
/// back-link navigation, the contextual op lifecycle, the grid's cell edit + submit,
/// and the operation reply.
pub type Msg {
  DetailFetched(
    as_of: calendar.Date,
    engineer_id: Int,
    result: Result(EngineerDetail, rsvp.Error(String)),
  )
  TimesheetFetched(
    as_of: calendar.Date,
    engineer_id: Int,
    result: Result(TimesheetWeek, rsvp.Error(String)),
  )
  DirectoryFetched(
    as_of: calendar.Date,
    result: Result(Roster, rsvp.Error(String)),
  )
  BackClicked
  OpOpened(kind: ui.OpKind)
  OpCancelled
  OpFieldEdited(field: ui.OpField, value: String)
  OpSubmitted
  CellEdited(project_id: Int, day: calendar.Date, value: String)
  TimesheetSubmitted
  OperationReturned(result: Result(List(gateway.Event), rsvp.Error(String)))
}

// --- Init / refetch ---------------------------------------------------------

/// Start the detail mode for `engineer_id` at `as_of`, fetching the bundle, the
/// timesheet, and the directory in parallel.
pub fn init(as_of: calendar.Date, engineer_id: Int) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      as_of:,
      engineer_id:,
      detail: DetailLoading,
      timesheet: TimesheetLoading,
      roster: DirectoryLoading,
      op: None,
    )
  #(
    model,
    effect.batch([fetch_detail(as_of, engineer_id), fetch_directory(as_of)]),
  )
}

/// Re-fetch the detail mode for a new `as_of` (stale-while-revalidate), keeping any
/// open op form: refetch both the bundle and the timesheet for the new instant.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  #(
    Model(
      ..model,
      as_of:,
      detail: DetailLoading,
      timesheet: TimesheetLoading,
      roster: DirectoryLoading,
    ),
    effect.batch([
      fetch_detail(as_of, model.engineer_id),
      fetch_directory(as_of),
    ]),
  )
}

fn fetch_detail(as_of: calendar.Date, engineer_id: Int) -> Effect(Msg) {
  effect.batch([
    api.get(
      "/api/engineers/"
        <> int.to_string(engineer_id)
        <> "?as_of="
        <> time.iso_date(as_of),
      engineer_view.engineer_detail_decoder(),
      fn(result) { DetailFetched(as_of:, engineer_id:, result:) },
    ),
    fetch_timesheet(as_of, engineer_id),
  ])
}

fn fetch_directory(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/roster?as_of=" <> time.iso_date(as_of),
    roster_view.roster_decoder(),
    fn(result) { DirectoryFetched(as_of:, result:) },
  )
}

fn fetch_timesheet(as_of: calendar.Date, engineer_id: Int) -> Effect(Msg) {
  let week = time.week_start_of(as_of)
  api.get(
    "/api/timesheet?engineer="
      <> int.to_string(engineer_id)
      <> "&week="
      <> time.iso_date(week),
    timesheet_view.timesheet_week_decoder(),
    fn(result) { TimesheetFetched(as_of:, engineer_id:, result:) },
  )
}

// --- Update -----------------------------------------------------------------

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    DetailFetched(as_of:, engineer_id:, result:) ->
      case model.as_of == as_of && model.engineer_id == engineer_id {
        False -> #(model, effect.none(), [])
        True -> {
          let detail = case result {
            Ok(detail) -> DetailLoaded(detail:)
            Error(error) -> DetailFailed(api.describe_error(error))
          }
          #(Model(..model, detail:), effect.none(), [])
        }
      }

    TimesheetFetched(as_of:, engineer_id:, result:) ->
      case model.as_of == as_of && model.engineer_id == engineer_id {
        False -> #(model, effect.none(), [])
        True -> {
          let timesheet = case result {
            Ok(week) -> TimesheetLoaded(week:, edits: dict.new())
            Error(error) -> TimesheetFailed(api.describe_error(error))
          }
          #(Model(..model, timesheet:), effect.none(), [])
        }
      }

    DirectoryFetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let roster = case result {
            Ok(roster) -> DirectoryLoaded(roster:)
            Error(error) -> DirectoryFailed(api.describe_error(error))
          }
          #(Model(..model, roster:), effect.none(), [])
        }
      }

    BackClicked -> #(model, effect.none(), [Navigate(route.People(id: None))])

    OpOpened(kind:) -> #(
      Model(
        ..model,
        op: Some(ui.OpState(kind:, form: blank_form(model, kind), error: None)),
      ),
      effect.none(),
      [],
    )

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

    CellEdited(project_id:, day:, value:) -> #(
      edit_cell(model, project_id, day, value),
      effect.none(),
      [],
    )

    TimesheetSubmitted ->
      case model.timesheet {
        TimesheetLoaded(week:, edits:) -> #(
          model,
          api.submit_operation(
            gateway.TimesheetCommand(LogWeek(
              engineer_id: model.engineer_id,
              entries: week_entries(week, edits),
            )),
            OperationReturned,
          ),
          [],
        )
        _ -> #(model, effect.none(), [])
      }

    OperationReturned(result:) ->
      case result {
        Ok(_events) -> {
          let #(refreshed, fetch) =
            refetch(Model(..model, op: None), model.as_of)
          #(refreshed, fetch, [OperationCommitted])
        }
        Error(error) -> #(
          set_op_error(model, api.describe_error(error)),
          effect.none(),
          [],
        )
      }
  }
}

// --- Update helpers ---------------------------------------------------------

/// Surface a rejection on the open op form, leaving its typed fields intact.
fn set_op_error(model: Model, message: String) -> Model {
  case model.op {
    Some(ui.OpState(kind:, form:, ..)) ->
      Model(..model, op: Some(ui.OpState(kind:, form:, error: Some(message))))
    None -> model
  }
}

/// The active project `Ref`s from the loaded directory, for the op-form
/// `<select>`s. Empty until the directory loads.
fn project_refs(model: Model) -> List(Ref) {
  case model.roster {
    DirectoryLoaded(roster:) -> roster.projects
    _ -> []
  }
}

/// A fresh op form seeded for `kind`: the visible engineer's id (every detail op
/// acts on the shown engineer), the loaded contact/banking/emergency facts
/// pre-filled into the matching edit form, the roll-off project pre-selected from
/// the engineer's active allocation, and every entity slot snapped to a valid
/// directory option. Dates default to the as-of.
fn blank_form(model: Model, kind: ui.OpKind) -> ui.OpForm {
  let form = ui.blank_op_form(kind, model.as_of)
  let form = case kind {
    ui.OpTakeLeave -> ui.update_op_form(form, ui.FKind, "annual")
    _ -> form
  }
  let form =
    ui.update_op_form(form, ui.FEngineerId, int.to_string(model.engineer_id))
  let form = prefill_from_detail(form, kind, model.detail)
  ui.reconcile_form(form, [], project_refs(model))
}

/// Pre-fill the form's slots from the loaded engineer bundle for the kinds that
/// edit existing facts: the contact/banking/emergency edit forms open showing the
/// current values, and roll-off pre-selects the engineer's active allocation. Other
/// kinds (and an unloaded bundle) leave the form untouched.
fn prefill_from_detail(
  form: ui.OpForm,
  kind: ui.OpKind,
  detail: DetailData,
) -> ui.OpForm {
  case detail {
    DetailLoaded(detail:) ->
      case kind {
        ui.OpUpdateContact -> {
          let EngineerContact(name:, email:, phone:, postal_address:, ..) =
            detail.contact
          form
          |> ui.update_op_form(ui.FName, name)
          |> ui.update_op_form(ui.FEmail, email)
          |> ui.update_op_form(ui.FPhone, phone)
          |> ui.update_op_form(ui.FPostalAddress, postal_address)
        }
        ui.OpUpdateBanking -> {
          let EngineerBanking(bank:, branch:, account_no:, account_name:, ..) =
            detail.banking
          form
          |> ui.update_op_form(ui.FBank, bank)
          |> ui.update_op_form(ui.FBranch, branch)
          |> ui.update_op_form(ui.FAccountNo, account_no)
          |> ui.update_op_form(ui.FAccountName, account_name)
        }
        ui.OpUpdateEmergency -> {
          let EngineerEmergency(relation:, name:, phone:, email:, ..) =
            detail.emergency
          form
          |> ui.update_op_form(ui.FRelation, relation)
          |> ui.update_op_form(ui.FEmergencyName, name)
          |> ui.update_op_form(ui.FEmergencyPhone, phone)
          |> ui.update_op_form(ui.FEmergencyEmail, email)
        }
        ui.OpRollOff ->
          case active_allocation(detail.allocations) {
            Some(project_id) ->
              ui.update_op_form(form, ui.FProjectId, int.to_string(project_id))
            None -> form
          }
        _ -> form
      }
    _ -> form
  }
}

/// The project id of the engineer's first active allocation, if any — the natural
/// roll-off target so the form opens pre-selected.
fn active_allocation(
  allocations: List(allocation_view.AllocationRow),
) -> Option(Int) {
  list.find_map(allocations, fn(allocation) {
    case allocation {
      AllocationRow(project_id:, active: True, ..) -> Ok(project_id)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// Record a typed timesheet cell value, keyed by `#(project_id, day_index)`, so the
/// grid re-renders the typed value and the submit reads it back.
fn edit_cell(
  model: Model,
  project_id: Int,
  day: calendar.Date,
  value: String,
) -> Model {
  case model.timesheet {
    TimesheetLoaded(week:, edits:) -> {
      let key = #(project_id, time.date_to_day_index(day))
      let edits = dict.insert(edits, key, value)
      Model(..model, timesheet: TimesheetLoaded(week:, edits:))
    }
    _ -> model
  }
}

/// Assemble the `LogWeek` entries from the fetched grid and the presenter's edits:
/// one entry per editable (project, day) cell, taking the typed value when present
/// (an unparseable or blank typed value clears the cell at 0.0) and otherwise the
/// cell's already-logged hours. Disabled cells are never logged.
fn week_entries(
  week: TimesheetWeek,
  edits: Dict(#(Int, Int), String),
) -> List(TimesheetEntry) {
  list.flat_map(week.rows, fn(row) {
    let TimesheetWeekRow(project_id:, cells:, ..) = row
    list.filter_map(cells, fn(cell) {
      let TimesheetCell(date:, allocated:, hours:) = cell
      case allocated {
        False -> Error(Nil)
        True -> {
          let key = #(project_id, time.date_to_day_index(date))
          let value = case dict.get(edits, key) {
            Ok(typed) -> parse_hours(typed)
            Error(Nil) -> hours
          }
          Ok(TimesheetEntry(project_id:, day: date, hours: value))
        }
      }
    })
  })
}

/// Parse a typed hours cell; a blank or unparseable value clears the cell (0.0).
/// Accepts both decimals ("7.5") and bare integers ("8").
fn parse_hours(raw: String) -> Float {
  let trimmed = string.trim(raw)
  case float.parse(trimmed) {
    Ok(value) -> value
    Error(Nil) ->
      case int.parse(trimmed) {
        Ok(value) -> int.to_float(value)
        Error(Nil) -> 0.0
      }
  }
}

// --- View -------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  let back =
    html.a([attribute.class("back-link"), event.on_click(BackClicked)], [
      html.text("‹ All engineers"),
    ])
  case model.detail {
    DetailLoading -> column([back, ui.empty_state("Loading engineer…")])
    DetailFailed(message:) ->
      column([back, ui.empty_state("Could not load this engineer: " <> message)])
    DetailLoaded(detail:) ->
      column([
        back,
        detail_head(detail),
        view_op_modal(model, model.op),
        detail_grid(detail, model.timesheet),
      ])
  }
}

fn column(children: List(Element(Msg))) -> Element(Msg) {
  html.div([], children)
}

fn detail_head(detail: EngineerDetail) -> Element(Msg) {
  let EngineerDetail(engineer_id:, name:, level:, allocations:, ..) = detail
  html.div([attribute.class("page-head")], [
    html.div([], [
      html.h1([attribute.class("detail__title")], [
        ui.avatar(name:, category: engineer_id, class: "avatar"),
        html.text(name),
      ]),
      html.div([attribute.class("detail__subtitle")], [
        html.text(ui.level_band(level)),
      ]),
      html.p([], [html.text(situation(allocations))]),
    ]),
    html.div([attribute.class("action-row")], [
      op_button("Take leave", ui.OpTakeLeave, True),
      op_button("Roll off", ui.OpRollOff, True),
      op_button("Terminate", ui.OpTerminateEmployment, True),
      op_button("Promote", ui.OpPromote, False),
    ]),
  ])
}

/// A one-line situation for the detail header: allocated to the active project(s)
/// or currently unassigned, derived from the allocations the server already flagged
/// `active` for the detail's as-of. The bundle carries no leave active-flag, so
/// leave is reflected only on the roster list.
fn situation(allocations: List(allocation_view.AllocationRow)) -> String {
  let active_projects =
    list.filter_map(allocations, fn(allocation) {
      case allocation {
        AllocationRow(project:, active: True, ..) -> Ok(project)
        _ -> Error(Nil)
      }
    })
  case active_projects {
    [] -> "Currently unassigned."
    titles -> "Allocated to " <> string_join(titles, " & ") <> "."
  }
}

fn detail_grid(
  detail: EngineerDetail,
  timesheet: TimesheetData,
) -> Element(Msg) {
  html.div([attribute.class("detail-grid")], [
    html.div([], [
      allocations_panel(detail.allocations),
      timesheet_panel(timesheet),
    ]),
    html.div([], [
      balance_panel(detail.balance),
      contact_panel(detail.contact),
      banking_panel(detail.banking),
      employment_panel(detail.employment, detail.level, detail.emergency),
    ]),
  ])
}

fn allocations_panel(
  allocations: List(allocation_view.AllocationRow),
) -> Element(Msg) {
  let rows = list.map(allocations, allocation_row)
  let body = case allocations {
    [] -> [ui.empty_state("No allocations on record.")]
    _ -> [
      ui.data_table(
        headers: [
          #("Project", False),
          #("Fraction", True),
          #("Period", False),
          #("State", False),
        ],
        rows:,
      ),
    ]
  }
  ui.panel(title: "Allocations", count: "", right: [], body:)
}

fn allocation_row(allocation: allocation_view.AllocationRow) -> Element(Msg) {
  let AllocationRow(
    project_id:,
    project:,
    fraction:,
    valid_from:,
    valid_to:,
    active:,
  ) = allocation
  let #(variant, label) = case active {
    True -> #("active", "active")
    False -> #("ended", "ended")
  }
  html.tr([], [
    html.td([], [
      ui.swatch(category: project_id, inline: True),
      html.text(project),
    ]),
    html.td([attribute.class("num")], [html.text(ui.fraction(fraction))]),
    html.td([attribute.class("mono muted")], [
      html.text(time.iso_date(valid_from) <> " → " <> time.iso_date(valid_to)),
    ]),
    html.td([], [ui.pill(variant:, label:)]),
  ])
}

// --- Timesheet grid ---------------------------------------------------------

/// The detail's timesheet panel: its Loading/Failed guards, delegating the loaded
/// week's grid to the self-contained `page/people/timesheet` module. The grid's two
/// actions (submit the week, edit a cell) are wired from this module's `Msg`.
fn timesheet_panel(timesheet: TimesheetData) -> Element(Msg) {
  case timesheet {
    TimesheetLoading ->
      ui.panel(title: "Timesheet", count: "", right: [], body: [
        ui.empty_state("Loading week…"),
      ])
    TimesheetFailed(message:) ->
      ui.panel(title: "Timesheet", count: "", right: [], body: [
        ui.empty_state("Could not load the timesheet: " <> message),
      ])
    TimesheetLoaded(week:, edits:) ->
      timesheet_grid.view(
        week,
        edits,
        on_submit: TimesheetSubmitted,
        on_cell_edit: fn(project_id, day, value) {
          CellEdited(project_id:, day:, value:)
        },
      )
  }
}

// --- Side panels ------------------------------------------------------------

fn balance_panel(balance: leave_view.LeaveBalance) -> Element(Msg) {
  let LeaveBalance(annual:, sick:, ..) = balance
  ui.panel(title: "Leave balance", count: "", right: [], body: [
    html.div([attribute.class("pad-block")], [
      balance_bar("Annual", annual, 20.0),
      balance_bar("Sick", sick, 10.0),
    ]),
  ])
}

fn balance_bar(label: String, value: Float, max: Float) -> Element(Msg) {
  let pct = int.min(float_round(value /. max *. 100.0), 100)
  html.div([attribute.class("balance")], [
    html.div([attribute.class("balance__head")], [
      html.span([attribute.class("eyebrow")], [html.text(label)]),
      html.span([attribute.class("balance__value")], [
        html.text(ui.days(value) <> " days"),
      ]),
    ]),
    html.div([attribute.class("spark spark--lg")], [
      html.i([attribute.style("width", int.to_string(pct) <> "%")], []),
    ]),
  ])
}

fn contact_panel(contact: engineer_view.EngineerContact) -> Element(Msg) {
  let EngineerContact(name:, email:, phone:, postal_address:, ..) = contact
  let _ = name
  ui.panel(title: "Contact", count: "", right: [contact_edit_button()], body: [
    html.div([attribute.class("pad-detail")], [
      html.div([attribute.class("kv")], [
        ui.kv(key: "Email", value: email, mono: False),
        ui.kv(key: "Phone", value: phone, mono: True),
        ui.kv(key: "Address", value: postal_address, mono: False),
      ]),
    ]),
  ])
}

fn banking_panel(banking: engineer_view.EngineerBanking) -> Element(Msg) {
  let EngineerBanking(bank:, branch:, account_no:, account_name:, ..) = banking
  ui.panel(
    title: "Banking",
    count: "",
    right: [op_button("Edit", ui.OpUpdateBanking, True)],
    body: [
      html.div([attribute.class("pad-detail")], [
        html.div([attribute.class("kv")], [
          ui.kv(key: "Bank", value: bank, mono: False),
          ui.kv(key: "BSB", value: branch, mono: True),
          ui.kv(key: "Account", value: account_no, mono: True),
          ui.kv(key: "Name", value: account_name, mono: False),
        ]),
      ]),
    ],
  )
}

fn contact_edit_button() -> Element(Msg) {
  op_button("Edit", ui.OpUpdateContact, True)
}

fn employment_panel(
  employment: engineer_view.Employment,
  level: Int,
  emergency: engineer_view.EngineerEmergency,
) -> Element(Msg) {
  let Employment(started:, monthly_salary:, ..) = employment
  let EngineerEmergency(relation:, name:, phone:, ..) = emergency
  let emergency_line = name <> " (" <> relation <> ", " <> phone <> ")"
  ui.panel(
    title: "Employment",
    count: "",
    right: [op_button("Emergency", ui.OpUpdateEmergency, True)],
    body: [
      html.div([attribute.class("pad-detail")], [
        html.div([attribute.class("kv")], [
          ui.kv(key: "Started", value: time.iso_date(started), mono: True),
          ui.kv(key: "Level", value: ui.level_band(level), mono: False),
          ui.kv(
            key: "Monthly salary",
            value: ui.money(money.to_float(monthly_salary)),
            mono: True,
          ),
          ui.kv(key: "Emergency", value: emergency_line, mono: False),
        ]),
      ]),
    ],
  )
}

// --- Op form ----------------------------------------------------------------

/// A button that opens the contextual operation `kind`. `ghost` renders the
/// secondary (outlined) variant.
fn op_button(label: String, kind: ui.OpKind, ghost: Bool) -> Element(Msg) {
  let button_kind = case ghost {
    True -> ui.Ghost
    False -> ui.Primary
  }
  ui.button(label:, kind: button_kind, size: ui.Small, on_press: OpOpened(kind))
}

/// The contextual operation as a centred modal over a dimmed backdrop, shown only
/// while an op is open. Renders the fields the chosen kind needs, the rejection
/// prompt if any, and the Cancel / op-verb Confirm footer.
fn view_op_modal(model: Model, op: Option(ui.OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(ui.OpState(kind:, form:, error:)) ->
      ui.modal(
        title: op_title(kind),
        error: option.unwrap(error, ""),
        body: op_fields(model, kind, form),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: op_verb(kind),
      )
  }
}

/// The form fields each operation kind reads, bound to the shared `OpForm`: the
/// roll-off project is a `<select>` over the as-of directory, the leave kind a fixed
/// `<select>`, and the contact/banking/emergency edits open pre-filled with the
/// loaded values. Only the detail kinds have a populated arm; any other shows just
/// its engineer-id field (a safe fallback never triggered).
fn op_fields(
  model: Model,
  kind: ui.OpKind,
  form: ui.OpForm,
) -> List(Element(Msg)) {
  case kind {
    ui.OpPromote -> [
      number_field("New level", ui.FLevel, form.level),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpTakeLeave -> [
      leave_kind_field(form.kind),
      date_field("From", ui.FValidFrom, form.valid_from),
      date_field("To", ui.FValidTo, form.valid_to),
    ]
    ui.OpRollOff -> [
      ui.ref_select(
        label: "Project",
        field: ui.FProjectId,
        refs: project_refs(model),
        selected: form.project_id,
        to_msg: OpFieldEdited,
      ),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpTerminateEmployment -> [
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpUpdateContact -> [
      text_field("Name", ui.FName, form.name),
      text_field("Email", ui.FEmail, form.email),
      text_field("Phone", ui.FPhone, form.phone),
      text_field("Address", ui.FPostalAddress, form.postal_address),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpUpdateBanking -> [
      text_field("Bank", ui.FBank, form.bank),
      text_field("BSB", ui.FBranch, form.branch),
      text_field("Account", ui.FAccountNo, form.account_no),
      text_field("Account name", ui.FAccountName, form.account_name),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpUpdateEmergency -> [
      text_field("Relation", ui.FRelation, form.relation),
      text_field("Name", ui.FEmergencyName, form.emergency_name),
      text_field("Phone", ui.FEmergencyPhone, form.emergency_phone),
      text_field("Email", ui.FEmergencyEmail, form.emergency_email),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    _ -> [number_field("Engineer id", ui.FEngineerId, form.engineer_id)]
  }
}

/// The leave-kind `<select>` for TakeLeave: a fixed list of leave kinds bound to the
/// form's `kind` slot, so the wire value is always one the domain accepts rather
/// than free text. Defaults to "annual" when the slot is blank.
fn leave_kind_field(selected: String) -> Element(Msg) {
  let selected = case selected {
    "" -> "annual"
    other -> other
  }
  let options =
    list.map(["annual", "sick", "parental", "unpaid"], fn(kind) {
      html.option(
        [attribute.value(kind), attribute.selected(kind == selected)],
        string.capitalise(kind),
      )
    })
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Kind")]),
    html.select(
      [
        attribute.attribute("aria-label", "Kind"),
        event.on_change(fn(value) { OpFieldEdited(field: ui.FKind, value:) }),
      ],
      options,
    ),
  ])
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

fn number_field(
  label: String,
  field: ui.OpField,
  value: String,
) -> Element(Msg) {
  ui.op_field(
    label:,
    field:,
    value:,
    input_type: "number",
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

fn op_title(kind: ui.OpKind) -> String {
  case kind {
    ui.OpPromote -> "Promote"
    ui.OpTakeLeave -> "Take leave"
    ui.OpRollOff -> "Roll off a project"
    ui.OpTerminateEmployment -> "Terminate employment"
    ui.OpUpdateContact -> "Update contact details"
    ui.OpUpdateBanking -> "Update banking details"
    ui.OpUpdateEmergency -> "Update emergency contact"
    _ -> "Operation"
  }
}

/// The confirm-button verb for an operation kind — the action the presenter is
/// committing, not a generic "Apply".
fn op_verb(kind: ui.OpKind) -> String {
  case kind {
    ui.OpPromote -> "Promote"
    ui.OpTakeLeave -> "Take leave"
    ui.OpRollOff -> "Roll off"
    ui.OpTerminateEmployment -> "Terminate"
    ui.OpUpdateContact -> "Save contact"
    ui.OpUpdateBanking -> "Save banking"
    ui.OpUpdateEmergency -> "Save emergency"
    _ -> "Confirm"
  }
}

// --- Small helpers ----------------------------------------------------------

fn float_round(value: Float) -> Int {
  float.round(value)
}

fn string_join(parts: List(String), with separator: String) -> String {
  string.join(parts, separator)
}
