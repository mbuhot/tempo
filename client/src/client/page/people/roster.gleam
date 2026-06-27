//// The People roster list (FR-PE*), a self-contained sub-component MVU split out
//// of `client/page/people`. This is the page's LIST mode: it owns its own `Model`
//// (its as-of, the roster table load state, the as-of operations directory, and the
//// open Onboard-engineer op form), its own `Msg`, its `init`/`update`, and its
//// `view`.
////
//// The roster list renders via the generic data table (`client/table`): it reads
//// `GET /api/people/table?as_of=&filter.*=&sort=&page_size=&cursor=` for the schema-
//// driven, filtered/sorted/paged rows, and `GET /api/roster?as_of=` for the op-form
//// directory. Each result carries the `as_of` it answers so a stale reply is dropped.
//// Its one write is OnboardEngineer; submitting posts via `api.submit_operation` and,
//// on success, raises `OperationCommitted` and refetches. The table's `Activated`
//// outcome raises `Navigate(People(Some(id)))` so the shell owns the URL (the detail
//// mode is a different sub-component).

import client/api
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/route
import client/scheduler
import client/storage
import client/table
import client/time
import client/ui
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import gleam/time/calendar
import gleam/uri
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import rsvp
import shared/roster/view.{type Ref, type Roster} as roster_view
import shared/table/column
import shared/table/response.{type Row, type TableResponse}

/// The roster list's state: the as-of its data answers, the roster table load
/// state, the as-of operations directory (project `Ref`s for the op form), and the
/// open Onboard-engineer op form (or `None`).
pub type Model {
  Model(
    as_of: calendar.Date,
    table: Load,
    roster: Directory,
    op: Option(ui.OpState),
  )
}

/// The roster table's load state. `Loaded` holds the server schema, the rows
/// accumulated across "Load more" pages, the opaque `next_cursor` for the following
/// page, and the local table view state (sort/filters/column layout).
pub type Load {
  Loading
  Loaded(
    schema: column.Schema,
    rows: List(Row),
    next_cursor: Option(String),
    table_state: table.State,
  )
  LoadFailed(message: String)
}

/// The as-of operations directory's load state.
pub type Directory {
  DirectoryLoading
  DirectoryLoaded(roster: Roster)
  DirectoryFailed(message: String)
}

/// The list mode's messages: the table / load-more / directory fetch results (each
/// carrying the `as_of` they answer), the table sub-messages, the Onboard op
/// lifecycle, and the operation reply.
pub type Msg {
  GotTable(
    as_of: calendar.Date,
    result: Result(TableResponse, rsvp.Error(String)),
  )
  GotMore(
    as_of: calendar.Date,
    result: Result(TableResponse, rsvp.Error(String)),
  )
  TableMsg(sub: table.Msg)
  DirectoryFetched(
    as_of: calendar.Date,
    result: Result(Roster, rsvp.Error(String)),
  )
  OpOpened(permit: ui.Permit)
  OpCancelled
  OpFieldEdited(field: ui.OpField, value: String)
  OpSubmitted
  OperationReturned(result: Result(Nil, rsvp.Error(String)))
}

/// Start the list mode at `as_of`, fetching the roster table and the directory.
pub fn init(as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let model = Model(as_of:, table: Loading, roster: DirectoryLoading, op: None)
  #(
    model,
    effect.batch([
      fetch_table(as_of, table.initial_params()),
      fetch_directory(as_of),
    ]),
  )
}

/// Re-fetch the list mode for a new `as_of` (stale-while-revalidate), keeping any
/// open op form and the active filters/sort/layout.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  #(
    Model(..model, as_of:, roster: DirectoryLoading),
    effect.batch([
      fetch_table(as_of, current_params(model)),
      fetch_directory(as_of),
    ]),
  )
}

fn current_params(model: Model) -> List(#(String, String)) {
  case model.table {
    Loaded(table_state:, ..) -> table.params(table_state)
    _ -> []
  }
}

fn fetch_table(
  as_of: calendar.Date,
  params: List(#(String, String)),
) -> Effect(Msg) {
  api.get(table_url(as_of, params), response.response_decoder(), GotTable(
    as_of,
    _,
  ))
}

fn fetch_more(
  as_of: calendar.Date,
  params: List(#(String, String)),
  cursor: String,
) -> Effect(Msg) {
  api.get(
    table_url(as_of, list.append(params, [#("cursor", cursor)])),
    response.response_decoder(),
    GotMore(as_of, _),
  )
}

fn table_url(as_of: calendar.Date, params: List(#(String, String))) -> String {
  let base = "/api/people/table?as_of=" <> time.iso_date(as_of)
  case params {
    [] -> base
    _ -> base <> "&" <> query_string(params)
  }
}

fn query_string(params: List(#(String, String))) -> String {
  params
  |> list.map(fn(pair) { pair.0 <> "=" <> uri.percent_encode(pair.1) })
  |> string.join("&")
}

fn fetch_directory(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/roster?as_of=" <> time.iso_date(as_of),
    roster_view.roster_decoder(),
    fn(result) { DirectoryFetched(as_of:, result:) },
  )
}

// --- Update -----------------------------------------------------------------

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    GotTable(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True ->
          case result {
            Error(error) -> #(
              Model(
                ..model,
                table: LoadFailed(message: api.describe_error(error)),
              ),
              effect.none(),
              [],
            )
            Ok(table_response) -> {
              let table_state = case model.table {
                Loaded(table_state:, ..) ->
                  table.reconcile(table_state, table_response.schema)
                _ -> initial_state(table_response.schema)
              }
              let load =
                Loaded(
                  schema: table_response.schema,
                  rows: table_response.rows,
                  next_cursor: table_response.page.next_cursor,
                  table_state:,
                )
              #(Model(..model, table: load), effect.none(), [])
            }
          }
      }

    GotMore(as_of:, result:) ->
      case model.as_of == as_of, model.table, result {
        True, Loaded(schema:, rows:, table_state:, ..), Ok(table_response) -> {
          let load =
            Loaded(
              schema:,
              rows: list.append(rows, table_response.rows),
              next_cursor: table_response.page.next_cursor,
              table_state: table.reconcile(table_state, table_response.schema),
            )
          #(Model(..model, table: load), effect.none(), [])
        }
        _, _, _ -> #(model, effect.none(), [])
      }

    TableMsg(sub:) -> on_table_msg(model, sub)

    DirectoryFetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let roster = case result {
            Ok(roster) -> DirectoryLoaded(roster:)
            Error(error) -> DirectoryFailed(message: api.describe_error(error))
          }
          #(Model(..model, roster:), effect.none(), [])
        }
      }

    OpOpened(permit:) -> {
      let kind = ui.permit_kind(permit)
      #(
        Model(
          ..model,
          op: Some(ui.OpState(kind:, form: blank_form(model, kind), error: None)),
        ),
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

/// Build the table state for a freshly loaded schema, applying any saved column
/// layout from local storage.
fn initial_state(schema: column.Schema) -> table.State {
  let base = table.init(schema)
  case storage.get(table.layout_key(base)) {
    Some(layout) -> table.with_layout(base, layout, schema)
    None -> base
  }
}

/// Fold a table sub-message: thread it through `table.update` and act on the
/// `Outcome` — re-query (fresh), append the next page, persist the layout, schedule
/// the debounce settle, or open the clicked engineer.
fn on_table_msg(
  model: Model,
  sub: table.Msg,
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model.table {
    Loaded(schema:, rows:, next_cursor:, table_state:) -> {
      let #(next_state, outcome) = table.update(table_state, sub)
      let updated =
        Loaded(schema:, rows:, next_cursor:, table_state: next_state)
      let model = Model(..model, table: updated)
      case outcome {
        table.Idle -> #(model, effect.none(), [])
        table.Requery(params:) -> #(model, fetch_table(model.as_of, params), [])
        table.AppendPage(params:) ->
          case next_cursor {
            Some(cursor) -> #(
              model,
              fetch_more(model.as_of, params, cursor),
              [],
            )
            None -> #(model, effect.none(), [])
          }
        table.Persist(layout:) -> #(
          model,
          storage.set(table.layout_key(next_state), layout),
          [],
        )
        table.Schedule(token:) -> #(
          model,
          scheduler.after(table.debounce_ms, TableMsg(table.SettleFired(token))),
          [],
        )
        table.Activated(id:) ->
          case int.parse(id) {
            Ok(engineer_id) -> #(model, effect.none(), [
              Navigate(route.People(id: Some(engineer_id))),
            ])
            Error(Nil) -> #(model, effect.none(), [])
          }
      }
    }
    _ -> #(model, effect.none(), [])
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

/// A fresh op form for `kind`: every entity slot snapped to a valid directory
/// option and dates defaulting to the as-of. The list mode only raises
/// OnboardEngineer, whose fields are typed free-text, so no detail prefill applies.
fn blank_form(model: Model, kind: ui.OpKind) -> ui.OpForm {
  let form = ui.blank_op_form(kind, model.as_of)
  ui.reconcile_form(form, [], project_refs(model))
}

/// The active project `Ref`s from the loaded directory, for the op-form
/// `<select>`s. Empty until the directory loads.
fn project_refs(model: Model) -> List(Ref) {
  case model.roster {
    DirectoryLoaded(roster:) -> roster.projects
    _ -> []
  }
}

// --- View -------------------------------------------------------------------

/// Render the list mode: the page head with the Onboard action, the op modal, and
/// the roster panel (its own loading / failed guards), the roster rendered via the
/// generic data table.
pub fn view(model: Model, permissions: Set(String)) -> Element(Msg) {
  let head =
    ui.page_head(
      title: "People",
      blurb: "Everyone employed as of "
        <> time.iso_date(model.as_of)
        <> ". Open a person for their full record and history.",
      actions: [
        ui.launch(
          ui.permit(permissions, own: False, kind: ui.OpOnboardEngineer),
          to_msg: OpOpened,
          label: "+ Onboard",
          kind: ui.Primary,
          size: ui.Small,
        ),
      ],
    )
  let op_modal = view_op_modal(model.op)
  let body = case model.table {
    Loading -> ui.empty_state("Loading roster…")
    LoadFailed(message:) ->
      ui.empty_state("Could not load the roster: " <> message)
    Loaded(schema:, rows:, next_cursor:, table_state:) ->
      list_view(schema, rows, next_cursor, table_state)
  }
  column([head, op_modal, body])
}

fn column(children: List(Element(Msg))) -> Element(Msg) {
  html.div([], children)
}

/// The roster table: the generic data table (schema-driven rows, filters, sort,
/// pagination, column layout) wrapped in the Roster panel. The table's own messages
/// are mapped onto the list mode's `TableMsg`.
fn list_view(
  schema: column.Schema,
  rows: List(Row),
  next_cursor: Option(String),
  table_state: table.State,
) -> Element(Msg) {
  ui.panel(title: "Roster", count: "", right: [], body: [
    element.map(
      table.view(schema, rows, table_state, option.is_some(next_cursor)),
      TableMsg,
    ),
  ])
}

/// The Onboard-engineer op as a centred modal, shown only while open. The list
/// mode raises only OnboardEngineer, so the modal is fixed to that op.
fn view_op_modal(op: Option(ui.OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(ui.OpState(form:, error:, ..)) ->
      ui.modal(
        title: "Onboard an engineer",
        error: option.unwrap(error, ""),
        body: op_fields(form),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: "Onboard",
      )
  }
}

fn op_fields(form: ui.OpForm) -> List(Element(Msg)) {
  [
    text_field("Name", ui.FName, form.name),
    number_field("Level", ui.FLevel, form.level),
    date_field("Effective", ui.FEffective, form.effective),
  ]
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
