//// The Tempo client SHELL: the login gate, the sidebar, the one global as-of
//// rail (ADR-036), the URL/route wiring (modem), and the active page sum. It
//// composes seven disjoint page modules (`client/page/*`), each implementing the
//// same frozen interface (Model/Msg/OutMsg/init/update/view/refetch), so the
//// per-page work never touches this file.
////
//// The shell owns four cross-cutting messages — SignedIn/SignedOut (the login
//// gate, ADR-035), AsOfChanged (the global as-of), RouteChanged (URL change) —
//// plus one wrapper per page. The time rail (`client/time`) owns its own
//// `time.Msg(AsOfChanged)`; the shell maps it into its OWN `AsOfChanged` via
//// `element.map` (Gleam has no constructor re-export). Scrubbing the rail
//// `modem.replace`s the new `?date=` (so a scrub does not flood history);
//// sidebar and drill-in navigation `push`. The signed-in actor flows into every
//// `api.submit_operation(actor, ...)`, replacing the old hardcoded console actor.
////
//// Imports `client/*` and `shared/*` only — never `server/*`.

import client/page/activity
import client/page/board
import client/page/clients
import client/page/finance
import client/page/people
import client/page/projects
import client/page/settings
import client/route.{type Route}
import client/time
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem

/// The active page and its opaque sub-model. The shell never inspects a page
/// model; it only routes the matching `*Msg` into the matching `*Page`.
pub type Page {
  BoardPage(board.Model)
  PeoplePage(people.Model)
  ClientsPage(clients.Model)
  ProjectsPage(projects.Model)
  FinancePage(finance.Model)
  ActivityPage(activity.Model)
  SettingsPage(settings.Model)
}

/// The shell model: who is signed in (the login gate — `None` shows the gate),
/// the current route, the one global as-of date, and the active page sub-model.
/// The as-of lives ONLY here; pages receive it as a parameter and never store it.
pub type Model {
  Model(actor: Option(String), route: Route, as_of: calendar.Date, page: Page)
}

/// Messages the runtime feeds back to `update`: the four cross-cutting shell
/// messages plus one wrapper per page. `AsOfChanged` is the shell's OWN
/// constructor; the rail's `time.Msg(AsOfChanged)` is mapped into it at the view
/// boundary via `element.map` (not re-exported).
pub type Msg {
  /// An identity was chosen on the login gate; its name becomes the actor.
  SignedIn(actor: String)
  /// The signed-in actor signed out, returning to the login gate.
  SignedOut
  /// The global as-of changed (rail scrub/step/pick/Today). The shell stores it,
  /// `modem.replace`s the new `?date=`, and refetches ONLY the active page.
  AsOfChanged(date: calendar.Date)
  /// The URL changed (modem). The shell reconciles its as-of from the query and,
  /// when the route's page differs, inits the target page.
  RouteChanged(route: Route)
  BoardMsg(board.Msg)
  PeopleMsg(people.Msg)
  ClientsMsg(clients.Msg)
  ProjectsMsg(projects.Msg)
  FinanceMsg(finance.Msg)
  ActivityMsg(activity.Msg)
  SettingsMsg(settings.Msg)
}

/// Client entrypoint: start the Lustre application mounted on `#app`.
pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

/// Initial state: signed out (the login gate), the as-of resolved from the URL's
/// `?date=` (falling back to the seed "now"), and the route resolved from the
/// URL path. The initial effect subscribes to URL changes and kicks off the
/// resting page's fetch.
fn init(_arguments: Nil) -> #(Model, Effect(Msg)) {
  let as_of = initial_as_of()
  let route = initial_route()
  let #(page, page_effect) = init_page(route, as_of, "")
  let model = Model(actor: None, route:, as_of:, page:)
  #(
    model,
    effect.batch([
      modem.init(fn(uri) { RouteChanged(route: route.parse(uri)) }),
      page_effect,
    ]),
  )
}

/// The as-of to open at: the URL's `?date=` when present and valid, otherwise the
/// seed "now". Clamped to the rail bounds so an out-of-range link still lands on
/// a valid position.
fn initial_as_of() -> calendar.Date {
  case modem.initial_uri() {
    Ok(uri) ->
      case route.as_of_of(uri) {
        Some(date) -> time.clamp_date(date)
        None -> time.seed_now
      }
    Error(Nil) -> time.seed_now
  }
}

/// The route to open at: the URL's path when present, otherwise the Board.
fn initial_route() -> Route {
  case modem.initial_uri() {
    Ok(uri) -> route.parse(uri)
    Error(Nil) -> route.Board
  }
}

/// Fold a message into the model.
fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SignedIn(actor:) -> {
      let #(page, page_effect) = init_page(model.route, model.as_of, actor)
      #(Model(..model, actor: Some(actor), page:), page_effect)
    }

    SignedOut -> #(Model(..model, actor: None), effect.none())

    AsOfChanged(date:) -> {
      let as_of = time.clamp_date(date)
      let #(page, page_effect) =
        refetch_page(model.page, as_of, actor_of(model))
      #(
        Model(..model, as_of:, page:),
        effect.batch([sync_as_of(model.route, as_of), page_effect]),
      )
    }

    RouteChanged(route:) -> {
      // Reconcile the global as-of from the URL on every change so a shared link
      // or a back/forward lands on the right instant. Re-init the target page
      // whenever the route DIFFERS from the current one — including a detail id or
      // finance tab/invoice change within the same section — so a cold load,
      // reload, or back/forward of a detail route lands on the detail (the page's
      // `init(route, ..)` loads the right sub-view). No-op when the route is
      // identical (the self-push that follows a page's own Navigate must not loop);
      // refetch when only the as-of moved underneath an identical route.
      let as_of = as_of_from_url(model.as_of)
      case route == model.route {
        True ->
          case as_of == model.as_of {
            True -> #(model, effect.none())
            False -> {
              let #(page, page_effect) =
                refetch_page(model.page, as_of, actor_of(model))
              #(Model(..model, as_of:, page:), page_effect)
            }
          }
        False -> {
          let #(page, page_effect) = init_page(route, as_of, actor_of(model))
          #(Model(..model, route:, as_of:, page:), page_effect)
        }
      }
    }

    BoardMsg(page_msg) ->
      case model.page {
        BoardPage(page_model) -> {
          let #(next, page_effect, outs) = board.update(page_model, page_msg)
          handle_page(
            model,
            BoardPage(next),
            effect.map(page_effect, BoardMsg),
            board_outs(outs),
          )
        }
        _ -> #(model, effect.none())
      }

    PeopleMsg(page_msg) ->
      case model.page {
        PeoplePage(page_model) -> {
          let #(next, page_effect, outs) = people.update(page_model, page_msg)
          handle_page(
            model,
            PeoplePage(next),
            effect.map(page_effect, PeopleMsg),
            people_outs(outs),
          )
        }
        _ -> #(model, effect.none())
      }

    ClientsMsg(page_msg) ->
      case model.page {
        ClientsPage(page_model) -> {
          let #(next, page_effect, outs) = clients.update(page_model, page_msg)
          handle_page(
            model,
            ClientsPage(next),
            effect.map(page_effect, ClientsMsg),
            clients_outs(outs),
          )
        }
        _ -> #(model, effect.none())
      }

    ProjectsMsg(page_msg) ->
      case model.page {
        ProjectsPage(page_model) -> {
          let #(next, page_effect, outs) = projects.update(page_model, page_msg)
          handle_page(
            model,
            ProjectsPage(next),
            effect.map(page_effect, ProjectsMsg),
            projects_outs(outs),
          )
        }
        _ -> #(model, effect.none())
      }

    FinanceMsg(page_msg) ->
      case model.page {
        FinancePage(page_model) -> {
          let #(next, page_effect, outs) = finance.update(page_model, page_msg)
          handle_page(
            model,
            FinancePage(next),
            effect.map(page_effect, FinanceMsg),
            finance_outs(outs),
          )
        }
        _ -> #(model, effect.none())
      }

    ActivityMsg(page_msg) ->
      case model.page {
        ActivityPage(page_model) -> {
          let #(next, page_effect, outs) = activity.update(page_model, page_msg)
          handle_page(
            model,
            ActivityPage(next),
            effect.map(page_effect, ActivityMsg),
            activity_outs(outs),
          )
        }
        _ -> #(model, effect.none())
      }

    SettingsMsg(page_msg) ->
      case model.page {
        SettingsPage(page_model) -> {
          let #(next, page_effect, outs) = settings.update(page_model, page_msg)
          handle_page(
            model,
            SettingsPage(next),
            effect.map(page_effect, SettingsMsg),
            settings_outs(outs),
          )
        }
        _ -> #(model, effect.none())
      }
  }
}

/// A page's cross-cutting effects, lifted from any page's `OutMsg` into the
/// shell's own neutral form. The two-variant `OutMsg` is the ONLY cross-page
/// coupling (frozen in step 5): `Navigate` pushes a route URL,
/// `OperationCommitted` is a no-op for now (a future Activity badge hooks here).
type Out {
  NavigateTo(Route)
  Committed
}

// Each page declares an identical `OutMsg { Navigate(route.Route)
// OperationCommitted }`, but they are DISTINCT types, so each needs a mechanical
// mapper into the shell's neutral `Out`.

fn board_outs(outs: List(board.OutMsg)) -> List(Out) {
  list.map(outs, fn(out) {
    case out {
      board.Navigate(route) -> NavigateTo(route)
      board.OperationCommitted -> Committed
    }
  })
}

fn people_outs(outs: List(people.OutMsg)) -> List(Out) {
  list.map(outs, fn(out) {
    case out {
      people.Navigate(route) -> NavigateTo(route)
      people.OperationCommitted -> Committed
    }
  })
}

fn clients_outs(outs: List(clients.OutMsg)) -> List(Out) {
  list.map(outs, fn(out) {
    case out {
      clients.Navigate(route) -> NavigateTo(route)
      clients.OperationCommitted -> Committed
    }
  })
}

fn projects_outs(outs: List(projects.OutMsg)) -> List(Out) {
  list.map(outs, fn(out) {
    case out {
      projects.Navigate(route) -> NavigateTo(route)
      projects.OperationCommitted -> Committed
    }
  })
}

fn finance_outs(outs: List(finance.OutMsg)) -> List(Out) {
  list.map(outs, fn(out) {
    case out {
      finance.Navigate(route) -> NavigateTo(route)
      finance.OperationCommitted -> Committed
    }
  })
}

fn activity_outs(outs: List(activity.OutMsg)) -> List(Out) {
  list.map(outs, fn(out) {
    case out {
      activity.Navigate(route) -> NavigateTo(route)
      activity.OperationCommitted -> Committed
    }
  })
}

fn settings_outs(outs: List(settings.OutMsg)) -> List(Out) {
  list.map(outs, fn(out) {
    case out {
      settings.Navigate(route) -> NavigateTo(route)
      settings.OperationCommitted -> Committed
    }
  })
}

/// Apply a page transition: store the next page model, batch its (already
/// shell-mapped) effect with the effects its `Out`s induce, and return.
fn handle_page(
  model: Model,
  page: Page,
  page_effect: Effect(Msg),
  outs: List(Out),
) -> #(Model, Effect(Msg)) {
  let out_effect = fold_outs(model, outs)
  #(Model(..model, page:), effect.batch([page_effect, out_effect]))
}

/// Turn the page's `Out`s into shell effects: `NavigateTo` pushes the route URL
/// (carrying the current as-of), `Committed` is a no-op for now.
fn fold_outs(model: Model, outs: List(Out)) -> Effect(Msg) {
  case outs {
    [] -> effect.none()
    [NavigateTo(route), ..rest] ->
      effect.batch([push_route(route, model.as_of), fold_outs(model, rest)])
    [Committed, ..rest] -> fold_outs(model, rest)
  }
}

/// Initialise the page sub-model for a route, on the given actor's behalf, at the
/// as-of, wrapping its effect into the matching shell message.
fn init_page(
  route: Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Page, Effect(Msg)) {
  case route {
    route.Board -> {
      let #(page, eff) = board.init(route, as_of, actor)
      #(BoardPage(page), effect.map(eff, BoardMsg))
    }
    route.People(..) -> {
      let #(page, eff) = people.init(route, as_of, actor)
      #(PeoplePage(page), effect.map(eff, PeopleMsg))
    }
    route.Clients(..) -> {
      let #(page, eff) = clients.init(route, as_of, actor)
      #(ClientsPage(page), effect.map(eff, ClientsMsg))
    }
    route.Projects(..) -> {
      let #(page, eff) = projects.init(route, as_of, actor)
      #(ProjectsPage(page), effect.map(eff, ProjectsMsg))
    }
    route.Finance(..) -> {
      let #(page, eff) = finance.init(route, as_of, actor)
      #(FinancePage(page), effect.map(eff, FinanceMsg))
    }
    route.Activity -> {
      let #(page, eff) = activity.init(route, as_of, actor)
      #(ActivityPage(page), effect.map(eff, ActivityMsg))
    }
    route.Settings -> {
      let #(page, eff) = settings.init(route, as_of, actor)
      #(SettingsPage(page), effect.map(eff, SettingsMsg))
    }
    route.NotFound -> {
      let #(page, eff) = board.init(route, as_of, actor)
      #(BoardPage(page), effect.map(eff, BoardMsg))
    }
  }
}

/// Refetch ONLY the active page for a new as-of, keeping its current sub-model
/// (stale-while-revalidate; half-typed forms survive). Activity's refetch is a
/// deliberate no-op (system-time).
fn refetch_page(
  page: Page,
  as_of: calendar.Date,
  actor: String,
) -> #(Page, Effect(Msg)) {
  case page {
    BoardPage(model) -> {
      let #(next, eff) = board.refetch(model, as_of, actor)
      #(BoardPage(next), effect.map(eff, BoardMsg))
    }
    PeoplePage(model) -> {
      let #(next, eff) = people.refetch(model, as_of, actor)
      #(PeoplePage(next), effect.map(eff, PeopleMsg))
    }
    ClientsPage(model) -> {
      let #(next, eff) = clients.refetch(model, as_of, actor)
      #(ClientsPage(next), effect.map(eff, ClientsMsg))
    }
    ProjectsPage(model) -> {
      let #(next, eff) = projects.refetch(model, as_of, actor)
      #(ProjectsPage(next), effect.map(eff, ProjectsMsg))
    }
    FinancePage(model) -> {
      let #(next, eff) = finance.refetch(model, as_of, actor)
      #(FinancePage(next), effect.map(eff, FinanceMsg))
    }
    ActivityPage(model) -> {
      let #(next, eff) = activity.refetch(model, as_of, actor)
      #(ActivityPage(next), effect.map(eff, ActivityMsg))
    }
    SettingsPage(model) -> {
      let #(next, eff) = settings.refetch(model, as_of, actor)
      #(SettingsPage(next), effect.map(eff, SettingsMsg))
    }
  }
}

/// The signed-in actor name, or the empty string when signed out (init/refetch
/// run on the resting page before sign-in).
fn actor_of(model: Model) -> String {
  case model.actor {
    Some(actor) -> actor
    None -> ""
  }
}

// --- URL <-> as-of ----------------------------------------------------------
// The as-of is mirrored in `?date=YYYY-MM-DD`. Scrubbing the rail `replace`s
// (no history flood); navigation `push`es. Pages never write the URL directly —
// they raise `Navigate`, and the shell owns the modem call.

/// The as-of carried in the live URL, falling back to `current` when absent or
/// malformed. Clamped to the rail bounds.
fn as_of_from_url(current: calendar.Date) -> calendar.Date {
  case modem.initial_uri() {
    Ok(uri) ->
      case route.as_of_of(uri) {
        Some(date) -> time.clamp_date(date)
        None -> current
      }
    Error(Nil) -> current
  }
}

/// Mirror a new as-of into the URL, REPLACING the current history entry so a
/// scrub does not flood the back stack. Keeps the current route's path.
fn sync_as_of(route: Route, as_of: calendar.Date) -> Effect(Msg) {
  modem.replace(route.to_path(route), Some(as_of_query(as_of)), None)
}

/// PUSH a navigation to a route at the current as-of (a new history entry).
fn push_route(route: Route, as_of: calendar.Date) -> Effect(Msg) {
  modem.push(route.to_path(route), Some(as_of_query(as_of)), None)
}

/// The `date=YYYY-MM-DD` query fragment for an as-of (no leading `?`).
fn as_of_query(as_of: calendar.Date) -> String {
  "date=" <> time.iso_date(as_of)
}

// --- View -------------------------------------------------------------------

/// Render the shell: the login gate when signed out, otherwise the sidebar, the
/// global as-of rail (mapped from `time.Msg` into the shell's `AsOfChanged`), and
/// the active page's view.
pub fn view(model: Model) -> Element(Msg) {
  case model.actor {
    None -> view_login()
    Some(actor) -> view_app(model, actor)
  }
}

/// The signed-out login gate (ADR-035): the brand, the seeded engineers as
/// identities, and the Admin/Ops roles. Picking one signs in under that name,
/// which then stamps every operation. Mirrors the prototype's `#login` markup.
fn view_login() -> Element(Msg) {
  html.div([attribute.id("login")], [
    html.div([attribute.class("login__card")], [
      view_brand(),
      html.h1([], [html.text("Sign in")]),
      html.p([attribute.class("login__sub")], [
        html.text(
          "Pick who you are. Tempo stamps every change with your name in the activity log.",
        ),
      ]),
      html.div([attribute.class("eyebrow")], [html.text("People")]),
      html.div(
        [attribute.class("login__identities")],
        list.map(login_people, fn(person) {
          let #(name, sublabel) = person
          view_identity(name, sublabel, arrow: True)
        }),
      ),
      html.div([attribute.class("eyebrow login__eyebrow--spaced")], [
        html.text("Roles"),
      ]),
      html.div(
        [attribute.class("login__roles")],
        list.map(login_roles, fn(role) {
          let #(name, sublabel) = role
          view_identity(name, sublabel, arrow: False)
        }),
      ),
      html.div([attribute.class("login__foot")], [
        html.text("Demo workspace · no password required"),
      ]),
    ]),
  ])
}

/// The seeded engineers offered on the login gate (the first three seed
/// engineers, FR-11), each #(name, "L<n> · band") matching the prototype.
const login_people = [
  #("Priya Sharma", "L5 · Principal"),
  #("Marcus Chen", "L3 · Senior"),
  #("Aisha Okafor", "L4 · Staff"),
]

/// The non-engineer roles offered on the login gate.
const login_roles = [
  #("Admin", "full access"),
  #("Ops", "scheduling & delivery"),
]

/// One login identity button: a name and sub-label, optionally with a trailing
/// arrow. Clicking it signs in under that name.
fn view_identity(
  name: String,
  sublabel: String,
  arrow arrow: Bool,
) -> Element(Msg) {
  let trailing = case arrow {
    True -> [html.span([attribute.class("identity__arrow")], [html.text("→")])]
    False -> []
  }
  html.button(
    [attribute.class("identity"), event.on_click(SignedIn(actor: name))],
    [
      html.div([attribute.class("identity__meta")], [
        html.div([attribute.class("identity__name")], [html.text(name)]),
        html.div([attribute.class("identity__role")], [html.text(sublabel)]),
      ]),
      ..trailing
    ],
  )
}

/// The signed-in chrome: the sidebar, the global as-of rail, and the active
/// page's content. Mirrors the prototype's `#app` grid.
fn view_app(model: Model, actor: String) -> Element(Msg) {
  html.div([attribute.class("app")], [
    view_sidebar(model.route, actor),
    html.div([attribute.class("main")], [
      element.map(time.view(model.as_of), fn(rail_msg) {
        case rail_msg {
          time.AsOfChanged(date) -> AsOfChanged(date:)
        }
      }),
      html.div([attribute.class("content")], [view_page(model)]),
    ]),
  ])
}

/// The sidebar: the brand, the nav (one link per page, the active route
/// highlighted), and the signed-in identity with a sign-out switch. Mirrors the
/// prototype's `.sidebar` markup and classes.
fn view_sidebar(active: Route, actor: String) -> Element(Msg) {
  html.aside([attribute.class("sidebar")], [
    view_brand(),
    html.nav([attribute.class("sidebar__nav")], [
      view_nav_link(active, route.Board, "▦", "Board"),
      view_nav_link(active, route.People(id: None), "◔", "People"),
      view_nav_link(active, route.Clients(id: None), "◇", "Clients"),
      view_nav_link(active, route.Projects(id: None), "▪", "Projects"),
      view_nav_link(
        active,
        route.Finance(tab: route.Invoices, invoice: None),
        "$",
        "Finance",
      ),
      view_nav_link(active, route.Activity, "≋", "Activity"),
      html.div([attribute.class("sidebar__nav-group eyebrow")], [
        html.text("Admin"),
      ]),
      view_nav_link(active, route.Settings, "⚙", "Settings"),
    ]),
    view_who(actor),
  ])
}

/// One nav link. Navigation is a `RouteChanged` raised on click (the shell then
/// pushes the URL), so the sidebar pushes history (vs the rail's replace). The
/// active section carries the `active` class even on a detail view.
fn view_nav_link(
  active: Route,
  target: Route,
  icon: String,
  label: String,
) -> Element(Msg) {
  let class = case same_page(active, target) {
    True -> "sidebar__nav-link sidebar__nav-link--active"
    False -> "sidebar__nav-link"
  }
  html.a(
    [
      attribute.class(class),
      attribute.href(route.to_path(target)),
      event.on_click(RouteChanged(route: target)),
    ],
    [
      html.span([attribute.class("sidebar__nav-icon")], [html.text(icon)]),
      html.text(" " <> label),
    ],
  )
}

/// Whether two routes land on the same sidebar section (ignoring detail ids and
/// finance tabs), so a detail view keeps its section highlighted.
fn same_page(a: Route, b: Route) -> Bool {
  case a, b {
    route.Board, route.Board -> True
    route.People(..), route.People(..) -> True
    route.Clients(..), route.Clients(..) -> True
    route.Projects(..), route.Projects(..) -> True
    route.Finance(..), route.Finance(..) -> True
    route.Activity, route.Activity -> True
    route.Settings, route.Settings -> True
    route.NotFound, route.NotFound -> True
    _, _ -> False
  }
}

/// The signed-in identity footer: an avatar, the actor's name, and a sign-out
/// switch. Mirrors the prototype's `.sidebar__user` block.
fn view_who(actor: String) -> Element(Msg) {
  html.div([attribute.class("sidebar__user")], [
    html.div([attribute.class("sidebar__user-avatar")], [
      html.text(avatar_initials(actor)),
    ]),
    html.div([attribute.class("sidebar__user-meta")], [
      html.div([attribute.class("sidebar__user-name")], [html.text(actor)]),
      html.div([attribute.class("sidebar__user-role")], [html.text("signed in")]),
    ]),
    html.button(
      [
        attribute.class("sidebar__switch"),
        attribute.attribute("aria-label", "Sign out"),
        event.on_click(SignedOut),
      ],
      [html.text("⇄")],
    ),
  ])
}

/// Up to two upper-case initials from a name, for the identity avatar.
fn avatar_initials(name: String) -> String {
  case string.split(string.trim(name), " ") {
    [first, second, ..] -> first_letter(first) <> first_letter(second)
    [only] -> first_letter(only)
    [] -> "?"
  }
}

fn first_letter(word: String) -> String {
  case string.first(word) {
    Ok(letter) -> string.uppercase(letter)
    Error(Nil) -> ""
  }
}

/// The active page's view, wrapped into the shell's message via the matching
/// `*Msg` constructor.
fn view_page(model: Model) -> Element(Msg) {
  case model.page {
    BoardPage(page) -> element.map(board.view(page, model.as_of), BoardMsg)
    PeoplePage(page) -> element.map(people.view(page, model.as_of), PeopleMsg)
    ClientsPage(page) ->
      element.map(clients.view(page, model.as_of), ClientsMsg)
    ProjectsPage(page) ->
      element.map(projects.view(page, model.as_of), ProjectsMsg)
    FinancePage(page) ->
      element.map(finance.view(page, model.as_of), FinanceMsg)
    ActivityPage(page) ->
      element.map(activity.view(page, model.as_of), ActivityMsg)
    SettingsPage(page) ->
      element.map(settings.view(page, model.as_of), SettingsMsg)
  }
}

/// The brand mark + wordmark, shared by the login card and the sidebar. Mirrors
/// the prototype's `.brand` markup.
fn view_brand() -> Element(Msg) {
  html.div([attribute.class("brand")], [
    html.div([attribute.class("brand__mark")], [html.text("◷")]),
    html.div([attribute.class("brand__name")], [
      html.text("Tempo"),
      html.span([], [html.text(".")]),
    ]),
  ])
}
