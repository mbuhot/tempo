//// The People roster list (FR-PE*), a self-contained sub-component MVU split out
//// of `client/page/people`. This is the page's LIST mode: it owns its own `Model`
//// (its as-of, the roster table host, the as-of operations directory, and the open
//// Onboard-engineer op form), its own `Msg`, its `init`/`update`, and its `view`.
////
//// The roster list renders via the generic data table, embedded through `table_host`
//// (which owns the load state, infinite scroll, debounce, and column-layout
//// persistence): it reads `GET /api/people/table?as_of=&filter.*=&sort=&page_size=&
//// cursor=` for the schema-driven, filtered/sorted/paged rows, and `GET /api/roster?
//// as_of=` for the op-form directory. Each result carries the `as_of` it answers so
//// a stale reply is dropped. Its one write is OnboardEngineer; submitting posts via
//// `api.submit_operation` and, on success, raises `OperationCommitted` and refetches.
//// The host's `Activated` outcome raises `Navigate(People(Some(id)))` so the shell
//// owns the URL (the detail mode is a different sub-component).

import client/api
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/route
import client/table_host
import client/time
import client/ui
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/time/calendar
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import rsvp
import shared/roster/view.{type Ref, type Roster} as roster_view

/// The roster list's state: the as-of its data answers, the roster table host, the
/// as-of operations directory (project `Ref`s for the op form), and the open
/// Onboard-engineer op form (or `None`).
pub type Model {
  Model(
    as_of: calendar.Date,
    host: table_host.Host,
    roster: Directory,
    op: Option(ui.OpState),
  )
}

/// The as-of operations directory's load state.
pub type Directory {
  DirectoryLoading
  DirectoryLoaded(roster: Roster)
  DirectoryFailed(message: String)
}

/// The list mode's messages: the table host's sub-messages, the directory fetch
/// result (carrying the `as_of` it answers), the Onboard op lifecycle, and the
/// operation reply.
pub type Msg {
  TableHostMsg(sub: table_host.Msg)
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
  let #(host, host_effect) = table_host.init("/api/people/table", as_of)
  let model = Model(as_of:, host:, roster: DirectoryLoading, op: None)
  #(
    model,
    effect.batch([
      effect.map(host_effect, TableHostMsg),
      fetch_directory(as_of),
    ]),
  )
}

/// Re-fetch the list mode for a new `as_of` (stale-while-revalidate), keeping any
/// open op form and the active filters/sort/layout.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let #(host, host_effect) = table_host.refetch(model.host, as_of)
  #(
    Model(..model, as_of:, host:, roster: DirectoryLoading),
    effect.batch([
      effect.map(host_effect, TableHostMsg),
      fetch_directory(as_of),
    ]),
  )
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
    TableHostMsg(sub:) -> {
      let #(host, host_effect, out) =
        table_host.update(model.host, sub, model.as_of)
      let model = Model(..model, host:)
      let effect = effect.map(host_effect, TableHostMsg)
      case out {
        table_host.Stay -> #(model, effect, [])
        table_host.Activated(id:) ->
          case int.parse(id) {
            Ok(engineer_id) -> #(model, effect, [
              Navigate(route.People(id: Some(engineer_id))),
            ])
            Error(Nil) -> #(model, effect, [])
          }
        table_host.ActionInvoked(..) -> #(model, effect, [])
      }
    }

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
/// the roster panel (the roster rendered via the generic data table through its
/// host, which owns the loading / failed guards).
pub fn view(model: Model, permissions: Set(String)) -> Element(Msg) {
  let op_modal = view_op_modal(model.op)
  let list_page =
    ui.list_page(
      title: "People",
      blurb: "Everyone employed as of "
        <> time.iso_date(model.as_of)
        <> ". Open a person for their full record and history.",
      actions: [
        ui.page_action(
          ui.permit(permissions, own: False, kind: ui.OpOnboardEngineer),
          OpOpened,
          "+ Onboard",
        ),
      ],
      body: element.map(
        table_host.view(model.host, "Loading roster…"),
        TableHostMsg,
      ),
    )
  html.div([], [op_modal, list_page])
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
