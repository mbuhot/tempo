//// The Clients page (FR-CP1..): the client list as of the global rail date and a
//// single client's detail. The list reads `GET /api/clients?as_of=`
//// (`ClientList`: name / since / project_count / active); the detail reads
//// `GET /api/clients/:id?as_of=` (`ClientDetail`: profile + since + contracts +
//// projects). The detail FETCHES with the as-of — the profile name is durable,
//// but `ContractRow.active` / `ClientProjectRow.active` follow the rail.
////
//// `init` takes the route: `Clients(Some(id))` opens that client's detail (so a
//// cold deep link to `/clients/:id` lands on it), any other route opens the list.
//// Drilling into a client raises `Navigate(Clients(Some(id)))` only — the shell
//// pushes the URL and re-inits the page, so cold and click-through paths are one.
//// A project row in the detail raises `Navigate(Projects(Some(project_id)))`.
////
//// Contextual writes: `SignContract` (a client signs a contract over a window) and
//// `UpdateClientProfile` (rename a client effective a date). Both drive the shared
//// `ui` op-form engine; on success the page raises `OperationCommitted` and
//// refetches the active view.
////
//// Staleness: every fetch-result message carries the `as_of` it answers, and the
//// list/detail results are dropped when that date no longer matches the model's
//// current as-of (stale-while-revalidate; a fresh view or a half-typed op form is
//// never clobbered).

import client/api
import client/route
import client/time
import client/ui
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/codecs
import shared/types.{
  type ClientDetail, type ClientList, type ClientListRow, type ClientProjectRow,
  type ContractRow,
}

// --- Model ------------------------------------------------------------------

/// The page's state. `Loading` until the first list arrives (carrying any
/// deep-linked client id so the list transition can drill straight in), `Failed`
/// on a rejected list fetch, otherwise `Loaded` carrying the list, the as-of it
/// answers, the optional drilled-in client detail, and any open op form.
pub type Model {
  Loading(actor: String, pending: Option(Int))
  Failed(actor: String, message: String)
  Loaded(
    actor: String,
    as_of: calendar.Date,
    list: ClientList,
    detail: Detail,
    op: Option(OpState),
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

/// An open contextual-operation form: which write it composes, the typed field
/// values, and the last submission error (a validation prompt or a server
/// rejection) to surface beneath it.
pub type OpState {
  OpState(kind: ui.OpKind, form: ui.OpForm, error: Option(String))
}

// --- Messages ---------------------------------------------------------------

/// The page's messages. List/detail fetch results carry the `as_of` they answer
/// for the staleness guard; the op messages drive the shared form engine.
pub type Msg {
  ListFetched(
    as_of: calendar.Date,
    result: Result(ClientList, rsvp.Error(String)),
  )
  DetailFetched(
    as_of: calendar.Date,
    client_id: Int,
    result: Result(ClientDetail, rsvp.Error(String)),
  )
  OpenClient(client_id: Int)
  CloseDetail
  OpenProject(project_id: Int)
  OpStarted(kind: ui.OpKind)
  OpCancelled
  OpFieldEdited(field: ui.OpField, value: String)
  OpSubmitted
  OpResponded(result: Result(List(types.Event), rsvp.Error(String)))
}

/// The cross-page effects this page raises: navigate to a route (the shell owns
/// the URL) or signal a committed write. Identical across all seven pages.
pub type OutMsg {
  Navigate(route.Route)
  OperationCommitted
}

// --- Lifecycle --------------------------------------------------------------

/// Build the page for `route` at `as_of`, kicking off the client-list fetch (and,
/// for `Clients(Some(id))`, that client's detail too — so a cold deep link to
/// `/clients/:id` lands on the detail). The pending id rides on `Loading` so the
/// list transition drills straight in once the list arrives.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  case route {
    route.Clients(id: Some(client_id)) -> #(
      Loading(actor:, pending: Some(client_id)),
      effect.batch([fetch_list(as_of), fetch_detail(as_of, client_id)]),
    )
    _ -> #(Loading(actor:, pending: None), fetch_list(as_of))
  }
}

/// Re-fetch the active view for a new `as_of` without dropping the open op form:
/// always re-fetch the list, and re-fetch the detail too when one is open (its
/// active flags follow the rail). The op form is preserved across the refetch.
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  case model {
    Loading(pending: Some(client_id), ..) -> #(
      Loading(actor:, pending: Some(client_id)),
      effect.batch([fetch_list(as_of), fetch_detail(as_of, client_id)]),
    )
    Loading(..) | Failed(..) -> #(
      Loading(actor:, pending: None),
      fetch_list(as_of),
    )
    Loaded(detail:, ..) -> {
      let detail_effect = case detail_client_id(detail) {
        Some(client_id) -> fetch_detail(as_of, client_id)
        None -> effect.none()
      }
      let detail = mark_detail_loading(detail)
      #(
        Loaded(..model, actor:, as_of:, detail:),
        effect.batch([fetch_list(as_of), detail_effect]),
      )
    }
  }
}

/// Fold a message into the model, returning any cross-page out-messages.
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    ListFetched(as_of:, result:) ->
      case stale(model, as_of) {
        True -> #(model, effect.none(), [])
        False ->
          case result {
            Ok(client_list) -> {
              let pending = pending_detail(model)
              let detail_effect = case pending {
                Some(client_id) -> fetch_detail(as_of, client_id)
                None -> effect.none()
              }
              #(loaded_with_list(model, as_of, client_list), detail_effect, [])
            }
            Error(error) -> #(fail(model, error), effect.none(), [])
          }
      }

    DetailFetched(as_of:, client_id:, result:) ->
      case model {
        Loaded(detail:, ..) ->
          case stale(model, as_of) || !awaiting_detail(detail, client_id) {
            True -> #(model, effect.none(), [])
            False -> {
              let detail = case result {
                Ok(detail) -> DetailLoaded(detail:)
                Error(error) ->
                  DetailFailed(client_id:, message: api.describe_error(error))
              }
              #(Loaded(..model, detail:), effect.none(), [])
            }
          }
        _ -> #(model, effect.none(), [])
      }

    OpenClient(client_id:) -> #(model, effect.none(), [
      Navigate(route.Clients(id: Some(client_id))),
    ])

    CloseDetail -> #(model, effect.none(), [Navigate(route.Clients(id: None))])

    OpenProject(project_id:) -> #(model, effect.none(), [
      Navigate(route.Projects(id: Some(project_id))),
    ])

    OpStarted(kind:) ->
      case model {
        Loaded(as_of:, ..) -> #(
          Loaded(
            ..model,
            op: Some(OpState(
              kind:,
              form: ui.blank_op_form(kind, as_of),
              error: None,
            )),
          ),
          effect.none(),
          [],
        )
        _ -> #(model, effect.none(), [])
      }

    OpCancelled ->
      case model {
        Loaded(..) -> #(Loaded(..model, op: None), effect.none(), [])
        _ -> #(model, effect.none(), [])
      }

    OpFieldEdited(field:, value:) ->
      case model {
        Loaded(op: Some(op), ..) -> #(
          Loaded(
            ..model,
            op: Some(
              OpState(..op, form: ui.update_op_form(op.form, field, value)),
            ),
          ),
          effect.none(),
          [],
        )
        _ -> #(model, effect.none(), [])
      }

    OpSubmitted ->
      case model {
        Loaded(actor:, op: Some(op), ..) ->
          case ui.build_command(op.kind, op.form) {
            Ok(command) -> #(
              model,
              api.submit_operation(actor, command, OpResponded),
              [],
            )
            Error(prompt) -> #(
              Loaded(..model, op: Some(OpState(..op, error: Some(prompt)))),
              effect.none(),
              [],
            )
          }
        _ -> #(model, effect.none(), [])
      }

    OpResponded(result:) ->
      case model {
        Loaded(actor:, as_of:, op: Some(op), ..) ->
          case result {
            Ok(_) -> {
              let #(refetched, refetch_effect) =
                refetch(Loaded(..model, op: None), as_of, actor)
              #(refetched, refetch_effect, [OperationCommitted])
            }
            Error(error) -> #(
              Loaded(
                ..model,
                op: Some(OpState(..op, error: Some(api.describe_error(error)))),
              ),
              effect.none(),
              [],
            )
          }
        _ -> #(model, effect.none(), [])
      }
  }
}

// --- Fetch helpers ----------------------------------------------------------

/// Fetch the client list for `as_of`, tagging the result with the date it answers.
fn fetch_list(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/clients?as_of=" <> time.iso_date(as_of),
    codecs.client_list_decoder(),
    fn(result) { ListFetched(as_of:, result:) },
  )
}

/// Fetch one client's detail for `as_of`, tagging the result with both the date
/// and the client id it answers (so a stale or superseded detail is dropped).
fn fetch_detail(as_of: calendar.Date, client_id: Int) -> Effect(Msg) {
  api.get(
    "/api/clients/"
      <> int.to_string(client_id)
      <> "?as_of="
      <> time.iso_date(as_of),
    codecs.client_detail_decoder(),
    fn(result) { DetailFetched(as_of:, client_id:, result:) },
  )
}

// --- Model transitions ------------------------------------------------------

/// Whether a dated result is stale: it answers a different as-of than the model's
/// current one. A `Loading`/`Failed` model has no committed as-of, so nothing is
/// stale against it.
fn stale(model: Model, as_of: calendar.Date) -> Bool {
  case model {
    Loaded(as_of: current, ..) -> current != as_of
    _ -> False
  }
}

/// Fold a fresh list into the model, preserving any open detail and op form when
/// the page was already loaded, or starting clean from `Loading`/`Failed`.
fn loaded_with_list(
  model: Model,
  as_of: calendar.Date,
  client_list: ClientList,
) -> Model {
  case model {
    Loaded(actor:, detail:, op:, ..) ->
      Loaded(actor:, as_of:, list: client_list, detail:, op:)
    _ -> {
      let detail = case pending_detail(model) {
        Some(client_id) -> DetailLoading(client_id:)
        None -> NoDetail
      }
      Loaded(actor: model.actor, as_of:, list: client_list, detail:, op: None)
    }
  }
}

/// Record a list-fetch failure, keeping a loaded view on screen (stale data beats
/// a blank page) and only blanking to `Failed` when nothing has loaded yet.
fn fail(model: Model, error: rsvp.Error(String)) -> Model {
  case model {
    Loaded(..) -> model
    _ -> Failed(actor: model.actor, message: api.describe_error(error))
  }
}

/// The deep-linked client id a still-loading page is waiting to drill into, or
/// `None`. Only `Loading` carries a pending id; a `Loaded`/`Failed` model has
/// already resolved its detail (or has none).
fn pending_detail(model: Model) -> Option(Int) {
  case model {
    Loading(pending:, ..) -> pending
    _ -> None
  }
}

/// Whether a detail-fetch result is still wanted: it matches the client id the
/// detail sub-state is currently awaiting or showing.
fn awaiting_detail(detail: Detail, client_id: Int) -> Bool {
  detail_client_id(detail) == Some(client_id)
}

/// The client id an open detail is for (loading, loaded, or failed), or `None`
/// when no client is drilled in.
fn detail_client_id(detail: Detail) -> Option(Int) {
  case detail {
    NoDetail -> None
    DetailLoading(client_id:) -> Some(client_id)
    DetailLoaded(detail: types.ClientDetail(
      profile: types.ClientProfile(client_id:, ..),
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

/// Render the page for `as_of`: the client detail when one is drilled in,
/// otherwise the client roster. The optional op form is layered above either view.
pub fn view(model: Model, as_of: calendar.Date) -> Element(Msg) {
  let _ = as_of
  case model {
    Loading(..) -> ui.empty_state(message: "Loading clients…")
    Failed(message:, ..) ->
      ui.empty_state(message: "Could not load clients: " <> message)
    Loaded(list:, detail:, op:, ..) ->
      case detail {
        NoDetail -> view_list(list, op)
        _ -> view_detail(detail, op)
      }
  }
}

/// The client roster: a header with the Sign-contract action, the optional op
/// form, and a table of clients (name, since, project count, active status). Each
/// row drills into that client.
fn view_list(client_list: ClientList, op: Option(OpState)) -> Element(Msg) {
  let clients = client_list.clients
  html.div([], [
    ui.page_head(
      eyebrow: "Clients",
      title: "Clients",
      blurb: "Who we work for, and the contracts behind the projects.",
      actions: [op_trigger("+ Sign contract", ui.OpSignContract)],
    ),
    op_panel(op),
    ui.panel(
      title: "All clients",
      count: int.to_string(list.length(clients)),
      right: [],
      body: [
        case clients {
          [] -> ui.empty_state(message: "No clients on this date.")
          rows ->
            ui.data_table(
              headers: [
                #("Client", False),
                #("Since", False),
                #("Projects", True),
                #("Status", False),
              ],
              rows: list.map(rows, view_list_row),
            )
        },
      ],
    ),
  ])
}

/// One roster row: a square client avatar + name, the since date, project count,
/// and an active/ended pill. Clicking it opens the client detail.
fn view_list_row(client: ClientListRow) -> Element(Msg) {
  let types.ClientListRow(client_id:, name:, since:, project_count:, active:) =
    client
  html.tr(
    [attribute.class("clickable"), event.on_click(OpenClient(client_id:))],
    [
      html.td([attribute.class("cell-name")], [
        html.div(
          [
            attribute.class("avatar avatar--square"),
            attribute.style("background", cat_var(client_id + 3)),
          ],
          [html.text(initials(name))],
        ),
        html.span([attribute.class("cell-name__name")], [html.text(name)]),
      ]),
      html.td([attribute.class("mono muted")], [html.text(option_date(since))]),
      html.td([attribute.class("num")], [
        html.text(int.to_string(project_count)),
      ]),
      html.td([], [status_pill(active)]),
    ],
  )
}

/// The client-detail page: a back link, a header carrying the durable client name
/// and since date, the optional op form, then a two-column grid of the client's
/// projects (active/ended as-of) and a profile/contracts panel.
fn view_detail(detail: Detail, op: Option(OpState)) -> Element(Msg) {
  case detail {
    NoDetail -> ui.empty_state(message: "No client selected.")
    DetailLoading(..) ->
      html.div([], [back_link(), ui.empty_state(message: "Loading client…")])
    DetailFailed(message:, ..) ->
      html.div([], [
        back_link(),
        ui.empty_state(message: "Could not load client: " <> message),
      ])
    DetailLoaded(detail: loaded) -> view_detail_loaded(loaded, op)
  }
}

fn view_detail_loaded(
  detail: ClientDetail,
  op: Option(OpState),
) -> Element(Msg) {
  let types.ClientDetail(profile:, since:, contracts:, projects:) = detail
  let types.ClientProfile(name:, ..) = profile
  html.div([], [
    back_link(),
    ui.page_head(
      eyebrow: "Client",
      title: name,
      blurb: "Client since " <> option_date(since) <> ".",
      actions: [
        op_trigger("Sign contract", ui.OpSignContract),
        op_trigger("Edit profile", ui.OpUpdateClientProfile),
      ],
    ),
    op_panel(op),
    html.div([attribute.class("detail-grid")], [
      html.div([], [view_projects_panel(projects)]),
      html.div([], [view_profile_panel(name, since, contracts)]),
    ]),
  ])
}

/// The client's projects panel: each project row shows its swatch + title, budget,
/// target date, and an active/ended pill computed as-of. Clicking a row opens that
/// project's detail (a cross-page navigation).
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
  let types.ClientProjectRow(
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
      html.td([attribute.class("num")], [html.text(ui.money_k(budget))]),
      html.td([attribute.class("mono muted")], [
        html.text(time.iso_date(target_completion)),
      ]),
      html.td([], [status_pill(active)]),
    ],
  )
}

/// The profile panel: the client's durable name and since date, and a list of
/// contract terms with their windows and active/ended state as-of.
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
  let types.ContractRow(contract_id:, valid_from:, valid_to:, active:) =
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
fn op_trigger(label: String, kind: ui.OpKind) -> Element(Msg) {
  html.button([attribute.class("btn"), event.on_click(OpStarted(kind:))], [
    html.text(label),
  ])
}

/// The open op form (or nothing): a titled panel of the kind's fields, an optional
/// error line, and submit/cancel actions. Fields bind through the shared `ui`
/// engine so `build_command` assembles the typed `Command` on submit.
fn op_panel(op: Option(OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(OpState(kind:, form:, error:)) ->
      ui.panel(title: op_title(kind), count: "", right: [], body: [
        html.div([attribute.class("op-form")], op_fields(kind, form)),
        op_error(error),
        html.div([attribute.class("op-form__actions")], [
          html.button([attribute.class("btn"), event.on_click(OpSubmitted)], [
            html.text("Apply"),
          ]),
          html.button(
            [attribute.class("btn btn--ghost"), event.on_click(OpCancelled)],
            [html.text("Cancel")],
          ),
        ]),
      ])
  }
}

/// The fields each Clients write needs, bound to the shared `OpForm` slots.
fn op_fields(kind: ui.OpKind, form: ui.OpForm) -> List(Element(Msg)) {
  case kind {
    ui.OpSignContract -> [
      ui.op_field("Client", ui.FClient, form.client, "text", OpFieldEdited),
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
      ui.op_field(
        "Client id",
        ui.FClientId,
        form.client_id,
        "number",
        OpFieldEdited,
      ),
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

/// The op form's heading for a kind.
fn op_title(kind: ui.OpKind) -> String {
  case kind {
    ui.OpSignContract -> "Sign a contract"
    ui.OpUpdateClientProfile -> "Update client profile"
    _ -> "Operation"
  }
}

/// A validation/rejection line beneath the op form, or nothing when clean.
fn op_error(error: Option(String)) -> Element(Msg) {
  case error {
    None -> element.none()
    Some(message) ->
      html.div([attribute.class("op-form__error")], [html.text(message)])
  }
}

// --- Small view helpers -----------------------------------------------------

/// The "‹ All clients" back link returning to the roster: clearing the detail and
/// navigating to the list route (the navigation is raised when `CloseDetail` folds).
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

/// The `var(--cat-N)` token for a categorical index (wrapped 1..7), mirroring the
/// prototype's `catVar` for the client avatar tint.
fn cat_var(category: Int) -> String {
  let index = { int.modulo(category, 7) |> result.unwrap(0) } + 1
  "var(--cat-" <> int.to_string(index) <> ")"
}

/// Up to two upper-case initials of a name, mirroring the prototype's `initials`.
fn initials(name: String) -> String {
  string.split(name, " ")
  |> list.filter_map(fn(word) {
    string.first(word) |> result.map(string.uppercase)
  })
  |> list.take(2)
  |> string.concat
}
