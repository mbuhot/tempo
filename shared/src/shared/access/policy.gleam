//// The write-authorization policy, shared so the server's enforcement gate and the
//// client's launcher gating consult ONE source of truth (issue #22). A `CommandKey` is
//// the payload-free identity of a write command; `requirement` maps each key to the
//// permission it needs (a single permission, or — for the ownership-sensitive ones — an
//// `any` permission OR an `own` permission when acting on one's own record); `satisfies`
//// is the predicate both sides run.
////
//// The two sides reach the key from different starting points and never duplicate the
//// policy: the SERVER resolves `key(command)` from a concrete `Command` (and `target`
//// for the ownership check); the CLIENT resolves the key from the launcher it is about
//// to offer. Read endpoints are NOT modelled here — they are plain single-permission
//// checks against the `shared/access` constants, not command authorization.

import gleam/option.{type Option, None, Some}
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
import shared/timesheet/command as timesheet_command

/// The payload-free identity of a write command — the key the authorization policy is
/// keyed on. One per distinct permission outcome: the engineer lifecycle splits
/// (`Onboard`/`Promote`/`Terminate`) because each needs a different permission, while
/// commands that share an outcome share a key (e.g. every invoice transition is
/// `ManageInvoice`, both project edits and a requirement are `ManageProject`).
pub type CommandKey {
  Onboard
  Promote
  Terminate
  UpdateProfile
  ManageAllocation
  ManageEngagement
  TakeLeave
  LogTimesheet
  UpdateClient
  ManageProject
  ManageRateCard
  SetSalary
  ManageInvoice
  RunPayroll
  ManageRoles
}

/// What a key requires: a single permission (`Direct`), or — for the ownership-sensitive
/// keys — the `any` permission OR the `own` permission when acting on one's OWN record.
pub type Requirement {
  Direct(permission: String)
  Owned(own: String, any: String)
}

/// The permission each command key requires — THE policy table, total over `CommandKey`,
/// so a new key (hence a new command outcome) is a compile error until its permission is
/// declared here. Both the server gate and the client launcher gating resolve through it.
pub fn requirement(key: CommandKey) -> Requirement {
  case key {
    Onboard -> Direct(access.engineer_onboard)
    Promote -> Direct(access.engineer_promote)
    Terminate -> Direct(access.engineer_terminate)
    UpdateProfile -> Owned(access.profile_update_own, access.profile_update_any)
    ManageAllocation -> Direct(access.allocation_manage)
    ManageEngagement -> Direct(access.engagement_manage)
    TakeLeave -> Owned(access.leave_take_own, access.leave_take_any)
    LogTimesheet -> Owned(access.timesheet_log_own, access.timesheet_log_any)
    UpdateClient -> Direct(access.client_manage)
    ManageProject -> Direct(access.project_manage)
    ManageRateCard -> Direct(access.ratecard_manage)
    SetSalary -> Direct(access.salary_set)
    ManageInvoice -> Direct(access.invoice_manage)
    RunPayroll -> Direct(access.payroll_run)
    ManageRoles -> Direct(access.roles_manage)
  }
}

/// The key of a concrete command — the server's entry into the policy. Exhaustive over
/// `Command`, so a new command must be classified here.
pub fn key(command: Command) -> CommandKey {
  case command {
    EngineerCommand(engineer_command.OnboardEngineer(..)) -> Onboard
    EngineerCommand(engineer_command.Promote(..)) -> Promote
    EngineerCommand(engineer_command.TerminateEmployment(..)) -> Terminate
    EngineerDetailsCommand(_) -> UpdateProfile
    AllocationCommand(_) -> ManageAllocation
    EngagementCommand(_) -> ManageEngagement
    LeaveCommand(_) -> TakeLeave
    TimesheetCommand(_) -> LogTimesheet
    ClientDetailsCommand(_) -> UpdateClient
    ProjectDetailsCommand(_) -> ManageProject
    ProjectRequirementCommand(_) -> ManageProject
    RateCardCommand(_) -> ManageRateCard
    SalaryCommand(_) -> SetSalary
    InvoiceCommand(_) -> ManageInvoice
    PayrollCommand(_) -> RunPayroll
    RoleCommand(_) -> ManageRoles
  }
}

/// The engineer a command targets for the ownership check, or `None` when it is not
/// ownership-sensitive — the data half of an `Owned` requirement, which only the concrete
/// command carries. The server pairs this with the principal's linked engineer.
pub fn target(command: Command) -> Option(Int) {
  case command {
    EngineerDetailsCommand(details) -> Some(engineer_details_target(details))
    LeaveCommand(leave_command.TakeLeave(engineer_id:, ..)) -> Some(engineer_id)
    TimesheetCommand(entry) -> Some(timesheet_target(entry))
    _ -> None
  }
}

/// Whether holding `permissions` — and, for an `Owned` requirement, owning the target
/// (`own`) — satisfies `requirement`. The shared predicate the server enforces and the
/// client mirrors.
pub fn satisfies(
  permissions: Set(String),
  own own: Bool,
  requirement requirement: Requirement,
) -> Bool {
  case requirement {
    Direct(permission:) -> set.contains(permissions, permission)
    Owned(own: own_permission, any:) ->
      set.contains(permissions, any)
      || { own && set.contains(permissions, own_permission) }
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
