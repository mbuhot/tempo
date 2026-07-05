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
import shared/access/policy
import shared/capability/command as capability_command
import shared/command.{
  type Command, AllocationCommand, CapabilityCommand, ClientDetailsCommand,
  EngagementCommand, EngineerCommand, EngineerDetailsCommand,
  EngineerSkillCommand, InvoiceCommand, LeaveCommand, LocationCommand,
  MeetingCommand, PayrollCommand, ProjectCapabilityCommand,
  ProjectDetailsCommand, ProjectRequirementCommand, RateCardCommand, RoleCommand,
  SalaryCommand, SkillCommand, TimesheetCommand, WorkflowCommand,
}
import shared/engineer/command as engineer_command
import shared/engineer_skill/command as engineer_skill_command
import shared/role/command as role_command
import shared/skill/command as skill_command
import shared/workflow/command as workflow_command

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

/// Whether the principal may run `command`, via the SHARED write-authorization policy
/// (`shared/access/policy`) — the same table the client gates its launchers with. A
/// `Direct` requirement is a permission check; an `Owned` one additionally allows the
/// principal their OWN record (the command's `target` engineer matched to the principal's
/// linked engineer).
fn permitted(principal: Principal, command: Command) -> Bool {
  policy.satisfies(
    principal.permissions,
    own: owns_target(principal, command),
    requirement: policy.requirement(policy.key(command)),
  )
}

/// Whether the principal owns the engineer the command targets (for the ownership-
/// sensitive commands); `False` for commands that target no engineer.
fn owns_target(principal: Principal, command: Command) -> Bool {
  case policy.target(command) {
    Some(engineer_id) -> owns(principal, engineer_id)
    _ -> False
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
    ProjectCapabilityCommand(_) -> "set_project_capability"
    RateCardCommand(_) -> "manage_rate_card"
    SalaryCommand(_) -> "set_salary"
    InvoiceCommand(_) -> "manage_invoice"
    PayrollCommand(_) -> "run_payroll"
    RoleCommand(role_command.GrantUserRole(..)) -> "grant_user_role"
    RoleCommand(role_command.RevokeUserRole(..)) -> "revoke_user_role"
    WorkflowCommand(workflow_command.CommitOnboarding(..)) ->
      "commit_onboarding"
    WorkflowCommand(workflow_command.CreateProject(..)) -> "create_project"
    CapabilityCommand(capability_command.CreateCapability(..)) ->
      "create_capability"
    CapabilityCommand(capability_command.DefineCapability(..)) ->
      "define_capability"
    CapabilityCommand(capability_command.RetireCapability(..)) ->
      "retire_capability"
    CapabilityCommand(capability_command.SetCapabilitySkill(..)) ->
      "set_capability_skill"
    CapabilityCommand(capability_command.RemoveCapabilitySkill(..)) ->
      "remove_capability_skill"
    SkillCommand(skill_command.CreateSkill(..)) -> "create_skill"
    SkillCommand(skill_command.DefineSkill(..)) -> "define_skill"
    SkillCommand(skill_command.RetireSkill(..)) -> "retire_skill"
    EngineerSkillCommand(engineer_skill_command.AssessSkill(..)) ->
      "assess_skill"
    LocationCommand(_) -> "set_engineer_location"
    MeetingCommand(_) -> "manage_meeting"
  }
}
