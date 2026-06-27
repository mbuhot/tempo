//// The Clients page (FR-CP1..): the client list as of the global rail date and a
//// single client's detail. The list renders via the generic data table, embedded
//// through `table_host` (which owns the load state, infinite scroll, debounce, and
//// column-layout persistence): it reads `GET /api/clients/table?as_of=&filter.*=&
//// sort=&page_size=&cursor=` for the schema-driven, filtered/sorted/paged rows. The
//// detail reads `GET /api/clients/:id?as_of=` (`ClientDetail`: profile + since +
//// contracts + projects); its embedded Projects/Contracts tables stay small inline
//// reference tables.
////
//// `init` takes the route: `Clients(Some(id))` opens that client's detail (so a cold
//// deep link to `/clients/:id` lands on it), any other route opens the list. The
//// host's `Activated` outcome raises `Navigate(Clients(Some(id)))` so the shell owns
//// the URL. A project row in the detail raises `Navigate(Projects(Some(id)))`.
////
//// Contextual writes: `SignContract` (a client signs a contract over a window) and
//// `UpdateClientProfile` (rename a client effective a date). Both drive the shared
//// `ui` op-form engine through a centred modal; on success the page raises
//// `OperationCommitted` and refetches the active view. The op forms pick the client
//// from the as-of roster (`GET /api/roster?as_of=`, fetched alongside the list).
////
//// Staleness: every fetch-result message carries the `as_of` it answers, and the
//// detail/roster results are dropped when that date no longer matches the model's
//// current as-of (stale-while-revalidate).

import client/api
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/route
import client/table_host
import client/time
import client/ui
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/time/calendar.{type Date}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/client/view.{
  type ClientDetail, type ClientProjectRow, type ContractRow,
} as client_view
import shared/money
import shared/roster/view.{type Ref, type Roster} as roster_view

// --- Model ------------------------------------------------------------------

/// The page's state: the as-of its data answers, the actor (current viewer), the
/// client-list table host, the as-of roster (the directory the op selects pick
/// from), the drilled-in client detail, and any open op form.
pub type Model {
  Model(
    actor: String,
    as_of: calendar.Date,
    host: table_host.Host,
    roster: Option(Result(Roster, String)),
    detail: Detail,
    op: Option(ui.OpState),
  )
}

/// The drill-in sub-state of the list: no client open, a detail loading for a
/// client id, the loaded detail, or a failed detail fetch (kept on screen with its
/// id so a refetch can retry it).
pub type Detail {
  NoDetail
  DetailLoading(client_id: Int)
  DetailLoaded(detail: ClientDetail)
  DetailFailed(client_id: Int, message: String)
}

// --- Messages ---------------------------------------------------------------

/// The page's messages: the table host's sub-messages, the detail/roster fetch
/// results (each carrying the `as_of` it answers for the staleness guard), the
/// navigation actions, and the op lifecycle.
pub type Msg {
  TableHostMsg(sub: table_host.Msg)
  DetailFetched(
    as_of: calendar.Date,
    client_id: Int,
    result: Result(ClientDetail, rsvp.Error(String)),
  )
  RosterFetched(
    as_of: calendar.Date,
    result: Result(Roster, rsvp.Error(String)),
  )
  CloseDetail
  OpenProject(project_id: Int)
  OpStarted(permit: ui.Permit)
  OpCancelled
  OpFieldEdited(field: ui.OpField, value: String)
  OpSubmitted
  OpResponded(result: Result(Nil, rsvp.Error(String)))
}

// --- Lifecycle --------------------------------------------------------------

/// Build the page for `route` at `as_of`, starting the client-list table (and, for
/// `Clients(Some(id))`, that client's detail too — so a cold deep link to
/// `/clients/:id` lands on the detail). The roster is fetched for the op selects.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let #(host, host_effect) = table_host.init("/api/clients/table", as_of)
  let detail = case route {
    route.Clients(id: Some(client_id)) -> DetailLoading(client_id:)
    _ -> NoDetail
  }
  let model = Model(actor:, as_of:, host:, roster: None, detail:, op: None)
  #(
    model,
    effect.batch([
      effect.map(host_effect, TableHostMsg),
      detail_effect(detail, as_of),
      fetch_roster(as_of),
    ]),
  )
}

/// Re-fetch the active view for a new `as_of` (stale-while-revalidate), keeping the
/// open op form and the active filters/sort/layout: re-fetch the table host and the
/// roster, and re-fetch the detail too when one is open (its active flags follow the
/// rail).
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let #(host, host_effect) = table_host.refetch(model.host, as_of)
  let detail = mark_detail_loading(model.detail)
  #(
    Model(..model, actor:, as_of:, host:, roster: None, detail:),
    effect.batch([
      effect.map(host_effect, TableHostMsg),
      detail_effect(detail, as_of),
      fetch_roster(as_of),
    ]),
  )
}

fn detail_effect(detail: Detail, as_of: calendar.Date) -> Effect(Msg) {
  case detail_client_id(detail) {
    Some(client_id) -> fetch_detail(as_of, client_id)
    None -> effect.none()
  }
}

// --- Update -----------------------------------------------------------------

/// Fold a message into the model, returning any cross-page out-messages.
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
            Ok(client_id) -> #(model, effect, [
              Navigate(route.Clients(id: Some(client_id))),
            ])
            Error(Nil) -> #(model, effect, [])
          }
      }
    }

    DetailFetched(as_of:, client_id:, result:) ->
      case model.as_of == as_of && awaiting_detail(model.detail, client_id) {
        False -> #(model, effect.none(), [])
        True -> {
          let detail = case result {
            Ok(detail) -> DetailLoaded(detail:)
            Error(error) ->
              DetailFailed(client_id:, message: api.describe_error(error))
          }
          #(Model(..model, detail:), effect.none(), [])
        }
      }

    RosterFetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let roster = case result {
            Ok(roster) -> Ok(roster)
            Error(error) -> Error(api.describe_error(error))
          }
          let op = reconcile_op_client(model.op, Some(roster))
          #(Model(..model, roster: Some(roster), op:), effect.none(), [])
        }
      }

    CloseDetail -> #(model, effect.none(), [Navigate(route.Clients(id: None))])

    OpenProject(project_id:) -> #(model, effect.none(), [
      Navigate(route.Projects(id: Some(project_id))),
    ])

    OpStarted(permit:) -> {
      let kind = ui.permit_kind(permit)
      let form = ui.blank_op_form(kind, model.as_of)
      let form = prefill_op_form(kind, form, model.detail, model)
      #(
        Model(..model, op: Some(ui.OpState(kind:, form:, error: None))),
        effect.none(),
        [],
      )
    }

    OpCancelled -> #(Model(..model, op: None), effect.none(), [])

    OpFieldEdited(field:, value:) ->
      case model.op {
        Some(op) -> {
          let form = apply_field_edit(model, op, field, value)
          #(
            Model(..model, op: Some(ui.OpState(..op, form:))),
            effect.none(),
            [],
          )
        }
        None -> #(model, effect.none(), [])
      }

    OpSubmitted ->
      case model.op {
        Some(op) ->
          case ui.build_command(op.kind, op.form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OpResponded),
              [],
            )
            Error(prompt) -> #(
              Model(..model, op: Some(ui.OpState(..op, error: Some(prompt)))),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    OpResponded(result:) ->
      case model.op {
        Some(op) ->
          case result {
            Ok(_) -> {
              let #(refetched, refetch_effect) =
                refetch(Model(..model, op: None), model.as_of, model.actor)
              #(refetched, refetch_effect, [OperationCommitted])
            }
            Error(error) -> #(
              Model(
                ..model,
                op: Some(
                  ui.OpState(..op, error: Some(api.describe_error(error))),
                ),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }
  }
}

// --- Fetch helpers ----------------------------------------------------------

/// Fetch one client's detail for `as_of`, tagging the result with both the date and
/// the client id it answers (so a stale or superseded detail is dropped).
fn fetch_detail(as_of: calendar.Date, client_id: Int) -> Effect(Msg) {
  api.get(
    "/api/clients/"
      <> int.to_string(client_id)
      <> "?as_of="
      <> time.iso_date(as_of),
    client_view.client_detail_decoder(),
    fn(result) { DetailFetched(as_of:, client_id:, result:) },
  )
}

/// Fetch the as-of roster (the client directory the op selects pick from), tagging
/// the result with the date it answers for the staleness guard.
fn fetch_roster(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/roster?as_of=" <> time.iso_date(as_of),
    roster_view.roster_decoder(),
    fn(result) { RosterFetched(as_of:, result:) },
  )
}

// --- Detail helpers ---------------------------------------------------------

/// Whether a detail-fetch result is still wanted: it matches the client id the
/// detail sub-state is currently awaiting or showing.
fn awaiting_detail(detail: Detail, client_id: Int) -> Bool {
  detail_client_id(detail) == Some(client_id)
}

/// The client id an open detail is for (loading, loaded, or failed), or `None` when
/// no client is drilled in.
fn detail_client_id(detail: Detail) -> Option(Int) {
  case detail {
    NoDetail -> None
    DetailLoading(client_id:) -> Some(client_id)
    DetailLoaded(detail: client_view.ClientDetail(
      profile: client_view.ClientProfile(client_id:, ..),
      ..,
    )) -> Some(client_id)
    DetailFailed(client_id:, ..) -> Some(client_id)
  }
}

/// Put an open detail back into its loading state for a refetch, remembering which
/// client it is for (so the incoming result is matched and the spinner shows).
fn mark_detail_loading(detail: Detail) -> Detail {
  case detail_client_id(detail) {
    Some(client_id) -> DetailLoading(client_id:)
    None -> NoDetail
  }
}

// --- View -------------------------------------------------------------------

/// Render the page for `as_of`: the client detail when one is drilled in, otherwise
/// the client list (the generic data table). The optional op form layers above
/// either view.
pub fn view(
  model: Model,
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  let _ = as_of
  case model.detail {
    NoDetail -> view_list(model, permissions)
    _ -> view_detail(model.detail, model.roster, model.op, permissions)
  }
}

/// The client list: a header with the Sign-contract action, the optional op form,
/// and the clients data table (name, since, projects, status) through its host
/// (which owns the loading / failed guards). Each row drills into that client.
fn view_list(model: Model, permissions: Set(String)) -> Element(Msg) {
  html.div([], [
    ui.page_head(
      title: "Clients",
      blurb: "Who we work for, and the contracts behind the projects.",
      actions: [op_trigger(permissions, "+ Sign contract", ui.OpSignContract)],
    ),
    op_panel(model.roster, model.op),
    ui.panel(title: "All clients", count: "", right: [], body: [
      element.map(table_host.view(model.host, "Loading clients…"), TableHostMsg),
    ]),
  ])
}

/// The client-detail page: a back link, a header carrying the durable client name
/// and since date, the optional op form, then a two-column grid of the client's
/// projects (active/ended as-of) and a profile/contracts panel.
fn view_detail(
  detail: Detail,
  roster: Option(Result(Roster, String)),
  op: Option(ui.OpState),
  permissions: Set(String),
) -> Element(Msg) {
  case detail {
    NoDetail -> ui.empty_state(message: "No client selected.")
    DetailLoading(..) ->
      html.div([], [back_link(), ui.empty_state(message: "Loading client…")])
    DetailFailed(message:, ..) ->
      html.div([], [
        back_link(),
        ui.empty_state(message: "Could not load client: " <> message),
      ])
    DetailLoaded(detail: loaded) ->
      view_detail_loaded(loaded, roster, op, permissions)
  }
}

fn view_detail_loaded(
  detail: ClientDetail,
  roster: Option(Result(Roster, String)),
  op: Option(ui.OpState),
  permissions: Set(String),
) -> Element(Msg) {
  let client_view.ClientDetail(profile:, since:, contracts:, projects:) = detail
  let client_view.ClientProfile(name:, ..) = profile
  html.div([], [
    back_link(),
    ui.page_head(
      title: name,
      blurb: "Client since " <> option_date(since) <> ".",
      actions: [
        op_trigger(permissions, "Sign contract", ui.OpSignContract),
        op_trigger(permissions, "Edit profile", ui.OpUpdateClientProfile),
      ],
    ),
    op_panel(roster, op),
    html.div([attribute.class("detail-grid")], [
      html.div([], [view_projects_panel(projects)]),
      html.div([], [view_profile_panel(name, since, contracts)]),
    ]),
  ])
}

/// The client's projects panel (a small embedded reference table): each project row
/// shows its swatch + title, budget, target date, and an active/ended pill computed
/// as-of. Clicking a row opens that project's detail (a cross-page navigation).
fn view_projects_panel(projects: List(ClientProjectRow)) -> Element(Msg) {
  ui.panel(
    title: "Projects",
    count: int.to_string(list.length(projects)),
    right: [],
    body: [
      case projects {
        [] -> ui.empty_state(message: "No projects for this client.")
        rows ->
          ui.data_table(
            headers: [
              #("Project", False),
              #("Budget", True),
              #("Target", False),
              #("State", False),
            ],
            rows: list.map(rows, view_project_row),
          )
      },
    ],
  )
}

fn view_project_row(project: ClientProjectRow) -> Element(Msg) {
  let client_view.ClientProjectRow(
    project_id:,
    title:,
    budget:,
    target_completion:,
    active:,
    ..,
  ) = project
  html.tr(
    [attribute.class("clickable"), event.on_click(OpenProject(project_id:))],
    [
      html.td([], [
        ui.swatch(category: project_id, inline: True),
        html.text(title),
      ]),
      html.td([attribute.class("num")], [
        html.text(ui.money_k(money.to_float(budget))),
      ]),
      html.td([attribute.class("mono muted")], [
        html.text(time.iso_date(target_completion)),
      ]),
      html.td([], [status_pill(active)]),
    ],
  )
}

/// The profile panel: the client's durable name and since date, and a list of
/// contract terms with their windows and active/ended state as-of (an embedded
/// reference table).
fn view_profile_panel(
  name: String,
  since: Option(Date),
  contracts: List(ContractRow),
) -> Element(Msg) {
  ui.panel(title: "Profile", count: "", right: [], body: [
    html.div([attribute.class("pad-detail")], [
      html.div([attribute.class("kv")], [
        ui.kv(key: "Name", value: name, mono: False),
        ui.kv(key: "Client since", value: option_date(since), mono: True),
        ui.kv(
          key: "Contracts",
          value: int.to_string(list.length(contracts)),
          mono: False,
        ),
      ]),
      view_contracts(contracts),
    ]),
  ])
}

fn view_contracts(contracts: List(ContractRow)) -> Element(Msg) {
  case contracts {
    [] -> ui.empty_state(message: "No contracts signed.")
    rows ->
      ui.data_table(
        headers: [#("Contract", False), #("Term", False), #("State", False)],
        rows: list.map(rows, view_contract_row),
      )
  }
}

fn view_contract_row(contract: ContractRow) -> Element(Msg) {
  let client_view.ContractRow(contract_id:, valid_from:, valid_to:, active:) =
    contract
  html.tr([], [
    html.td([attribute.class("mono")], [
      html.text("#" <> int.to_string(contract_id)),
    ]),
    html.td([attribute.class("mono muted")], [
      html.text(time.iso_date(valid_from) <> " → " <> time.iso_date(valid_to)),
    ]),
    html.td([], [status_pill(active)]),
  ])
}

// --- Op form ----------------------------------------------------------------

/// A header button that opens a contextual operation's form.
fn op_trigger(
  permissions: Set(String),
  label: String,
  kind: ui.OpKind,
) -> Element(Msg) {
  ui.launch(
    ui.permit(permissions, own: False, kind:),
    to_msg: OpStarted,
    label: label,
    kind: ui.Primary,
    size: ui.Medium,
  )
}

/// The open op form (or nothing) as a centred modal over a dimmed backdrop: the
/// kind's fields, any rejection line, and a Cancel / op-verb footer.
fn op_panel(
  roster: Option(Result(Roster, String)),
  op: Option(ui.OpState),
) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(ui.OpState(kind:, form:, error:)) ->
      ui.modal(
        title: op_title(kind),
        error: option.unwrap(error, ""),
        body: op_fields(roster, kind, form),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: op_verb(kind),
      )
  }
}

/// The fields each Clients write needs, bound to the shared `OpForm` slots. The
/// client is picked from the as-of roster via a `ref_select`; for `SignContract` the
/// selected slot is the client NAME the command field reads, so the select's
/// `selected` is the id resolved back from that name. For `UpdateClientProfile` the
/// client id and name are pre-filled from the loaded detail and the id is shown
/// read-only.
fn op_fields(
  roster: Option(Result(Roster, String)),
  kind: ui.OpKind,
  form: ui.OpForm,
) -> List(Element(Msg)) {
  case kind {
    ui.OpSignContract -> [
      ui.ref_select(
        label: "Client",
        field: ui.FClient,
        refs: client_refs(roster),
        selected: client_id_for_name(roster, form.client),
        to_msg: OpFieldEdited,
      ),
      ui.op_field(
        "Valid from",
        ui.FValidFrom,
        form.valid_from,
        "date",
        OpFieldEdited,
      ),
      ui.op_field("Valid to", ui.FValidTo, form.valid_to, "date", OpFieldEdited),
    ]
    ui.OpUpdateClientProfile -> [
      locked_field("Client", form.name),
      ui.op_field("Name", ui.FName, form.name, "text", OpFieldEdited),
      ui.op_field(
        "Effective",
        ui.FEffective,
        form.effective,
        "date",
        OpFieldEdited,
      ),
    ]
    _ -> []
  }
}

/// A read-only labelled field showing a pre-filled, non-editable value (here the
/// client whose profile is being edited — known from the detail, so not asked for).
fn locked_field(label: String, value: String) -> Element(Msg) {
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text(label)]),
    html.input([
      attribute.type_("text"),
      attribute.attribute("aria-label", label),
      attribute.value(value),
      attribute.disabled(True),
    ]),
  ])
}

/// The op form's heading for a kind.
fn op_title(kind: ui.OpKind) -> String {
  case kind {
    ui.OpSignContract -> "Sign a contract"
    ui.OpUpdateClientProfile -> "Update client profile"
    _ -> "Operation"
  }
}

/// The confirm-button verb for a kind.
fn op_verb(kind: ui.OpKind) -> String {
  case kind {
    ui.OpSignContract -> "Sign contract"
    ui.OpUpdateClientProfile -> "Save profile"
    _ -> "Confirm"
  }
}

// --- Op pre-fill / field mapping --------------------------------------------

/// Seed a freshly-opened op form from context. `UpdateClientProfile` is launched
/// from a loaded client detail, which knows the client id and name — so both slots
/// are pre-filled (the id is then shown read-only). `SignContract` snaps its client
/// slot to the first roster client when the roster has loaded, so the modal opens on
/// a valid selection. Other kinds open blank.
fn prefill_op_form(
  kind: ui.OpKind,
  form: ui.OpForm,
  detail: Detail,
  model: Model,
) -> ui.OpForm {
  case kind {
    ui.OpUpdateClientProfile ->
      case detail {
        DetailLoaded(detail: client_view.ClientDetail(
          profile: client_view.ClientProfile(client_id:, name:),
          ..,
        )) -> {
          let form =
            ui.update_op_form(form, ui.FClientId, int.to_string(client_id))
          ui.update_op_form(form, ui.FName, name)
        }
        _ -> form
      }
    ui.OpSignContract ->
      case client_refs(model.roster) {
        [first, ..] -> ui.update_op_form(form, ui.FClient, first.name)
        [] -> form
      }
    _ -> form
  }
}

/// Snap an open `SignContract` op's client slot to the first roster client once the
/// roster lands, when it is still empty — so a modal opened before the roster arrived
/// ends up on a valid selection rather than a blank one. Leaves any other open op (or
/// none) untouched.
fn reconcile_op_client(
  op: Option(ui.OpState),
  roster: Option(Result(Roster, String)),
) -> Option(ui.OpState) {
  case op {
    Some(ui.OpState(kind: ui.OpSignContract, form:, ..) as state) ->
      case form.client, client_refs(roster) {
        "", [first, ..] ->
          Some(
            ui.OpState(
              ..state,
              form: ui.update_op_form(form, ui.FClient, first.name),
            ),
          )
        _, _ -> op
      }
    _ -> op
  }
}

/// Fold an op-form field edit, translating the `SignContract` client `<select>`
/// (which reports the chosen client's ID) into the client NAME its command field
/// expects, so `build_command(OpSignContract)` still reads `form.client` as a name.
/// Every other field writes through unchanged.
fn apply_field_edit(
  model: Model,
  op: ui.OpState,
  field: ui.OpField,
  value: String,
) -> ui.OpForm {
  case op.kind, field {
    ui.OpSignContract, ui.FClient ->
      ui.update_op_form(op.form, ui.FClient, client_name_for_id(model, value))
    _, _ -> ui.update_op_form(op.form, field, value)
  }
}

// --- Roster directory (client Refs for op selects) --------------------------

/// The client directory for the op `<select>`s, from the as-of roster (every client,
/// id + name). Empty until the roster loads.
fn client_refs(roster: Option(Result(Roster, String))) -> List(Ref) {
  case roster {
    Some(Ok(roster)) -> roster.clients
    _ -> []
  }
}

/// The client NAME for a chosen client id, resolved through the as-of roster, so a
/// `SignContract` client `<select>` can store the name its command field reads. The
/// unchanged id string when the roster has not loaded or the id is absent.
fn client_name_for_id(model: Model, id: String) -> String {
  client_refs(model.roster)
  |> list.find(fn(reference) { int.to_string(reference.id) == id })
  |> result.map(fn(reference) { reference.name })
  |> result.unwrap(id)
}

/// The id string a client `<select>` should show as selected for a stored client
/// NAME, resolved through the as-of roster (the inverse of `client_name_for_id`). The
/// empty string when the name has not yet resolved, so the select shows no selection
/// rather than a wrong one.
fn client_id_for_name(
  roster: Option(Result(Roster, String)),
  name: String,
) -> String {
  client_refs(roster)
  |> list.find(fn(reference) { reference.name == name })
  |> result.map(fn(reference) { int.to_string(reference.id) })
  |> result.unwrap("")
}

// --- Small view helpers -----------------------------------------------------

/// The "‹ All clients" back link returning to the list: navigating to the list route
/// (the navigation is raised when `CloseDetail` folds).
fn back_link() -> Element(Msg) {
  html.a([attribute.class("back-link"), event.on_click(CloseDetail)], [
    html.text("‹ All clients"),
  ])
}

/// An active/ended status pill.
fn status_pill(active: Bool) -> Element(Msg) {
  case active {
    True -> ui.pill(variant: "active", label: "active")
    False -> ui.pill(variant: "ended", label: "ended")
  }
}

/// Render an optional date as ISO "YYYY-MM-DD", or an em dash when absent.
fn option_date(date: Option(Date)) -> String {
  case date {
    Some(date) -> time.iso_date(date)
    None -> "—"
  }
}
