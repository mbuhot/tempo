//// The Projects page's views: the list mode (page head with the create/start
//// actions, the schema-driven table, the create-project wizard with its rate-card
//// aside) and the detail mode (header, stats, Overview/Coverage tabs, the
//// team/requirements/coverage/invoices/plan panels).

import client/page/projects/op_form.{op_modal}
import client/page/projects/update.{
  type Load, type Model, type Msg, type Tab, AssignRecommendationOpened,
  BackToListClicked, Coverage, CreateProjectClicked, DetailView, Failed,
  InvoiceRowClicked, ListView, Loaded, Loading, OpStarted, OpStartedFor,
  Overview, TabClicked, TableHostMsg, TeamCardClicked, WizardMsg, config,
}
import client/table_host
import client/time
import client/ui/atoms
import client/ui/format
import client/ui/ops
import client/workflow/host
import client/workflow/wizard
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import gleam/time/calendar
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/invoice/status as invoice_status
import shared/invoice/view.{type Invoice} as _
import shared/money
import shared/project/view.{
  type ProjectDetail, type ProjectRequirement, type TeamMember,
} as _
import shared/project_capability/view.{
  type CoverageEngineer, type CoverageRequirement, type CoverageSnapshot,
  type GapRecommendations, type Pairing, type Recommendation, CoverageEngineer,
  CoverageRequirement, CoverageSnapshot, GapRecommendations, Pairing,
  Recommendation,
} as _
import shared/roster/view.{type Roster} as _
import shared/settings/view.{type RateCardRow} as _

// --- View -------------------------------------------------------------------

/// Render the page for `as_of`.
pub fn view(
  model: Model,
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  case model {
    ListView(host:, roster:, op:, wizard:, rates:, ..) ->
      view_list(host, roster, op, wizard, rates, as_of, permissions)
    DetailView(detail:, roster:, op:, tab:, coverage:, recommendations:, ..) ->
      view_detail(
        detail,
        roster,
        op,
        tab,
        coverage,
        recommendations,
        as_of,
        permissions,
      )
  }
}

/// Render the list mode: the page head with the Start-project action, the project
/// list via the generic data table (embedded through its host, which owns the
/// loading / failed guards), and the op modal.
fn view_list(
  host: table_host.Host,
  roster: Load(Roster),
  op: Option(ops.OpState),
  wizard_open: Option(wizard.Model),
  rates: Option(List(RateCardRow)),
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  let page =
    atoms.list_page(
      title: "Projects",
      blurb: "Active engagements as of "
        <> time.format_date(as_of)
        <> ", with budget and target completion.",
      actions: [
        ops.when_permitted(
          ops.permit(permissions, own: False, kind: ops.OpCreateProject),
          fn(_granted) {
            atoms.button(
              label: "+ New project",
              kind: atoms.Primary,
              size: atoms.Medium,
              on_press: CreateProjectClicked,
            )
          },
        ),
        ops.page_action(
          ops.permit(permissions, own: False, kind: ops.OpStartProject),
          OpStarted,
          "+ Start project",
        ),
      ],
      body: element.map(
        table_host.view(host, "Loading projects…"),
        TableHostMsg,
      ),
    )
  html.div([], [
    view_wizard(wizard_open, rates, permissions),
    page,
    op_modal(op, roster, Loading, None),
  ])
}

fn view_wizard(
  open: Option(wizard.Model),
  rates: Option(List(RateCardRow)),
  permissions: Set(String),
) -> Element(Msg) {
  host.view(
    open,
    config(),
    permissions,
    fn(step) {
      case step {
        "contract" -> rates_panel(rates)
        _ -> element.none()
      }
    },
    WizardMsg,
  )
}

fn rates_panel(rates: Option(List(RateCardRow))) -> Element(a) {
  let body = case rates {
    None -> [html.p([], [html.text("Set a contract start date to see rates.")])]
    Some([]) -> [html.p([], [html.text("No rate card for that date.")])]
    Some(rows) ->
      list.map(rows, fn(row) {
        html.div([attribute.class("kv__row")], [
          html.span([attribute.class("kv__key")], [
            html.span([attribute.class("level-pill")], [
              html.text(format.level_band(row.level)),
            ]),
          ]),
          html.span([attribute.class("kv__value mono")], [
            html.text(format.money(money.to_float(row.day_rate)) <> "/d"),
          ]),
        ])
      })
  }
  html.div([attribute.class("wizard__aside")], [
    html.h3([], [html.text("Rate card (from contract date)")]),
    html.div([attribute.class("kv")], body),
  ])
}

fn view_detail(
  detail: Load(ProjectDetail),
  roster: Load(Roster),
  op: Option(ops.OpState),
  tab: Tab,
  coverage: Load(CoverageSnapshot),
  recommendations: Load(List(GapRecommendations)),
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  let back =
    html.a([attribute.class("back-link"), event.on_click(BackToListClicked)], [
      html.text("‹ All projects"),
    ])
  let body = case detail {
    Loading -> atoms.empty_state(message: "Loading project…")
    Failed(message:) ->
      atoms.empty_state(message: "Could not load project: " <> message)
    Loaded(value:) ->
      view_project_detail(
        value,
        roster,
        op,
        tab,
        coverage,
        recommendations,
        as_of,
        permissions,
      )
  }
  html.div([], [back, body])
}

fn view_project_detail(
  detail: ProjectDetail,
  roster: Load(Roster),
  op: Option(ops.OpState),
  tab: Tab,
  coverage: Load(CoverageSnapshot),
  recommendations: Load(List(GapRecommendations)),
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  let head =
    html.div([attribute.class("page-head")], [
      html.div([], [
        html.h1([], [html.text(detail.profile.title)]),
        html.div([attribute.class("detail__subtitle")], [
          atoms.swatch(category: detail.profile.project_id, inline: False),
          html.text(detail.client),
        ]),
        html.p([], [html.text(detail.profile.summary)]),
      ]),
      html.div([attribute.class("action-row")], [
        ops.launch(
          ops.permit(permissions, own: False, kind: ops.OpAssignToProject),
          to_msg: OpStarted,
          label: "Assign",
          kind: atoms.Ghost,
          size: atoms.Small,
        ),
        ops.launch(
          ops.permit(
            permissions,
            own: False,
            kind: ops.OpChangeAllocationFraction,
          ),
          to_msg: OpStarted,
          label: "Adjust allocation",
          kind: atoms.Ghost,
          size: atoms.Small,
        ),
        ops.launch(
          ops.permit(permissions, own: False, kind: ops.OpUpdateProjectProfile),
          to_msg: OpStarted,
          label: "Edit profile",
          kind: atoms.Ghost,
          size: atoms.Small,
        ),
        ops.launch(
          ops.permit(permissions, own: False, kind: ops.OpUpdateProjectPlan),
          to_msg: OpStarted,
          label: "Edit plan",
          kind: atoms.Ghost,
          size: atoms.Small,
        ),
        ops.launch(
          ops.permit(permissions, own: False, kind: ops.OpSetProjectRequirement),
          to_msg: OpStarted,
          label: "Set requirement",
          kind: atoms.Ghost,
          size: atoms.Small,
        ),
        ops.launch(
          ops.permit(permissions, own: False, kind: ops.OpDraftInvoice),
          to_msg: OpStarted,
          label: "Draft invoice",
          kind: atoms.Primary,
          size: atoms.Small,
        ),
      ]),
    ])
  let stats =
    html.div([attribute.class("stats")], [
      atoms.stat(
        value: format.money_k(money.to_float(detail.plan.budget)),
        unit: "",
        label: "Budget",
        pct: atoms.NoPct,
      ),
      atoms.stat(
        value: int.to_string(list.length(detail.team)),
        unit: "people",
        label: "On team now",
        pct: atoms.NoPct,
      ),
      atoms.stat(
        value: format.money_k(money.to_float(run_rate_of(detail.team))),
        unit: "/day",
        label: "Run-rate",
        pct: atoms.NoPct,
      ),
      atoms.stat(
        value: short_date(detail.plan.target_completion),
        unit: "",
        label: "Target",
        pct: atoms.NoPct,
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
    view_tabs(tab),
    subpage(tab == Overview, grid),
    subpage(
      tab == Coverage,
      html.div([], [
        coverage_panel(coverage, permissions, as_of),
        recommendations_panel(recommendations, permissions),
      ]),
    ),
    op_modal(op, roster, coverage, Some(detail.profile.project_id)),
  ])
}

fn view_tabs(active: Tab) -> Element(Msg) {
  html.div([attribute.class("tabs")], [
    tab_button("Overview", Overview, active),
    tab_button("Capability coverage", Coverage, active),
  ])
}

fn tab_button(label: String, tab: Tab, active: Tab) -> Element(Msg) {
  let class = case tab == active {
    True -> "tabs__tab tabs__tab--active"
    False -> "tabs__tab"
  }
  html.button([attribute.class(class), event.on_click(TabClicked(tab))], [
    html.text(label),
  ])
}

fn subpage(active: Bool, body: Element(Msg)) -> Element(Msg) {
  let class = case active {
    True -> "subpage subpage--active"
    False -> "subpage"
  }
  html.div([attribute.class(class)], [body])
}

fn team_panel(
  team: List(TeamMember),
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  let cards = case team {
    [] -> [atoms.empty_state(message: "No one allocated on this date.")]
    members ->
      list.index_map(members, fn(member, index) {
        team_card(member, index, permissions)
      })
  }
  atoms.panel(
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
      atoms.avatar(name: member.name, category: index, class: "avatar"),
      html.div([attribute.class("board-card__info")], [
        html.div([attribute.class("board-card__name")], [html.text(member.name)]),
        html.div([attribute.class("board-card__sub")], [
          html.span([attribute.class("board-card__fraction")], [
            html.text(format.fraction(member.fraction)),
          ]),
          html.span([attribute.class("level-pill")], [
            html.text(format.level_band(member.level)),
          ]),
          html.span([], [
            html.text(format.money(money.to_float(member.day_rate)) <> "/d"),
          ]),
        ]),
      ]),
      html.div([attribute.class("board-card__action")], [
        ops.when_permitted(
          ops.permit(
            permissions,
            own: False,
            kind: ops.OpChangeAllocationFraction,
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
    [] -> [atoms.empty_state(message: "No capacity requirements.")]
    requirements -> list.map(requirements, requirement_row)
  }
  atoms.panel(
    title: "Capacity requirements",
    count: int.to_string(list.length(requirements)),
    right: [],
    body: [html.div([attribute.class("kv")], body)],
  )
}

fn requirement_row(requirement: ProjectRequirement) -> Element(Msg) {
  html.div([attribute.class("kv__row")], [
    html.span([attribute.class("kv__key")], [
      atoms.chip(
        label: format.level_band(requirement.level),
        tone: atoms.Neutral,
      ),
      html.span([attribute.class("board-card__fraction")], [
        html.text("×" <> format.days(requirement.quantity)),
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

/// The Capability coverage tab's panel: per required capability, a coverage bar
/// (have N of M engineers at ≥ target), the covering engineers with their
/// proficiency and allocation share, and the below-target engineers, gated behind
/// the "Set requirement" launcher (`project.manage`).
fn coverage_panel(
  coverage: Load(CoverageSnapshot),
  permissions: Set(String),
  as_of: calendar.Date,
) -> Element(Msg) {
  case coverage {
    Loading ->
      atoms.panel(title: "Capability coverage", count: "", right: [], body: [
        atoms.empty_state(message: "Loading coverage…"),
      ])
    Failed(message:) ->
      atoms.panel(title: "Capability coverage", count: "", right: [], body: [
        atoms.empty_state(message: "Could not load coverage: " <> message),
      ])
    Loaded(value: CoverageSnapshot(requirements:, ..)) -> {
      let launcher =
        ops.launch(
          ops.permit(permissions, own: False, kind: ops.OpSetProjectCapability),
          to_msg: OpStarted,
          label: "Set requirement",
          kind: atoms.Ghost,
          size: atoms.Small,
        )
      let note =
        html.span([attribute.class("note")], [
          html.text("as of " <> time.format_date(as_of)),
        ])
      let body = case requirements {
        [] -> [atoms.empty_state(message: "No capability requirements.")]
        rows -> [
          html.div(
            [attribute.class("coverage"), attribute.role("list")],
            list.index_map(rows, coverage_row),
          ),
        ]
      }
      atoms.panel(
        title: "Capability coverage",
        count: int.to_string(list.length(requirements)),
        right: [note, launcher],
        body:,
      )
    }
  }
}

fn coverage_row(requirement: CoverageRequirement, index: Int) -> Element(Msg) {
  let CoverageRequirement(
    capability_name:,
    target_level:,
    quantity:,
    covering:,
    others:,
    ..,
  ) = requirement
  let covering_count = list.length(covering)
  let slots = capability_quantity_slots(quantity)
  let have_count = int.min(covering_count, slots)
  let gap = int.max(slots - covering_count, 0)
  let count_class = case gap {
    0 -> "coverage__count coverage__count--ok"
    _ -> "coverage__count coverage__count--gap"
  }
  let count_text = case gap {
    0 ->
      int.to_string(covering_count)
      <> " / "
      <> format.days(quantity)
      <> " · covered"
    _ ->
      int.to_string(covering_count)
      <> " / "
      <> format.days(quantity)
      <> " · gap "
      <> int.to_string(gap)
  }
  let bar =
    list.append(
      list.repeat(coverage_slot(True), have_count),
      list.repeat(coverage_slot(False), gap),
    )
  let covering_chips =
    list.map(covering, fn(engineer) { coverage_engineer_chip(engineer) })
  let below_note = case others {
    [] -> element.none()
    engineers ->
      html.span([attribute.class("note")], [
        html.text(
          "below target: "
          <> string.join(list.map(engineers, engineer_summary), " · "),
        ),
      ])
  }
  html.div(
    [
      attribute.class("coverage__row"),
      attribute.role("listitem"),
      attribute.aria_label(capability_name),
    ],
    [
      html.div([attribute.class("coverage__head")], [
        html.span([attribute.class("coverage__cap")], [
          atoms.swatch(category: index, inline: True),
          html.text(capability_name),
        ]),
        html.span([attribute.class("coverage__target")], [
          html.text(
            "target L"
            <> int.to_string(target_level)
            <> " · need "
            <> format.days(quantity),
          ),
        ]),
        html.span([attribute.class(count_class)], [html.text(count_text)]),
      ]),
      html.div([attribute.class("coverage__bar")], bar),
      html.div(
        [attribute.class("coverage__who")],
        list.append(covering_chips, [
          below_note,
        ]),
      ),
    ],
  )
}

/// The number of bar slots a requirement's `quantity` renders as: the fractional
/// count of engineers needed, rounded to a whole slot (coverage counts whole
/// engineers against quantity, ignoring allocation fraction), never fewer than
/// one.
fn capability_quantity_slots(quantity: Float) -> Int {
  int.max(float.round(quantity), 1)
}

fn coverage_slot(have: Bool) -> Element(Msg) {
  let class = case have {
    True -> "coverage__slot coverage__slot--have"
    False -> "coverage__slot coverage__slot--gap"
  }
  html.div([attribute.class(class)], [])
}

fn coverage_engineer_chip(engineer: CoverageEngineer) -> Element(Msg) {
  let CoverageEngineer(name:, proficiency:, allocation:, ..) = engineer
  atoms.chip(
    label: name
      <> " · "
      <> format.days(proficiency)
      <> " · "
      <> format.fraction(allocation),
    tone: atoms.Accent,
  )
}

fn engineer_summary(engineer: CoverageEngineer) -> String {
  let CoverageEngineer(name:, proficiency:, ..) = engineer
  name <> " " <> format.days(proficiency)
}

/// The "Recommended assignments" panel, below Capability coverage: one panel
/// per unmet requirement (`GapRecommendations`), each badged with the gap it
/// addresses and listing the server's top candidates. `Loading`/`Failed` mirror
/// `coverage_panel`'s treatment; an empty gap list reads as every requirement
/// being covered.
fn recommendations_panel(
  recommendations: Load(List(GapRecommendations)),
  permissions: Set(String),
) -> Element(Msg) {
  case recommendations {
    Loading -> recommendations_status_panel("Loading recommendations…")
    Failed(message:) ->
      recommendations_status_panel(
        "Could not load recommendations: " <> message,
      )
    Loaded(value: []) ->
      recommendations_status_panel("All capability requirements are covered.")
    Loaded(value: gaps) ->
      html.div([], list.map(gaps, fn(gap) { gap_panel(gap, permissions) }))
  }
}

fn recommendations_status_panel(message: String) -> Element(Msg) {
  atoms.panel(title: "Recommended assignments", count: "", right: [], body: [
    atoms.empty_state(message:),
  ])
}

/// One gap's section: the panel badged with the capability it addresses,
/// listing the top 4 ready-now recommendations followed by all growth
/// (mentorship) recommendations (or "No suitable candidates."), so a deep
/// ready-now bench never crowds growth rows out of view. Rank numbers
/// continue through this displayed order.
fn gap_panel(
  gap: GapRecommendations,
  permissions: Set(String),
) -> Element(Msg) {
  let GapRecommendations(capability_name:, target_level:, recommendations:, ..) =
    gap
  let displayed = update.ranked_recommendations(recommendations)
  let body = case displayed {
    [] -> [atoms.empty_state(message: "No suitable candidates.")]
    rows -> [
      html.div(
        [attribute.class("rec-rows"), attribute.role("list")],
        list.index_map(rows, fn(recommendation, index) {
          recommendation_row(recommendation, index, target_level, permissions)
        }),
      ),
    ]
  }
  atoms.panel(
    title: "Recommended assignments",
    count: capability_name <> " gap",
    right: [],
    body:,
  )
}

fn recommendation_row(
  recommendation: Recommendation,
  index: Int,
  target_level: Int,
  permissions: Set(String),
) -> Element(Msg) {
  let Recommendation(name:, level:, proficiency:, rationale:, pairing:, ..) =
    recommendation
  let row_class = case pairing {
    Some(_) -> "rec rec--mentor"
    None -> "rec"
  }
  let rank = index + 1
  html.div(
    [
      attribute.class(row_class),
      attribute.role("listitem"),
      attribute.aria_label("Rank " <> int.to_string(rank) <> ": " <> name),
    ],
    [
      html.div([attribute.class("rec__rank")], [
        html.text(int.to_string(rank)),
      ]),
      atoms.avatar(name:, category: index, class: "avatar"),
      html.div([attribute.class("rec__info")], [
        recommendation_name(name, level, pairing),
        html.div([attribute.class("rec__rationale")], [html.text(rationale)]),
      ]),
      recommendation_fit(proficiency, target_level, pairing),
      html.div([attribute.class("rec__action")], [
        assign_button(recommendation, permissions),
      ]),
    ],
  )
}

fn recommendation_name(
  name: String,
  level: Int,
  pairing: Option(Pairing),
) -> Element(Msg) {
  let level_chip =
    atoms.chip(label: format.level_band(level), tone: atoms.Neutral)
  case pairing {
    None ->
      html.div([attribute.class("rec__name")], [html.text(name), level_chip])
    Some(Pairing(teacher_name:, ..)) ->
      html.div([attribute.class("rec__name")], [
        html.span([attribute.class("rec__pair")], [
          html.text(name),
          level_chip,
          html.span([attribute.class("tag-mentor")], [
            html.text("pair with " <> teacher_name),
          ]),
        ]),
      ])
  }
}

fn recommendation_fit(
  proficiency: Float,
  target_level: Int,
  pairing: Option(Pairing),
) -> Element(Msg) {
  case pairing {
    Some(_) ->
      html.div([attribute.class("rec__fit")], [
        html.text("growth"),
        html.small([], [html.text("mentorship")]),
      ])
    None ->
      html.div([attribute.class("rec__fit")], [
        html.text(fit_percent(proficiency, target_level)),
        html.small([], [html.text("ready-now fit")]),
      ])
  }
}

/// `min(proficiency / target_level, 1.0)` as a whole-number percentage.
fn fit_percent(proficiency: Float, target_level: Int) -> String {
  let ratio = float.min(proficiency /. int.to_float(target_level), 1.0)
  format.pct(ratio *. 100.0)
}

fn assign_button(
  recommendation: Recommendation,
  permissions: Set(String),
) -> Element(Msg) {
  ops.launch(
    ops.permit(permissions, own: False, kind: ops.OpAssignToProject),
    to_msg: fn(granted) {
      AssignRecommendationOpened(permit: granted, recommendation:)
    },
    label: "Assign",
    kind: atoms.Ghost,
    size: atoms.Small,
  )
}

fn invoices_panel(invoices: List(Invoice)) -> Element(Msg) {
  let body = case invoices {
    [] -> atoms.empty_state(message: "No invoices.")
    invoices ->
      atoms.data_table(
        headers: [
          #("Invoice", False),
          #("Month", False),
          #("Total", True),
          #("Status as of date", False),
        ],
        rows: list.map(invoices, invoice_row),
      )
  }
  atoms.panel(
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
        html.text(format.money(money.to_float(invoice.total))),
      ]),
      html.td([], [
        atoms.pill(
          variant: invoice_status.to_string(invoice.status),
          label: invoice_status.to_string(invoice.status),
        ),
      ]),
    ],
  )
}

fn plan_panel(detail: ProjectDetail) -> Element(Msg) {
  atoms.panel(title: "Plan", count: "", right: [], body: [
    html.div([attribute.class("pad-detail")], [
      html.div([attribute.class("kv")], [
        atoms.kv(
          key: "Budget",
          value: format.money(money.to_float(detail.plan.budget)),
          mono: True,
        ),
        atoms.kv(
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

// --- Small view helpers -----------------------------------------------------

fn run_rate_of(team: List(TeamMember)) -> money.Money {
  money.sum(
    list.map(team, fn(member) {
      money.scale_by(member.day_rate, member.fraction)
    }),
  )
}

fn short_date(date: calendar.Date) -> String {
  int.to_string(date.day) <> " " <> time.month_abbrev(date.month)
}
