//// The Projects page (FR-CP5..): the project list as of the global rail date and
//// a single project's detail with its team and invoices. Writes: StartProject,
//// AssignToProject, ChangeAllocationFraction, UpdateProjectProfile,
//// UpdateProjectPlan, DraftInvoice. Invoice drill-in navigates via
//// OutMsg Navigate(route.Finance(Invoices, Some(invoice_id))); a team card via
//// Navigate(route.People(Some(engineer_id))) — the id rides in the route, so no
//// shell edit is needed.
////
//// The model is a list-vs-detail sum, each arm Loading/Loaded/Failed. Every fetch
//// result carries the as_of it answers; `update` drops a result whose as_of no
//// longer matches the model's current as_of (stale-while-revalidate) so a fresh
//// view or a half-typed op form is never clobbered.
////
//// `init` takes the route: `Projects(Some(id))` opens that project's detail (so a
//// cold deep link to `/projects/:id` lands on it), any other route opens the list.
//// A row click raises `Navigate(route.Projects(Some(id)))` only — the shell pushes
//// the URL and re-inits the page, so the cold and click-through paths are one; the
//// back link raises `Navigate(route.Projects(None))`.

import client/api
import client/route
import client/ui
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/codecs
import shared/types.{
  type Event, type Invoice, type ProjectDetail, type ProjectList,
  type ProjectListRow, type TeamMember,
}

// --- Model ------------------------------------------------------------------

/// The page renders one of two sub-views: the project list or a single project's
/// detail. Each is independently loadable, so the model is a sum over the two with
/// each arm carrying its own load state. The signed-in `actor` is threaded in
/// (the frozen `update` signature omits it) so contextual writes can post on the
/// presenter's behalf; the current `as_of` is held so a committed write can
/// refetch the same instant.
pub type Model {
  ListView(
    actor: String,
    as_of: calendar.Date,
    list: Load(ProjectList),
    op: Option(OpState),
  )
  DetailView(
    actor: String,
    as_of: calendar.Date,
    project_id: Int,
    detail: Load(ProjectDetail),
    op: Option(OpState),
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

/// An open contextual-operation form: which command it builds, the shared form
/// state, and the last submission error (a validation prompt or a rejected-op
/// server message), if any.
pub type OpState {
  OpState(kind: ui.OpKind, form: ui.OpForm, error: Option(String))
}

// --- Messages ---------------------------------------------------------------

/// The page's messages, wrapped by the shell as `ProjectsMsg(projects.Msg)`.
pub type Msg {
  ListFetched(
    result: Result(ProjectList, rsvp.Error(String)),
    as_of: calendar.Date,
  )
  DetailFetched(
    project_id: Int,
    result: Result(ProjectDetail, rsvp.Error(String)),
    as_of: calendar.Date,
  )
  ProjectRowClicked(project_id: Int)
  BackToListClicked
  TeamCardClicked(engineer_id: Int)
  InvoiceRowClicked(invoice_id: Int)
  OpStarted(kind: ui.OpKind)
  OpFieldEdited(field: ui.OpField, value: String)
  OpCancelled
  OpSubmitted
  OpResponded(result: Result(List(Event), rsvp.Error(String)))
}

/// The cross-page effects a page can raise (the ONLY shell coupling, frozen in
/// step 5): navigate to a route, or signal a write committed. Identical across
/// all 7 pages.
pub type OutMsg {
  Navigate(route.Route)
  OperationCommitted
}

// --- Init / refetch ---------------------------------------------------------

/// Build the page's initial state for `route` at `as_of` on the signed-in
/// `actor`'s behalf. `Projects(Some(id))` opens that project's detail (so a cold
/// deep link to `/projects/:id` lands on the detail); any other route opens the
/// project list.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  case route {
    route.Projects(id: Some(project_id)) -> #(
      DetailView(actor:, as_of:, project_id:, detail: Loading, op: None),
      fetch_detail(project_id, as_of),
    )
    _ -> #(ListView(actor:, as_of:, list: Loading, op: None), fetch_list(as_of))
  }
}

/// Re-fetch the active view for a new `as_of` without dropping in-flight op-form
/// state (stale-while-revalidate). The open form, if any, is preserved.
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  case model {
    ListView(op:, ..) -> #(
      ListView(actor:, as_of:, list: Loading, op:),
      fetch_list(as_of),
    )
    DetailView(project_id:, op:, ..) -> #(
      DetailView(actor:, as_of:, project_id:, detail: Loading, op:),
      fetch_detail(project_id, as_of),
    )
  }
}

fn fetch_list(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/projects?as_of=" <> iso_date(as_of),
    codecs.project_list_decoder(),
    fn(result) { ListFetched(result:, as_of:) },
  )
}

fn fetch_detail(project_id: Int, as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/projects/"
      <> int.to_string(project_id)
      <> "?as_of="
      <> iso_date(as_of),
    codecs.project_detail_decoder(),
    fn(result) { DetailFetched(project_id:, result:, as_of:) },
  )
}

// --- Update -----------------------------------------------------------------

/// Fold a page message into the model, returning any cross-page `OutMsg`s for
/// the shell to act on.
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    ListFetched(result:, as_of:) ->
      case model {
        ListView(as_of: current, ..) if current == as_of -> #(
          set_list(model, load_result(result)),
          effect.none(),
          [],
        )
        _ -> #(model, effect.none(), [])
      }

    DetailFetched(project_id:, result:, as_of:) ->
      case model {
        DetailView(project_id: current, as_of: current_as_of, ..)
          if current == project_id && current_as_of == as_of
        -> #(set_detail(model, load_result(result)), effect.none(), [])
        _ -> #(model, effect.none(), [])
      }

    ProjectRowClicked(project_id:) -> #(model, effect.none(), [
      Navigate(route.Projects(id: Some(project_id))),
    ])

    BackToListClicked -> #(model, effect.none(), [
      Navigate(route.Projects(id: None)),
    ])

    TeamCardClicked(engineer_id:) -> #(model, effect.none(), [
      Navigate(route.People(id: Some(engineer_id))),
    ])

    InvoiceRowClicked(invoice_id:) -> #(model, effect.none(), [
      Navigate(route.Finance(tab: route.Invoices, invoice: Some(invoice_id))),
    ])

    OpStarted(kind:) -> #(
      set_op(model, Some(open_op(model, kind))),
      effect.none(),
      [],
    )

    OpFieldEdited(field:, value:) ->
      case current_op(model) {
        Some(OpState(kind:, form:, ..)) -> {
          let form = ui.update_op_form(form, field, value)
          #(
            set_op(model, Some(OpState(kind:, form:, error: None))),
            effect.none(),
            [],
          )
        }
        None -> #(model, effect.none(), [])
      }

    OpCancelled -> #(set_op(model, None), effect.none(), [])

    OpSubmitted ->
      case current_op(model) {
        Some(OpState(kind:, form:, ..)) ->
          case ui.build_command(kind, form) {
            Ok(command) -> #(
              model,
              api.submit_operation(actor_of(model), command, OpResponded),
              [],
            )
            Error(prompt) -> #(
              set_op(model, Some(OpState(kind:, form:, error: Some(prompt)))),
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
            Some(OpState(kind:, form:, ..)) -> #(
              set_op(
                model,
                Some(OpState(
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

/// Re-fetch the active view at the as_of the current view answers, so a committed
/// write is reflected immediately.
fn reload(model: Model) -> #(Model, Effect(Msg)) {
  case model {
    ListView(actor:, as_of:, op:, ..) -> #(
      ListView(actor:, as_of:, list: Loading, op:),
      fetch_list(as_of),
    )
    DetailView(actor:, as_of:, project_id:, op:, ..) -> #(
      DetailView(actor:, as_of:, project_id:, detail: Loading, op:),
      fetch_detail(project_id, as_of),
    )
  }
}

fn actor_of(model: Model) -> String {
  case model {
    ListView(actor:, ..) -> actor
    DetailView(actor:, ..) -> actor
  }
}

fn view_as_of(model: Model) -> calendar.Date {
  case model {
    ListView(as_of:, ..) -> as_of
    DetailView(as_of:, ..) -> as_of
  }
}

fn current_op(model: Model) -> Option(OpState) {
  case model {
    ListView(op:, ..) -> op
    DetailView(op:, ..) -> op
  }
}

fn set_op(model: Model, op: Option(OpState)) -> Model {
  case model {
    ListView(actor:, as_of:, list:, ..) -> ListView(actor:, as_of:, list:, op:)
    DetailView(actor:, as_of:, project_id:, detail:, ..) ->
      DetailView(actor:, as_of:, project_id:, detail:, op:)
  }
}

fn set_list(model: Model, list: Load(ProjectList)) -> Model {
  case model {
    ListView(actor:, as_of:, op:, ..) -> ListView(actor:, as_of:, list:, op:)
    _ -> model
  }
}

fn set_detail(model: Model, detail: Load(ProjectDetail)) -> Model {
  case model {
    DetailView(actor:, as_of:, project_id:, op:, ..) ->
      DetailView(actor:, as_of:, project_id:, detail:, op:)
    _ -> model
  }
}

/// A fresh op form for `kind`, seeding the project id from the detail view (so an
/// op started on a project's page pre-targets it) and dates from the view's as_of.
fn open_op(model: Model, kind: ui.OpKind) -> OpState {
  let form = ui.blank_op_form(kind, view_as_of(model))
  let form = case model {
    DetailView(project_id:, ..) ->
      ui.update_op_form(form, ui.FProjectId, int.to_string(project_id))
    ListView(..) -> form
  }
  OpState(kind:, form:, error: None)
}

// --- View -------------------------------------------------------------------

/// Render the page for `as_of`.
pub fn view(model: Model, as_of: calendar.Date) -> Element(Msg) {
  case model {
    ListView(list:, op:, ..) -> view_list(list, op, as_of)
    DetailView(detail:, op:, ..) -> view_detail(detail, op, as_of)
  }
}

fn view_list(
  list: Load(ProjectList),
  op: Option(OpState),
  as_of: calendar.Date,
) -> Element(Msg) {
  let head =
    ui.page_head(
      title: "Projects",
      blurb: "Active engagements as of "
        <> format_date(as_of)
        <> ", with budget and target completion.",
      actions: [
        op_button("+ Start project", "btn", OpStarted(ui.OpStartProject)),
      ],
    )
  let body = case list {
    Loading -> ui.empty_state(message: "Loading projects…")
    Failed(message:) ->
      ui.empty_state(message: "Could not load projects: " <> message)
    Loaded(value:) -> view_project_table(value.projects)
  }
  html.div([], [head, op_form_panel(op), body])
}

fn view_project_table(rows: List(ProjectListRow)) -> Element(Msg) {
  let body = case rows {
    [] -> ui.empty_state(message: "No projects.")
    rows ->
      ui.data_table(
        headers: [
          #("Project", False),
          #("State", False),
          #("Team", True),
          #("Budget", True),
          #("Target", False),
        ],
        rows: list.index_map(rows, project_row),
      )
  }
  ui.panel(
    title: "All projects",
    count: int.to_string(list.length(rows)),
    right: [],
    body: [body],
  )
}

fn project_row(row: ProjectListRow, index: Int) -> Element(Msg) {
  let #(variant, label) = state_pill(row.active)
  html.tr(
    [
      attribute.class("clickable"),
      event.on_click(ProjectRowClicked(project_id: row.project_id)),
    ],
    [
      html.td([], [
        html.div([attribute.class("cell-name")], [
          ui.swatch(category: index, inline: False),
          html.div([], [
            html.div([attribute.class("cell-name__name")], [
              html.text(row.title),
            ]),
            html.div([attribute.class("cell-sub")], [html.text(row.client)]),
          ]),
        ]),
      ]),
      html.td([], [ui.pill(variant: variant, label: label)]),
      html.td([attribute.class("num")], [
        html.text(int.to_string(row.team_size)),
      ]),
      html.td([attribute.class("num")], [html.text(ui.money_k(row.budget))]),
      html.td([attribute.class("mono muted")], [
        html.text(format_date(row.target_completion)),
      ]),
    ],
  )
}

fn view_detail(
  detail: Load(ProjectDetail),
  op: Option(OpState),
  as_of: calendar.Date,
) -> Element(Msg) {
  let back =
    html.a([attribute.class("back-link"), event.on_click(BackToListClicked)], [
      html.text("‹ All projects"),
    ])
  let body = case detail {
    Loading -> ui.empty_state(message: "Loading project…")
    Failed(message:) ->
      ui.empty_state(message: "Could not load project: " <> message)
    Loaded(value:) -> view_project_detail(value, op, as_of)
  }
  html.div([], [back, body])
}

fn view_project_detail(
  detail: ProjectDetail,
  op: Option(OpState),
  as_of: calendar.Date,
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
        op_button(
          "Assign",
          "btn btn--ghost btn--sm",
          OpStarted(ui.OpAssignToProject),
        ),
        op_button(
          "Adjust allocation",
          "btn btn--ghost btn--sm",
          OpStarted(ui.OpChangeAllocationFraction),
        ),
        op_button(
          "Edit profile",
          "btn btn--ghost btn--sm",
          OpStarted(ui.OpUpdateProjectProfile),
        ),
        op_button(
          "Edit plan",
          "btn btn--ghost btn--sm",
          OpStarted(ui.OpUpdateProjectPlan),
        ),
        op_button("Draft invoice", "btn btn--sm", OpStarted(ui.OpDraftInvoice)),
      ]),
    ])
  let stats =
    html.div([attribute.class("stats")], [
      ui.stat(
        value: ui.money_k(detail.plan.budget),
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
        value: ui.money_k(run_rate_of(detail.team)),
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
        team_panel(detail.team, as_of),
        invoices_panel(detail.invoices),
      ]),
      html.div([], [plan_panel(detail)]),
    ])
  html.div([], [head, op_form_panel(op), stats, grid])
}

fn team_panel(team: List(TeamMember), as_of: calendar.Date) -> Element(Msg) {
  let cards = case team {
    [] -> [ui.empty_state(message: "No one allocated on this date.")]
    members -> list.index_map(members, team_card)
  }
  ui.panel(
    title: "Team on " <> format_date(as_of),
    count: int.to_string(list.length(team)),
    right: [],
    body: [
      html.div([attribute.class("board-group")], [
        html.div([attribute.class("board-grid")], cards),
      ]),
    ],
  )
}

fn team_card(member: TeamMember, index: Int) -> Element(Msg) {
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
          html.span([], [html.text(ui.money(member.day_rate) <> "/d")]),
        ]),
      ]),
    ],
  )
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
      html.td([], [html.text(format_month(invoice.billing_from))]),
      html.td([attribute.class("num")], [html.text(ui.money(invoice.total))]),
      html.td([], [ui.pill(variant: invoice.status, label: invoice.status)]),
    ],
  )
}

fn plan_panel(detail: ProjectDetail) -> Element(Msg) {
  ui.panel(title: "Plan", count: "", right: [], body: [
    html.div([attribute.class("pad-detail")], [
      html.div([attribute.class("kv")], [
        ui.kv(key: "Budget", value: ui.money(detail.plan.budget), mono: True),
        ui.kv(
          key: "Target completion",
          value: format_date(detail.plan.target_completion),
          mono: True,
        ),
      ]),
      html.div([attribute.class("note")], [
        html.text(
          format_date(detail.valid_from)
          <> " → "
          <> format_date(detail.valid_to),
        ),
      ]),
    ]),
  ])
}

// --- Op-form view -----------------------------------------------------------

/// The contextual-operation form panel, shown only while a form is open. It
/// renders the kind-specific fields, an error line (validation prompt or rejected
/// server message), and Apply/Cancel buttons.
fn op_form_panel(op: Option(OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(OpState(kind:, form:, error:)) ->
      ui.panel(title: op_title(kind), count: "", right: [], body: [
        html.div([attribute.class("op-form")], op_fields(kind, form)),
        op_error(error),
        html.div([attribute.class("action-row")], [
          op_button("Apply", "btn", OpSubmitted),
          op_button("Cancel", "btn btn--ghost", OpCancelled),
        ]),
      ])
  }
}

fn op_error(error: Option(String)) -> Element(Msg) {
  case error {
    None -> element.none()
    Some(message) -> html.div([attribute.class("note")], [html.text(message)])
  }
}

fn op_fields(kind: ui.OpKind, form: ui.OpForm) -> List(Element(Msg)) {
  case kind {
    ui.OpStartProject -> [
      text_field("Title", ui.FName, form.name),
      number_field("Contract id", ui.FContractId, form.contract_id),
      date_field("Valid from", ui.FValidFrom, form.valid_from),
      date_field("Valid to", ui.FValidTo, form.valid_to),
    ]
    ui.OpAssignToProject -> [
      number_field("Engineer id", ui.FEngineerId, form.engineer_id),
      number_field("Project id", ui.FProjectId, form.project_id),
      number_field("Fraction", ui.FFraction, form.fraction),
      date_field("Valid from", ui.FValidFrom, form.valid_from),
      date_field("Valid to", ui.FValidTo, form.valid_to),
    ]
    ui.OpChangeAllocationFraction -> [
      number_field("Engineer id", ui.FEngineerId, form.engineer_id),
      number_field("Project id", ui.FProjectId, form.project_id),
      number_field("Fraction", ui.FFraction, form.fraction),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpUpdateProjectProfile -> [
      number_field("Project id", ui.FProjectId, form.project_id),
      text_field("Title", ui.FTitle, form.title),
      text_field("Summary", ui.FSummary, form.summary),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpUpdateProjectPlan -> [
      number_field("Project id", ui.FProjectId, form.project_id),
      number_field("Budget", ui.FBudget, form.budget),
      date_field(
        "Target completion",
        ui.FTargetCompletion,
        form.target_completion,
      ),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpDraftInvoice -> [
      number_field("Project id", ui.FProjectId, form.project_id),
      date_field("Billing from", ui.FValidFrom, form.valid_from),
      date_field("Billing to", ui.FValidTo, form.valid_to),
    ]
    _ -> []
  }
}

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
    _ -> "Operation"
  }
}

// --- Small view helpers -----------------------------------------------------

fn op_button(label: String, class: String, msg: Msg) -> Element(Msg) {
  html.button([attribute.class(class), event.on_click(msg)], [html.text(label)])
}

fn state_pill(active: Bool) -> #(String, String) {
  case active {
    True -> #("active", "active")
    False -> #("ended", "ended")
  }
}

fn run_rate_of(team: List(TeamMember)) -> Float {
  list.fold(team, 0.0, fn(total, member) {
    total +. member.fraction *. member.day_rate
  })
}

// --- Date formatting --------------------------------------------------------

fn iso_date(date: calendar.Date) -> String {
  let calendar.Date(year:, month:, day:) = date
  pad4(year) <> "-" <> pad2(calendar.month_to_int(month)) <> "-" <> pad2(day)
}

fn format_date(date: calendar.Date) -> String {
  int.to_string(date.day)
  <> " "
  <> month_abbrev(date.month)
  <> " "
  <> int.to_string(date.year)
}

fn short_date(date: calendar.Date) -> String {
  int.to_string(date.day) <> " " <> month_abbrev(date.month)
}

fn format_month(date: calendar.Date) -> String {
  month_abbrev(date.month) <> " " <> int.to_string(date.year)
}

fn month_abbrev(month: calendar.Month) -> String {
  case month {
    calendar.January -> "Jan"
    calendar.February -> "Feb"
    calendar.March -> "Mar"
    calendar.April -> "Apr"
    calendar.May -> "May"
    calendar.June -> "Jun"
    calendar.July -> "Jul"
    calendar.August -> "Aug"
    calendar.September -> "Sep"
    calendar.October -> "Oct"
    calendar.November -> "Nov"
    calendar.December -> "Dec"
  }
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
