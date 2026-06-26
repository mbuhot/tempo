//// Domain: the role aggregate — assign or revoke a user's role over time, the temporal
//// `user_role` map behind the Access management page. `command.route` destructures the
//// role command and this operation returns the journal entry plus the access-control
//// `Fact` it records; `command.dispatch` records them (through `repository`) in ONE
//// transaction. No HTTP — never imports `wisp`. The authorization gate (`roles.manage`)
//// runs before dispatch, so only an Owner reaches here.

import gleam/int
import gleam/time/calendar.{type Date}
import shared/command.{RoleCommand} as gateway
import shared/role/command.{type RoleCommand, GrantUserRole, RevokeUserRole}
import tempo/server/fact.{
  type Recorded, Recorded, UserRoleGranted, UserRoleRevoked,
}
import tempo/server/operation.{type OperationError, Event}

/// Route a role command to its operation, returning the audit entry and the fact it
/// records. Exhaustive over `RoleCommand`.
pub fn route(command: RoleCommand) -> Result(Recorded, OperationError) {
  case command {
    GrantUserRole(account_id:, role:, effective:) ->
      grant(command, account_id:, role:, effective:)
    RevokeUserRole(account_id:, role:, effective:) ->
      revoke(command, account_id:, role:, effective:)
  }
}

fn grant(
  command: RoleCommand,
  account_id account_id: Int,
  role role: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "grant_user_role",
        summary: "Grant "
          <> role
          <> " to account "
          <> int.to_string(account_id)
          <> " from "
          <> operation.iso(effective),
        payload: gateway.encode_command(RoleCommand(command)),
      ),
      facts: [UserRoleGranted(account_id:, role:, from: effective)],
    ),
  )
}

fn revoke(
  command: RoleCommand,
  account_id account_id: Int,
  role role: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "revoke_user_role",
        summary: "Revoke "
          <> role
          <> " from account "
          <> int.to_string(account_id)
          <> " from "
          <> operation.iso(effective),
        payload: gateway.encode_command(RoleCommand(command)),
      ),
      facts: [UserRoleRevoked(account_id:, role:, from: effective)],
    ),
  )
}
