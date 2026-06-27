//// The Projects page (FR-CP5..): the project list as of the global rail date and
//// a single project's detail with its team and invoices. Writes: StartProject,
//// AssignToProject, ChangeAllocationFraction, UpdateProjectProfile,
//// UpdateProjectPlan, DraftInvoice. Invoice drill-in navigates via
//// OutMsg Navigate(route.Finance(Invoices, Some(invoice_id))); a team card via
//// Navigate(route.People(Some(engineer_id))) — the id rides in the route, so no
//// shell edit is needed.
////
//// Each view fetches its read model AND the as-of `Roster` (the directory of
//// employed engineers, active projects, and clients as `Ref`s — id + name) so the
//// op forms select an engineer/project by NAME rather than a typed id. The op form
//// opens in a centred modal (`ui.modal`); entity slots are `ui.ref_select`s sourced
//// from the roster and snapped to valid options by `ui.reconcile_form`. The
//// project select is locked to the project in view; an op launched from a team card
//// pre-fills the engineer.
////
//// The model is a list-vs-detail sum, each arm Loading/Loaded/Failed for both its
//// read model and the roster. Every fetch result carries the as_of it answers;
//// `update` drops a result whose as_of no longer matches the model's current as_of
//// (stale-while-revalidate) so a fresh view or a half-typed op form is never
//// clobbered.
////
//// `init` takes the route: `Projects(Some(id))` opens that project's detail (so a
//// cold deep link to `/projects/:id` lands on it), any other route opens the list.
//// A row click raises `Navigate(route.Projects(Some(id)))` only — the shell pushes
//// the URL and re-inits the page, so the cold and click-through paths are one; the
//// back link raises `Navigate(route.Projects(None))`.

import client/api
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/route
import client/table_host
import client/time
import client/ui
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/time/calendar
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/invoice/view.{type Invoice} as _
import shared/money
import shared/project/view.{
  type ProjectDetail, type ProjectRequirement, type TeamMember,
} as project_view
import shared/roster/view.{type Ref, type Roster} as roster_view

// --- Model ------------------------------------------------------------------

/// The page renders one of two sub-views: the project list or a single project's
/// detail. Each is independently loadable, so the model is a sum over the two with
/// each arm carrying its own load state plus the as-of `Roster` the op selects
/// draw from. The signed-in `actor` is threaded in (the frozen `update` signature
/// omits it) so contextual writes can post on the presenter's behalf; the current
/// `as_of` is held so a committed write can refetch the same instant.
pub type Model {
  ListView(
    actor: String,
    as_of: calendar.Date,
    host: table_host.Host,
    roster: Load(Roster),
    op: Option(ui.OpState),
  )
  DetailView(
    actor: String,
    as_of: calendar.Date,
    project_id: Int,
    detail: Load(ProjectDetail),
    roster: Load(Roster),
    op: Option(ui.OpState),
  )
}

/// A loadable region: still fetching, loaded with the data and the as_of it
/// answers, or failed with a message. The as_of on `Loaded` is what the staleness
/// guard compares against the model's current as_of.
pub type Load(a) {
  Loading
  Loaded(value: a)
  Failed(message: String)
}

// --- Messages ---------------------------------------------------------------

/// The page's messages, wrapped by the shell as `ProjectsMsg(projects.Msg)`. Each
/// fetch result tags the `as_of` it answers for the staleness guard.
pub type Msg {
  TableHostMsg(sub: table_host.Msg)
  DetailFetched(
    project_id: Int,
    result: Result(ProjectDetail, rsvp.Error(String)),
    as_of: calendar.Date,
  )
  RosterFetched(
    result: Result(Roster, rsvp.Error(String)),
    as_of: calendar.Date,
  )
  BackToListClicked
  TeamCardClicked(engineer_id: Int)
  InvoiceRowClicked(invoice_id: Int)
  OpStarted(permit: ui.Permit)
  OpStartedFor(permit: ui.Permit, engineer_id: Int)
  OpFieldEdited(field: ui.OpField, value: String)
  OpCancelled
  OpSubmitted
  OpResponded(result: Result(Nil, rsvp.Error(String)))
}

// --- Init / refetch ---------------------------------------------------------

/// Build the page's initial state for `route` at `as_of` on the signed-in
/// `actor`'s behalf. `Projects(Some(id))` opens that project's detail (so a cold
/// deep link to `/projects/:id` lands on the detail); any other route opens the
/// project list. Both arms kick off their read-model fetch AND the roster fetch.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  case route {
    route.Projects(id: Some(project_id)) -> #(
      DetailView(
        actor:,
        as_of:,
        project_id:,
        detail: Loading,
        roster: Loading,
        op: None,
      ),
      effect.batch([fetch_detail(project_id, as_of), fetch_roster(as_of)]),
    )
    _ -> {
      let #(host, host_effect) = table_host.init("/api/projects/table", as_of)
      #(
        ListView(actor:, as_of:, host:, roster: Loading, op: None),
        effect.batch([
          effect.map(host_effect, TableHostMsg),
          fetch_roster(as_of),
        ]),
      )
    }
  }
}

/// Re-fetch the active view for a new `as_of` without dropping in-flight op-form
/// state (stale-while-revalidate). The open form, if any, is preserved. Advancing
/// `as_of` makes the staleness guard in `update` drop any in-flight responses for
/// the previous date.
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  case model {
    ListView(host:, op:, ..) -> {
      let #(host, host_effect) = table_host.refetch(host, as_of)
      #(
        ListView(actor:, as_of:, host:, roster: Loading, op:),
        effect.batch([
          effect.map(host_effect, TableHostMsg),
          fetch_roster(as_of),
        ]),
      )
    }
    DetailView(project_id:, op:, ..) -> #(
      DetailView(
        actor:,
        as_of:,
        project_id:,
        detail: Loading,
        roster: Loading,
        op:,
      ),
      effect.batch([fetch_detail(project_id, as_of), fetch_roster(as_of)]),
    )
  }
}

fn fetch_detail(project_id: Int, as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/projects/"
      <> int.to_string(project_id)
      <> "?as_of="
      <> iso_date(as_of),
    project_view.project_detail_decoder(),
    fn(result) { DetailFetched(project_id:, result:, as_of:) },
  )
}

fn fetch_roster(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/roster?as_of=" <> iso_date(as_of),
    roster_view.roster_decoder(),
    fn(result) { RosterFetched(result:, as_of:) },
  )
}

// --- Update -----------------------------------------------------------------

/// Fold a page message into the model, returning any cross-page `OutMsg`s for
/// the shell to act on.
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    TableHostMsg(sub:) ->
      case model {
        ListView(as_of:, host:, ..) -> {
          let #(host, host_effect, out) = table_host.update(host, sub, as_of)
          let model = ListView(..model, host:)
          let effect = effect.map(host_effect, TableHostMsg)
          case out {
            table_host.Stay -> #(model, effect, [])
            table_host.Activated(id:) ->
              case int.parse(id) {
                Ok(project_id) -> #(model, effect, [
                  Navigate(route.Projects(id: Some(project_id))),
                ])
                Error(Nil) -> #(model, effect, [])
              }
            table_host.ActionInvoked(..) -> #(model, effect, [])
          }
        }
        _ -> #(model, effect.none(), [])
      }

    DetailFetched(project_id:, result:, as_of:) ->
      case model {
        DetailView(project_id: current, as_of: current_as_of, ..)
          if current == project_id && current_as_of == as_of
        -> #(set_detail(model, load_result(result)), effect.none(), [])
        _ -> #(model, effect.none(), [])
      }

    RosterFetched(result:, as_of:) ->
      case as_of == view_as_of(model) {
        True -> #(set_roster(model, load_result(result)), effect.none(), [])
        False -> #(model, effect.none(), [])
      }

    BackToListClicked -> #(model, effect.none(), [
      Navigate(route.Projects(id: None)),
    ])

    TeamCardClicked(engineer_id:) -> #(model, effect.none(), [
      Navigate(route.People(id: Some(engineer_id))),
    ])

    InvoiceRowClicked(invoice_id:) -> #(model, effect.none(), [
      Navigate(route.Finance(tab: route.Invoices, invoice: Some(invoice_id))),
    ])

    OpStarted(permit:) -> #(
      set_op(model, Some(open_op(model, ui.permit_kind(permit), None))),
      effect.none(),
      [],
    )

    OpStartedFor(permit:, engineer_id:) -> #(
      set_op(
        model,
        Some(open_op(model, ui.permit_kind(permit), Some(engineer_id))),
      ),
      effect.none(),
      [],
    )

    OpFieldEdited(field:, value:) ->
      case current_op(model) {
        Some(ui.OpState(kind:, form:, ..)) -> {
          let form = ui.update_op_form(form, field, value)
          #(
            set_op(model, Some(ui.OpState(kind:, form:, error: None))),
            effect.none(),
            [],
          )
        }
        None -> #(model, effect.none(), [])
      }

    OpCancelled -> #(set_op(model, None), effect.none(), [])

    OpSubmitted ->
      case current_op(model) {
        Some(ui.OpState(kind:, form:, ..)) ->
          case ui.build_command(kind, form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OpResponded),
              [],
            )
            Error(prompt) -> #(
              set_op(model, Some(ui.OpState(kind:, form:, error: Some(prompt)))),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    OpResponded(result:) ->
      case result {
        Ok(_) -> {
          let cleared = set_op(model, None)
          let #(reloaded, effect) = reload(cleared)
          #(reloaded, effect, [OperationCommitted])
        }
        Error(error) ->
          case current_op(model) {
            Some(ui.OpState(kind:, form:, ..)) -> #(
              set_op(
                model,
                Some(ui.OpState(
                  kind:,
                  form:,
                  error: Some(api.describe_error(error)),
                )),
              ),
              effect.none(),
              [],
            )
            None -> #(model, effect.none(), [])
          }
      }
  }
}

fn load_result(result: Result(a, rsvp.Error(String))) -> Load(a) {
  case result {
    Ok(value) -> Loaded(value:)
    Error(error) -> Failed(api.describe_error(error))
  }
}

/// Re-fetch the active view (read model and roster) at the as_of the current view
/// answers, so a committed write is reflected immediately.
fn reload(model: Model) -> #(Model, Effect(Msg)) {
  case model {
    ListView(actor:, as_of:, host:, op:, ..) -> {
      let #(host, host_effect) = table_host.refetch(host, as_of)
      #(
        ListView(actor:, as_of:, host:, roster: Loading, op:),
        effect.batch([
          effect.map(host_effect, TableHostMsg),
          fetch_roster(as_of),
        ]),
      )
    }
    DetailView(actor:, as_of:, project_id:, op:, ..) -> #(
      DetailView(
        actor:,
        as_of:,
        project_id:,
        detail: Loading,
        roster: Loading,
        op:,
      ),
      effect.batch([fetch_detail(project_id, as_of), fetch_roster(as_of)]),
    )
  }
}

fn view_as_of(model: Model) -> calendar.Date {
  case model {
    ListView(as_of:, ..) -> as_of
    DetailView(as_of:, ..) -> as_of
  }
}

fn current_op(model: Model) -> Option(ui.OpState) {
  case model {
    ListView(op:, ..) -> op
    DetailView(op:, ..) -> op
  }
}

fn set_op(model: Model, op: Option(ui.OpState)) -> Model {
  case model {
    ListView(..) -> ListView(..model, op:)
    DetailView(..) -> DetailView(..model, op:)
  }
}

fn set_detail(model: Model, detail: Load(ProjectDetail)) -> Model {
  case model {
    DetailView(..) -> DetailView(..model, detail:)
    _ -> model
  }
}

fn set_roster(model: Model, roster: Load(Roster)) -> Model {
  case model {
    ListView(..) -> ListView(..model, roster:)
    DetailView(..) -> DetailView(..model, roster:)
  }
}

// --- Op-form launch ----------------------------------------------------------

/// A fresh op form for `kind`. The project select is pre-filled and locked from
/// the detail view (so an op started on a project's page targets it); profile and
/// plan edits are pre-filled from the loaded detail (title/summary, budget/target
/// completion) rather than starting blank; an op launched from a team card
/// pre-fills the engineer. Entity slots are then snapped to valid roster options.
fn open_op(
  model: Model,
  kind: ui.OpKind,
  engineer_id: Option(Int),
) -> ui.OpState {
  let form = ui.blank_op_form(kind, view_as_of(model))
  let form = seed_project(model, form)
  let form = seed_detail_fields(model, kind, form)
  let form = case engineer_id {
    Some(id) -> ui.update_op_form(form, ui.FEngineerId, int.to_string(id))
    None -> form
  }
  let form = reconcile(model, form)
  ui.OpState(kind:, form:, error: None)
}

/// Seed the form's project slot from the detail view, so an op composed on a
/// project's page pre-targets that project.
fn seed_project(model: Model, form: ui.OpForm) -> ui.OpForm {
  case model {
    DetailView(project_id:, ..) ->
      ui.update_op_form(form, ui.FProjectId, int.to_string(project_id))
    ListView(..) -> form
  }
}

/// Pre-fill the profile (title/summary) and plan (budget/target completion) slots
/// from the loaded detail, so an edit form opens showing the project's current
/// values rather than blank.
fn seed_detail_fields(
  model: Model,
  kind: ui.OpKind,
  form: ui.OpForm,
) -> ui.OpForm {
  case model {
    DetailView(detail: Loaded(detail), ..) ->
      case kind {
        ui.OpUpdateProjectProfile ->
          form
          |> ui.update_op_form(ui.FTitle, detail.profile.title)
          |> ui.update_op_form(ui.FSummary, detail.profile.summary)
        ui.OpUpdateProjectPlan ->
          form
          |> ui.update_op_form(
            ui.FBudget,
            float_text(money.to_float(detail.plan.budget)),
          )
          |> ui.update_op_form(
            ui.FTargetCompletion,
            iso_date(detail.plan.target_completion),
          )
        ui.OpSetProjectRequirement ->
          form
          |> ui.update_op_form(ui.FLevel, "3")
          |> ui.update_op_form(ui.FFraction, "1")
        _ -> form
      }
    _ -> form
  }
}

/// Snap the form's engineer and project slots to valid options from the as-of
/// roster, so a freshly opened form names an engineer and project the directory
/// actually carries.
fn reconcile(model: Model, form: ui.OpForm) -> ui.OpForm {
  ui.reconcile_form(form, engineer_refs(model), project_refs(model))
}

// --- View -------------------------------------------------------------------

/// Render the page for `as_of`.
pub fn view(
  model: Model,
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  case model {
    ListView(host:, roster:, op:, ..) ->
      view_list(host, roster, op, as_of, permissions)
    DetailView(detail:, roster:, op:, ..) ->
      view_detail(detail, roster, op, as_of, permissions)
  }
}

/// Render the list mode: the page head with the Start-project action, the project
/// list via the generic data table (embedded through its host, which owns the
/// loading / failed guards), and the op modal.
fn view_list(
  host: table_host.Host,
  roster: Load(Roster),
  op: Option(ui.OpState),
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  let head =
    ui.page_head(
      title: "Projects",
      blurb: "Active engagements as of "
        <> time.format_date(as_of)
        <> ", with budget and target completion.",
      actions: [
        ui.launch(
          ui.permit(permissions, own: False, kind: ui.OpStartProject),
          to_msg: OpStarted,
          label: "+ Start project",
          kind: ui.Primary,
          size: ui.Medium,
        ),
      ],
    )
  let body =
    ui.panel(title: "All projects", count: "", right: [], body: [
      element.map(table_host.view(host, "Loading projects…"), TableHostMsg),
    ])
  html.div([], [head, body, op_modal(op, roster, None)])
}

fn view_detail(
  detail: Load(ProjectDetail),
  roster: Load(Roster),
  op: Option(ui.OpState),
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  let back =
    html.a([attribute.class("back-link"), event.on_click(BackToListClicked)], [
      html.text("‹ All projects"),
    ])
  let body = case detail {
    Loading -> ui.empty_state(message: "Loading project…")
    Failed(message:) ->
      ui.empty_state(message: "Could not load project: " <> message)
    Loaded(value:) -> view_project_detail(value, roster, op, as_of, permissions)
  }
  html.div([], [back, body])
}

fn view_project_detail(
  detail: ProjectDetail,
  roster: Load(Roster),
  op: Option(ui.OpState),
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  let head =
    html.div([attribute.class("page-head")], [
      html.div([], [
        html.h1([], [html.text(detail.profile.title)]),
        html.div([attribute.class("detail__subtitle")], [
          ui.swatch(category: detail.profile.project_id, inline: False),
          html.text(detail.client),
        ]),
        html.p([], [html.text(detail.profile.summary)]),
      ]),
      html.div([attribute.class("action-row")], [
        ui.launch(
          ui.permit(permissions, own: False, kind: ui.OpAssignToProject),
          to_msg: OpStarted,
          label: "Assign",
          kind: ui.Ghost,
          size: ui.Small,
        ),
        ui.launch(
          ui.permit(
            permissions,
            own: False,
            kind: ui.OpChangeAllocationFraction,
          ),
          to_msg: OpStarted,
          label: "Adjust allocation",
          kind: ui.Ghost,
          size: ui.Small,
        ),
        ui.launch(
          ui.permit(permissions, own: False, kind: ui.OpUpdateProjectProfile),
          to_msg: OpStarted,
          label: "Edit profile",
          kind: ui.Ghost,
          size: ui.Small,
        ),
        ui.launch(
          ui.permit(permissions, own: False, kind: ui.OpUpdateProjectPlan),
          to_msg: OpStarted,
          label: "Edit plan",
          kind: ui.Ghost,
          size: ui.Small,
        ),
        ui.launch(
          ui.permit(permissions, own: False, kind: ui.OpSetProjectRequirement),
          to_msg: OpStarted,
          label: "Set requirement",
          kind: ui.Ghost,
          size: ui.Small,
        ),
        ui.launch(
          ui.permit(permissions, own: False, kind: ui.OpDraftInvoice),
          to_msg: OpStarted,
          label: "Draft invoice",
          kind: ui.Primary,
          size: ui.Small,
        ),
      ]),
    ])
  let stats =
    html.div([attribute.class("stats")], [
      ui.stat(
        value: ui.money_k(money.to_float(detail.plan.budget)),
        unit: "",
        label: "Budget",
        pct: ui.NoPct,
      ),
      ui.stat(
        value: int.to_string(list.length(detail.team)),
        unit: "people",
        label: "On team now",
        pct: ui.NoPct,
      ),
      ui.stat(
        value: ui.money_k(money.to_float(run_rate_of(detail.team))),
        unit: "/day",
        label: "Run-rate",
        pct: ui.NoPct,
      ),
      ui.stat(
        value: short_date(detail.plan.target_completion),
        unit: "",
        label: "Target",
        pct: ui.NoPct,
      ),
    ])
  let grid =
    html.div([attribute.class("detail-grid")], [
      html.div([], [
        team_panel(detail.team, as_of, permissions),
        requirements_panel(detail.requirements),
        invoices_panel(detail.invoices),
      ]),
      html.div([], [plan_panel(detail)]),
    ])
  html.div([], [
    head,
    stats,
    grid,
    op_modal(op, roster, Some(detail.profile.project_id)),
  ])
}

fn team_panel(
  team: List(TeamMember),
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  let cards = case team {
    [] -> [ui.empty_state(message: "No one allocated on this date.")]
    members ->
      list.index_map(members, fn(member, index) {
        team_card(member, index, permissions)
      })
  }
  ui.panel(
    title: "Team on " <> time.format_date(as_of),
    count: int.to_string(list.length(team)),
    right: [],
    body: [
      html.div([attribute.class("board-group")], [
        html.div([attribute.class("board-grid")], cards),
      ]),
    ],
  )
}

/// One project-team member card: clicking the card drills into the engineer's
/// detail; the right-aligned "Adjust" action opens the ChangeAllocationFraction
/// modal pre-filled with this engineer (and the locked project), without firing
/// the card's drill-in via `stop_propagation`.
fn team_card(
  member: TeamMember,
  index: Int,
  permissions: Set(String),
) -> Element(Msg) {
  html.div(
    [
      attribute.class("board-card"),
      event.on_click(TeamCardClicked(engineer_id: member.engineer_id)),
    ],
    [
      ui.avatar(name: member.name, category: index, class: "avatar"),
      html.div([attribute.class("board-card__info")], [
        html.div([attribute.class("board-card__name")], [html.text(member.name)]),
        html.div([attribute.class("board-card__sub")], [
          html.span([attribute.class("board-card__fraction")], [
            html.text(ui.fraction(member.fraction)),
          ]),
          html.span([attribute.class("level-pill")], [
            html.text(ui.level_band(member.level)),
          ]),
          html.span([], [
            html.text(ui.money(money.to_float(member.day_rate)) <> "/d"),
          ]),
        ]),
      ]),
      html.div([attribute.class("board-card__action")], [
        ui.when_permitted(
          ui.permit(
            permissions,
            own: False,
            kind: ui.OpChangeAllocationFraction,
          ),
          fn(granted) {
            html.button(
              [
                attribute.class("btn btn--ghost btn--sm"),
                event.stop_propagation(
                  event.on_click(OpStartedFor(
                    permit: granted,
                    engineer_id: member.engineer_id,
                  )),
                ),
              ],
              [html.text("Adjust")],
            )
          },
        ),
      ]),
    ],
  )
}

/// The capacity-requirements panel (demand): each line as a level chip, its
/// fractional-FTE quantity (`×N`), and the period it covers. An empty-state when
/// the project carries no requirements.
fn requirements_panel(requirements: List(ProjectRequirement)) -> Element(Msg) {
  let body = case requirements {
    [] -> [ui.empty_state(message: "No capacity requirements.")]
    requirements -> list.map(requirements, requirement_row)
  }
  ui.panel(
    title: "Capacity requirements",
    count: int.to_string(list.length(requirements)),
    right: [],
    body: [html.div([attribute.class("kv")], body)],
  )
}

fn requirement_row(requirement: ProjectRequirement) -> Element(Msg) {
  html.div([attribute.class("kv__row")], [
    html.span([attribute.class("kv__key")], [
      ui.chip(label: ui.level_band(requirement.level), tone: ui.Neutral),
      html.span([attribute.class("board-card__fraction")], [
        html.text("×" <> ui.days(requirement.quantity)),
      ]),
    ]),
    html.span([attribute.class("kv__value mono")], [
      html.text(
        time.format_date(requirement.valid_from)
        <> " → "
        <> time.format_date(requirement.valid_to),
      ),
    ]),
  ])
}

fn invoices_panel(invoices: List(Invoice)) -> Element(Msg) {
  let body = case invoices {
    [] -> ui.empty_state(message: "No invoices.")
    invoices ->
      ui.data_table(
        headers: [
          #("Invoice", False),
          #("Month", False),
          #("Total", True),
          #("Status as of date", False),
        ],
        rows: list.map(invoices, invoice_row),
      )
  }
  ui.panel(
    title: "Invoices",
    count: int.to_string(list.length(invoices)),
    right: [],
    body: [body],
  )
}

fn invoice_row(invoice: Invoice) -> Element(Msg) {
  html.tr(
    [
      attribute.class("clickable"),
      event.on_click(InvoiceRowClicked(invoice_id: invoice.id)),
    ],
    [
      html.td([attribute.class("mono")], [
        html.text("#" <> int.to_string(invoice.id)),
      ]),
      html.td([], [html.text(time.format_month(invoice.billing_from))]),
      html.td([attribute.class("num")], [
        html.text(ui.money(money.to_float(invoice.total))),
      ]),
      html.td([], [ui.pill(variant: invoice.status, label: invoice.status)]),
    ],
  )
}

fn plan_panel(detail: ProjectDetail) -> Element(Msg) {
  ui.panel(title: "Plan", count: "", right: [], body: [
    html.div([attribute.class("pad-detail")], [
      html.div([attribute.class("kv")], [
        ui.kv(
          key: "Budget",
          value: ui.money(money.to_float(detail.plan.budget)),
          mono: True,
        ),
        ui.kv(
          key: "Target completion",
          value: time.format_date(detail.plan.target_completion),
          mono: True,
        ),
      ]),
      html.div([attribute.class("note")], [
        html.text(
          time.format_date(detail.valid_from)
          <> " → "
          <> time.format_date(detail.valid_to),
        ),
      ]),
    ]),
  ])
}

// --- Op-form modal -----------------------------------------------------------

/// The contextual operation, shown as a centred modal over a dimmed backdrop when
/// an op is open. Renders the kind-specific fields (engineer/project as `<select>`s
/// from the as-of directory, the project locked to the project in view on the
/// detail page), the last rejection message, and a Cancel / verb-labelled Confirm
/// footer. `locked_project_id`, when present, pins the project select to that id.
fn op_modal(
  op: Option(ui.OpState),
  roster: Load(Roster),
  locked_project_id: Option(Int),
) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(ui.OpState(kind:, form:, error:)) ->
      ui.modal(
        title: op_title(kind),
        error: error_text(error),
        body: op_fields(kind, form, roster, locked_project_id),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: op_verb(kind),
      )
  }
}

fn error_text(error: Option(String)) -> String {
  case error {
    None -> ""
    Some(message) -> message
  }
}

/// The form fields for the open op. Entity ids are `<select>`s over the as-of
/// roster; the project is locked when a `locked_project_id` is in view; the
/// engineer (AssignToProject / ChangeAllocationFraction) is a free select.
/// StartProject keeps a typed numeric Contract id — the roster carries no contract
/// directory to select over.
fn op_fields(
  kind: ui.OpKind,
  form: ui.OpForm,
  roster: Load(Roster),
  locked_project_id: Option(Int),
) -> List(Element(Msg)) {
  let engineers = roster_engineers(roster)
  let projects = roster_projects(roster)
  let project_select = project_field(form, projects, locked_project_id)
  let engineer_select =
    ui.ref_select(
      label: "Engineer",
      field: ui.FEngineerId,
      refs: engineers,
      selected: form.engineer_id,
      to_msg: edit,
    )
  case kind {
    ui.OpStartProject -> [
      text_field("Title", ui.FName, form.name),
      number_field("Contract id", ui.FContractId, form.contract_id),
      date_field("Valid from", ui.FValidFrom, form.valid_from),
      date_field("Valid to", ui.FValidTo, form.valid_to),
    ]
    ui.OpAssignToProject -> [
      engineer_select,
      project_select,
      number_field("Fraction", ui.FFraction, form.fraction),
      date_field("Valid from", ui.FValidFrom, form.valid_from),
      date_field("Valid to", ui.FValidTo, form.valid_to),
    ]
    ui.OpChangeAllocationFraction -> [
      engineer_select,
      project_select,
      number_field("Fraction", ui.FFraction, form.fraction),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpUpdateProjectProfile -> [
      project_select,
      text_field("Title", ui.FTitle, form.title),
      text_field("Summary", ui.FSummary, form.summary),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpUpdateProjectPlan -> [
      project_select,
      number_field("Budget", ui.FBudget, form.budget),
      date_field(
        "Target completion",
        ui.FTargetCompletion,
        form.target_completion,
      ),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpDraftInvoice -> [
      project_select,
      date_field("Billing from", ui.FValidFrom, form.valid_from),
      date_field("Billing to", ui.FValidTo, form.valid_to),
    ]
    ui.OpSetProjectRequirement -> [
      project_select,
      level_select(form.level),
      number_field("Quantity", ui.FFraction, form.fraction),
      date_field("Valid from", ui.FValidFrom, form.valid_from),
      date_field("Valid to", ui.FValidTo, form.valid_to),
    ]
    _ -> []
  }
}

/// A labelled `<select>` over levels 1–7, bound to the `FLevel` slot. The option
/// value is the level number as text, the label its band name; the form's current
/// level is pre-selected. Built locally so `ui.gleam` stays frozen.
fn level_select(selected: String) -> Element(Msg) {
  let options =
    [1, 2, 3, 4, 5, 6, 7]
    |> list.map(fn(level) {
      let value = int.to_string(level)
      html.option(
        [attribute.value(value), attribute.selected(value == selected)],
        ui.level_band(level),
      )
    })
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Level")]),
    html.select(
      [
        attribute.attribute("aria-label", "Level"),
        event.on_change(fn(value) { OpFieldEdited(ui.FLevel, value) }),
      ],
      options,
    ),
  ])
}

/// The project select: a free `<select>` over the roster on the list page, or a
/// locked single-option select pinned to the project in view on the detail page.
fn project_field(
  form: ui.OpForm,
  projects: List(Ref),
  locked_project_id: Option(Int),
) -> Element(Msg) {
  case locked_project_id {
    Some(project_id) -> locked_project_select(project_id, projects)
    None ->
      ui.ref_select(
        label: "Project",
        field: ui.FProjectId,
        refs: projects,
        selected: form.project_id,
        to_msg: edit,
      )
  }
}

/// A disabled project select pinned to the project in view: a single option named
/// from the roster (or the bare id while the roster loads). It is inert so the
/// presenter cannot retarget an op composed from a project's page, while the form
/// still carries the pre-filled `FProjectId` for `build_command`.
fn locked_project_select(project_id: Int, projects: List(Ref)) -> Element(Msg) {
  let id = int.to_string(project_id)
  let name =
    projects
    |> list.find(fn(reference) { reference.id == project_id })
    |> option.from_result
    |> option.map(fn(reference) { reference.name })
    |> option.unwrap("Project #" <> id)
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Project")]),
    html.select(
      [attribute.attribute("aria-label", "Project"), attribute.disabled(True)],
      [html.option([attribute.value(id), attribute.selected(True)], name)],
    ),
  ])
}

// --- Op-form directories -----------------------------------------------------

/// The engineer directory for op selects on the open model, from the as-of roster.
/// Empty until the roster loads.
fn engineer_refs(model: Model) -> List(Ref) {
  roster_engineers(roster_of(model))
}

/// The project directory for op selects on the open model, from the as-of roster.
/// Empty until the roster loads.
fn project_refs(model: Model) -> List(Ref) {
  roster_projects(roster_of(model))
}

fn roster_of(model: Model) -> Load(Roster) {
  case model {
    ListView(roster:, ..) -> roster
    DetailView(roster:, ..) -> roster
  }
}

fn roster_engineers(roster: Load(Roster)) -> List(Ref) {
  case roster {
    Loaded(value:) -> value.engineers
    _ -> []
  }
}

fn roster_projects(roster: Load(Roster)) -> List(Ref) {
  case roster {
    Loaded(value:) -> value.projects
    _ -> []
  }
}

// --- Op-form field helpers ---------------------------------------------------

fn text_field(label: String, field: ui.OpField, value: String) -> Element(Msg) {
  ui.op_field(label:, field:, value:, input_type: "text", to_msg: edit)
}

fn number_field(
  label: String,
  field: ui.OpField,
  value: String,
) -> Element(Msg) {
  ui.op_field(label:, field:, value:, input_type: "number", to_msg: edit)
}

fn date_field(label: String, field: ui.OpField, value: String) -> Element(Msg) {
  ui.op_field(label:, field:, value:, input_type: "date", to_msg: edit)
}

fn edit(field: ui.OpField, value: String) -> Msg {
  OpFieldEdited(field:, value:)
}

fn op_title(kind: ui.OpKind) -> String {
  case kind {
    ui.OpStartProject -> "Start a project"
    ui.OpAssignToProject -> "Assign to project"
    ui.OpChangeAllocationFraction -> "Change allocation fraction"
    ui.OpUpdateProjectProfile -> "Edit project profile"
    ui.OpUpdateProjectPlan -> "Edit project plan"
    ui.OpDraftInvoice -> "Draft an invoice"
    ui.OpSetProjectRequirement -> "Set capacity requirement"
    _ -> "Operation"
  }
}

fn op_verb(kind: ui.OpKind) -> String {
  case kind {
    ui.OpStartProject -> "Start project"
    ui.OpAssignToProject -> "Assign"
    ui.OpChangeAllocationFraction -> "Adjust allocation"
    ui.OpUpdateProjectProfile -> "Save profile"
    ui.OpUpdateProjectPlan -> "Save plan"
    ui.OpDraftInvoice -> "Draft invoice"
    ui.OpSetProjectRequirement -> "Set requirement"
    _ -> "Confirm"
  }
}

// --- Small view helpers -----------------------------------------------------

fn run_rate_of(team: List(TeamMember)) -> money.Money {
  money.sum(
    list.map(team, fn(member) {
      money.scale_by(member.day_rate, member.fraction)
    }),
  )
}

// --- Date / number formatting -----------------------------------------------

/// Render a budget float for a pre-filled text input: a whole number when
/// integral ("84000"), otherwise its decimal form, so the Edit-plan form opens on
/// the project's current budget rather than blank.
fn float_text(value: Float) -> String {
  case value == int.to_float(float.truncate(value)) {
    True -> int.to_string(float.truncate(value))
    False -> float.to_string(value)
  }
}

fn iso_date(date: calendar.Date) -> String {
  let calendar.Date(year:, month:, day:) = date
  pad4(year) <> "-" <> pad2(calendar.month_to_int(month)) <> "-" <> pad2(day)
}

fn short_date(date: calendar.Date) -> String {
  int.to_string(date.day) <> " " <> time.month_abbrev(date.month)
}

fn pad2(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}

fn pad4(value: Int) -> String {
  case value < 10 {
    True -> "000" <> int.to_string(value)
    False ->
      case value < 100 {
        True -> "00" <> int.to_string(value)
        False ->
          case value < 1000 {
            True -> "0" <> int.to_string(value)
            False -> int.to_string(value)
          }
      }
  }
}
