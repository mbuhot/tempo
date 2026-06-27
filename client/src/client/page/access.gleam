//// The Access management page (Owner-only; the sidebar shows it behind `roles.manage`).
//// A read-only visualization of the role->permission matrix — a roles-by-permissions
//// grid — and the list of users with a toggle per role: granting a role a user lacks or
//// revoking one they hold. Reads `GET /api/access`; a grant/revoke goes through the
//// normal operations pipeline (a `RoleCommand`, effective at the rail's as-of date),
//// then the page refetches the snapshot so the chips reflect the new truth.
////
//// Follows the frozen page interface (init/update/view/refetch + OutMsg).

import client/api
import client/page.{type OutMsg, OperationCommitted}
import gleam/list
import gleam/set
import gleam/time/calendar.{type Date}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/access/view.{type AccessSnapshot, type RoleInfo, type UserRoles}
import shared/command.{RoleCommand}
import shared/role/command as role_command

pub type Model {
  Model(state: State)
}

/// The page's load state: fetching, the loaded snapshot, or a load failure.
pub type State {
  Loading
  Loaded(snapshot: AccessSnapshot)
  Failed(detail: String)
}

pub type Msg {
  SnapshotReturned(result: Result(AccessSnapshot, rsvp.Error(String)))
  GrantRole(account_id: Int, role: String, effective: Date)
  RevokeRole(account_id: Int, role: String, effective: Date)
  OperationReturned(result: Result(Nil, rsvp.Error(String)))
}

pub fn init(_route, _as_of: Date, _actor: String) -> #(Model, Effect(Msg)) {
  #(Model(state: Loading), fetch())
}

pub fn refetch(
  model: Model,
  _as_of: Date,
  _actor: String,
) -> #(Model, Effect(Msg)) {
  #(model, fetch())
}

fn fetch() -> Effect(Msg) {
  api.get("/api/access", view.access_snapshot_decoder(), SnapshotReturned)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    SnapshotReturned(Ok(snapshot)) -> #(
      Model(state: Loaded(snapshot)),
      effect.none(),
      [],
    )
    SnapshotReturned(Error(error)) -> #(
      Model(state: Failed(api.describe_error(error))),
      effect.none(),
      [],
    )
    GrantRole(account_id:, role:, effective:) -> #(
      model,
      submit(role_command.GrantUserRole(account_id:, role:, effective:)),
      [],
    )
    RevokeRole(account_id:, role:, effective:) -> #(
      model,
      submit(role_command.RevokeUserRole(account_id:, role:, effective:)),
      [],
    )
    // A grant/revoke landed (or failed): refetch the snapshot so the chips show the
    // server's truth, and signal the write so the Activity journal can refresh.
    OperationReturned(Ok(_)) -> #(model, fetch(), [OperationCommitted])
    OperationReturned(Error(_)) -> #(model, fetch(), [])
  }
}

fn submit(command: role_command.RoleCommand) -> Effect(Msg) {
  api.submit_operation(RoleCommand(command), OperationReturned)
}

pub fn view(model: Model, as_of: Date) -> Element(Msg) {
  html.div([attribute.class("access")], [
    html.h1([], [html.text("Access")]),
    case model.state {
      Loading ->
        html.p([attribute.class("access__status")], [html.text("Loading…")])
      Failed(detail) ->
        html.p([attribute.class("access__status access__status--error")], [
          html.text(detail),
        ])
      Loaded(snapshot) ->
        html.div([], [view_matrix(snapshot), view_users(snapshot, as_of)])
    },
  ])
}

/// The role->permission matrix: permissions down the rows, roles across the columns, a
/// check where the role grants the permission as-of today.
fn view_matrix(snapshot: AccessSnapshot) -> Element(Msg) {
  let granted =
    set.from_list(
      list.map(snapshot.matrix, fn(grant) {
        grant.role <> "|" <> grant.permission
      }),
    )
  html.section([attribute.class("access__section")], [
    html.div([attribute.class("eyebrow")], [html.text("Roles")]),
    html.div([attribute.class("access__matrix-scroll")], [
      html.table([attribute.class("access__matrix")], [
        html.thead([], [
          html.tr([], [
            html.th([], [html.text("Permission")]),
            ..list.map(snapshot.roles, fn(role) {
              html.th([], [html.text(role.name)])
            })
          ]),
        ]),
        html.tbody(
          [],
          list.map(snapshot.permissions, fn(permission) {
            html.tr([], [
              html.th([attribute.class("access__perm")], [
                html.text(permission.key),
              ]),
              ..list.map(snapshot.roles, fn(role) {
                let held =
                  set.contains(granted, role.name <> "|" <> permission.key)
                html.td([attribute.class(cell_class(held))], [
                  html.text(case held {
                    True -> "✓"
                    False -> ""
                  }),
                ])
              })
            ])
          }),
        ),
      ]),
    ]),
  ])
}

fn cell_class(held: Bool) -> String {
  case held {
    True -> "access__cell access__cell--on"
    False -> "access__cell"
  }
}

/// The users: each account with a toggle button per role (highlighted when held).
/// Clicking grants a role the user lacks, or revokes one they hold, effective at the
/// rail's as-of date.
fn view_users(snapshot: AccessSnapshot, as_of: Date) -> Element(Msg) {
  html.section([attribute.class("access__section")], [
    html.div([attribute.class("eyebrow")], [html.text("People")]),
    html.div(
      [attribute.class("access__users")],
      list.map(snapshot.users, fn(user) {
        view_user(user, snapshot.roles, as_of)
      }),
    ),
  ])
}

fn view_user(
  user: UserRoles,
  roles: List(RoleInfo),
  as_of: Date,
) -> Element(Msg) {
  html.div([attribute.class("access__user")], [
    html.div([attribute.class("access__user-meta")], [
      html.div([attribute.class("access__user-name")], [
        html.text(user.display_name),
      ]),
      html.div([attribute.class("access__user-email")], [
        html.text(user.username),
      ]),
    ]),
    html.div(
      [attribute.class("access__user-roles")],
      list.map(roles, fn(role) { view_role_toggle(user, role, as_of) }),
    ),
  ])
}

fn view_role_toggle(
  user: UserRoles,
  role: RoleInfo,
  as_of: Date,
) -> Element(Msg) {
  let held = list.contains(user.roles, role.name)
  let message = case held {
    True ->
      RevokeRole(account_id: user.account_id, role: role.name, effective: as_of)
    False ->
      GrantRole(account_id: user.account_id, role: role.name, effective: as_of)
  }
  let class = case held {
    True -> "access__role access__role--on"
    False -> "access__role"
  }
  html.button(
    [
      attribute.class(class),
      attribute.attribute("aria-pressed", case held {
        True -> "true"
        False -> "false"
      }),
      event.on_click(message),
    ],
    [html.text(role.name)],
  )
}
