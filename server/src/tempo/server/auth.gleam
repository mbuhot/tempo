//// Domain: who may do what — the permission-based authorization gate (issue #6).
////
//// A request's `Principal` carries the account identity, the linked engineer (for
//// ownership), and the SET of permission keys it holds as-of today — resolved from the
//// temporal `user_role`/`role_permission` maps by `access.resolve`, never from the
//// cookie. `authorize` maps each command to the permission it requires (and, for the
//// ownership-sensitive ones, whose engineer it targets) and checks the set. ONE place
//// covering every command; it refuses BEFORE any transaction opens, so a denied command
//// never touches the database, and the journal `actor` is the principal's display name.
////
//// No HTTP and no database: the web layer authenticates the request (a signed cookie
//// carrying the account id) and `access.resolve` builds the `Principal`; this module
//// only decides whether that principal may run a command or read a resource.

import gleam/option.{type Option, Some}
import gleam/set.{type Set}
import shared/access
import shared/command.{
  type Command, AllocationCommand, ClientDetailsCommand, EngagementCommand,
  EngineerCommand, EngineerDetailsCommand, InvoiceCommand, LeaveCommand,
  PayrollCommand, ProjectDetailsCommand, ProjectRequirementCommand,
  RateCardCommand, RoleCommand, SalaryCommand, TimesheetCommand,
}
import shared/engineer/command as engineer_command
import shared/engineer_details/command as engineer_details_command
import shared/leave/command as leave_command
import shared/role/command as role_command
import shared/timesheet/command as timesheet_command

/// An authenticated identity: the `account_id` (carried in the signed cookie), the
/// `actor` display name stamped on the journal, the `engineer_id` it is linked to (for
/// ownership; `None` for non-engineer accounts), and the permission keys it holds
/// as-of today. Built ONLY by `access.resolve` from a verified session.
pub type Principal {
  Principal(
    account_id: Int,
    actor: String,
    engineer_id: Option(Int),
    permissions: Set(String),
  )
}

/// Why authorization refused a command: the principal lacks the permission it needs.
pub type AuthzError {
  Forbidden(actor: String, command: String)
}

/// Whether the principal holds a permission key.
pub fn can(principal: Principal, permission: String) -> Bool {
  set.contains(principal.permissions, permission)
}

/// Whether the principal may read engineer `engineer_id`: anyone with `read.engineers`,
/// or the engineer reading their OWN record.
pub fn can_read_engineer(principal: Principal, engineer_id: Int) -> Bool {
  can(principal, access.read_engineers) || owns(principal, engineer_id)
}

fn owns(principal: Principal, engineer_id: Int) -> Bool {
  principal.engineer_id == Some(engineer_id)
}

/// Authorize a principal to run a command, BEFORE any transaction opens: the ONE gate
/// covering every command. Returns the principal's actor (to stamp on the journal) when
/// allowed, or `Forbidden` naming the refused command.
pub fn authorize(
  principal: Principal,
  command: Command,
) -> Result(String, AuthzError) {
  case permitted(principal, command) {
    True -> Ok(principal.actor)
    False ->
      Error(Forbidden(actor: principal.actor, command: command_tag(command)))
  }
}

/// What a command needs: a single permission, or an ownership pair (the `any` form on
/// some engineer, else the `own` form when the principal IS that engineer).
type Requirement {
  Direct(permission: String)
  Owned(own: String, any: String, engineer_id: Int)
}

fn permitted(principal: Principal, command: Command) -> Bool {
  case requirement(command) {
    Direct(permission:) -> can(principal, permission)
    Owned(own:, any:, engineer_id:) ->
      can(principal, any)
      || { can(principal, own) && owns(principal, engineer_id) }
  }
}

/// Map each command to the permission it requires. Exhaustive over `Command`, so a new
/// command with no arm is a compile error rather than a silently-unguarded write.
fn requirement(command: Command) -> Requirement {
  case command {
    EngineerCommand(engineer_command.OnboardEngineer(..)) ->
      Direct(access.engineer_onboard)
    EngineerCommand(engineer_command.Promote(..)) ->
      Direct(access.engineer_promote)
    EngineerCommand(engineer_command.TerminateEmployment(..)) ->
      Direct(access.engineer_terminate)
    EngineerDetailsCommand(details) ->
      Owned(
        access.profile_update_own,
        access.profile_update_any,
        engineer_details_target(details),
      )
    AllocationCommand(_) -> Direct(access.allocation_manage)
    EngagementCommand(_) -> Direct(access.engagement_manage)
    LeaveCommand(leave_command.TakeLeave(engineer_id:, ..)) ->
      Owned(access.leave_take_own, access.leave_take_any, engineer_id)
    TimesheetCommand(entry) ->
      Owned(
        access.timesheet_log_own,
        access.timesheet_log_any,
        timesheet_target(entry),
      )
    ClientDetailsCommand(_) -> Direct(access.client_manage)
    ProjectDetailsCommand(_) -> Direct(access.project_manage)
    ProjectRequirementCommand(_) -> Direct(access.project_manage)
    RateCardCommand(_) -> Direct(access.ratecard_manage)
    SalaryCommand(_) -> Direct(access.salary_set)
    InvoiceCommand(_) -> Direct(access.invoice_manage)
    PayrollCommand(_) -> Direct(access.payroll_run)
    RoleCommand(_) -> Direct(access.roles_manage)
  }
}

fn engineer_details_target(
  command: engineer_details_command.EngineerDetailsCommand,
) -> Int {
  case command {
    engineer_details_command.UpdateContactDetails(engineer_id:, ..) ->
      engineer_id
    engineer_details_command.UpdateBankingDetails(engineer_id:, ..) ->
      engineer_id
    engineer_details_command.UpdateEmergencyContact(engineer_id:, ..) ->
      engineer_id
  }
}

fn timesheet_target(command: timesheet_command.TimesheetCommand) -> Int {
  case command {
    timesheet_command.LogTimesheet(engineer_id:, ..) -> engineer_id
    timesheet_command.LogWeek(engineer_id:, ..) -> engineer_id
  }
}

/// A short tag naming a command for an authorization-error message (so a 403 body can
/// say which command was refused without leaking its parameters).
fn command_tag(command: Command) -> String {
  case command {
    EngineerCommand(engineer_command.OnboardEngineer(..)) -> "onboard_engineer"
    EngineerCommand(engineer_command.Promote(..)) -> "promote"
    EngineerCommand(engineer_command.TerminateEmployment(..)) ->
      "terminate_employment"
    EngineerDetailsCommand(_) -> "update_profile"
    AllocationCommand(_) -> "manage_allocation"
    EngagementCommand(_) -> "manage_engagement"
    LeaveCommand(_) -> "take_leave"
    TimesheetCommand(_) -> "log_timesheet"
    ClientDetailsCommand(_) -> "update_client"
    ProjectDetailsCommand(_) -> "manage_project"
    ProjectRequirementCommand(_) -> "set_project_requirement"
    RateCardCommand(_) -> "manage_rate_card"
    SalaryCommand(_) -> "set_salary"
    InvoiceCommand(_) -> "manage_invoice"
    PayrollCommand(_) -> "run_payroll"
    RoleCommand(role_command.GrantUserRole(..)) -> "grant_user_role"
    RoleCommand(role_command.RevokeUserRole(..)) -> "revoke_user_role"
  }
}
