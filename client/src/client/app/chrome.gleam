//// The shell's chrome: the brand mark, the signed-out login gate, and the
//// signed-in sidebar (nav links gated by permission, the identity footer with
//// sign-out). Generic over the shell's message type — the shell passes its own
//// constructors in, so this module renders chrome and raises nothing of its own.

import client/icons
import client/route.{type Route}
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import gleam/time/calendar
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/access as perm

/// The login gate's form state: the typed credentials, the "remember me" opt-in, an
/// inline `error` shown after a rejected attempt, and `submitting` while the login
/// request is in flight (so the button can disable and not double-submit).
pub type LoginForm {
  LoginForm(
    username: String,
    password: String,
    remember: Bool,
    error: Option(String),
    submitting: Bool,
  )
}

/// A blank login form: the gate's resting state (signed out, nothing typed).
pub fn empty_login() -> LoginForm {
  LoginForm(
    username: "",
    password: "",
    remember: False,
    error: None,
    submitting: False,
  )
}

/// The signed-out login gate: the brand and a real credentials form — email,
/// password, and a separate "remember me" opt-in (off by default → a session cookie;
/// on → a persistent one). Submitting authenticates server-side; a rejected attempt
/// shows an inline error and keeps the gate up. The authenticated name stamps every
/// later operation.
pub fn login(
  form form: LoginForm,
  on_username on_username: fn(String) -> msg,
  on_password on_password: fn(String) -> msg,
  on_remember on_remember: fn(Bool) -> msg,
  on_submit on_submit: msg,
) -> Element(msg) {
  html.div([attribute.id("login")], [
    html.div([attribute.class("login__card")], [
      brand(),
      html.h1([], [html.text("Sign in")]),
      html.p([attribute.class("login__sub")], [
        html.text(
          "Sign in with your Tempo account. Every change is stamped with your name in the activity log.",
        ),
      ]),
      html.form(
        [attribute.class("login__form"), event.on_submit(fn(_) { on_submit })],
        [
          view_field(
            id: "login-email",
            label: "Email",
            control: html.input([
              attribute.id("login-email"),
              attribute.type_("email"),
              attribute.name("username"),
              attribute.value(form.username),
              attribute.attribute("autocomplete", "username"),
              event.on_input(on_username),
            ]),
          ),
          view_field(
            id: "login-password",
            label: "Password",
            control: html.input([
              attribute.id("login-password"),
              attribute.type_("password"),
              attribute.name("password"),
              attribute.value(form.password),
              attribute.attribute("autocomplete", "current-password"),
              event.on_input(on_password),
            ]),
          ),
          html.label([attribute.class("login__remember")], [
            html.input([
              attribute.type_("checkbox"),
              attribute.checked(form.remember),
              event.on_check(on_remember),
            ]),
            html.text("Remember me"),
          ]),
          view_login_error(form.error),
          html.button(
            [
              attribute.class("login__submit"),
              attribute.type_("submit"),
              attribute.disabled(form.submitting),
            ],
            [
              html.text(case form.submitting {
                True -> "Signing in…"
                False -> "Sign in"
              }),
            ],
          ),
        ],
      ),
    ]),
  ])
}

/// A labelled form field: a `<label for>` bound to the control's id so it is
/// reachable by its accessible name.
fn view_field(
  id id: String,
  label label: String,
  control control: Element(msg),
) -> Element(msg) {
  html.div([attribute.class("login__field")], [
    html.label([attribute.for(id)], [html.text(label)]),
    control,
  ])
}

/// The inline login error, shown only after a rejected attempt.
fn view_login_error(error: Option(String)) -> Element(msg) {
  case error {
    Some(message) ->
      html.p([attribute.class("login__error"), attribute.role("alert")], [
        html.text(message),
      ])
    None -> element.none()
  }
}

/// The sidebar: the brand, the nav (one link per page, the active route
/// highlighted), and the signed-in identity with a sign-out switch. Mirrors the
/// prototype's `.sidebar` markup and classes.
pub fn sidebar(
  active active: Route,
  as_of as_of: calendar.Date,
  actor actor: String,
  permissions permissions: Set(String),
  on_sign_out on_sign_out: msg,
) -> Element(msg) {
  html.aside([attribute.class("sidebar")], [
    brand(),
    html.nav([attribute.class("sidebar__nav")], [
      nav_link_if(
        permissions,
        perm.read_projects,
        active,
        as_of,
        route.Board,
        icons.board(),
        "Board",
      ),
      nav_link_if(
        permissions,
        perm.read_engineers,
        active,
        as_of,
        route.People(id: None),
        icons.people(),
        "People",
      ),
      nav_link_if(
        permissions,
        perm.read_projects,
        active,
        as_of,
        route.Clients(id: None),
        icons.clients(),
        "Clients",
      ),
      nav_link_if(
        permissions,
        perm.read_projects,
        active,
        as_of,
        route.Projects(id: None),
        icons.projects(),
        "Projects",
      ),
      nav_link_if(
        permissions,
        perm.read_finances,
        active,
        as_of,
        route.Finance(tab: route.Invoices, invoice: None),
        icons.finance(),
        "Finance",
      ),
      nav_link_if(
        permissions,
        perm.read_engineers,
        active,
        as_of,
        route.Activity,
        icons.activity(),
        "Activity",
      ),
      nav_link_if(
        permissions,
        perm.read_engineers,
        active,
        as_of,
        route.Locations,
        icons.locations(),
        "Locations",
      ),
      nav_link_if(
        permissions,
        perm.read_projects,
        active,
        as_of,
        route.Schedule,
        icons.board(),
        "Schedule",
      ),
      nav_link_if(
        permissions,
        perm.read_engineers,
        active,
        as_of,
        route.Meetings,
        icons.meetings(),
        "Meetings",
      ),
      admin_header(permissions),
      nav_link_if(
        permissions,
        perm.skills_manage,
        active,
        as_of,
        route.Skills,
        icons.skills(),
        "Skills",
      ),
      nav_link_if(
        permissions,
        perm.read_finances,
        active,
        as_of,
        route.Settings,
        icons.settings(),
        "Settings",
      ),
      nav_link_if(
        permissions,
        perm.roles_manage,
        active,
        as_of,
        route.Access,
        icons.access(),
        "Access",
      ),
    ]),
    view_who(actor, on_sign_out),
  ])
}

/// Render a nav link only when the principal holds the permission its page needs
/// (server-side gating is the security boundary; this just hides what would 403).
fn nav_link_if(
  permissions: Set(String),
  permission: String,
  active: Route,
  as_of: calendar.Date,
  target: Route,
  icon: Element(msg),
  label: String,
) -> Element(msg) {
  case set.contains(permissions, permission) {
    True -> view_nav_link(active, as_of, target, icon, label)
    False -> element.none()
  }
}

/// The "Admin" group header, shown only when the principal has at least one admin item
/// (Settings or Access) so it never sits above an empty group.
fn admin_header(permissions: Set(String)) -> Element(msg) {
  case
    set.contains(permissions, perm.read_finances)
    || set.contains(permissions, perm.roles_manage)
    || set.contains(permissions, perm.skills_manage)
  {
    True ->
      html.div([attribute.class("sidebar__nav-group eyebrow")], [
        html.text("Admin"),
      ])
    False -> element.none()
  }
}

/// One nav link. Navigation is a `RouteChanged` raised on click (the shell then
/// pushes the URL), so the sidebar pushes history (vs the rail's replace). The
/// active section carries the `active` class even on a detail view.
fn view_nav_link(
  active: Route,
  as_of: calendar.Date,
  target: Route,
  icon: Element(msg),
  label: String,
) -> Element(msg) {
  let class = case same_page(active, target) {
    True -> "sidebar__nav-link sidebar__nav-link--active"
    False -> "sidebar__nav-link"
  }
  // A plain in-app link: modem intercepts the click and drives the route, firing
  // RouteChanged with this uri (carrying ?date= so the as-of persists across nav).
  // No explicit on_click — that would double-fire and bypass the URL.
  html.a(
    [attribute.class(class), attribute.href(route.with_as_of(target, as_of))],
    [
      html.span([attribute.class("sidebar__nav-icon")], [icon]),
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
    route.Access, route.Access -> True
    route.Skills, route.Skills -> True
    route.Locations, route.Locations -> True
    route.Schedule, route.Schedule -> True
    route.Meetings, route.Meetings -> True
    route.NotFound, route.NotFound -> True
    _, _ -> False
  }
}

/// The signed-in identity footer: an avatar, the actor's name, and a sign-out
/// switch. Mirrors the prototype's `.sidebar__user` block.
fn view_who(actor: String, on_sign_out: msg) -> Element(msg) {
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
        event.on_click(on_sign_out),
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

/// The brand mark + wordmark, shared by the login card and the sidebar. Mirrors
/// the prototype's `.brand` markup.
pub fn brand() -> Element(msg) {
  html.div([attribute.class("brand")], [
    html.div([attribute.class("brand__mark")], [icons.clock()]),
    html.div([attribute.class("brand__name")], [
      html.text("Tempo"),
      html.span([], [html.text(".")]),
    ]),
  ])
}
