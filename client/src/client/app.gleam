//// The Tempo client SHELL: the login gate, the sidebar, the one global as-of
//// rail (ADR-036), the URL/route wiring (modem), and the active page sum. It
//// composes seven disjoint page modules (`client/page/*`), each implementing the
//// same frozen interface (Model/Msg/OutMsg/init/update/view/refetch), so the
//// per-page work never touches this file.
////
//// The shell owns the cross-cutting messages — the login form
//// (LoginUsernameChanged/LoginPasswordChanged/LoginRememberToggled/LoginSubmitted/
//// LoginReturned) and SignedOut/LogoutReturned (real password auth, issue #6),
//// AsOfChanged (a discrete as-of change), AsOfScrubbed + AsOfScrubSettled (the debounced slider
//// scrub), RouteChanged (URL change) — plus one wrapper per page. The time rail
//// (`client/time`) maps its messages into these via `element.map` (Gleam has no
//// constructor re-export). A discrete change (step/pick/Today) applies at once:
//// refetch + `modem.replace` the new `?date=`. A scrub updates the as-of and
//// `?date=` INSTANTLY (so the readout tracks the thumb and the URL stays
//// shareable) but defers the refetch to a settle, debounced via `scheduler.after`
//// and guarded by a generation token so only the final position fetches (a scrub
//// does not flood the network). The URL is synced on the scrub tick rather than
//// the settle so its same-route RouteChanged echo is a clean no-op, never a
//// settle's `replace` racing a navigation. Sidebar and drill-in navigation `push`.
//// Submitting the login form AUTHENTICATES the credentials server-side (`api.login`,
//// which verifies the password and issues a signed session cookie); the actor is
//// then the server-confirmed name, and the browser carries the cookie on every
//// `api.submit_operation(...)` so the server derives the journal actor from the
//// session, never the request body (issue #6). Sign-out clears the cookie via
//// `api.logout`.
////
//// Imports `client/*` and `shared/*` only — never `server/*`.

import client/api
import client/page.{type OutMsg}
import client/page/access
import client/page/activity
import client/page/board
import client/page/clients
import client/page/finance
import client/page/people
import client/page/projects
import client/page/settings
import client/route.{type Route}
import client/scheduler
import client/storage
import client/time
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import gleam/time/calendar
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import modem
import rsvp
import shared/access as perm

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
  AccessPage(access.Model)
}

/// The shell model: who is signed in (the login gate — `None` shows the gate),
/// the current route, the one global as-of date, the active page sub-model, the
/// scrub generation token, and the login form's state. The as-of lives ONLY here;
/// pages receive it as a parameter and never store it. `scrub_token` is bumped on
/// every as-of/route change so a debounced scrub-settle only refetches when it is
/// still the latest.
pub type Model {
  Model(
    actor: Option(String),
    engineer_id: Option(Int),
    permissions: Set(String),
    route: Route,
    as_of: calendar.Date,
    page: Page,
    scrub_token: Int,
    login: LoginForm,
  )
}

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
fn empty_login() -> LoginForm {
  LoginForm(
    username: "",
    password: "",
    remember: False,
    error: None,
    submitting: False,
  )
}

/// The debounce window (ms) for a slider scrub: the as-of updates instantly, but
/// the refetch + URL sync wait this long after the last drag tick.
const scrub_refetch_ms = 150

/// Messages the runtime feeds back to `update`: the four cross-cutting shell
/// messages plus one wrapper per page. `AsOfChanged` is the shell's OWN
/// constructor; the rail's `time.Msg(AsOfChanged)` is mapped into it at the view
/// boundary via `element.map` (not re-exported).
pub type Msg {
  /// The login form's email field changed.
  LoginUsernameChanged(value: String)
  /// The login form's password field changed.
  LoginPasswordChanged(value: String)
  /// The "remember me" checkbox was toggled.
  LoginRememberToggled(value: Bool)
  /// The login form was submitted: authenticate the typed credentials server-side
  /// (POST /api/login, which verifies the password and issues the session cookie).
  LoginSubmitted
  /// The login POST returned: `Ok(identity)` is the server-authenticated identity
  /// (actor + linked engineer + permission keys; becomes the shell's identity and
  /// enters the app); an `Error` keeps the gate up with an inline message so bad
  /// credentials cannot sign in.
  LoginReturned(result: Result(api.Identity, rsvp.Error(String)))
  /// The signed-in actor signed out: clear the session cookie server-side
  /// (POST /api/logout) and return to the login gate.
  SignedOut
  /// The logout POST returned; the gate is already shown, so the result is ignored.
  LogoutReturned(result: Result(Nil, rsvp.Error(String)))
  /// GET /api/me returned: `Ok` restores the session from the cookie (on boot, or
  /// refreshes permissions after a write); an `Error` (no valid session) leaves the
  /// gate up. The canonical source of the actor + effective permissions.
  MeReturned(result: Result(api.Identity, rsvp.Error(String)))
  /// A discrete as-of change (rail step/pick/Today). The shell stores it,
  /// `modem.replace`s the new `?date=`, and refetches ONLY the active page — all
  /// at once.
  AsOfChanged(date: calendar.Date)
  /// A slider scrub tick. The shell stores the new as-of and syncs `?date=`
  /// immediately (so the rail readout tracks the thumb and the URL stays
  /// shareable) and schedules a debounced `AsOfScrubSettled`, but does NOT refetch
  /// yet.
  AsOfScrubbed(date: calendar.Date)
  /// A scheduled scrub settle: refetch the active page, but only if `token` is
  /// still the model's current `scrub_token` (a later scrub or any navigation
  /// supersedes it). The URL was already synced on the scrub tick.
  AsOfScrubSettled(token: Int)
  /// The URL changed (modem). Carries the route AND the `?date=` parsed from the
  /// SAME uri, so the shell reconciles its as-of from the CURRENT url (never the
  /// page-load url), and inits the target page when the route's page differs.
  RouteChanged(route: Route, as_of: Option(calendar.Date))
  BoardMsg(board.Msg)
  PeopleMsg(people.Msg)
  ClientsMsg(clients.Msg)
  ProjectsMsg(projects.Msg)
  FinanceMsg(finance.Msg)
  ActivityMsg(activity.Msg)
  SettingsMsg(settings.Msg)
  AccessMsg(access.Msg)
}

/// Client entrypoint: start the Lustre application mounted on `#app`.
pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

/// Initial state: the as-of and route resolved from the URL. We do NOT fetch the page
/// yet — instead we ask `GET /api/me` to restore the session from the cookie. If it
/// resolves `Ok`, `MeReturned` enters the app and fetches the page; if `Error` (no valid
/// session), the login gate stays. This keeps a reload signed in (the cookie survives)
/// without trusting any client-held permissions. The initial effect also subscribes to
/// URL changes.
fn init(_arguments: Nil) -> #(Model, Effect(Msg)) {
  let as_of = initial_as_of()
  let route = initial_route()
  let #(page, _page_effect) = init_page(route, as_of, "")
  let model =
    Model(
      actor: None,
      engineer_id: None,
      permissions: set.new(),
      route:,
      as_of:,
      page:,
      scrub_token: 0,
      login: empty_login(),
    )
  #(
    model,
    effect.batch([
      modem.init(fn(uri) { RouteChanged(route.parse(uri), route.as_of_of(uri)) }),
      api.me(MeReturned),
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
    LoginUsernameChanged(value:) -> #(
      Model(..model, login: LoginForm(..model.login, username: value)),
      effect.none(),
    )

    LoginPasswordChanged(value:) -> #(
      Model(..model, login: LoginForm(..model.login, password: value)),
      effect.none(),
    )

    LoginRememberToggled(value:) -> #(
      Model(..model, login: LoginForm(..model.login, remember: value)),
      effect.none(),
    )

    LoginSubmitted -> #(
      Model(
        ..model,
        login: LoginForm(..model.login, error: None, submitting: True),
      ),
      api.login(
        model.login.username,
        model.login.password,
        model.login.remember,
        LoginReturned,
      ),
    )

    LoginReturned(result:) ->
      case result {
        Ok(identity) -> enter(model, identity)
        Error(error) -> #(
          Model(
            ..model,
            login: LoginForm(
              ..model.login,
              error: Some(api.describe_error(error)),
              submitting: False,
            ),
          ),
          effect.none(),
        )
      }

    SignedOut -> #(
      Model(
        ..model,
        actor: None,
        engineer_id: None,
        permissions: set.new(),
        login: empty_login(),
      ),
      api.logout(LogoutReturned),
    )

    LogoutReturned(result: _) -> #(model, effect.none())

    // Boot-restore / refresh: `Ok` enters the app (or updates permissions in place);
    // `Error` (no valid session) leaves the gate up. Never an error to the user — a
    // failed /api/me on boot simply means "not signed in".
    MeReturned(result:) ->
      case result {
        Ok(identity) -> enter(model, identity)
        Error(_) -> #(model, effect.none())
      }

    AsOfChanged(date:) -> {
      let as_of = time.clamp_date(date)
      let #(page, page_effect) =
        refetch_page(model.page, as_of, actor_of(model))
      #(
        Model(..model, as_of:, page:, scrub_token: model.scrub_token + 1),
        effect.batch([sync_as_of(model.route, as_of), page_effect]),
      )
    }

    AsOfScrubbed(date:) -> {
      // Update the as-of INSTANTLY so the rail readout/fill track the thumb and bump
      // the token; defer BOTH the refetch and the URL sync to a debounced settle
      // carrying this token. The URL must NOT be written per tick: a drag fires an
      // `input` on every thumb step, so mirroring `?date=` each time floods
      // history.replaceState past the browser's ~100-per-10s cap (a SecurityError).
      let as_of = time.clamp_date(date)
      let token = model.scrub_token + 1
      #(
        Model(..model, as_of:, scrub_token: token),
        scheduler.after(scrub_refetch_ms, AsOfScrubSettled(token)),
      )
    }

    AsOfScrubSettled(token:) ->
      // Only the latest scrub settles: a later tick or any navigation has bumped
      // scrub_token past this one, so a superseded settle is a no-op. The live settle
      // refetches the page AND mirrors the rested as-of into the URL — collapsing a
      // whole drag's worth of replaceState into ONE write. Syncing HERE is safe
      // because a current token means NO navigation has happened, so we are still on
      // `model.route` and the `replace`'s same-route RouteChanged echo is a clean
      // no-op (a navigation bumps the token, so its settle never reaches this branch
      // and never replaces a route we have already left).
      case token == model.scrub_token {
        False -> #(model, effect.none())
        True -> {
          let #(page, page_effect) =
            refetch_page(model.page, model.as_of, actor_of(model))
          #(
            Model(..model, page:),
            effect.batch([sync_as_of(model.route, model.as_of), page_effect]),
          )
        }
      }

    RouteChanged(route:, as_of: url_as_of) -> {
      // Reconcile the global as-of from the CURRENT url (the uri this event
      // carried), so a shared link or back/forward lands on the right instant, and
      // init the target page (its `init(route, ..)` loads the right sub-view — a
      // detail id, a finance tab — so a cold load, reload, or back/forward lands
      // there). Bump scrub_token so a pending scrub settle does not refetch the
      // page we just left.
      let as_of = case url_as_of {
        Some(date) -> time.clamp_date(date)
        None -> model.as_of
      }
      case route == model.route {
        // Same route: this is the echo of our own `replace` (a scrub tick or a
        // discrete sync). We already hold the authoritative as_of, set
        // synchronously when the change was applied, so the echo is a no-op —
        // whether its date matches (the rested position) or lags (a superseded
        // mid-drag replace, which must NOT drag the as_of backward or refetch). A
        // genuine same-route date change never arrives here: scrubs `replace` (no
        // new history entry) and navigation `push`es a route change, so
        // back/forward always lands on a DIFFERENT route.
        True -> #(model, effect.none())
        False -> {
          let #(page, page_effect) = init_page(route, as_of, actor_of(model))
          #(
            Model(
              ..model,
              route:,
              as_of:,
              page:,
              scrub_token: model.scrub_token + 1,
            ),
            page_effect,
          )
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
            page_outs(outs),
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
            page_outs(outs),
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
            page_outs(outs),
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
            page_outs(outs),
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
            page_outs(outs),
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
            page_outs(outs),
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
            page_outs(outs),
          )
        }
        _ -> #(model, effect.none())
      }

    AccessMsg(page_msg) ->
      case model.page {
        AccessPage(page_model) -> {
          let #(next, page_effect, outs) = access.update(page_model, page_msg)
          handle_page(
            model,
            AccessPage(next),
            effect.map(page_effect, AccessMsg),
            page_outs(outs),
          )
        }
        _ -> #(model, effect.none())
      }
  }
}

/// A page's cross-cutting effects, lifted from the shared `page.OutMsg` into the
/// shell's own neutral form. The two-variant `OutMsg` is the ONLY cross-page
/// coupling (one shared type, `client/page`, since issue #10): `Navigate` pushes a
/// route URL; `OperationCommitted` re-reads `/api/me` so the actor's permissions
/// converge if a write changed them.
type Out {
  NavigateTo(Route)
  Committed
}

/// Map the page-interface `OutMsg`s every page now shares into the shell's neutral
/// `Out`. One mapper, since all seven pages raise the SAME `page.OutMsg` (they used
/// to each declare an identical-but-distinct copy needing a mapper apiece).
fn page_outs(outs: List(OutMsg)) -> List(Out) {
  list.map(outs, fn(out) {
    case out {
      page.Navigate(route) -> NavigateTo(route)
      page.OperationCommitted -> Committed
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
/// (carrying the current as-of); `Committed` is a DELIBERATE global no-op (issue
/// #10's invalidation decision). Each page holds only its own data and re-`init`s
/// (a full refetch) whenever the shell navigates to it, so a write committed on
/// one page is re-read the next time any other page is opened — there is no
/// cross-page cache to stale. The committed signal is kept on the interface (not
/// dropped) so the day a cross-page cache or an Activity unread-badge lands, the
/// hook is already wired: this branch becomes its invalidation point, no page or
/// interface change needed.
fn fold_outs(model: Model, outs: List(Out)) -> Effect(Msg) {
  case outs {
    [] -> effect.none()
    [NavigateTo(route), ..rest] ->
      effect.batch([push_route(route, model.as_of), fold_outs(model, rest)])
    // A write committed: re-read `/api/me` so the actor's own permissions converge if
    // the write changed them (e.g. an Owner granting/revoking on the Access page).
    [Committed, ..rest] ->
      effect.batch([api.me(MeReturned), fold_outs(model, rest)])
  }
}

/// Enter the app with a resolved identity. On boot/login (was signed OUT) it seats the
/// actor + permissions and fetches the current route's page. On a refresh (already
/// signed in — e.g. after a write re-reads `/api/me`) it updates the actor and
/// permissions IN PLACE, leaving the current page untouched so an in-flight view is not
/// reset.
fn enter(model: Model, identity: api.Identity) -> #(Model, Effect(Msg)) {
  let was_signed_in = model.actor != None
  let model =
    Model(
      ..model,
      actor: Some(identity.actor),
      engineer_id: identity.engineer_id,
      permissions: set.from_list(identity.permissions),
      login: empty_login(),
    )
  let remember_actor = storage.set("tempo.actor", identity.actor)
  case was_signed_in {
    True -> #(model, remember_actor)
    False -> {
      let #(page, page_effect) =
        init_page(model.route, model.as_of, identity.actor)
      #(Model(..model, page:), effect.batch([remember_actor, page_effect]))
    }
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
    route.Access -> {
      let #(page, eff) = access.init(route, as_of, actor)
      #(AccessPage(page), effect.map(eff, AccessMsg))
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
    AccessPage(model) -> {
      let #(next, eff) = access.refetch(model, as_of, actor)
      #(AccessPage(next), effect.map(eff, AccessMsg))
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
    None -> view_login(model.login)
    Some(actor) -> view_app(model, actor)
  }
}

/// The signed-out login gate: the brand and a real credentials form — email,
/// password, and a separate "remember me" opt-in (off by default → a session cookie;
/// on → a persistent one). Submitting authenticates server-side; a rejected attempt
/// shows an inline error and keeps the gate up. The authenticated name stamps every
/// later operation.
fn view_login(form: LoginForm) -> Element(Msg) {
  html.div([attribute.id("login")], [
    html.div([attribute.class("login__card")], [
      view_brand(),
      html.h1([], [html.text("Sign in")]),
      html.p([attribute.class("login__sub")], [
        html.text(
          "Sign in with your Tempo account. Every change is stamped with your name in the activity log.",
        ),
      ]),
      html.form(
        [attribute.class("login__form"), event.on_submit(submit_login)],
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
              event.on_input(LoginUsernameChanged),
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
              event.on_input(LoginPasswordChanged),
            ]),
          ),
          html.label([attribute.class("login__remember")], [
            html.input([
              attribute.type_("checkbox"),
              attribute.checked(form.remember),
              event.on_check(LoginRememberToggled),
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

/// `LoginSubmitted` regardless of the browser-collected form data — the typed values
/// are already in the model via the per-field `on_input` handlers.
fn submit_login(_form_data: List(#(String, String))) -> Msg {
  LoginSubmitted
}

/// A labelled form field: a `<label for>` bound to the control's id so it is
/// reachable by its accessible name.
fn view_field(
  id id: String,
  label label: String,
  control control: Element(Msg),
) -> Element(Msg) {
  html.div([attribute.class("login__field")], [
    html.label([attribute.for(id)], [html.text(label)]),
    control,
  ])
}

/// The inline login error, shown only after a rejected attempt.
fn view_login_error(error: Option(String)) -> Element(Msg) {
  case error {
    Some(message) ->
      html.p([attribute.class("login__error"), attribute.role("alert")], [
        html.text(message),
      ])
    None -> element.none()
  }
}

/// The signed-in chrome: the sidebar, the global as-of rail, and the active
/// page's content. Mirrors the prototype's `#app` grid.
fn view_app(model: Model, actor: String) -> Element(Msg) {
  html.div([attribute.class("app")], [
    view_sidebar(model.route, model.as_of, actor, model.permissions),
    html.div([attribute.class("main")], [
      element.map(time.view(model.as_of), fn(rail_msg) {
        case rail_msg {
          time.AsOfChanged(date) -> AsOfChanged(date:)
          time.AsOfScrubbed(date) -> AsOfScrubbed(date:)
        }
      }),
      html.div([attribute.class("content")], [view_page(model)]),
    ]),
  ])
}

/// The sidebar: the brand, the nav (one link per page, the active route
/// highlighted), and the signed-in identity with a sign-out switch. Mirrors the
/// prototype's `.sidebar` markup and classes.
fn view_sidebar(
  active: Route,
  as_of: calendar.Date,
  actor: String,
  permissions: Set(String),
) -> Element(Msg) {
  html.aside([attribute.class("sidebar")], [
    view_brand(),
    html.nav([attribute.class("sidebar__nav")], [
      nav_link_if(
        permissions,
        perm.read_projects,
        active,
        as_of,
        route.Board,
        "▦",
        "Board",
      ),
      nav_link_if(
        permissions,
        perm.read_engineers,
        active,
        as_of,
        route.People(id: None),
        "◔",
        "People",
      ),
      nav_link_if(
        permissions,
        perm.read_projects,
        active,
        as_of,
        route.Clients(id: None),
        "◇",
        "Clients",
      ),
      nav_link_if(
        permissions,
        perm.read_projects,
        active,
        as_of,
        route.Projects(id: None),
        "▪",
        "Projects",
      ),
      nav_link_if(
        permissions,
        perm.read_finances,
        active,
        as_of,
        route.Finance(tab: route.Invoices, invoice: None),
        "$",
        "Finance",
      ),
      nav_link_if(
        permissions,
        perm.read_engineers,
        active,
        as_of,
        route.Activity,
        "≋",
        "Activity",
      ),
      admin_header(permissions),
      nav_link_if(
        permissions,
        perm.read_finances,
        active,
        as_of,
        route.Settings,
        "⚙",
        "Settings",
      ),
      nav_link_if(
        permissions,
        perm.roles_manage,
        active,
        as_of,
        route.Access,
        "⛭",
        "Access",
      ),
    ]),
    view_who(actor),
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
  icon: String,
  label: String,
) -> Element(Msg) {
  case set.contains(permissions, permission) {
    True -> view_nav_link(active, as_of, target, icon, label)
    False -> element.none()
  }
}

/// The "Admin" group header, shown only when the principal has at least one admin item
/// (Settings or Access) so it never sits above an empty group.
fn admin_header(permissions: Set(String)) -> Element(Msg) {
  case
    set.contains(permissions, perm.read_finances)
    || set.contains(permissions, perm.roles_manage)
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
  icon: String,
  label: String,
) -> Element(Msg) {
  let class = case same_page(active, target) {
    True -> "sidebar__nav-link sidebar__nav-link--active"
    False -> "sidebar__nav-link"
  }
  // A plain in-app link: modem intercepts the click and drives the route, firing
  // RouteChanged with this uri (carrying ?date= so the as-of persists across nav).
  // No explicit on_click — that would double-fire and bypass the URL.
  html.a(
    [
      attribute.class(class),
      attribute.href(route.to_path(target) <> "?" <> as_of_query(as_of)),
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
    route.Access, route.Access -> True
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
/// Render the active page, threading the principal's effective `permissions` (and, for
/// People, the viewer's own `engineer_id`) so each page can hide the in-page action
/// launchers the principal could not run. The server stays the boundary; this is the UI
/// mirror of the sidebar gating.
fn view_page(model: Model) -> Element(Msg) {
  let permissions = model.permissions
  case model.page {
    BoardPage(page) ->
      element.map(board.view(page, model.as_of, permissions), BoardMsg)
    PeoplePage(page) ->
      element.map(
        people.view(page, model.as_of, permissions, model.engineer_id),
        PeopleMsg,
      )
    ClientsPage(page) ->
      element.map(clients.view(page, model.as_of, permissions), ClientsMsg)
    ProjectsPage(page) ->
      element.map(projects.view(page, model.as_of, permissions), ProjectsMsg)
    FinancePage(page) ->
      element.map(finance.view(page, model.as_of, permissions), FinanceMsg)
    ActivityPage(page) ->
      element.map(activity.view(page, model.as_of), ActivityMsg)
    SettingsPage(page) ->
      element.map(settings.view(page, model.as_of, permissions), SettingsMsg)
    AccessPage(page) -> element.map(access.view(page, model.as_of), AccessMsg)
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
