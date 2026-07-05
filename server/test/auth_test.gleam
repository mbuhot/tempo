//// Unit tests for the permission-based authorization gate (issue #6). Pure — no
//// database, no HTTP: `authorize` checks a command against a principal's permission set,
//// the ownership pairs scope `.own` to the principal's own engineer, and
//// `can_read_engineer` allows `read.engineers` or one's own record.

import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/time/calendar
import shared/access
import shared/capability/command as capability_command
import shared/command.{
  CapabilityCommand, EngineerCommand, EngineerSkillCommand, PayrollCommand,
  SalaryCommand, SkillCommand,
}
import shared/engineer/command as engineer_command
import shared/engineer_skill/command as engineer_skill_command
import shared/money.{type Money}
import shared/payroll/command as payroll_command
import shared/salary/command as salary_command
import shared/skill/command as skill_command
import tempo/server/auth.{type Principal, Forbidden, Principal}

fn date() -> calendar.Date {
  calendar.Date(2026, calendar.June, 15)
}

fn money_of(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

fn principal_with(
  permissions: List(String),
  engineer_id: Option(Int),
) -> Principal {
  Principal(
    account_id: 1,
    actor: "Test",
    engineer_id:,
    permissions: set.from_list(permissions),
  )
}

fn update_contact(engineer_id: Int) -> command.Command {
  EngineerCommand(engineer_command.UpdateContactDetails(
    engineer_id:,
    name: "A",
    email: "a@x",
    phone: "1",
    postal_address: "addr",
    effective: date(),
  ))
}

// A command runs only when the principal holds its required permission.
pub fn authorize_requires_the_commands_permission_test() {
  let promote =
    EngineerCommand(engineer_command.Promote(
      engineer_id: 2,
      level: 6,
      effective: date(),
    ))
  assert auth.authorize(
      principal_with([access.engineer_promote], None),
      promote,
    )
    == Ok("Test")
  assert auth.authorize(principal_with([], None), promote)
    == Error(Forbidden(actor: "Test", command: "promote"))
}

// The four financial commands key on distinct permissions, so a manager-style set
// (no money permissions) is refused payroll and salary.
pub fn financial_commands_need_their_own_permissions_test() {
  let payroll = PayrollCommand(payroll_command.RunPayroll(date(), date()))
  let salary =
    SalaryCommand(salary_command.SetSalary(5, money_of("12000.00"), date()))
  assert auth.authorize(principal_with([access.payroll_run], None), payroll)
    == Ok("Test")
  assert auth.authorize(principal_with([access.salary_set], None), salary)
    == Ok("Test")
  assert auth.authorize(principal_with([access.payroll_run], None), salary)
    == Error(Forbidden(actor: "Test", command: "set_salary"))
}

// profile.update is ownership-scoped: `.own` lets the engineer edit their OWN record
// but not another's; `.any` edits anyone's.
pub fn profile_update_is_ownership_scoped_test() {
  let own_set = principal_with([access.profile_update_own], Some(5))
  assert auth.authorize(own_set, update_contact(5)) == Ok("Test")
  assert auth.authorize(own_set, update_contact(9))
    == Error(Forbidden(actor: "Test", command: "update_profile"))

  let any_set = principal_with([access.profile_update_any], None)
  assert auth.authorize(any_set, update_contact(9)) == Ok("Test")
}

// Every capability/skill write keys on skills.manage: a principal holding it may create,
// define, retire, and edit the composition matrix; without it, every one is refused.
pub fn capability_and_skill_commands_need_skills_manage_test() {
  let create_capability =
    CapabilityCommand(capability_command.CreateCapability(
      name: "Cloud Platforms",
      summary: "Designs and operates cloud infrastructure.",
      effective: date(),
    ))
  let define_capability =
    CapabilityCommand(capability_command.DefineCapability(
      capability_id: 1,
      name: "Cloud Platforms",
      summary: "Designs, operates and secures cloud infrastructure.",
      effective: date(),
    ))
  let retire_capability =
    CapabilityCommand(capability_command.RetireCapability(
      capability_id: 1,
      effective: date(),
    ))
  let set_capability_skill =
    CapabilityCommand(capability_command.SetCapabilitySkill(
      capability_id: 1,
      skill_id: 2,
      weight: 3,
      effective: date(),
    ))
  let remove_capability_skill =
    CapabilityCommand(capability_command.RemoveCapabilitySkill(
      capability_id: 1,
      skill_id: 2,
      effective: date(),
    ))
  let create_skill =
    SkillCommand(skill_command.CreateSkill(
      name: "Kubernetes",
      summary: "Operates containerized workloads on Kubernetes.",
      effective: date(),
    ))
  let define_skill =
    SkillCommand(skill_command.DefineSkill(
      skill_id: 2,
      name: "Kubernetes",
      summary: "Designs and operates Kubernetes clusters at scale.",
      effective: date(),
    ))
  let retire_skill =
    SkillCommand(skill_command.RetireSkill(skill_id: 2, effective: date()))

  let manager = principal_with([access.skills_manage], None)
  assert auth.authorize(manager, create_capability) == Ok("Test")
  assert auth.authorize(manager, define_capability) == Ok("Test")
  assert auth.authorize(manager, retire_capability) == Ok("Test")
  assert auth.authorize(manager, set_capability_skill) == Ok("Test")
  assert auth.authorize(manager, remove_capability_skill) == Ok("Test")
  assert auth.authorize(manager, create_skill) == Ok("Test")
  assert auth.authorize(manager, define_skill) == Ok("Test")
  assert auth.authorize(manager, retire_skill) == Ok("Test")

  let unprivileged = principal_with([], None)
  assert auth.authorize(unprivileged, create_capability)
    == Error(Forbidden(actor: "Test", command: "create_capability"))
  assert auth.authorize(unprivileged, define_capability)
    == Error(Forbidden(actor: "Test", command: "define_capability"))
  assert auth.authorize(unprivileged, retire_capability)
    == Error(Forbidden(actor: "Test", command: "retire_capability"))
  assert auth.authorize(unprivileged, set_capability_skill)
    == Error(Forbidden(actor: "Test", command: "set_capability_skill"))
  assert auth.authorize(unprivileged, remove_capability_skill)
    == Error(Forbidden(actor: "Test", command: "remove_capability_skill"))
  assert auth.authorize(unprivileged, create_skill)
    == Error(Forbidden(actor: "Test", command: "create_skill"))
  assert auth.authorize(unprivileged, define_skill)
    == Error(Forbidden(actor: "Test", command: "define_skill"))
  assert auth.authorize(unprivileged, retire_skill)
    == Error(Forbidden(actor: "Test", command: "retire_skill"))
}

// AssessSkill keys on the distinct skills.assess permission: a principal holding it may
// assess, but not manage the taxonomy; the reverse holds for a skills.manage principal.
pub fn assess_skill_needs_skills_assess_not_skills_manage_test() {
  let assess_skill =
    EngineerSkillCommand(engineer_skill_command.AssessSkill(
      engineer_id: 1,
      skill_id: 2,
      level: 4,
      effective: date(),
    ))
  assert auth.authorize(
      principal_with([access.skills_assess], None),
      assess_skill,
    )
    == Ok("Test")
  assert auth.authorize(
      principal_with([access.skills_manage], None),
      assess_skill,
    )
    == Error(Forbidden(actor: "Test", command: "assess_skill"))

  let create_skill =
    SkillCommand(skill_command.CreateSkill(
      name: "Kubernetes",
      summary: "Operates containerized workloads on Kubernetes.",
      effective: date(),
    ))
  assert auth.authorize(
      principal_with([access.skills_assess], None),
      create_skill,
    )
    == Error(Forbidden(actor: "Test", command: "create_skill"))
}

// can_read_engineer: anyone with read.engineers reads any engineer; otherwise only one's
// own record.
pub fn can_read_engineer_allows_any_with_permission_or_own_test() {
  assert auth.can_read_engineer(
    principal_with([access.read_engineers], None),
    9,
  )
  assert !auth.can_read_engineer(principal_with([], Some(5)), 9)
  assert auth.can_read_engineer(principal_with([], Some(5)), 5)
}
